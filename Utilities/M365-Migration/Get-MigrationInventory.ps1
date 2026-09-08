#Requires -Version 7.4

<#
.SYNOPSIS
    Takes one read-only inventory of a Microsoft 365 tenant and writes it as per-tab CSVs
    plus a single Excel workbook.

.DESCRIPTION
    Phase 1 of the AutomationHub tenant-to-tenant migration toolkit. Everything the later
    phases need to plan a cutover is pulled here, once, and written to files: the planner
    (New-MigrationIdentityPlan) reads these CSVs and never touches the source tenant again.
    That separation is deliberate - the source tenant is often a client's production estate
    with a change freeze, and a plan you can re-run offline is worth more than a plan you
    have to re-authenticate for.

    Nine tabs are produced, each as its own CSV and as a worksheet in one workbook:

      Users               one row per Entra user, with licences, manager, roles and
                          (optionally) MFA registration and OneDrive usage
      UserMailboxes       Exchange Online UserMailbox rows, including LegacyExchangeDN and
                          X500 addresses, holds, forwarding and quotas
      SharedMailboxes     the same columns for Shared, Room, Equipment and Scheduling
      MailboxPermissions  FullAccess, SendAs, SendOnBehalf and explicit Calendar delegates
      Groups              distribution lists, mail-enabled security groups, dynamic DLs,
                          Microsoft 365 groups, Teams and security groups, with members
      Contacts            mail contacts
      Domains             accepted domains and their verification state
      Licenses            subscribed SKUs with seat counts
      Summary             tenant facts and per-tab counts

    Performance is a first-class concern because the tenants this runs against routinely
    hold a couple of thousand mailboxes. Users come from a single paged Graph call with
    $select and $expand=manager rather than a call per user; mailboxes come from
    Get-EXOMailbox with property sets rather than the slower Get-Mailbox; permissions use
    the REST-based Get-EXOMailboxPermission / Get-EXORecipientPermission cmdlets, which
    Microsoft recommends over the remote-PowerShell equivalents that fail with a 500MB
    session limit on large orgs. The two genuinely per-object passes - mailbox statistics
    and mailbox permissions - each have a switch to turn them off.

    The script is read-only against the tenant. -DryRun still connects and counts every
    object so the run is a true rehearsal, but writes nothing except the log.

.PARAMETER OutputPath
    Overrides the default output root (%LOCALAPPDATA%\Migration-Automations on Windows,
    ~/Migration-Automations elsewhere).

.PARAMETER Prefix
    Names the client or run. Output lands in <root>\<Prefix>\ and filenames start with
    '<Prefix>_'. Use 'Source' and 'Destination' when inventorying both ends of a migration.

.PARAMETER LogPath
    Overrides the derived log file path.

.PARAMETER TenantId
    The Entra tenant to sign in to for Microsoft Graph. Recommended when the technician
    has access to several tenants.

.PARAMETER DelegatedOrganization
    The customer tenant domain for delegated (GDAP) Exchange Online access, for example
    'contoso.onmicrosoft.com'. Omit when signing in to your own tenant.

.PARAMETER DomainFilter
    One or more domains. Only objects whose UPN or primary SMTP address is on one of them
    are inventoried. Accepts 'contoso.com' or '@contoso.com'.

.PARAMETER IncludeGuests
    Also inventory guest (#EXT#) accounts. Members only by default.

.PARAMETER IncludeDisabled
    Also inventory accounts where sign-in is blocked. Enabled accounts only by default.

.PARAMETER IncludeOneDrive
    Adds OneDriveUrl and OneDriveUsedGB to the Users tab. This is one Graph call per user,
    so it is opt-in.

.PARAMETER IncludeAuthMethods
    Adds MfaRegistered and MfaMethods to the Users tab from the authentication methods
    registration report. Needs AuditLog.Read.All.

.PARAMETER SkipMailboxPermissions
    Turns off the MailboxPermissions tab. Permissions cost three Exchange calls per
    mailbox and are by far the slowest part of a large inventory.

.PARAMETER SkipMailboxStats
    Skips Get-EXOMailboxStatistics. Size, item count, archive size and last logon are left
    blank, and the run is dramatically faster.

.PARAMETER SkipExcel
    Writes the CSVs only. Use this when ImportExcel cannot be installed on the machine.

.PARAMETER DryRun
    Connects, collects and counts everything, logs the files it would have written, and
    writes nothing but the log.

.PARAMETER Verbosity
    Console output level: Low, Medium (default) or High. The log file always gets
    everything.

.EXAMPLE
    .\Get-MigrationInventory.ps1 -Prefix Source

    Signs in interactively, inventories the whole tenant and writes Source_*.csv plus
    Source_Migration-Inventory_<timestamp>.xlsx.

.EXAMPLE
    .\Get-MigrationInventory.ps1 -Prefix Source -DomainFilter 'contoso.com', 'fabrikam.com' -IncludeAuthMethods

    Inventories only the two named domains and adds MFA registration to the Users tab.

.EXAMPLE
    .\Get-MigrationInventory.ps1 -Prefix Destination -TenantId 'newco.onmicrosoft.com' `
        -DelegatedOrganization 'newco.onmicrosoft.com'

    Inventories a customer tenant through GDAP so the planner can use it as the reserved
    address list for the destination.

.EXAMPLE
    .\Get-MigrationInventory.ps1 -Prefix Source -SkipMailboxStats -SkipMailboxPermissions -DryRun

    Rehearses the fastest possible run and prints the file list without writing anything.

.NOTES
    Author      : AutomationHub
    Written with assistance from Claude (Anthropic).

    Graph scopes (delegated):
      User.Read.All, Group.Read.All, Directory.Read.All, Organization.Read.All,
      RoleManagement.Read.Directory
      + Files.Read.All             with -IncludeOneDrive
      + AuditLog.Read.All          with -IncludeAuthMethods (and for the LastSignIn column;
        the column is left blank and a warning logged when the scope or licence is absent)
      + UserAuthenticationMethod.Read.All with -IncludeAuthMethods

    Exchange Online roles: View-Only Recipients plus View-Only Configuration - the Global
    Reader or Exchange Recipient Administrator roles both cover it. Mailbox statistics
    additionally need View-Only Recipients on the mailbox in question.

    GDAP: supported. -DelegatedOrganization drives Exchange Online and -TenantId drives
    Graph; both are delegated/interactive sign-ins. App-only certificate authentication
    cannot be combined with -DelegatedOrganization.

    Exit codes: 0 success, 1 fatal error, 2 completed with per-object failures.
#>

[CmdletBinding()]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$OutputPath,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$Prefix,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$LogPath,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$TenantId,

    [Alias('Tenant')]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$DelegatedOrganization,

    [ValidatePattern('^@?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$')]
    [string[]]$DomainFilter,

    [switch]$IncludeGuests,

    [switch]$IncludeDisabled,

    [switch]$IncludeOneDrive,

    [switch]$IncludeAuthMethods,

    [switch]$SkipMailboxPermissions,

    [switch]$SkipMailboxStats,

    [switch]$SkipExcel,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Configuration ----------------------------------------------------------------------------

# Scopes are declared up front so Connect-MigrationGraph can fail fast on a shortfall rather
# than letting a missing consent surface as a 403 halfway through the users pass.
$requiredGraphScopes = @(
    'User.Read.All'
    'Group.Read.All'
    'Directory.Read.All'
    'Organization.Read.All'
    'RoleManagement.Read.Directory'
)
if ($IncludeOneDrive) { $requiredGraphScopes += 'Files.Read.All' }
if ($IncludeAuthMethods) { $requiredGraphScopes += @('AuditLog.Read.All', 'UserAuthenticationMethod.Read.All') }

# Tab order is also the worksheet order in the workbook and the order the CSVs are logged in.
$inventoryTabs = @(
    'Users'
    'UserMailboxes'
    'SharedMailboxes'
    'MailboxPermissions'
    'Groups'
    'Contacts'
    'Domains'
    'Licenses'
    'Summary'
)

# Property sets keep Get-EXOMailbox to one round trip while still returning the hold,
# forwarding, policy and quota fields the plan needs. Anything not covered by a set is
# named explicitly; if the combination is ever rejected the collector falls back to -PropertySets All.
$mailboxPropertySets = @('Minimum', 'Delivery', 'Archive', 'Hold', 'Policy', 'Quota', 'Retention', 'AddressList')
$mailboxProperties = @('LegacyExchangeDN', 'WhenCreated', 'ExchangeGuid', 'ExternalDirectoryObjectId')
$mailboxRecipientTypes = @('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox', 'SchedulingMailbox')

# Trustees that are noise in every tenant: the mailbox's own SELF ACE and orphaned SIDs.
$permissionTrusteeExclusions = '^(NT AUTHORITY\\SELF|S-1-5-)'

# Calendar folder permissions are only interesting for named delegates.
$calendarBuiltInTrustees = @('Default', 'Anonymous')

$script:RecipientIndex = @{}
$script:RowFailureCount = 0

#endregion ---------------------------------------------------------------------------------------

#region Functions --------------------------------------------------------------------------------

function Get-InventoryValue {
    <#
    .SYNOPSIS
        Reads a property that may not exist on the object, returning a default instead of throwing.

    .DESCRIPTION
        Exchange Online returns different property bags depending on which property sets were
        requested, and Graph omits properties that were not $select-ed. Under
        Set-StrictMode -Version Latest a plain $object.Missing is a terminating error, so every
        read of a tenant object goes through here. Empty strings collapse to the default too,
        which is what keeps blank cells out of the CSVs as literal ' '.

    .PARAMETER InputObject
        The object to read from.

    .PARAMETER Name
        The property name.

    .PARAMETER Default
        Returned when the property is absent, null or an empty string.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [AllowNull()]
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) { return $Default }

    $value = $property.Value
    if ($null -eq $value) { return $Default }
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { return $Default }

    return $value
}

function ConvertTo-InventoryByteCount {
    <#
    .SYNOPSIS
        Parses an Exchange ByteQuantifiedSize into a byte count.

    .DESCRIPTION
        Exchange sizes render as '1.5 GB (1,610,612,736 bytes)'. The parenthesised byte count is
        the exact figure and the one worth keeping - the leading value is rounded and locale
        dependent. When the string does not carry a byte count the object's own ToBytes() is
        tried before giving up.

    .PARAMETER Size
        The size value from Exchange, as an object or a string.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[System.Int64]])]
    param(
        [AllowNull()]
        $Size
    )

    if ($null -eq $Size) { return $null }

    $text = [string]$Size
    if ($text -match '\(([\d.,\s]+)\s*bytes\)') {
        $digits = $Matches[1] -replace '[^\d]', ''
        if ($digits) { return [int64]$digits }
    }

    if ($Size -isnot [string] -and $Size.PSObject.Methods['ToBytes']) {
        try { return [int64]$Size.ToBytes() } catch { return $null }
    }

    if ($text -match '^\d+$') { return [int64]$text }

    return $null
}

function ConvertTo-InventoryGigabyte {
    <#
    .SYNOPSIS
        Converts an Exchange size or raw byte count to GB, rounded to two decimals.

    .PARAMETER Size
        A byte count, or an Exchange ByteQuantifiedSize value.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[System.Double]])]
    param(
        [AllowNull()]
        $Size
    )

    $bytes = ConvertTo-InventoryByteCount -Size $Size
    if ($null -eq $bytes) { return $null }

    return [math]::Round(($bytes / 1GB), 2)
}

function ConvertTo-InventoryDomainList {
    <#
    .SYNOPSIS
        Normalises the -DomainFilter values to bare lower-case domains.

    .PARAMETER Domain
        The raw filter values, with or without a leading '@'.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Domain
    )

    if (-not $Domain) { return @() }

    return @($Domain |
        ForEach-Object { $_.TrimStart('@').Trim().ToLowerInvariant() } |
        Where-Object { $_ } |
        Sort-Object -Unique)
}

function Test-InventoryDomainMatch {
    <#
    .SYNOPSIS
        True when any of the supplied addresses is on one of the filtered domains.

    .DESCRIPTION
        An empty filter matches everything, which is what makes the caller's code a plain
        Where-Object with no special case for 'no filter supplied'. A guest whose UPN is
        alice_fabrikam.com#EXT#@contoso.onmicrosoft.com matches on its mail address rather than
        its UPN, so both are passed in and any one hit is enough.

    .PARAMETER Address
        The addresses to test - typically UPN and primary SMTP.

    .PARAMETER Domain
        The normalised domain list from ConvertTo-InventoryDomainList.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Address,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Domain
    )

    if (-not $Domain -or $Domain.Count -eq 0) { return $true }
    if (-not $Address) { return $false }

    foreach ($candidate in $Address) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($candidate -notmatch '@') { continue }
        $suffix = ($candidate -split '@')[-1].Trim().ToLowerInvariant()
        if ($Domain -contains $suffix) { return $true }
    }

    return $false
}

function Select-InventoryAddress {
    <#
    .SYNOPSIS
        Splits an Exchange EmailAddresses collection into its typed parts.

    .DESCRIPTION
        Returns the entries verbatim plus the pieces the plan needs separately: the primary
        SMTP address (the entry prefixed with an upper-case 'SMTP:'), the secondary smtp
        aliases, and the X500 addresses. X500 entries keep their 'X500:' prefix because that is
        the form Set-Mailbox -EmailAddresses expects when they are re-added in the destination.

    .PARAMETER EmailAddress
        The EmailAddresses / proxyAddresses collection.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$EmailAddress
    )

    $all = @()
    if ($EmailAddress) { $all = @($EmailAddress | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }

    $primary = ''
    $aliases = [System.Collections.Generic.List[string]]::new()
    $x500 = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $all) {
        $value = $entry.Trim()
        if ($value -cmatch '^SMTP:') {
            if (-not $primary) { $primary = $value.Substring(5) }
        }
        elseif ($value -cmatch '^smtp:') {
            $aliases.Add($value.Substring(5))
        }
        elseif ($value -match '^X500:') {
            $x500.Add('X500:' + $value.Substring(5))
        }
    }

    return [pscustomobject]@{
        All          = $all
        PrimarySmtp  = $primary
        SmtpAliases  = $aliases.ToArray()
        X500Addresses = $x500.ToArray()
    }
}

function Add-InventoryRecipientIndexEntry {
    <#
    .SYNOPSIS
        Registers a recipient under every key Exchange might refer to it by.

    .DESCRIPTION
        Exchange returns delegate and moderator lists as whatever identity string the directory
        happened to store - a display name, an alias, a canonical name or a GUID. Resolving those
        to a primary SMTP address makes the Groups and Mailboxes tabs joinable against the Users
        tab, which is the whole point of the inventory. The index is built from objects already
        in memory, so resolution costs no extra calls.

    .PARAMETER Key
        The identity strings to register.

    .PARAMETER PrimarySmtpAddress
        The address those identities resolve to.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Key,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$PrimarySmtpAddress
    )

    if ([string]::IsNullOrWhiteSpace($PrimarySmtpAddress)) { return }
    if (-not $Key) { return }

    foreach ($entry in $Key) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $normalised = $entry.Trim().ToLowerInvariant()
        if (-not $script:RecipientIndex.ContainsKey($normalised)) {
            $script:RecipientIndex[$normalised] = $PrimarySmtpAddress
        }
    }
}

function Resolve-InventoryRecipient {
    <#
    .SYNOPSIS
        Turns an Exchange identity string into a primary SMTP address where one is known.

    .DESCRIPTION
        Falls back to the identity's last path segment (canonical names arrive as
        'contoso.com/Users/Jane Doe') and finally to the value verbatim. An unresolved value is
        still worth writing out: an operator can act on 'Jane Doe' where they can do nothing
        with a blank cell.

    .PARAMETER Identity
        The identity string, or an object that stringifies to one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Identity
    )

    if ($null -eq $Identity) { return '' }

    $text = ([string]$Identity).Trim()
    if (-not $text) { return '' }

    $key = $text.ToLowerInvariant()
    if ($script:RecipientIndex.ContainsKey($key)) { return $script:RecipientIndex[$key] }

    $leaf = ($text -split '/')[-1].Trim()
    if ($leaf) {
        $leafKey = $leaf.ToLowerInvariant()
        if ($script:RecipientIndex.ContainsKey($leafKey)) { return $script:RecipientIndex[$leafKey] }
    }

    return $text
}

function Join-InventoryRecipientList {
    <#
    .SYNOPSIS
        Resolves a multi-valued Exchange recipient property to a ';'-joined address list.

    .PARAMETER Value
        The raw multi-valued property.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return '' }

    $resolved = @(@($Value) | ForEach-Object { Resolve-InventoryRecipient -Identity $_ })
    return (Join-MigrationList -Values $resolved)
}

function ConvertTo-InventoryMailboxRow {
    <#
    .SYNOPSIS
        Shapes one Exchange mailbox into the UserMailboxes / SharedMailboxes CSV row.

    .DESCRIPTION
        The column names here are a published interface: New-MigrationIdentityPlan reads this
        CSV by column name, so renaming one breaks the planner rather than just the spreadsheet.
        Statistics are optional because -SkipMailboxStats leaves them out, and every read goes
        through Get-InventoryValue so a narrower property set only blanks cells instead
        of failing the run.

    .PARAMETER Mailbox
        The mailbox object from Get-EXOMailbox.

    .PARAMETER Statistics
        The primary mailbox statistics, or $null.

    .PARAMETER ArchiveStatistics
        The archive mailbox statistics, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Mailbox,

        [AllowNull()]
        $Statistics,

        [AllowNull()]
        $ArchiveStatistics
    )

    $addresses = Select-InventoryAddress -EmailAddress (@(Get-InventoryValue $Mailbox 'EmailAddresses' @()))
    $primary = Get-InventoryValue $Mailbox 'PrimarySmtpAddress' $addresses.PrimarySmtp

    $inPlaceHolds = @(Get-InventoryValue $Mailbox 'InPlaceHolds' @())

    return [pscustomobject][ordered]@{
        UserPrincipalName             = [string](Get-InventoryValue $Mailbox 'UserPrincipalName' '')
        DisplayName                   = [string](Get-InventoryValue $Mailbox 'DisplayName' '')
        PrimarySmtpAddress            = [string]$primary
        Alias                         = [string](Get-InventoryValue $Mailbox 'Alias' '')
        RecipientTypeDetails          = [string](Get-InventoryValue $Mailbox 'RecipientTypeDetails' '')
        EmailAddresses                = Join-MigrationList -Values $addresses.All
        LegacyExchangeDN              = [string](Get-InventoryValue $Mailbox 'LegacyExchangeDN' '')
        X500Addresses                 = Join-MigrationList -Values $addresses.X500Addresses
        ArchiveStatus                 = [string](Get-InventoryValue $Mailbox 'ArchiveStatus' '')
        LitigationHoldEnabled         = [bool](Get-InventoryValue $Mailbox 'LitigationHoldEnabled' $false)
        InPlaceHolds                  = $inPlaceHolds.Count
        RetentionPolicy               = [string](Get-InventoryValue $Mailbox 'RetentionPolicy' '')
        HiddenFromAddressListsEnabled = [bool](Get-InventoryValue $Mailbox 'HiddenFromAddressListsEnabled' $false)
        ForwardingAddress             = Resolve-InventoryRecipient -Identity (Get-InventoryValue $Mailbox 'ForwardingAddress' '')
        ForwardingSmtpAddress         = [string](Get-InventoryValue $Mailbox 'ForwardingSmtpAddress' '')
        DeliverToMailboxAndForward    = [bool](Get-InventoryValue $Mailbox 'DeliverToMailboxAndForward' $false)
        EmailAddressPolicyEnabled     = [bool](Get-InventoryValue $Mailbox 'EmailAddressPolicyEnabled' $false)
        TotalItemSizeGB               = ConvertTo-InventoryGigabyte -Size (Get-InventoryValue $Statistics 'TotalItemSize')
        ItemCount                     = Get-InventoryValue $Statistics 'ItemCount'
        ArchiveSizeGB                 = ConvertTo-InventoryGigabyte -Size (Get-InventoryValue $ArchiveStatistics 'TotalItemSize')
        LastLogonTime                 = Get-InventoryValue $Statistics 'LastLogonTime'
        ProhibitSendReceiveQuota      = [string](Get-InventoryValue $Mailbox 'ProhibitSendReceiveQuota' '')
        GrantSendOnBehalfTo           = Join-InventoryRecipientList -Value (Get-InventoryValue $Mailbox 'GrantSendOnBehalfTo')
    }
}

function ConvertTo-InventoryUserRow {
    <#
    .SYNOPSIS
        Shapes one Graph user into the Users CSV row.

    .DESCRIPTION
        The optional columns are added only when their switch was supplied, so a run without
        -IncludeOneDrive produces a CSV with no OneDrive columns at all rather than a column of
        blanks - Import-MigrationCsv treats a missing optional column and an empty one the same
        way, and the narrower file is easier to read.

    .PARAMETER User
        The Graph user object.

    .PARAMETER SkuNameById
        SKU id to part number map, used for the Licenses column.

    .PARAMETER DirectoryRole
        The role display names this user holds.

    .PARAMETER Registration
        The user's userRegistrationDetails record, or $null.

    .PARAMETER Drive
        The user's OneDrive object, or $null.

    .PARAMETER IncludeAuthMethodColumn
        Adds MfaRegistered and MfaMethods.

    .PARAMETER IncludeOneDriveColumn
        Adds OneDriveUrl and OneDriveUsedGB.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $User,

        [AllowNull()]
        [hashtable]$SkuNameById,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DirectoryRole,

        [AllowNull()]
        $Registration,

        [AllowNull()]
        $Drive,

        [switch]$IncludeAuthMethodColumn,

        [switch]$IncludeOneDriveColumn
    )

    $proxyAddresses = @(Get-InventoryValue $User 'proxyAddresses' @())
    $addresses = Select-InventoryAddress -EmailAddress $proxyAddresses

    $assigned = @(Get-InventoryValue $User 'assignedLicenses' @())
    $skuIds = @($assigned | ForEach-Object { [string](Get-InventoryValue $_ 'skuId' '') } |
        Where-Object { $_ })
    $skuNames = @($skuIds | ForEach-Object {
        if ($SkuNameById -and $SkuNameById.ContainsKey($_)) { $SkuNameById[$_] } else { $_ }
    } | Sort-Object -Unique)

    $assignmentStates = @(Get-InventoryValue $User 'licenseAssignmentStates' @())
    $byGroup = [bool]@($assignmentStates |
        Where-Object { (Get-InventoryValue $_ 'assignedByGroup') }).Count

    $manager = Get-InventoryValue $User 'manager'
    $signIn = Get-InventoryValue $User 'signInActivity'

    $row = [ordered]@{
        ObjectId               = [string](Get-InventoryValue $User 'id' '')
        UserPrincipalName      = [string](Get-InventoryValue $User 'userPrincipalName' '')
        DisplayName            = [string](Get-InventoryValue $User 'displayName' '')
        FirstName              = [string](Get-InventoryValue $User 'givenName' '')
        MiddleName             = [string](Get-InventoryValue $User 'middleName' '')
        LastName               = [string](Get-InventoryValue $User 'surname' '')
        Mail                   = [string](Get-InventoryValue $User 'mail' $addresses.PrimarySmtp)
        JobTitle               = [string](Get-InventoryValue $User 'jobTitle' '')
        Department             = [string](Get-InventoryValue $User 'department' '')
        Office                 = [string](Get-InventoryValue $User 'officeLocation' '')
        MobilePhone            = [string](Get-InventoryValue $User 'mobilePhone' '')
        UsageLocation          = [string](Get-InventoryValue $User 'usageLocation' '')
        AccountEnabled         = [bool](Get-InventoryValue $User 'accountEnabled' $false)
        UserType               = [string](Get-InventoryValue $User 'userType' '')
        IsSynced               = [bool](Get-InventoryValue $User 'onPremisesSyncEnabled' $false)
        ImmutableId            = [string](Get-InventoryValue $User 'onPremisesImmutableId' '')
        ManagerUpn             = [string](Get-InventoryValue $manager 'userPrincipalName' '')
        Licenses               = Join-MigrationList -Values $skuNames
        LicenseSkuIds          = Join-MigrationList -Values $skuIds
        LicenseAssignedByGroup = $byGroup
        ProxyAddresses         = Join-MigrationList -Values $addresses.All
        LastSignIn             = [string](Get-InventoryValue $signIn 'lastSignInDateTime' '')
        CreatedDateTime        = [string](Get-InventoryValue $User 'createdDateTime' '')
    }

    if ($IncludeAuthMethodColumn) {
        $methods = @(Get-InventoryValue $Registration 'methodsRegistered' @())
        $row['MfaRegistered'] = [bool](Get-InventoryValue $Registration 'isMfaRegistered' $false)
        $row['MfaMethods'] = Join-MigrationList -Values @($methods | ForEach-Object { [string]$_ })
    }

    if ($IncludeOneDriveColumn) {
        $quota = Get-InventoryValue $Drive 'quota'
        $row['OneDriveUrl'] = [string](Get-InventoryValue $Drive 'webUrl' '')
        $row['OneDriveUsedGB'] = ConvertTo-InventoryGigabyte -Size (Get-InventoryValue $quota 'used')
    }

    $row['DirectoryRoles'] = Join-MigrationList -Values @($DirectoryRole | Sort-Object -Unique)

    return [pscustomobject]$row
}

function Get-InventoryGroupType {
    <#
    .SYNOPSIS
        Classifies a group into the plan's GroupType vocabulary.

    .DESCRIPTION
        The planner branches on this string: Distribution and MailEnabledSecurity groups are
        recreated by New-MigrationGroups, DynamicDistribution groups carry a RecipientFilter to
        port, and M365Group / Team / SecurityGroup rows are informational because AvePoint Fly
        migrates them. Exchange recipient type details win when present because they distinguish
        a mail-enabled security group from a plain distribution list, which Graph's group types
        alone do not.

    .PARAMETER RecipientTypeDetails
        The Exchange RecipientTypeDetails value, when the group came from Exchange.

    .PARAMETER GroupType
        The Graph groupTypes collection.

    .PARAMETER MailEnabled
        The Graph mailEnabled flag.

    .PARAMETER SecurityEnabled
        The Graph securityEnabled flag.

    .PARAMETER IsTeam
        True when resourceProvisioningOptions contains 'Team'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RecipientTypeDetails,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$GroupType,

        [bool]$MailEnabled,

        [bool]$SecurityEnabled,

        [bool]$IsTeam
    )

    switch -Regex ($RecipientTypeDetails) {
        '^MailUniversalSecurityGroup$' { return 'MailEnabledSecurity' }
        '^MailUniversalDistributionGroup$' { return 'Distribution' }
        '^DynamicDistributionGroup$' { return 'DynamicDistribution' }
        '^GroupMailbox$' { return $(if ($IsTeam) { 'Team' } else { 'M365Group' }) }
        '^RoomList$' { return 'Distribution' }
    }

    $types = @($GroupType)
    if ($types -contains 'Unified') {
        if ($IsTeam) { return 'Team' }
        return 'M365Group'
    }
    if ($MailEnabled -and $SecurityEnabled) { return 'MailEnabledSecurity' }
    if ($MailEnabled) { return 'Distribution' }
    if ($SecurityEnabled) { return 'SecurityGroup' }

    return 'SecurityGroup'
}

function ConvertTo-InventoryContactRow {
    <#
    .SYNOPSIS
        Shapes one mail contact into the Contacts CSV row.

    .DESCRIPTION
        Get-MailContact carries the addressing and Get-Contact carries the name parts, so both
        are joined here rather than paying for a per-contact lookup.

    .PARAMETER MailContact
        The Get-MailContact object.

    .PARAMETER Contact
        The matching Get-Contact object, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $MailContact,

        [AllowNull()]
        $Contact
    )

    $addresses = Select-InventoryAddress -EmailAddress (@(Get-InventoryValue $MailContact 'EmailAddresses' @()))

    return [pscustomobject][ordered]@{
        DisplayName                   = [string](Get-InventoryValue $MailContact 'DisplayName' '')
        ExternalEmailAddress          = ([string](Get-InventoryValue $MailContact 'ExternalEmailAddress' '')) -replace '^(?i)smtp:', ''
        PrimarySmtpAddress            = [string](Get-InventoryValue $MailContact 'PrimarySmtpAddress' $addresses.PrimarySmtp)
        Alias                         = [string](Get-InventoryValue $MailContact 'Alias' '')
        FirstName                     = [string](Get-InventoryValue $Contact 'FirstName' '')
        LastName                      = [string](Get-InventoryValue $Contact 'LastName' '')
        HiddenFromAddressListsEnabled = [bool](Get-InventoryValue $MailContact 'HiddenFromAddressListsEnabled' $false)
        EmailAddresses                = Join-MigrationList -Values $addresses.All
    }
}

function ConvertTo-InventoryPermissionRow {
    <#
    .SYNOPSIS
        Shapes one delegation into the MailboxPermissions CSV row.

    .PARAMETER MailboxPrimarySmtp
        The mailbox the permission is on.

    .PARAMETER MailboxType
        Its RecipientTypeDetails.

    .PARAMETER Trustee
        The delegate.

    .PARAMETER Permission
        FullAccess, SendAs, SendOnBehalf or 'Calendar:<rights>'.

    .PARAMETER AutoMapping
        Left blank where Exchange does not expose it, which is everywhere except an explicit
        Add-MailboxPermission call - Get-MailboxPermission has never returned it.

    .PARAMETER IsInherited
        Whether the ACE is inherited.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string]$MailboxPrimarySmtp,

        [AllowEmptyString()]
        [string]$MailboxType,

        [AllowEmptyString()]
        [string]$Trustee,

        [AllowEmptyString()]
        [string]$Permission,

        [AllowEmptyString()]
        [string]$AutoMapping = '',

        [bool]$IsInherited
    )

    $resolved = Resolve-InventoryRecipient -Identity $Trustee
    $trusteeType = if ($script:RecipientIndex.ContainsKey($resolved.ToLowerInvariant())) { 'Recipient' }
        elseif ($resolved -match '@') { 'Recipient' }
        else { 'Unresolved' }

    return [pscustomobject][ordered]@{
        MailboxPrimarySmtp = $MailboxPrimarySmtp
        MailboxType        = $MailboxType
        Trustee            = $resolved
        TrusteeType        = $trusteeType
        Permission         = $Permission
        AutoMapping        = $AutoMapping
        IsInherited        = $IsInherited
    }
}

function Test-InventoryTrustee {
    <#
    .SYNOPSIS
        False for the trustees every mailbox has and nobody needs to migrate.

    .PARAMETER Trustee
        The trustee string from Exchange.

    .PARAMETER Pattern
        The exclusion regex.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Trustee,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Trustee)) { return $false }
    return ($Trustee -notmatch $Pattern)
}

function Write-InventoryProgress {
    <#
    .SYNOPSIS
        Reports progress for one tab.

    .PARAMETER Tab
        The tab being built.

    .PARAMETER Status
        The current item.

    .PARAMETER Current
        Items processed so far.

    .PARAMETER Total
        Items in total.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Tab,

        [AllowEmptyString()]
        [string]$Status = '',

        [int]$Current = 0,

        [int]$Total = 0
    )

    $percent = 0
    if ($Total -gt 0) { $percent = [math]::Min(100, [int](($Current / $Total) * 100)) }

    Write-Progress -Activity "Inventory: $Tab" -Status "$Current of $Total $Status" -PercentComplete $percent
}

function Export-InventoryTab {
    <#
    .SYNOPSIS
        Writes one tab to CSV and, when enabled, to a worksheet in the shared workbook.

    .DESCRIPTION
        An empty tab still produces a file with a single informational row so that the workbook
        keeps a predictable shape and a downstream Import-Csv does not fall over on a zero-byte
        file. The write goes through Invoke-MigrationAction, which is what makes -DryRun log the
        planned file list and write nothing.

    .PARAMETER Row
        The rows to write.

    .PARAMETER Name
        The tab name; also the worksheet name.

    .PARAMETER CsvPath
        The CSV destination.

    .PARAMETER ExcelPath
        The workbook destination.

    .PARAMETER IncludeExcel
        Adds the worksheet. Off when -SkipExcel was given or ImportExcel is unavailable.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'ExcelPath and IncludeExcel are consumed inside the Invoke-MigrationAction scriptblock, which the analyzer does not follow. The scriptblock is what makes the write DryRun-aware.')]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Row,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExcelPath,

        [switch]$IncludeExcel
    )

    $data = @($Row)
    $count = $data.Count
    if ($count -eq 0) {
        $data = @([pscustomobject]@{ Info = "No $Name records found." })
    }

    Invoke-MigrationAction -Description "Write the $Name tab ($count row(s)) to $CsvPath" -Action {
        $data | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
        if ($IncludeExcel -and -not [string]::IsNullOrWhiteSpace($ExcelPath)) {
            $data | Export-Excel -Path $ExcelPath -WorksheetName $Name -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter
        }
    }
}

function Get-InventoryGraphUser {
    <#
    .SYNOPSIS
        Reads every user in one paged Graph call.

    .DESCRIPTION
        One request with $select and $expand=manager replaces the call-per-user pattern that
        makes a 2,000-seat inventory take an hour. Two properties are known to be fragile:
        signInActivity needs AuditLog.Read.All and an Entra ID P1 context, and $expand=manager
        is occasionally refused alongside it. Rather than making the operator guess which
        permission they are missing, the call degrades in two documented steps and says in the
        log which columns went blank.

    .PARAMETER IncludeDisabledUser
        Drops the accountEnabled filter.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [switch]$IncludeDisabledUser
    )

    $select = @(
        'id', 'userPrincipalName', 'displayName', 'givenName', 'surname', 'mail', 'jobTitle',
        'department', 'officeLocation', 'mobilePhone', 'usageLocation', 'accountEnabled',
        'userType', 'onPremisesSyncEnabled', 'onPremisesImmutableId', 'assignedLicenses',
        'licenseAssignmentStates', 'proxyAddresses', 'createdDateTime'
    )

    $filter = if ($IncludeDisabledUser) { '' } else { '&$filter=accountEnabled eq true' }

    $expand = "&`$expand=manager(`$select=userPrincipalName)"
    $withActivity = ($select + 'signInActivity') -join ','
    $withoutActivity = $select -join ','

    $attempts = @(
        @{
            Uri     = "/v1.0/users?`$select=$withActivity$expand&`$top=999$filter"
            Message = ''
        }
        @{
            Uri     = "/v1.0/users?`$select=$withoutActivity$expand&`$top=999$filter"
            Message = 'signInActivity was refused - LastSignIn will be blank. It needs ' +
                      'AuditLog.Read.All and an Entra ID P1 licence.'
        }
        @{
            Uri     = "/v1.0/users?`$select=$withoutActivity&`$top=999$filter"
            Message = 'The manager expansion was refused - the ManagerUpn column will be blank.'
        }
    )

    $lastError = $null
    foreach ($attempt in $attempts) {
        try {
            $users = @(Invoke-MigrationGraphRequest -Method GET -Uri $attempt.Uri -All)
            if ($attempt.Message) { Write-MigrationLog -Message $attempt.Message -Level WARNING }
            return $users
        }
        catch {
            $lastError = $_
            Write-MigrationLog -Message "Graph user query failed: $($_.Exception.Message)" -Level DEBUG
        }
    }

    throw "Could not read users from Microsoft Graph: $($lastError.Exception.Message)"
}

function Get-InventoryDirectoryRoleMap {
    <#
    .SYNOPSIS
        Maps user object id to the directory roles they hold.

    .DESCRIPTION
        One call per activated role beats one call per user by two orders of magnitude, and the
        result answers the question the migration actually asks: which accounts will need their
        privileged roles re-created in the destination before the source is decommissioned.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $map = @{}
    $roles = @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/directoryRoles' -All)

    $index = 0
    foreach ($role in $roles) {
        $index++
        $roleName = [string](Get-InventoryValue $role 'displayName' '')
        $roleId = [string](Get-InventoryValue $role 'id' '')
        if (-not $roleId) { continue }

        Write-InventoryProgress -Tab 'Directory roles' -Status $roleName -Current $index -Total $roles.Count

        try {
            $members = @(Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/directoryRoles/$roleId/members?`$select=id" -All)
        }
        catch {
            Write-MigrationLog -Message "Could not read members of role '$roleName': $($_.Exception.Message)" -Level WARNING
            $script:RowFailureCount++
            continue
        }

        foreach ($member in $members) {
            $memberId = [string](Get-InventoryValue $member 'id' '')
            if (-not $memberId) { continue }
            if (-not $map.ContainsKey($memberId)) {
                $map[$memberId] = [System.Collections.Generic.List[string]]::new()
            }
            $map[$memberId].Add($roleName)
        }
    }
    Write-Progress -Activity 'Inventory: Directory roles' -Completed

    return $map
}

function Get-InventoryAuthMethodMap {
    <#
    .SYNOPSIS
        Maps user object id to their MFA registration record.

    .DESCRIPTION
        The userRegistrationDetails report is a single paged read of the whole tenant, so it
        costs one call regardless of user count. It needs AuditLog.Read.All rather than
        UserAuthenticationMethod.Read.All, which is the permission most operators reach for
        first - both are requested so either configuration works.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $map = @{}
    $uri = '/v1.0/reports/authenticationMethods/userRegistrationDetails'

    try {
        $records = @(Invoke-MigrationGraphRequest -Method GET -Uri $uri -All)
    }
    catch {
        Write-MigrationLog -Message "Could not read the authentication methods report: $($_.Exception.Message)" -Level WARNING
        Write-MigrationLog -Message 'MfaRegistered and MfaMethods will be blank. AuditLog.Read.All is required.' -Level WARNING
        $script:RowFailureCount++
        return $map
    }

    foreach ($record in $records) {
        $id = [string](Get-InventoryValue $record 'id' '')
        if ($id) { $map[$id] = $record }
    }

    Write-MigrationLog -Message "Read MFA registration for $($map.Count) principal(s)." -Level INFO
    return $map
}

function Get-InventoryMailbox {
    <#
    .SYNOPSIS
        Reads every mailbox in one Exchange call.

    .DESCRIPTION
        Get-EXOMailbox is the REST-backed cmdlet and is several times faster than Get-Mailbox on
        a large tenant, but only returns the properties asked for. The property sets below cover
        the holds, forwarding, policy and quota columns; if a future service change rejects the
        combination the call is retried with -PropertySets All, which is slow but always works.

    .PARAMETER PropertySet
        The property sets to request.

    .PARAMETER Property
        Individual properties not covered by a set.

    .PARAMETER RecipientTypeDetail
        The mailbox types to return.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string[]]$PropertySet,

        [Parameter(Mandatory)]
        [string[]]$Property,

        [Parameter(Mandatory)]
        [string[]]$RecipientTypeDetail
    )

    $parameters = @{
        ResultSize           = 'Unlimited'
        RecipientTypeDetails = $RecipientTypeDetail
        PropertySets         = $PropertySet
        Properties           = $Property
        ErrorAction          = 'Stop'
    }

    try {
        return @(Get-EXOMailbox @parameters)
    }
    catch {
        Write-MigrationLog -Level WARNING -Message ("Get-EXOMailbox with property sets failed " +
            "($($_.Exception.Message)); retrying with -PropertySets All.")
        return @(Get-EXOMailbox -ResultSize Unlimited -PropertySets All -ErrorAction Stop `
            -RecipientTypeDetails $RecipientTypeDetail)
    }
}

function Get-InventoryMailboxStatistic {
    <#
    .SYNOPSIS
        Collects primary and archive mailbox statistics keyed by ExchangeGuid.

    .DESCRIPTION
        This is one of only two per-object passes in the script, which is why -SkipMailboxStats
        exists. The archive call is made only for mailboxes that report an archive, so a tenant
        with no archives pays nothing for the archive column.

    .PARAMETER Mailbox
        The mailboxes to measure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Mailbox
    )

    $map = @{}
    $all = @($Mailbox)
    $index = 0

    foreach ($item in $all) {
        $index++
        $guid = [string](Get-InventoryValue $item 'ExchangeGuid' '')
        $smtp = [string](Get-InventoryValue $item 'PrimarySmtpAddress' '')
        if (-not $guid) { continue }

        Write-InventoryProgress -Tab 'Mailbox statistics' -Status $smtp -Current $index -Total $all.Count

        $entry = [pscustomobject]@{ Primary = $null; Archive = $null }

        try {
            $entry.Primary = Get-EXOMailboxStatistics -Identity $guid -ErrorAction Stop
        }
        catch {
            Write-MigrationLog -Message "No statistics for ${smtp}: $($_.Exception.Message)" -Level WARNING
            $script:RowFailureCount++
        }

        $archiveStatus = [string](Get-InventoryValue $item 'ArchiveStatus' '')
        $archiveGuid = [string](Get-InventoryValue $item 'ArchiveGuid' '')
        $hasArchive = ($archiveStatus -eq 'Active') -or
            ($archiveGuid -and $archiveGuid -ne '00000000-0000-0000-0000-000000000000')

        if ($hasArchive) {
            try {
                $entry.Archive = Get-EXOMailboxStatistics -Identity $guid -Archive -ErrorAction Stop
            }
            catch {
                Write-MigrationLog -Message "No archive statistics for ${smtp}: $($_.Exception.Message)" -Level DEBUG
            }
        }

        $map[$guid] = $entry
    }
    Write-Progress -Activity 'Inventory: Mailbox statistics' -Completed

    return $map
}

function Get-InventoryMailboxPermission {
    <#
    .SYNOPSIS
        Collects FullAccess, SendAs, SendOnBehalf and explicit Calendar delegations.

    .DESCRIPTION
        The REST cmdlets are used deliberately: tenant-wide Get-MailboxPermission over remote
        PowerShell throws 'data exceeded the maximum permitted by the session' on large orgs,
        and Microsoft's own guidance is to use Get-EXOMailboxPermission instead. Three calls per
        mailbox is the honest cost of this tab - hence -SkipMailboxPermissions.

        Calendar permissions are read for the Calendar folder only. The folder name is localised
        in some tenants, so a failure there is logged at DEBUG and skipped rather than counted
        as an error.

    .PARAMETER Mailbox
        The mailboxes to inspect.

    .PARAMETER ExclusionPattern
        Trustees to ignore.

    .PARAMETER CalendarBuiltIn
        Calendar trustees to ignore (Default, Anonymous).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Mailbox,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExclusionPattern,

        [Parameter(Mandatory)]
        [string[]]$CalendarBuiltIn
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $all = @($Mailbox)
    $index = 0

    foreach ($item in $all) {
        $index++
        $smtp = [string](Get-InventoryValue $item 'PrimarySmtpAddress' '')
        $type = [string](Get-InventoryValue $item 'RecipientTypeDetails' '')
        $identity = [string](Get-InventoryValue $item 'ExternalDirectoryObjectId' $smtp)
        if (-not $identity) { $identity = $smtp }
        if (-not $identity) { continue }

        Write-InventoryProgress -Tab 'MailboxPermissions' -Status $smtp -Current $index -Total $all.Count

        try {
            foreach ($ace in @(Get-EXOMailboxPermission -Identity $identity -ErrorAction Stop)) {
                $trustee = [string](Get-InventoryValue $ace 'User' '')
                if (-not (Test-InventoryTrustee -Trustee $trustee -Pattern $ExclusionPattern)) { continue }
                if ([bool](Get-InventoryValue $ace 'Deny' $false)) { continue }

                $rights = @(Get-InventoryValue $ace 'AccessRights' @())
                if ($rights -notcontains 'FullAccess') { continue }

                $rows.Add((ConvertTo-InventoryPermissionRow -MailboxPrimarySmtp $smtp -MailboxType $type `
                    -Trustee $trustee -Permission 'FullAccess' `
                    -IsInherited ([bool](Get-InventoryValue $ace 'IsInherited' $false))))
            }
        }
        catch {
            Write-MigrationLog -Message "Could not read mailbox permissions for ${smtp}: $($_.Exception.Message)" -Level WARNING
            $script:RowFailureCount++
        }

        try {
            foreach ($ace in @(Get-EXORecipientPermission -Identity $identity -ErrorAction Stop)) {
                $trustee = [string](Get-InventoryValue $ace 'Trustee' '')
                if (-not (Test-InventoryTrustee -Trustee $trustee -Pattern $ExclusionPattern)) { continue }
                if ((Get-InventoryValue $ace 'AccessControlType' 'Allow') -ne 'Allow') { continue }

                $rows.Add((ConvertTo-InventoryPermissionRow -MailboxPrimarySmtp $smtp -MailboxType $type `
                    -Trustee $trustee -Permission 'SendAs' -IsInherited $false))
            }
        }
        catch {
            Write-MigrationLog -Message "Could not read recipient permissions for ${smtp}: $($_.Exception.Message)" -Level WARNING
            $script:RowFailureCount++
        }

        foreach ($delegate in @(Get-InventoryValue $item 'GrantSendOnBehalfTo' @())) {
            $trustee = [string]$delegate
            if (-not (Test-InventoryTrustee -Trustee $trustee -Pattern $ExclusionPattern)) { continue }
            $rows.Add((ConvertTo-InventoryPermissionRow -MailboxPrimarySmtp $smtp -MailboxType $type `
                -Trustee $trustee -Permission 'SendOnBehalf' -IsInherited $false))
        }

        try {
            $folder = '{0}:\Calendar' -f $identity
            foreach ($ace in @(Get-EXOMailboxFolderPermission -Identity $folder -ErrorAction Stop)) {
                $trustee = [string](Get-InventoryValue $ace 'User' '')
                if (-not (Test-InventoryTrustee -Trustee $trustee -Pattern $ExclusionPattern)) { continue }
                if ($CalendarBuiltIn -contains $trustee) { continue }

                $rights = @(Get-InventoryValue $ace 'AccessRights' @())
                if (-not $rights) { continue }
                if ($rights -contains 'None') { continue }

                $rows.Add((ConvertTo-InventoryPermissionRow -MailboxPrimarySmtp $smtp -MailboxType $type `
                    -Trustee $trustee -Permission ('Calendar:' + (($rights | ForEach-Object { [string]$_ }) -join ',')) `
                    -IsInherited $false))
            }
        }
        catch {
            Write-MigrationLog -Message "No calendar permissions for ${smtp}: $($_.Exception.Message)" -Level DEBUG
        }
    }
    Write-Progress -Activity 'Inventory: MailboxPermissions' -Completed

    return $rows.ToArray()
}

#endregion ---------------------------------------------------------------------------------------

#region Main -------------------------------------------------------------------------------------

$exitCode = 0

try {
    $run = Initialize-MigrationRun -ScriptName 'Get-MigrationInventory' -OutputPath $OutputPath -Prefix $Prefix `
        -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

    $domains = ConvertTo-InventoryDomainList -Domain $DomainFilter
    if ($domains.Count -gt 0) {
        Write-MigrationLog -Message "Domain filter: $(Join-MigrationList -Values $domains)" -Level INFO
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $filePrefix = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
    $excelPath = Join-Path -Path $run.OutputDirectory -ChildPath "${filePrefix}Migration-Inventory_$timestamp.xlsx"
    $csvPaths = [ordered]@{}
    foreach ($tab in $inventoryTabs) {
        $csvPaths[$tab] = Join-Path -Path $run.OutputDirectory -ChildPath "${filePrefix}${tab}_$timestamp.csv"
    }

    # ImportExcel is a convenience, not a dependency: an inventory that produced only CSVs is
    # still a complete inventory, so a failed install warns rather than aborting the run.
    $useExcel = -not $SkipExcel
    if ($useExcel) {
        try {
            Initialize-MigrationModule -Name 'ImportExcel'
        }
        catch {
            Write-MigrationLog -Message "ImportExcel is unavailable ($($_.Exception.Message)); writing CSVs only." -Level WARNING
            $useExcel = $false
        }
    }

    Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId | Out-Null
    Connect-MigrationExchange -DelegatedOrganization $DelegatedOrganization | Out-Null

    #-- Tenant facts ------------------------------------------------------------------------------
    $tenantId = ''
    $tenantName = ''
    $defaultDomain = ''
    try {
        $organisation = @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/organization' -All) | Select-Object -First 1
        $tenantId = [string](Get-InventoryValue $organisation 'id' '')
        $tenantName = [string](Get-InventoryValue $organisation 'displayName' '')
    }
    catch {
        Write-MigrationLog -Message "Could not read tenant details: $($_.Exception.Message)" -Level WARNING
        $script:RowFailureCount++
    }

    #-- Domains -----------------------------------------------------------------------------------
    Write-MigrationLog -Message 'Reading accepted domains...' -Level INFO
    $domainRows = @()
    try {
        $graphDomains = @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/domains' -All)
        $domainRows = @(foreach ($domain in $graphDomains) {
            $isDefault = [bool](Get-InventoryValue $domain 'isDefault' $false)
            $name = [string](Get-InventoryValue $domain 'id' '')
            if ($isDefault) { $defaultDomain = $name }
            [pscustomobject][ordered]@{
                DomainName         = $name
                IsDefault          = $isDefault
                IsInitial          = [bool](Get-InventoryValue $domain 'isInitial' $false)
                IsVerified         = [bool](Get-InventoryValue $domain 'isVerified' $false)
                AuthenticationType = [string](Get-InventoryValue $domain 'authenticationType' '')
                SupportedServices  = Join-MigrationList -Values @(
                    @(Get-InventoryValue $domain 'supportedServices' @()) |
                        ForEach-Object { [string]$_ })
            }
        })
    }
    catch {
        Write-MigrationLog -Message "Could not read domains: $($_.Exception.Message)" -Level WARNING
        $script:RowFailureCount++
    }
    Write-MigrationLog -Message "Domains: $($domainRows.Count)" -Level INFO

    #-- Licences ----------------------------------------------------------------------------------
    Write-MigrationLog -Message 'Reading subscribed SKUs...' -Level INFO
    $skuCatalog = @(Get-MigrationSkuCatalog)
    $skuNameById = @{}
    foreach ($sku in $skuCatalog) { $skuNameById[$sku.SkuId] = $sku.SkuPartNumber }

    # The catalog exposes service plan names but not their ids, and disabledPlans on a user is a
    # list of ids - so the raw payload is read once to build the id-to-name map.
    $servicePlanNameById = @{}
    try {
        foreach ($raw in @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/subscribedSkus' -All)) {
            foreach ($plan in @(Get-InventoryValue $raw 'servicePlans' @())) {
                $planId = [string](Get-InventoryValue $plan 'servicePlanId' '')
                $planName = [string](Get-InventoryValue $plan 'servicePlanName' '')
                if ($planId -and -not $servicePlanNameById.ContainsKey($planId)) { $servicePlanNameById[$planId] = $planName }
            }
        }
    }
    catch {
        Write-MigrationLog -Message "Could not map service plan names: $($_.Exception.Message)" -Level WARNING
    }

    #-- Users -------------------------------------------------------------------------------------
    Write-MigrationLog -Message 'Reading users from Microsoft Graph...' -Level INFO
    $graphUsers = @(Get-InventoryGraphUser -IncludeDisabledUser:$IncludeDisabled)
    Write-MigrationLog -Message "Graph returned $($graphUsers.Count) user(s)." -Level INFO

    if (-not $IncludeGuests) {
        $graphUsers = @($graphUsers | Where-Object {
            (Get-InventoryValue $_ 'userType' 'Member') -ne 'Guest'
        })
    }
    if ($domains.Count -gt 0) {
        $graphUsers = @($graphUsers | Where-Object {
            Test-InventoryDomainMatch -Domain $domains -Address @(
                [string](Get-InventoryValue $_ 'userPrincipalName' '')
                [string](Get-InventoryValue $_ 'mail' '')
            )
        })
    }
    Write-MigrationLog -Message "Users after filtering: $($graphUsers.Count)" -Level INFO

    $roleMap = Get-InventoryDirectoryRoleMap
    $authMap = @{}
    if ($IncludeAuthMethods) { $authMap = Get-InventoryAuthMethodMap }

    #-- Mailboxes ---------------------------------------------------------------------------------
    Write-MigrationLog -Message 'Reading Exchange Online mailboxes...' -Level INFO
    $mailboxes = @(Get-InventoryMailbox -PropertySet $mailboxPropertySets -Property $mailboxProperties `
        -RecipientTypeDetail $mailboxRecipientTypes)
    Write-MigrationLog -Message "Exchange returned $($mailboxes.Count) mailbox(es)." -Level INFO

    if ($domains.Count -gt 0) {
        $mailboxes = @($mailboxes | Where-Object {
            Test-InventoryDomainMatch -Domain $domains -Address @(
                [string](Get-InventoryValue $_ 'UserPrincipalName' '')
                [string](Get-InventoryValue $_ 'PrimarySmtpAddress' '')
            )
        })
        Write-MigrationLog -Message "Mailboxes after filtering: $($mailboxes.Count)" -Level INFO
    }

    #-- Groups and contacts -----------------------------------------------------------------------
    Write-MigrationLog -Message 'Reading distribution groups...' -Level INFO
    $distributionGroups = @()
    try { $distributionGroups = @(Get-DistributionGroup -ResultSize Unlimited -ErrorAction Stop) }
    catch {
        Write-MigrationLog -Message "Could not read distribution groups: $($_.Exception.Message)" -Level WARNING
        $script:RowFailureCount++
    }

    $dynamicGroups = @()
    try { $dynamicGroups = @(Get-DynamicDistributionGroup -ResultSize Unlimited -ErrorAction Stop) }
    catch {
        Write-MigrationLog -Message "Could not read dynamic distribution groups: $($_.Exception.Message)" -Level WARNING
        $script:RowFailureCount++
    }

    $unifiedGroups = @()
    try { $unifiedGroups = @(Get-UnifiedGroup -ResultSize Unlimited -ErrorAction Stop) }
    catch {
        Write-MigrationLog -Message "Could not read Microsoft 365 groups from Exchange: $($_.Exception.Message)" -Level WARNING
        $script:RowFailureCount++
    }

    Write-MigrationLog -Message 'Reading groups from Microsoft Graph...' -Level INFO
    $graphGroups = @()
    try {
        $groupSelect = @(
            'id', 'displayName', 'mail', 'mailNickname', 'mailEnabled', 'securityEnabled', 'groupTypes',
            'visibility', 'resourceProvisioningOptions', 'proxyAddresses', 'onPremisesSyncEnabled', 'membershipRule'
        ) -join ','
        $graphGroups = @(Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/groups?`$select=$groupSelect&`$top=999" -All)
    }
    catch {
        Write-MigrationLog -Message "Could not read groups from Graph: $($_.Exception.Message)" -Level WARNING
        $script:RowFailureCount++
    }
    Write-MigrationLog -Message "Graph returned $($graphGroups.Count) group(s)." -Level INFO

    Write-MigrationLog -Message 'Reading mail contacts...' -Level INFO
    $mailContacts = @()
    $contactByGuid = @{}
    try {
        $mailContacts = @(Get-MailContact -ResultSize Unlimited -ErrorAction Stop)
        foreach ($contact in @(Get-Contact -ResultSize Unlimited -ErrorAction Stop)) {
            $guid = [string](Get-InventoryValue $contact 'Guid' '')
            if ($guid) { $contactByGuid[$guid] = $contact }
        }
    }
    catch {
        Write-MigrationLog -Message "Could not read mail contacts: $($_.Exception.Message)" -Level WARNING
        $script:RowFailureCount++
    }

    if ($domains.Count -gt 0) {
        $mailContacts = @($mailContacts | Where-Object {
            Test-InventoryDomainMatch -Domain $domains -Address @(
                [string](Get-InventoryValue $_ 'PrimarySmtpAddress' '')
            )
        })
    }

    #-- Recipient index ---------------------------------------------------------------------------
    # Built before any row is shaped so that delegate, moderator and member lists resolve to
    # addresses rather than to whatever identity string Exchange happened to store.
    foreach ($item in $mailboxes) {
        $smtp = [string](Get-InventoryValue $item 'PrimarySmtpAddress' '')
        Add-InventoryRecipientIndexEntry -PrimarySmtpAddress $smtp -Key @(
            $smtp
            [string](Get-InventoryValue $item 'UserPrincipalName' '')
            [string](Get-InventoryValue $item 'Alias' '')
            [string](Get-InventoryValue $item 'DisplayName' '')
            [string](Get-InventoryValue $item 'Name' '')
            [string](Get-InventoryValue $item 'Identity' '')
            [string](Get-InventoryValue $item 'ExternalDirectoryObjectId' '')
        )
    }
    foreach ($item in @($distributionGroups + $dynamicGroups + $unifiedGroups + $mailContacts)) {
        $smtp = [string](Get-InventoryValue $item 'PrimarySmtpAddress' '')
        Add-InventoryRecipientIndexEntry -PrimarySmtpAddress $smtp -Key @(
            $smtp
            [string](Get-InventoryValue $item 'Alias' '')
            [string](Get-InventoryValue $item 'DisplayName' '')
            [string](Get-InventoryValue $item 'Name' '')
            [string](Get-InventoryValue $item 'Identity' '')
            [string](Get-InventoryValue $item 'ExternalDirectoryObjectId' '')
        )
    }
    Write-MigrationLog -Message "Recipient index holds $($script:RecipientIndex.Count) key(s)." -Level DEBUG

    #-- Users tab ---------------------------------------------------------------------------------
    Write-MigrationLog -Message 'Building the Users tab...' -Level INFO
    $userRows = [System.Collections.Generic.List[object]]::new()
    $disabledPlanTally = @{}
    $oneDriveTotalGB = 0
    $index = 0

    foreach ($user in $graphUsers) {
        $index++
        $upn = [string](Get-InventoryValue $user 'userPrincipalName' '')
        Write-InventoryProgress -Tab 'Users' -Status $upn -Current $index -Total $graphUsers.Count

        $userId = [string](Get-InventoryValue $user 'id' '')
        $roles = @()
        if ($userId -and $roleMap.ContainsKey($userId)) { $roles = @($roleMap[$userId]) }

        $registration = $null
        if ($userId -and $authMap.ContainsKey($userId)) { $registration = $authMap[$userId] }

        $drive = $null
        if ($IncludeOneDrive -and $userId) {
            try {
                $drive = Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/users/$userId/drive`?`$select=webUrl,quota"
            }
            catch {
                # A 404 here is the normal answer for a user whose OneDrive was never
                # provisioned, so it is information rather than a failure.
                Write-MigrationLog -Message "No OneDrive for ${upn}: $($_.Exception.Message)" -Level DEBUG
            }
        }

        foreach ($state in @(Get-InventoryValue $user 'assignedLicenses' @())) {
            foreach ($planId in @(Get-InventoryValue $state 'disabledPlans' @())) {
                $skuId = [string](Get-InventoryValue $state 'skuId' '')
                $key = "$skuId|$planId"
                if (-not $disabledPlanTally.ContainsKey($key)) { $disabledPlanTally[$key] = 0 }
                $disabledPlanTally[$key]++
            }
        }

        $row = ConvertTo-InventoryUserRow -User $user -SkuNameById $skuNameById -DirectoryRole $roles `
            -Registration $registration -Drive $drive `
            -IncludeAuthMethodColumn:$IncludeAuthMethods -IncludeOneDriveColumn:$IncludeOneDrive

        if ($IncludeOneDrive -and $row.OneDriveUsedGB) { $oneDriveTotalGB += [double]$row.OneDriveUsedGB }
        $userRows.Add($row)
    }
    Write-Progress -Activity 'Inventory: Users' -Completed

    #-- Mailbox tabs ------------------------------------------------------------------------------
    $statisticsMap = @{}
    if (-not $SkipMailboxStats) {
        Write-MigrationLog -Message "Collecting statistics for $($mailboxes.Count) mailbox(es)..." -Level INFO
        $statisticsMap = Get-InventoryMailboxStatistic -Mailbox $mailboxes
    }
    else {
        Write-MigrationLog -Message 'Skipping mailbox statistics (-SkipMailboxStats).' -Level WARNING
    }

    Write-MigrationLog -Message 'Building the mailbox tabs...' -Level INFO
    $userMailboxRows = [System.Collections.Generic.List[object]]::new()
    $sharedMailboxRows = [System.Collections.Generic.List[object]]::new()
    $totalMailboxGB = 0
    $totalArchiveGB = 0
    $index = 0

    foreach ($item in $mailboxes) {
        $index++
        Write-InventoryProgress -Tab 'Mailboxes' -Current $index -Total $mailboxes.Count `
            -Status ([string](Get-InventoryValue $item 'PrimarySmtpAddress' ''))

        $guid = [string](Get-InventoryValue $item 'ExchangeGuid' '')
        $entry = if ($guid -and $statisticsMap.ContainsKey($guid)) { $statisticsMap[$guid] } else { $null }

        $row = ConvertTo-InventoryMailboxRow -Mailbox $item `
            -Statistics (Get-InventoryValue $entry 'Primary') `
            -ArchiveStatistics (Get-InventoryValue $entry 'Archive')

        if ($row.TotalItemSizeGB) { $totalMailboxGB += [double]$row.TotalItemSizeGB }
        if ($row.ArchiveSizeGB) { $totalArchiveGB += [double]$row.ArchiveSizeGB }

        if ($row.RecipientTypeDetails -eq 'UserMailbox') { $userMailboxRows.Add($row) }
        else { $sharedMailboxRows.Add($row) }
    }
    Write-Progress -Activity 'Inventory: Mailboxes' -Completed

    #-- MailboxPermissions tab --------------------------------------------------------------------
    $permissionRows = @()
    if ($SkipMailboxPermissions) {
        Write-MigrationLog -Message 'Skipping mailbox permissions (-SkipMailboxPermissions).' -Level WARNING
    }
    else {
        Write-MigrationLog -Level INFO -Message ("Collecting permissions for " +
            "$($mailboxes.Count) mailbox(es) - this is the slowest pass.")
        $permissionRows = @(Get-InventoryMailboxPermission -Mailbox $mailboxes `
            -ExclusionPattern $permissionTrusteeExclusions -CalendarBuiltIn $calendarBuiltInTrustees)
        Write-MigrationLog -Message "Found $($permissionRows.Count) delegation(s)." -Level INFO
    }

    #-- Groups tab --------------------------------------------------------------------------------
    Write-MigrationLog -Message 'Building the Groups tab...' -Level INFO
    $graphGroupById = @{}
    foreach ($group in $graphGroups) {
        $id = [string](Get-InventoryValue $group 'id' '')
        if ($id) { $graphGroupById[$id] = $group }
    }

    $groupRows = [System.Collections.Generic.List[object]]::new()
    $seenGroupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $exchangeGroups = @($distributionGroups + $dynamicGroups + $unifiedGroups)
    $index = 0

    foreach ($group in $exchangeGroups) {
        $index++
        $displayName = [string](Get-InventoryValue $group 'DisplayName' '')
        Write-InventoryProgress -Tab 'Groups' -Status $displayName -Current $index -Total $exchangeGroups.Count

        $primarySmtp = [string](Get-InventoryValue $group 'PrimarySmtpAddress' '')
        if ($domains.Count -gt 0 -and -not (Test-InventoryDomainMatch -Domain $domains -Address @($primarySmtp))) { continue }

        $objectId = [string](Get-InventoryValue $group 'ExternalDirectoryObjectId' '')
        if ($objectId) { $null = $seenGroupIds.Add($objectId) }

        $graphGroup = $null
        if ($objectId -and $graphGroupById.ContainsKey($objectId)) { $graphGroup = $graphGroupById[$objectId] }

        $provisioning = @(Get-InventoryValue $graphGroup 'resourceProvisioningOptions' @())
        $isTeam = ($provisioning -contains 'Team')
        $recipientType = [string](Get-InventoryValue $group 'RecipientTypeDetails' '')
        $groupType = Get-InventoryGroupType -RecipientTypeDetails $recipientType -IsTeam $isTeam `
            -GroupType @(Get-InventoryValue $graphGroup 'groupTypes' @()) `
            -MailEnabled $true -SecurityEnabled $false

        # Dynamic groups are defined by their filter, not by a membership list: the filter is
        # what has to be recreated in the destination, so it is captured verbatim and no
        # (potentially enormous) preview expansion is run.
        $recipientFilter = [string](Get-InventoryValue $group 'RecipientFilter' '')

        $members = @()
        if ($groupType -in @('Distribution', 'MailEnabledSecurity')) {
            try {
                $members = @(Get-DistributionGroupMember -Identity $objectId -ResultSize Unlimited -ErrorAction Stop |
                    ForEach-Object {
                        $memberSmtp = [string](Get-InventoryValue $_ 'PrimarySmtpAddress' '')
                        if ($memberSmtp) { $memberSmtp }
                        else { [string](Get-InventoryValue $_ 'DisplayName' '') }
                    })
            }
            catch {
                Write-MigrationLog -Message "Could not read members of '$displayName': $($_.Exception.Message)" -Level WARNING
                $script:RowFailureCount++
            }
        }
        elseif ($groupType -in @('M365Group', 'Team') -and $objectId) {
            try {
                $members = @(Invoke-MigrationGraphRequest -Method GET -All `
                    -Uri "/v1.0/groups/$objectId/members`?`$select=id,displayName,userPrincipalName,mail&`$top=999" |
                    ForEach-Object {
                        $value = [string](Get-InventoryValue $_ 'userPrincipalName' '')
                        if (-not $value) { $value = [string](Get-InventoryValue $_ 'mail' '') }
                        if (-not $value) { $value = [string](Get-InventoryValue $_ 'displayName' '') }
                        $value
                    })
            }
            catch {
                Write-MigrationLog -Message "Could not read members of '$displayName': $($_.Exception.Message)" -Level WARNING
                $script:RowFailureCount++
            }
        }

        $owners = Join-InventoryRecipientList -Value (Get-InventoryValue $group 'ManagedBy')
        $addresses = Select-InventoryAddress -EmailAddress (@(Get-InventoryValue $group 'EmailAddresses' @()))

        $groupRows.Add([pscustomobject][ordered]@{
            ObjectId                            = $objectId
            DisplayName                         = $displayName
            PrimarySmtpAddress                  = $primarySmtp
            GroupType                           = $groupType
            Alias                               = [string](Get-InventoryValue $group 'Alias' '')
            EmailAddresses                      = Join-MigrationList -Values $addresses.All
            LegacyExchangeDN                    = [string](Get-InventoryValue $group 'LegacyExchangeDN' '')
            ManagedBy                           = $owners
            Members                             = Join-MigrationList -Values $members
            MemberCount                         = $members.Count
            Owners                              = $owners
            HiddenFromAddressLists              = [bool](Get-InventoryValue $group 'HiddenFromAddressListsEnabled' $false)
            RequireSenderAuthenticationEnabled  = [bool](Get-InventoryValue $group 'RequireSenderAuthenticationEnabled' $false)
            AcceptMessagesOnlyFrom              = Join-InventoryRecipientList -Value `
                (Get-InventoryValue $group 'AcceptMessagesOnlyFromSendersOrMembers')
            ModerationEnabled                   = [bool](Get-InventoryValue $group 'ModerationEnabled' $false)
            ModeratedBy                         = Join-InventoryRecipientList -Value (Get-InventoryValue $group 'ModeratedBy')
            GrantSendOnBehalfTo                 = Join-InventoryRecipientList -Value (Get-InventoryValue $group 'GrantSendOnBehalfTo')
            MemberJoinRestriction               = [string](Get-InventoryValue $group 'MemberJoinRestriction' '')
            MemberDepartRestriction             = [string](Get-InventoryValue $group 'MemberDepartRestriction' '')
            RecipientFilter                     = $recipientFilter
            IsSynced                            = [bool](Get-InventoryValue $graphGroup 'onPremisesSyncEnabled' $false)
            Visibility                          = [string](Get-InventoryValue $graphGroup 'visibility' '')
            TeamEnabled                         = $isTeam
        })
    }

    # Graph-only groups: security groups that Exchange never sees. They are informational -
    # nothing in the toolkit recreates them - but a migration that silently loses a security
    # group's membership is a migration that gets escalated three weeks later.
    foreach ($group in $graphGroups) {
        $index++
        $objectId = [string](Get-InventoryValue $group 'id' '')
        if (-not $objectId -or $seenGroupIds.Contains($objectId)) { continue }

        $displayName = [string](Get-InventoryValue $group 'displayName' '')
        $groupTotal = $exchangeGroups.Count + $graphGroups.Count
        Write-InventoryProgress -Tab 'Groups' -Status $displayName -Current $index -Total $groupTotal

        $mail = [string](Get-InventoryValue $group 'mail' '')
        if ($domains.Count -gt 0 -and $mail -and -not (Test-InventoryDomainMatch -Domain $domains -Address @($mail))) { continue }

        $provisioning = @(Get-InventoryValue $group 'resourceProvisioningOptions' @())
        $isTeam = ($provisioning -contains 'Team')
        $groupType = Get-InventoryGroupType -RecipientTypeDetails '' -IsTeam $isTeam `
            -GroupType @(Get-InventoryValue $group 'groupTypes' @()) `
            -MailEnabled ([bool](Get-InventoryValue $group 'mailEnabled' $false)) `
            -SecurityEnabled ([bool](Get-InventoryValue $group 'securityEnabled' $false))

        $members = @()
        $owners = @()
        try {
            $members = @(Invoke-MigrationGraphRequest -Method GET -All `
                -Uri "/v1.0/groups/$objectId/members`?`$select=id,displayName,userPrincipalName,mail&`$top=999" |
                ForEach-Object {
                    $value = [string](Get-InventoryValue $_ 'userPrincipalName' '')
                    if (-not $value) { $value = [string](Get-InventoryValue $_ 'mail' '') }
                    if (-not $value) { $value = [string](Get-InventoryValue $_ 'displayName' '') }
                    $value
                })
            $owners = @(Invoke-MigrationGraphRequest -Method GET -All `
                -Uri "/v1.0/groups/$objectId/owners`?`$select=id,displayName,userPrincipalName,mail&`$top=999" |
                ForEach-Object {
                    $value = [string](Get-InventoryValue $_ 'userPrincipalName' '')
                    if (-not $value) { $value = [string](Get-InventoryValue $_ 'mail' '') }
                    if (-not $value) { $value = [string](Get-InventoryValue $_ 'displayName' '') }
                    $value
                })
        }
        catch {
            Write-MigrationLog -Message "Could not read membership of '$displayName': $($_.Exception.Message)" -Level WARNING
            $script:RowFailureCount++
        }

        $addresses = Select-InventoryAddress -EmailAddress (@(Get-InventoryValue $group 'proxyAddresses' @()))

        $groupRows.Add([pscustomobject][ordered]@{
            ObjectId                            = $objectId
            DisplayName                         = $displayName
            PrimarySmtpAddress                  = $mail
            GroupType                           = $groupType
            Alias                               = [string](Get-InventoryValue $group 'mailNickname' '')
            EmailAddresses                      = Join-MigrationList -Values $addresses.All
            LegacyExchangeDN                    = ''
            ManagedBy                           = Join-MigrationList -Values $owners
            Members                             = Join-MigrationList -Values $members
            MemberCount                         = $members.Count
            Owners                              = Join-MigrationList -Values $owners
            HiddenFromAddressLists              = $false
            RequireSenderAuthenticationEnabled  = $false
            AcceptMessagesOnlyFrom              = ''
            ModerationEnabled                   = $false
            ModeratedBy                         = ''
            GrantSendOnBehalfTo                 = ''
            MemberJoinRestriction               = ''
            MemberDepartRestriction             = ''
            RecipientFilter                     = [string](Get-InventoryValue $group 'membershipRule' '')
            IsSynced                            = [bool](Get-InventoryValue $group 'onPremisesSyncEnabled' $false)
            Visibility                          = [string](Get-InventoryValue $group 'visibility' '')
            TeamEnabled                         = $isTeam
        })
    }
    Write-Progress -Activity 'Inventory: Groups' -Completed
    Write-MigrationLog -Message "Groups: $($groupRows.Count)" -Level INFO

    #-- Contacts tab ------------------------------------------------------------------------------
    Write-MigrationLog -Message 'Building the Contacts tab...' -Level INFO
    $contactRows = @(foreach ($mailContact in $mailContacts) {
        $guid = [string](Get-InventoryValue $mailContact 'Guid' '')
        $contact = if ($guid -and $contactByGuid.ContainsKey($guid)) { $contactByGuid[$guid] } else { $null }
        ConvertTo-InventoryContactRow -MailContact $mailContact -Contact $contact
    })

    #-- Licenses tab ------------------------------------------------------------------------------
    $licenseRows = @(foreach ($sku in $skuCatalog) {
        $common = @($disabledPlanTally.GetEnumerator() |
            Where-Object { $_.Key.StartsWith("$($sku.SkuId)|", [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object -Property Value -Descending |
            Select-Object -First 3 |
            ForEach-Object {
                $planId = ($_.Key -split '\|')[-1]
                $planName = if ($servicePlanNameById.ContainsKey($planId)) { $servicePlanNameById[$planId] } else { $planId }
                "$planName ($($_.Value))"
            })

        [pscustomobject][ordered]@{
            SkuPartNumber               = $sku.SkuPartNumber
            FriendlyName                = $sku.FriendlyName
            SkuId                       = $sku.SkuId
            Enabled                     = $sku.Enabled
            Consumed                    = $sku.Consumed
            Available                   = $sku.Available
            ServicePlansDisabledCommon  = Join-MigrationList -Values $common
        }
    })

    #-- Summary tab -------------------------------------------------------------------------------
    $mailboxTypeCount = @{}
    foreach ($row in $sharedMailboxRows) {
        $key = [string]$row.RecipientTypeDetails
        if (-not $mailboxTypeCount.ContainsKey($key)) { $mailboxTypeCount[$key] = 0 }
        $mailboxTypeCount[$key]++
    }
    $groupTypeCount = @{}
    foreach ($row in $groupRows) {
        $key = [string]$row.GroupType
        if (-not $groupTypeCount.ContainsKey($key)) { $groupTypeCount[$key] = 0 }
        $groupTypeCount[$key]++
    }
    $countOf = {
        param([hashtable]$Table, [string]$Key)
        if ($Table.ContainsKey($Key)) { $Table[$Key] } else { 0 }
    }

    $summaryRows = @(
        [pscustomobject]@{ Item = 'TenantId'; Value = $tenantId }
        [pscustomobject]@{ Item = 'TenantDisplayName'; Value = $tenantName }
        [pscustomobject]@{ Item = 'DefaultDomain'; Value = $defaultDomain }
        [pscustomobject]@{ Item = 'InventoryTimestamp'; Value = $timestamp }
        [pscustomobject]@{ Item = 'DomainFilter'; Value = (Join-MigrationList -Values $domains) }
        [pscustomobject]@{ Item = 'IncludeGuests'; Value = [bool]$IncludeGuests }
        [pscustomobject]@{ Item = 'IncludeDisabled'; Value = [bool]$IncludeDisabled }
        [pscustomobject]@{ Item = 'Users'; Value = $userRows.Count }
        [pscustomobject]@{ Item = 'UsersLicensed'; Value = @($userRows | Where-Object { $_.Licenses }).Count }
        [pscustomobject]@{ Item = 'UsersSynced'; Value = @($userRows | Where-Object { $_.IsSynced }).Count }
        [pscustomobject]@{ Item = 'UsersGuest'; Value = @($userRows | Where-Object { $_.UserType -eq 'Guest' }).Count }
        [pscustomobject]@{ Item = 'UserMailboxes'; Value = $userMailboxRows.Count }
        [pscustomobject]@{ Item = 'SharedMailboxes'; Value = (& $countOf $mailboxTypeCount 'SharedMailbox') }
        [pscustomobject]@{ Item = 'RoomMailboxes'; Value = (& $countOf $mailboxTypeCount 'RoomMailbox') }
        [pscustomobject]@{ Item = 'EquipmentMailboxes'; Value = (& $countOf $mailboxTypeCount 'EquipmentMailbox') }
        [pscustomobject]@{ Item = 'MailboxPermissions'; Value = @($permissionRows).Count }
        [pscustomobject]@{ Item = 'Groups'; Value = $groupRows.Count }
        [pscustomobject]@{ Item = 'GroupsDistribution'; Value = (& $countOf $groupTypeCount 'Distribution') }
        [pscustomobject]@{ Item = 'GroupsMailEnabledSecurity'; Value = (& $countOf $groupTypeCount 'MailEnabledSecurity') }
        [pscustomobject]@{ Item = 'GroupsDynamicDistribution'; Value = (& $countOf $groupTypeCount 'DynamicDistribution') }
        [pscustomobject]@{ Item = 'GroupsM365'; Value = ((& $countOf $groupTypeCount 'M365Group') + (& $countOf $groupTypeCount 'Team')) }
        [pscustomobject]@{ Item = 'GroupsSecurity'; Value = (& $countOf $groupTypeCount 'SecurityGroup') }
        [pscustomobject]@{ Item = 'Contacts'; Value = @($contactRows).Count }
        [pscustomobject]@{ Item = 'Domains'; Value = @($domainRows).Count }
        [pscustomobject]@{ Item = 'DomainsVerified'; Value = @($domainRows | Where-Object { $_.IsVerified }).Count }
        [pscustomobject]@{ Item = 'SubscribedSkus'; Value = @($licenseRows).Count }
        [pscustomobject]@{ Item = 'TotalMailboxSizeGB'; Value = [math]::Round($totalMailboxGB, 2) }
        [pscustomobject]@{ Item = 'TotalArchiveSizeGB'; Value = [math]::Round($totalArchiveGB, 2) }
        [pscustomobject]@{ Item = 'TotalOneDriveUsedGB'; Value = [math]::Round($oneDriveTotalGB, 2) }
    )

    #-- Write the tabs ----------------------------------------------------------------------------
    if ($useExcel -and (Test-Path -LiteralPath $excelPath)) {
        Invoke-MigrationAction -Description "Replace the existing workbook $excelPath" -Action {
            Remove-Item -LiteralPath $excelPath -Force
        }
    }

    $tabData = [ordered]@{
        Users              = $userRows.ToArray()
        UserMailboxes      = $userMailboxRows.ToArray()
        SharedMailboxes    = $sharedMailboxRows.ToArray()
        MailboxPermissions = @($permissionRows)
        Groups             = $groupRows.ToArray()
        Contacts           = @($contactRows)
        Domains            = @($domainRows)
        Licenses           = @($licenseRows)
        Summary            = @($summaryRows)
    }

    foreach ($tab in $inventoryTabs) {
        Export-InventoryTab -Row $tabData[$tab] -Name $tab -CsvPath $csvPaths[$tab] `
            -ExcelPath $excelPath -IncludeExcel:$useExcel
    }

    Write-MigrationLog -Message '--- Inventory summary ---' -Level SUCCESS
    foreach ($tab in $inventoryTabs) {
        $line = '  {0,-19}{1,6} row(s)  {2}' -f $tab, @($tabData[$tab]).Count, $csvPaths[$tab]
        Write-MigrationLog -Message $line -Level SUCCESS
    }
    if ($useExcel) {
        Write-MigrationLog -Message "  Workbook           $excelPath" -Level SUCCESS
    }

    if ($script:RowFailureCount -gt 0) {
        Write-MigrationLog -Level WARNING -Message ("$($script:RowFailureCount) object(s) " +
            'could not be read; see the warnings above.')
        $exitCode = 2
    }
}
catch {
    Write-MigrationLog -Message "Inventory failed: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message $_.ScriptStackTrace -Level DEBUG
    $exitCode = 1
}

#endregion ---------------------------------------------------------------------------------------

#region Cleanup ----------------------------------------------------------------------------------

# Connections are deliberately left open: an operator normally runs the destination inventory
# straight after the source one, and tearing the sessions down would force a fresh sign-in.
Write-Progress -Activity 'Inventory' -Completed
exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion ---------------------------------------------------------------------------------------
