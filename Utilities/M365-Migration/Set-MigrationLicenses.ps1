#Requires -Version 7.4

<#
.SYNOPSIS
    Assigns the licences an identity plan calls for to the matching users in the destination tenant.

.DESCRIPTION
    Phase 3 of the migration toolkit. Every plan row carries a TargetLicenses list of SKU part
    numbers; this script turns that list into Microsoft Graph assignLicense calls against the
    destination tenant, one call per user.

    Four things have to happen in a fixed order or Microsoft 365 rejects the work, so the script
    enforces that order rather than leaving it to the operator:

      1. usageLocation first. assignLicense fails outright when a user has no usage location, and
         the failure surfaces in the admin center as a vague "invalid usage location" issue rather
         than at the point of assignment. The script PATCHes usageLocation (plan value, else
         -DefaultUsageLocation) before it ever posts a licence change.
      2. Group-assigned SKUs are refused. licenseAssignmentStates tells you which SKUs arrived
         through group-based licensing (assignedByGroup is non-null). assignLicense cannot remove
         those - the user has to leave the group instead - and re-adding one directly quietly
         doubles up the assignment. Both directions are skipped and reported.
      3. Seats are counted before anything is assigned. The script totals the new assignments per
         SKU, compares them with the seats the tenant actually has spare, prints a table, and stops
         before the first write unless -Force says to press on and let individual rows fail.
      4. Only then does the per-row loop run.

    -DryRun performs every read, every calculation and the whole seat pre-check, then writes a
    results file whose rows are Status 'Planned' and changes nothing. -WhatIf is honoured at the
    row level as well.

.PARAMETER PlanPath
    Path to IdentityPlan.csv. Only ObjectType 'User' rows are considered; rows whose PlanStatus is
    not Planned, ManualOverride or UpnSmtpDiverge are reported as Skipped.

.PARAMETER Wave
    One or more wave labels to process. Omit to process every wave in the plan.

.PARAMETER SkuMapPath
    Optional SkuMap.csv. When supplied the desired SKUs are recomputed from SourceLicenses through
    the map instead of being read from TargetLicenses, which lets an operator correct the mapping
    after the plan was generated without regenerating the plan. Source SKUs the map does not mention
    are carried through unchanged and named in the row Detail.

.PARAMETER RemoveUnplanned
    Also remove directly assigned SKUs that the plan does not ask for. Group-inherited SKUs are
    never removed - they are reported instead.

.PARAMETER DefaultUsageLocation
    Two-letter ISO country code used when a plan row has no UsageLocation and the destination user
    has none either. Without it, such rows fail rather than guess.

.PARAMETER IncludeCollisions
    Also process rows whose PlanStatus is 'Collision'. Off by default, because a collision means the
    planned address is not safe to use yet.

.PARAMETER Force
    Continue past the seat pre-check when the tenant does not have enough spare seats. Individual
    rows will then fail as Microsoft 365 runs out of licences, which is sometimes the intent when
    seats are being purchased in parallel.

.PARAMETER TenantId
    Destination tenant id or domain for Connect-MgGraph. Supported under GDAP.

.PARAMETER OutputPath
    Overrides the output root (default %LOCALAPPDATA%\Migration-Automations, ~/Migration-Automations
    off Windows).

.PARAMETER Prefix
    Names the client or run. Output lands in <root>\<Prefix>\ and filenames start with '<Prefix>_'.

.PARAMETER LogPath
    Overrides the derived log file path.

.PARAMETER DryRun
    Read, calculate and report without assigning anything. Results are written with Status 'Planned'.

.PARAMETER Verbosity
    Console detail: Low (errors and successes), Medium (default, adds warnings) or High (everything).
    The log file always receives every line.

.EXAMPLE
    .\Set-MigrationLicenses.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -DryRun -Prefix Fabrikam

    Reads wave 1, resolves every licence change, prints the seat table and writes
    Fabrikam_Set-MigrationLicenses-DryRun_<timestamp>.csv without touching the tenant.

.EXAMPLE
    .\Set-MigrationLicenses.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -DefaultUsageLocation US

    Assigns wave 1's licences, defaulting anyone with no usage location in the plan to the US.

.EXAMPLE
    .\Set-MigrationLicenses.ps1 -PlanPath .\IdentityPlan.csv -SkuMapPath .\SkuMap.csv -RemoveUnplanned

    Recomputes the target SKUs from SourceLicenses through a corrected SKU map and strips any
    directly assigned licence the map does not produce.

.EXAMPLE
    .\Set-MigrationLicenses.ps1 -PlanPath .\IdentityPlan.csv -Wave 2 -TenantId newco.onmicrosoft.com -WhatIf

    Shows the per-user Graph calls that would run against a GDAP-delegated destination tenant.

.NOTES
    Author: AutomationHub
    Written with assistance from Claude (Anthropic).

    Required Microsoft Graph scopes:
      User.ReadWrite.All      - PATCH usageLocation and POST assignLicense
      Organization.Read.All   - read subscribedSkus for the seat pre-check
      Directory.Read.All      - read licenseAssignmentStates

    Exchange Online is not used by this script, so no EXO role is required.

    GDAP: supported. Pass -TenantId <customer domain or id>; Connect-MgGraph honours an active
    GDAP relationship and scopes the session to the roles that relationship granted.

    Exit codes: 0 success, 1 fatal (connection, plan or seat pre-check), 2 completed with row
    failures.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [AllowNull()][AllowEmptyCollection()]
    [string[]]$Wave,

    [AllowNull()][AllowEmptyString()]
    [string]$SkuMapPath,

    [switch]$RemoveUnplanned,

    [ValidatePattern('^([A-Za-z]{2})?$')]
    [string]$DefaultUsageLocation,

    [switch]$IncludeCollisions,

    [switch]$Force,

    [AllowNull()][AllowEmptyString()]
    [string]$TenantId,

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

# Declared here rather than inline so a reviewer can see the blast radius of the script in one place.
$requiredGraphScopes = @(
    'User.ReadWrite.All'
    'Organization.Read.All'
    'Directory.Read.All'
)

# Writers act only on rows the planner marked safe. Collision rows are opt-in because the planned
# address is, by definition, still contested.
$eligiblePlanStatus = @('Planned', 'ManualOverride', 'UpnSmtpDiverge')
if ($IncludeCollisions) { $eligiblePlanStatus += 'Collision' }

# Graph rejects very long $filter strings, so identifiers are looked up in chunks rather than one
# request per plan row.
$userLookupBatchSize = 15

#endregion Configuration

#region Functions

function Get-PropertyValue {
    <#
    .SYNOPSIS
        Reads a property from an arbitrary object without tripping Set-StrictMode.

    .DESCRIPTION
        Graph responses omit properties that have no value, and strict mode makes a blind read of a
        missing property fatal. Get-MigrationCsvValue solves the same problem for plan rows but
        stringifies its result, which destroys arrays such as licenseAssignmentStates - so complex
        Graph values are read through this instead.

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

function Get-DesiredSku {
    <#
    .SYNOPSIS
        Works out which SKU part numbers a plan row should end up with.

    .DESCRIPTION
        Without a SKU map the answer is simply the plan's TargetLicenses column. With one, the
        answer is recomputed from SourceLicenses so that a mapping corrected after planning takes
        effect without regenerating the plan. A source SKU the map does not mention is carried
        through unchanged and reported, because silently dropping a licence is worse than assigning
        one the operator can revoke.

    .PARAMETER Row
        The identity plan row.

    .PARAMETER SkuMap
        Hashtable from Resolve-MigrationSkuMap, or $null to use TargetLicenses as written.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row,
        [AllowNull()][hashtable]$SkuMap
    )

    if (-not $SkuMap) {
        return [pscustomobject]@{
            Sku      = @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'TargetLicenses' -Default ''))
            Unmapped = @()
        }
    }

    $sourceSku = @(Split-MigrationList -Value (Get-MigrationCsvValue -Row $Row -Name 'SourceLicenses' -Default ''))
    $resolved = [System.Collections.Generic.List[string]]::new()
    $unmapped = [System.Collections.Generic.List[string]]::new()

    foreach ($sku in $sourceSku) {
        if ($SkuMap.ContainsKey($sku)) {
            foreach ($target in @($SkuMap[$sku])) {
                if (-not $resolved.Contains($target)) { $resolved.Add($target) }
            }
            continue
        }
        $unmapped.Add($sku)
        if (-not $resolved.Contains($sku)) { $resolved.Add($sku) }
    }

    return [pscustomobject]@{
        Sku      = $resolved.ToArray()
        Unmapped = $unmapped.ToArray()
    }
}

function Resolve-LicenseChange {
    <#
    .SYNOPSIS
        Turns a desired SKU list plus the user's current assignment states into add/remove sets.

    .DESCRIPTION
        The whole point of this function is that it touches nothing. It takes plain objects, so the
        rules that matter - group-inherited licences are neither added nor removed, unknown part
        numbers never reach Graph, already-assigned SKUs are not re-sent - are all testable offline.

        A SKU can appear twice in licenseAssignmentStates, once direct and once via a group. Direct
        wins for the "already assigned" decision; the group entry still blocks removal.

    .PARAMETER DesiredSkuPartNumber
        The part numbers the plan wants the user to hold.

    .PARAMETER Catalog
        Output of Get-MigrationSkuCatalog (needs SkuId, SkuPartNumber, Available).

    .PARAMETER AssignmentState
        The user's licenseAssignmentStates array from Graph.

    .PARAMETER RemoveUnplanned
        Also compute removals for directly assigned SKUs the plan does not ask for.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$DesiredSkuPartNumber,
        [AllowNull()][AllowEmptyCollection()][object[]]$Catalog,
        [AllowNull()][AllowEmptyCollection()][object[]]$AssignmentState,
        [switch]$RemoveUnplanned
    )

    $idByPart = @{}
    $partById = @{}
    foreach ($sku in @($Catalog)) {
        $part = [string](Get-PropertyValue -InputObject $sku -Name 'SkuPartNumber' -Default '')
        $id = [string](Get-PropertyValue -InputObject $sku -Name 'SkuId' -Default '')
        if ($part -and $id) {
            $idByPart[$part] = $id
            $partById[$id] = $part
        }
    }

    $directId = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $groupId = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($state in @($AssignmentState)) {
        $skuId = [string](Get-PropertyValue -InputObject $state -Name 'skuId' -Default '')
        if (-not $skuId) { continue }
        $byGroup = [string](Get-PropertyValue -InputObject $state -Name 'assignedByGroup' -Default '')
        if ([string]::IsNullOrWhiteSpace($byGroup)) { [void]$directId.Add($skuId) }
        else { [void]$groupId.Add($skuId) }
    }

    $addId = [System.Collections.Generic.List[string]]::new()
    $addPart = [System.Collections.Generic.List[string]]::new()
    $alreadyPart = [System.Collections.Generic.List[string]]::new()
    $groupPart = [System.Collections.Generic.List[string]]::new()
    $unknownPart = [System.Collections.Generic.List[string]]::new()
    $desiredId = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($part in @($DesiredSkuPartNumber)) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        if (-not $idByPart.ContainsKey($part)) {
            if (-not $unknownPart.Contains($part)) { $unknownPart.Add($part) }
            continue
        }

        $skuId = $idByPart[$part]
        [void]$desiredId.Add($skuId)

        if ($directId.Contains($skuId)) {
            if (-not $alreadyPart.Contains($part)) { $alreadyPart.Add($part) }
            continue
        }
        if ($groupId.Contains($skuId)) {
            # Adding it directly on top of the group assignment double-books a seat.
            if (-not $groupPart.Contains($part)) { $groupPart.Add($part) }
            continue
        }
        if (-not $addId.Contains($skuId)) {
            $addId.Add($skuId)
            $addPart.Add($part)
        }
    }

    $removeId = [System.Collections.Generic.List[string]]::new()
    $removePart = [System.Collections.Generic.List[string]]::new()

    if ($RemoveUnplanned) {
        foreach ($skuId in $directId) {
            if ($desiredId.Contains($skuId)) { continue }
            $removeId.Add($skuId)
            $part = if ($partById.ContainsKey($skuId)) { $partById[$skuId] } else { $skuId }
            $removePart.Add($part)
        }
        foreach ($skuId in $groupId) {
            if ($desiredId.Contains($skuId)) { continue }
            # assignLicense cannot take back what a group handed out; say so instead of failing.
            $part = if ($partById.ContainsKey($skuId)) { $partById[$skuId] } else { $skuId }
            if (-not $groupPart.Contains($part)) { $groupPart.Add($part) }
        }
    }

    return [pscustomobject]@{
        AddSkuId          = $addId.ToArray()
        AddSkuPartNumber  = $addPart.ToArray()
        RemoveSkuId       = $removeId.ToArray()
        RemoveSkuPartNumber = $removePart.ToArray()
        AlreadyAssigned   = $alreadyPart.ToArray()
        GroupAssigned     = $groupPart.ToArray()
        UnknownSku        = $unknownPart.ToArray()
    }
}

function Measure-LicenseSeat {
    <#
    .SYNOPSIS
        Totals the seats the run will consume per SKU and compares them with what the tenant has.

    .DESCRIPTION
        Only new assignments consume a seat, so the arithmetic runs over the resolved add sets
        rather than over the plan's TargetLicenses - a user who already holds the SKU costs nothing.
        Unknown part numbers are reported with a Status of 'Unknown' so the operator sees a bad SKU
        map before the first assignment rather than as a wall of per-row failures.

    .PARAMETER Change
        The Resolve-LicenseChange results for every row that will be processed.

    .PARAMETER Catalog
        Output of Get-MigrationSkuCatalog.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Change,
        [AllowNull()][AllowEmptyCollection()][object[]]$Catalog
    )

    $needed = [ordered]@{}
    foreach ($item in @($Change)) {
        foreach ($part in @(Get-PropertyValue -InputObject $item -Name 'AddSkuPartNumber' -Default @())) {
            if (-not $needed.Contains($part)) { $needed[$part] = 0 }
            $needed[$part] = [int]$needed[$part] + 1
        }
        foreach ($part in @(Get-PropertyValue -InputObject $item -Name 'UnknownSku' -Default @())) {
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
                SkuPartNumber = $part
                SkuId         = ''
                Needed        = $count
                Available     = 0
                Shortfall     = $count
                Status        = 'Unknown'
            })
            continue
        }

        $sku = $catalogByPart[$part]
        $available = [int](Get-PropertyValue -InputObject $sku -Name 'Available' -Default 0)
        $shortfall = [Math]::Max(0, $count - $available)
        $rows.Add([pscustomobject]@{
            SkuPartNumber = $part
            SkuId         = [string](Get-PropertyValue -InputObject $sku -Name 'SkuId' -Default '')
            Needed        = $count
            Available     = $available
            Shortfall     = $shortfall
            Status        = if ($shortfall -gt 0) { 'Shortfall' } else { 'Sufficient' }
        })
    }

    return $rows.ToArray()
}

function Write-SeatTable {
    <#
    .SYNOPSIS
        Prints the seat pre-check as a fixed-width table through the toolkit logger.

    .PARAMETER Seat
        Rows from Measure-LicenseSeat.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Seat
    )

    Write-MigrationLog -Message '--- Licence seat pre-check ---' -Level SUCCESS
    if (@($Seat).Count -eq 0) {
        Write-MigrationLog -Message '  (no new assignments required)' -Level SUCCESS
        return
    }

    Write-MigrationLog -Message ('  {0,-28} {1,7} {2,9} {3,9}  {4}' -f
        'SkuPartNumber', 'Needed', 'Available', 'Shortfall', 'Status') -Level SUCCESS
    foreach ($row in @($Seat) | Sort-Object -Property SkuPartNumber) {
        $level = switch ($row.Status) {
            'Sufficient' { 'SUCCESS' }
            default      { 'ERROR' }
        }
        Write-MigrationLog -Message ('  {0,-28} {1,7} {2,9} {3,9}  {4}' -f
            $row.SkuPartNumber, $row.Needed, $row.Available, $row.Shortfall, $row.Status) -Level $level
    }
}

function Get-DestinationUserMap {
    <#
    .SYNOPSIS
        Reads the destination users a plan refers to, in batches rather than one call per row.

    .DESCRIPTION
        A wave of several hundred rows becomes a handful of Graph calls: the identifiers are turned
        into OData equality clauses and sent -BatchSize at a time. Results are indexed both by object
        id and by lower-cased UPN so callers can match a row however the plan identifies it.

    .PARAMETER UserPrincipalName
        UPNs to look up.

    .PARAMETER ObjectId
        Directory object ids to look up.

    .PARAMETER BatchSize
        Equality clauses per request. Graph tolerates far more, but short filters keep the URL well
        inside proxy limits and make a failure easy to attribute.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$UserPrincipalName,
        [AllowNull()][AllowEmptyCollection()][string[]]$ObjectId,
        [ValidateRange(1, 20)][int]$BatchSize = 15
    )

    $clause = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($id in @($ObjectId)) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $text = "id eq '$(ConvertTo-MigrationODataString -Value $id)'"
        if ($seen.Add($text)) { $clause.Add($text) }
    }
    foreach ($upn in @($UserPrincipalName)) {
        if ([string]::IsNullOrWhiteSpace($upn)) { continue }
        $text = "userPrincipalName eq '$(ConvertTo-MigrationODataString -Value $upn)'"
        if ($seen.Add($text)) { $clause.Add($text) }
    }

    $byId = @{}
    $byUpn = @{}
    if ($clause.Count -eq 0) { return @{ ById = $byId; ByUpn = $byUpn } }

    $select = 'id,userPrincipalName,displayName,accountEnabled,usageLocation,licenseAssignmentStates'
    for ($offset = 0; $offset -lt $clause.Count; $offset += $BatchSize) {
        $take = [Math]::Min($BatchSize, $clause.Count - $offset)
        $filter = [uri]::EscapeDataString(($clause.GetRange($offset, $take) -join ' or '))
        $uri = "/v1.0/users?`$select=$select&`$filter=$filter&`$top=999"

        try {
            $found = @(Invoke-MigrationGraphRequest -Method GET -Uri $uri -All)
        }
        catch {
            throw "Could not read destination users from Graph: $($_.Exception.Message)"
        }

        foreach ($user in $found) {
            $id = [string](Get-PropertyValue -InputObject $user -Name 'id' -Default '')
            if ($id) { $byId[$id] = $user }
            $upn = [string](Get-PropertyValue -InputObject $user -Name 'userPrincipalName' -Default '')
            if ($upn) { $byUpn[$upn.ToLowerInvariant()] = $user }
        }
    }

    $callCount = [Math]::Ceiling($clause.Count / $BatchSize)
    Write-MigrationLog -Message "Resolved $($byId.Count) destination user(s) in $callCount Graph call(s)." -Level INFO
    return @{ ById = $byId; ByUpn = $byUpn }
}

function Set-PlanRowLicense {
    <#
    .SYNOPSIS
        Applies one plan row's licence change and returns the result row for the CSV.

    .DESCRIPTION
        The whole per-row decision lives here so it can be exercised offline with a fake user
        object and a mocked Invoke-MigrationGraphRequest. usageLocation is PATCHed before the
        assignLicense POST, unconditionally and in that order, because Microsoft 365 rejects the
        assignment otherwise.

    .PARAMETER Row
        The identity plan row.

    .PARAMETER User
        The Graph user object from Get-DestinationUserMap, or $null when the user was not found.

    .PARAMETER Catalog
        Output of Get-MigrationSkuCatalog.

    .PARAMETER SkuMap
        Optional hashtable from Resolve-MigrationSkuMap.

    .PARAMETER DefaultUsageLocation
        Fallback two-letter country code.

    .PARAMETER RemoveUnplanned
        Remove directly assigned SKUs the plan does not ask for.

    .PARAMETER DryRun
        Report the change as 'Planned' instead of performing it. Invoke-MigrationAction independently
        suppresses the mutation from the run context; this switch only chooses the reported Status.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Row,
        [AllowNull()]$User,
        [AllowNull()][AllowEmptyCollection()][object[]]$Catalog,
        [AllowNull()][hashtable]$SkuMap,
        [AllowNull()][AllowEmptyString()][string]$DefaultUsageLocation,
        [switch]$RemoveUnplanned,
        [switch]$DryRun
    )

    $identity = Get-MigrationCsvValue -Row $Row -Name 'TargetUserPrincipalName' -Default ''
    if (-not $identity) { $identity = Get-MigrationCsvValue -Row $Row -Name 'InterimUserPrincipalName' -Default '' }
    if (-not $identity) { $identity = Get-MigrationCsvValue -Row $Row -Name 'SourceUserPrincipalName' -Default '(unknown)' }

    $result = [pscustomobject]@{
        Identity       = $identity
        Action         = 'AssignLicense'
        Status         = 'Failed'
        Detail         = ''
        TargetObjectId = ''
        UsageLocation  = ''
        Added          = ''
        Removed        = ''
        GroupAssigned  = ''
        Unknown        = ''
    }

    if ($null -eq $User) {
        $result.Status = 'Failed'
        $result.Detail = 'No destination user matched this row - run New-MigrationUsers first.'
        return $result
    }

    $userId = [string](Get-PropertyValue -InputObject $User -Name 'id' -Default '')
    $result.TargetObjectId = $userId

    $desired = Get-DesiredSku -Row $Row -SkuMap $SkuMap
    $change = Resolve-LicenseChange -DesiredSkuPartNumber $desired.Sku -Catalog $Catalog `
        -AssignmentState @(Get-PropertyValue -InputObject $User -Name 'licenseAssignmentStates' -Default @()) `
        -RemoveUnplanned:$RemoveUnplanned

    $result.Added = Join-MigrationList -Values $change.AddSkuPartNumber
    $result.Removed = Join-MigrationList -Values $change.RemoveSkuPartNumber
    $result.GroupAssigned = Join-MigrationList -Values $change.GroupAssigned
    $result.Unknown = Join-MigrationList -Values $change.UnknownSku

    $note = [System.Collections.Generic.List[string]]::new()
    if (@($desired.Unmapped).Count -gt 0) {
        $note.Add("source SKU not in map, carried through: $(Join-MigrationList -Values $desired.Unmapped)")
    }
    if (@($change.UnknownSku).Count -gt 0) {
        $note.Add("not a SKU in this tenant: $(Join-MigrationList -Values $change.UnknownSku)")
    }
    if (@($change.GroupAssigned).Count -gt 0) {
        $note.Add("group-assigned, left alone: $(Join-MigrationList -Values $change.GroupAssigned)")
    }
    if (@($change.AlreadyAssigned).Count -gt 0) {
        $note.Add("already assigned: $(Join-MigrationList -Values $change.AlreadyAssigned)")
    }

    # usageLocation has to be in place before assignLicense, so it is resolved before anything is sent.
    $currentLocation = [string](Get-PropertyValue -InputObject $User -Name 'usageLocation' -Default '')
    $plannedLocation = Get-MigrationCsvValue -Row $Row -Name 'UsageLocation' -Default ''
    $wantedLocation = if ($plannedLocation) { $plannedLocation } elseif ($DefaultUsageLocation) { $DefaultUsageLocation } else { '' }
    $locationToSet = ''
    if (-not $currentLocation -or ($wantedLocation -and $wantedLocation -ne $currentLocation)) {
        $locationToSet = $wantedLocation
    }
    $result.UsageLocation = if ($locationToSet) { $locationToSet } else { $currentLocation }

    $needsAssign = (@($change.AddSkuId).Count -gt 0) -or (@($change.RemoveSkuId).Count -gt 0)

    if (-not $currentLocation -and -not $locationToSet -and $needsAssign) {
        $result.Status = 'Failed'
        $result.Detail = 'No usage location on the user or in the plan; supply -DefaultUsageLocation.'
        return $result
    }

    if (-not $needsAssign -and -not $locationToSet) {
        $result.Status = 'Skipped'
        $result.Detail = if ($note.Count -gt 0) { "Nothing to do - $($note -join '; ')" }
            else { 'Nothing to do - licences already match the plan.' }
        return $result
    }

    try {
        if ($locationToSet) {
            $description = "Set usageLocation '$locationToSet' on $identity"
            if ($PSCmdlet.ShouldProcess($identity, "Set usageLocation to '$locationToSet'")) {
                $locationBody = @{ usageLocation = $locationToSet }
                Invoke-MigrationAction -Description $description -Action {
                    $null = Invoke-MigrationGraphRequest -Method PATCH -Uri "/v1.0/users/$userId" -Body $locationBody
                }
            }
        }

        if ($needsAssign) {
            $addPayload = @(foreach ($skuId in @($change.AddSkuId)) { @{ skuId = $skuId; disabledPlans = @() } })
            $assignBody = @{
                addLicenses    = @($addPayload)
                removeLicenses = @($change.RemoveSkuId)
            }
            $addText = Join-MigrationList -Values $change.AddSkuPartNumber
            $removeText = Join-MigrationList -Values $change.RemoveSkuPartNumber
            $summary = "add [$addText] remove [$removeText]"
            if ($PSCmdlet.ShouldProcess($identity, "Assign licences: $summary")) {
                Invoke-MigrationAction -Description "Assign licences for $identity ($summary)" -Action {
                    $null = Invoke-MigrationGraphRequest -Method POST -Uri "/v1.0/users/$userId/assignLicense" -Body $assignBody
                }
            }
        }
    }
    catch {
        $result.Status = 'Failed'
        $result.Detail = $_.Exception.Message
        return $result
    }

    $result.Status = if ($DryRun) { 'Planned' } else { 'Succeeded' }
    $summaryParts = [System.Collections.Generic.List[string]]::new()
    if ($locationToSet) { $summaryParts.Add("usageLocation=$locationToSet") }
    if (@($change.AddSkuPartNumber).Count -gt 0) { $summaryParts.Add("added $(Join-MigrationList -Values $change.AddSkuPartNumber)") }
    if (@($change.RemoveSkuPartNumber).Count -gt 0) {
        $summaryParts.Add("removed $(Join-MigrationList -Values $change.RemoveSkuPartNumber)")
    }
    foreach ($item in $note) { $summaryParts.Add($item) }
    $result.Detail = ($summaryParts -join '; ')
    return $result
}

#endregion Functions

#region Main

$exitCode = 0
$results = [System.Collections.Generic.List[object]]::new()

$null = Initialize-MigrationRun -ScriptName 'Set-MigrationLicenses' -OutputPath $OutputPath -Prefix $Prefix `
    -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    # Only User rows can hold a licence; anything else is filtered out at the source rather than
    # padding the results file with hundreds of irrelevant Skipped rows.
    $planRows = @(Import-MigrationPlan -Path $PlanPath -Wave $Wave -ObjectType 'User')

    $skuMap = $null
    if ($SkuMapPath) {
        $skuMap = Resolve-MigrationSkuMap -Path $SkuMapPath
        Write-MigrationLog -Message 'Target SKUs will be recomputed from SourceLicenses through the supplied map.' -Level WARNING
    }

    $eligible = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $planRows) {
        $status = Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default ''
        $identity = Get-MigrationCsvValue -Row $row -Name 'TargetUserPrincipalName' -Default ''
        if (-not $identity) { $identity = Get-MigrationCsvValue -Row $row -Name 'InterimUserPrincipalName' -Default '' }
        if (-not $identity) { $identity = Get-MigrationCsvValue -Row $row -Name 'SourceUserPrincipalName' -Default '(unknown)' }

        if ($eligiblePlanStatus -notcontains $status) {
            $results.Add([pscustomobject]@{
                Identity       = $identity
                Action         = 'AssignLicense'
                Status         = 'Skipped'
                Detail         = "PlanStatus is '$status'."
                TargetObjectId = Get-MigrationCsvValue -Row $row -Name 'TargetObjectId' -Default ''
                UsageLocation  = ''
                Added          = ''
                Removed        = ''
                GroupAssigned  = ''
                Unknown        = ''
            })
            continue
        }
        $eligible.Add($row)
    }

    Write-MigrationLog -Message "$($eligible.Count) of $($planRows.Count) plan row(s) are eligible for licensing." -Level INFO

    if ($eligible.Count -eq 0) {
        # Nothing to sign in for: no eligible row means no Graph call is worth an interactive prompt.
        Write-MigrationLog -Message 'No eligible plan rows; skipping the tenant connection entirely.' -Level WARNING
    }
    else {
        $null = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId
        $catalog = @(Get-MigrationSkuCatalog)

        $upnList = [System.Collections.Generic.List[string]]::new()
        $idList = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $eligible) {
            $objectId = Get-MigrationCsvValue -Row $row -Name 'TargetObjectId' -Default ''
            if ($objectId) { $idList.Add($objectId); continue }
            $upn = Get-MigrationCsvValue -Row $row -Name 'TargetUserPrincipalName' -Default ''
            if (-not $upn) { $upn = Get-MigrationCsvValue -Row $row -Name 'InterimUserPrincipalName' -Default '' }
            if ($upn) { $upnList.Add($upn) }
        }

        $userMap = Get-DestinationUserMap -UserPrincipalName $upnList.ToArray() -ObjectId $idList.ToArray() `
            -BatchSize $userLookupBatchSize

        # Pair every eligible row with its user once, so the seat pre-check and the apply loop agree.
        $work = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $eligible) {
            $objectId = Get-MigrationCsvValue -Row $row -Name 'TargetObjectId' -Default ''
            $upn = Get-MigrationCsvValue -Row $row -Name 'TargetUserPrincipalName' -Default ''
            if (-not $upn) { $upn = Get-MigrationCsvValue -Row $row -Name 'InterimUserPrincipalName' -Default '' }

            $user = $null
            if ($objectId -and $userMap.ById.ContainsKey($objectId)) { $user = $userMap.ById[$objectId] }
            elseif ($upn -and $userMap.ByUpn.ContainsKey($upn.ToLowerInvariant())) { $user = $userMap.ByUpn[$upn.ToLowerInvariant()] }

            $change = $null
            if ($null -ne $user) {
                $desired = Get-DesiredSku -Row $row -SkuMap $skuMap
                $change = Resolve-LicenseChange -DesiredSkuPartNumber $desired.Sku -Catalog $catalog `
                    -AssignmentState @(Get-PropertyValue -InputObject $user -Name 'licenseAssignmentStates' -Default @()) `
                    -RemoveUnplanned:$RemoveUnplanned
            }
            $work.Add([pscustomobject]@{ Row = $row; User = $user; Change = $change })
        }

        $seat = @(Measure-LicenseSeat -Change @($work.Where({ $null -ne $_.Change }).ForEach({ $_.Change })) -Catalog $catalog)
        Write-SeatTable -Seat $seat

        $blocking = @($seat | Where-Object { $_.Status -ne 'Sufficient' })
        if ($blocking.Count -gt 0) {
            $names = ($blocking | ForEach-Object { $_.SkuPartNumber }) -join ', '
            if (-not $Force) {
                throw ("The destination tenant cannot cover this run: $names. Buy seats, correct the SKU map, " +
                    'or re-run with -Force to attempt the assignments anyway.')
            }
            Write-MigrationLog -Message "-Force set; continuing despite seat problems with: $names" -Level WARNING
        }

        foreach ($item in $work) {
            $results.Add((Set-PlanRowLicense -Row $item.Row -User $item.User -Catalog $catalog -SkuMap $skuMap `
                -DefaultUsageLocation $DefaultUsageLocation -RemoveUnplanned:$RemoveUnplanned -DryRun:$DryRun))
        }
    }
}
catch {
    Write-MigrationLog -Message "Fatal: $($_.Exception.Message)" -Level ERROR
    $exitCode = 1
}

#endregion Main

#region Cleanup

if ($results.Count -gt 0) {
    try {
        $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Set-MigrationLicenses'
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
