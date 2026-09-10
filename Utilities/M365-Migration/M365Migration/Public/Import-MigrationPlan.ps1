function Import-MigrationPlan {
    <#
    .SYNOPSIS
        Reads and validates an identity plan CSV, then applies the standard filters.

    .DESCRIPTION
        Every writer in the toolkit starts here, so the schema is checked once and the
        rest of the run can read any column without guarding it. All plan columns must be
        present except the writeback columns (TargetObjectId, MailboxProvisioned,
        OneDriveProvisioned, ProvisionStatus, ProvisionDetail), which are added as empty
        strings - a plan hand-built in a spreadsheet should not have to carry columns the
        operator is not meant to fill in.

        Headers are trimmed and matched case-insensitively, and the returned rows always
        expose the canonical column names in canonical order, so Save-MigrationPlan can
        write the file straight back without reshaping it.

        Excluded rows are returned rather than dropped: writers are required to record a
        Skipped result naming the status, and they cannot do that for a row they never saw.

        An empty result after filtering is an error, not an empty run. A wave filter that
        matches nothing is almost always a typo, and failing loudly beats reporting a
        successful run that did nothing.

    .PARAMETER Path
        The identity plan CSV. A wildcard pattern (for example
        '.\Contoso_IdentityPlan_*.csv') is resolved when it matches exactly one file;
        zero or more than one match is still an error.

    .PARAMETER Wave
        Restricts the result to these waves.

    .PARAMETER ObjectType
        Restricts the result to these object types.

    .PARAMETER PlanStatus
        Restricts the result to these plan statuses.

    .EXAMPLE
        $plan = Import-MigrationPlan -Path .\IdentityPlan.csv -Wave '1'

        Reads the plan and returns the wave-one rows.

    .EXAMPLE
        $plan = Import-MigrationPlan -Path .\IdentityPlan.csv -ObjectType 'Shared', 'Room' -PlanStatus 'Planned'

        Returns only the resource mailboxes that are ready to provision.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [AllowNull()][AllowEmptyCollection()][string[]]$Wave,
        [AllowNull()][AllowEmptyCollection()][string[]]$ObjectType,
        [AllowNull()][AllowEmptyCollection()][string[]]$PlanStatus
    )

    $resolvedPath = $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -and $Path -match '[*?\[]') {
        $candidates = @()
        try { $candidates = @(Resolve-Path -Path $Path -ErrorAction Stop | Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf }) }
        catch { $candidates = @() }

        if ($candidates.Count -gt 1) {
            throw ("The identity plan pattern '$Path' matched $($candidates.Count) files: " +
                (($candidates | ForEach-Object { $_.Path }) -join ', ') + '. Pass one specific file name.')
        }
        if ($candidates.Count -eq 1) { $resolvedPath = $candidates[0].Path }
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Identity plan not found: $Path"
    }

    try {
        $raw = @(Import-Csv -LiteralPath $resolvedPath -Encoding utf8 -ErrorAction Stop)
    }
    catch {
        throw "Could not read the identity plan '$resolvedPath': $($_.Exception.Message)"
    }

    if ($raw.Count -eq 0) {
        throw "The identity plan '$resolvedPath' contains no data rows."
    }

    $headers = @($raw[0].PSObject.Properties.Name)
    $headerLookup = @{}
    foreach ($header in $headers) { $headerLookup[$header.Trim()] = $header }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($column in $script:MigrationPlanColumns) {
        if ($headerLookup.ContainsKey($column)) { continue }
        if ($script:MigrationPlanWritebackColumns -contains $column) { continue }
        $missing.Add($column)
    }

    if ($missing.Count -gt 0) {
        throw ("The identity plan '$Path' is missing required column(s): " + ($missing -join ', ') +
            '. Regenerate it with New-MigrationIdentityPlan or start from Templates\IdentityPlan.sample.csv.')
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $raw) {
        $row = [ordered]@{}
        foreach ($column in $script:MigrationPlanColumns) {
            $value = ''
            if ($headerLookup.ContainsKey($column)) {
                $cell = $record.PSObject.Properties[$headerLookup[$column]].Value
                if ($null -ne $cell) { $value = ([string]$cell).Trim() }
            }
            $row[$column] = $value
        }
        $rows.Add([pscustomobject]$row)
    }

    Write-MigrationLog -Message "Loaded $($rows.Count) plan row(s) from $resolvedPath" -Level INFO

    $selectParameters = @{ Rows = $rows.ToArray(); IncludeExcluded = $true }
    if ($Wave) { $selectParameters['Wave'] = $Wave }
    if ($ObjectType) { $selectParameters['ObjectType'] = $ObjectType }
    if ($PlanStatus) { $selectParameters['PlanStatus'] = $PlanStatus }

    $filtered = @(Select-MigrationPlanRows @selectParameters)

    if ($filtered.Count -eq 0) {
        $describe = [System.Collections.Generic.List[string]]::new()
        if ($Wave) { $describe.Add("Wave = $($Wave -join ', ')") }
        if ($ObjectType) { $describe.Add("ObjectType = $($ObjectType -join ', ')") }
        if ($PlanStatus) { $describe.Add("PlanStatus = $($PlanStatus -join ', ')") }
        $criteria = if ($describe.Count -gt 0) { ' matching ' + ($describe -join '; ') } else { '' }
        throw "The identity plan '$resolvedPath' returned no rows$criteria. Check the filter values against the plan file."
    }

    if ($filtered.Count -ne $rows.Count) {
        Write-MigrationLog -Message "Filtered to $($filtered.Count) of $($rows.Count) plan row(s)" -Level INFO
    }

    return $filtered
}
