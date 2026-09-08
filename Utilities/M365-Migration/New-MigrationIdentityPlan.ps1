#Requires -Version 7.4

<#
.SYNOPSIS
    Turns source-tenant inventory CSVs into the identity plan every later phase reads.

.DESCRIPTION
    This is the offline heart of the migration toolkit. It never connects to a tenant: it
    reads the CSVs produced by Get-MigrationInventory.ps1, decides what every source object
    is going to be called in the destination tenant, and writes one IdentityPlan.csv that
    the provisioning, licensing and cutover scripts then act on.

    Deciding names offline matters because the plan is the artefact the client signs off.
    An operator can open it, correct a surname, override an address, and re-run the writers
    without ever asking the tool to guess again.

    For every source object the script:
      * classifies it (User, Guest, Shared, Room, Equipment, Distribution,
        MailEnabledSecurity, DynamicDistribution, Contact, M365Group);
      * excludes what must not be migrated - break-glass accounts, service accounts,
        directory-synced objects, disabled accounts, guests, Entra groups Fly handles -
        recording why in ExcludeReason rather than dropping the row;
      * builds the destination local part from a naming template (-UpnFormat, -SmtpFormat,
        -MailNicknameFormat), transliterating accents and stripping apostrophes;
      * resolves collisions deterministically, preferring a middle initial over a numeric
        suffix, taking addresses already used in the destination into account;
      * validates every address it produced;
      * maps source licences through a SKU map;
      * carries the LegacyExchangeDN across as an X500 address so that replies to old mail
        do not bounce with an IMCEAEX non-delivery report;
      * assigns waves.

    Nothing is guessed. A name that cannot be templated (no surname, a name written only in
    a non-Latin script) is marked NeedsReview with the target columns left empty, which is
    the operator's cue to fill it in by hand.

    Re-running the script against an updated inventory is safe: with -ExistingPlanPath, any
    row that has already been provisioned (a non-empty TargetObjectId) or that an operator
    has marked ManualOverride keeps its destination identity verbatim, and its addresses are
    treated as reserved so no newly planned object can take them.

    The script is read-only apart from the plan file it writes, so -DryRun computes the whole
    plan, prints the summary, and writes nothing.

.PARAMETER UsersCsv
    The Users tab from Get-MigrationInventory. Required - it is the spine of the plan.

.PARAMETER UserMailboxesCsv
    The UserMailboxes tab. Optional but strongly recommended: it supplies LegacyExchangeDN,
    the existing proxy addresses and the recipient type, none of which Entra ID exposes.

.PARAMETER SharedMailboxesCsv
    The SharedMailboxes tab (shared, room, equipment and scheduling mailboxes).

.PARAMETER GroupsCsv
    The Groups tab. Distribution, mail-enabled security and dynamic distribution groups are
    planned; Microsoft 365 groups, Teams and plain security groups are recorded as excluded
    because a third-party mover (Fly) or Entra itself owns them.

.PARAMETER ContactsCsv
    The Contacts tab (mail contacts).

.PARAMETER TargetDomain
    The destination vanity domain, with or without a leading '@' - for example newco.com.
    Every templated address is built in this domain.

.PARAMETER InterimDomain
    An optional routing domain used before the vanity domain cuts over, typically
    newco.onmicrosoft.com. When supplied the Interim* columns are built in this domain;
    when omitted the Interim* columns simply mirror the Target* columns.

.PARAMETER UpnFormat
    Naming template or preset for the destination user principal name. Default 'First.Last'.
    Presets: First.Last, FLast, F.Last, FirstLast, First, First.L, FirstL, First.M.Last,
    FMLast, Last.First, Keep. Templates use {first} {last} {middle} {f} {m} {l} {source}
    {display} with optional truncation, for example '{f}{last:12}'.

.PARAMETER SmtpFormat
    Naming template or preset for the destination primary SMTP address. Defaults to
    -UpnFormat, which is what keeps the UPN and the mail address identical.

.PARAMETER MailNicknameFormat
    Naming template or preset for the mail nickname (Exchange alias). When omitted the
    resolved SMTP local part is used, which is the behaviour you almost always want because
    it survives collision resolution.

.PARAMETER SkuMapPath
    CSV of SourceSkuPartNumber,TargetSkuPartNumber. A ';' separated target maps one source
    licence to several; an empty target drops the licence. Source SKUs absent from the map
    are carried through unchanged and called out in PlanDetail so the readiness check can
    flag them.

.PARAMETER ExclusionRulesPath
    CSV of Pattern,MatchOn,Reason with an optional MatchType column (Wildcard, the default,
    or Regex). Any object whose MatchOn column matches the pattern is excluded.

.PARAMETER WaveMapPath
    CSV of UserPrincipalName,Wave. Matched against the source UPN and then the source primary
    SMTP address. Objects not listed get -DefaultWave.

.PARAMETER DefaultWave
    Wave assigned to everything the wave map does not name. Default '1'.

.PARAMETER DefaultUsageLocation
    Two-letter usage location applied when the source object has none. Assigning a licence
    fails without a usage location, so setting this saves a round trip in phase 3.

.PARAMETER ExistingPlanPath
    A previous IdentityPlan.csv. Rows in it that carry a TargetObjectId or the PlanStatus
    ManualOverride keep their destination identity, wave and provisioning state verbatim,
    and their addresses become reserved.

.PARAMETER ReservedAddressesPath
    One or more files listing addresses already in use in the destination. Each file may be
    a destination inventory CSV (Users, Groups or Contacts - the address columns are read
    automatically) or a plain text list of one address per line ('#' starts a comment).

.PARAMETER IncludeDisabled
    Plan disabled source accounts instead of excluding them.

.PARAMETER IncludeGuests
    Plan guest (#EXT#) accounts instead of excluding them. Guests keep their existing
    external identity verbatim - no template is applied.

.PARAMETER IncludeSynced
    Plan directory-synced objects instead of excluding them. Synced objects are excluded by
    default because their authoritative copy lives in on-premises Active Directory.

.PARAMETER PreserveAliases
    Carry the source proxy addresses across as destination aliases, re-domained through
    -AliasDomainMap. Without -AliasDomainMap there is nothing to re-domain, so the switch
    only warns.

.PARAMETER AliasDomainMap
    Hashtable of source domain to destination domain, for example
    @{ 'contoso.com' = 'newco.com'; 'contoso.co.uk' = 'newco.co.uk' }.

.PARAMETER OutputPath
    Directory for the plan and the log. Defaults to the toolkit output root.

.PARAMETER Prefix
    Client or run name. When supplied, output lands in <OutputPath>\<Prefix>\ and file names
    start with '<Prefix>_'.

.PARAMETER LogPath
    Override for the log file path.

.PARAMETER DryRun
    Compute the entire plan and print the summary without writing the plan file.

.PARAMETER Verbosity
    Console noise level: Low (errors and successes), Medium (adds warnings, the default) or
    High (everything). The log file always receives everything.

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

    Full offline dress rehearsal: every object type, interim routing addresses, licence
    mapping, aliases re-domained, waves applied - summary printed, nothing written.

.EXAMPLE
    .\New-MigrationIdentityPlan.ps1 -UsersCsv .\Users.csv -TargetDomain newco.com `
        -ExistingPlanPath .\Contoso_IdentityPlan_20260901-090000.csv `
        -ReservedAddressesPath .\Destination_Users.csv, .\Destination_Groups.csv

    Re-plans after a second inventory pull. Already provisioned and manually overridden rows
    keep their identity, and addresses already live in the destination are never reused.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4+ and the bundled M365Migration module. No tenant connection
                  is made and no Graph scope or Exchange Online role is needed - this script
                  is entirely offline, so GDAP does not apply.
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

# Exchange recipient type to plan ObjectType. Scheduling mailboxes are resource mailboxes
# that behave like equipment, so they land in the same bucket rather than inventing a type.
$script:MailboxTypeMap = @{
    'SharedMailbox'     = 'Shared'
    'RoomMailbox'       = 'Room'
    'EquipmentMailbox'  = 'Equipment'
    'SchedulingMailbox' = 'Equipment'
}

# Inventory GroupType to plan ObjectType. The three informational kinds are recorded so the
# operator can see they were considered, but no writer in the toolkit acts on them.
$script:GroupTypeMap = @{
    'Distribution'        = 'Distribution'
    'MailEnabledSecurity' = 'MailEnabledSecurity'
    'DynamicDistribution' = 'DynamicDistribution'
    'M365Group'           = 'M365Group'
    'Team'                = 'M365Group'
    'SecurityGroup'       = 'M365Group'
}

$script:GroupExcludeReasons = @{
    'M365Group'     = 'Migrated by Fly'
    'Team'          = 'Migrated by Fly'
    'SecurityGroup' = 'Not mail-enabled'
}

# Columns of a destination inventory CSV that can hold an address already in use.
$script:ReservedAddressColumns = @(
    'UserPrincipalName', 'PrimarySmtpAddress', 'TargetUserPrincipalName', 'TargetPrimarySmtp',
    'InterimUserPrincipalName', 'InterimPrimarySmtp', 'EmailAddresses', 'ProxyAddresses',
    'ExternalEmailAddress', 'TargetAliases'
)

#endregion -----------------------------------------------------------------------------

#region Functions ----------------------------------------------------------------------

function Get-PlanLocalPart {
    <#
    .SYNOPSIS
        Returns the part of an address before the '@'.
    .DESCRIPTION
        Guest UPNs contain '#EXT#' before the '@' and must survive untouched, so the split
        is deliberately naive: everything up to the first '@' is the local part.
    .PARAMETER Address
        The address to split. A value with no '@' is returned unchanged.
    .EXAMPLE
        Get-PlanLocalPart -Address 'jsmith@contoso.com'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return '' }
    $trimmed = $Address.Trim()
    if (-not $trimmed.Contains('@')) { return $trimmed }
    return $trimmed.Split('@', 2)[0]
}

function Get-PlanDomainPart {
    <#
    .SYNOPSIS
        Returns the domain of an address, lowercased.
    .PARAMETER Address
        The address to split.
    .EXAMPLE
        Get-PlanDomainPart -Address 'jsmith@Contoso.com'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return '' }
    $trimmed = $Address.Trim()
    if (-not $trimmed.Contains('@')) { return '' }
    return $trimmed.Split('@', 2)[1].ToLowerInvariant()
}

function Get-PlanProxyAddressSet {
    <#
    .SYNOPSIS
        Splits a proxy-address list into SMTP aliases and X500 addresses.
    .DESCRIPTION
        Exchange stores every address of a recipient in one multi-valued attribute using a
        prefix convention: uppercase 'SMTP:' is the primary, lowercase 'smtp:' an alias,
        'X500:' a legacy distinguished name and 'sip:'/'spo:'/'eum:' belong to other
        workloads. Only the mail addresses and the X500 entries are migration-relevant, so
        the rest are dropped rather than carried into the destination.
    .PARAMETER Value
        The ';' separated proxy-address list from the inventory.
    .PARAMETER PrimaryAddress
        The recipient's primary SMTP address, which is excluded from the alias list because
        the plan already records it as SourcePrimarySmtp.
    .EXAMPLE
        Get-PlanProxyAddressSet -Value 'SMTP:a@contoso.com;smtp:b@contoso.com' -PrimaryAddress 'a@contoso.com'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$PrimaryAddress
    )

    $primary = ''
    if (-not [string]::IsNullOrWhiteSpace($PrimaryAddress)) { $primary = $PrimaryAddress.Trim().ToLowerInvariant() }

    $aliases = [System.Collections.Generic.List[string]]::new()
    $x500 = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @(Split-MigrationList -Value $Value)) {
        $prefix = 'smtp'
        $rest = $entry
        if ($entry -match '^(?<prefix>[A-Za-z0-9]+):(?<rest>.+)$') {
            $prefix = $Matches['prefix'].ToLowerInvariant()
            $rest = $Matches['rest']
        }

        switch ($prefix) {
            'smtp' {
                $address = $rest.Trim().ToLowerInvariant()
                if ($address -and $address -ne $primary) {
                    $candidate = "smtp:$address"
                    if (-not $aliases.Contains($candidate)) { $aliases.Add($candidate) }
                }
            }
            'x500' {
                $candidate = 'X500:' + $rest.Trim()
                if (-not $x500.Contains($candidate)) { $x500.Add($candidate) }
            }
            default {
                # sip:, spo: and eum: addresses belong to Teams, SharePoint and Unified
                # Messaging; they are re-created by those workloads in the destination.
            }
        }
    }

    return [pscustomobject]@{
        Aliases = [string[]]$aliases.ToArray()
        X500    = [string[]]$x500.ToArray()
    }
}

function Get-PlanX500List {
    <#
    .SYNOPSIS
        Normalises legacy distinguished names into X500 proxy-address form.
    .PARAMETER Value
        A ';' separated list of X500 addresses or bare legacy distinguished names.
    .EXAMPLE
        Get-PlanX500List -Value '/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=abc'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(Split-MigrationList -Value $Value)) {
        $text = $entry.Trim()
        if (-not $text) { continue }
        if ($text -notmatch '^(?i)x500:') { $text = "X500:$text" }
        else { $text = 'X500:' + $text.Substring(5) }
        if (-not $result.Contains($text)) { $result.Add($text) }
    }
    return [string[]]$result.ToArray()
}

function Import-PlanExclusionRule {
    <#
    .SYNOPSIS
        Reads the exclusion rule file.
    .DESCRIPTION
        Rules are wildcard patterns by default because that is what an operator writes by
        hand ('break-glass*', '*.breakglass@*'). A rule that needs the full expressive power
        of a regular expression sets MatchType to Regex in an optional fourth column.
    .PARAMETER Path
        The exclusion rules CSV: Pattern, MatchOn, Reason and optionally MatchType.
    .EXAMPLE
        Import-PlanExclusionRule -Path .\Templates\ExclusionRules.sample.csv
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $rows = @(Import-MigrationCsv -Path $Path -RequiredColumns @('Pattern', 'MatchOn'))
    $rules = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 1

    foreach ($row in $rows) {
        $lineNumber++
        $pattern = Get-MigrationCsvValue -Row $row -Name 'Pattern' -Default ''
        $matchOn = Get-MigrationCsvValue -Row $row -Name 'MatchOn' -Default ''
        if (-not $pattern -or -not $matchOn) {
            throw "The exclusion rules file '$Path' has an empty Pattern or MatchOn on line $lineNumber."
        }

        $matchType = Get-MigrationCsvValue -Row $row -Name 'MatchType' -Default 'Wildcard'
        if ($matchType -notin @('Wildcard', 'Regex')) {
            throw "The exclusion rules file '$Path' has MatchType '$matchType' on line $lineNumber; use Wildcard or Regex."
        }

        if ($matchType -eq 'Regex') {
            try { $null = [regex]::new($pattern) }
            catch { throw "The exclusion rules file '$Path' has an invalid regular expression on line ${lineNumber}: $($_.Exception.Message)" }
        }

        $rules.Add([pscustomobject]@{
                Pattern   = $pattern
                MatchOn   = $matchOn
                MatchType = $matchType
                Reason    = (Get-MigrationCsvValue -Row $row -Name 'Reason' -Default "Matched exclusion rule '$pattern' on $matchOn")
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
        [Parameter(Mandatory)]
        [AllowNull()]
        $Row,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rule
    )

    foreach ($rule in @($Rule)) {
        $value = Get-MigrationCsvValue -Row $Row -Name $rule.MatchOn -Default ''
        if (-not $value) { continue }

        $isMatch = if ($rule.MatchType -eq 'Regex') { $value -match $rule.Pattern } else { $value -like $rule.Pattern }
        if ($isMatch) { return [string]$rule.Reason }
    }

    return ''
}

function Import-PlanWaveMap {
    <#
    .SYNOPSIS
        Reads the wave map into an address-keyed hashtable.
    .PARAMETER Path
        CSV of UserPrincipalName,Wave.
    .EXAMPLE
        Import-PlanWaveMap -Path .\Waves.csv
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $rows = @(Import-MigrationCsv -Path $Path -RequiredColumns @('UserPrincipalName', 'Wave'))
    $map = @{}
    $lineNumber = 1

    foreach ($row in $rows) {
        $lineNumber++
        $identity = Get-MigrationCsvValue -Row $row -Name 'UserPrincipalName' -Default ''
        $wave = Get-MigrationCsvValue -Row $row -Name 'Wave' -Default ''
        if (-not $identity) { throw "The wave map '$Path' has an empty UserPrincipalName on line $lineNumber." }
        if (-not $wave) { throw "The wave map '$Path' has an empty Wave on line $lineNumber." }
        $map[$identity.ToLowerInvariant()] = $wave
    }

    Write-MigrationLog -Message "Loaded $($map.Count) wave assignment(s) from $Path" -Level INFO
    return $map
}

function Get-PlanReservedAddress {
    <#
    .SYNOPSIS
        Collects addresses that are already in use in the destination tenant.
    .DESCRIPTION
        Accepts either a destination inventory CSV - in which case every address-bearing
        column is harvested - or a plain text list of one address per line. Detecting the
        shape rather than demanding a format means an operator can paste a list of addresses
        into a text file and it just works.
    .PARAMETER Path
        One or more files to read.
    .EXAMPLE
        Get-PlanReservedAddress -Path .\Destination_Users.csv, .\Reserved.txt
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path
    )

    $reserved = [System.Collections.Generic.List[string]]::new()

    $addValue = {
        param([string]$Raw)
        foreach ($entry in @(Split-MigrationList -Value $Raw)) {
            $text = $entry.Trim()
            # The capture groups are read into locals immediately: the -ne test below would
            # otherwise be a second match operation and would overwrite $Matches.
            $entryPrefix = ''
            $entryRest = ''
            if ($text -match '^(?<prefix>[A-Za-z0-9]+):(?<rest>.+)$') {
                $entryPrefix = $Matches['prefix']
                $entryRest = $Matches['rest'].Trim()
            }
            if ($entryPrefix) {
                if ($entryPrefix -ne 'smtp') { continue }
                $text = $entryRest
            }
            if (-not $text.Contains('@')) { continue }
            $text = $text.ToLowerInvariant()
            if (-not $reserved.Contains($text)) { $reserved.Add($text) }
        }
    }

    foreach ($file in $Path) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Reserved address file not found: $file"
        }

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
                if (-not $text -or $text.StartsWith('#')) { continue }
                & $addValue $text
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
        An unmapped SKU is kept rather than dropped: the destination readiness check then
        reports it as unavailable, which is a far louder signal than a silently missing
        licence discovered on cutover day.
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
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SourceLicense,

        [AllowNull()]
        [hashtable]$SkuMap
    )

    $targets = [System.Collections.Generic.List[string]]::new()
    $unmapped = [System.Collections.Generic.List[string]]::new()
    $dropped = [System.Collections.Generic.List[string]]::new()

    foreach ($sku in @(Split-MigrationList -Value $SourceLicense)) {
        if ($null -eq $SkuMap) {
            if (-not $targets.Contains($sku)) { $targets.Add($sku) }
            continue
        }

        $key = @($SkuMap.Keys | Where-Object { $_ -ieq $sku } | Select-Object -First 1)
        if ($key.Count -eq 0) {
            if (-not $unmapped.Contains($sku)) { $unmapped.Add($sku) }
            if (-not $targets.Contains($sku)) { $targets.Add($sku) }
            continue
        }

        $mapped = @($SkuMap[$key[0]])
        if ($mapped.Count -eq 0) {
            if (-not $dropped.Contains($sku)) { $dropped.Add($sku) }
            continue
        }

        foreach ($target in $mapped) {
            if (-not $targets.Contains($target)) { $targets.Add($target) }
        }
    }

    return [pscustomobject]@{
        Licenses = [string[]]$targets.ToArray()
        Unmapped = [string[]]$unmapped.ToArray()
        Dropped  = [string[]]$dropped.ToArray()
    }
}

function Get-PlanRedomainedAlias {
    <#
    .SYNOPSIS
        Re-domains the source addresses that the alias domain map covers.
    .DESCRIPTION
        Mail sent to an old address keeps arriving for months after a move, so the old local
        part is re-created in the destination domain. Only domains the operator named in
        -AliasDomainMap are re-domained; anything else is left behind deliberately, because
        re-creating an address in a domain nobody owns produces a non-routable alias.
    .PARAMETER Address
        The source addresses to consider (primary plus aliases, in 'smtp:x@y' or plain form).
    .PARAMETER DomainMap
        Hashtable of source domain to destination domain.
    .EXAMPLE
        Get-PlanRedomainedAlias -Address 'smtp:jsmith@contoso.com' -DomainMap @{ 'contoso.com' = 'newco.com' }
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Address,

        [AllowNull()]
        [hashtable]$DomainMap
    )

    $result = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $DomainMap -or $DomainMap.Count -eq 0) { return [string[]]$result.ToArray() }

    $lookup = @{}
    foreach ($key in $DomainMap.Keys) {
        $lookup[([string]$key).Trim().TrimStart('@').ToLowerInvariant()] = ([string]$DomainMap[$key]).Trim().TrimStart('@').ToLowerInvariant()
    }

    foreach ($entry in @($Address)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $text = $entry.Trim()
        if ($text -match '^(?i)smtp:(?<rest>.+)$') { $text = $Matches['rest'].Trim() }
        if (-not $text.Contains('@')) { continue }

        $localPart = Get-PlanLocalPart -Address $text
        $domain = Get-PlanDomainPart -Address $text
        if (-not $lookup.ContainsKey($domain)) { continue }

        $candidate = 'smtp:' + $localPart.ToLowerInvariant() + '@' + $lookup[$domain]
        if (-not $result.Contains($candidate)) { $result.Add($candidate) }
    }

    return [string[]]$result.ToArray()
}

function Get-PlanCollisionDetail {
    <#
    .SYNOPSIS
        Explains, in one sentence, who took the address a row wanted.
    .PARAMETER Kind
        'UPN' or 'SMTP', used to open the sentence.
    .PARAMETER WantedLocalPart
        The local part the row would have had.
    .PARAMETER Domain
        The domain the collision happened in.
    .PARAMETER ResolvedLocalPart
        The local part actually assigned.
    .PARAMETER Claimant
        Description of the object holding the wanted address, or an empty string when it was
        reserved by the destination rather than by another planned row.
    .EXAMPLE
        Get-PlanCollisionDetail -Kind UPN -WantedLocalPart john.smith -Domain newco.com -ResolvedLocalPart john.q.smith -Claimant 'jsmith@contoso.com'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('UPN', 'SMTP')][string]$Kind,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WantedLocalPart,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Domain,
        [AllowEmptyString()][string]$ResolvedLocalPart,
        [AllowEmptyString()][string]$Claimant
    )

    $taken = if ($Claimant) { "taken by $Claimant" } else { 'already reserved in the destination' }
    if ([string]::IsNullOrWhiteSpace($ResolvedLocalPart)) {
        return "$Kind ${WantedLocalPart}@$Domain is $taken and no free alternative was found - assign one by hand."
    }
    return "$Kind ${WantedLocalPart}@$Domain is $taken; used ${ResolvedLocalPart}@$Domain."
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
        Write-MigrationLog -Message '-PreserveAliases was supplied without -AliasDomainMap, so no source alias can be re-domained. Only X500 addresses will be carried across.' -Level WARNING
    }

    # --- Supporting files ------------------------------------------------------------
    $skuMap = $null
    if ($SkuMapPath) { $skuMap = Resolve-MigrationSkuMap -Path $SkuMapPath }

    $exclusionRules = @()
    if ($ExclusionRulesPath) { $exclusionRules = @(Import-PlanExclusionRule -Path $ExclusionRulesPath) }

    $waveMap = @{}
    if ($WaveMapPath) { $waveMap = Import-PlanWaveMap -Path $WaveMapPath }

    $reservedAddresses = [System.Collections.Generic.List[string]]::new()
    if ($ReservedAddressesPath) {
        foreach ($address in @(Get-PlanReservedAddress -Path $ReservedAddressesPath)) {
            if (-not $reservedAddresses.Contains($address)) { $reservedAddresses.Add($address) }
        }
    }

    # --- Rows preserved from a previous plan ------------------------------------------
    $preservedIndex = @{}
    $preservedFields = @(
        'Wave', 'InterimUserPrincipalName', 'InterimPrimarySmtp', 'TargetUserPrincipalName',
        'TargetPrimarySmtp', 'TargetAliases', 'TargetMailNickname', 'TargetLicenses',
        'PlanStatus', 'PlanDetail', 'ExcludeReason', 'TargetObjectId', 'MailboxProvisioned',
        'OneDriveProvisioned', 'ProvisionStatus', 'ProvisionDetail'
    )

    if ($ExistingPlanPath) {
        $existingRows = @(Import-MigrationPlan -Path $ExistingPlanPath)
        foreach ($existing in $existingRows) {
            $hasTargetObject = -not [string]::IsNullOrWhiteSpace((Get-MigrationCsvValue -Row $existing -Name 'TargetObjectId' -Default ''))
            $isOverride = (Get-MigrationCsvValue -Row $existing -Name 'PlanStatus' -Default '') -eq 'ManualOverride'
            if (-not $hasTargetObject -and -not $isOverride) { continue }

            foreach ($keyColumn in @('SourceObjectId', 'SourcePrimarySmtp', 'SourceUserPrincipalName')) {
                $keyValue = Get-MigrationCsvValue -Row $existing -Name $keyColumn -Default ''
                if (-not $keyValue) { continue }
                $indexKey = "$keyColumn|$($keyValue.ToLowerInvariant())"
                if (-not $preservedIndex.ContainsKey($indexKey)) { $preservedIndex[$indexKey] = $existing }
            }

            # A preserved identity is, by definition, already spoken for in the destination.
            foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'InterimUserPrincipalName', 'InterimPrimarySmtp')) {
                $address = (Get-MigrationCsvValue -Row $existing -Name $column -Default '').ToLowerInvariant()
                if ($address -and -not $reservedAddresses.Contains($address)) { $reservedAddresses.Add($address) }
            }
        }
        Write-MigrationLog -Message "Existing plan '$ExistingPlanPath' contributes $((@($preservedIndex.Values) | Sort-Object -Property SourceObjectId -Unique).Count) preserved row(s)." -Level INFO
    }

    # --- Mailbox detail keyed by address ------------------------------------------------
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

    # --- Build the source item list ------------------------------------------------------
    $items = [System.Collections.Generic.List[hashtable]]::new()

    # Users -------------------------------------------------------------------------------
    $userRows = @(Import-MigrationCsv -Path $UsersCsv -RequiredColumns @('UserPrincipalName'))
    foreach ($source in $userRows) {
        $sourceUpn = Get-MigrationCsvValue -Row $source -Name 'UserPrincipalName' -Default ''
        $sourceSmtp = Get-MigrationCsvValue -Row $source -Name 'PrimarySmtpAddress' -Default ''
        $userType = Get-MigrationCsvValue -Row $source -Name 'UserType' -Default 'Member'
        $isGuest = ($userType -ieq 'Guest') -or ($sourceUpn -match '#EXT#')

        $mailbox = $null
        foreach ($lookup in @($sourceUpn, $sourceSmtp)) {
            if ($lookup -and $mailboxIndex.ContainsKey($lookup.ToLowerInvariant())) {
                $mailbox = $mailboxIndex[$lookup.ToLowerInvariant()]
                break
            }
        }

        $primary = if ($sourceSmtp) { $sourceSmtp } else { $sourceUpn }
        $proxyRaw = Get-MigrationCsvValue -Row $source -Name 'ProxyAddresses' -Default ''
        if (-not $proxyRaw -and $mailbox) { $proxyRaw = Get-MigrationCsvValue -Row $mailbox -Name 'EmailAddresses' -Default '' }
        $proxySet = Get-PlanProxyAddressSet -Value $proxyRaw -PrimaryAddress $primary

        $legacyDn = ''
        $x500List = @()
        $mailboxType = 'UserMailbox'
        if ($mailbox) {
            $legacyDn = Get-MigrationCsvValue -Row $mailbox -Name 'LegacyExchangeDN' -Default ''
            $x500List = @(Get-PlanX500List -Value (Get-MigrationCsvValue -Row $mailbox -Name 'X500Addresses' -Default ''))
            $mailboxType = Get-MigrationCsvValue -Row $mailbox -Name 'RecipientTypeDetails' -Default 'UserMailbox'
        }
        if ($proxySet.X500.Count -gt 0) {
            $x500List = @($x500List + $proxySet.X500 | Select-Object -Unique)
        }

        $row = New-MigrationPlanRow
        $row.ObjectType = if ($isGuest) { 'Guest' } else { 'User' }
        $row.SourceObjectId = Get-MigrationCsvValue -Row $source -Name 'ObjectId' -Default ''
        $row.SourceUserPrincipalName = $sourceUpn
        $row.SourcePrimarySmtp = $sourceSmtp
        $row.SourceAliases = Join-MigrationList -Values $proxySet.Aliases
        $row.LegacyExchangeDN = $legacyDn
        $row.SourceX500 = Join-MigrationList -Values ([string[]]$x500List)
        $row.DisplayName = Get-MigrationCsvValue -Row $source -Name 'DisplayName' -Default ''
        $row.FirstName = Get-MigrationCsvValue -Row $source -Name 'FirstName' -Default ''
        $row.MiddleName = Get-MigrationCsvValue -Row $source -Name 'MiddleName' -Default ''
        $row.LastName = Get-MigrationCsvValue -Row $source -Name 'LastName' -Default ''
        $row.JobTitle = Get-MigrationCsvValue -Row $source -Name 'JobTitle' -Default ''
        $row.Department = Get-MigrationCsvValue -Row $source -Name 'Department' -Default ''
        $row.Office = Get-MigrationCsvValue -Row $source -Name 'Office' -Default ''
        $row.MobilePhone = Get-MigrationCsvValue -Row $source -Name 'MobilePhone' -Default ''
        $row.UsageLocation = Get-MigrationCsvValue -Row $source -Name 'UsageLocation' -Default $DefaultUsageLocation
        $row.ManagerUpn = Get-MigrationCsvValue -Row $source -Name 'ManagerUpn' -Default ''
        $row.MailboxType = $mailboxType
        $row.AccountEnabled = Get-MigrationCsvValue -Row $source -Name 'AccountEnabled' -Default ''
        $row.IsSynced = Get-MigrationCsvValue -Row $source -Name 'IsSynced' -Default ''
        $row.SourceLicenses = Get-MigrationCsvValue -Row $source -Name 'Licenses' -Default ''

        $items.Add(@{
            Row          = $row
            Source       = $source
            Key          = if ($row.SourceObjectId) { $row.SourceObjectId } else { $primary }
            IsGuest      = $isGuest
            UsesTemplate = -not $isGuest
            SourceKind   = 'User'
            })
    }

    # Shared, room and equipment mailboxes ------------------------------------------------
    if ($SharedMailboxesCsv) {
        foreach ($source in @(Import-MigrationCsv -Path $SharedMailboxesCsv -RequiredColumns @('PrimarySmtpAddress'))) {
            $primary = Get-MigrationCsvValue -Row $source -Name 'PrimarySmtpAddress' -Default ''
            $recipientType = Get-MigrationCsvValue -Row $source -Name 'RecipientTypeDetails' -Default 'SharedMailbox'
            $objectType = if ($script:MailboxTypeMap.ContainsKey($recipientType)) { $script:MailboxTypeMap[$recipientType] } else { 'Shared' }
            $proxySet = Get-PlanProxyAddressSet -Value (Get-MigrationCsvValue -Row $source -Name 'EmailAddresses' -Default '') -PrimaryAddress $primary
            $x500List = @(Get-PlanX500List -Value (Get-MigrationCsvValue -Row $source -Name 'X500Addresses' -Default ''))
            if ($proxySet.X500.Count -gt 0) { $x500List = @($x500List + $proxySet.X500 | Select-Object -Unique) }

            $row = New-MigrationPlanRow
            $row.ObjectType = $objectType
            $row.SourceObjectId = Get-MigrationCsvValue -Row $source -Name 'ObjectId' -Default ''
            $row.SourceUserPrincipalName = Get-MigrationCsvValue -Row $source -Name 'UserPrincipalName' -Default ''
            $row.SourcePrimarySmtp = $primary
            $row.SourceAliases = Join-MigrationList -Values $proxySet.Aliases
            $row.LegacyExchangeDN = Get-MigrationCsvValue -Row $source -Name 'LegacyExchangeDN' -Default ''
            $row.SourceX500 = Join-MigrationList -Values ([string[]]$x500List)
            $row.DisplayName = Get-MigrationCsvValue -Row $source -Name 'DisplayName' -Default ''
            $row.MailboxType = $recipientType
            $row.AccountEnabled = Get-MigrationCsvValue -Row $source -Name 'AccountEnabled' -Default ''
            $row.IsSynced = Get-MigrationCsvValue -Row $source -Name 'IsSynced' -Default ''

            $items.Add(@{
                Row          = $row
                Source       = $source
                Key          = if ($row.SourceObjectId) { $row.SourceObjectId } else { $primary }
                IsGuest      = $false
                UsesTemplate = $false
                SourceKind   = 'SharedMailbox'
                })
        }
    }

    # Groups --------------------------------------------------------------------------------
    if ($GroupsCsv) {
        foreach ($source in @(Import-MigrationCsv -Path $GroupsCsv -RequiredColumns @('DisplayName'))) {
            $primary = Get-MigrationCsvValue -Row $source -Name 'PrimarySmtpAddress' -Default ''
            $groupType = Get-MigrationCsvValue -Row $source -Name 'GroupType' -Default 'Distribution'
            $objectType = if ($script:GroupTypeMap.ContainsKey($groupType)) { $script:GroupTypeMap[$groupType] } else { 'Distribution' }
            $proxySet = Get-PlanProxyAddressSet -Value (Get-MigrationCsvValue -Row $source -Name 'EmailAddresses' -Default '') -PrimaryAddress $primary

            $row = New-MigrationPlanRow
            $row.ObjectType = $objectType
            $row.SourceObjectId = Get-MigrationCsvValue -Row $source -Name 'ObjectId' -Default ''
            $row.SourcePrimarySmtp = $primary
            $row.SourceAliases = Join-MigrationList -Values $proxySet.Aliases
            $row.LegacyExchangeDN = Get-MigrationCsvValue -Row $source -Name 'LegacyExchangeDN' -Default ''
            $row.SourceX500 = Join-MigrationList -Values $proxySet.X500
            $row.DisplayName = Get-MigrationCsvValue -Row $source -Name 'DisplayName' -Default ''
            # The plan enum has no SecurityGroup member, so the real Entra group type is kept
            # in MailboxType where the operator - and the readiness check - can still see it.
            $row.MailboxType = $groupType
            $row.IsSynced = Get-MigrationCsvValue -Row $source -Name 'IsSynced' -Default ''

            $excludeReason = ''
            if ($script:GroupExcludeReasons.ContainsKey($groupType)) { $excludeReason = $script:GroupExcludeReasons[$groupType] }
            elseif (-not $primary) { $excludeReason = 'Not mail-enabled' }

            $items.Add(@{
                Row              = $row
                Source           = $source
                Key              = if ($row.SourceObjectId) { $row.SourceObjectId } else { $row.DisplayName }
                IsGuest          = $false
                UsesTemplate     = $false
                SourceKind       = 'Group'
                PresetExcludeWhy = $excludeReason
                })
        }
    }

    # Contacts -------------------------------------------------------------------------------
    if ($ContactsCsv) {
        foreach ($source in @(Import-MigrationCsv -Path $ContactsCsv -RequiredColumns @('DisplayName'))) {
            $primary = Get-MigrationCsvValue -Row $source -Name 'PrimarySmtpAddress' -Default ''
            $external = Get-MigrationCsvValue -Row $source -Name 'ExternalEmailAddress' -Default ''
            $proxySet = Get-PlanProxyAddressSet -Value (Get-MigrationCsvValue -Row $source -Name 'EmailAddresses' -Default '') -PrimaryAddress $primary

            $row = New-MigrationPlanRow
            $row.ObjectType = 'Contact'
            $row.SourceObjectId = Get-MigrationCsvValue -Row $source -Name 'ObjectId' -Default ''
            $row.SourcePrimarySmtp = $primary
            $row.SourceAliases = Join-MigrationList -Values $proxySet.Aliases
            $row.SourceX500 = Join-MigrationList -Values $proxySet.X500
            $row.DisplayName = Get-MigrationCsvValue -Row $source -Name 'DisplayName' -Default ''
            $row.FirstName = Get-MigrationCsvValue -Row $source -Name 'FirstName' -Default ''
            $row.LastName = Get-MigrationCsvValue -Row $source -Name 'LastName' -Default ''
            $row.MailboxType = 'MailContact'
            # The external address is what a contact actually points at, so it is recorded as
            # the manager-free equivalent of a source UPN for traceability.
            $row.SourceUserPrincipalName = $external

            $items.Add(@{
                Row          = $row
                Source       = $source
                Key          = if ($row.SourceObjectId) { $row.SourceObjectId } else { $primary }
                IsGuest      = $false
                UsesTemplate = $false
                SourceKind   = 'Contact'
                })
        }
    }

    Write-MigrationLog -Message "Prepared $($items.Count) source object(s) for planning." -Level INFO
    if ($items.Count -eq 0) { throw 'No source objects were loaded - check the inventory CSVs.' }

    # --- Exclusions, preservation and waves ---------------------------------------------------
    foreach ($item in $items) {
        $row = $item.Row

        $waveKeys = @($row.SourceUserPrincipalName, $row.SourcePrimarySmtp) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToLowerInvariant() }
        $wave = $DefaultWave
        foreach ($waveKey in $waveKeys) {
            if ($waveMap.ContainsKey($waveKey)) { $wave = $waveMap[$waveKey]; break }
        }
        $row.Wave = $wave

        $preserved = $null
        foreach ($keyColumn in @('SourceObjectId', 'SourcePrimarySmtp', 'SourceUserPrincipalName')) {
            $keyValue = Get-MigrationCsvValue -Row $row -Name $keyColumn -Default ''
            if (-not $keyValue) { continue }
            $indexKey = "$keyColumn|$($keyValue.ToLowerInvariant())"
            if ($preservedIndex.ContainsKey($indexKey)) { $preserved = $preservedIndex[$indexKey]; break }
        }

        if ($preserved) {
            foreach ($field in $preservedFields) { $row.$field = Get-MigrationCsvValue -Row $preserved -Name $field -Default '' }
            $item['IsPreserved'] = $true
            continue
        }
        $item['IsPreserved'] = $false

        $excludeReason = ''
        if ($item.ContainsKey('PresetExcludeWhy') -and $item['PresetExcludeWhy']) {
            $excludeReason = $item['PresetExcludeWhy']
        }
        if (-not $excludeReason) { $excludeReason = Get-PlanExclusionReason -Row $item.Source -Rule $exclusionRules }
        if (-not $excludeReason -and $row.IsSynced -eq 'True' -and -not $IncludeSynced) {
            $excludeReason = 'Directory-synced'
        }
        if (-not $excludeReason -and $item.SourceKind -eq 'User') {
            if ($row.AccountEnabled -eq 'False' -and -not $IncludeDisabled) { $excludeReason = 'Account disabled' }
            elseif ($item.IsGuest -and -not $IncludeGuests) { $excludeReason = 'Guest account' }
        }

        if ($excludeReason) {
            $row.PlanStatus = 'Excluded'
            $row.ExcludeReason = $excludeReason
            $item['IsExcluded'] = $true
        }
        else {
            $item['IsExcluded'] = $false
        }
    }

    # --- Naming -------------------------------------------------------------------------------
    $planned = @($items | Where-Object { -not $_.IsPreserved -and -not $_.IsExcluded })

    foreach ($item in $planned) {
        $row = $item.Row
        $sourceAddress = if ($row.SourcePrimarySmtp) { $row.SourcePrimarySmtp } else { $row.SourceUserPrincipalName }
        $sourceLocalPart = Get-PlanLocalPart -Address $sourceAddress

        if ($item.IsGuest) {
            # A guest is an invitation to an identity that lives in another tenant. Rewriting
            # it would break the link, so it is carried across exactly as Entra ID stores it.
            $item['UpnLocalPart'] = ''
            $item['SmtpLocalPart'] = ''
            # Entra ID generates a guest's mail nickname itself; this is only a legal
            # placeholder, so the '#EXT#' marker and any other illegal character is stripped.
            $guestLocalPart = (Get-PlanLocalPart -Address $row.SourceUserPrincipalName).ToLowerInvariant()
            $item['NicknameLocalPart'] = ($guestLocalPart -replace '[^a-z0-9._-]', '')
            $item['MissingTokens'] = @()
            continue
        }

        # Only a user account carries a user principal name. Shared mailboxes, groups and
        # contacts are addressed by their primary SMTP address alone, so their UPN columns
        # stay empty rather than being filled with an address nothing will ever sign in to.
        $isUserPrincipal = $row.ObjectType -eq 'User'
        $smtpTemplateForItem = if ($item.UsesTemplate) { $smtpTemplate } else { 'Keep' }

        $nameArguments = @{
            FirstName       = $row.FirstName
            MiddleName      = $row.MiddleName
            LastName        = $row.LastName
            SourceLocalPart = $sourceLocalPart
            DisplayName     = $row.DisplayName
        }

        $missing = [System.Collections.Generic.List[string]]::new()

        $upnLocalPart = ''
        if ($isUserPrincipal) {
            $upnResult = ConvertTo-MigrationLocalPart -Template $UpnFormat @nameArguments
            $upnLocalPart = $upnResult.LocalPart
            foreach ($token in @($upnResult.MissingTokens)) {
                if ($token -and -not $missing.Contains($token)) { $missing.Add($token) }
            }
        }

        $smtpResult = ConvertTo-MigrationLocalPart -Template $smtpTemplateForItem @nameArguments
        foreach ($token in @($smtpResult.MissingTokens)) {
            if ($token -and -not $missing.Contains($token)) { $missing.Add($token) }
        }

        $item['UpnLocalPart'] = $upnLocalPart
        $item['SmtpLocalPart'] = $smtpResult.LocalPart
        $item['WantedUpnLocalPart'] = $upnLocalPart
        $item['WantedSmtpLocalPart'] = $smtpResult.LocalPart
        $item['MissingTokens'] = [string[]]$missing.ToArray()

        if ($nicknameTemplate) {
            $nicknameResult = ConvertTo-MigrationLocalPart -Template $nicknameTemplate @nameArguments
            $item['NicknameLocalPart'] = $nicknameResult.LocalPart
            foreach ($token in @($nicknameResult.MissingTokens)) {
                if ($token -and -not $missing.Contains($token)) { $missing.Add($token) }
            }
            $item['MissingTokens'] = [string[]]$missing.ToArray()
        }
        else {
            $item['NicknameLocalPart'] = ''
        }

        if (@($item['MissingTokens']).Count -gt 0) {
            $row.PlanStatus = 'NeedsReview'
            $row.PlanDetail = 'Could not build a destination address from the source name (missing: ' +
                (@($item['MissingTokens']) -join ', ') + '). Fill in the target columns by hand.'
        }
    }

    # --- Collision resolution --------------------------------------------------------------------
    $namedItems = @($planned | Where-Object { $_.Row.PlanStatus -ne 'NeedsReview' -and -not $_.IsGuest })

    $upnCandidates = [System.Collections.Generic.List[object]]::new()
    $smtpCandidates = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $namedItems) {
        $middleInitial = ''
        if ($item.Row.MiddleName) { $middleInitial = $item.Row.MiddleName }

        # Only users hold a user principal name; every other recipient type is addressed by
        # its primary SMTP address alone, which is why the UPN set is deliberately smaller.
        if ($item.Row.ObjectType -eq 'User') {
            $upnCandidates.Add([pscustomobject]@{
                    Key = [string]$item.Key; LocalPart = [string]$item['UpnLocalPart']
                    MiddleInitial = $middleInitial; Domain = $targetDomainName
                })
        }
        $smtpCandidates.Add([pscustomobject]@{
                Key = [string]$item.Key; LocalPart = [string]$item['SmtpLocalPart']
                MiddleInitial = $middleInitial; Domain = $targetDomainName
            })
    }

    $reservedArray = [string[]]$reservedAddresses.ToArray()
    $upnResolved = @(Resolve-MigrationCollision -Candidates $upnCandidates.ToArray() -Reserved $reservedArray)
    $smtpResolved = @(Resolve-MigrationCollision -Candidates $smtpCandidates.ToArray() -Reserved $reservedArray)

    $upnByKey = @{}
    foreach ($resolved in $upnResolved) { $upnByKey[[string]$resolved.Key] = $resolved }
    $smtpByKey = @{}
    foreach ($resolved in $smtpResolved) { $smtpByKey[[string]$resolved.Key] = $resolved }

    # Who ended up holding each address, so a collision message can name the winner.
    $itemByKey = @{}
    foreach ($item in $items) { $itemByKey[[string]$item.Key] = $item }

    $describeClaimant = {
        param([object[]]$Resolved, [string]$LocalPart)
        foreach ($entry in $Resolved) {
            if ([string]$entry.ResolvedLocalPart -ne $LocalPart) { continue }
            $owner = $itemByKey[[string]$entry.Key]
            if ($null -eq $owner) { return '' }
            $identity = $owner.Row.SourceUserPrincipalName
            if (-not $identity) { $identity = $owner.Row.SourcePrimarySmtp }
            if (-not $identity) { $identity = $owner.Row.DisplayName }
            return [string]$identity
        }
        return ''
    }

    foreach ($item in $namedItems) {
        $row = $item.Row
        $key = [string]$item.Key
        $details = [System.Collections.Generic.List[string]]::new()
        $isCollision = $false

        if ($upnByKey.ContainsKey($key)) {
            $resolved = $upnByKey[$key]
            $item['UpnLocalPart'] = [string]$resolved.ResolvedLocalPart
            if ($resolved.Collided) {
                $isCollision = $true
                $wanted = [string]$item['WantedUpnLocalPart']
                $claimant = & $describeClaimant $upnResolved $wanted
                if ($resolved.Resolution -eq 'Unresolved') {
                    $item['UpnLocalPart'] = ''
                    $details.Add((Get-PlanCollisionDetail -Kind UPN -WantedLocalPart $wanted -Domain $targetDomainName -ResolvedLocalPart '' -Claimant $claimant))
                }
                else {
                    $details.Add((Get-PlanCollisionDetail -Kind UPN -WantedLocalPart $wanted -Domain $targetDomainName -ResolvedLocalPart $resolved.ResolvedLocalPart -Claimant $claimant))
                }
            }
        }

        if ($smtpByKey.ContainsKey($key)) {
            $resolved = $smtpByKey[$key]
            $item['SmtpLocalPart'] = [string]$resolved.ResolvedLocalPart
            if ($resolved.Collided) {
                $isCollision = $true
                $wanted = [string]$item['WantedSmtpLocalPart']
                $claimant = & $describeClaimant $smtpResolved $wanted
                if ($resolved.Resolution -eq 'Unresolved') {
                    $item['SmtpLocalPart'] = ''
                    $details.Add((Get-PlanCollisionDetail -Kind SMTP -WantedLocalPart $wanted -Domain $targetDomainName -ResolvedLocalPart '' -Claimant $claimant))
                }
                else {
                    $details.Add((Get-PlanCollisionDetail -Kind SMTP -WantedLocalPart $wanted -Domain $targetDomainName -ResolvedLocalPart $resolved.ResolvedLocalPart -Claimant $claimant))
                }
            }
        }

        if ($isCollision) {
            $row.PlanStatus = 'Collision'
            $row.PlanDetail = ($details -join ' ')
        }
    }

    # --- Addresses, licences, aliases and validation ----------------------------------------------
    foreach ($item in $planned) {
        $row = $item.Row

        if ($item.IsGuest) {
            $row.TargetUserPrincipalName = $row.SourceUserPrincipalName
            $row.TargetPrimarySmtp = if ($row.SourcePrimarySmtp) { $row.SourcePrimarySmtp } else { '' }
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
            $row.TargetMailNickname = ($nickname -replace "[^a-z0-9._-]", '')
        }

        # Licences ---------------------------------------------------------------------------
        $licenseResult = Get-PlanTargetLicense -SourceLicense $row.SourceLicenses -SkuMap $skuMap
        $row.TargetLicenses = Join-MigrationList -Values $licenseResult.Licenses
        $licenseNotes = [System.Collections.Generic.List[string]]::new()
        if ($licenseResult.Unmapped.Count -gt 0) {
            $licenseNotes.Add('No SKU mapping for ' + ($licenseResult.Unmapped -join ', ') + ' - carried through unchanged.')
        }
        if ($licenseResult.Dropped.Count -gt 0) {
            $licenseNotes.Add('SKU map drops ' + ($licenseResult.Dropped -join ', ') + '.')
        }

        # Aliases ----------------------------------------------------------------------------
        $aliases = [System.Collections.Generic.List[string]]::new()
        if ($PreserveAliases) {
            $sourceAddresses = [System.Collections.Generic.List[string]]::new()
            if ($row.SourcePrimarySmtp) { $sourceAddresses.Add($row.SourcePrimarySmtp) }
            foreach ($alias in @(Split-MigrationList -Value $row.SourceAliases)) { $sourceAddresses.Add($alias) }
            foreach ($redomained in @(Get-PlanRedomainedAlias -Address $sourceAddresses.ToArray() -DomainMap $AliasDomainMap)) {
                if (-not $aliases.Contains($redomained)) { $aliases.Add($redomained) }
            }
        }

        # The legacy DN always travels, aliases or not: without it, replies to pre-migration
        # mail bounce with an IMCEAEX non-delivery report.
        foreach ($x500 in @(Get-PlanX500List -Value $row.LegacyExchangeDN) + @(Split-MigrationList -Value $row.SourceX500)) {
            if ($x500 -and -not $aliases.Contains($x500)) { $aliases.Add($x500) }
        }

        $primaryForms = @($row.TargetPrimarySmtp, $row.InterimPrimarySmtp) |
            Where-Object { $_ } |
            ForEach-Object { 'smtp:' + $_.ToLowerInvariant() }
        $row.TargetAliases = Join-MigrationList -Values ([string[]]@($aliases | Where-Object { $primaryForms -notcontains $_ }))

        # Status -------------------------------------------------------------------------------
        if ($row.PlanStatus -eq 'NeedsReview') {
            foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'TargetAliases',
                    'TargetMailNickname', 'InterimUserPrincipalName', 'InterimPrimarySmtp')) {
                $row.$column = ''
            }
            continue
        }

        $validationChecks = @(
            @{ Column = 'TargetUserPrincipalName'; Kind = 'Upn' }
            @{ Column = 'InterimUserPrincipalName'; Kind = 'Upn' }
            @{ Column = 'TargetPrimarySmtp'; Kind = 'Smtp' }
            @{ Column = 'InterimPrimarySmtp'; Kind = 'Smtp' }
            @{ Column = 'TargetMailNickname'; Kind = 'MailNickname' }
        )

        $invalidReason = ''
        foreach ($check in $validationChecks) {
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

    # --- Summary ---------------------------------------------------------------------------------
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
            Write-MigrationLog -Message ("  [{0}] {1} - {2}" -f $row.PlanStatus, $identity, $row.PlanDetail) -Level WARNING
        }
    }

    # --- Write --------------------------------------------------------------------------------------
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leader = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
    $planPath = Join-Path -Path $run.OutputDirectory -ChildPath "${leader}IdentityPlan_$timestamp.csv"

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
