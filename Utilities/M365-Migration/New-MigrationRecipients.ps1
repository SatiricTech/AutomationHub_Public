#Requires -Version 7.4

<#
.SYNOPSIS
    Creates and configures destination-tenant mail recipients from a migration identity plan.

.DESCRIPTION
    Phase 3 of the migration toolkit, and the counterpart to New-MigrationUsers: everything
    in a tenant that receives mail but is not a licensed user account. Shared, room and
    equipment mailboxes, distribution lists, mail-enabled security groups, dynamic
    distribution groups and mail contacts are all created from the same identity plan, in
    one pass, against one Exchange Online session.

    Two jobs, one script. Creation needs nothing but the plan. Re-creating the *settings* -
    who owns a list, who may send to it, who moderates it, who is in it - needs the source
    tenant's inventory, because the plan deliberately does not carry them. -Mode chooses:

      Create           create what is missing, nothing else
      UpdateSettings   leave creation alone and patch settings onto what is already there
      CreateAndUpdate  both, in that order (the default)

    UpdateSettings is what makes this usable alongside a mailbox-migration vendor: groups
    the vendor already created in the destination are adopted rather than duplicated, and
    the settings are applied on top of them. An existing object is only adopted when its
    recipient type is the one the row would create, and a hit found by mail nickname alone
    must also carry the row's display name; anything else fails the row rather than being
    claimed. Settings are compared against the adopted object's full state, so a re-run
    resends only what differs and leaves destination-side edits alone.

    Address mapping. Members, owners, moderators and delivery restrictions in the source
    inventory are all source-tenant addresses. Applying them unchanged would either fail or,
    worse, silently grant a stranger rights on the destination object. Every one of them is
    therefore translated through a Source-to-Target address map built from the plan, and
    anything the plan cannot map is reported in the row's Detail rather than guessed at or
    treated as fatal - a distribution list with one ex-employee in it should still be
    created with the other forty members.

    X500. Each created recipient gets the source object's LegacyExchangeDN back as an X500
    address, so replies from cached Outlook address entries and old calendar items resolve
    instead of bouncing with an IMCEAEX non-delivery report.

    Out of scope on purpose. Primary SMTP changes and GAL hiding at cutover belong to
    Set-MigrationIdentity; mailbox delegation at scale belongs to
    Set-MigrationMailboxPermissions; Microsoft 365 group and Team migration belongs to the
    mailbox-migration vendor (M365Group plan rows are informational). Members are added,
    never removed - an unexpected member is a conversation, not something a script should
    silently delete.

    -DryRun evaluates every row and writes a results file in which every action that would
    change the tenant is Status 'Planned'; rows the script would not act on are 'Skipped'.
    The Exchange session is the same as a live run - nothing is written, and the plan is not
    written back.

.PARAMETER PlanPath
    The identity plan CSV (IdentityPlan.csv). Read in full, filtered in memory, and written
    back in place with the object IDs of everything this run created.

.PARAMETER Wave
    Restricts the run to these plan waves. Omit to process every wave in the file.

.PARAMETER Type
    Which recipient types to process. Defaults to all seven. The values match the plan's
    ObjectType column.

.PARAMETER Mode
    Create, UpdateSettings or CreateAndUpdate (default). See the DESCRIPTION.

.PARAMETER GroupsCsv
    The source tenant's Groups inventory CSV from Get-MigrationInventory. Supplies owners,
    members, moderation, delivery restrictions, join and depart restrictions and the
    RecipientFilter for dynamic groups. Without it, group creation still works but no
    settings can be applied.

.PARAMETER ContactsCsv
    The source tenant's Contacts inventory CSV. Supplies each mail contact's
    ExternalEmailAddress, which is the one address that must NOT be mapped - a contact
    points at someone outside both tenants.

.PARAMETER SharedMailboxesCsv
    The source tenant's SharedMailboxes inventory CSV (Source_SharedMailboxes_*.csv). Supplies
    HiddenFromAddressListsEnabled and GrantSendOnBehalfTo for shared, room and equipment
    mailboxes.

.PARAMETER MailboxPermissionsCsv
    The source tenant's MailboxPermissions inventory CSV. When supplied, FullAccess and
    SendAs grants on the created shared and resource mailboxes are re-applied with their
    trustees mapped through the plan. Omit it to leave delegation entirely to
    Set-MigrationMailboxPermissions.

.PARAMETER UseInterim
    Uses each row's InterimPrimarySmtp instead of TargetPrimarySmtp. Use this while the
    vanity domain still belongs to the source tenant.

.PARAMETER TenantId
    Pins the run to the destination tenant: its onmicrosoft.com domain or its tenant ID.
    Exchange Online has no sign-in pin outside GDAP, so the check happens after the session
    is established or reused - when the connected organisation is not this tenant the run
    stops before the first row instead of creating recipients in whatever tenant a leftover
    session belongs to. Pass it on every run.

.PARAMETER DelegatedOrganization
    The customer tenant for GDAP delegated access, for example 'newco.onmicrosoft.com'.
    Omit when signing in to your own tenant.

.PARAMETER IncludeCollisions
    Also processes rows whose PlanStatus is 'Collision'. Without it only Planned,
    ManualOverride and UpnSmtpDiverge rows are acted on.

.PARAMETER OutputPath
    Overrides the output root for the log and results files.

.PARAMETER Prefix
    Names the client or run. Output lands in <root>\<Prefix>\ with '<Prefix>_' filenames.

.PARAMETER LogPath
    Overrides the derived log file path.

.PARAMETER DryRun
    Evaluates every row and writes a '-DryRun_' results file without changing anything.

.PARAMETER Verbosity
    Console verbosity: Low, Medium (default) or High. The log file always gets everything.

.EXAMPLE
    .\New-MigrationRecipients.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -TenantId newco.onmicrosoft.com -DryRun

    Rehearses wave one: reports which recipients would be created, which already exist and
    which members could not be mapped, and writes a DryRun results file.

.EXAMPLE
    .\New-MigrationRecipients.ps1 -PlanPath .\IdentityPlan.csv -Type Shared,Room -UseInterim -MailboxPermissionsCsv .\Contoso_MailboxPermissions.csv -TenantId newco.onmicrosoft.com -Prefix Contoso

    Stages the shared and resource mailboxes on newco.onmicrosoft.com and re-applies their
    FullAccess and SendAs grants with the trustees mapped to their destination accounts.

.EXAMPLE
    .\New-MigrationRecipients.ps1 -PlanPath .\IdentityPlan.csv -Mode UpdateSettings -GroupsCsv .\Contoso_Groups.csv -DelegatedOrganization newco.onmicrosoft.com

    GDAP alternative: as a partner administering the tenant through GDAP rather than signing in
    as a Global Admin in it. Leaves creation alone and patches owners, members, moderation and
    delivery restrictions onto groups that already exist in the customer tenant.

.NOTES
    Author:  AutomationHub
    Written with assistance from Claude (Anthropic).

    Exchange Online roles: Recipient Management is enough for everything here (New-Mailbox,
    New-DistributionGroup, New-DynamicDistributionGroup, New-MailContact, the matching Set-
    cmdlets, Add-DistributionGroupMember, Add-MailboxPermission, Add-RecipientPermission).
    Organization Management also works. No Graph session is needed.

    Sessions: Connect-MigrationExchange reuses any Exchange Online session already open in the
    shell, and no script disconnects. -TenantId is the guard against the source-tenant session
    Get-MigrationInventory left behind: it is compared with the organisation the session
    reports and a mismatch stops the run.

    GDAP: supported through -DelegatedOrganization, which is a delegated/interactive sign-in
    path. It cannot be combined with app-only certificate authentication. If GDAP claims are
    dropped during sign-in, connect with Connect-ExchangeOnline -DisableWAM first and re-run.

    Email address policies can reassert a primary SMTP address after this script adds
    aliases. This script never changes a primary address - Set-MigrationIdentity owns that,
    and it disables the policy on the object first.

    For a hybrid or directory-synced destination object, Exchange Online refuses
    EmailAddresses edits ('out of the current user's write scope'); the addresses have to be
    added to on-premises proxyAddresses and synced.

    Exit codes: 0 success, 1 fatal error, 2 completed with row failures.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [AllowNull()]
    [AllowEmptyCollection()]
    [string[]]$Wave,

    [ValidateSet('Shared', 'Room', 'Equipment', 'Distribution', 'MailEnabledSecurity', 'DynamicDistribution', 'Contact')]
    [string[]]$Type = @('Shared', 'Room', 'Equipment', 'Distribution', 'MailEnabledSecurity', 'DynamicDistribution', 'Contact'),

    [ValidateSet('Create', 'UpdateSettings', 'CreateAndUpdate')]
    [string]$Mode = 'CreateAndUpdate',

    [AllowNull()]
    [AllowEmptyString()]
    [string]$GroupsCsv,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$ContactsCsv,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$SharedMailboxesCsv,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$MailboxPermissionsCsv,

    [switch]$UseInterim,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$TenantId,

    [Alias('Tenant')]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$DelegatedOrganization,

    [switch]$IncludeCollisions,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$OutputPath,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$Prefix,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$LogPath,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Configuration -----------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$doCreate = $Mode -in @('Create', 'CreateAndUpdate')
$doUpdate = $Mode -in @('UpdateSettings', 'CreateAndUpdate')

# The group settings this script reproduces. Behaviour notes item 6: Get-DistributionGroup
# and Set-DistributionGroup read and write every one of them, so one cmdlet pair covers the
# whole list and the diff below can be driven off a single table.
$booleanGroupSetting = @(
    'HiddenFromAddressListsEnabled'
    'RequireSenderAuthenticationEnabled'
    'ModerationEnabled'
    'ReportToManagerEnabled'
)
$textGroupSetting = @(
    'MemberJoinRestriction'
    'MemberDepartRestriction'
)
$addressGroupSetting = @(
    'ManagedBy'
    'ModeratedBy'
    'AcceptMessagesOnlyFromSendersOrMembers'
    'GrantSendOnBehalfTo'
)

# ManagedBy, ModeratedBy, GrantSendOnBehalfTo and the delivery restrictions come back from
# Exchange as canonical names ('newco.com/Users/John Smith'), not addresses. The settings diff
# compares addresses, so each name is resolved through Get-Recipient once and remembered.
$recipientAddressCache = @{}
$resolveRecipientAddress = { param($Identity) Resolve-RecipientAddress -Identity $Identity -Cache $recipientAddressCache }

$script:results = [System.Collections.Generic.List[object]]::new()

#endregion Configuration --------------------------------------------------------------

#region Functions ---------------------------------------------------------------------

function ConvertTo-AddressArray {
    <#
    .SYNOPSIS
        Normalises anything that might hold a list of recipients into a string array.

    .DESCRIPTION
        The same logical field arrives in three shapes: a semicolon-delimited cell from an
        inventory CSV, a multi-valued Exchange property holding ADObjectId-ish objects, and
        a plain string from a hand-edited file. Normalising once here is what lets the
        settings diff compare desired against current without caring where either came from.

        Values are trimmed, empties dropped, an 'smtp:' prefix removed and the result
        de-duplicated case-insensitively while keeping the first spelling seen.

    .EXAMPLE
        ConvertTo-AddressArray -Value 'ap@contoso.com; smtp:accounts@contoso.com'

        Returns both addresses with the prefix stripped.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value) { return @() }

    $candidates = if ($Value -is [string]) {
        @(Split-MigrationList -Value $Value)
    }
    else {
        @(@($Value) | ForEach-Object { [string]$_ } | ForEach-Object { Split-MigrationList -Value $_ })
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        $text = ([string]$candidate).Trim() -replace '^(?i)smtp:', ''
        if (-not $text) { continue }
        if ($seen.Add($text)) { $result.Add($text) }
    }

    return $result.ToArray()
}

function Resolve-RecipientAddress {
    <#
    .SYNOPSIS
        Resolves an Exchange identity to its primary SMTP address, memoised per run.

    .DESCRIPTION
        ManagedBy, ModeratedBy, GrantSendOnBehalfTo and delivery-restriction members come
        back from Get-DistributionGroup/Get-Mailbox as ADObjectId-ish identities (for
        example 'newco.com/Users/John Smith'), not addresses, so the settings diff cannot
        compare them against the plan's address map until each one is looked up. -Cache
        keeps that lookup to at most once per identity for the whole run.

        A value that is already an address is returned unchanged without a lookup. A value
        that cannot be resolved is returned as-is too, so the diff still treats it as
        'something is there' rather than silently dropping it.

    .EXAMPLE
        Resolve-RecipientAddress -Identity 'newco.com/Users/John Smith' -Cache $cache

        Returns 'john.smith@newco.com', looking it up once and remembering the answer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Identity,
        [Parameter(Mandatory)][hashtable]$Cache
    )

    $text = [string]$Identity
    if (-not $text) { return '' }
    if ($text -match '^[^@\s]+@[^@\s]+$') { return $text }

    $lookup = $text.ToLowerInvariant()
    if ($Cache.ContainsKey($lookup)) { return $Cache[$lookup] }

    $resolved = $text
    try {
        $found = @(Get-Recipient -Identity $text -ErrorAction Stop)
        if ($found.Count -gt 0) {
            $primary = Get-MigrationCsvValue -Row $found[0] -Name 'PrimarySmtpAddress' -Default ''
            if ($primary) { $resolved = [string]$primary }
        }
    }
    catch {
        Write-MigrationLog -Message "Could not resolve recipient identity '$text' to an address: $($_.Exception.Message)" -Level DEBUG
    }

    $Cache[$lookup] = $resolved
    return $resolved
}

function ConvertTo-RecipientBoolean {
    <#
    .SYNOPSIS
        Parses an inventory cell into a boolean, or $null when it says nothing.

    .DESCRIPTION
        A blank cell is not $false. 'Not stated' has to stay distinguishable from
        'explicitly off', because the settings diff must leave a setting alone when the
        inventory has no opinion about it rather than switching it off.

    .EXAMPLE
        ConvertTo-RecipientBoolean -Value 'True'

        Returns $true. An empty string returns $null.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]$Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [bool]$Value }

    $text = ([string]$Value).Trim()
    if (-not $text) { return $null }
    if ($text -match '^(?i)(1|true|yes|y|enabled)$') { return $true }
    if ($text -match '^(?i)(0|false|no|n|disabled)$') { return $false }
    return $null
}

function Get-RowTargetAddress {
    <#
    .SYNOPSIS
        Returns the destination address a plan row should be created on.

    .DESCRIPTION
        Non-user recipients carry their address in the Interim/Target PrimarySmtp columns,
        with the UPN columns left empty; user rows populate both. Preferring the SMTP column
        and falling back to the UPN means the one function serves every row type, which is
        what the address map needs when it indexes users and recipients together.

    .EXAMPLE
        Get-RowTargetAddress -Row $row -UseInterim

        Returns 'accounts@newco.onmicrosoft.com' for the sample shared mailbox row.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Row,
        [switch]$UseInterim
    )

    $order = if ($UseInterim) {
        @('InterimPrimarySmtp', 'InterimUserPrincipalName', 'TargetPrimarySmtp', 'TargetUserPrincipalName')
    }
    else {
        @('TargetPrimarySmtp', 'TargetUserPrincipalName', 'InterimPrimarySmtp', 'InterimUserPrincipalName')
    }

    foreach ($column in $order) {
        $value = Get-MigrationCsvValue -Row $Row -Name $column -Default ''
        if ($value) { return $value }
    }

    return ''
}

function Resolve-MappedAddressList {
    <#
    .SYNOPSIS
        Translates a list of source addresses, keeping the failures visible.

    .DESCRIPTION
        Returns what could be mapped and what could not, separately, so the caller can apply
        the first and report the second. A list of forty members with one departed employee
        in it should still be created with thirty-nine.

    .EXAMPLE
        $members = Resolve-MappedAddressList -Value $row.Members -Map $map
        $members.Mapped
        $members.Unmapped

        Applies the mapped members and reports the rest.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][hashtable]$Map
    )

    $mapped = [System.Collections.Generic.List[string]]::new()
    $unmapped = [System.Collections.Generic.List[string]]::new()

    foreach ($address in (ConvertTo-AddressArray -Value $Value)) {
        $target = (Resolve-MigrationPlanAddress -Map $Map -Address $address).Address
        if ($target) {
            if (-not $mapped.Contains($target)) { $mapped.Add($target) }
        }
        elseif (-not $unmapped.Contains($address)) {
            $unmapped.Add($address)
        }
    }

    return [pscustomobject]@{
        Mapped   = $mapped.ToArray()
        Unmapped = $unmapped.ToArray()
    }
}

function ConvertTo-GroupSettingState {
    <#
    .SYNOPSIS
        Normalises a group object or inventory row into a comparable settings hashtable.

    .DESCRIPTION
        The desired state comes from a CSV and the current state comes from
        Get-DistributionGroup, so the two are the same settings in two different shapes.
        Both go through here, which is what lets Get-GroupSettingChange be a plain
        comparison rather than a pile of type checks - and what lets the diff be tested
        without an Exchange session.

        A setting the source object says nothing about is left out of the result entirely,
        not defaulted, so the diff can tell 'off' from 'not stated'.

        -Map and -Resolver serve opposite directions of the same problem: the desired side
        carries source-tenant addresses that -Map translates through the plan; the current
        side comes back from Exchange as ADObjectId-ish identities ('newco.com/Users/John
        Smith') that -Resolver turns into a primary SMTP address so the two sides can be
        compared as plain strings. Pass at most one.

    .EXAMPLE
        ConvertTo-GroupSettingState -InputObject $group -BooleanSetting $booleanGroupSetting -TextSetting $textGroupSetting -AddressSetting $addressGroupSetting

        Normalises a live Exchange group for comparison.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]$InputObject,
        [AllowNull()][AllowEmptyCollection()][string[]]$BooleanSetting = @(),
        [AllowNull()][AllowEmptyCollection()][string[]]$TextSetting = @(),
        [AllowNull()][AllowEmptyCollection()][string[]]$AddressSetting = @(),
        [AllowNull()][hashtable]$Map,
        [AllowNull()]$Resolver
    )

    $settings = [ordered]@{}
    $unmapped = [System.Collections.Generic.List[string]]::new()

    if ($null -ne $InputObject) {
        foreach ($name in @($BooleanSetting)) {
            # HiddenFromAddressLists is the inventory's spelling; the cmdlet parameter and
            # the Exchange property are both HiddenFromAddressListsEnabled.
            $raw = $null
            foreach ($candidate in @($name, ($name -replace 'Enabled$', ''))) {
                if ($InputObject.PSObject.Properties[$candidate]) {
                    $raw = $InputObject.PSObject.Properties[$candidate].Value
                    break
                }
            }
            $value = ConvertTo-RecipientBoolean -Value $raw
            if ($null -ne $value) { $settings[$name] = $value }
        }

        foreach ($name in @($TextSetting)) {
            $value = Get-MigrationCsvValue -Row $InputObject -Name $name -Default ''
            if ($value) { $settings[$name] = $value }
        }

        foreach ($name in @($AddressSetting)) {
            # AcceptMessagesOnlyFromSendersOrMembers is the cmdlet parameter; the inventory
            # shortens it to AcceptMessagesOnlyFrom.
            $raw = $null
            $aliases = @($name)
            if ($name -eq 'AcceptMessagesOnlyFromSendersOrMembers') { $aliases += 'AcceptMessagesOnlyFrom' }
            if ($name -eq 'ManagedBy') { $aliases += 'Owners' }
            foreach ($candidate in $aliases) {
                if ($InputObject.PSObject.Properties[$candidate]) {
                    $raw = $InputObject.PSObject.Properties[$candidate].Value
                    break
                }
            }
            if ($null -eq $raw) { continue }

            if ($Map) {
                $resolved = Resolve-MappedAddressList -Value $raw -Map $Map
                foreach ($miss in $resolved.Unmapped) {
                    if (-not $unmapped.Contains("${name}: $miss")) { $unmapped.Add("${name}: $miss") }
                }
                if ($resolved.Mapped.Count -gt 0) { $settings[$name] = $resolved.Mapped }
            }
            elseif ($Resolver) {
                # Exchange returns these as identities, not addresses ('newco.com/Users/John
                # Smith'), so each one is resolved to its primary SMTP address before the diff
                # ever compares it against the desired side.
                $resolvedAddresses = [System.Collections.Generic.List[string]]::new()
                foreach ($item in @($raw)) {
                    $resolvedAddress = [string](& $Resolver $item)
                    if (-not $resolvedAddress) { continue }
                    if (-not $resolvedAddresses.Contains($resolvedAddress)) { $resolvedAddresses.Add($resolvedAddress) }
                }
                if ($resolvedAddresses.Count -gt 0) { $settings[$name] = $resolvedAddresses.ToArray() }
            }
            else {
                # @() is load-bearing: the helper's array unrolls through the pipeline, so one
                # address arrives as a bare string and none as $null - .Count throws on both
                # under Set-StrictMode.
                $addresses = @(ConvertTo-AddressArray -Value $raw)
                if ($addresses.Count -gt 0) { $settings[$name] = $addresses }
            }
        }
    }

    return [pscustomobject]@{
        Settings = $settings
        Unmapped = $unmapped.ToArray()
    }
}

function Get-GroupSettingChange {
    <#
    .SYNOPSIS
        Returns only the settings that differ between desired and current state.

    .DESCRIPTION
        Sending the full settings block on every run would rewrite values a technician
        deliberately changed in the destination and would make the results file useless as a
        record of what actually moved. Only genuine differences are returned, and the result
        is already shaped as a Set-DistributionGroup parameter table so the caller can splat
        it.

        Address lists compare as case-insensitive sets: order is not meaningful to Exchange,
        so a reordered ManagedBy is not a change.

    .EXAMPLE
        $changes = Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings
        if ($changes.Count -gt 0) { Set-DistributionGroup -Identity $id @changes }

        Applies only what actually differs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Desired,
        [AllowNull()]$Current
    )

    $changes = @{}
    if ($null -eq $Desired) { return $changes }

    foreach ($name in @($Desired.Keys)) {
        $wanted = $Desired[$name]

        $existing = $null
        $hasExisting = $false
        if ($null -ne $Current -and $Current.Contains($name)) {
            $existing = $Current[$name]
            $hasExisting = $true
        }

        if ($wanted -is [array]) {
            $wantedSet = @(@($wanted) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
            $existingSet = @()
            if ($hasExisting -and $null -ne $existing) {
                $existingSet = @(@($existing) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
            }
            if (($wantedSet -join '|') -ne ($existingSet -join '|')) { $changes[$name] = $wanted }
        }
        elseif (-not $hasExisting -or [string]$existing -ne [string]$wanted) {
            $changes[$name] = $wanted
        }
    }

    return $changes
}

function Get-CsvIndex {
    <#
    .SYNOPSIS
        Indexes an inventory CSV by the addresses each row is known by.

    .DESCRIPTION
        Inventory rows have to be found from a plan row, and the only thing the two reliably
        share is an address. Indexing on every address column at once - primary SMTP, UPN,
        alias, display name - means a plan built from one export still joins to an inventory
        exported at a different time or by a different technician.

    .EXAMPLE
        $groupIndex = Get-CsvIndex -Rows $groupRows -KeyColumn 'PrimarySmtpAddress', 'DisplayName'

        Returns a hashtable keyed by lowercased address and display name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$KeyColumn
    )

    $index = @{}
    foreach ($row in @($Rows)) {
        foreach ($column in $KeyColumn) {
            $value = Get-MigrationCsvValue -Row $row -Name $column -Default ''
            if (-not $value) { continue }
            $lookup = $value.ToLowerInvariant()
            if (-not $index.ContainsKey($lookup)) { $index[$lookup] = $row }
        }
    }
    return $index
}

function Find-IndexedRow {
    <#
    .SYNOPSIS
        Looks a plan row up in an inventory index by any of its source addresses.

    .DESCRIPTION
        Tries the source primary SMTP, then the source UPN, then the display name, then each
        source alias, and returns the first inventory row that matches. Returns $null when
        the inventory has nothing for this plan row, which the caller reports rather than
        treating as an error - a settings CSV is optional.

    .EXAMPLE
        $inventoryRow = Find-IndexedRow -Row $planRow -Index $groupIndex

        Returns the matching Groups inventory row, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][hashtable]$Index
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($column in @('SourcePrimarySmtp', 'SourceUserPrincipalName', 'DisplayName')) {
        $value = Get-MigrationCsvValue -Row $Row -Name $column -Default ''
        if ($value) { $candidates.Add($value) }
    }
    foreach ($alias in (ConvertTo-AddressArray -Value (Get-MigrationCsvValue -Row $Row -Name 'SourceAliases' -Default ''))) {
        $candidates.Add($alias)
    }

    foreach ($candidate in $candidates) {
        $lookup = $candidate.ToLowerInvariant()
        if ($Index.ContainsKey($lookup)) { return $Index[$lookup] }
    }

    return $null
}

function Resolve-ContactExternalAddress {
    <#
    .SYNOPSIS
        Returns the address a mail contact should point at.

    .DESCRIPTION
        A mail contact is defined by the address outside both tenants that it forwards to,
        and that address lives in three places of decreasing authority.

        The Contacts inventory row is authoritative: ExternalEmailAddress is what the source
        tenant actually had. Failing that, the plan row carries it in SourceUserPrincipalName -
        a contact has no user principal name, so New-MigrationIdentityPlan parks the external
        address in that column, which keeps it out of SourcePrimarySmtp where the destination
        address is derived from. SourcePrimarySmtp is the last resort: it is the contact's
        address inside the source tenant, which is being decommissioned, so it is only ever
        right for a plan an operator hand-built without an inventory.

    .PARAMETER PlanRow
        The plan row for the contact.

    .PARAMETER InventoryRow
        The matching Contacts inventory row, or $null when no -ContactsCsv was supplied.

    .EXAMPLE
        Resolve-ContactExternalAddress -PlanRow $row -InventoryRow $inventoryRow

        Returns 'auditor@fabrikam.com' for a contact the Contacts inventory covers.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$PlanRow,
        [AllowNull()]$InventoryRow
    )

    if ($InventoryRow) {
        $address = Get-MigrationCsvValue -Row $InventoryRow -Name 'ExternalEmailAddress' -Default ''
        if ($address) { return [string]$address }
    }

    foreach ($column in @('SourceUserPrincipalName', 'SourcePrimarySmtp')) {
        $address = Get-MigrationCsvValue -Row $PlanRow -Name $column -Default ''
        if ($address) { return [string]$address }
    }

    return ''
}

function Get-PlanAliasAddress {
    <#
    .SYNOPSIS
        Returns the proxy addresses to add to a newly created recipient.

    .DESCRIPTION
        The target aliases from the plan plus the source object's LegacyExchangeDN as an
        X500 address. The X500 is what stops replies from cached Outlook entries and old
        calendar items bouncing with an IMCEAEX non-delivery report after the move, and it
        is the single most commonly forgotten step in a cross-tenant migration.

        The primary address is excluded so Exchange is never asked to add an address the
        object already holds as its primary.

    .EXAMPLE
        Get-PlanAliasAddress -Row $row -PrimaryAddress 'accounts@newco.com'

        Returns @('smtp:ap@newco.com', 'X500:/o=ExchangeLabs/...').
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Row,
        [AllowEmptyString()][string]$PrimaryAddress = ''
    )

    $addresses = [System.Collections.Generic.List[string]]::new()

    foreach ($alias in @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'TargetAliases' -Default ''))) {
        $text = $alias.Trim()
        if (-not $text) { continue }
        if ($text -notmatch '^(?i)(smtp:|x500:)') { $text = "smtp:$text" }
        if (($text -replace '^(?i)smtp:', '') -eq $PrimaryAddress) { continue }
        if (-not $addresses.Contains($text)) { $addresses.Add($text) }
    }

    # An explicit SourceX500 wins; the LegacyExchangeDN is only promoted when there is none.
    $x500 = Get-MigrationCsvValue -Row $Row -Name 'SourceX500' -Default ''
    if (-not $x500) { $x500 = Get-MigrationCsvValue -Row $Row -Name 'LegacyExchangeDN' -Default '' }
    foreach ($entry in @(ConvertTo-MigrationX500 -Value $x500)) {
        if (-not $addresses.Contains($entry)) { $addresses.Add($entry) }
    }

    return $addresses.ToArray()
}

function Invoke-SettingChange {
    <#
    .SYNOPSIS
        Applies a settings diff through one Set-* cmdlet and returns the names it changed.

    .DESCRIPTION
        Groups, mailboxes and contacts all reach Exchange the same way - splat the diff onto a
        Set-* cmdlet with an Identity - and having that in one place is what keeps the DryRun
        guarantee, the log wording and the SettingsChanged column consistent across all three.

    .EXAMPLE
        Invoke-SettingChange -Cmdlet 'Set-DistributionGroup' -Identity $targetAddress -Change $changes

        Applies the diff and returns @('ManagedBy', 'ModerationEnabled').
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The caller gates the row with ShouldProcess and Invoke-MigrationAction honours -DryRun.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Cmdlet and Change are consumed inside the Invoke-MigrationAction scriptblock, which the analyzer does not follow. The scriptblock exists so the call can be suppressed under -DryRun.')]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Cmdlet,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Identity,
        [Parameter(Mandatory)][AllowNull()][hashtable]$Change
    )

    if ($null -eq $Change -or $Change.Count -eq 0) { return @() }

    $names = @($Change.Keys | Sort-Object)
    $parameters = $Change.Clone()
    $parameters['Identity'] = $Identity
    $parameters['ErrorAction'] = 'Stop'

    $null = Invoke-MigrationAction -Description "Apply $($names -join ', ') to $Identity" -Action {
        & $Cmdlet @parameters
    }

    return [string[]]$names
}

function Add-ResultRow {
    <#
    .SYNOPSIS
        Appends one row to the run's results collection in the toolkit's standard shape.

    .DESCRIPTION
        Identity, Action, Status and Detail lead every results file in the toolkit. Building
        the rows in one place is what keeps that true across the dozen places this script
        reports an outcome from.

    .EXAMPLE
        Add-ResultRow -Identity $identity -Action 'CreateRecipient' -Status 'Succeeded' -Detail 'Shared mailbox created.'

        Records a successful creation.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Planned', 'Succeeded', 'Skipped', 'Failed')][string]$Status,
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$ObjectType = '',
        [AllowEmptyString()][string]$PlanStatus = '',
        [AllowEmptyString()][string]$TargetAddress = '',
        [AllowEmptyString()][string]$TargetObjectId = '',
        [AllowEmptyString()][string]$SettingsChanged = '',
        [AllowEmptyString()][string]$MembersAdded = '',
        [AllowEmptyString()][string]$Unmappable = ''
    )

    $script:results.Add([pscustomobject][ordered]@{
            Identity        = $Identity
            Action          = $Action
            Status          = $Status
            Detail          = $Detail
            ObjectType      = $ObjectType
            PlanStatus      = $PlanStatus
            TargetAddress   = $TargetAddress
            TargetObjectId  = $TargetObjectId
            SettingsChanged = $SettingsChanged
            MembersAdded    = $MembersAdded
            Unmappable      = $Unmappable
        })
}

#endregion Functions ------------------------------------------------------------------

#region Main --------------------------------------------------------------------------

$null = Initialize-MigrationRun -ScriptName 'New-MigrationRecipients' -OutputPath $OutputPath -Prefix $Prefix `
    -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    # The whole plan is read, not just the wave: Save-MigrationPlan rewrites the file in
    # full, and the address map needs members who live in waves this run is not touching.
    $planRows = @(Import-MigrationPlan -Path $PlanPath)
}
catch {
    Write-MigrationLog -Message $_.Exception.Message -Level ERROR
    exit (Complete-MigrationRun -ExitCode 1)
}

$waveRows = @(Select-MigrationPlanRows -Rows $planRows -Wave $Wave -ObjectType $Type -IncludeExcluded)
if ($waveRows.Count -eq 0) {
    Write-MigrationLog -Message ("No plan rows match wave '$($Wave -join ', ')' and type '$($Type -join ', ')'. " +
        "Check the Wave and ObjectType values in $PlanPath.") -Level ERROR
    exit (Complete-MigrationRun -ExitCode 1)
}
Write-MigrationLog -Message "Processing $($waveRows.Count) plan row(s) in mode $Mode." -Level INFO

$addressMap = Get-MigrationPlanAddressMap -Rows $planRows -UseInterim:$UseInterim
Write-MigrationLog -Message "Address map holds $($addressMap.Count) source address(es)." -Level INFO

$groupIndex = @{}
$contactIndex = @{}
$mailboxIndex = @{}
$permissionsBySource = @{}

foreach ($csv in @(
        @{ Path = $GroupsCsv; Label = 'Groups' }
        @{ Path = $ContactsCsv; Label = 'Contacts' }
        @{ Path = $SharedMailboxesCsv; Label = 'Mailboxes' }
        @{ Path = $MailboxPermissionsCsv; Label = 'MailboxPermissions' }
    )) {
    if (-not $csv.Path) { continue }
    try {
        $rows = @(Import-MigrationCsv -Path $csv.Path)
        switch ($csv.Label) {
            'Groups' { $groupIndex = Get-CsvIndex -Rows $rows -KeyColumn 'PrimarySmtpAddress', 'DisplayName', 'Alias' }
            'Contacts' { $contactIndex = Get-CsvIndex -Rows $rows -KeyColumn 'PrimarySmtpAddress', 'ExternalEmailAddress', 'DisplayName', 'Alias' }
            'Mailboxes' { $mailboxIndex = Get-CsvIndex -Rows $rows -KeyColumn 'PrimarySmtpAddress', 'UserPrincipalName', 'DisplayName', 'Alias' }
            'MailboxPermissions' {
                foreach ($permission in $rows) {
                    $mailbox = Get-MigrationCsvValue -Row $permission -Name 'MailboxPrimarySmtp' -Default ''
                    if (-not $mailbox) { continue }
                    $lookup = $mailbox.ToLowerInvariant()
                    if (-not $permissionsBySource.ContainsKey($lookup)) {
                        $permissionsBySource[$lookup] = [System.Collections.Generic.List[object]]::new()
                    }
                    $permissionsBySource[$lookup].Add($permission)
                }
            }
        }
        Write-MigrationLog -Message "Loaded $($rows.Count) row(s) from the $($csv.Label) inventory." -Level INFO
    }
    catch {
        Write-MigrationLog -Message "Could not read the $($csv.Label) inventory '$($csv.Path)': $($_.Exception.Message)" -Level ERROR
        exit (Complete-MigrationRun -ExitCode 1)
    }
}

if ($doUpdate -and -not $GroupsCsv -and @($Type | Where-Object { $_ -in @('Distribution', 'MailEnabledSecurity', 'DynamicDistribution') }).Count -gt 0) {
    Write-MigrationLog -Message ('No -GroupsCsv was supplied, so group owners, members, moderation and delivery ' +
        'restrictions cannot be applied. Aliases from the plan are still applied.') -Level WARNING
}

try {
    $exchangeConnection = Connect-MigrationExchange -DelegatedOrganization $DelegatedOrganization
}
catch {
    Write-MigrationLog -Message $_.Exception.Message -Level ERROR
    exit (Complete-MigrationRun -ExitCode 1)
}

# Connect-MigrationExchange reuses whatever Exchange Online session is already open in the
# shell, and nothing in this toolkit disconnects one - a source-tenant session left behind by
# Get-MigrationInventory would otherwise be reused here silently. -DelegatedOrganization is
# already checked by Connect-MigrationExchange itself; -TenantId is the same check for the
# primary, non-GDAP path. Connect-MigrationExchange now accepts its own -TenantId (GUID form)
# and would reconnect silently on a mismatch, but a live recipient-creation run is kept as a
# hard stop instead - re-run after confirming the tenant rather than having the script pick a
# session for you.
if ($TenantId -and $exchangeConnection) {
    $connectedOrganization = Get-MigrationCsvValue -Row $exchangeConnection -Name 'Organization' -Default ''
    $connectedTenantId = Get-MigrationCsvValue -Row $exchangeConnection -Name 'TenantId' -Default ''
    $tenantMatches = ($connectedOrganization -and $connectedOrganization -eq $TenantId) -or
        ($connectedTenantId -and $connectedTenantId -eq $TenantId)
    if (-not $tenantMatches -and ($connectedOrganization -or $connectedTenantId)) {
        $connectedAs = if ($connectedOrganization) { $connectedOrganization } else { $connectedTenantId }
        Write-MigrationLog -Message ("Connected to '$connectedAs' but -TenantId asked for '$TenantId'. Stopping before " +
            'the first row rather than creating recipients in the wrong tenant. Disconnect-ExchangeOnline and re-run.') `
            -Level ERROR
        exit (Complete-MigrationRun -ExitCode 1)
    }
}

$planChanged = $false
$planSaveFailed = $false
$resultsExported = $false
$exitCode = 0
$rowIndex = 0

# Import-MigrationPlan materialises every canonical plan column, so these are normally already
# present. The guard costs one property lookup per row and removes a whole class of failure:
# under Set-StrictMode -Version Latest, assigning a property the object does not carry throws,
# and these write-backs happen inside the per-row catch - where a second exception would hide
# the error the operator actually has to read.
foreach ($row in $waveRows) {
    foreach ($column in @('TargetObjectId', 'ProvisionStatus', 'ProvisionDetail')) {
        if (-not $row.PSObject.Properties[$column]) {
            $row | Add-Member -NotePropertyName $column -NotePropertyValue '' -Force
        }
    }
}

# Everything from here to the finally block is inside one try: an exception outside the per-row
# catch (a dropped Exchange session, a throttled tenant) must still leave the operator with the
# plan write-back for the recipients already created and a results file for the rows already
# processed. Losing either turns a partial run into a manual reconciliation.
try {

    foreach ($row in $waveRows) {
        $rowIndex++

        $objectType = Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default ''
        $planStatus = Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default ''
        $displayName = Get-MigrationCsvValue -Row $row -Name 'DisplayName' -Default ''

        $identity = Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default ''
        if (-not $identity) { $identity = Get-MigrationCsvValue -Row $row -Name 'SourceUserPrincipalName' -Default '' }
        if (-not $identity) { $identity = $displayName }
        if (-not $identity) { $identity = "(plan row $rowIndex)" }

        Write-Progress -Activity 'Creating destination recipients' -Status "$rowIndex of $($waveRows.Count): $identity" `
            -PercentComplete (($rowIndex / [math]::Max($waveRows.Count, 1)) * 100)

        $common = @{ Identity = $identity; ObjectType = $objectType; PlanStatus = $planStatus }

        # -AllowSynced: this script creates fresh destination objects, so the source object's
        # directory-sync state is not a reason to skip the row.
        $gate = Test-MigrationPlanRowActionable -Row $row -IncludeCollisions:$IncludeCollisions -AllowSynced
        if (-not $gate.Actionable) {
            $detail = $gate.Reason
            if ($planStatus -eq 'Collision') { $detail += ' Re-run with -IncludeCollisions to process it.' }
            Add-ResultRow @common -Action 'CreateRecipient' -Status $gate.Status -Detail $detail
            continue
        }

        $targetAddress = ''
        $recipient = $null
        $targetObjectId = ''
        # The catch below reports whichever phase was running, so a settings failure is not filed as a
        # creation failure and re-run as one.
        $phase = 'CreateRecipient'

        try {
            $targetAddress = Get-RowTargetAddress -Row $row -UseInterim:$UseInterim
            if (-not $targetAddress) { throw 'The plan row has no interim or target primary SMTP address.' }

            $addressCheck = Test-MigrationAddress -Address $targetAddress -Kind 'Smtp'
            if (-not $addressCheck.IsValid) { throw "'$targetAddress' is not a usable SMTP address: $($addressCheck.Reason)" }

            if (-not $displayName) { throw 'The plan row has no DisplayName, which every recipient type requires.' }

            $alias = Get-MigrationCsvValue -Row $row -Name 'TargetMailNickname' -Default ''
            if (-not $alias) { $alias = ($targetAddress -split '@')[0] }

            #-- Does it already exist? --------------------------------------------------------
            # A hit is only adopted when it is plausibly this row's object - matching on Name or
            # Alias alone would let an unrelated destination object with the same nickname be
            # recorded as this row's TargetObjectId and then have this row's settings applied to
            # it. RecipientTypeDetails must match what this row would create; a hit found only
            # through the alias candidate (not the target address itself) must also carry the
            # row's DisplayName.
            $expectedRecipientTypeDetails = switch ($objectType) {
                'Shared' { 'SharedMailbox' }
                'Room' { 'RoomMailbox' }
                'Equipment' { 'EquipmentMailbox' }
                'Distribution' { 'MailUniversalDistributionGroup' }
                'MailEnabledSecurity' { 'MailUniversalSecurityGroup' }
                'DynamicDistribution' { 'DynamicDistributionGroup' }
                'Contact' { 'MailContact' }
                default { '' }
            }
            $recipientAdoptedByAliasOnly = $false

            foreach ($candidate in @($targetAddress, $alias)) {
                if ($recipient) { break }
                try {
                    $found = @(Get-Recipient -Identity $candidate -ErrorAction Stop)
                    if ($found.Count -gt 0) {
                        $recipient = $found[0]
                        $recipientAdoptedByAliasOnly = ($candidate -eq $alias -and $candidate -ne $targetAddress)
                    }
                }
                catch {
                    # 'Not found' is the expected answer for a recipient that does not exist yet.
                    # Anything else - throttling, a dropped session, a permission problem - must not be
                    # read as 'does not exist', because the next step would then create a duplicate.
                    $lookupError = [string]$_.Exception.Message
                    $isNotFound = $lookupError -match "(?i)couldn't be found|could not be found|wasn't found|was not found|not found on"
                    if (-not $isNotFound) {
                        throw ("Could not determine whether '$candidate' already exists in the destination " +
                            "tenant, so nothing was created: $lookupError")
                    }
                    Write-MigrationLog -Message "No destination recipient matches '$candidate'." -Level DEBUG
                }
            }

            if ($recipient) {
                $hitTypeDetails = Get-MigrationCsvValue -Row $recipient -Name 'RecipientTypeDetails' -Default ''
                if ($expectedRecipientTypeDetails -and $hitTypeDetails -and $hitTypeDetails -ne $expectedRecipientTypeDetails) {
                    throw ("An existing recipient matches '$targetAddress' or alias '$alias' but is a " +
                        "$hitTypeDetails, not the $objectType type this row would create ($expectedRecipientTypeDetails). " +
                        'Not adopting it - rename the plan row''s target address or alias, or remove the conflicting object.')
                }
                if ($recipientAdoptedByAliasOnly) {
                    $hitDisplayName = Get-MigrationCsvValue -Row $recipient -Name 'DisplayName' -Default ''
                    if ($hitDisplayName -ne $displayName) {
                        throw ("Alias '$alias' is already used by '$hitDisplayName' in the destination tenant, which " +
                            "does not match this row's DisplayName '$displayName'. Not adopting it.")
                    }
                }

                $targetObjectId = Get-MigrationCsvValue -Row $recipient -Name 'ExternalDirectoryObjectId' -Default ''
                if (-not $targetObjectId) { $targetObjectId = Get-MigrationCsvValue -Row $recipient -Name 'Guid' -Default '' }
            }

            # Every subsequent Set-*/Add-* call targets the object by its own identity rather than
            # by $targetAddress: an adopted object (found via the alias candidate, or a vendor
            # placeholder not yet pointed at the vanity domain) does not necessarily hold
            # $targetAddress at all. $targetAddress is kept only for reporting and for the create
            # call, which is what establishes it in the first place.
            $recipientIdentity = $targetAddress
            if ($targetObjectId) { $recipientIdentity = $targetObjectId }

            #-- Create ------------------------------------------------------------------------
            if ($doCreate -and -not $recipient) {
                if (-not $PSCmdlet.ShouldProcess($targetAddress, "Create $objectType recipient")) {
                    Add-ResultRow @common -Action 'CreateRecipient' -Status 'Skipped' -Detail 'Declined at the confirmation prompt.' `
                        -TargetAddress $targetAddress
                    continue
                }

                $createParameters = @{ Name = $displayName; DisplayName = $displayName; Alias = $alias; ErrorAction = 'Stop' }
                $createDescription = "Create $objectType recipient $targetAddress"

                switch ($objectType) {
                    { $_ -in @('Shared', 'Room', 'Equipment') } {
                        $createParameters['PrimarySmtpAddress'] = $targetAddress
                        $createParameters[$objectType] = $true
                        $created = Invoke-MigrationAction -Description $createDescription -PassThru -Action {
                            New-Mailbox @createParameters
                        }
                    }
                    { $_ -in @('Distribution', 'MailEnabledSecurity') } {
                        $createParameters['PrimarySmtpAddress'] = $targetAddress
                        $createParameters['Type'] = if ($objectType -eq 'MailEnabledSecurity') { 'Security' } else { 'Distribution' }
                        $created = Invoke-MigrationAction -Description $createDescription -PassThru -Action {
                            New-DistributionGroup @createParameters
                        }
                    }
                    'DynamicDistribution' {
                        $inventoryRow = Find-IndexedRow -Row $row -Index $groupIndex
                        $recipientFilter = if ($inventoryRow) { Get-MigrationCsvValue -Row $inventoryRow -Name 'RecipientFilter' -Default '' } else { '' }
                        if (-not $recipientFilter) {
                            throw ('A dynamic distribution group needs its RecipientFilter, which is only in the Groups ' +
                                'inventory. Supply -GroupsCsv, or create this group by hand.')
                        }
                        $createParameters['PrimarySmtpAddress'] = $targetAddress
                        $createParameters['RecipientFilter'] = $recipientFilter
                        $created = Invoke-MigrationAction -Description $createDescription -PassThru -Action {
                            New-DynamicDistributionGroup @createParameters
                        }
                    }
                    'Contact' {
                        $inventoryRow = Find-IndexedRow -Row $row -Index $contactIndex
                        $externalAddress = Resolve-ContactExternalAddress -PlanRow $row -InventoryRow $inventoryRow
                        if (-not $externalAddress) {
                            throw ('A mail contact needs an ExternalEmailAddress. Supply -ContactsCsv, or put the ' +
                                'external address in the plan row SourceUserPrincipalName column.')
                        }
                        # Deliberately not mapped: a contact points at someone outside both tenants.
                        # PrimarySmtpAddress is the contact's own address inside this tenant - without
                        # it the contact's primary address defaults to ExternalEmailAddress, and every
                        # later Set-MailContact/Add-DistributionGroupMember targeting $targetAddress
                        # would then find nothing.
                        $createParameters['ExternalEmailAddress'] = $externalAddress
                        $createParameters['PrimarySmtpAddress'] = $targetAddress
                        $created = Invoke-MigrationAction -Description $createDescription -PassThru -Action {
                            New-MailContact @createParameters
                        }
                    }
                    default {
                        throw "ObjectType '$objectType' is not created by this script."
                    }
                }

                if ($DryRun) {
                    Add-ResultRow @common -Action 'CreateRecipient' -Status 'Planned' -TargetAddress $targetAddress `
                        -Detail "Would create a $objectType recipient named '$displayName' with alias '$alias'."
                }
                else {
                    # The created object becomes the 'current' state for the settings diff, so a
                    # brand-new group is compared against what Exchange actually gave it rather
                    # than against nothing - which would resend defaults Exchange already applied.
                    $recipient = $created
                    $targetObjectId = Get-MigrationCsvValue -Row $created -Name 'ExternalDirectoryObjectId' -Default ''
                    if (-not $targetObjectId) { $targetObjectId = Get-MigrationCsvValue -Row $created -Name 'Guid' -Default '' }
                    if ($targetObjectId) { $recipientIdentity = $targetObjectId }

                    $row.TargetObjectId = $targetObjectId
                    $row.ProvisionStatus = 'Created'
                    $row.ProvisionDetail = "Created as a $objectType recipient on $targetAddress."
                    $planChanged = $true

                    Add-ResultRow @common -Action 'CreateRecipient' -Status 'Succeeded' -TargetAddress $targetAddress `
                        -TargetObjectId $targetObjectId -Detail "Created a $objectType recipient named '$displayName'."
                }
            }
            elseif ($doCreate) {
                $row.TargetObjectId = $targetObjectId
                $row.ProvisionStatus = 'Exists'
                $row.ProvisionDetail = "Already present in the destination tenant as $targetAddress."
                $planChanged = $true
                Add-ResultRow @common -Action 'CreateRecipient' -Status 'Skipped' -TargetAddress $targetAddress `
                    -TargetObjectId $targetObjectId -Detail 'Already exists in the destination tenant; recorded its object ID.'
            }

            #-- Update settings ---------------------------------------------------------------
            if (-not $doUpdate) { continue }
            $phase = 'UpdateSettings'

            if (-not $recipient -and -not $doCreate) {
                Add-ResultRow @common -Action 'UpdateSettings' -Status 'Skipped' -TargetAddress $targetAddress `
                    -Detail "No recipient matches '$targetAddress' in the destination tenant. Run with -Mode CreateAndUpdate first."
                continue
            }

            if (-not $recipient -and $DryRun) {
                Add-ResultRow @common -Action 'UpdateSettings' -Status 'Planned' -TargetAddress $targetAddress `
                    -Detail 'Settings would be applied after the recipient is created.'
                continue
            }

            if (-not $PSCmdlet.ShouldProcess($targetAddress, "Update $objectType settings")) {
                Add-ResultRow @common -Action 'UpdateSettings' -Status 'Skipped' -TargetAddress $targetAddress `
                    -TargetObjectId $targetObjectId -Detail 'Declined at the confirmation prompt.'
                continue
            }

            $updateDetail = [System.Collections.Generic.List[string]]::new()
            $unmappable = [System.Collections.Generic.List[string]]::new()
            $settingsChanged = [System.Collections.Generic.List[string]]::new()
            $membersAdded = 0
            # Set by any settings step that caught an exception. Those steps continue so the rest of the
            # row is still applied, but the row is reported Failed rather than Succeeded-with-a-note.
            $rowFailed = $false

            $setCmdlet = switch ($objectType) {
                { $_ -in @('Shared', 'Room', 'Equipment') } { 'Set-Mailbox' }
                { $_ -in @('Distribution', 'MailEnabledSecurity') } { 'Set-DistributionGroup' }
                'DynamicDistribution' { 'Set-DynamicDistributionGroup' }
                'Contact' { 'Set-MailContact' }
                default { '' }
            }
            $getCmdlet = switch ($objectType) {
                { $_ -in @('Shared', 'Room', 'Equipment') } { 'Get-Mailbox' }
                { $_ -in @('Distribution', 'MailEnabledSecurity') } { 'Get-DistributionGroup' }
                'DynamicDistribution' { 'Get-DynamicDistributionGroup' }
                'Contact' { 'Get-MailContact' }
                default { '' }
            }

            # Get-Recipient - what $recipient holds - does not reliably return every
            # object-specific property (Microsoft Learn: 'use the corresponding cmdlet, for
            # example Get-Mailbox or Get-DistributionGroup'). ManagedBy, ModeratedBy and the
            # rest of the settings diff need the typed cmdlet's full view, or every one of
            # those settings looks 'not stated' and gets resent on every run. A re-read
            # failure (a permission gap, a dropped session) falls back to $recipient rather
            # than failing the whole row - the diff is then best-effort, same as before this
            # fix, instead of losing the row entirely.
            $liveRecipient = $recipient
            if ($getCmdlet -and $recipient) {
                try {
                    $liveRecipient = & $getCmdlet -Identity $recipientIdentity -ErrorAction Stop
                }
                catch {
                    Write-MigrationLog -Message ("Could not re-read '$targetAddress' with $getCmdlet for the settings " +
                        "comparison; using the Get-Recipient result instead: $($_.Exception.Message)") -Level WARNING
                }
            }

            #-- Aliases and the X500 address --------------------------------------------------
            $aliasAddresses = @(Get-PlanAliasAddress -Row $row -PrimaryAddress $targetAddress)
            if ($aliasAddresses.Count -gt 0 -and $setCmdlet) {
                $aliasParameters = @{ Identity = $recipientIdentity; EmailAddresses = @{ Add = $aliasAddresses }; ErrorAction = 'Stop' }
                $null = Invoke-MigrationAction -Description "Add $($aliasAddresses.Count) proxy address(es) to $targetAddress" -Action {
                    & $setCmdlet @aliasParameters
                }
                $settingsChanged.Add('EmailAddresses')
                $updateDetail.Add("Proxy addresses added: $($aliasAddresses -join ', ').")
            }

            #-- Settings from the inventory ---------------------------------------------------
            if ($objectType -in @('Distribution', 'MailEnabledSecurity', 'DynamicDistribution')) {
                $inventoryRow = Find-IndexedRow -Row $row -Index $groupIndex
                if (-not $inventoryRow) {
                    if ($GroupsCsv) { $updateDetail.Add('No matching row in the Groups inventory; settings left alone.') }
                }
                else {
                    $desired = ConvertTo-GroupSettingState -InputObject $inventoryRow -BooleanSetting $booleanGroupSetting `
                        -TextSetting $textGroupSetting -AddressSetting $addressGroupSetting -Map $addressMap
                    foreach ($miss in $desired.Unmapped) { $unmappable.Add($miss) }

                    # A dynamic group has no membership to restrict, so those two settings are
                    # dropped rather than sent and rejected.
                    if ($objectType -eq 'DynamicDistribution') {
                        foreach ($name in @('MemberJoinRestriction', 'MemberDepartRestriction')) {
                            if ($desired.Settings.Contains($name)) { $desired.Settings.Remove($name) }
                        }
                    }

                    $current = ConvertTo-GroupSettingState -InputObject $liveRecipient -BooleanSetting $booleanGroupSetting `
                        -TextSetting $textGroupSetting -AddressSetting $addressGroupSetting -Resolver $resolveRecipientAddress
                    $changes = Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings

                    if ($changes.Count -gt 0 -and $setCmdlet) {
                        foreach ($name in (Invoke-SettingChange -Cmdlet $setCmdlet -Identity $recipientIdentity -Change $changes)) {
                            $settingsChanged.Add($name)
                        }
                    }
                    elseif ($changes.Count -eq 0) {
                        $updateDetail.Add('Settings already match the source.')
                    }

                    #-- Members ---------------------------------------------------------------
                    if ($objectType -in @('Distribution', 'MailEnabledSecurity')) {
                        $members = Resolve-MappedAddressList -Value (Get-MigrationCsvValue -Row $inventoryRow -Name 'Members' -Default '') -Map $addressMap
                        foreach ($miss in $members.Unmapped) { $unmappable.Add("Members: $miss") }

                        $existingMembers = @()
                        try {
                            $existingMembers = @(Get-DistributionGroupMember -Identity $recipientIdentity -ResultSize Unlimited -ErrorAction Stop |
                                    ForEach-Object { [string](Get-MigrationCsvValue -Row $_ -Name 'PrimarySmtpAddress' -Default '') } |
                                    Where-Object { $_ })
                        }
                        catch {
                            $updateDetail.Add("Could not read the current membership: $($_.Exception.Message)")
                            $rowFailed = $true
                        }

                        foreach ($member in $members.Mapped) {
                            if ($existingMembers -contains $member) { continue }
                            try {
                                $null = Invoke-MigrationAction -Description "Add $member to $targetAddress" -Action {
                                    Add-DistributionGroupMember -Identity $recipientIdentity -Member $member -BypassSecurityGroupManagerCheck -ErrorAction Stop
                                }
                                $membersAdded++
                            }
                            catch {
                                $updateDetail.Add("Member '$member' not added: $($_.Exception.Message)")
                                $rowFailed = $true
                            }
                        }
                    }
                }
            }

            #-- Shared and resource mailbox settings ------------------------------------------
            if ($objectType -in @('Shared', 'Room', 'Equipment')) {
                $inventoryRow = Find-IndexedRow -Row $row -Index $mailboxIndex
                if ($inventoryRow) {
                    $desired = ConvertTo-GroupSettingState -InputObject $inventoryRow `
                        -BooleanSetting @('HiddenFromAddressListsEnabled') -AddressSetting @('GrantSendOnBehalfTo') -Map $addressMap
                    foreach ($miss in $desired.Unmapped) { $unmappable.Add($miss) }

                    $current = ConvertTo-GroupSettingState -InputObject $liveRecipient `
                        -BooleanSetting @('HiddenFromAddressListsEnabled') -AddressSetting @('GrantSendOnBehalfTo') -Resolver $resolveRecipientAddress
                    $changes = Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings

                    foreach ($name in (Invoke-SettingChange -Cmdlet 'Set-Mailbox' -Identity $recipientIdentity -Change $changes)) {
                        $settingsChanged.Add($name)
                    }
                }

                #-- FullAccess and SendAs ------------------------------------------------------
                $sourceAddress = Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default ''
                $sourceLookup = if ($sourceAddress) { $sourceAddress.ToLowerInvariant() } else { '' }
                if ($sourceLookup -and $permissionsBySource.ContainsKey($sourceLookup)) {
                    foreach ($permission in $permissionsBySource[$sourceLookup]) {
                        $right = Get-MigrationCsvValue -Row $permission -Name 'Permission' -Default ''
                        if ($right -notin @('FullAccess', 'SendAs')) { continue }

                        $trustee = (Resolve-MigrationPlanAddress -Map $addressMap `
                                -Address (Get-MigrationCsvValue -Row $permission -Name 'Trustee' -Default '')).Address
                        if (-not $trustee) {
                            $rawTrustee = Get-MigrationCsvValue -Row $permission -Name 'Trustee' -Default '(blank)'
                            $unmappable.Add("${right}: $rawTrustee")
                            continue
                        }

                        try {
                            if ($right -eq 'FullAccess') {
                                $null = Invoke-MigrationAction -Description "Grant FullAccess on $targetAddress to $trustee" -Action {
                                    Add-MailboxPermission -Identity $recipientIdentity -User $trustee -AccessRights FullAccess `
                                        -AutoMapping $true -ErrorAction Stop
                                }
                            }
                            else {
                                $null = Invoke-MigrationAction -Description "Grant SendAs on $targetAddress to $trustee" -Action {
                                    Add-RecipientPermission -Identity $recipientIdentity -Trustee $trustee -AccessRights SendAs `
                                        -Confirm:$false -ErrorAction Stop
                                }
                            }
                            $settingsChanged.Add($right)
                        }
                        catch {
                            $updateDetail.Add("$right for '$trustee' failed: $($_.Exception.Message)")
                            $rowFailed = $true
                        }
                    }
                }
            }

            #-- Contact settings --------------------------------------------------------------
            if ($objectType -eq 'Contact') {
                $inventoryRow = Find-IndexedRow -Row $row -Index $contactIndex
                if ($inventoryRow) {
                    $desired = ConvertTo-GroupSettingState -InputObject $inventoryRow -BooleanSetting @('HiddenFromAddressListsEnabled')
                    $current = ConvertTo-GroupSettingState -InputObject $liveRecipient -BooleanSetting @('HiddenFromAddressListsEnabled')
                    $changes = Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings
                    foreach ($name in (Invoke-SettingChange -Cmdlet 'Set-MailContact' -Identity $recipientIdentity -Change $changes)) {
                        $settingsChanged.Add($name)
                    }
                }
            }

            if ($unmappable.Count -gt 0) {
                $updateDetail.Add("Not in the plan, so left off: $($unmappable.Count) address(es).")
            }
            if ($settingsChanged.Count -eq 0 -and $membersAdded -eq 0 -and $updateDetail.Count -eq 0) {
                $updateDetail.Add('Nothing to change.')
            }

            $status = if ($rowFailed) { 'Failed' } elseif ($DryRun) { 'Planned' } else { 'Succeeded' }
            Add-ResultRow @common -Action 'UpdateSettings' -Status $status -TargetAddress $targetAddress `
                -TargetObjectId $targetObjectId -Detail ($updateDetail -join ' ') `
                -SettingsChanged (Join-MigrationList -Values $settingsChanged.ToArray()) `
                -MembersAdded ([string]$membersAdded) `
                -Unmappable (Join-MigrationList -Values $unmappable.ToArray())
        }
        catch {
            $message = $_.Exception.Message
            $row.ProvisionStatus = 'Failed'
            $row.ProvisionDetail = $message
            $planChanged = $true
            Write-MigrationLog -Message "$identity - $message" -Level ERROR
            Add-ResultRow @common -Action $phase -Status 'Failed' -Detail $message -TargetAddress $targetAddress
        }
    }
}
catch {
    # Anything that escapes the per-row catch ends the run, but not before the two artefacts it
    # has already earned are written by the finally block below.
    Write-MigrationLog -Message "Fatal error: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message $_.ScriptStackTrace -Level DEBUG
    $exitCode = 1
}
finally {
    Write-Progress -Activity 'Creating destination recipients' -Completed

    if ($planChanged) {
        try {
            $null = Invoke-MigrationAction -Description "Write provisioning results back to $PlanPath" -Action {
                Save-MigrationPlan -Path $PlanPath -Rows $planRows
            }
        }
        catch {
            # Losing the write-back loses the TargetObjectIds this run just earned, so it is a failed
            # run even when every row succeeded.
            Write-MigrationLog -Message ("Could not write the plan back to $PlanPath, so the object IDs " +
                "recorded by this run are only in the results file: $($_.Exception.Message)") -Level ERROR
            $planSaveFailed = $true
        }
    }

    # The flag is what keeps a fatal run from producing two results files for one run: whoever
    # exports first sets it, and this block then leaves the file alone.
    if (-not $resultsExported) {
        try {
            $null = Export-MigrationResult -Rows $script:results.ToArray() -Name 'New-Recipients'
            $resultsExported = $true
        }
        catch {
            # The run is already ending; a results file that cannot be written must not mask the
            # reason it ended, so the failure is logged and the exit code stands.
            Write-MigrationLog -Message "Could not write the results file: $($_.Exception.Message)" -Level ERROR
        }
    }
}

#endregion Main -----------------------------------------------------------------------

#region Cleanup -----------------------------------------------------------------------

# A fatal error already set 1; row failures and a lost write-back are the softer exit 2.
if ($exitCode -eq 0 -and ($planSaveFailed -or @($script:results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0)) {
    $exitCode = 2
}
exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion Cleanup --------------------------------------------------------------------
