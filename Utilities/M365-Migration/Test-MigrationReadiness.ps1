#Requires -Version 7.4

<#
.SYNOPSIS
    Pre-flights the destination tenant against an identity plan and reports every check as pass or fail.

.DESCRIPTION
    The gate between planning and provisioning, and again between provisioning and cutover. It reads
    the destination tenant and answers one question per check: is the plan safe to run right now?
    The only tenant-side effect is in the Provisioned stage: with the delegated sign-in this script
    uses, reading /users/{id}/drive provisions OneDrive for a licensed user who does not have one
    yet, so that read (and the plan writeback below) is skipped under -DryRun and -WhatIf.

      Pre          Before any object exists: are the target and interim domains verified, are there
                   enough seats for the SKUs the plan asks for, does every licensed row have a usage
                   location, is the plan clean of NeedsReview/Invalid/Collision rows, and does any
                   planned UPN, address or mail nickname already belong to a user, group, contact,
                   mailbox - or to a soft-deleted user, which holds its UPN and returns 409 on
                   create until it is purged or restored?

      Provisioned  After New-MigrationUsers and Set-MigrationLicenses: does the user exist, does the
                   mailbox exist, is the archive on where the source had one, is litigation hold off
                   (move tools refuse mailboxes that hold), has OneDrive been provisioned (GET
                   /users/{id}/drive returns 404 until it has - and provisions it, for a licensed
                   user, the moment it does not) and is the quota at least the size of the source
                   mailbox? Shared, room and equipment mailboxes skip the OneDrive check; they have
                   none. The only stage that writes anything, and it writes only MailboxProvisioned
                   and OneDriveProvisioned back to the plan.

      Post         After cutover: is the UPN the planned one, is the primary SMTP address, is every
                   planned alias present (X500 included), is the object visible and enabled?

    A per-object check that finds nothing wrong reports one summary row rather than one row per
    object, so a clean run stays readable. The run ends with a pass/fail table and exits 2 if any
    check failed.

.PARAMETER PlanPath
    Path to IdentityPlan.csv.

.PARAMETER Stage
    Pre (default), Provisioned or Post. See the description for what each stage asks.

.PARAMETER Wave
    One or more wave labels to check. Omit to check every wave.

.PARAMETER SourceMailboxesCsv
    Inventory of the source mailboxes, used by the Provisioned stage for the archive and mailbox-size
    checks. Columns: PrimarySmtpAddress (required), TotalItemSizeGB, ArchiveStatus. Without it those
    two checks report Skipped rather than guessing.

.PARAMETER TenantId
    Destination tenant id or domain for Connect-MgGraph. Supported under GDAP.

.PARAMETER DelegatedOrganization
    Destination tenant for Connect-ExchangeOnline under a GDAP relationship. Alias: -Tenant.

.PARAMETER OutputPath
    Overrides the output root (default %LOCALAPPDATA%\Migration-Automations, ~/Migration-Automations
    off Windows).

.PARAMETER Prefix
    Names the client or run. Output lands in <root>\<Prefix>\ and filenames start with '<Prefix>_'.

.PARAMETER LogPath
    Overrides the derived log file path.

.PARAMETER DryRun
    Suppresses the Provisioned stage's plan writeback and the OneDrive read that would provision a
    licensed user's drive (that check reports Skipped instead). Every other check still runs and
    the results file is written with the -DryRun_ marker.

.PARAMETER Verbosity
    Console detail: Low, Medium (default) or High. The log file always receives every line.

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -PlanPath .\IdentityPlan.csv -Prefix Fabrikam

    Runs the Pre stage over the whole plan and writes Fabrikam_Test-MigrationReadiness-Results_<ts>.csv.

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -Stage Provisioned -SourceMailboxesCsv .\Mailboxes.csv

    Confirms wave 1's users, mailboxes, archives and OneDrive sites exist in the destination and
    records MailboxProvisioned / OneDriveProvisioned back into the plan.

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -PlanPath .\IdentityPlan.csv -Stage Provisioned -DryRun

    Runs every Provisioned check and reports them without touching the plan file.

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -Stage Post -DelegatedOrganization newco.onmicrosoft.com

    GDAP alternative: verifies wave 1 landed on its planned addresses in a destination tenant
    administered through GDAP rather than with a Global Admin account in it.

.NOTES
    Author: AutomationHub
    Written with assistance from Claude (Anthropic).

    Required Microsoft Graph scopes:
      User.Read.All          - destination users, all stages
      Directory.Read.All     - soft-deleted users under /directory/deletedItems, all stages
      Group.Read.All         - group clash detection, Pre stage
      Organization.Read.All  - subscribedSkus for the seat check, Pre stage
      Files.Read.All         - GET /users/{id}/drive for the OneDrive check, Provisioned stage

    Required Exchange Online role: View-Only Recipients (included in View-Only Organization
    Management). Get-EXORecipient and Get-EXOMailbox are used because the REST-based v3 cmdlets
    survive tenant-wide reads that the older RPS cmdlets cannot.

    GDAP: supported. -TenantId for Graph, -DelegatedOrganization for Exchange Online. If the
    Exchange connection drops its delegated claims, add -DisableWAM to the EXO connection.

    Exit codes: 0 every check passed, 1 fatal (connection, plan or writeback), 2 completed with
    failed checks.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [ValidateSet('Pre', 'Provisioned', 'Post')]
    [string]$Stage = 'Pre',

    [AllowNull()][AllowEmptyCollection()]
    [string[]]$Wave,

    [AllowNull()][AllowEmptyString()]
    [string]$SourceMailboxesCsv,

    [AllowNull()][AllowEmptyString()]
    [string]$TenantId,

    [Alias('Tenant')]
    [AllowNull()][AllowEmptyString()]
    [string]$DelegatedOrganization,

    [AllowNull()][AllowEmptyString()]
    [string]$OutputPath,

    [AllowNull()][AllowEmptyString()]
    [string]$Prefix,

    [AllowNull()][AllowEmptyString()]
    [string]$LogPath,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Configuration

# Only the scopes the chosen stage actually needs are requested; Connect-MigrationGraph refuses to
# continue when a requested scope was not granted, so asking for more than the job needs turns a
# working least-privilege consent into a hard failure.
$requiredGraphScopes = @('User.Read.All', 'Directory.Read.All')
switch ($Stage) {
    'Pre'         { $requiredGraphScopes += @('Group.Read.All', 'Organization.Read.All') }
    'Provisioned' { $requiredGraphScopes += 'Files.Read.All' }
}

# Rows the planner did not mark safe are not provisioned, so they are the subject of the PlanClean
# check rather than of the domain, seat and clash checks.
$dirtyPlanStatus = @('NeedsReview', 'Invalid', 'Collision')

# Clash lookups are batched: OData equality clauses per Graph request, and per Exchange filter.
$graphFilterBatchSize = 15
$exoFilterBatchSize = 20

#endregion Configuration

#region Functions

function Get-PlanRowIdentity {
    <#
    .SYNOPSIS
        Picks the most useful label for a plan row in a result file.
    .PARAMETER Row
        The identity plan row.
    .EXAMPLE
        Get-PlanRowIdentity -Row $planRow
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Row)

    foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'InterimUserPrincipalName',
            'SourceUserPrincipalName', 'SourcePrimarySmtp', 'DisplayName')) {
        $value = Get-MigrationCsvValue -Row $Row -Name $column -Default ''
        if ($value) { return $value }
    }
    return '(unnamed plan row)'
}

function New-CheckResult {
    <#
    .SYNOPSIS
        Builds one result row in the toolkit's fixed column order.
    .DESCRIPTION
        Given -Row, the label, wave and object type come off the plan row rather than being spelled
        out at each call site.
    .PARAMETER Action
        The check name, which is also what the pass/fail table groups on.
    .PARAMETER Status
        Succeeded, Failed or Skipped.
    .PARAMETER Detail
        Human-readable explanation. Always populated for Failed and Skipped rows.
    .PARAMETER Identity
        The object or check the row is about. Defaults to -Row's label, or the check name.
    .PARAMETER Stage
        Pre, Provisioned or Post.
    .PARAMETER Row
        The plan row the check is about, when it is about one.
    .EXAMPLE
        New-CheckResult -Row $planRow -Action 'PlanClean' -Status Failed -Detail $why -Stage Pre
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory result object for the results CSV; it changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Succeeded', 'Failed', 'Skipped')][string]$Status,
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$Identity = '',
        [AllowEmptyString()][string]$Stage = '',
        [AllowNull()]$Row
    )

    $wave = ''
    $objectType = ''
    if ($null -ne $Row) {
        if (-not $Identity) { $Identity = Get-PlanRowIdentity -Row $Row }
        $wave = [string](Get-MigrationCsvValue -Row $Row -Name 'Wave' -Default '')
        $objectType = [string](Get-MigrationCsvValue -Row $Row -Name 'ObjectType' -Default '')
    }
    if (-not $Identity) { $Identity = $Action }

    return [pscustomobject]@{
        Identity   = $Identity
        Action     = $Action
        Status     = $Status
        Detail     = $Detail
        Stage      = $Stage
        Wave       = $wave
        ObjectType = $objectType
    }
}

function ConvertTo-BareAddress {
    <#
    .SYNOPSIS
        Strips an Exchange proxy-address prefix and returns the bare, lower-cased address.
    .DESCRIPTION
        Only SMTP addresses take part in clash detection, so an X500, SIP or SPO entry returns an
        empty string and the caller drops it.
    .PARAMETER Value
        The raw proxy address.
    .EXAMPLE
        ConvertTo-BareAddress -Value 'SMTP:John.Smith@newco.com'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    $parsed = Split-MigrationProxyAddress -Entry $Value
    if ($parsed.Kind -ne 'Smtp') { return '' }
    return $parsed.Address.Trim().ToLowerInvariant()
}

function Get-AddressDomain {
    <#
    .SYNOPSIS
        Returns the domain half of an address, lower-cased, or an empty string.
    .PARAMETER Value
        A UPN or SMTP address. Guest UPNs carry '@' inside the local part, so the last one wins.
    .EXAMPLE
        Get-AddressDomain -Value 'John.Smith@Newco.COM'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    $text = ([string]$Value).Trim()
    $index = $text.LastIndexOf('@')
    if ($index -lt 0 -or $index -eq ($text.Length - 1)) { return '' }
    return $text.Substring($index + 1).ToLowerInvariant()
}

function Get-PlanAddressCandidate {
    <#
    .SYNOPSIS
        Lists every destination-side identifier one plan row wants to claim.
    .DESCRIPTION
        X500 entries in TargetAliases are routing history, not claims on an address, so they are
        excluded here and checked only by the Post stage.
    .PARAMETER Row
        The identity plan row.
    .EXAMPLE
        Get-PlanAddressCandidate -Row $planRow
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Row)

    $candidate = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Kind, [string]$Scope, [string]$Value)
        $text = ([string]$Value).Trim()
        if ($text) { $candidate.Add([pscustomobject]@{ Kind = $Kind; Scope = $Scope; Value = $text.ToLowerInvariant() }) }
    }

    foreach ($claim in @(
            @{ Kind = 'Upn'; Scope = 'Target'; Column = 'TargetUserPrincipalName' }
            @{ Kind = 'Upn'; Scope = 'Interim'; Column = 'InterimUserPrincipalName' }
            @{ Kind = 'Smtp'; Scope = 'Target'; Column = 'TargetPrimarySmtp' }
            @{ Kind = 'Smtp'; Scope = 'Interim'; Column = 'InterimPrimarySmtp' }
            @{ Kind = 'MailNickname'; Scope = 'Target'; Column = 'TargetMailNickname' })) {
        & $add $claim.Kind $claim.Scope (Get-MigrationCsvValue -Row $Row -Name $claim.Column -Default '')
    }

    foreach ($alias in @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'TargetAliases' -Default ''))) {
        & $add 'Smtp' 'Alias' (ConvertTo-BareAddress -Value $alias)
    }

    return $candidate.ToArray()
}

function Test-AddressClash {
    <#
    .SYNOPSIS
        Reports every planned identifier that something in the destination tenant already holds.
    .DESCRIPTION
        Pure, so the clash rules can be exercised offline against a fake recipient list. An object
        whose id matches the row's own TargetObjectId is not a clash - it is the row's own,
        already-provisioned object.
    .PARAMETER Row
        The plan rows to check.
    .PARAMETER ExistingObject
        Destination objects, each with Id, Kind, DisplayName, MailNickname and an Address array of
        bare SMTP addresses and UPNs.
    .PARAMETER Stage
        Stamped onto every result row.
    .EXAMPLE
        Test-AddressClash -Row $planRows -ExistingObject $destinationObjects -Stage Pre
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Row,
        [AllowNull()][AllowEmptyCollection()][object[]]$ExistingObject,
        [AllowEmptyString()][string]$Stage = 'Pre'
    )

    $byAddress = @{}
    $byNickname = @{}
    $index = {
        param([hashtable]$Table, [string]$Key, $Value)
        if (-not $Key) { return }
        if (-not $Table.ContainsKey($Key)) { $Table[$Key] = [System.Collections.Generic.List[object]]::new() }
        $Table[$Key].Add($Value)
    }

    foreach ($existing in @($ExistingObject)) {
        foreach ($address in @(Get-MigrationProperty -InputObject $existing -Name 'Address' -Default @())) {
            & $index $byAddress ([string]$address).Trim().ToLowerInvariant() $existing
        }
        & $index $byNickname ([string](Get-MigrationProperty -InputObject $existing -Name 'MailNickname' -Default '')).Trim().ToLowerInvariant() $existing
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($planRow in @($Row)) {
        $ownId = Get-MigrationCsvValue -Row $planRow -Name 'TargetObjectId' -Default ''
        $reported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($candidate in (Get-PlanAddressCandidate -Row $planRow)) {
            $table = if ($candidate.Kind -eq 'MailNickname') { $byNickname } else { $byAddress }
            if (-not $table.ContainsKey($candidate.Value)) { continue }

            foreach ($hit in $table[$candidate.Value]) {
                $hitId = [string](Get-MigrationProperty -InputObject $hit -Name 'Id' -Default '')
                if ($ownId -and $hitId -and $hitId -eq $ownId) { continue }

                $kind = [string](Get-MigrationProperty -InputObject $hit -Name 'Kind' -Default 'object')
                $name = [string](Get-MigrationProperty -InputObject $hit -Name 'DisplayName' -Default '')
                # Keyed on the object id when there is one, so the same holder found once by Graph
                # (Kind 'User') and once by Exchange (Kind 'UserMailbox') reports as a single row
                # rather than two. An id-less recipient (Get-EXORecipient without
                # ExternalDirectoryObjectID, e.g. some contacts) still dedupes per kind.
                $dedupeKey = if ($hitId) { $hitId } else { $kind }
                if (-not $reported.Add("$($candidate.Value)|$dedupeKey")) { continue }

                $held = if ($name) { "$kind '$name'" } else { $kind }
                $results.Add((New-CheckResult -Row $planRow -Action 'AddressClash' -Status 'Failed' -Stage $Stage `
                            -Detail "$($candidate.Scope) $($candidate.Kind) '$($candidate.Value)' is already held by $held."))
            }
        }
    }

    return $results.ToArray()
}

function Measure-SeatRequirement {
    <#
    .SYNOPSIS
        Totals the seats a plan asks for per SKU and compares them with the destination's spare seats.
    .DESCRIPTION
        Pure, so the arithmetic is testable without a tenant. A part number the destination does not
        subscribe to gets Status 'Unknown' - almost always a SKU map written against the source
        tenant's product names.
    .PARAMETER Row
        The plan rows to total.
    .PARAMETER Catalog
        Output of Get-MigrationSkuCatalog (needs SkuPartNumber and Available).
    .EXAMPLE
        Measure-SeatRequirement -Row $planRows -Catalog (Get-MigrationSkuCatalog)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Row,
        [AllowNull()][AllowEmptyCollection()][object[]]$Catalog
    )

    $needed = [ordered]@{}
    foreach ($planRow in @($Row)) {
        foreach ($part in @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $planRow -Name 'TargetLicenses' -Default ''))) {
            if (-not $needed.Contains($part)) { $needed[$part] = 0 }
            $needed[$part] = [int]$needed[$part] + 1
        }
    }

    $available = @{}
    foreach ($sku in @($Catalog)) {
        $part = [string](Get-MigrationProperty -InputObject $sku -Name 'SkuPartNumber' -Default '')
        if ($part) { $available[$part] = [int](Get-MigrationProperty -InputObject $sku -Name 'Available' -Default 0) }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($part in $needed.Keys) {
        $count = [int]$needed[$part]
        $spare = if ($available.ContainsKey($part)) { [int]$available[$part] } else { 0 }
        $shortfall = [Math]::Max(0, $count - $spare)
        $rows.Add([pscustomobject]@{
                SkuPartNumber = $part
                Needed        = $count
                Available     = $spare
                Shortfall     = $shortfall
                Status        = if (-not $available.ContainsKey($part)) { 'Unknown' }
                elseif ($shortfall -gt 0) { 'Shortfall' }
                else { 'Sufficient' }
            })
    }

    return $rows.ToArray()
}

function ConvertTo-QuotaGigabyte {
    <#
    .SYNOPSIS
        Turns an Exchange quota string into gigabytes.
    .DESCRIPTION
        ProhibitSendReceiveQuota reads like '100 GB (107,374,182,400 bytes)'. The parenthesised byte
        count is the exact figure and is preferred; the leading unit string is the fallback.
        'Unlimited' returns [double]::MaxValue so a comparison against it always passes.
    .PARAMETER Value
        The quota as Exchange renders it.
    .EXAMPLE
        ConvertTo-QuotaGigabyte -Value '100 GB (107,374,182,400 bytes)'
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    $text = ([string]$Value).Trim()
    if (-not $text) { return 0 }
    if ($text -match '(?i)^unlimited$') { return [double]::MaxValue }

    $parsed = 0.0
    if ($text -match '\(([\d,\.]+)\s*bytes\)') {
        if ([double]::TryParse(($Matches[1] -replace '[,\s]', ''), [ref]$parsed)) { return [Math]::Round($parsed / 1GB, 3) }
    }

    if ($text -match '(?i)^([\d,\.]+)\s*(KB|MB|GB|TB)') {
        $unit = $Matches[2].ToUpperInvariant()
        if ([double]::TryParse(($Matches[1] -replace ',', ''), [ref]$parsed)) {
            $factor = switch ($unit) { 'KB' { 1 / 1MB } 'MB' { 1 / 1KB } 'TB' { 1024 } default { 1 } }
            return [Math]::Round($parsed * $factor, 3)
        }
    }

    return 0
}

function Test-GraphNotFound {
    <#
    .SYNOPSIS
        Says whether a failed Graph call was a 404 rather than a real problem.
    .DESCRIPTION
        A 404 from GET /users/{id}/drive means OneDrive has not been provisioned yet, which is a
        finding rather than an error. Get-MigrationGraphErrorStatusCode does the reading; the one
        signal it does not map is the 'itemNotFound' code the drive endpoint returns in its body,
        so that is checked here as well.
    .PARAMETER ErrorRecord
        The ErrorRecord from the catch block.
    .EXAMPLE
        try { Invoke-MigrationGraphRequest -Method GET -Uri $uri }
        catch { if (-not (Test-GraphNotFound -ErrorRecord $_)) { throw } }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$ErrorRecord)

    if ((Get-MigrationGraphErrorStatusCode -ErrorRecord $ErrorRecord) -eq 404) { return $true }

    $detail = if ($ErrorRecord.ErrorDetails) { [string]$ErrorRecord.ErrorDetails.Message } else { '' }
    if ($detail -match '(?i)"code"\s*:\s*"itemNotFound"') { return $true }

    return ([string]$ErrorRecord.Exception.Message -match '(?i)not\s*found')
}

function Get-VerifiedDomain {
    <#
    .SYNOPSIS
        Returns the verified domain names on the connected tenant, lower-cased.
    .EXAMPLE
        Get-VerifiedDomain
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $verified = [System.Collections.Generic.List[string]]::new()
    foreach ($domain in @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/domains' -All)) {
        if (-not [bool](Get-MigrationProperty -InputObject $domain -Name 'isVerified' -Default $false)) { continue }
        $name = [string](Get-MigrationProperty -InputObject $domain -Name 'id' -Default '')
        if ($name) { $verified.Add($name.ToLowerInvariant()) }
    }
    return $verified.ToArray()
}

function Get-DirectoryClashObject {
    <#
    .SYNOPSIS
        Reads the destination users, groups and soft-deleted users that hold any of the given identifiers.
    .DESCRIPTION
        One Graph call per batch of equality clauses rather than one per plan row. Soft-deleted users
        are queried separately because a deleted user still owns its UPN and proxy addresses, and
        fails a create or a rename with 409 until it is purged.
    .PARAMETER UserPrincipalName
        UPNs to look for.
    .PARAMETER EmailAddress
        Bare SMTP addresses to look for.
    .PARAMETER MailNickname
        Mail nicknames to look for.
    .PARAMETER BatchSize
        Equality clauses per request.
    .EXAMPLE
        Get-DirectoryClashObject -UserPrincipalName $upns -EmailAddress $addresses -MailNickname $nicknames
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$UserPrincipalName,
        [AllowNull()][AllowEmptyCollection()][string[]]$EmailAddress,
        [AllowNull()][AllowEmptyCollection()][string[]]$MailNickname,
        [ValidateRange(1, 20)][int]$BatchSize = 15
    )

    $found = [System.Collections.Generic.List[object]]::new()

    $clauseFor = {
        param([string]$Property, [string[]]$Value)
        @($Value | Where-Object { $_ } | Sort-Object -Unique |
            ForEach-Object { "$Property eq '$(ConvertTo-MigrationODataString -Value $_)'" })
    }
    $upnClause = @(& $clauseFor 'userPrincipalName' $UserPrincipalName)
    $mailClause = @(& $clauseFor 'mail' $EmailAddress)
    $nicknameClause = @(& $clauseFor 'mailNickname' $MailNickname)

    $invokeBatched = {
        param([string[]]$Clause, [string]$Uri, [string]$Kind, [int]$Size)

        for ($offset = 0; $offset -lt $Clause.Count; $offset += $Size) {
            $take = [Math]::Min($Size, $Clause.Count - $offset)
            $filter = [uri]::EscapeDataString((@($Clause[$offset..($offset + $take - 1)]) -join ' or '))
            try { $page = @(Invoke-MigrationGraphRequest -Method GET -Uri "$Uri&`$filter=$filter" -All) }
            catch { throw "Could not read destination $Kind objects from Graph: $($_.Exception.Message)" }

            foreach ($item in $page) {
                $address = [System.Collections.Generic.List[string]]::new()
                foreach ($name in @('userPrincipalName', 'mail')) {
                    $value = [string](Get-MigrationProperty -InputObject $item -Name $name -Default '')
                    if ($value) { $address.Add($value.ToLowerInvariant()) }
                }
                foreach ($proxy in @(Get-MigrationProperty -InputObject $item -Name 'proxyAddresses' -Default @())) {
                    $bare = ConvertTo-BareAddress -Value ([string]$proxy)
                    if ($bare) { $address.Add($bare) }
                }

                $found.Add([pscustomobject]@{
                        Id           = [string](Get-MigrationProperty -InputObject $item -Name 'id' -Default '')
                        Kind         = $Kind
                        DisplayName  = [string](Get-MigrationProperty -InputObject $item -Name 'displayName' -Default '')
                        MailNickname = ([string](Get-MigrationProperty -InputObject $item -Name 'mailNickname' -Default '')).ToLowerInvariant()
                        Address      = @($address | Sort-Object -Unique)
                    })
            }
        }
    }

    $select = 'id,displayName,userPrincipalName,mail,mailNickname,proxyAddresses'
    & $invokeBatched @($upnClause + $mailClause + $nicknameClause) "/v1.0/users?`$select=$select&`$top=999" 'User' $BatchSize
    & $invokeBatched @($mailClause + $nicknameClause) "/v1.0/groups?`$select=id,displayName,mail,mailNickname,proxyAddresses&`$top=999" 'Group' $BatchSize
    & $invokeBatched @($upnClause + $mailClause) "/v1.0/directory/deletedItems/microsoft.graph.user?`$select=$select&`$top=999" 'SoftDeletedUser' $BatchSize

    return $found.ToArray()
}

function Get-RecipientClashObject {
    <#
    .SYNOPSIS
        Reads the Exchange recipients that hold any of the given SMTP addresses.
    .DESCRIPTION
        Get-EXORecipient covers the whole mail-enabled surface a new address can collide with. The
        addresses go into one OPATH filter per batch rather than one call per plan row - tenant-wide
        recipient reads are exactly what throttles on a large org.
    .PARAMETER EmailAddress
        Bare SMTP addresses to look for.
    .PARAMETER BatchSize
        Addresses per Exchange filter.
    .EXAMPLE
        Get-RecipientClashObject -EmailAddress $addresses -BatchSize 20
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$EmailAddress,
        [ValidateRange(1, 50)][int]$BatchSize = 20
    )

    $wanted = @($EmailAddress | Where-Object { $_ } | Sort-Object -Unique)
    $found = [System.Collections.Generic.List[object]]::new()

    for ($offset = 0; $offset -lt $wanted.Count; $offset += $BatchSize) {
        $take = [Math]::Min($BatchSize, $wanted.Count - $offset)
        $filter = (@($wanted[$offset..($offset + $take - 1)] | ForEach-Object {
                    "EmailAddresses -eq 'smtp:$(ConvertTo-MigrationODataString -Value $_)'" }) -join ' -or ')

        try {
            $page = @(Get-EXORecipient -Filter $filter -ResultSize Unlimited -ErrorAction Stop -Properties @(
                    'EmailAddresses', 'PrimarySmtpAddress', 'DisplayName', 'Alias'))
        }
        catch { throw "Could not read Exchange recipients: $($_.Exception.Message)" }

        foreach ($recipient in $page) {
            $address = [System.Collections.Generic.List[string]]::new()
            foreach ($proxy in @(Get-MigrationProperty -InputObject $recipient -Name 'EmailAddresses' -Default @())) {
                $bare = ConvertTo-BareAddress -Value ([string]$proxy)
                if ($bare) { $address.Add($bare) }
            }
            $primary = [string](Get-MigrationProperty -InputObject $recipient -Name 'PrimarySmtpAddress' -Default '')
            if ($primary) { $address.Add($primary.ToLowerInvariant()) }

            $found.Add([pscustomobject]@{
                    Id           = [string](Get-MigrationProperty -InputObject $recipient -Name 'ExternalDirectoryObjectId' -Default '')
                    Kind         = [string](Get-MigrationProperty -InputObject $recipient -Name 'RecipientType' -Default 'Recipient')
                    DisplayName  = [string](Get-MigrationProperty -InputObject $recipient -Name 'DisplayName' -Default '')
                    MailNickname = ([string](Get-MigrationProperty -InputObject $recipient -Name 'Alias' -Default '')).ToLowerInvariant()
                    Address      = @($address | Sort-Object -Unique)
                })
        }
    }

    return $found.ToArray()
}

function Test-ProvisionedRow {
    <#
    .SYNOPSIS
        Grades one already-provisioned plan row and returns its check rows plus the plan writeback values.
    .DESCRIPTION
        Pure: the caller reads, this decides what the readings mean. Returns Row (the check results)
        plus MailboxProvisioned and OneDriveProvisioned as the 'True'/'False' the plan schema stores.
    .PARAMETER Row
        The identity plan row.
    .PARAMETER User
        The destination Graph user, or $null when the lookup returned 404.
    .PARAMETER Mailbox
        The destination mailbox from Get-EXOMailbox, or $null when there is none yet.
    .PARAMETER DriveState
        Present when GET /users/{id}/drive returned a drive, Absent when it 404'd, or NotChecked
        when the read was skipped under -DryRun/-WhatIf (that read provisions OneDrive for a
        licensed user under delegated auth, so it does not run in a rehearsal).
    .PARAMETER SourceMailbox
        The matching source mailbox inventory row, or $null when no inventory was supplied.
    .EXAMPLE
        Test-ProvisionedRow -Row $planRow -User $user -Mailbox $mailbox -DriveState Present
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row,
        [AllowNull()]$User,
        [AllowNull()]$Mailbox,
        [ValidateSet('Present', 'Absent', 'NotChecked')][string]$DriveState = 'Absent',
        [AllowNull()]$SourceMailbox
    )

    # Captured under its own name so the closures below read as what they are.
    $planRow = $Row
    $objectType = [string](Get-MigrationCsvValue -Row $planRow -Name 'ObjectType' -Default '')
    $isResourceMailbox = @('Shared', 'Room', 'Equipment') -contains $objectType
    $results = [System.Collections.Generic.List[object]]::new()
    $newRow = {
        param([string]$Action, [string]$Status, [string]$Detail)
        $results.Add((New-CheckResult -Row $planRow -Action $Action -Status $Status -Detail $Detail -Stage 'Provisioned'))
    }
    $verdict = {
        param([string]$Action, [bool]$Pass, [string]$Good, [string]$Bad)
        & $newRow $Action $(if ($Pass) { 'Succeeded' } else { 'Failed' }) $(if ($Pass) { $Good } else { $Bad })
    }

    if ($null -eq $User) {
        & $newRow 'UserExists' 'Failed' 'No destination user with this TargetObjectId.'
        return @{ Row = $results.ToArray(); MailboxProvisioned = 'False'; OneDriveProvisioned = 'False' }
    }
    & $newRow 'UserExists' 'Succeeded' ([string](Get-MigrationProperty -InputObject $User -Name 'userPrincipalName' -Default ''))

    $hasMailbox = $null -ne $Mailbox
    & $verdict 'MailboxExists' $hasMailbox `
        ([string](Get-MigrationProperty -InputObject $Mailbox -Name 'PrimarySmtpAddress' -Default '')) `
        'No mailbox yet - the licence may still be provisioning.'

    if ($hasMailbox) {
        # Third-party move tools refuse a destination mailbox that is on hold, so this is a blocker
        # rather than a note.
        $hold = [bool](Get-MigrationProperty -InputObject $Mailbox -Name 'LitigationHoldEnabled' -Default $false)
        & $verdict 'LitigationHoldOff' (-not $hold) 'Off.' 'Litigation hold is on; the migration tool will refuse this mailbox.'

        $sourceArchive = if ($null -ne $SourceMailbox) { Get-MigrationCsvValue -Row $SourceMailbox -Name 'ArchiveStatus' -Default '' } else { '' }
        if (-not $sourceArchive) {
            & $newRow 'ArchiveEnabled' 'Skipped' 'No source archive state; supply -SourceMailboxesCsv.'
        }
        elseif ($sourceArchive -match '(?i)^(none|disabled|false)$') {
            & $newRow 'ArchiveEnabled' 'Succeeded' 'Source had no archive; none required.'
        }
        else {
            $archiveGuid = [string](Get-MigrationProperty -InputObject $Mailbox -Name 'ArchiveGuid' -Default '')
            $hasArchive = ([string](Get-MigrationProperty -InputObject $Mailbox -Name 'ArchiveStatus' -Default '') -match '(?i)active') -or
                ($archiveGuid -and $archiveGuid -ne '00000000-0000-0000-0000-000000000000')
            & $verdict 'ArchiveEnabled' $hasArchive "Archive present (source: $sourceArchive)." `
                "Source archive is '$sourceArchive' but the destination has no archive."
        }

        $sourceSize = 0.0
        if ($null -ne $SourceMailbox) {
            $raw = Get-MigrationCsvValue -Row $SourceMailbox -Name 'TotalItemSizeGB' -Default ''
            if ($raw) { $null = [double]::TryParse($raw, [ref]$sourceSize) }
        }
        if ($sourceSize -le 0) {
            & $newRow 'MailboxQuota' 'Skipped' 'No source mailbox size; supply -SourceMailboxesCsv.'
        }
        else {
            $quotaGb = ConvertTo-QuotaGigabyte -Value ([string](Get-MigrationProperty -InputObject $Mailbox -Name 'ProhibitSendReceiveQuota' -Default ''))
            $quotaText = if ($quotaGb -ge [double]::MaxValue) { 'unlimited' } else { "$quotaGb GB" }
            $detail = "Destination quota $quotaText vs source $sourceSize GB."
            & $verdict 'MailboxQuota' ($quotaGb -ge $sourceSize) $detail $detail
        }
    }

    if ($isResourceMailbox) {
        & $newRow 'OneDriveExists' 'Skipped' 'Shared and resource mailboxes are disabled by design and have no OneDrive.'
    }
    elseif ($DriveState -eq 'NotChecked') {
        & $newRow 'OneDriveExists' 'Skipped' `
            'Not checked under -DryRun/-WhatIf; the delegated drive read would provision OneDrive for a licensed user.'
    }
    else {
        & $verdict 'OneDriveExists' ($DriveState -eq 'Present') 'Drive present.' `
            'GET /users/{id}/drive returned 404; pre-provision with Request-SPOPersonalSite.'
    }

    # A skipped read (resource mailbox, or -DryRun/-WhatIf) leaves the plan's existing value alone
    # rather than flipping OneDriveProvisioned to False for a check that never ran.
    $oneDriveProvisioned = if ($isResourceMailbox -or $DriveState -eq 'NotChecked') {
        Get-MigrationCsvValue -Row $planRow -Name 'OneDriveProvisioned' -Default 'False'
    }
    elseif ($DriveState -eq 'Present') { 'True' }
    else { 'False' }

    return @{
        Row                 = $results.ToArray()
        MailboxProvisioned  = if ($hasMailbox) { 'True' } else { 'False' }
        OneDriveProvisioned = $oneDriveProvisioned
    }
}

function Test-PostRow {
    <#
    .SYNOPSIS
        Grades one plan row after cutover: addresses, visibility and account state.
    .DESCRIPTION
        Pure, for the same reason Test-ProvisionedRow is. Aliases are compared with their type prefix
        intact so that an X500 entry is only satisfied by an X500 entry.
    .PARAMETER Row
        The identity plan row.
    .PARAMETER User
        The destination Graph user, or $null.
    .PARAMETER Mailbox
        The destination mailbox from Get-EXOMailbox, or $null.
    .EXAMPLE
        Test-PostRow -Row $planRow -User $user -Mailbox $mailbox
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row,
        [AllowNull()]$User,
        [AllowNull()]$Mailbox
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $newRow = {
        param([string]$Action, [string]$Status, [string]$Detail)
        $results.Add((New-CheckResult -Row $Row -Action $Action -Status $Status -Detail $Detail -Stage 'Post'))
    }
    $verdict = {
        param([string]$Action, [bool]$Pass, [string]$Good, [string]$Bad)
        & $newRow $Action $(if ($Pass) { 'Succeeded' } else { 'Failed' }) $(if ($Pass) { $Good } else { $Bad })
    }
    # Both address checks ask the same question of a different column pair.
    $matchesPlan = {
        param([string]$Action, [string]$Column, $Actual, [string]$SkipDetail)
        $wanted = Get-MigrationCsvValue -Row $Row -Name $Column -Default ''
        $found = [string]$Actual
        if (-not $wanted) { & $newRow $Action 'Skipped' $SkipDetail; return }
        & $verdict $Action ([bool]($found -and $found -eq $wanted)) $found "Expected '$wanted' but found '$found'."
    }

    if ($null -eq $User) {
        & $newRow 'UserExists' 'Failed' 'No destination user with this TargetObjectId.'
        return $results.ToArray()
    }

    & $matchesPlan 'UpnMatchesPlan' 'TargetUserPrincipalName' `
        (Get-MigrationProperty -InputObject $User -Name 'userPrincipalName' -Default '') 'The plan has no TargetUserPrincipalName.'

    $objectType = [string](Get-MigrationCsvValue -Row $Row -Name 'ObjectType' -Default '')
    if (@('Shared', 'Room', 'Equipment') -contains $objectType) {
        & $newRow 'AccountEnabled' 'Skipped' 'Shared and resource mailboxes are disabled by design.'
    }
    else {
        & $verdict 'AccountEnabled' ([bool](Get-MigrationProperty -InputObject $User -Name 'accountEnabled' -Default $false)) `
            'Enabled.' 'The account is disabled.'
    }

    if ($null -eq $Mailbox) {
        & $newRow 'PrimarySmtpMatchesPlan' 'Failed' 'No mailbox to read addresses from.'
        return $results.ToArray()
    }

    & $matchesPlan 'PrimarySmtpMatchesPlan' 'TargetPrimarySmtp' `
        (Get-MigrationProperty -InputObject $Mailbox -Name 'PrimarySmtpAddress' -Default '') 'The plan has no TargetPrimarySmtp.'

    $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($proxy in @(Get-MigrationProperty -InputObject $Mailbox -Name 'EmailAddresses' -Default @())) {
        [void]$present.Add(([string]$proxy).Trim())
    }
    $wantedAlias = @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'TargetAliases' -Default ''))
    $sourceX500 = Get-MigrationCsvValue -Row $Row -Name 'SourceX500' -Default ''
    if ($sourceX500) { $wantedAlias += $sourceX500 }

    if (@($wantedAlias).Count -eq 0) {
        & $newRow 'AliasesPresent' 'Skipped' 'The plan lists no target aliases.'
    }
    else {
        $missing = @($wantedAlias | ForEach-Object { $_.Trim() } | Where-Object { -not $present.Contains($_) })
        & $verdict 'AliasesPresent' ($missing.Count -eq 0) `
            "All $(@($wantedAlias).Count) planned address(es) present." `
            "Missing: $(Join-MigrationList -Values $missing)"
    }

    & $verdict 'VisibleInAddressList' `
        (-not [bool](Get-MigrationProperty -InputObject $Mailbox -Name 'HiddenFromAddressListsEnabled' -Default $false)) `
        'Visible.' 'Still hidden from address lists.'

    return $results.ToArray()
}

function Write-CheckTable {
    <#
    .SYNOPSIS
        Prints the pass/fail table that closes every run.
    .PARAMETER Result
        Every result row produced by the run.
    .EXAMPLE
        Write-CheckTable -Result $results.ToArray()
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$Result)

    $format = '  {0,-24} {1,7} {2,7} {3,8}  {4}'
    Write-MigrationLog -Message '--- Readiness checks ---' -Level SUCCESS
    if (@($Result).Count -eq 0) {
        Write-MigrationLog -Message '  (no checks ran)' -Level WARNING
        return
    }

    Write-MigrationLog -Message ($format -f 'Check', 'Passed', 'Failed', 'Skipped', 'Verdict') -Level SUCCESS
    foreach ($group in (@($Result) | Group-Object -Property Action | Sort-Object -Property Name)) {
        $passed = @($group.Group | Where-Object { $_.Status -eq 'Succeeded' }).Count
        $failed = @($group.Group | Where-Object { $_.Status -eq 'Failed' }).Count
        $skipped = @($group.Group | Where-Object { $_.Status -eq 'Skipped' }).Count
        $verdict = if ($failed -gt 0) { 'FAIL' } elseif ($passed -gt 0) { 'PASS' } else { 'SKIPPED' }
        $level = if ($failed -gt 0) { 'ERROR' } elseif ($passed -gt 0) { 'SUCCESS' } else { 'WARNING' }
        Write-MigrationLog -Message ($format -f $group.Name, $passed, $failed, $skipped, $verdict) -Level $level
    }
}

#endregion Functions

#region Main

$exitCode = 0
$results = [System.Collections.Generic.List[object]]::new()

$null = Initialize-MigrationRun -ScriptName 'Test-MigrationReadiness' -OutputPath $OutputPath -Prefix $Prefix `
    -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    # The whole plan is loaded even when -Wave narrows the checks, because the Provisioned stage
    # writes back and Save-MigrationPlan rewrites the file in full.
    $allRows = @(Import-MigrationPlan -Path $PlanPath)
    $scopedRows = @(Select-MigrationPlanRows -Rows $allRows -Wave $Wave)
    if ($scopedRows.Count -eq 0) {
        # Bail out before signing in: connecting to check nothing is pure cost, and an empty scope is
        # almost always a -Wave value that does not appear in the plan.
        throw "No plan rows are in scope. Check -Wave against the Wave column in '$PlanPath'."
    }
    Write-MigrationLog -Message "Stage '$Stage' over $($scopedRows.Count) plan row(s)." -Level INFO

    $sourceMailboxByAddress = @{}
    if ($SourceMailboxesCsv) {
        foreach ($mailboxRow in @(Import-MigrationCsv -Path $SourceMailboxesCsv -RequiredColumns @('PrimarySmtpAddress'))) {
            $key = ([string](Get-MigrationCsvValue -Row $mailboxRow -Name 'PrimarySmtpAddress' -Default '')).ToLowerInvariant()
            if ($key) { $sourceMailboxByAddress[$key] = $mailboxRow }
        }
        Write-MigrationLog -Message "Loaded $($sourceMailboxByAddress.Count) source mailbox record(s)." -Level INFO
    }

    $graphContext = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId
    $exoConnection = Connect-MigrationExchange -DelegatedOrganization $DelegatedOrganization

    # Connect-MigrationExchange reuses a live EXO session whenever -DelegatedOrganization is
    # omitted, which is exactly how every documented -TenantId-only run is invoked. Without this
    # check a leftover session to the source tenant runs every Exchange-backed check against the
    # wrong tenant while Graph correctly targets the destination.
    $graphTenantId = [string](Get-MigrationProperty -InputObject $graphContext -Name 'TenantId' -Default '')
    $exoTenantId = [string](Get-MigrationProperty -InputObject $exoConnection -Name 'TenantID' -Default '')
    if ($graphTenantId -and $exoTenantId -and $graphTenantId -ne $exoTenantId) {
        throw ("Microsoft Graph is connected to tenant $graphTenantId but Exchange Online is connected to " +
            "tenant $exoTenantId. Re-run with -DelegatedOrganization for the same destination tenant, or run " +
            "Disconnect-ExchangeOnline first so a fresh session is established.")
    }
    Write-MigrationLog -Message ("Checking destination tenant $graphTenantId (Graph as " +
        "$(Get-MigrationProperty -InputObject $graphContext -Name 'Account' -Default '?'), EXO as " +
        "$(Get-MigrationProperty -InputObject $exoConnection -Name 'UserPrincipalName' -Default '?')).") -Level INFO

    if ($Stage -eq 'Pre') {
        # PlanClean - anything the planner could not resolve is a blocker, not a warning.
        $dirty = @($scopedRows | Where-Object {
                $dirtyPlanStatus -contains (Get-MigrationCsvValue -Row $_ -Name 'PlanStatus' -Default '')
            })
        foreach ($row in $dirty) {
            $results.Add((New-CheckResult -Row $row -Action 'PlanClean' -Status 'Failed' -Stage $Stage -Detail (
                        "PlanStatus is '$(Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default '')': " +
                        "$(Get-MigrationCsvValue -Row $row -Name 'PlanDetail' -Default 'no detail recorded')")))
        }
        if ($dirty.Count -eq 0) {
            $results.Add((New-CheckResult -Action 'PlanClean' -Status 'Succeeded' -Stage $Stage `
                        -Detail "No NeedsReview, Invalid or Collision rows in $($scopedRows.Count) row(s)."))
        }

        # DomainVerified - every domain the plan intends to use must already be verified.
        $verifiedDomain = @(Get-VerifiedDomain)
        $plannedDomain = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($row in $scopedRows) {
            foreach ($candidate in (Get-PlanAddressCandidate -Row $row)) {
                if ($candidate.Kind -eq 'MailNickname') { continue }
                $domain = Get-AddressDomain -Value $candidate.Value
                if ($domain) { [void]$plannedDomain.Add($domain) }
            }
        }
        foreach ($domain in $plannedDomain) {
            $isVerified = $verifiedDomain -contains $domain
            $results.Add((New-CheckResult -Identity $domain -Action 'DomainVerified' -Stage $Stage `
                        -Status $(if ($isVerified) { 'Succeeded' } else { 'Failed' }) `
                        -Detail $(if ($isVerified) { 'Verified in the destination tenant.' }
                            else { 'Not a verified domain in the destination tenant.' })))
        }
        if ($plannedDomain.Count -eq 0) {
            $results.Add((New-CheckResult -Action 'DomainVerified' -Status 'Skipped' -Stage $Stage `
                        -Detail 'The plan names no target or interim addresses.'))
        }

        # SkuSeats - the seat arithmetic the tenant will enforce, run before anyone waits on it.
        $seat = @(Measure-SeatRequirement -Row $scopedRows -Catalog @(Get-MigrationSkuCatalog))
        foreach ($sku in $seat) {
            $detail = switch ($sku.Status) {
                'Unknown' { "The destination tenant has no subscription with part number '$($sku.SkuPartNumber)'." }
                'Shortfall' { "Needs $($sku.Needed), $($sku.Available) available - short by $($sku.Shortfall)." }
                default { "Needs $($sku.Needed) of $($sku.Available) available." }
            }
            $results.Add((New-CheckResult -Identity $sku.SkuPartNumber -Action 'SkuSeats' -Stage $Stage -Detail $detail `
                        -Status $(if ($sku.Status -eq 'Sufficient') { 'Succeeded' } else { 'Failed' })))
        }
        if ($seat.Count -eq 0) {
            $results.Add((New-CheckResult -Action 'SkuSeats' -Status 'Skipped' -Stage $Stage `
                        -Detail 'No plan row asks for a licence.'))
        }

        # UsageLocation - assignLicense fails outright without one.
        $licensed = @($scopedRows | Where-Object { (Get-MigrationCsvValue -Row $_ -Name 'TargetLicenses' -Default '') })
        $noLocation = @($licensed | Where-Object { -not (Get-MigrationCsvValue -Row $_ -Name 'UsageLocation' -Default '') })
        foreach ($row in $noLocation) {
            $results.Add((New-CheckResult -Row $row -Action 'UsageLocation' -Status 'Failed' -Stage $Stage `
                        -Detail 'Row is licensed but has no UsageLocation; assignLicense will fail unless a default is supplied.'))
        }
        if ($noLocation.Count -eq 0) {
            $results.Add((New-CheckResult -Action 'UsageLocation' -Status 'Succeeded' -Stage $Stage `
                        -Detail "All $($licensed.Count) licensed row(s) carry a usage location."))
        }

        # AddressClash - users, groups, soft-deleted users (Graph) plus every mail-enabled recipient (EXO).
        $upnList = [System.Collections.Generic.List[string]]::new()
        $addressList = [System.Collections.Generic.List[string]]::new()
        $nicknameList = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $scopedRows) {
            foreach ($candidate in (Get-PlanAddressCandidate -Row $row)) {
                switch ($candidate.Kind) {
                    'Upn' { $upnList.Add($candidate.Value); $addressList.Add($candidate.Value) }
                    'Smtp' { $addressList.Add($candidate.Value) }
                    'MailNickname' { $nicknameList.Add($candidate.Value) }
                }
            }
        }

        $existing = [System.Collections.Generic.List[object]]::new()
        $existing.AddRange(@(Get-DirectoryClashObject -UserPrincipalName $upnList.ToArray() `
                    -EmailAddress $addressList.ToArray() -MailNickname $nicknameList.ToArray() -BatchSize $graphFilterBatchSize))
        $existing.AddRange(@(Get-RecipientClashObject -EmailAddress $addressList.ToArray() -BatchSize $exoFilterBatchSize))
        Write-MigrationLog -Message "Found $($existing.Count) destination object(s) holding a planned identifier." -Level INFO

        $clash = @(Test-AddressClash -Row $scopedRows -ExistingObject $existing.ToArray() -Stage $Stage)
        foreach ($row in $clash) { $results.Add($row) }
        if ($clash.Count -eq 0) {
            $results.Add((New-CheckResult -Action 'AddressClash' -Status 'Succeeded' -Stage $Stage `
                        -Detail 'No planned UPN, address or mail nickname is already taken.'))
        }

        # SyncedSource - a directory-synced source object cannot have its addresses edited in EXO.
        $synced = @($scopedRows | Where-Object { (Get-MigrationCsvValue -Row $_ -Name 'IsSynced' -Default '') -match '(?i)^true$' })
        foreach ($row in $synced) {
            $results.Add((New-CheckResult -Row $row -Action 'SyncedSource' -Status 'Skipped' -Stage $Stage `
                        -Detail ('Source object is directory-synced; addresses must be edited on-premises and ' +
                            'synced, not in Exchange Online.')))
        }
        if ($synced.Count -gt 0) {
            Write-MigrationLog -Message "$($synced.Count) plan row(s) are directory-synced at the source." -Level WARNING
        }
        else {
            $results.Add((New-CheckResult -Action 'SyncedSource' -Status 'Succeeded' -Stage $Stage `
                        -Detail 'No directory-synced source objects in scope.'))
        }
    }
    else {
        $provisionedRows = @($scopedRows | Where-Object { (Get-MigrationCsvValue -Row $_ -Name 'TargetObjectId' -Default '') })
        foreach ($row in @($scopedRows | Where-Object { -not (Get-MigrationCsvValue -Row $_ -Name 'TargetObjectId' -Default '') })) {
            $results.Add((New-CheckResult -Row $row -Action 'UserExists' -Status 'Skipped' -Stage $Stage `
                        -Detail 'No TargetObjectId yet; the row has not been provisioned.'))
        }

        # Distribution lists, security groups, contacts and dynamic groups have no Graph user, no
        # mailbox in the sense these checks mean, and no OneDrive; New-MigrationRecipients already
        # verifies they were created. Running the user/mailbox checks over them fails UserExists on
        # every one and forces exit 2 on any plan that contains recipients alongside users.
        $recipientOnlyObjectTypes = @('Distribution', 'MailEnabledSecurity', 'Contact', 'DynamicDistribution', 'M365Group')

        $changed = $false
        foreach ($row in $provisionedRows) {
            $objectType = Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default ''
            if ($recipientOnlyObjectTypes -contains $objectType) {
                $results.Add((New-CheckResult -Row $row -Action 'ReadinessCheck' -Status 'Skipped' -Stage $Stage `
                            -Detail 'Recipient rows are verified by New-MigrationRecipients; this stage checks users and mailboxes only.'))
                continue
            }

            $objectId = Get-MigrationCsvValue -Row $row -Name 'TargetObjectId' -Default ''

            $user = $null
            try {
                $user = Invoke-MigrationGraphRequest -Method GET `
                    -Uri "/v1.0/users/$objectId`?`$select=id,userPrincipalName,displayName,accountEnabled,usageLocation"
            }
            catch { if (-not (Test-GraphNotFound -ErrorRecord $_)) { throw } }

            $mailbox = $null
            try {
                $mailbox = Get-EXOMailbox -Identity $objectId -ErrorAction Stop -PropertySets Minimum -Properties @(
                    'LitigationHoldEnabled', 'ArchiveStatus', 'ArchiveGuid', 'ProhibitSendReceiveQuota',
                    'HiddenFromAddressListsEnabled', 'EmailAddresses', 'PrimarySmtpAddress'
                )
            }
            catch {
                # Not-found is a real finding (no mailbox yet); anything else - a throttled or
                # dropped REST session, a permission error, a wrong-tenant session - is rethrown so
                # it stops the run instead of quietly writing MailboxProvisioned=False for every row.
                if ($_.Exception.Message -match 'ManagementObjectNotFoundException|couldn.t be found' -or
                    $_.CategoryInfo.Category -eq 'ObjectNotFound') {
                    Write-MigrationLog -Message "No mailbox for $objectId - $($_.Exception.Message)" -Level DEBUG
                }
                else {
                    throw "Could not read mailbox $objectId from Exchange Online: $($_.Exception.Message)"
                }
            }

            if ($Stage -eq 'Post') {
                foreach ($resultRow in @(Test-PostRow -Row $row -User $user -Mailbox $mailbox)) { $results.Add($resultRow) }
                continue
            }

            # With the delegated auth this script uses, GET /users/{id}/drive auto-provisions the
            # user's OneDrive when they are licensed and do not have one yet - a tenant write, so it
            # is gated behind ShouldProcess/-WhatIf and skipped under -DryRun like every other
            # mutation, leaving the check Skipped and OneDriveProvisioned unchanged rather than
            # writing a False that a check which never ran did not actually observe.
            $driveState = 'NotChecked'
            if ($PSCmdlet.ShouldProcess($objectId, 'Read OneDrive (provisions the drive if licensed and absent)')) {
                $isDryRun = [bool](Get-MigrationRunContext).DryRun
                try {
                    $drive = Invoke-MigrationAction -Description "Read OneDrive for $objectId (provisions it if licensed and absent)" `
                        -PassThru -Action { Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/users/$objectId/drive" }
                    if (-not $isDryRun) { $driveState = if ($null -ne $drive) { 'Present' } else { 'Absent' } }
                }
                catch {
                    if (-not (Test-GraphNotFound -ErrorRecord $_)) { throw }
                    if (-not $isDryRun) { $driveState = 'Absent' }
                }
            }

            $sourceAddress = ([string](Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default '')).ToLowerInvariant()
            $sourceMailbox = if ($sourceAddress -and $sourceMailboxByAddress.ContainsKey($sourceAddress)) {
                $sourceMailboxByAddress[$sourceAddress]
            }
            else { $null }

            $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox `
                -DriveState $driveState -SourceMailbox $sourceMailbox
            foreach ($resultRow in @($graded.Row)) { $results.Add($resultRow) }

            if ((Get-MigrationCsvValue -Row $row -Name 'MailboxProvisioned' -Default '') -ne $graded.MailboxProvisioned -or
                (Get-MigrationCsvValue -Row $row -Name 'OneDriveProvisioned' -Default '') -ne $graded.OneDriveProvisioned) {
                $row.MailboxProvisioned = $graded.MailboxProvisioned
                $row.OneDriveProvisioned = $graded.OneDriveProvisioned
                $changed = $true
            }
        }

        if ($Stage -eq 'Provisioned' -and $changed) {
            if ($PSCmdlet.ShouldProcess($PlanPath, 'Write back MailboxProvisioned and OneDriveProvisioned')) {
                Invoke-MigrationAction -Description "Update provisioning state in $PlanPath" -Action {
                    Save-MigrationPlan -Path $PlanPath -Rows $allRows
                }
            }
        }
        elseif ($Stage -eq 'Provisioned') {
            Write-MigrationLog -Message 'Provisioning state already matches the plan; nothing written back.' -Level INFO
        }
    }
}
catch {
    Write-MigrationLog -Message "Fatal: $($_.Exception.Message)" -Level ERROR
    $exitCode = 1
}

#endregion Main

#region Cleanup

Write-CheckTable -Result $results.ToArray()

if ($results.Count -gt 0) {
    try { $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Test-MigrationReadiness' }
    catch {
        Write-MigrationLog -Message "Could not write the results file: $($_.Exception.Message)" -Level ERROR
        $exitCode = 1
    }
}

if ($exitCode -eq 0 -and @($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { $exitCode = 2 }

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion Cleanup
