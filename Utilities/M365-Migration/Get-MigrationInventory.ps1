#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, ExchangeOnlineManagement

<#
.SYNOPSIS
    Builds a single migration inventory workbook for a Microsoft 365 tenant,
    combining Exchange Online mailbox data and Microsoft 365 user / group data
    onto separate, purpose-built tabs.

.DESCRIPTION
    Connects to Microsoft Graph and Exchange Online (interactive sign-in) and
    produces ONE Excel workbook (.xlsx) with the tabs a migration actually needs,
    plus a matching CSV for every tab so the data still drops straight into
    third-party migration tools:

      1. User Mailboxes   - Exchange Online UserMailbox rows only.
      2. Shared Mailboxes - Exchange Online SharedMailbox rows only.
      3. M365 Users       - one row per user. The most relevant fields are in the
                            first columns (First Name, Last Name, UPN, sign-in
                            status, title, licenses); progressively less relevant
                            data sits farther right.
      4. Summary          - the at-a-glance view: First Name, Last Name, UPN,
                            Primary Email, Mailbox Type, sign-in status, licenses
                            and assigned roles.
      5. Teams & Groups   - Microsoft 365 Groups, Teams, distribution lists and
                            security groups, including the mail addresses created
                            from groups / Teams / SharePoint.

    Mailbox sizing is pulled once from Exchange Online and reused for both the
    mailbox tabs and the user/summary tabs, so users are NOT queried one mailbox
    at a time. The script is read-only against the tenant.

    This replaces the older Get-M365ActiveUsers.ps1 and Get-ExchangeMailboxes.ps1
    scripts, which produced flat single-purpose CSVs (including a "full" mailbox
    CSV padded with every Get-Mailbox property).

.PARAMETER OutputPath
    Directory where the workbook and CSVs are written. If omitted, defaults to
    "<LocalAppData>\Migration-Automations", prints that path, and asks you to
    confirm it or supply a different directory.

.PARAMETER Prefix
    Text prepended to every output file name (e.g. 'Contoso' ->
    'Contoso_Migration-Inventory_...'). If omitted, you are asked whether you
    want a custom prefix; if not, whether this is the Source or Destination
    tenant and that label is used instead.

.PARAMETER IncludeGuests
    Also include guest (external) user accounts on the user tabs. By default only
    member accounts are exported.

.PARAMETER IncludeDisabled
    Also include accounts where sign-in is blocked (accountEnabled = false). By
    default only enabled accounts are exported.

.PARAMETER IncludeOneDrive
    Also query each user's OneDrive used / total size (Graph, in GB) and add the
    OneDriveUsedGB / OneDriveTotalGB columns to the M365 Users tab. This is one
    extra Graph call per user, so it is opt-in for speed.

.PARAMETER SkipMailboxStats
    Skip the per-mailbox Get-EXOMailboxStatistics lookup for a much faster run.
    Mailbox size and item-count columns are left blank.

.PARAMETER DryRun
    Preview only - resolve the prefix and output location and print the planned
    output files, then exit without connecting to Microsoft 365 or writing
    anything.

.EXAMPLE
    .\Get-MigrationInventory.ps1

    Interactive sign-in, prompts for prefix + output location, writes the
    workbook and per-tab CSVs.

.EXAMPLE
    .\Get-MigrationInventory.ps1 -OutputPath 'C:\Migrations\Contoso' -Prefix Source -IncludeOneDrive

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, Microsoft.Graph, ExchangeOnlineManagement, ImportExcel
    Permissions : Reader-level Graph scopes + a role that can read mailbox
                  statistics (e.g. Exchange / Global Reader).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$Prefix,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeGuests,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeDisabled,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeOneDrive,

    [Parameter(Mandatory = $false)]
    [switch]$SkipMailboxStats,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

#region Shared helpers ---------------------------------------------------------

function Resolve-MigrationOutputDirectory {
    <#
        Returns a usable output directory. If -Path is supplied it is used as-is.
        Otherwise the user is shown the default (<LocalAppData>\Migration-Automations)
        and asked to accept it or provide another. The directory is created if it
        does not exist.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        $resolved = $Path
    }
    else {
        $appData = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($appData)) {
            $appData = [Environment]::GetFolderPath('LocalApplicationData')
        }
        if ([string]::IsNullOrWhiteSpace($appData)) {
            $appData = Join-Path -Path $HOME -ChildPath '.local/share'
        }
        $resolved = Join-Path -Path $appData -ChildPath 'Migration-Automations'

        Write-Host ''
        Write-Host 'No -OutputPath was provided.' -ForegroundColor Yellow
        Write-Host "Default output location: $resolved" -ForegroundColor Cyan

        while ($true) {
            $answer = (Read-Host 'Use this location? [Y] Yes  [N] Choose another') ?? ''
            $answer = $answer.Trim()
            if ($answer -match '^(y|yes|)$') {
                break
            }
            elseif ($answer -match '^(n|no)$') {
                $custom = (Read-Host 'Enter the full path to use for output') ?? ''
                if (-not [string]::IsNullOrWhiteSpace($custom)) {
                    $resolved = $custom.Trim()
                    Write-Host "Output location set to: $resolved" -ForegroundColor Cyan
                    break
                }
                Write-Host 'No path entered - please try again.' -ForegroundColor Red
            }
            else {
                Write-Host 'Please answer Y or N.' -ForegroundColor Red
            }
        }
    }

    if (-not (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
        Write-Host "Created output directory: $resolved" -ForegroundColor Green
    }

    return (Resolve-Path -LiteralPath $resolved).Path
}

function ConvertTo-GBValue {
    <# Converts a byte count to GB rounded to 2 decimals; $null stays $null. #>
    param($Bytes)
    if ($null -eq $Bytes -or $Bytes -eq '') { return $null }
    return [math]::Round(([double]$Bytes / 1GB), 2)
}

function Convert-ExchangeSizeToBytes {
    <# Parses an Exchange ByteQuantifiedSize / string like "1.5 GB (1,610,612,736 bytes)". #>
    param($Size)
    if ($null -eq $Size) { return $null }
    $text = $Size.ToString()
    if ($text -match '\(([\d,]+)\s*bytes\)') {
        return [int64]($Matches[1] -replace ',', '')
    }
    return $null
}

function Initialize-RequiredModule {
    <# Ensures a module is available, installing it for the current user if not. #>
    param([Parameter(Mandatory)][string]$Name)
    if (Get-Module -ListAvailable -Name $Name) { return }
    Write-Host "Installing required module '$Name' (CurrentUser scope)..." -ForegroundColor Yellow
    Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
}

function Format-FilePrefix {
    <# Strips characters that are unsafe in file names and trims separators. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value -replace '[^A-Za-z0-9._-]', '').Trim('_', '.', '-', ' ')
}

function Resolve-FilePrefix {
    <#
        Determines the file-name prefix. If -Value is supplied it is sanitised and
        used. Otherwise the user is asked whether to use a custom prefix; if not,
        whether this is the Source or Destination tenant - that label becomes the
        prefix so file names are self-describing.
    #>
    [CmdletBinding()]
    param([string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $clean = Format-FilePrefix -Value $Value
        if ($clean) { return $clean }
        Write-Host "Provided prefix '$Value' was empty after cleanup; falling back to a prompt." -ForegroundColor Yellow
    }

    Write-Host ''
    while ($true) {
        $answer = ((Read-Host 'Add a custom file-name prefix? [Y] Yes  [N] No (label as Source/Destination)') ?? '').Trim()
        if ($answer -match '^(y|yes)$') {
            $custom = ((Read-Host 'Enter the prefix to use') ?? '').Trim()
            $clean = Format-FilePrefix -Value $custom
            if ($clean) { return $clean }
            Write-Host 'Prefix was empty after cleanup - please try again.' -ForegroundColor Red
        }
        elseif ($answer -match '^(n|no)$') {
            while ($true) {
                $sd = ((Read-Host 'Is this the [S]ource or [D]estination tenant?') ?? '').Trim()
                if ($sd -match '^(s|source)$') { return 'Source' }
                if ($sd -match '^(d|destination)$') { return 'Destination' }
                Write-Host 'Please enter S or D.' -ForegroundColor Red
            }
        }
        else {
            Write-Host 'Please answer Y or N.' -ForegroundColor Red
        }
    }
}

function Export-InventoryTab {
    <#
        Writes one collection to both a worksheet in the shared workbook and a
        standalone CSV. Empty collections still produce a visible tab / CSV with
        an informational placeholder so the workbook structure is predictable.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Data,
        [Parameter(Mandatory)][string]$WorksheetName,
        [Parameter(Mandatory)][string]$ExcelPath,
        [Parameter(Mandatory)][string]$CsvPath
    )

    if (-not $Data -or $Data.Count -eq 0) {
        $Data = @([pscustomobject][ordered]@{ Info = "No $WorksheetName records found." })
    }

    $Data | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    $Data | Export-Excel -Path $ExcelPath -WorksheetName $WorksheetName `
        -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter
}

#endregion ---------------------------------------------------------------------

# Common SKU friendly names. Anything not listed falls back to its SkuPartNumber.
$script:SkuFriendlyNames = @{
    'O365_BUSINESS_ESSENTIALS' = 'Microsoft 365 Business Basic'
    'O365_BUSINESS_PREMIUM'    = 'Microsoft 365 Business Standard'
    'SPB'                      = 'Microsoft 365 Business Premium'
    'SPE_E3'                   = 'Microsoft 365 E3'
    'SPE_E5'                   = 'Microsoft 365 E5'
    'ENTERPRISEPACK'           = 'Office 365 E3'
    'ENTERPRISEPREMIUM'        = 'Office 365 E5'
    'STANDARDPACK'             = 'Office 365 E1'
    'EXCHANGESTANDARD'         = 'Exchange Online (Plan 1)'
    'EXCHANGEENTERPRISE'       = 'Exchange Online (Plan 2)'
    'POWER_BI_STANDARD'        = 'Power BI (free)'
    'POWER_BI_PRO'             = 'Power BI Pro'
    'FLOW_FREE'                = 'Power Automate Free'
    'EMS'                      = 'Enterprise Mobility + Security E3'
    'EMSPREMIUM'               = 'Enterprise Mobility + Security E5'
    'AAD_PREMIUM'              = 'Entra ID P1'
    'AAD_PREMIUM_P2'           = 'Entra ID P2'
    'WINDOWS_STORE'            = 'Windows Store for Business'
    'TEAMS_EXPLORATORY'        = 'Teams Exploratory'
    'MCOMEETADV'               = 'Microsoft 365 Audio Conferencing'
    'MCOEV'                    = 'Microsoft Teams Phone Standard'
    'DESKLESSPACK'             = 'Office 365 F3'
    'SPE_F1'                   = 'Microsoft 365 F3'
}

function Get-FriendlySkuName {
    param([string]$SkuPartNumber)
    if ($script:SkuFriendlyNames.ContainsKey($SkuPartNumber)) {
        return $script:SkuFriendlyNames[$SkuPartNumber]
    }
    return $SkuPartNumber
}

function Get-GroupKind {
    <# Classifies a Graph group into a migration-friendly category. #>
    param($Group, [bool]$IsTeam)
    $types = @($Group.GroupTypes)
    if ($types -contains 'Unified') {
        if ($IsTeam) { return 'Microsoft Team' }
        return 'Microsoft 365 Group'
    }
    if ($Group.MailEnabled -and $Group.SecurityEnabled) { return 'Mail-enabled Security' }
    if ($Group.MailEnabled) { return 'Distribution List' }
    if ($Group.SecurityEnabled) { return 'Security Group' }
    return 'Other'
}

# --- Begin ---------------------------------------------------------------------

Write-Host '=== Microsoft 365 Migration Inventory ===' -ForegroundColor Cyan

$filePrefix = Resolve-FilePrefix -Value $Prefix
$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$excelPath = Join-Path -Path $outputDir -ChildPath "${filePrefix}_Migration-Inventory_$timestamp.xlsx"
$csvPaths = [ordered]@{
    'User Mailboxes'   = Join-Path -Path $outputDir -ChildPath "${filePrefix}_UserMailboxes_$timestamp.csv"
    'Shared Mailboxes' = Join-Path -Path $outputDir -ChildPath "${filePrefix}_SharedMailboxes_$timestamp.csv"
    'M365 Users'       = Join-Path -Path $outputDir -ChildPath "${filePrefix}_M365Users_$timestamp.csv"
    'Summary'          = Join-Path -Path $outputDir -ChildPath "${filePrefix}_Summary_$timestamp.csv"
    'Teams & Groups'   = Join-Path -Path $outputDir -ChildPath "${filePrefix}_TeamsAndGroups_$timestamp.csv"
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN - no connection or file write will occur.' -ForegroundColor Magenta
    Write-Host 'Would connect to Microsoft Graph + Exchange Online and build the inventory.' -ForegroundColor Magenta
    Write-Host 'Planned workbook:' -ForegroundColor Magenta
    Write-Host "  $excelPath" -ForegroundColor Magenta
    Write-Host 'Planned per-tab CSVs:' -ForegroundColor Magenta
    foreach ($name in $csvPaths.Keys) {
        Write-Host ("  {0,-16}: {1}" -f $name, $csvPaths[$name]) -ForegroundColor Magenta
    }
    return
}

Initialize-RequiredModule -Name 'Microsoft.Graph.Users'
Initialize-RequiredModule -Name 'Microsoft.Graph.Groups'
Initialize-RequiredModule -Name 'Microsoft.Graph.Identity.DirectoryManagement'
Initialize-RequiredModule -Name 'Microsoft.Graph.Files'
Initialize-RequiredModule -Name 'ExchangeOnlineManagement'
Initialize-RequiredModule -Name 'ImportExcel'
Import-Module ImportExcel

# Connect to Microsoft Graph (read-only scopes).
Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
$graphScopes = @(
    'User.Read.All'
    'Group.Read.All'
    'Directory.Read.All'
    'Files.Read.All'
    'Organization.Read.All'
    'RoleManagement.Read.Directory'
)
Connect-MgGraph -Scopes $graphScopes -NoWelcome

Write-Host 'Connecting to Exchange Online...' -ForegroundColor Cyan
Connect-ExchangeOnline -ShowBanner:$false

#region Exchange mailboxes -----------------------------------------------------

Write-Host 'Retrieving Exchange Online mailboxes...' -ForegroundColor Cyan
$allMailboxes = Get-Mailbox -ResultSize Unlimited `
    -RecipientTypeDetails @('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox')
Write-Host "Found $($allMailboxes.Count) mailbox(es)." -ForegroundColor Green

# Statistics keyed by ExchangeGuid (one pass, optional).
$statsByGuid = @{}
if (-not $SkipMailboxStats) {
    $index = 0
    foreach ($mbx in $allMailboxes) {
        $index++
        Write-Progress -Activity 'Collecting mailbox statistics' `
            -Status "$index of $($allMailboxes.Count): $($mbx.PrimarySmtpAddress)" `
            -PercentComplete (($index / [math]::Max($allMailboxes.Count, 1)) * 100)
        try {
            $stats = Get-EXOMailboxStatistics -Identity $mbx.ExchangeGuid.ToString() -ErrorAction Stop
            $statsByGuid[$mbx.ExchangeGuid.ToString()] = [pscustomobject]@{
                SizeGB        = ConvertTo-GBValue -Bytes (Convert-ExchangeSizeToBytes -Size $stats.TotalItemSize)
                ItemCount     = $stats.ItemCount
                LastLogonTime = $stats.LastLogonTime
            }
        }
        catch {
            Write-Verbose "No statistics for $($mbx.PrimarySmtpAddress): $($_.Exception.Message)"
        }
    }
    Write-Progress -Activity 'Collecting mailbox statistics' -Completed
}

# Build a mailbox lookup keyed by UPN and primary SMTP (lower-cased) so the user
# tabs can reuse the type and size without re-querying Exchange per user.
$mailboxByKey = @{}
foreach ($mbx in $allMailboxes) {
    $stat = $statsByGuid[$mbx.ExchangeGuid.ToString()]
    $info = [pscustomobject]@{
        Type      = [string]$mbx.RecipientTypeDetails
        SizeGB    = $stat.SizeGB
        ItemCount = $stat.ItemCount
    }
    foreach ($key in @($mbx.UserPrincipalName, $mbx.PrimarySmtpAddress)) {
        if ($key) { $mailboxByKey[$key.ToString().ToLowerInvariant()] = $info }
    }
}

# Shared row builder for the two mailbox tabs.
function New-MailboxRow {
    param($Mailbox, $Stat)
    $aliases = ($Mailbox.EmailAddresses | Where-Object { $_ -clike 'smtp:*' } |
        ForEach-Object { $_ -replace '^smtp:', '' }) -join '; '
    [pscustomobject][ordered]@{
        DisplayName            = $Mailbox.DisplayName
        UserPrincipalName      = $Mailbox.UserPrincipalName
        PrimarySmtpAddress     = $Mailbox.PrimarySmtpAddress
        Alias                  = $Mailbox.Alias
        MailboxSizeGB          = $Stat.SizeGB
        MailboxItemCount       = $Stat.ItemCount
        ArchiveStatus          = $Mailbox.ArchiveStatus
        LitigationHoldEnabled  = $Mailbox.LitigationHoldEnabled
        ForwardingSmtpAddress  = $Mailbox.ForwardingSmtpAddress
        ForwardingAddress      = $Mailbox.ForwardingAddress
        HiddenFromAddressLists = $Mailbox.HiddenFromAddressListsEnabled
        AliasAddresses         = $aliases
        LastLogonTime          = $Stat.LastLogonTime
        WhenCreated            = $Mailbox.WhenCreated
    }
}

Write-Host 'Building mailbox tabs...' -ForegroundColor Cyan
$userMailboxRows = foreach ($mbx in ($allMailboxes | Where-Object { $_.RecipientTypeDetails -eq 'UserMailbox' })) {
    New-MailboxRow -Mailbox $mbx -Stat $statsByGuid[$mbx.ExchangeGuid.ToString()]
}
$sharedMailboxRows = foreach ($mbx in ($allMailboxes | Where-Object { $_.RecipientTypeDetails -eq 'SharedMailbox' })) {
    New-MailboxRow -Mailbox $mbx -Stat $statsByGuid[$mbx.ExchangeGuid.ToString()]
}

#endregion ---------------------------------------------------------------------

#region Microsoft 365 users ----------------------------------------------------

# SKU id -> friendly name map.
Write-Host 'Loading subscribed SKUs...' -ForegroundColor Cyan
$skuMap = @{}
foreach ($sku in Get-MgSubscribedSku -All) {
    $skuMap[$sku.SkuId] = Get-FriendlySkuName -SkuPartNumber $sku.SkuPartNumber
}

# userId -> directory roles map (one bulk pass, cheaper than per-user).
Write-Host 'Mapping directory role assignments...' -ForegroundColor Cyan
$roleMap = @{}
foreach ($role in Get-MgDirectoryRole -All) {
    foreach ($member in Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All) {
        if (-not $roleMap.ContainsKey($member.Id)) {
            $roleMap[$member.Id] = [System.Collections.Generic.List[string]]::new()
        }
        $roleMap[$member.Id].Add($role.DisplayName)
    }
}

$userFilter = 'accountEnabled eq true'
if ($IncludeDisabled) { $userFilter = $null }

$userProperties = @(
    'id', 'displayName', 'givenName', 'surname', 'userPrincipalName', 'mail',
    'jobTitle', 'department', 'officeLocation', 'mobilePhone', 'businessPhones',
    'city', 'state', 'country', 'usageLocation', 'accountEnabled', 'userType',
    'createdDateTime', 'assignedLicenses', 'proxyAddresses'
)

Write-Host 'Retrieving users from Microsoft Graph...' -ForegroundColor Cyan
$getUserParams = @{ All = $true; Property = $userProperties }
if ($userFilter) { $getUserParams['Filter'] = $userFilter }
$users = Get-MgUser @getUserParams

if (-not $IncludeGuests) {
    $users = $users | Where-Object { $_.UserType -ne 'Guest' }
}

Write-Host "Processing $($users.Count) user(s)..." -ForegroundColor Green

$m365Rows = [System.Collections.Generic.List[object]]::new()
$summaryRows = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($user in $users) {
    $index++
    Write-Progress -Activity 'Building user tabs' `
        -Status "$index of $($users.Count): $($user.UserPrincipalName)" `
        -PercentComplete (($index / [math]::Max($users.Count, 1)) * 100)

    # Licenses (friendly names).
    $licenses = @()
    foreach ($lic in $user.AssignedLicenses) {
        if ($skuMap.ContainsKey($lic.SkuId)) { $licenses += $skuMap[$lic.SkuId] }
    }
    $licenseText = ($licenses | Sort-Object -Unique) -join '; '

    # Primary SMTP from proxyAddresses (SMTP: in caps = primary), falling back to Mail.
    $primarySmtp = $user.Mail
    $primaryProxy = $user.ProxyAddresses | Where-Object { $_ -clike 'SMTP:*' } | Select-Object -First 1
    if ($primaryProxy) { $primarySmtp = $primaryProxy -replace '^SMTP:', '' }

    # Roles.
    $roleText = if ($roleMap.ContainsKey($user.Id)) { $roleMap[$user.Id] -join '; ' } else { '' }

    # Mailbox type & size, reused from the Exchange pull (no per-user EXO call).
    $mailboxInfo = $null
    foreach ($key in @($user.UserPrincipalName, $primarySmtp, $user.Mail)) {
        if ($key -and $mailboxByKey.ContainsKey($key.ToString().ToLowerInvariant())) {
            $mailboxInfo = $mailboxByKey[$key.ToString().ToLowerInvariant()]
            break
        }
    }
    $mailboxType = if ($mailboxInfo) { $mailboxInfo.Type } else { 'None' }

    # OneDrive usage (opt-in; one Graph call per user).
    $oneDriveUsedGB = $null
    $oneDriveTotalGB = $null
    if ($IncludeOneDrive) {
        try {
            $drive = Get-MgUserDefaultDrive -UserId $user.Id -ErrorAction Stop
            if ($drive -and $drive.Quota) {
                $oneDriveUsedGB = ConvertTo-GBValue -Bytes $drive.Quota.Used
                $oneDriveTotalGB = ConvertTo-GBValue -Bytes $drive.Quota.Total
            }
        }
        catch {
            Write-Verbose "No OneDrive for $($user.UserPrincipalName): $($_.Exception.Message)"
        }
    }

    # M365 Users tab: most relevant first, least relevant last.
    $row = [ordered]@{
        FirstName         = $user.GivenName
        LastName          = $user.Surname
        UserPrincipalName = $user.UserPrincipalName
        AccountEnabled    = $user.AccountEnabled
        JobTitle          = $user.JobTitle
        Licenses          = $licenseText
        PrimaryEmail      = $primarySmtp
        MailboxType       = $mailboxType
        MailboxSizeGB     = if ($mailboxInfo) { $mailboxInfo.SizeGB } else { $null }
        MailboxItemCount  = if ($mailboxInfo) { $mailboxInfo.ItemCount } else { $null }
        Department        = $user.Department
        Office            = $user.OfficeLocation
        MobilePhone       = $user.MobilePhone
        BusinessPhones    = ($user.BusinessPhones -join '; ')
        UsageLocation     = $user.UsageLocation
        City              = $user.City
        State             = $user.State
        Country           = $user.Country
        Roles             = $roleText
    }
    if ($IncludeOneDrive) {
        $row['OneDriveUsedGB'] = $oneDriveUsedGB
        $row['OneDriveTotalGB'] = $oneDriveTotalGB
    }
    $row['UserType'] = $user.UserType
    $row['CreatedDateTime'] = $user.CreatedDateTime
    $m365Rows.Add([pscustomobject]$row)

    # Summary tab: the at-a-glance basics.
    $summaryRows.Add([pscustomobject][ordered]@{
        FirstName         = $user.GivenName
        LastName          = $user.Surname
        UserPrincipalName = $user.UserPrincipalName
        PrimaryEmail      = $primarySmtp
        MailboxType       = $mailboxType
        AccountEnabled    = $user.AccountEnabled
        Licenses          = $licenseText
        Roles             = $roleText
    })
}
Write-Progress -Activity 'Building user tabs' -Completed

#endregion ---------------------------------------------------------------------

#region Teams & Groups ---------------------------------------------------------

Write-Host 'Retrieving Microsoft 365 Groups, Teams and distribution / security groups...' -ForegroundColor Cyan
$groupProperties = @(
    'id', 'displayName', 'mail', 'mailNickname', 'mailEnabled', 'securityEnabled',
    'groupTypes', 'visibility', 'description', 'createdDateTime',
    'resourceProvisioningOptions', 'proxyAddresses', 'onPremisesSyncEnabled'
)
$groups = Get-MgGroup -All -Property $groupProperties
Write-Host "Found $($groups.Count) group(s)." -ForegroundColor Green

$groupRows = foreach ($group in $groups) {
    $provisioning = @($group.ResourceProvisioningOptions)
    if (-not $provisioning -and $group.AdditionalProperties -and
        $group.AdditionalProperties.ContainsKey('resourceProvisioningOptions')) {
        $provisioning = @($group.AdditionalProperties['resourceProvisioningOptions'])
    }
    $isTeam = $provisioning -contains 'Team'
    $types = @($group.GroupTypes)
    $membershipType = if ($types -contains 'DynamicMembership') { 'Dynamic' } else { 'Assigned' }

    $aliases = ($group.ProxyAddresses | Where-Object { $_ -clike 'smtp:*' } |
        ForEach-Object { $_ -replace '^smtp:', '' }) -join '; '

    [pscustomobject][ordered]@{
        DisplayName     = $group.DisplayName
        GroupKind       = Get-GroupKind -Group $group -IsTeam $isTeam
        IsTeam          = $isTeam
        Mail            = $group.Mail
        MailNickname    = $group.MailNickname
        MembershipType  = $membershipType
        Visibility      = $group.Visibility
        AliasAddresses  = $aliases
        OnPremSynced    = [bool]$group.OnPremisesSyncEnabled
        Description     = $group.Description
        CreatedDateTime = $group.CreatedDateTime
    }
}

#endregion ---------------------------------------------------------------------

#region Write workbook + CSVs --------------------------------------------------

Write-Host 'Writing workbook and per-tab CSVs...' -ForegroundColor Cyan
if (Test-Path -LiteralPath $excelPath) { Remove-Item -LiteralPath $excelPath -Force }

Export-InventoryTab -Data $userMailboxRows   -WorksheetName 'User Mailboxes'   -ExcelPath $excelPath -CsvPath $csvPaths['User Mailboxes']
Export-InventoryTab -Data $sharedMailboxRows -WorksheetName 'Shared Mailboxes' -ExcelPath $excelPath -CsvPath $csvPaths['Shared Mailboxes']
Export-InventoryTab -Data $m365Rows          -WorksheetName 'M365 Users'       -ExcelPath $excelPath -CsvPath $csvPaths['M365 Users']
Export-InventoryTab -Data $summaryRows       -WorksheetName 'Summary'          -ExcelPath $excelPath -CsvPath $csvPaths['Summary']
Export-InventoryTab -Data $groupRows         -WorksheetName 'Teams & Groups'   -ExcelPath $excelPath -CsvPath $csvPaths['Teams & Groups']

Write-Host ''
Write-Host 'Migration inventory complete.' -ForegroundColor Green
Write-Host "  User mailboxes  : $(@($userMailboxRows).Count)" -ForegroundColor Cyan
Write-Host "  Shared mailboxes: $(@($sharedMailboxRows).Count)" -ForegroundColor Cyan
Write-Host "  Users           : $($m365Rows.Count)" -ForegroundColor Cyan
Write-Host "  Groups / Teams  : $(@($groupRows).Count)" -ForegroundColor Cyan
Write-Host ''
Write-Host "Workbook: $excelPath" -ForegroundColor Cyan
Write-Host 'Per-tab CSVs:' -ForegroundColor Cyan
foreach ($name in $csvPaths.Keys) {
    Write-Host ("  {0,-16}: {1}" -f $name, $csvPaths[$name]) -ForegroundColor Cyan
}

#endregion ---------------------------------------------------------------------

# Cleanup.
Disconnect-ExchangeOnline -Confirm:$false | Out-Null
Disconnect-MgGraph | Out-Null
Write-Host 'Done.' -ForegroundColor Green
