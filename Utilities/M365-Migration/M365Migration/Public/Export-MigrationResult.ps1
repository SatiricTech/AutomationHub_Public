function Export-MigrationResult {
    <#
    .SYNOPSIS
        Writes the run's per-row results to CSV and prints a summary by status.

    .DESCRIPTION
        Every phase script ends here, and every results file has the same shape, so a
        technician reading a migration folder six months later does not have to learn a
        new column layout per script.

        The first four columns are always Identity, Action, Status and Detail; any
        script-specific columns follow in the order they first appear. Status is one of
        Planned, Succeeded, Skipped or Failed - 'Planned' being what a dry run produces.

        The filename encodes the mode, because mixing a rehearsal up with the real thing
        is the expensive mistake this toolkit exists to avoid:
          <Prefix>_<Name>-Results_<timestamp>.csv   a real run
          <Prefix>_<Name>-DryRun_<timestamp>.csv    a dry run
        The prefix and its leading underscore are omitted when the run has no prefix.

        The summary block is written through the logger, so it lands in the run log as
        well as on the console.

    .PARAMETER Rows
        The result objects to write.

    .PARAMETER Name
        The result set name, normally the operation - for example 'Set-Identity'.

    .PARAMETER DryRun
        Marks the output as a dry run. Defaults to the run context's own DryRun state, so
        scripts rarely need to pass it.

    .EXAMPLE
        $path = Export-MigrationResult -Rows $results -Name 'Set-Identity'

        Writes the results CSV and returns its full path.

    .EXAMPLE
        Export-MigrationResult -Rows $results -Name 'New-Users' -DryRun

        Writes a DryRun-named file even if the run context says otherwise.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [switch]$DryRun
    )

    $isDryRun = $DryRun.IsPresent
    if (-not $PSBoundParameters.ContainsKey('DryRun') -and $script:MigrationRun) {
        $isDryRun = [bool]$script:MigrationRun.DryRun
    }

    $directory = if ($script:MigrationRun) { $script:MigrationRun.OutputDirectory } else { Get-MigrationDefaultOutputRoot }
    $prefix = if ($script:MigrationRun) { $script:MigrationRun.Prefix } else { '' }

    if (-not (Test-Path -LiteralPath $directory)) {
        try {
            $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
        }
        catch {
            throw "Could not create the results directory '$directory': $($_.Exception.Message)"
        }
    }

    $mode = if ($isDryRun) { 'DryRun' } else { 'Results' }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leader = if ($prefix) { "${prefix}_" } else { '' }
    $fileName = "${leader}${Name}-${mode}_$timestamp.csv"
    $filePath = Join-Path -Path $directory -ChildPath $fileName

    # The four standard columns lead; everything a script added follows in first-seen order.
    $standardColumns = @('Identity', 'Action', 'Status', 'Detail')
    $extraColumns = [System.Collections.Generic.List[string]]::new()
    foreach ($row in @($Rows)) {
        foreach ($property in $row.PSObject.Properties.Name) {
            if ($standardColumns -contains $property) { continue }
            if (-not $extraColumns.Contains($property)) { $extraColumns.Add($property) }
        }
    }

    $columns = @($standardColumns + $extraColumns.ToArray())
    $shaped = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) {
        $ordered = [ordered]@{}
        foreach ($column in $columns) {
            $value = ''
            if ($row.PSObject.Properties[$column]) { $value = $row.PSObject.Properties[$column].Value }
            $ordered[$column] = $value
        }
        $shaped.Add([pscustomobject]$ordered)
    }

    try {
        $shaped | Export-Csv -LiteralPath $filePath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
    }
    catch {
        throw "Could not write the results file '$filePath': $($_.Exception.Message)"
    }

    Write-MigrationLog -Message '--- Result summary ---' -Level SUCCESS
    if ($shaped.Count -eq 0) {
        Write-MigrationLog -Message '  (no rows processed)' -Level WARNING
    }
    else {
        $groups = $shaped | Group-Object -Property Status | Sort-Object -Property Name
        foreach ($group in $groups) {
            $status = if ([string]::IsNullOrWhiteSpace([string]$group.Name)) { '(none)' } else { $group.Name }
            $level = switch ($status) {
                'Failed'    { 'ERROR' }
                'Skipped'   { 'WARNING' }
                'Succeeded' { 'SUCCESS' }
                default     { 'SUCCESS' }
            }
            Write-MigrationLog -Message ('  {0,-12} {1}' -f $status, $group.Count) -Level $level
        }
        Write-MigrationLog -Message ('  {0,-12} {1}' -f 'Total', $shaped.Count) -Level SUCCESS
    }
    Write-MigrationLog -Message "Results written to $filePath" -Level SUCCESS

    return $filePath
}
