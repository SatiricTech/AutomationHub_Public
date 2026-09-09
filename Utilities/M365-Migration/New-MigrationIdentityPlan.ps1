#Requires -Version 7.4

<#
.SYNOPSIS
    Turns source-tenant inventory CSVs into the identity plan every later phase reads.

.DESCRIPTION
    The offline heart of the toolkit. It reads the CSVs produced by Get-MigrationInventory.ps1,
    decides what every source object is going to be called in the destination tenant, and writes
    one IdentityPlan.csv that the provisioning, licensing and cutover scripts then act on. No
    tenant connection is made, so -DryRun computes the whole plan and simply writes nothing.

    Deciding names offline matters because the plan is the artefact the client signs off. An
    operator can open it, correct a surname, override an address, and re-run the writers without
    ever asking the tool to guess again.

    For every source object the script classifies it (User, Guest, Shared, Room, Equipment,
    Distribution, MailEnabledSecurity, DynamicDistribution, Contact, M365Group), excludes what
    must not be migrated - break-glass and service accounts, directory-synced objects, disabled
    accounts, guests, Entra groups Fly handles - recording why in ExcludeReason rather than
    dropping the row, builds the destination local part from a naming template, resolves
    collisions deterministically, validates every address it produced, maps source licences
    through a SKU map, carries the LegacyExchangeDN across as an X500 address so replies to old
    mail do not bounce with an IMCEAEX non-delivery report, and assigns waves.

    Nothing is guessed. A name that cannot be templated (no surname, a name written only in a
    non-Latin script) is marked NeedsReview with the target columns left empty, which is the
    operator's cue to fill it in by hand.

    Re-running against an updated inventory is safe: with -ExistingPlanPath, any row already
    provisioned (a non-empty TargetObjectId) or marked ManualOverride keeps its destination
    identity verbatim, and its addresses are treated as reserved.

.PARAMETER UsersCsv
    The Users tab from Get-MigrationInventory. Required - it is the spine of the plan.

.PARAMETER UserMailboxesCsv
    The UserMailboxes tab. Strongly recommended: it supplies LegacyExchangeDN, the proxy
    addresses and the recipient type, none of which Entra ID exposes.

.PARAMETER SharedMailboxesCsv
    The SharedMailboxes tab (shared, room, equipment and scheduling mailboxes).

.PARAMETER GroupsCsv
    The Groups tab. Distribution, mail-enabled security and dynamic distribution groups are
    planned; Microsoft 365 groups, Teams and security groups are recorded as excluded.

.PARAMETER ContactsCsv
    The Contacts tab (mail contacts).

.PARAMETER TargetDomain
    Destination vanity domain, with or without a leading '@'. Every templated address is built
    in this domain.

.PARAMETER InterimDomain
    Routing domain used before the vanity domain cuts over, typically newco.onmicrosoft.com.
    When omitted the Interim* columns mirror the Target* columns.

.PARAMETER UpnFormat
    Naming template or preset for the destination UPN. Default 'First.Last'. Presets:
    First.Last, FLast, F.Last, FirstLast, First, First.L, FirstL, First.M.Last, FMLast,
    Last.First, Keep. Templates use {first} {last} {middle} {f} {m} {l} {source} {display} with
    optional truncation, for example '{f}{last:12}'.

.PARAMETER SmtpFormat
    Template for the primary SMTP address. Defaults to -UpnFormat, which keeps the UPN and the
    mail address identical.

.PARAMETER MailNicknameFormat
    Template for the mail nickname. When omitted the resolved SMTP local part is used, which
    survives collision resolution.

.PARAMETER SkuMapPath
    CSV of SourceSkuPartNumber,TargetSkuPartNumber. A ';' separated target maps one licence to
    several; an empty target drops it. Unmapped SKUs are carried through and noted in PlanDetail.

.PARAMETER ExclusionRulesPath
    CSV of Pattern,MatchOn,Reason with an optional MatchType column (Wildcard, the default, or
    Regex). Any object whose MatchOn column matches the pattern is excluded.

.PARAMETER WaveMapPath
    CSV of UserPrincipalName,Wave, matched against the source UPN then the source primary SMTP
    address. Objects not listed get -DefaultWave.

.PARAMETER DefaultWave
    Wave assigned to everything the wave map does not name. Default '1'.

.PARAMETER DefaultUsageLocation
    Two-letter usage location applied when the source object has none. Licence assignment fails
    without one.

.PARAMETER ExistingPlanPath
    A previous IdentityPlan.csv. Rows carrying a TargetObjectId or the PlanStatus ManualOverride
    keep their destination identity, wave and provisioning state verbatim.

.PARAMETER ReservedAddressesPath
    Files listing addresses already in use in the destination. Each may be a destination
    inventory CSV or a plain text list of one address per line ('#' starts a comment).

.PARAMETER IncludeDisabled
    Plan disabled source accounts instead of excluding them.

.PARAMETER IncludeGuests
    Plan guest (#EXT#) accounts. Guests keep their existing external identity verbatim.

.PARAMETER IncludeSynced
    Plan directory-synced objects, whose authoritative copy lives in on-premises AD.

.PARAMETER PreserveAliases
    Carry the source proxy addresses across as destination aliases, re-domained through
    -AliasDomainMap. Without that map there is nothing to re-domain, so the switch only warns.

.PARAMETER AliasDomainMap
    Hashtable of source domain to destination domain, for example
    @{ 'contoso.com' = 'newco.com'; 'contoso.co.uk' = 'newco.co.uk' }.

.PARAMETER OutputPath
    Directory for the plan and the log. Defaults to the toolkit output root.

.PARAMETER Prefix
    Client or run name. Output lands in <OutputPath>\<Prefix>\ and file names start '<Prefix>_'.

.PARAMETER LogPath
    Override for the log file path.

.PARAMETER DryRun
    Compute the entire plan and print the summary without writing the plan file.

.PARAMETER Verbosity
    Console noise level: Low, Medium (default) or High. The log file always gets everything.

.EXAMPLE
    .\New-MigrationIdentityPlan.ps1 -UsersCsv .\Contoso_Users_20260908-101500.csv `
        -UserMailboxesCsv .\Contoso_UserMailboxes_20260908-101500.csv `
        -TargetDomain newco.com -Prefix Contoso

    Plans every enabled, cloud-only user as first.last@newco.com and writes
    Contoso_IdentityPlan_<timestamp>.csv.

.EXAMPLE
    .\New-MigrationIdentityPlan.ps1 -UsersCsv .\Users.csv -SharedMailboxesCsv .\Shared.csv `
        -GroupsCsv .\Groups.csv -ContactsCsv .\Contacts.csv `
        -TargetDomain newco.com -InterimDomain newco.onmicrosoft.com `
        -UpnFormat F.Last -SkuMapPath .\Templates\SkuMap.sample.csv `
        -ExclusionRulesPath .\Templates\ExclusionRules.sample.csv -WaveMapPath .\Waves.csv `
        -PreserveAliases -AliasDomainMap @{ 'contoso.com' = 'newco.com' } -DryRun

    Full offline dress rehearsal - summary printed, nothing written.

.EXAMPLE
    .\New-MigrationIdentityPlan.ps1 -UsersCsv .\Users.csv -TargetDomain newco.com `
        -ExistingPlanPath .\Contoso_IdentityPlan_20260901-090000.csv `
        -ReservedAddressesPath .\Destination_Users.csv, .\Destination_Groups.csv

    Re-plans after a second inventory pull, keeping provisioned and overridden identities.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4+ and the bundled M365Migration module. Entirely offline - no
                  Graph scope or Exchange Online role is needed, so GDAP does not apply.
    Exit codes  : 0 success (rows needing review are the operator's to-do, not a failure),
                  1 fatal error.
    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$UsersCsv,

    [ValidateNotNullOrEmpty()]
    [string]$UserMailboxesCsv,

    [ValidateNotNullOrEmpty()]
    [string]$SharedMailboxesCsv,

    [ValidateNotNullOrEmpty()]
    [string]$GroupsCsv,

    [ValidateNotNullOrEmpty()]
    [string]$ContactsCsv,

    [Parameter(Mandatory)]
    [ValidatePattern('^@?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$')]
    [string]$TargetDomain,

    [ValidatePattern('^@?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$')]
    [string]$InterimDomain,

    [ValidateNotNullOrEmpty()]
    [string]$UpnFormat = 'First.Last',

    [ValidateNotNullOrEmpty()]
    [string]$SmtpFormat,

    [ValidateNotNullOrEmpty()]
    [string]$MailNicknameFormat,

    [ValidateNotNullOrEmpty()]
    [string]$SkuMapPath,

    [ValidateNotNullOrEmpty()]
    [string]$ExclusionRulesPath,

    [ValidateNotNullOrEmpty()]
    [string]$WaveMapPath,

    [ValidateNotNullOrEmpty()]
    [string]$DefaultWave = '1',

    [ValidatePattern('^[A-Za-z]{2}$')]
    [string]$DefaultUsageLocation,

    [ValidateNotNullOrEmpty()]
    [string]$ExistingPlanPath,

    [ValidateNotNullOrEmpty()]
    [string[]]$ReservedAddressesPath,

    [switch]$IncludeDisabled,
    [switch]$IncludeGuests,
    [switch]$IncludeSynced,
    [switch]$PreserveAliases,

    [hashtable]$AliasDomainMap,

    [string]$OutputPath,
    [string]$Prefix,
    [string]$LogPath,
    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Configuration ------------------------------------------------------------------

# Scheduling mailboxes are resource mailboxes that behave like equipment, so they land in the
# same bucket rather than inventing a plan type for them.
$script:MailboxTypeMap = @{
    'SharedMailbox' = 'Shared'; 'RoomMailbox' = 'Room'
    'EquipmentMailbox' = 'Equipment'; 'SchedulingMailbox' = 'Equipment'
}

# The informational kinds are recorded so the operator can see they were considered, but no
# writer in the toolkit acts on them.
$script:GroupTypeMap = @{
    'Distribution' = 'Distribution'; 'MailEnabledSecurity' = 'MailEnabledSecurity'
    'DynamicDistribution' = 'DynamicDistribution'; 'M365Group' = 'M365Group'
    'Team' = 'M365Group'; 'SecurityGroup' = 'M365Group'
}

$script:GroupExcludeReasons = @{
    'M365Group' = 'Migrated by Fly'; 'Team' = 'Migrated by Fly'
    'SecurityGroup' = 'Not mail-enabled'
}

# Columns of a destination inventory CSV that can hold an address already in use.
$script:ReservedAddressColumns = @(
    'UserPrincipalName', 'PrimarySmtpAddress', 'TargetUserPrincipalName', 'TargetPrimarySmtp',
    'InterimUserPrincipalName', 'InterimPrimarySmtp', 'EmailAddresses', 'ProxyAddresses',
    'ExternalEmailAddress', 'TargetAliases'
)

# Columns whose plan name and inventory name are identical, per source kind.
$script:PassThroughColumns = @{
    'User'          = @('DisplayName', 'FirstName', 'MiddleName', 'LastName', 'JobTitle',
        'Department', 'Office', 'MobilePhone', 'ManagerUpn', 'AccountEnabled', 'IsSynced')
    'SharedMailbox' = @('DisplayName', 'AccountEnabled', 'IsSynced')
    'Group'         = @('DisplayName', 'IsSynced')
    'Contact'       = @('DisplayName', 'FirstName', 'LastName')
}

# Columns preserved verbatim from a previous plan, and the columns a row is matched on.
$script:PreservedFields = @(
    'Wave', 'InterimUserPrincipalName', 'InterimPrimarySmtp', 'TargetUserPrincipalName',
    'TargetPrimarySmtp', 'TargetAliases', 'TargetMailNickname', 'TargetLicenses', 'PlanStatus',
    'PlanDetail', 'ExcludeReason', 'TargetObjectId', 'MailboxProvisioned', 'OneDriveProvisioned',
    'ProvisionStatus', 'ProvisionDetail'
)
$script:IdentityColumns = @('SourceObjectId', 'SourcePrimarySmtp', 'SourceUserPrincipalName')

#endregion -----------------------------------------------------------------------------

#region Functions ----------------------------------------------------------------------

function Split-PlanAddress {
    <#
    .SYNOPSIS
        Splits an address into its local part and its lowercased domain.
    .DESCRIPTION
        Deliberately naive - everything up to the first '@' is the local part - so the '#EXT#'
        marker in a guest UPN survives untouched. A value with no '@' is all local part.
    .PARAMETER Address
        The address to split.
    .EXAMPLE
        (Split-PlanAddress -Address 'jsmith@Contoso.com').Domain
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Address)

    $text = ([string]$Address).Trim()
    $at = $text.IndexOf('@')
    if ($at -lt 0) { return [pscustomobject]@{ Local = $text; Domain = '' } }

    [pscustomobject]@{ Local = $text.Substring(0, $at); Domain = $text.Substring($at + 1).ToLowerInvariant() }
}

function Get-PlanAddressSet {
    <#
    .SYNOPSIS
        Splits an inventory proxy-address list into destination-relevant aliases and X500s.
    .DESCRIPTION
        SIP, SPO and EUM addresses are dropped: the workloads that own them re-create them in
        the destination. The primary is dropped from the alias list because the plan already
        records it as SourcePrimarySmtp.
    .PARAMETER Value
        The ';' separated proxy-address list from the inventory.
    .PARAMETER PrimaryAddress
        The recipient's primary SMTP address.
    .EXAMPLE
        Get-PlanAddressSet -Value 'SMTP:a@contoso.com;smtp:b@contoso.com' -PrimaryAddress 'a@contoso.com'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [AllowNull()][AllowEmptyString()][string]$PrimaryAddress
    )

    $primary = ([string]$PrimaryAddress).Trim().ToLowerInvariant()
    $aliases = [System.Collections.Generic.List[string]]::new()
    $legacyDns = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @(Split-MigrationList -Value $Value)) {
        $parsed = Split-MigrationProxyAddress -Entry $entry
        switch ($parsed.Kind) {
            'Smtp' {
                $address = $parsed.Address.Trim().ToLowerInvariant()
                if ($address -and $address -ne $primary -and -not $aliases.Contains("smtp:$address")) {
                    $aliases.Add("smtp:$address")
                }
            }
            'X500' { $legacyDns.Add($parsed.Address) }
        }
    }

    [pscustomobject]@{
        Aliases = [string[]]$aliases.ToArray()
        X500    = [string[]]@(ConvertTo-MigrationX500 -Value $legacyDns.ToArray())
    }
}

function New-PlanSourceRow {
    <#
    .SYNOPSIS
        Builds the plan-row columns that every source kind shares.
    .DESCRIPTION
        The identity, the proxy-address split and the X500 set are the same work for a user, a
        shared mailbox, a group and a contact; only the type columns differ, so the caller sets
        those on the row this returns.
    .PARAMETER Source
        The inventory row.
    .PARAMETER Kind
        Selects the pass-through column list: User, SharedMailbox, Group or Contact.
    .PARAMETER Primary
        The recipient's primary SMTP address.
    .PARAMETER ProxyValue
        The ';' separated proxy-address list to split.
    .PARAMETER Detail
        The row holding LegacyExchangeDN and X500Addresses. Defaults to -Source; a user's live
        on its mailbox row instead.
    .EXAMPLE
        New-PlanSourceRow -Source $source -Kind Group -Primary $primary -ProxyValue $addresses
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only; nothing is written to disk or to a tenant.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Source,
        [Parameter(Mandatory)][ValidateSet('User', 'SharedMailbox', 'Group', 'Contact')][string]$Kind,
        [AllowNull()][AllowEmptyString()][string]$Primary,
        [AllowNull()][AllowEmptyString()][string]$ProxyValue,
        [AllowNull()]$Detail
    )

    if ($null -eq $Detail) { $Detail = $Source }
    $addressSet = Get-PlanAddressSet -Value $ProxyValue -PrimaryAddress $Primary

    $row = New-MigrationPlanRow
    foreach ($name in $script:PassThroughColumns[$Kind]) {
        $row.$name = Get-MigrationCsvValue -Row $Source -Name $name -Default ''
    }
    $row.SourceObjectId = Get-MigrationCsvValue -Row $Source -Name 'ObjectId' -Default ''
    $row.SourcePrimarySmtp = $Primary
    $row.SourceAliases = Join-MigrationList -Values $addressSet.Aliases
    $row.LegacyExchangeDN = Get-MigrationCsvValue -Row $Detail -Name 'LegacyExchangeDN' -Default ''
    $row.SourceX500 = Join-MigrationList -Values @(ConvertTo-MigrationX500 -Value (
            @(Get-MigrationCsvValue -Row $Detail -Name 'X500Addresses' -Default '') + $addressSet.X500))
    return $row
}

function Import-PlanExclusionRule {
    <#
    .SYNOPSIS
        Reads the exclusion rule file.
    .DESCRIPTION
        Rules are wildcard patterns by default because that is what an operator writes by hand
        ('break-glass*'); a rule needing a regular expression sets MatchType to Regex.
    .PARAMETER Path
        The exclusion rules CSV: Pattern, MatchOn, Reason and optionally MatchType.
    .EXAMPLE
        Import-PlanExclusionRule -Path .\Templates\ExclusionRules.sample.csv
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)

    $rules = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 1

    foreach ($row in @(Import-MigrationCsv -Path $Path -RequiredColumns @('Pattern', 'MatchOn'))) {
        $lineNumber++
        $pattern = Get-MigrationCsvValue -Row $row -Name 'Pattern' -Default ''
        $matchOn = Get-MigrationCsvValue -Row $row -Name 'MatchOn' -Default ''
        $matchType = Get-MigrationCsvValue -Row $row -Name 'MatchType' -Default 'Wildcard'

        if (-not $pattern -or -not $matchOn) {
            throw "The exclusion rules file '$Path' has an empty Pattern or MatchOn on line $lineNumber."
        }
        if ($matchType -notin @('Wildcard', 'Regex')) {
            throw "The exclusion rules file '$Path' has MatchType '$matchType' on line $lineNumber; use Wildcard or Regex."
        }
        if ($matchType -eq 'Regex') {
            try { $null = [regex]::new($pattern) }
            catch { throw "The exclusion rules file '$Path' has an invalid regular expression on line ${lineNumber}: $($_.Exception.Message)" }
        }

        $rules.Add([pscustomobject]@{
                Pattern = $pattern; MatchOn = $matchOn; MatchType = $matchType
                Reason  = (Get-MigrationCsvValue -Row $row -Name 'Reason' -Default "Matched exclusion rule '$pattern' on $matchOn")
            })
    }

    Write-MigrationLog -Message "Loaded $($rules.Count) exclusion rule(s) from $Path" -Level INFO
    return $rules.ToArray()
}

function Get-PlanExclusionReason {
    <#
    .SYNOPSIS
        Returns the reason the first matching exclusion rule gives, or an empty string.
    .PARAMETER Row
        The source inventory row to test.
    .PARAMETER Rule
        The rules returned by Import-PlanExclusionRule.
    .EXAMPLE
        Get-PlanExclusionReason -Row $user -Rule $rules
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row,
        [AllowNull()][AllowEmptyCollection()][object[]]$Rule
    )

    foreach ($rule in @($Rule)) {
        $value = Get-MigrationCsvValue -Row $Row -Name $rule.MatchOn -Default ''
        if (-not $value) { continue }
        $isMatch = if ($rule.MatchType -eq 'Regex') { $value -match $rule.Pattern } else { $value -like $rule.Pattern }
        if ($isMatch) { return [string]$rule.Reason }
    }

    return ''
}

function Get-PlanReservedAddress {
    <#
    .SYNOPSIS
        Collects addresses already in use in the destination tenant.
    .DESCRIPTION
        Accepts either a destination inventory CSV - in which case every address-bearing column
        is harvested - or a plain text list of one address per line. Detecting the shape rather
        than demanding a format means an operator can paste addresses into a text file and it
        just works.
    .PARAMETER Path
        One or more files to read.
    .EXAMPLE
        Get-PlanReservedAddress -Path .\Destination_Users.csv, .\Reserved.txt
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Path)

    $reserved = [System.Collections.Generic.List[string]]::new()

    $addValue = {
        param([string]$Raw)
        foreach ($entry in @(Split-MigrationList -Value $Raw)) {
            $parsed = Split-MigrationProxyAddress -Entry $entry
            if ($parsed.Kind -ne 'Smtp') { continue }
            $text = $parsed.Address.Trim().ToLowerInvariant()
            if ($text.Contains('@') -and -not $reserved.Contains($text)) { $reserved.Add($text) }
        }
    }

    foreach ($file in $Path) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Reserved address file not found: $file" }

        try { $lines = @(Get-Content -LiteralPath $file -Encoding utf8 -ErrorAction Stop) }
        catch { throw "Could not read the reserved address file '$file': $($_.Exception.Message)" }

        $header = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if ($header.Count -eq 0) {
            Write-MigrationLog -Message "Reserved address file '$file' is empty; skipping it." -Level WARNING
            continue
        }

        $looksLikeCsv = $header[0].Contains(',') -or ($script:ReservedAddressColumns | Where-Object { $header[0].Trim('"', ' ') -ieq $_ })
        if ($looksLikeCsv) {
            try { $rows = @(Import-Csv -LiteralPath $file -Encoding utf8 -ErrorAction Stop) }
            catch { throw "Could not read the reserved address CSV '$file': $($_.Exception.Message)" }

            foreach ($row in $rows) {
                foreach ($column in $script:ReservedAddressColumns) {
                    & $addValue (Get-MigrationCsvValue -Row $row -Name $column -Default '')
                }
            }
        }
        else {
            foreach ($line in $lines) {
                $text = $line.Trim()
                if ($text -and -not $text.StartsWith('#')) { & $addValue $text }
            }
        }
    }

    Write-MigrationLog -Message "Loaded $($reserved.Count) reserved destination address(es) from $($Path.Count) file(s)." -Level INFO
    return [string[]]$reserved.ToArray()
}

function Get-PlanTargetLicense {
    <#
    .SYNOPSIS
        Maps a source licence list through the SKU map.
    .DESCRIPTION
        An unmapped SKU is kept rather than dropped: the destination readiness check then reports
        it as unavailable, which is a far louder signal than a silently missing licence
        discovered on cutover day.
    .PARAMETER SourceLicense
        The ';' separated source SkuPartNumber list.
    .PARAMETER SkuMap
        The hashtable from Resolve-MigrationSkuMap, or $null when no map was supplied.
    .EXAMPLE
        Get-PlanTargetLicense -SourceLicense 'ENTERPRISEPACK;MCOEV' -SkuMap $map
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyString()][string]$SourceLicense,
        [AllowNull()][hashtable]$SkuMap
    )

    $targets = [System.Collections.Generic.List[string]]::new()
    $unmapped = [System.Collections.Generic.List[string]]::new()
    $dropped = [System.Collections.Generic.List[string]]::new()
    $add = {
        param([System.Collections.Generic.List[string]]$List, [string]$Value)
        if (-not $List.Contains($Value)) { $List.Add($Value) }
    }

    foreach ($sku in @(Split-MigrationList -Value $SourceLicense)) {
        # A plain hashtable compares keys case-insensitively, which is what a hand-typed map needs.
        if ($null -eq $SkuMap -or -not $SkuMap.ContainsKey($sku)) {
            if ($null -ne $SkuMap) { & $add $unmapped $sku }
            & $add $targets $sku
            continue
        }

        $mapped = @($SkuMap[$sku])
        if ($mapped.Count -eq 0) { & $add $dropped $sku; continue }
        foreach ($target in $mapped) { & $add $targets $target }
    }

    [pscustomobject]@{
        Licenses = [string[]]$targets.ToArray()
        Unmapped = [string[]]$unmapped.ToArray()
        Dropped  = [string[]]$dropped.ToArray()
    }
}

#endregion -----------------------------------------------------------------------------

#region Main ---------------------------------------------------------------------------

$exitCode = 0

try {
    $run = Initialize-MigrationRun -ScriptName 'New-MigrationIdentityPlan' -OutputPath $OutputPath `
        -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity `
        -BoundParameters $PSBoundParameters

    $targetDomainName = $TargetDomain.TrimStart('@').ToLowerInvariant()
    $interimDomainName = if ($InterimDomain) { $InterimDomain.TrimStart('@').ToLowerInvariant() } else { '' }
    $smtpTemplate = if ($PSBoundParameters.ContainsKey('SmtpFormat')) { $SmtpFormat } else { $UpnFormat }
    $nicknameTemplate = if ($PSBoundParameters.ContainsKey('MailNicknameFormat')) { $MailNicknameFormat } else { '' }

    if ($PreserveAliases -and (-not $AliasDomainMap -or $AliasDomainMap.Count -eq 0)) {
        Write-MigrationLog -Message ('-PreserveAliases was supplied without -AliasDomainMap, so no source alias can ' +
            'be re-domained. Only X500 addresses will be carried across.') -Level WARNING
    }

    # Source domain to destination domain, normalised once for the alias pass below.
    $aliasDomainLookup = @{}
    if ($AliasDomainMap) {
        foreach ($key in @($AliasDomainMap.Keys)) {
            $aliasDomainLookup[([string]$key).Trim().TrimStart('@').ToLowerInvariant()] =
                ([string]$AliasDomainMap[$key]).Trim().TrimStart('@').ToLowerInvariant()
        }
    }

    # --- Supporting files ---------------------------------------------------------------------
    $skuMap = if ($SkuMapPath) { Resolve-MigrationSkuMap -Path $SkuMapPath } else { $null }
    $exclusionRules = @(if ($ExclusionRulesPath) { Import-PlanExclusionRule -Path $ExclusionRulesPath })

    $waveMap = @{}
    if ($WaveMapPath) {
        foreach ($row in @(Import-MigrationCsv -Path $WaveMapPath -RequiredColumns @('UserPrincipalName', 'Wave'))) {
            $identity = Get-MigrationCsvValue -Row $row -Name 'UserPrincipalName' -Default ''
            $wave = Get-MigrationCsvValue -Row $row -Name 'Wave' -Default ''
            if (-not $identity -or -not $wave) { throw "The wave map '$WaveMapPath' has a row with an empty UserPrincipalName or Wave." }
            $waveMap[$identity.ToLowerInvariant()] = $wave
        }
        Write-MigrationLog -Message "Loaded $($waveMap.Count) wave assignment(s) from $WaveMapPath" -Level INFO
    }

    $reservedAddresses = [System.Collections.Generic.List[string]]::new()
    $reserve = {
        param([string]$Address)
        $text = ([string]$Address).Trim().ToLowerInvariant()
        if ($text -and -not $reservedAddresses.Contains($text)) { $reservedAddresses.Add($text) }
    }
    if ($ReservedAddressesPath) {
        foreach ($address in @(Get-PlanReservedAddress -Path $ReservedAddressesPath)) { & $reserve $address }
    }

    # --- Rows preserved from a previous plan ---------------------------------------------------
    $preservedIndex = @{}
    if ($ExistingPlanPath) {
        foreach ($existing in @(Import-MigrationPlan -Path $ExistingPlanPath)) {
            $hasTargetObject = -not [string]::IsNullOrWhiteSpace((Get-MigrationCsvValue -Row $existing -Name 'TargetObjectId' -Default ''))
            if (-not $hasTargetObject -and (Get-MigrationCsvValue -Row $existing -Name 'PlanStatus' -Default '') -ne 'ManualOverride') { continue }

            foreach ($keyColumn in $script:IdentityColumns) {
                $keyValue = Get-MigrationCsvValue -Row $existing -Name $keyColumn -Default ''
                if (-not $keyValue) { continue }
                $indexKey = "$keyColumn|$($keyValue.ToLowerInvariant())"
                if (-not $preservedIndex.ContainsKey($indexKey)) { $preservedIndex[$indexKey] = $existing }
            }

            # A preserved identity is, by definition, already spoken for in the destination.
            foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'InterimUserPrincipalName', 'InterimPrimarySmtp')) {
                & $reserve (Get-MigrationCsvValue -Row $existing -Name $column -Default '')
            }
        }
        Write-MigrationLog -Message ("Existing plan '$ExistingPlanPath' contributes " +
            "$((@($preservedIndex.Values) | Sort-Object -Property SourceObjectId -Unique).Count) preserved row(s).") -Level INFO
    }

    # --- Build the source item list -------------------------------------------------------------
    # Entra ID knows nothing of LegacyExchangeDN, the proxy addresses or the recipient type, so a
    # user's mailbox row is looked up by either of its addresses.
    $mailboxIndex = @{}
    if ($UserMailboxesCsv) {
        foreach ($mailbox in @(Import-MigrationCsv -Path $UserMailboxesCsv)) {
            foreach ($keyColumn in @('UserPrincipalName', 'PrimarySmtpAddress')) {
                $keyValue = Get-MigrationCsvValue -Row $mailbox -Name $keyColumn -Default ''
                if ($keyValue -and -not $mailboxIndex.ContainsKey($keyValue.ToLowerInvariant())) {
                    $mailboxIndex[$keyValue.ToLowerInvariant()] = $mailbox
                }
            }
        }
    }

    $items = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($source in @(Import-MigrationCsv -Path $UsersCsv -RequiredColumns @('UserPrincipalName'))) {
        $sourceUpn = Get-MigrationCsvValue -Row $source -Name 'UserPrincipalName' -Default ''
        $sourceSmtp = Get-MigrationCsvValue -Row $source -Name 'PrimarySmtpAddress' -Default ''
        $isGuest = ((Get-MigrationCsvValue -Row $source -Name 'UserType' -Default 'Member') -ieq 'Guest') -or ($sourceUpn -match '#EXT#')
        $primary = if ($sourceSmtp) { $sourceSmtp } else { $sourceUpn }

        $mailbox = $null
        foreach ($lookup in @($sourceUpn, $sourceSmtp)) {
            if ($lookup -and $mailboxIndex.ContainsKey($lookup.ToLowerInvariant())) { $mailbox = $mailboxIndex[$lookup.ToLowerInvariant()]; break }
        }

        $proxyRaw = Get-MigrationCsvValue -Row $source -Name 'ProxyAddresses' -Default ''
        if (-not $proxyRaw -and $mailbox) { $proxyRaw = Get-MigrationCsvValue -Row $mailbox -Name 'EmailAddresses' -Default '' }

        $row = New-PlanSourceRow -Source $source -Kind 'User' -Primary $primary -ProxyValue $proxyRaw -Detail $mailbox
        $row.ObjectType = if ($isGuest) { 'Guest' } else { 'User' }
        $row.SourceUserPrincipalName = $sourceUpn
        $row.SourcePrimarySmtp = $sourceSmtp
        $row.UsageLocation = Get-MigrationCsvValue -Row $source -Name 'UsageLocation' -Default $DefaultUsageLocation
        $row.MailboxType = if ($mailbox) { Get-MigrationCsvValue -Row $mailbox -Name 'RecipientTypeDetails' -Default 'UserMailbox' } else { 'UserMailbox' }
        $row.SourceLicenses = Get-MigrationCsvValue -Row $source -Name 'Licenses' -Default ''

        $items.Add(@{
                Row = $row; Source = $source; SourceKind = 'User'; IsGuest = $isGuest; UsesTemplate = -not $isGuest
                Key = if ($row.SourceObjectId) { $row.SourceObjectId } else { $primary }
            })
    }

    if ($SharedMailboxesCsv) {
        foreach ($source in @(Import-MigrationCsv -Path $SharedMailboxesCsv -RequiredColumns @('PrimarySmtpAddress'))) {
            $primary = Get-MigrationCsvValue -Row $source -Name 'PrimarySmtpAddress' -Default ''
            $recipientType = Get-MigrationCsvValue -Row $source -Name 'RecipientTypeDetails' -Default 'SharedMailbox'

            $row = New-PlanSourceRow -Source $source -Kind 'SharedMailbox' -Primary $primary `
                -ProxyValue (Get-MigrationCsvValue -Row $source -Name 'EmailAddresses' -Default '')
            $row.ObjectType = if ($script:MailboxTypeMap.ContainsKey($recipientType)) { $script:MailboxTypeMap[$recipientType] } else { 'Shared' }
            $row.SourceUserPrincipalName = Get-MigrationCsvValue -Row $source -Name 'UserPrincipalName' -Default ''
            $row.MailboxType = $recipientType

            $items.Add(@{
                    Row = $row; Source = $source; SourceKind = 'SharedMailbox'; IsGuest = $false; UsesTemplate = $false
                    Key = if ($row.SourceObjectId) { $row.SourceObjectId } else { $primary }
                })
        }
    }

    if ($GroupsCsv) {
        foreach ($source in @(Import-MigrationCsv -Path $GroupsCsv -RequiredColumns @('DisplayName'))) {
            $primary = Get-MigrationCsvValue -Row $source -Name 'PrimarySmtpAddress' -Default ''
            $groupType = Get-MigrationCsvValue -Row $source -Name 'GroupType' -Default 'Distribution'

            $row = New-PlanSourceRow -Source $source -Kind 'Group' -Primary $primary `
                -ProxyValue (Get-MigrationCsvValue -Row $source -Name 'EmailAddresses' -Default '')
            $row.ObjectType = if ($script:GroupTypeMap.ContainsKey($groupType)) { $script:GroupTypeMap[$groupType] } else { 'Distribution' }
            # The plan enum has no SecurityGroup member, so the real Entra group type is kept in
            # MailboxType where the operator - and the readiness check - can still see it.
            $row.MailboxType = $groupType

            $items.Add(@{
                    Row = $row; Source = $source; SourceKind = 'Group'; IsGuest = $false; UsesTemplate = $false
                    Key = if ($row.SourceObjectId) { $row.SourceObjectId } else { $row.DisplayName }
                    PresetExcludeWhy = if ($script:GroupExcludeReasons.ContainsKey($groupType)) { $script:GroupExcludeReasons[$groupType] }
                    elseif (-not $primary) { 'Not mail-enabled' }
                    else { '' }
                })
        }
    }

    if ($ContactsCsv) {
        foreach ($source in @(Import-MigrationCsv -Path $ContactsCsv -RequiredColumns @('DisplayName'))) {
            $primary = Get-MigrationCsvValue -Row $source -Name 'PrimarySmtpAddress' -Default ''

            $row = New-PlanSourceRow -Source $source -Kind 'Contact' -Primary $primary `
                -ProxyValue (Get-MigrationCsvValue -Row $source -Name 'EmailAddresses' -Default '')
            $row.ObjectType = 'Contact'
            $row.MailboxType = 'MailContact'
            # What a contact actually points at, recorded as the manager-free equivalent of a
            # source UPN for traceability.
            $row.SourceUserPrincipalName = Get-MigrationCsvValue -Row $source -Name 'ExternalEmailAddress' -Default ''

            $items.Add(@{
                    Row = $row; Source = $source; SourceKind = 'Contact'; IsGuest = $false; UsesTemplate = $false
                    Key = if ($row.SourceObjectId) { $row.SourceObjectId } else { $primary }
                })
        }
    }

    Write-MigrationLog -Message "Prepared $($items.Count) source object(s) for planning." -Level INFO
    if ($items.Count -eq 0) { throw 'No source objects were loaded - check the inventory CSVs.' }

    # --- Exclusions, preservation and waves -----------------------------------------------------
    foreach ($item in $items) {
        $row = $item.Row

        $row.Wave = $DefaultWave
        foreach ($waveKey in @($row.SourceUserPrincipalName, $row.SourcePrimarySmtp)) {
            if ($waveKey -and $waveMap.ContainsKey($waveKey.ToLowerInvariant())) {
                $row.Wave = $waveMap[$waveKey.ToLowerInvariant()]
                break
            }
        }

        $preserved = $null
        foreach ($keyColumn in $script:IdentityColumns) {
            $keyValue = Get-MigrationCsvValue -Row $row -Name $keyColumn -Default ''
            if (-not $keyValue) { continue }
            $indexKey = "$keyColumn|$($keyValue.ToLowerInvariant())"
            if ($preservedIndex.ContainsKey($indexKey)) { $preserved = $preservedIndex[$indexKey]; break }
        }

        $item['IsPreserved'] = [bool]$preserved
        if ($preserved) {
            foreach ($field in $script:PreservedFields) { $row.$field = Get-MigrationCsvValue -Row $preserved -Name $field -Default '' }
            continue
        }

        $excludeReason = if ($item.ContainsKey('PresetExcludeWhy')) { [string]$item['PresetExcludeWhy'] } else { '' }
        if (-not $excludeReason) { $excludeReason = Get-PlanExclusionReason -Row $item.Source -Rule $exclusionRules }
        if (-not $excludeReason -and $row.IsSynced -eq 'True' -and -not $IncludeSynced) { $excludeReason = 'Directory-synced' }
        if (-not $excludeReason -and $item.SourceKind -eq 'User') {
            if ($row.AccountEnabled -eq 'False' -and -not $IncludeDisabled) { $excludeReason = 'Account disabled' }
            elseif ($item.IsGuest -and -not $IncludeGuests) { $excludeReason = 'Guest account' }
        }

        $item['IsExcluded'] = [bool]$excludeReason
        if ($excludeReason) {
            $row.PlanStatus = 'Excluded'
            $row.ExcludeReason = $excludeReason
        }
    }

    # --- Naming ---------------------------------------------------------------------------------
    $planned = @($items | Where-Object { -not $_.IsPreserved -and -not $_.IsExcluded })

    foreach ($item in $planned) {
        $row = $item.Row

        if ($item.IsGuest) {
            # A guest is an invitation to an identity that lives in another tenant. Rewriting it
            # would break the link, so it is carried across exactly as Entra ID stores it, and the
            # nickname is only a legal placeholder - Entra generates the real one.
            $item['UpnLocalPart'] = ''
            $item['SmtpLocalPart'] = ''
            $item['NicknameLocalPart'] = ((Split-PlanAddress -Address $row.SourceUserPrincipalName).Local.ToLowerInvariant() -replace '[^a-z0-9._-]', '')
            $item['MissingTokens'] = @()
            continue
        }

        $sourceAddress = if ($row.SourcePrimarySmtp) { $row.SourcePrimarySmtp } else { $row.SourceUserPrincipalName }
        $nameArguments = @{
            FirstName       = $row.FirstName
            MiddleName      = $row.MiddleName
            LastName        = $row.LastName
            SourceLocalPart = (Split-PlanAddress -Address $sourceAddress).Local
            DisplayName     = $row.DisplayName
        }

        $missing = [System.Collections.Generic.List[string]]::new()
        $build = {
            param([string]$Template)
            $result = ConvertTo-MigrationLocalPart -Template $Template @nameArguments
            foreach ($token in @($result.MissingTokens)) {
                if ($token -and -not $missing.Contains($token)) { $missing.Add($token) }
            }
            return [string]$result.LocalPart
        }

        # Only a user account carries a user principal name. Shared mailboxes, groups and contacts
        # are addressed by their primary SMTP address alone, so their UPN columns stay empty rather
        # than holding an address nothing will ever sign in to.
        $item['UpnLocalPart'] = if ($row.ObjectType -eq 'User') { & $build $UpnFormat } else { '' }
        $item['SmtpLocalPart'] = & $build $(if ($item.UsesTemplate) { $smtpTemplate } else { 'Keep' })
        $item['NicknameLocalPart'] = if ($nicknameTemplate) { & $build $nicknameTemplate } else { '' }
        $item['WantedUpnLocalPart'] = $item['UpnLocalPart']
        $item['WantedSmtpLocalPart'] = $item['SmtpLocalPart']
        $item['MissingTokens'] = [string[]]$missing.ToArray()

        if ($missing.Count -gt 0) {
            $row.PlanStatus = 'NeedsReview'
            $row.PlanDetail = 'Could not build a destination address from the source name (missing: ' +
                ($missing.ToArray() -join ', ') + '). Fill in the target columns by hand.'
        }
    }

    # --- Collision resolution -------------------------------------------------------------------
    $namedItems = @($planned | Where-Object { $_.Row.PlanStatus -ne 'NeedsReview' -and -not $_.IsGuest })
    $newCandidate = {
        param($Item, [string]$Slot)
        [pscustomobject]@{
            Key = [string]$Item.Key; LocalPart = [string]$Item[$Slot]
            MiddleInitial = [string]$Item.Row.MiddleName; Domain = $targetDomainName
        }
    }

    # Only users hold a user principal name, which is why the UPN set is deliberately smaller.
    $collisionSets = @(
        @{ Kind = 'UPN'; Slot = 'UpnLocalPart'; Resolved = @(Resolve-MigrationCollision -Reserved $reservedAddresses.ToArray() `
                    -Candidates @($namedItems | Where-Object { $_.Row.ObjectType -eq 'User' } | ForEach-Object { & $newCandidate $_ 'UpnLocalPart' })) }
        @{ Kind = 'SMTP'; Slot = 'SmtpLocalPart'; Resolved = @(Resolve-MigrationCollision -Reserved $reservedAddresses.ToArray() `
                    -Candidates @($namedItems | ForEach-Object { & $newCandidate $_ 'SmtpLocalPart' })) }
    )
    foreach ($set in $collisionSets) {
        $set['ByKey'] = @{}
        foreach ($resolved in $set.Resolved) { $set['ByKey'][[string]$resolved.Key] = $resolved }
    }

    # Who ended up holding each address, so a collision message can name the winner.
    $itemByKey = @{}
    foreach ($item in $items) { $itemByKey[[string]$item.Key] = $item }
    $describeClaimant = {
        param([object[]]$Resolved, [string]$LocalPart)
        foreach ($entry in $Resolved) {
            if ([string]$entry.ResolvedLocalPart -ne $LocalPart) { continue }
            $owner = $itemByKey[[string]$entry.Key]
            if ($null -eq $owner) { return '' }
            return [string](@($owner.Row.SourceUserPrincipalName, $owner.Row.SourcePrimarySmtp,
                    $owner.Row.DisplayName) | Where-Object { $_ } | Select-Object -First 1)
        }
        return ''
    }

    foreach ($item in $namedItems) {
        $key = [string]$item.Key
        $details = [System.Collections.Generic.List[string]]::new()

        foreach ($set in $collisionSets) {
            if (-not $set.ByKey.ContainsKey($key)) { continue }
            $resolved = $set.ByKey[$key]
            $item[$set.Slot] = [string]$resolved.ResolvedLocalPart
            if (-not $resolved.Collided) { continue }

            $wanted = [string]$item["Wanted$($set.Slot)"]
            $claimant = & $describeClaimant $set.Resolved $wanted
            $taken = if ($claimant) { "taken by $claimant" } else { 'already reserved in the destination' }

            if ($resolved.Resolution -eq 'Unresolved') {
                $item[$set.Slot] = ''
                $details.Add("$($set.Kind) ${wanted}@$targetDomainName is $taken and no free alternative was found - assign one by hand.")
            }
            else {
                $details.Add("$($set.Kind) ${wanted}@$targetDomainName is $taken; used $($resolved.ResolvedLocalPart)@$targetDomainName.")
            }
        }

        if ($details.Count -gt 0) {
            $item.Row.PlanStatus = 'Collision'
            $item.Row.PlanDetail = ($details -join ' ')
        }
    }

    # --- Addresses, licences, aliases and validation ---------------------------------------------
    foreach ($item in $planned) {
        $row = $item.Row

        if ($item.IsGuest) {
            $row.TargetUserPrincipalName = $row.SourceUserPrincipalName
            $row.TargetPrimarySmtp = $row.SourcePrimarySmtp
            $row.TargetMailNickname = [string]$item['NicknameLocalPart']
            $row.InterimUserPrincipalName = $row.TargetUserPrincipalName
            $row.InterimPrimarySmtp = $row.TargetPrimarySmtp
            if (-not $row.PlanDetail) {
                $row.PlanDetail = 'Guest kept with its existing external identity; re-invite it in the destination tenant.'
            }
        }
        else {
            $upnLocalPart = [string]$item['UpnLocalPart']
            $smtpLocalPart = [string]$item['SmtpLocalPart']

            if ($upnLocalPart) {
                $row.TargetUserPrincipalName = "$upnLocalPart@$targetDomainName"
                $row.InterimUserPrincipalName = if ($interimDomainName) { "$upnLocalPart@$interimDomainName" } else { $row.TargetUserPrincipalName }
            }
            if ($smtpLocalPart) {
                $row.TargetPrimarySmtp = "$smtpLocalPart@$targetDomainName"
                $row.InterimPrimarySmtp = if ($interimDomainName) { "$smtpLocalPart@$interimDomainName" } else { $row.TargetPrimarySmtp }
            }

            $nickname = if ($item['NicknameLocalPart']) { [string]$item['NicknameLocalPart'] } else { $smtpLocalPart }
            $row.TargetMailNickname = ($nickname -replace '[^a-z0-9._-]', '')
        }

        $licenseResult = Get-PlanTargetLicense -SourceLicense $row.SourceLicenses -SkuMap $skuMap
        $row.TargetLicenses = Join-MigrationList -Values $licenseResult.Licenses
        $licenseNotes = [System.Collections.Generic.List[string]]::new()
        if ($licenseResult.Unmapped.Count -gt 0) {
            $licenseNotes.Add('No SKU mapping for ' + ($licenseResult.Unmapped -join ', ') + ' - carried through unchanged.')
        }
        if ($licenseResult.Dropped.Count -gt 0) {
            $licenseNotes.Add('SKU map drops ' + ($licenseResult.Dropped -join ', ') + '.')
        }

        # Mail sent to an old address keeps arriving for months, so the old local part is re-created
        # in the destination - but only in a domain the operator named, because an address in a
        # domain nobody owns is not routable.
        $aliases = [System.Collections.Generic.List[string]]::new()
        if ($PreserveAliases) {
            foreach ($entry in @($row.SourcePrimarySmtp) + @(Split-MigrationList -Value $row.SourceAliases)) {
                $parsed = Split-MigrationProxyAddress -Entry $entry
                if ($parsed.Kind -ne 'Smtp') { continue }
                $split = Split-PlanAddress -Address $parsed.Address
                if (-not $aliasDomainLookup.ContainsKey($split.Domain)) { continue }
                $candidate = 'smtp:' + $split.Local.ToLowerInvariant() + '@' + $aliasDomainLookup[$split.Domain]
                if (-not $aliases.Contains($candidate)) { $aliases.Add($candidate) }
            }
        }

        # The legacy DN always travels, aliases or not: without it, replies to pre-migration mail
        # bounce with an IMCEAEX non-delivery report.
        foreach ($x500 in @(ConvertTo-MigrationX500 -Value @($row.LegacyExchangeDN, $row.SourceX500))) {
            if (-not $aliases.Contains($x500)) { $aliases.Add($x500) }
        }

        $primaryForms = @($row.TargetPrimarySmtp, $row.InterimPrimarySmtp) |
            Where-Object { $_ } | ForEach-Object { 'smtp:' + $_.ToLowerInvariant() }
        $row.TargetAliases = Join-MigrationList -Values ([string[]]@($aliases | Where-Object { $primaryForms -notcontains $_ }))

        if ($row.PlanStatus -eq 'NeedsReview') {
            foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'TargetAliases',
                    'TargetMailNickname', 'InterimUserPrincipalName', 'InterimPrimarySmtp')) {
                $row.$column = ''
            }
            continue
        }

        $invalidReason = ''
        foreach ($check in @(
                @{ Column = 'TargetUserPrincipalName'; Kind = 'Upn' }
                @{ Column = 'InterimUserPrincipalName'; Kind = 'Upn' }
                @{ Column = 'TargetPrimarySmtp'; Kind = 'Smtp' }
                @{ Column = 'InterimPrimarySmtp'; Kind = 'Smtp' }
                @{ Column = 'TargetMailNickname'; Kind = 'MailNickname' })) {
            $value = [string]$row.($check.Column)
            if (-not $value) { continue }
            $verdict = Test-MigrationAddress -Address $value -Kind $check.Kind
            if (-not $verdict.IsValid) {
                $invalidReason = "$($check.Column) '$value' is not usable: $($verdict.Reason)"
                break
            }
        }

        if ($invalidReason) {
            $row.PlanStatus = 'Invalid'
            $row.PlanDetail = (@($row.PlanDetail, $invalidReason) | Where-Object { $_ }) -join ' '
        }
        elseif ($row.PlanStatus -ne 'Collision') {
            $divergent = (-not $item.IsGuest) -and $row.TargetUserPrincipalName -and $row.TargetPrimarySmtp -and
                ($row.TargetUserPrincipalName -ne $row.TargetPrimarySmtp)
            $row.PlanStatus = if ($divergent) { 'UpnSmtpDiverge' } else { 'Planned' }
            if ($divergent -and -not $row.PlanDetail) {
                $row.PlanDetail = 'The user principal name and the primary SMTP address differ; both are set explicitly.'
            }
        }

        if ($licenseNotes.Count -gt 0) {
            $row.PlanDetail = (@($row.PlanDetail) + $licenseNotes.ToArray() | Where-Object { $_ }) -join ' '
        }
    }

    # --- Summary and write ------------------------------------------------------------------------
    $planRows = @($items | ForEach-Object { $_.Row })

    Write-MigrationLog -Message '--- Plan summary ---' -Level SUCCESS
    foreach ($group in ($planRows | Group-Object -Property ObjectType | Sort-Object -Property Name)) {
        $breakdown = @($group.Group | Group-Object -Property PlanStatus | Sort-Object -Property Name |
                ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
        Write-MigrationLog -Message ('  {0,-20} {1,4}  ({2})' -f $group.Name, $group.Count, $breakdown) -Level SUCCESS
    }
    Write-MigrationLog -Message ('  {0,-20} {1,4}' -f 'Total', $planRows.Count) -Level SUCCESS

    $attention = @($planRows | Where-Object { $_.PlanStatus -in @('NeedsReview', 'Collision', 'Invalid') })
    if ($attention.Count -gt 0) {
        Write-MigrationLog -Message "$($attention.Count) row(s) need an operator decision before provisioning:" -Level WARNING
        foreach ($row in $attention) {
            $identity = @($row.SourceUserPrincipalName, $row.SourcePrimarySmtp, $row.DisplayName) |
                Where-Object { $_ } | Select-Object -First 1
            Write-MigrationLog -Message ('  [{0}] {1} - {2}' -f $row.PlanStatus, $identity, $row.PlanDetail) -Level WARNING
        }
    }

    $leader = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
    $planPath = Join-Path -Path $run.OutputDirectory -ChildPath ("${leader}IdentityPlan_{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    if ($PSCmdlet.ShouldProcess($planPath, "Write $($planRows.Count) identity plan row(s)")) {
        Invoke-MigrationAction -Description "Write the identity plan to $planPath" -Action {
            Save-MigrationPlan -Path $planPath -Rows $planRows
        }
    }
}
catch {
    Write-MigrationLog -Message "Fatal error: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message "At: $($_.ScriptStackTrace)" -Level DEBUG
    $exitCode = 1
}

#endregion -----------------------------------------------------------------------------

#region Cleanup ------------------------------------------------------------------------

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion -----------------------------------------------------------------------------
