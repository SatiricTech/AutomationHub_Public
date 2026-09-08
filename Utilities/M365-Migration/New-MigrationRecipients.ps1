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
    the settings are applied on top of them.

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

    -DryRun connects read-only, evaluates every row, and writes a results file whose rows
    are all Status 'Planned'. Nothing is created or changed and the plan is not written back.

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
    The source tenant's Mailboxes inventory CSV. Supplies HiddenFromAddressLists and
    GrantSendOnBehalfTo for shared, room and equipment mailboxes.

.PARAMETER MailboxPermissionsCsv
    The source tenant's MailboxPermissions inventory CSV. When supplied, FullAccess and
    SendAs grants on the created shared and resource mailboxes are re-applied with their
    trustees mapped through the plan. Omit it to leave delegation entirely to
    Set-MigrationMailboxPermissions.

.PARAMETER UseInterim
    Uses each row's InterimPrimarySmtp instead of TargetPrimarySmtp. Use this while the
    vanity domain still belongs to the source tenant.

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
    .\New-MigrationRecipients.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -DryRun

    Rehearses wave one: reports which recipients would be created, which already exist and
    which members could not be mapped, and writes a DryRun results file.

.EXAMPLE
    .\New-MigrationRecipients.ps1 -PlanPath .\IdentityPlan.csv -Type Shared,Room -UseInterim -MailboxPermissionsCsv .\Contoso_MailboxPermissions.csv -Prefix Contoso

    Stages the shared and resource mailboxes on newco.onmicrosoft.com and re-applies their
    FullAccess and SendAs grants with the trustees mapped to their destination accounts.

.EXAMPLE
    .\New-MigrationRecipients.ps1 -PlanPath .\IdentityPlan.csv -Mode UpdateSettings -GroupsCsv .\Contoso_Groups.csv -DelegatedOrganization newco.onmicrosoft.com

    Leaves creation alone and patches owners, members, moderation and delivery restrictions
    onto groups that already exist in the customer tenant.

.NOTES
    Author:  AutomationHub
    Written with assistance from Claude (Anthropic).

    Exchange Online roles: Recipient Management is enough for everything here (New-Mailbox,
    New-DistributionGroup, New-DynamicDistributionGroup, New-MailContact, the matching Set-
    cmdlets, Add-DistributionGroupMember, Add-MailboxPermission, Add-RecipientPermission).
    Organization Management also works. No Graph session is needed.

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

$eligiblePlanStatuses = @('Planned', 'ManualOverride', 'UpnSmtpDiverge')
if ($IncludeCollisions) { $eligiblePlanStatuses += 'Collision' }

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

    .PARAMETER Value
        The raw value: string, array, or Exchange multi-valued property.

    .EXAMPLE
        ConvertTo-AddressArray -Value 'ap@contoso.com; smtp:accounts@contoso.com'

        Returns both addresses with the prefix stripped.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        $Value
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

function ConvertTo-RecipientBoolean {
    <#
    .SYNOPSIS
        Parses an inventory cell into a boolean, or $null when it says nothing.

    .DESCRIPTION
        A blank cell is not $false. 'Not stated' has to stay distinguishable from
        'explicitly off', because the settings diff must leave a setting alone when the
        inventory has no opinion about it rather than switching it off.

    .PARAMETER Value
        The raw cell value.

    .EXAMPLE
        ConvertTo-RecipientBoolean -Value 'True'

        Returns $true. An empty string returns $null.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        $Value
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

    .PARAMETER Row
        The identity plan row.

    .PARAMETER UseInterim
        Prefers the interim address over the target address.

    .EXAMPLE
        Get-RowTargetAddress -Row $row -UseInterim

        Returns 'accounts@newco.onmicrosoft.com' for the sample shared mailbox row.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Row,

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

function ConvertTo-RecipientAddressMap {
    <#
    .SYNOPSIS
        Builds the Source-to-Target address map used to translate members and delegates.

    .DESCRIPTION
        Every membership, ownership and delivery-restriction value in a source inventory is
        a source-tenant address. Applying one of those to a destination object either fails
        or resolves to the wrong recipient, so all of them are translated through this map.

        Each row contributes every address it is known by - source UPN, source primary SMTP,
        each source alias and its display name - all pointing at the one address the row
        will exist on in the destination. Display names are included because the inventory
        falls back to a display name for members Exchange could not resolve to an address.

        Keys are lowercased. A later row never overwrites an earlier key, so a duplicated
        alias resolves to the first row that claimed it rather than to whichever row the
        file happened to end with.

    .PARAMETER Rows
        The full set of plan rows, not just the wave being processed - a member is very
        often in a different wave from the group that contains them.

    .PARAMETER UseInterim
        Maps to interim addresses rather than target addresses.

    .EXAMPLE
        $map = ConvertTo-RecipientAddressMap -Rows $planRows

        Returns a hashtable mapping every known source address to its destination address.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [switch]$UseInterim
    )

    $map = @{}

    foreach ($row in $Rows) {
        $target = Get-RowTargetAddress -Row $row -UseInterim:$UseInterim
        if (-not $target) { continue }

        $keys = [System.Collections.Generic.List[string]]::new()
        foreach ($column in @('SourceUserPrincipalName', 'SourcePrimarySmtp', 'DisplayName')) {
            $value = Get-MigrationCsvValue -Row $row -Name $column -Default ''
            if ($value) { $keys.Add($value) }
        }
        foreach ($alias in (ConvertTo-AddressArray -Value (Get-MigrationCsvValue -Row $row -Name 'SourceAliases' -Default ''))) {
            if ($alias -notmatch '^(?i)x500:') { $keys.Add($alias) }
        }

        foreach ($key in $keys) {
            $lookup = $key.ToLowerInvariant()
            if (-not $map.ContainsKey($lookup)) { $map[$lookup] = $target }
        }
    }

    return $map
}

function Resolve-MappedAddress {
    <#
    .SYNOPSIS
        Translates one source address to its destination address.

    .PARAMETER Address
        The source address or display name.

    .PARAMETER Map
        The map from ConvertTo-RecipientAddressMap.

    .DESCRIPTION
        Returns an empty string when the address is not in the plan. The caller reports
        that rather than falling back to the source address: silently granting rights to an
        address that still resolves in the source tenant is exactly the failure this map
        exists to prevent.

    .EXAMPLE
        Resolve-MappedAddress -Address 'jsmith@contoso.com' -Map $map

        Returns 'john.smith@newco.com'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address,

        [Parameter(Mandatory)]
        [hashtable]$Map
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return '' }

    $lookup = $Address.Trim().ToLowerInvariant() -replace '^(?i)smtp:', ''
    if ($Map.ContainsKey($lookup)) { return [string]$Map[$lookup] }
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

    .PARAMETER Value
        The raw list: a delimited cell or an array.

    .PARAMETER Map
        The map from ConvertTo-RecipientAddressMap.

    .EXAMPLE
        $members = Resolve-MappedAddressList -Value $row.Members -Map $map
        $members.Mapped
        $members.Unmapped

        Applies the mapped members and reports the rest.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [hashtable]$Map
    )

    $mapped = [System.Collections.Generic.List[string]]::new()
    $unmapped = [System.Collections.Generic.List[string]]::new()

    foreach ($address in (ConvertTo-AddressArray -Value $Value)) {
        $target = Resolve-MappedAddress -Address $address -Map $Map
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

    .PARAMETER InputObject
        The inventory row or Exchange group object.

    .PARAMETER BooleanSetting
        Names of the boolean settings to read.

    .PARAMETER TextSetting
        Names of the plain-text settings to read.

    .PARAMETER AddressSetting
        Names of the recipient-list settings to read.

    .PARAMETER Map
        When supplied, address lists are translated through this Source-to-Target map and
        anything unmappable is returned in Unmapped.

    .EXAMPLE
        ConvertTo-GroupSettingState -InputObject $group -BooleanSetting $booleanGroupSetting -TextSetting $textGroupSetting -AddressSetting $addressGroupSetting

        Normalises a live Exchange group for comparison.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        $InputObject,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$BooleanSetting = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$TextSetting = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$AddressSetting = @(),

        [AllowNull()]
        [hashtable]$Map
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
            else {
                $addresses = ConvertTo-AddressArray -Value $raw
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

    .PARAMETER Desired
        The normalised desired settings.

    .PARAMETER Current
        The normalised current settings. An empty table means everything desired is a change.

    .EXAMPLE
        $changes = Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings
        if ($changes.Count -gt 0) { Set-DistributionGroup -Identity $id @changes }

        Applies only what actually differs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Desired,

        [AllowNull()]
        $Current
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

    .PARAMETER Rows
        The inventory rows.

    .PARAMETER KeyColumn
        The columns to index on, in priority order.

    .EXAMPLE
        $groupIndex = Get-CsvIndex -Rows $groupRows -KeyColumn 'PrimarySmtpAddress', 'DisplayName'

        Returns a hashtable keyed by lowercased address and display name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$KeyColumn
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

    .PARAMETER Row
        The plan row.

    .PARAMETER Index
        The index from Get-CsvIndex.

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
        [Parameter(Mandatory)]
        $Row,

        [Parameter(Mandatory)]
        [hashtable]$Index
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

    .PARAMETER Row
        The identity plan row.

    .PARAMETER PrimaryAddress
        The address the recipient was created on.

    .EXAMPLE
        Get-PlanAliasAddress -Row $row -PrimaryAddress 'accounts@newco.com'

        Returns @('smtp:ap@newco.com', 'X500:/o=ExchangeLabs/...').
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        $Row,

        [AllowEmptyString()]
        [string]$PrimaryAddress = ''
    )

    $addresses = [System.Collections.Generic.List[string]]::new()

    foreach ($alias in @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'TargetAliases' -Default ''))) {
        $text = $alias.Trim()
        if (-not $text) { continue }
        if ($text -notmatch '^(?i)(smtp:|x500:)') { $text = "smtp:$text" }
        if (($text -replace '^(?i)smtp:', '') -eq $PrimaryAddress) { continue }
        if (-not $addresses.Contains($text)) { $addresses.Add($text) }
    }

    $x500 = Get-MigrationCsvValue -Row $Row -Name 'SourceX500' -Default ''
    if (-not $x500) {
        $legacyDn = Get-MigrationCsvValue -Row $Row -Name 'LegacyExchangeDN' -Default ''
        if ($legacyDn) { $x500 = "X500:$legacyDn" }
    }
    if ($x500) {
        if ($x500 -notmatch '^(?i)x500:') { $x500 = "X500:$x500" }
        if (-not $addresses.Contains($x500)) { $addresses.Add($x500) }
    }

    return $addresses.ToArray()
}

function Add-ResultRow {
    <#
    .SYNOPSIS
        Appends one row to the run's results collection in the toolkit's standard shape.

    .DESCRIPTION
        Identity, Action, Status and Detail lead every results file in the toolkit. Building
        the rows in one place is what keeps that true across the dozen places this script
        reports an outcome from.

    .PARAMETER Identity
        The source identity the row is about.

    .PARAMETER Action
        What was attempted, for example 'CreateRecipient' or 'UpdateSettings'.

    .PARAMETER Status
        Planned, Succeeded, Skipped or Failed.

    .PARAMETER Detail
        Why. Always populated for Skipped and Failed.

    .PARAMETER ObjectType
        The plan row's ObjectType.

    .PARAMETER PlanStatus
        The plan row's PlanStatus.

    .PARAMETER TargetAddress
        The address the recipient was (or would be) created on.

    .PARAMETER TargetObjectId
        The destination ExternalDirectoryObjectId, when known.

    .PARAMETER SettingsChanged
        Semicolon-separated names of the settings this run changed.

    .PARAMETER MembersAdded
        How many members were added.

    .PARAMETER Unmappable
        Semicolon-separated source addresses the plan could not translate.

    .EXAMPLE
        Add-ResultRow -Identity $identity -Action 'CreateRecipient' -Status 'Succeeded' -Detail 'Shared mailbox created.'

        Records a successful creation.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Identity,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateSet('Planned', 'Succeeded', 'Skipped', 'Failed')]
        [string]$Status,

        [AllowEmptyString()]
        [string]$Detail = '',

        [AllowEmptyString()]
        [string]$ObjectType = '',

        [AllowEmptyString()]
        [string]$PlanStatus = '',

        [AllowEmptyString()]
        [string]$TargetAddress = '',

        [AllowEmptyString()]
        [string]$TargetObjectId = '',

        [AllowEmptyString()]
        [string]$SettingsChanged = '',

        [AllowEmptyString()]
        [string]$MembersAdded = '',

        [AllowEmptyString()]
        [string]$Unmappable = ''
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

$addressMap = ConvertTo-RecipientAddressMap -Rows $planRows -UseInterim:$UseInterim
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
    $null = Connect-MigrationExchange -DelegatedOrganization $DelegatedOrganization
}
catch {
    Write-MigrationLog -Message $_.Exception.Message -Level ERROR
    exit (Complete-MigrationRun -ExitCode 1)
}

$planChanged = $false
$rowIndex = 0

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

    if ($planStatus -notin $eligiblePlanStatuses) {
        $hint = if ($planStatus -eq 'Collision') { ' Re-run with -IncludeCollisions to process it.' } else { '' }
        Add-ResultRow @common -Action 'CreateRecipient' -Status 'Skipped' -Detail "PlanStatus is '$planStatus'.$hint"
        continue
    }

    $targetAddress = ''
    $recipient = $null
    $targetObjectId = ''

    try {
        $targetAddress = Get-RowTargetAddress -Row $row -UseInterim:$UseInterim
        if (-not $targetAddress) { throw 'The plan row has no interim or target primary SMTP address.' }

        $addressCheck = Test-MigrationAddress -Address $targetAddress -Kind 'Smtp'
        if (-not $addressCheck.IsValid) { throw "'$targetAddress' is not a usable SMTP address: $($addressCheck.Reason)" }

        if (-not $displayName) { throw 'The plan row has no DisplayName, which every recipient type requires.' }

        $alias = Get-MigrationCsvValue -Row $row -Name 'TargetMailNickname' -Default ''
        if (-not $alias) { $alias = ($targetAddress -split '@')[0] }

        #-- Does it already exist? --------------------------------------------------------
        foreach ($candidate in @($targetAddress, $alias)) {
            if ($recipient) { break }
            try {
                $found = @(Get-Recipient -Identity $candidate -ErrorAction Stop)
                if ($found.Count -gt 0) { $recipient = $found[0] }
            }
            catch {
                Write-MigrationLog -Message "No destination recipient matches '$candidate'." -Level DEBUG
            }
        }

        if ($recipient) {
            $targetObjectId = Get-MigrationCsvValue -Row $recipient -Name 'ExternalDirectoryObjectId' -Default ''
            if (-not $targetObjectId) { $targetObjectId = Get-MigrationCsvValue -Row $recipient -Name 'Guid' -Default '' }
        }

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
                    $externalAddress = if ($inventoryRow) { Get-MigrationCsvValue -Row $inventoryRow -Name 'ExternalEmailAddress' -Default '' } else { '' }
                    if (-not $externalAddress) { $externalAddress = Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default '' }
                    if (-not $externalAddress) {
                        throw 'A mail contact needs an ExternalEmailAddress. Supply -ContactsCsv or set SourcePrimarySmtp on the plan row.'
                    }
                    # Deliberately not mapped: a contact points at someone outside both tenants.
                    $createParameters['ExternalEmailAddress'] = $externalAddress
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

        $updateDetail = [System.Collections.Generic.List[string]]::new()
        $unmappable = [System.Collections.Generic.List[string]]::new()
        $settingsChanged = [System.Collections.Generic.List[string]]::new()
        $membersAdded = 0

        $setCmdlet = switch ($objectType) {
            { $_ -in @('Shared', 'Room', 'Equipment') } { 'Set-Mailbox' }
            { $_ -in @('Distribution', 'MailEnabledSecurity') } { 'Set-DistributionGroup' }
            'DynamicDistribution' { 'Set-DynamicDistributionGroup' }
            'Contact' { 'Set-MailContact' }
            default { '' }
        }

        #-- Aliases and the X500 address --------------------------------------------------
        $aliasAddresses = @(Get-PlanAliasAddress -Row $row -PrimaryAddress $targetAddress)
        if ($aliasAddresses.Count -gt 0 -and $setCmdlet) {
            $aliasParameters = @{ Identity = $targetAddress; EmailAddresses = @{ Add = $aliasAddresses }; ErrorAction = 'Stop' }
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

                $current = ConvertTo-GroupSettingState -InputObject $recipient -BooleanSetting $booleanGroupSetting `
                    -TextSetting $textGroupSetting -AddressSetting $addressGroupSetting
                $changes = Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings

                if ($changes.Count -gt 0 -and $setCmdlet) {
                    $changeNames = @($changes.Keys | Sort-Object)
                    $settingParameters = $changes.Clone()
                    $settingParameters['Identity'] = $targetAddress
                    $settingParameters['ErrorAction'] = 'Stop'
                    $null = Invoke-MigrationAction -Description "Apply $($changeNames -join ', ') to $targetAddress" -Action {
                        & $setCmdlet @settingParameters
                    }
                    foreach ($name in $changeNames) { $settingsChanged.Add($name) }
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
                        $existingMembers = @(Get-DistributionGroupMember -Identity $targetAddress -ResultSize Unlimited -ErrorAction Stop |
                                ForEach-Object { [string](Get-MigrationCsvValue -Row $_ -Name 'PrimarySmtpAddress' -Default '') } |
                                Where-Object { $_ })
                    }
                    catch {
                        $updateDetail.Add("Could not read the current membership: $($_.Exception.Message)")
                    }

                    foreach ($member in $members.Mapped) {
                        if ($existingMembers -contains $member) { continue }
                        try {
                            $null = Invoke-MigrationAction -Description "Add $member to $targetAddress" -Action {
                                Add-DistributionGroupMember -Identity $targetAddress -Member $member -BypassSecurityGroupManagerCheck -ErrorAction Stop
                            }
                            $membersAdded++
                        }
                        catch {
                            $updateDetail.Add("Member '$member' not added: $($_.Exception.Message)")
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

                $current = ConvertTo-GroupSettingState -InputObject $recipient `
                    -BooleanSetting @('HiddenFromAddressListsEnabled') -AddressSetting @('GrantSendOnBehalfTo')
                $changes = Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings

                if ($changes.Count -gt 0) {
                    $changeNames = @($changes.Keys | Sort-Object)
                    $mailboxParameters = $changes.Clone()
                    $mailboxParameters['Identity'] = $targetAddress
                    $mailboxParameters['ErrorAction'] = 'Stop'
                    $null = Invoke-MigrationAction -Description "Apply $($changeNames -join ', ') to $targetAddress" -Action {
                        Set-Mailbox @mailboxParameters
                    }
                    foreach ($name in $changeNames) { $settingsChanged.Add($name) }
                }
            }

            #-- FullAccess and SendAs ------------------------------------------------------
            $sourceAddress = Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default ''
            $sourceLookup = if ($sourceAddress) { $sourceAddress.ToLowerInvariant() } else { '' }
            if ($sourceLookup -and $permissionsBySource.ContainsKey($sourceLookup)) {
                foreach ($permission in $permissionsBySource[$sourceLookup]) {
                    $right = Get-MigrationCsvValue -Row $permission -Name 'Permission' -Default ''
                    if ($right -notin @('FullAccess', 'SendAs')) { continue }

                    $trustee = Resolve-MappedAddress -Address (Get-MigrationCsvValue -Row $permission -Name 'Trustee' -Default '') -Map $addressMap
                    if (-not $trustee) {
                        $rawTrustee = Get-MigrationCsvValue -Row $permission -Name 'Trustee' -Default '(blank)'
                        $unmappable.Add("${right}: $rawTrustee")
                        continue
                    }

                    try {
                        if ($right -eq 'FullAccess') {
                            $null = Invoke-MigrationAction -Description "Grant FullAccess on $targetAddress to $trustee" -Action {
                                Add-MailboxPermission -Identity $targetAddress -User $trustee -AccessRights FullAccess `
                                    -AutoMapping $true -ErrorAction Stop
                            }
                        }
                        else {
                            $null = Invoke-MigrationAction -Description "Grant SendAs on $targetAddress to $trustee" -Action {
                                Add-RecipientPermission -Identity $targetAddress -Trustee $trustee -AccessRights SendAs `
                                    -Confirm:$false -ErrorAction Stop
                            }
                        }
                        $settingsChanged.Add($right)
                    }
                    catch {
                        $updateDetail.Add("$right for '$trustee' failed: $($_.Exception.Message)")
                    }
                }
            }
        }

        #-- Contact settings --------------------------------------------------------------
        if ($objectType -eq 'Contact') {
            $inventoryRow = Find-IndexedRow -Row $row -Index $contactIndex
            if ($inventoryRow) {
                $desired = ConvertTo-GroupSettingState -InputObject $inventoryRow -BooleanSetting @('HiddenFromAddressListsEnabled')
                $current = ConvertTo-GroupSettingState -InputObject $recipient -BooleanSetting @('HiddenFromAddressListsEnabled')
                $changes = Get-GroupSettingChange -Desired $desired.Settings -Current $current.Settings
                if ($changes.Count -gt 0) {
                    $contactParameters = $changes.Clone()
                    $contactParameters['Identity'] = $targetAddress
                    $contactParameters['ErrorAction'] = 'Stop'
                    $null = Invoke-MigrationAction -Description "Apply HiddenFromAddressListsEnabled to $targetAddress" -Action {
                        Set-MailContact @contactParameters
                    }
                    $settingsChanged.Add('HiddenFromAddressListsEnabled')
                }
            }
        }

        if ($unmappable.Count -gt 0) {
            $updateDetail.Add("Not in the plan, so left off: $($unmappable.Count) address(es).")
        }
        if ($settingsChanged.Count -eq 0 -and $membersAdded -eq 0 -and $updateDetail.Count -eq 0) {
            $updateDetail.Add('Nothing to change.')
        }

        $status = if ($DryRun) { 'Planned' } else { 'Succeeded' }
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
        Add-ResultRow @common -Action 'CreateRecipient' -Status 'Failed' -Detail $message -TargetAddress $targetAddress
    }
}

Write-Progress -Activity 'Creating destination recipients' -Completed

#endregion Main -----------------------------------------------------------------------

#region Cleanup -----------------------------------------------------------------------

if ($planChanged) {
    try {
        $null = Invoke-MigrationAction -Description "Write provisioning results back to $PlanPath" -Action {
            Save-MigrationPlan -Path $PlanPath -Rows $planRows
        }
    }
    catch {
        Write-MigrationLog -Message "Could not write the plan back: $($_.Exception.Message)" -Level ERROR
    }
}

$null = Export-MigrationResult -Rows $script:results.ToArray() -Name 'New-Recipients'

$exitCode = if (@($script:results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { 2 } else { 0 }
exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion Cleanup --------------------------------------------------------------------
