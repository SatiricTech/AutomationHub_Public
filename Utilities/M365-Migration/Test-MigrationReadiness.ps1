#Requires -Version 7.4

<#
.SYNOPSIS
    Pre-flights the destination tenant against an identity plan and reports every check as pass or fail.

.DESCRIPTION
    The gate between planning and provisioning, and again between provisioning and cutover. It reads
    the destination tenant and answers one question per check: is the plan safe to run right now?
    Nothing is written to the tenant at any stage.

    Three stages, each answering a different question:

      Pre          Before any object exists. Are the target and interim domains verified? Are there
                   enough seats for the SKUs the plan asks for? Does every licensed row have a usage
                   location? Does any target UPN, SMTP address, alias or mail nickname already belong
                   to a user, group, contact or mailbox in the destination - or to a soft-deleted
                   user, which holds its UPN and will return 409 on create until it is purged or
                   restored? Is the plan itself clean of NeedsReview, Invalid and Collision rows?

      Provisioned  After New-MigrationUsers and Set-MigrationLicenses. Does the user exist? Does the
                   mailbox exist? Is the archive on where the source had one? Is litigation hold off
                   (third-party move tools refuse mailboxes that hold)? Has OneDrive been provisioned
                   - GET /users/{id}/drive returns 404 until it has - and is the destination quota at
                   least the size of the source mailbox? This is the only stage that writes anything,
                   and it writes only back to the plan: MailboxProvisioned and OneDriveProvisioned.

      Post         After cutover. Is the UPN the planned one? Is the primary SMTP address the planned
                   one? Is every planned alias present, X500 included? Is the object out of hiding and
                   the account enabled?

    Each check produces one result row. A per-object check that finds nothing wrong reports a single
    summary row rather than one row per object, so a clean run stays readable; anything wrong is
    reported per object. The run ends with a pass/fail table and exits 2 if any check failed.

.PARAMETER PlanPath
    Path to IdentityPlan.csv.

.PARAMETER Stage
    Pre (default), Provisioned or Post. See the description for what each stage asks.

.PARAMETER Wave
    One or more wave labels to check. Omit to check every wave.

.PARAMETER SourceMailboxesCsv
    Optional inventory of the source mailboxes, used by the Provisioned stage for the archive and
    mailbox-size checks. Recognised columns: PrimarySmtpAddress (required), TotalItemSizeGB,
    ArchiveStatus. Without it those two checks report Skipped rather than guessing.

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
    Suppresses the Provisioned stage's plan writeback - the one and only thing this script changes.
    Every check still runs and the results file is written with the -DryRun_ marker.

.PARAMETER Verbosity
    Console detail: Low (errors and successes), Medium (default, adds warnings) or High (everything).
    The log file always receives every line.

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -PlanPath .\IdentityPlan.csv -Prefix Fabrikam

    Runs the Pre stage over the whole plan and writes Fabrikam_Test-MigrationReadiness-Results_<ts>.csv.

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -Stage Provisioned -SourceMailboxesCsv .\Mailboxes.csv

    Confirms wave 1's users, mailboxes, archives and OneDrive sites exist in the destination and
    records MailboxProvisioned / OneDriveProvisioned back into the plan.

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -Stage Post -DelegatedOrganization newco.onmicrosoft.com

    Verifies wave 1 landed on its planned addresses in a GDAP-delegated destination tenant.

.EXAMPLE
    .\Test-MigrationReadiness.ps1 -PlanPath .\IdentityPlan.csv -Stage Provisioned -DryRun

    Runs every Provisioned check and reports them without touching the plan file.

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

function Get-PropertyValue {
    <#
    .SYNOPSIS
        Reads a property from an arbitrary object without tripping Set-StrictMode.

    .DESCRIPTION
        Graph and Exchange both omit properties that have no value, and strict mode makes a blind
        read of a missing property fatal. Get-MigrationCsvValue solves the same problem for plan rows
        but stringifies its result, which destroys arrays such as EmailAddresses.

    .PARAMETER InputObject
        The object to read from. $null is tolerated and yields the default.

    .PARAMETER Name
        The property name.

    .PARAMETER Default
        Returned when the object is null, the property is absent, or its value is null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if (-not $InputObject.Contains($Name)) { return $Default }
        $raw = $InputObject[$Name]
        if ($null -eq $raw) { return $Default }
        return $raw
    }
    if (-not $InputObject.PSObject.Properties[$Name]) { return $Default }

    $value = $InputObject.PSObject.Properties[$Name].Value
    if ($null -eq $value) { return $Default }
    return $value
}

function New-CheckResult {
    <#
    .SYNOPSIS
        Builds one result row in the toolkit's fixed column order.

    .PARAMETER Identity
        The object or check the row is about.

    .PARAMETER Action
        The check name, which is also what the pass/fail table groups on.

    .PARAMETER Status
        Succeeded, Failed or Skipped.

    .PARAMETER Detail
        Human-readable explanation. Always populated for Failed and Skipped rows.

    .PARAMETER Stage
        Pre, Provisioned or Post.

    .PARAMETER Wave
        The plan row's wave, when the row is about a plan object.

    .PARAMETER ObjectType
        The plan row's object type, when the row is about a plan object.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory result object for the results CSV; it changes no state.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Succeeded', 'Failed', 'Skipped')][string]$Status,
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$Stage = '',
        [AllowEmptyString()][string]$Wave = '',
        [AllowEmptyString()][string]$ObjectType = ''
    )

    return [pscustomobject]@{
        Identity   = $Identity
        Action     = $Action
        Status     = $Status
        Detail     = $Detail
        Stage      = $Stage
        Wave       = $Wave
        ObjectType = $ObjectType
    }
}

function ConvertTo-BareAddress {
    <#
    .SYNOPSIS
        Strips an Exchange proxy-address prefix and returns the bare, lower-cased address.

    .DESCRIPTION
        Plan aliases and Exchange EmailAddresses both carry a type prefix - 'smtp:', 'SMTP:',
        'X500:', 'sip:'. Only SMTP addresses take part in address clash detection, so anything else
        returns an empty string and the caller drops it.

    .PARAMETER Value
        The raw proxy address.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    $text = ([string]$Value).Trim()
    if (-not $text) { return '' }
    if ($text -notmatch ':') { return $text.ToLowerInvariant() }
    if ($text -match '^(?i)smtp:(.+)$') { return $Matches[1].Trim().ToLowerInvariant() }
    return ''
}

function Get-AddressDomain {
    <#
    .SYNOPSIS
        Returns the domain half of an address, lower-cased, or an empty string.

    .PARAMETER Value
        A UPN or SMTP address.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

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
        The clash and domain checks both need the same list: the target and interim UPNs, the target
        and interim primary SMTP addresses, the SMTP aliases, and the mail nickname. X500 entries in
        TargetAliases are routing history, not claims on an address, so they are excluded here and
        checked only by the Post stage.

    .PARAMETER Row
        The identity plan row.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row
    )

    $candidate = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$Kind, [string]$Scope, [string]$Value)
        $text = ([string]$Value).Trim()
        if ($text) {
            $candidate.Add([pscustomobject]@{ Kind = $Kind; Scope = $Scope; Value = $text.ToLowerInvariant() })
        }
    }

    & $add 'Upn' 'Target' (Get-MigrationCsvValue -Row $Row -Name 'TargetUserPrincipalName' -Default '')
    & $add 'Upn' 'Interim' (Get-MigrationCsvValue -Row $Row -Name 'InterimUserPrincipalName' -Default '')
    & $add 'Smtp' 'Target' (Get-MigrationCsvValue -Row $Row -Name 'TargetPrimarySmtp' -Default '')
    & $add 'Smtp' 'Interim' (Get-MigrationCsvValue -Row $Row -Name 'InterimPrimarySmtp' -Default '')
    & $add 'MailNickname' 'Target' (Get-MigrationCsvValue -Row $Row -Name 'TargetMailNickname' -Default '')

    foreach ($alias in @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'TargetAliases' -Default ''))) {
        & $add 'Smtp' 'Alias' (ConvertTo-BareAddress -Value $alias)
    }

    return $candidate.ToArray()
}

function Get-PlanRowIdentity {
    <#
    .SYNOPSIS
        Picks the most useful label for a plan row in a result file.

    .PARAMETER Row
        The identity plan row.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row
    )

    foreach ($column in @('TargetUserPrincipalName', 'TargetPrimarySmtp', 'InterimUserPrincipalName',
            'SourceUserPrincipalName', 'SourcePrimarySmtp', 'DisplayName')) {
        $value = Get-MigrationCsvValue -Row $Row -Name $column -Default ''
        if ($value) { return $value }
    }
    return '(unnamed plan row)'
}

function Test-AddressClash {
    <#
    .SYNOPSIS
        Reports every planned identifier that something in the destination tenant already holds.

    .DESCRIPTION
        Pure: it takes the plan rows and a flat list of destination objects, so the clash rules can
        be exercised offline against a fake recipient list. An object whose id matches the row's own
        TargetObjectId is not a clash - that is the row's own, already-provisioned object.

    .PARAMETER Row
        The plan rows to check.

    .PARAMETER ExistingObject
        Destination objects, each with Id, Kind, DisplayName, MailNickname and an Address array of
        bare SMTP addresses and UPNs.

    .PARAMETER Stage
        Stamped onto every result row.
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
    foreach ($existing in @($ExistingObject)) {
        foreach ($address in @(Get-PropertyValue -InputObject $existing -Name 'Address' -Default @())) {
            $key = ([string]$address).Trim().ToLowerInvariant()
            if (-not $key) { continue }
            if (-not $byAddress.ContainsKey($key)) { $byAddress[$key] = [System.Collections.Generic.List[object]]::new() }
            $byAddress[$key].Add($existing)
        }
        $nickname = ([string](Get-PropertyValue -InputObject $existing -Name 'MailNickname' -Default '')).Trim().ToLowerInvariant()
        if (-not $nickname) { continue }
        if (-not $byNickname.ContainsKey($nickname)) { $byNickname[$nickname] = [System.Collections.Generic.List[object]]::new() }
        $byNickname[$nickname].Add($existing)
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($planRow in @($Row)) {
        $identity = Get-PlanRowIdentity -Row $planRow
        $ownId = Get-MigrationCsvValue -Row $planRow -Name 'TargetObjectId' -Default ''
        $reported = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($candidate in (Get-PlanAddressCandidate -Row $planRow)) {
            $index = if ($candidate.Kind -eq 'MailNickname') { $byNickname } else { $byAddress }
            if (-not $index.ContainsKey($candidate.Value)) { continue }

            foreach ($hit in $index[$candidate.Value]) {
                $hitId = [string](Get-PropertyValue -InputObject $hit -Name 'Id' -Default '')
                if ($ownId -and $hitId -and $hitId -eq $ownId) { continue }

                $kind = [string](Get-PropertyValue -InputObject $hit -Name 'Kind' -Default 'object')
                $name = [string](Get-PropertyValue -InputObject $hit -Name 'DisplayName' -Default '')
                if (-not $reported.Add("$($candidate.Value)|$kind|$hitId")) { continue }

                $held = if ($name) { "$kind '$name'" } else { $kind }
                $results.Add((New-CheckResult -Identity $identity -Action 'AddressClash' -Status 'Failed' `
                    -Detail "$($candidate.Scope) $($candidate.Kind) '$($candidate.Value)' is already held by $held." `
                    -Stage $Stage -Wave (Get-MigrationCsvValue -Row $planRow -Name 'Wave' -Default '') `
                    -ObjectType (Get-MigrationCsvValue -Row $planRow -Name 'ObjectType' -Default '')))
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
        subscribe to is reported with Status 'Unknown' - almost always a SKU map that was written
        against the source tenant's product names.

    .PARAMETER Row
        The plan rows to total.

    .PARAMETER Catalog
        Output of Get-MigrationSkuCatalog (needs SkuPartNumber and Available).
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

    $catalogByPart = @{}
    foreach ($sku in @($Catalog)) {
        $part = [string](Get-PropertyValue -InputObject $sku -Name 'SkuPartNumber' -Default '')
        if ($part) { $catalogByPart[$part] = $sku }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($part in $needed.Keys) {
        $count = [int]$needed[$part]
        if (-not $catalogByPart.ContainsKey($part)) {
            $rows.Add([pscustomobject]@{
                SkuPartNumber = $part; Needed = $count; Available = 0; Shortfall = $count; Status = 'Unknown'
            })
            continue
        }

        $available = [int](Get-PropertyValue -InputObject $catalogByPart[$part] -Name 'Available' -Default 0)
        $shortfall = [Math]::Max(0, $count - $available)
        $rows.Add([pscustomobject]@{
            SkuPartNumber = $part
            Needed        = $count
            Available     = $available
            Shortfall     = $shortfall
            Status        = if ($shortfall -gt 0) { 'Shortfall' } else { 'Sufficient' }
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
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    $text = ([string]$Value).Trim()
    if (-not $text) { return 0 }
    if ($text -match '(?i)^unlimited$') { return [double]::MaxValue }

    if ($text -match '\(([\d,\.]+)\s*bytes\)') {
        $bytes = $Matches[1] -replace '[,\s]', ''
        $parsed = 0.0
        if ([double]::TryParse($bytes, [ref]$parsed)) { return [Math]::Round($parsed / 1GB, 3) }
    }

    if ($text -match '(?i)^([\d,\.]+)\s*(KB|MB|GB|TB)') {
        $number = $Matches[1] -replace ',', ''
        $parsed = 0.0
        if ([double]::TryParse($number, [ref]$parsed)) {
            $factor = switch ($Matches[2].ToUpperInvariant()) {
                'KB' { 1 / 1MB }
                'MB' { 1 / 1KB }
                'TB' { 1024 }
                default { 1 }
            }
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
        finding rather than an error. The module's own status-code helper is private, so the two
        signals that matter - the response status and the Graph error code - are read here.

    .PARAMETER ErrorRecord
        The ErrorRecord from the catch block.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$ErrorRecord
    )

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        $status = $response.Value.PSObject.Properties['StatusCode']
        if ($status -and $status.Value) { return ([int]$status.Value -eq 404) }
    }

    $detail = ''
    if ($ErrorRecord.ErrorDetails) { $detail = [string]$ErrorRecord.ErrorDetails.Message }
    if ($detail -match '(?i)"code"\s*:\s*"(itemNotFound|notFound|ResourceNotFound|Request_ResourceNotFound)"') {
        return $true
    }

    return ([string]$ErrorRecord.Exception.Message -match '(?i)\b404\b|not\s*found')
}

function Get-VerifiedDomain {
    <#
    .SYNOPSIS
        Returns the verified domain names on the connected tenant, lower-cased.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $domains = @(Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/domains' -All)
    $verified = [System.Collections.Generic.List[string]]::new()
    foreach ($domain in $domains) {
        if (-not [bool](Get-PropertyValue -InputObject $domain -Name 'isVerified' -Default $false)) { continue }
        $name = [string](Get-PropertyValue -InputObject $domain -Name 'id' -Default '')
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
        are queried separately under /directory/deletedItems because a deleted user still owns its
        UPN and proxy addresses, and will fail a create or a rename with 409 until it is purged.

    .PARAMETER UserPrincipalName
        UPNs to look for.

    .PARAMETER EmailAddress
        Bare SMTP addresses to look for.

    .PARAMETER MailNickname
        Mail nicknames to look for.

    .PARAMETER BatchSize
        Equality clauses per request.
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

    $invokeBatched = {
        param([string[]]$Clause, [string]$Uri, [string]$Kind, [int]$Size)

        for ($offset = 0; $offset -lt $Clause.Count; $offset += $Size) {
            $take = [Math]::Min($Size, $Clause.Count - $offset)
            $filter = [uri]::EscapeDataString((@($Clause[$offset..($offset + $take - 1)]) -join ' or '))
            try {
                $page = @(Invoke-MigrationGraphRequest -Method GET -Uri "$Uri&`$filter=$filter" -All)
            }
            catch {
                throw "Could not read destination $Kind objects from Graph: $($_.Exception.Message)"
            }

            foreach ($item in $page) {
                $address = [System.Collections.Generic.List[string]]::new()
                $upn = [string](Get-PropertyValue -InputObject $item -Name 'userPrincipalName' -Default '')
                if ($upn) { $address.Add($upn.ToLowerInvariant()) }
                $mail = [string](Get-PropertyValue -InputObject $item -Name 'mail' -Default '')
                if ($mail) { $address.Add($mail.ToLowerInvariant()) }
                foreach ($proxy in @(Get-PropertyValue -InputObject $item -Name 'proxyAddresses' -Default @())) {
                    $bare = ConvertTo-BareAddress -Value ([string]$proxy)
                    if ($bare) { $address.Add($bare) }
                }

                $found.Add([pscustomobject]@{
                    Id           = [string](Get-PropertyValue -InputObject $item -Name 'id' -Default '')
                    Kind         = $Kind
                    DisplayName  = [string](Get-PropertyValue -InputObject $item -Name 'displayName' -Default '')
                    MailNickname = ([string](Get-PropertyValue -InputObject $item -Name 'mailNickname' `
                        -Default '')).ToLowerInvariant()
                    Address      = @($address | Sort-Object -Unique)
                })
            }
        }
    }

    $upnClause = [System.Collections.Generic.List[string]]::new()
    $mailClause = [System.Collections.Generic.List[string]]::new()
    $nicknameClause = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($UserPrincipalName | Sort-Object -Unique)) {
        if ($value) { $upnClause.Add("userPrincipalName eq '$(ConvertTo-MigrationODataString -Value $value)'") }
    }
    foreach ($value in @($EmailAddress | Sort-Object -Unique)) {
        if ($value) { $mailClause.Add("mail eq '$(ConvertTo-MigrationODataString -Value $value)'") }
    }
    foreach ($value in @($MailNickname | Sort-Object -Unique)) {
        if ($value) { $nicknameClause.Add("mailNickname eq '$(ConvertTo-MigrationODataString -Value $value)'") }
    }

    $userUri = "/v1.0/users?`$select=id,displayName,userPrincipalName,mail,mailNickname,proxyAddresses&`$top=999"
    $groupUri = "/v1.0/groups?`$select=id,displayName,mail,mailNickname,proxyAddresses&`$top=999"
    $deletedSelect = 'id,displayName,userPrincipalName,mail,mailNickname,proxyAddresses'
    $deletedUri = "/v1.0/directory/deletedItems/microsoft.graph.user?`$select=$deletedSelect&`$top=999"

    & $invokeBatched @($upnClause + $mailClause + $nicknameClause) $userUri 'User' $BatchSize
    & $invokeBatched @($mailClause + $nicknameClause) $groupUri 'Group' $BatchSize
    & $invokeBatched @($upnClause + $mailClause) $deletedUri 'SoftDeletedUser' $BatchSize

    return $found.ToArray()
}

function Get-RecipientClashObject {
    <#
    .SYNOPSIS
        Reads the Exchange recipients that hold any of the given SMTP addresses.

    .DESCRIPTION
        Get-EXORecipient covers mailboxes, mail users, mail contacts and distribution groups in one
        pass, which is the whole mail-enabled surface a new address can collide with. The addresses
        go into a single OPATH filter per batch rather than one Get-EXORecipient call per plan row -
        tenant-wide recipient reads are exactly what throttles on a large org.

    .PARAMETER EmailAddress
        Bare SMTP addresses to look for.

    .PARAMETER BatchSize
        Addresses per Exchange filter.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$EmailAddress,
        [ValidateRange(1, 50)][int]$BatchSize = 20
    )

    $wanted = @($EmailAddress | Where-Object { $_ } | Sort-Object -Unique)
    $found = [System.Collections.Generic.List[object]]::new()
    if ($wanted.Count -eq 0) { return $found.ToArray() }

    for ($offset = 0; $offset -lt $wanted.Count; $offset += $BatchSize) {
        $take = [Math]::Min($BatchSize, $wanted.Count - $offset)
        $clause = foreach ($address in $wanted[$offset..($offset + $take - 1)]) {
            "EmailAddresses -eq 'smtp:$(ConvertTo-MigrationODataString -Value $address)'"
        }
        $filter = ($clause -join ' -or ')

        try {
            $page = @(Get-EXORecipient -Filter $filter -ResultSize Unlimited -ErrorAction Stop)
        }
        catch {
            throw "Could not read Exchange recipients: $($_.Exception.Message)"
        }

        foreach ($recipient in $page) {
            $address = [System.Collections.Generic.List[string]]::new()
            foreach ($proxy in @(Get-PropertyValue -InputObject $recipient -Name 'EmailAddresses' -Default @())) {
                $bare = ConvertTo-BareAddress -Value ([string]$proxy)
                if ($bare) { $address.Add($bare) }
            }
            $primary = [string](Get-PropertyValue -InputObject $recipient -Name 'PrimarySmtpAddress' -Default '')
            if ($primary) { $address.Add($primary.ToLowerInvariant()) }

            $found.Add([pscustomobject]@{
                Id           = [string](Get-PropertyValue -InputObject $recipient -Name 'ExternalDirectoryObjectId' -Default '')
                Kind         = [string](Get-PropertyValue -InputObject $recipient -Name 'RecipientType' -Default 'Recipient')
                DisplayName  = [string](Get-PropertyValue -InputObject $recipient -Name 'DisplayName' -Default '')
                MailNickname = ([string](Get-PropertyValue -InputObject $recipient -Name 'Alias' -Default '')).ToLowerInvariant()
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
        Pure: the caller does the reading, this decides what the readings mean, so every branch is
        testable with plain objects. Returns Row (the check results), MailboxProvisioned and
        OneDriveProvisioned ('True'/'False' as the plan schema stores booleans).

    .PARAMETER Row
        The identity plan row.

    .PARAMETER User
        The destination Graph user, or $null when the lookup returned 404.

    .PARAMETER Mailbox
        The destination mailbox from Get-EXOMailbox, or $null when there is none yet.

    .PARAMETER DriveExists
        Whether GET /users/{id}/drive returned a drive.

    .PARAMETER SourceMailbox
        The matching source mailbox inventory row, or $null when no inventory was supplied.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row,
        [AllowNull()]$User,
        [AllowNull()]$Mailbox,
        [switch]$DriveExists,
        [AllowNull()]$SourceMailbox
    )

    $identity = Get-PlanRowIdentity -Row $Row
    $wave = Get-MigrationCsvValue -Row $Row -Name 'Wave' -Default ''
    $objectType = Get-MigrationCsvValue -Row $Row -Name 'ObjectType' -Default ''
    $results = [System.Collections.Generic.List[object]]::new()

    $newRow = {
        param([string]$Action, [string]$Status, [string]$Detail)
        New-CheckResult -Identity $identity -Action $Action -Status $Status -Detail $Detail `
            -Stage 'Provisioned' -Wave $wave -ObjectType $objectType
    }

    if ($null -eq $User) {
        $results.Add((& $newRow 'UserExists' 'Failed' 'No destination user with this TargetObjectId.'))
        return @{ Row = $results.ToArray(); MailboxProvisioned = 'False'; OneDriveProvisioned = 'False' }
    }
    $results.Add((& $newRow 'UserExists' 'Succeeded' `
        ([string](Get-PropertyValue -InputObject $User -Name 'userPrincipalName' -Default ''))))

    $hasMailbox = $null -ne $Mailbox
    $results.Add((& $newRow 'MailboxExists' $(if ($hasMailbox) { 'Succeeded' } else { 'Failed' }) `
        $(if ($hasMailbox) { [string](Get-PropertyValue -InputObject $Mailbox -Name 'PrimarySmtpAddress' -Default '') }
          else { 'No mailbox yet - the licence may still be provisioning.' })))

    if ($hasMailbox) {
        # Third-party move tools refuse a destination mailbox that is on hold, so this is a blocker
        # rather than a note.
        $hold = [bool](Get-PropertyValue -InputObject $Mailbox -Name 'LitigationHoldEnabled' -Default $false)
        $results.Add((& $newRow 'LitigationHoldOff' $(if ($hold) { 'Failed' } else { 'Succeeded' }) `
            $(if ($hold) { 'Litigation hold is on; the migration tool will refuse this mailbox.' } else { 'Off.' })))

        $sourceArchive = ''
        if ($null -ne $SourceMailbox) {
            $sourceArchive = Get-MigrationCsvValue -Row $SourceMailbox -Name 'ArchiveStatus' -Default ''
        }
        if (-not $sourceArchive) {
            $results.Add((& $newRow 'ArchiveEnabled' 'Skipped' 'No source archive state; supply -SourceMailboxesCsv.'))
        }
        elseif ($sourceArchive -match '(?i)^(none|disabled|false)$') {
            $results.Add((& $newRow 'ArchiveEnabled' 'Succeeded' 'Source had no archive; none required.'))
        }
        else {
            $archiveState = [string](Get-PropertyValue -InputObject $Mailbox -Name 'ArchiveStatus' -Default '')
            $archiveGuid = [string](Get-PropertyValue -InputObject $Mailbox -Name 'ArchiveGuid' -Default '')
            $hasArchive = ($archiveState -match '(?i)active') -or
                ($archiveGuid -and $archiveGuid -ne '00000000-0000-0000-0000-000000000000')
            $results.Add((& $newRow 'ArchiveEnabled' $(if ($hasArchive) { 'Succeeded' } else { 'Failed' }) `
                $(if ($hasArchive) { "Archive present (source: $sourceArchive)." }
                  else { "Source archive is '$sourceArchive' but the destination has no archive." })))
        }

        $sourceSize = 0.0
        if ($null -ne $SourceMailbox) {
            $raw = Get-MigrationCsvValue -Row $SourceMailbox -Name 'TotalItemSizeGB' -Default ''
            if ($raw) { $null = [double]::TryParse($raw, [ref]$sourceSize) }
        }
        if ($sourceSize -le 0) {
            $results.Add((& $newRow 'MailboxQuota' 'Skipped' 'No source mailbox size; supply -SourceMailboxesCsv.'))
        }
        else {
            $quotaGb = ConvertTo-QuotaGigabyte -Value ([string](Get-PropertyValue -InputObject $Mailbox `
                -Name 'ProhibitSendReceiveQuota' -Default ''))
            $fits = $quotaGb -ge $sourceSize
            $quotaText = if ($quotaGb -ge [double]::MaxValue) { 'unlimited' } else { "$quotaGb GB" }
            $results.Add((& $newRow 'MailboxQuota' $(if ($fits) { 'Succeeded' } else { 'Failed' }) `
                "Destination quota $quotaText vs source $sourceSize GB."))
        }
    }

    $results.Add((& $newRow 'OneDriveExists' $(if ($DriveExists) { 'Succeeded' } else { 'Failed' }) `
        $(if ($DriveExists) { 'Drive present.' }
          else { 'GET /users/{id}/drive returned 404; pre-provision with Request-SPOPersonalSite.' })))

    return @{
        Row                 = $results.ToArray()
        MailboxProvisioned  = if ($hasMailbox) { 'True' } else { 'False' }
        OneDriveProvisioned = if ($DriveExists) { 'True' } else { 'False' }
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
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row,
        [AllowNull()]$User,
        [AllowNull()]$Mailbox
    )

    $identity = Get-PlanRowIdentity -Row $Row
    $wave = Get-MigrationCsvValue -Row $Row -Name 'Wave' -Default ''
    $objectType = Get-MigrationCsvValue -Row $Row -Name 'ObjectType' -Default ''
    $results = [System.Collections.Generic.List[object]]::new()

    $newRow = {
        param([string]$Action, [string]$Status, [string]$Detail)
        New-CheckResult -Identity $identity -Action $Action -Status $Status -Detail $Detail `
            -Stage 'Post' -Wave $wave -ObjectType $objectType
    }

    if ($null -eq $User) {
        $results.Add((& $newRow 'UserExists' 'Failed' 'No destination user with this TargetObjectId.'))
        return $results.ToArray()
    }

    $wantedUpn = Get-MigrationCsvValue -Row $Row -Name 'TargetUserPrincipalName' -Default ''
    $actualUpn = [string](Get-PropertyValue -InputObject $User -Name 'userPrincipalName' -Default '')
    if (-not $wantedUpn) {
        $results.Add((& $newRow 'UpnMatchesPlan' 'Skipped' 'The plan has no TargetUserPrincipalName.'))
    }
    else {
        $match = $actualUpn -and ($actualUpn -eq $wantedUpn)
        $results.Add((& $newRow 'UpnMatchesPlan' $(if ($match) { 'Succeeded' } else { 'Failed' }) `
            $(if ($match) { $actualUpn } else { "Expected '$wantedUpn' but found '$actualUpn'." })))
    }

    $enabled = [bool](Get-PropertyValue -InputObject $User -Name 'accountEnabled' -Default $false)
    $results.Add((& $newRow 'AccountEnabled' $(if ($enabled) { 'Succeeded' } else { 'Failed' }) `
        $(if ($enabled) { 'Enabled.' } else { 'The account is disabled.' })))

    if ($null -eq $Mailbox) {
        $results.Add((& $newRow 'PrimarySmtpMatchesPlan' 'Failed' 'No mailbox to read addresses from.'))
        return $results.ToArray()
    }

    $wantedSmtp = Get-MigrationCsvValue -Row $Row -Name 'TargetPrimarySmtp' -Default ''
    $actualSmtp = [string](Get-PropertyValue -InputObject $Mailbox -Name 'PrimarySmtpAddress' -Default '')
    if (-not $wantedSmtp) {
        $results.Add((& $newRow 'PrimarySmtpMatchesPlan' 'Skipped' 'The plan has no TargetPrimarySmtp.'))
    }
    else {
        $match = $actualSmtp -and ($actualSmtp -eq $wantedSmtp)
        $results.Add((& $newRow 'PrimarySmtpMatchesPlan' $(if ($match) { 'Succeeded' } else { 'Failed' }) `
            $(if ($match) { $actualSmtp } else { "Expected '$wantedSmtp' but found '$actualSmtp'." })))
    }

    $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($proxy in @(Get-PropertyValue -InputObject $Mailbox -Name 'EmailAddresses' -Default @())) {
        [void]$present.Add(([string]$proxy).Trim())
    }
    $wantedAlias = @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'TargetAliases' -Default ''))
    $sourceX500 = Get-MigrationCsvValue -Row $Row -Name 'SourceX500' -Default ''
    if ($sourceX500) { $wantedAlias += $sourceX500 }

    if (@($wantedAlias).Count -eq 0) {
        $results.Add((& $newRow 'AliasesPresent' 'Skipped' 'The plan lists no target aliases.'))
    }
    else {
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($alias in $wantedAlias) {
            if (-not $present.Contains($alias.Trim())) { $missing.Add($alias.Trim()) }
        }
        $results.Add((& $newRow 'AliasesPresent' $(if ($missing.Count -eq 0) { 'Succeeded' } else { 'Failed' }) `
            $(if ($missing.Count -eq 0) { "All $(@($wantedAlias).Count) planned address(es) present." }
              else { "Missing: $(Join-MigrationList -Values $missing.ToArray())" })))
    }

    $hidden = [bool](Get-PropertyValue -InputObject $Mailbox -Name 'HiddenFromAddressListsEnabled' -Default $false)
    $results.Add((& $newRow 'VisibleInAddressList' $(if ($hidden) { 'Failed' } else { 'Succeeded' }) `
        $(if ($hidden) { 'Still hidden from address lists.' } else { 'Visible.' })))

    return $results.ToArray()
}

function Write-CheckTable {
    <#
    .SYNOPSIS
        Prints the pass/fail table that closes every run.

    .PARAMETER Result
        Every result row produced by the run.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Result
    )

    Write-MigrationLog -Message '--- Readiness checks ---' -Level SUCCESS
    if (@($Result).Count -eq 0) {
        Write-MigrationLog -Message '  (no checks ran)' -Level WARNING
        return
    }

    Write-MigrationLog -Message ('  {0,-24} {1,7} {2,7} {3,8}  {4}' -f
        'Check', 'Passed', 'Failed', 'Skipped', 'Verdict') -Level SUCCESS
    foreach ($group in (@($Result) | Group-Object -Property Action | Sort-Object -Property Name)) {
        $passed = @($group.Group | Where-Object { $_.Status -eq 'Succeeded' }).Count
        $failed = @($group.Group | Where-Object { $_.Status -eq 'Failed' }).Count
        $skipped = @($group.Group | Where-Object { $_.Status -eq 'Skipped' }).Count
        $verdict = if ($failed -gt 0) { 'FAIL' } elseif ($passed -gt 0) { 'PASS' } else { 'SKIPPED' }
        $level = if ($failed -gt 0) { 'ERROR' } elseif ($passed -gt 0) { 'SUCCESS' } else { 'WARNING' }
        Write-MigrationLog -Message ('  {0,-24} {1,7} {2,7} {3,8}  {4}' -f
            $group.Name, $passed, $failed, $skipped, $verdict) -Level $level
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
        throw ("No plan rows are in scope. Check -Wave against the Wave column in '$PlanPath'.")
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

    $null = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId
    $null = Connect-MigrationExchange -DelegatedOrganization $DelegatedOrganization

    if ($Stage -eq 'Pre') {
        # PlanClean - anything the planner could not resolve is a blocker, not a warning.
        $dirty = @($scopedRows | Where-Object {
            $dirtyPlanStatus -contains (Get-MigrationCsvValue -Row $_ -Name 'PlanStatus' -Default '')
        })
        foreach ($row in $dirty) {
            $planStatus = Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default ''
            $planDetail = Get-MigrationCsvValue -Row $row -Name 'PlanDetail' -Default 'no detail recorded'
            $results.Add((New-CheckResult -Identity (Get-PlanRowIdentity -Row $row) -Action 'PlanClean' -Status 'Failed' `
                -Detail "PlanStatus is '$planStatus': $planDetail" `
                -Stage $Stage -Wave (Get-MigrationCsvValue -Row $row -Name 'Wave' -Default '') `
                -ObjectType (Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default '')))
        }
        if ($dirty.Count -eq 0) {
            $results.Add((New-CheckResult -Identity 'PlanClean' -Action 'PlanClean' -Status 'Succeeded' `
                -Detail "No NeedsReview, Invalid or Collision rows in $($scopedRows.Count) row(s)." -Stage $Stage))
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
            $results.Add((New-CheckResult -Identity $domain -Action 'DomainVerified' `
                -Status $(if ($isVerified) { 'Succeeded' } else { 'Failed' }) `
                -Detail $(if ($isVerified) { 'Verified in the destination tenant.' }
                    else { 'Not a verified domain in the destination tenant.' }) -Stage $Stage))
        }
        if ($plannedDomain.Count -eq 0) {
            $results.Add((New-CheckResult -Identity 'DomainVerified' -Action 'DomainVerified' -Status 'Skipped' `
                -Detail 'The plan names no target or interim addresses.' -Stage $Stage))
        }

        # SkuSeats - the seat arithmetic the tenant will enforce, run before anyone waits on it.
        $catalog = @(Get-MigrationSkuCatalog)
        $seat = @(Measure-SeatRequirement -Row $scopedRows -Catalog $catalog)
        foreach ($sku in $seat) {
            $status = if ($sku.Status -eq 'Sufficient') { 'Succeeded' } else { 'Failed' }
            $detail = switch ($sku.Status) {
                'Unknown' { "The destination tenant has no subscription with part number '$($sku.SkuPartNumber)'." }
                'Shortfall' { "Needs $($sku.Needed), $($sku.Available) available - short by $($sku.Shortfall)." }
                default { "Needs $($sku.Needed) of $($sku.Available) available." }
            }
            $results.Add((New-CheckResult -Identity $sku.SkuPartNumber -Action 'SkuSeats' -Status $status `
                -Detail $detail -Stage $Stage))
        }
        if ($seat.Count -eq 0) {
            $results.Add((New-CheckResult -Identity 'SkuSeats' -Action 'SkuSeats' -Status 'Skipped' `
                -Detail 'No plan row asks for a licence.' -Stage $Stage))
        }

        # UsageLocation - assignLicense fails outright without one.
        $licensed = @($scopedRows | Where-Object { (Get-MigrationCsvValue -Row $_ -Name 'TargetLicenses' -Default '') })
        $noLocation = @($licensed | Where-Object { -not (Get-MigrationCsvValue -Row $_ -Name 'UsageLocation' -Default '') })
        foreach ($row in $noLocation) {
            $results.Add((New-CheckResult -Identity (Get-PlanRowIdentity -Row $row) -Action 'UsageLocation' -Status 'Failed' `
                -Detail 'Row is licensed but has no UsageLocation; assignLicense will fail unless a default is supplied.' `
                -Stage $Stage -Wave (Get-MigrationCsvValue -Row $row -Name 'Wave' -Default '') `
                -ObjectType (Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default '')))
        }
        if ($noLocation.Count -eq 0) {
            $results.Add((New-CheckResult -Identity 'UsageLocation' -Action 'UsageLocation' -Status 'Succeeded' `
                -Detail "All $($licensed.Count) licensed row(s) carry a usage location." -Stage $Stage))
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
            $results.Add((New-CheckResult -Identity 'AddressClash' -Action 'AddressClash' -Status 'Succeeded' `
                -Detail 'No planned UPN, address or mail nickname is already taken.' -Stage $Stage))
        }

        # SyncedSource - a directory-synced source object cannot have its addresses edited in EXO.
        $synced = @($scopedRows | Where-Object { (Get-MigrationCsvValue -Row $_ -Name 'IsSynced' -Default '') -match '(?i)^true$' })
        foreach ($row in $synced) {
            $results.Add((New-CheckResult -Identity (Get-PlanRowIdentity -Row $row) -Action 'SyncedSource' -Status 'Skipped' `
                -Detail ('Source object is directory-synced; addresses must be edited on-premises and ' +
                    'synced, not in Exchange Online.') `
                -Stage $Stage -Wave (Get-MigrationCsvValue -Row $row -Name 'Wave' -Default '') `
                -ObjectType (Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default '')))
        }
        if ($synced.Count -gt 0) {
            Write-MigrationLog -Message "$($synced.Count) plan row(s) are directory-synced at the source." -Level WARNING
        }
        else {
            $results.Add((New-CheckResult -Identity 'SyncedSource' -Action 'SyncedSource' -Status 'Succeeded' `
                -Detail 'No directory-synced source objects in scope.' -Stage $Stage))
        }
    }
    else {
        $provisionedRows = @($scopedRows | Where-Object { (Get-MigrationCsvValue -Row $_ -Name 'TargetObjectId' -Default '') })
        foreach ($row in @($scopedRows | Where-Object { -not (Get-MigrationCsvValue -Row $_ -Name 'TargetObjectId' -Default '') })) {
            $results.Add((New-CheckResult -Identity (Get-PlanRowIdentity -Row $row) -Action 'UserExists' -Status 'Skipped' `
                -Detail 'No TargetObjectId yet; the row has not been provisioned.' -Stage $Stage `
                -Wave (Get-MigrationCsvValue -Row $row -Name 'Wave' -Default '') `
                -ObjectType (Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default '')))
        }

        $changed = $false
        foreach ($row in $provisionedRows) {
            $objectId = Get-MigrationCsvValue -Row $row -Name 'TargetObjectId' -Default ''

            $user = $null
            try {
                $user = Invoke-MigrationGraphRequest -Method GET `
                    -Uri "/v1.0/users/$objectId`?`$select=id,userPrincipalName,displayName,accountEnabled,usageLocation"
            }
            catch {
                if (-not (Test-GraphNotFound -ErrorRecord $_)) { throw }
            }

            $mailbox = $null
            try {
                $mailbox = Get-EXOMailbox -Identity $objectId -ErrorAction Stop -PropertySets Minimum -Properties @(
                    'LitigationHoldEnabled', 'ArchiveStatus', 'ArchiveGuid', 'ProhibitSendReceiveQuota',
                    'HiddenFromAddressListsEnabled', 'EmailAddresses', 'PrimarySmtpAddress'
                )
            }
            catch {
                Write-MigrationLog -Message "No mailbox for $objectId - $($_.Exception.Message)" -Level DEBUG
            }

            if ($Stage -eq 'Post') {
                foreach ($resultRow in @(Test-PostRow -Row $row -User $user -Mailbox $mailbox)) { $results.Add($resultRow) }
                continue
            }

            # Application permissions never auto-provision OneDrive, so a 404 here is a real finding.
            $driveExists = $false
            try {
                $drive = Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/users/$objectId/drive"
                $driveExists = $null -ne $drive
            }
            catch {
                if (-not (Test-GraphNotFound -ErrorRecord $_)) { throw }
            }

            $sourceMailbox = $null
            $sourceAddress = ([string](Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default '')).ToLowerInvariant()
            if ($sourceAddress -and $sourceMailboxByAddress.ContainsKey($sourceAddress)) {
                $sourceMailbox = $sourceMailboxByAddress[$sourceAddress]
            }

            $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox `
                -DriveExists:$driveExists -SourceMailbox $sourceMailbox
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
    try {
        $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Test-MigrationReadiness'
    }
    catch {
        Write-MigrationLog -Message "Could not write the results file: $($_.Exception.Message)" -Level ERROR
        $exitCode = 1
    }
}

if ($exitCode -eq 0 -and @($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) {
    $exitCode = 2
}

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion Cleanup
