#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Exports all active (enabled) Microsoft 365 users with the full data set a
    tenant-to-tenant migration needs, to a single CSV.

.DESCRIPTION
    Connects to Microsoft Graph and Exchange Online (interactive sign-in) and
    builds one row per enabled member user containing:

      - First name, last name, display name
      - UserPrincipalName and primary SMTP / email address
      - Assigned licenses (friendly names where known)
      - Registered / owned devices
      - Mailbox size and item count (Exchange Online, in GB)
      - OneDrive storage used and quota (Graph, in GB)
      - Directory roles held (e.g. Global Administrator)
      - Group memberships, phone numbers, job title, department, office,
        usage location and account metadata

    All storage figures are reported in GB. The script is read-only against the
    tenant - it only queries data and writes a local CSV.

    This is a standalone script: copy it anywhere and run it. It prompts for an
    output location if one is not supplied (see -OutputPath).

.PARAMETER OutputPath
    Directory where the CSV is written. If omitted, the script defaults to
    "<LocalAppData>\Migration-Automations", prints that path, and asks you to
    confirm it or supply a different directory.

.PARAMETER Prefix
    Text prepended to the output file name (e.g. 'Contoso' ->
    'Contoso_M365-ActiveUsers_...'). If omitted, you are asked whether you want
    a custom prefix; if not, you are asked whether this is the Source or
    Destination tenant and that label is used instead.

.PARAMETER IncludeGuests
    Also include guest (external) user accounts. By default only member
    accounts are exported.

.PARAMETER IncludeDisabled
    Also include accounts where sign-in is blocked (accountEnabled = false).
    By default only enabled ("active") accounts are exported.

.PARAMETER SkipMailboxStats
    Skip the per-user Exchange Online mailbox size lookup. Use this for a much
    faster run when mailbox sizing is not needed.

.EXAMPLE
    .\Get-M365ActiveUsers.ps1

    Interactive sign-in, prompts for output location, exports all active users.

.EXAMPLE
    .\Get-M365ActiveUsers.ps1 -OutputPath 'C:\Migrations\Contoso' -IncludeGuests

    Writes the CSV to the given folder without prompting and includes guests.

.NOTES
    Author        : AutomationHub
    Requires      : PowerShell 7, Microsoft.Graph, ExchangeOnlineManagement
    Permissions   : Reader-level Graph scopes + a role that can read mailbox
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
    [switch]$SkipMailboxStats
)

$ErrorActionPreference = 'Stop'

#region Shared helpers ---------------------------------------------------------

function Resolve-MigrationOutputDirectory {
    <#
        Returns a usable output directory. If -Path is supplied it is used as-is.
        Otherwise the user is shown the default (<LocalAppData>\Migration-Automations)
        and asked to accept it or provide another. The directory is created if
        it does not exist.
    #>
    [CmdletBinding()]
    param(
        [string]$Path
    )

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
        Determines the file-name prefix. If -Value is supplied it is sanitised
        and used. Otherwise the user is asked whether to use a custom prefix; if
        not, whether this is the Source or Destination tenant - that label
        becomes the prefix so file names are self-describing.
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

#endregion ---------------------------------------------------------------------

# Common SKU friendly names. Anything not listed falls back to its SkuPartNumber.
$script:SkuFriendlyNames = @{
    'O365_BUSINESS_ESSENTIALS'           = 'Microsoft 365 Business Basic'
    'O365_BUSINESS_PREMIUM'              = 'Microsoft 365 Business Standard'
    'SPB'                                = 'Microsoft 365 Business Premium'
    'SPE_E3'                             = 'Microsoft 365 E3'
    'SPE_E5'                             = 'Microsoft 365 E5'
    'ENTERPRISEPACK'                     = 'Office 365 E3'
    'ENTERPRISEPREMIUM'                  = 'Office 365 E5'
    'STANDARDPACK'                       = 'Office 365 E1'
    'EXCHANGESTANDARD'                   = 'Exchange Online (Plan 1)'
    'EXCHANGEENTERPRISE'                 = 'Exchange Online (Plan 2)'
    'POWER_BI_STANDARD'                  = 'Power BI (free)'
    'POWER_BI_PRO'                       = 'Power BI Pro'
    'FLOW_FREE'                          = 'Power Automate Free'
    'EMS'                                = 'Enterprise Mobility + Security E3'
    'EMSPREMIUM'                         = 'Enterprise Mobility + Security E5'
    'AAD_PREMIUM'                        = 'Entra ID P1'
    'AAD_PREMIUM_P2'                     = 'Entra ID P2'
    'WINDOWS_STORE'                      = 'Windows Store for Business'
    'TEAMS_EXPLORATORY'                  = 'Teams Exploratory'
    'MCOMEETADV'                         = 'Microsoft 365 Audio Conferencing'
    'MCOEV'                              = 'Microsoft Teams Phone Standard'
    'DESKLESSPACK'                       = 'Office 365 F3'
    'SPE_F1'                             = 'Microsoft 365 F3'
}

function Get-FriendlySkuName {
    param([string]$SkuPartNumber)
    if ($script:SkuFriendlyNames.ContainsKey($SkuPartNumber)) {
        return $script:SkuFriendlyNames[$SkuPartNumber]
    }
    return $SkuPartNumber
}

# --- Begin ---------------------------------------------------------------------

Write-Host '=== Microsoft 365 Active User Export ===' -ForegroundColor Cyan

$filePrefix = Resolve-FilePrefix -Value $Prefix
$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = Join-Path -Path $outputDir -ChildPath "${filePrefix}_M365-ActiveUsers_$timestamp.csv"

Initialize-RequiredModule -Name 'Microsoft.Graph.Users'
Initialize-RequiredModule -Name 'Microsoft.Graph.Identity.DirectoryManagement'
Initialize-RequiredModule -Name 'Microsoft.Graph.Files'
Initialize-RequiredModule -Name 'ExchangeOnlineManagement'

# Connect to Microsoft Graph (read-only scopes).
Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
$graphScopes = @(
    'User.Read.All'
    'Directory.Read.All'
    'Group.Read.All'
    'Device.Read.All'
    'Files.Read.All'
    'Organization.Read.All'
    'RoleManagement.Read.Directory'
)
Connect-MgGraph -Scopes $graphScopes -NoWelcome

# Connect to Exchange Online for accurate mailbox sizing.
if (-not $SkipMailboxStats) {
    Write-Host 'Connecting to Exchange Online...' -ForegroundColor Cyan
    Connect-ExchangeOnline -ShowBanner:$false
}

# Build the SKU id -> friendly name map once.
Write-Host 'Loading subscribed SKUs...' -ForegroundColor Cyan
$skuMap = @{}
foreach ($sku in Get-MgSubscribedSku -All) {
    $skuMap[$sku.SkuId] = Get-FriendlySkuName -SkuPartNumber $sku.SkuPartNumber
}

# Build a userId -> [list of directory roles] map once (cheaper than per-user).
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

# Pull users.
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

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($user in $users) {
    $index++
    Write-Progress -Activity 'Building user export' `
        -Status "$index of $($users.Count): $($user.UserPrincipalName)" `
        -PercentComplete (($index / [math]::Max($users.Count, 1)) * 100)

    # Licenses (friendly names).
    $licenses = @()
    foreach ($lic in $user.AssignedLicenses) {
        if ($skuMap.ContainsKey($lic.SkuId)) { $licenses += $skuMap[$lic.SkuId] }
    }

    # Primary SMTP from proxyAddresses (SMTP: in caps = primary), falling back to Mail.
    $primarySmtp = $user.Mail
    $primaryProxy = $user.ProxyAddresses | Where-Object { $_ -clike 'SMTP:*' } | Select-Object -First 1
    if ($primaryProxy) { $primarySmtp = $primaryProxy -replace '^SMTP:', '' }

    # Roles.
    $roles = if ($roleMap.ContainsKey($user.Id)) { $roleMap[$user.Id] -join '; ' } else { '' }

    # Groups (display names only).
    $groups = ''
    try {
        $memberOf = Get-MgUserMemberOf -UserId $user.Id -All -ErrorAction Stop
        $groupNames = $memberOf |
            Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } |
            ForEach-Object { $_.AdditionalProperties['displayName'] }
        $groups = ($groupNames | Sort-Object -Unique) -join '; '
    }
    catch {
        Write-Verbose "Could not read groups for $($user.UserPrincipalName): $($_.Exception.Message)"
    }

    # Devices (registered).
    $devices = ''
    try {
        $userDevices = Get-MgUserRegisteredDevice -UserId $user.Id -All -ErrorAction Stop
        $deviceNames = $userDevices | ForEach-Object { $_.AdditionalProperties['displayName'] }
        $devices = ($deviceNames | Where-Object { $_ } | Sort-Object -Unique) -join '; '
    }
    catch {
        Write-Verbose "Could not read devices for $($user.UserPrincipalName): $($_.Exception.Message)"
    }

    # OneDrive usage (real-time, from the user's default drive quota).
    $oneDriveUsedGB = $null
    $oneDriveTotalGB = $null
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

    # Mailbox size & usage (Exchange Online).
    $mailboxSizeGB = $null
    $mailboxItemCount = $null
    if (-not $SkipMailboxStats) {
        try {
            $stats = Get-EXOMailboxStatistics -Identity $user.UserPrincipalName -ErrorAction Stop
            $mailboxSizeGB = ConvertTo-GBValue -Bytes (Convert-ExchangeSizeToBytes -Size $stats.TotalItemSize)
            $mailboxItemCount = $stats.ItemCount
        }
        catch {
            Write-Verbose "No mailbox for $($user.UserPrincipalName): $($_.Exception.Message)"
        }
    }

    $results.Add([pscustomobject][ordered]@{
        FirstName          = $user.GivenName
        LastName           = $user.Surname
        DisplayName        = $user.DisplayName
        UserPrincipalName  = $user.UserPrincipalName
        PrimaryEmail       = $primarySmtp
        AccountEnabled     = $user.AccountEnabled
        UserType           = $user.UserType
        JobTitle           = $user.JobTitle
        Department         = $user.Department
        Office             = $user.OfficeLocation
        City               = $user.City
        State              = $user.State
        Country            = $user.Country
        UsageLocation      = $user.UsageLocation
        MobilePhone        = $user.MobilePhone
        BusinessPhones     = ($user.BusinessPhones -join '; ')
        Licenses           = ($licenses | Sort-Object -Unique) -join '; '
        Roles              = $roles
        Groups             = $groups
        Devices            = $devices
        MailboxSizeGB      = $mailboxSizeGB
        MailboxItemCount   = $mailboxItemCount
        OneDriveUsedGB     = $oneDriveUsedGB
        OneDriveTotalGB    = $oneDriveTotalGB
        CreatedDateTime    = $user.CreatedDateTime
    })
}

Write-Progress -Activity 'Building user export' -Completed

$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "Exported $($results.Count) user(s) to:" -ForegroundColor Green
Write-Host "  $csvPath" -ForegroundColor Cyan

# Cleanup.
if (-not $SkipMailboxStats) {
    Disconnect-ExchangeOnline -Confirm:$false | Out-Null
}
Disconnect-MgGraph | Out-Null
Write-Host 'Done.' -ForegroundColor Green
