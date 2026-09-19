function Get-MigrationResultSummary {
    <#
    .SYNOPSIS
        Counts the statuses in a results CSV, reading no other column.

    .DESCRIPTION
        The four numbers the workbench puts against a step - Succeeded, Failed, Skipped,
        Planned - come from here, and deliberately from the Status column alone. Every
        results file the toolkit writes carries Identity, Action, Status and Detail, and a
        provisioning run also carries GeneratedPassword: the workbench never reads, renders
        or persists that column, and the narrowest possible read is how that is guaranteed
        rather than promised (Docs/Workbench-Design.md, section 6).

        RowCount comes back alongside so the caller can tell "a run that did nothing" from
        "a file with a header and no rows", which is worth a warning naming the file.

        A file without a Status column at all - hand-edited, or a report saved under a
        results name - counts as zero of everything rather than failing the scan.

    .PARAMETER Path
        The results CSV to count.

    .EXAMPLE
        Get-MigrationResultSummary -Path .\Contoso_Set-Licenses-Results_20260918-110000.csv

        Returns { Path; RowCount; Succeeded; Failed; Skipped; Planned }.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $rows = @(Import-Csv -LiteralPath $Path -Encoding utf8 -ErrorAction Stop)

    # -ErrorAction SilentlyContinue covers the file that has no Status column: the counts are
    # then all zero, which is what "nothing to report" should look like.
    $statuses = @($rows | Select-Object -ExpandProperty 'Status' -ErrorAction SilentlyContinue)

    $counts = @{ Succeeded = 0; Failed = 0; Skipped = 0; Planned = 0 }
    foreach ($status in $statuses) {
        $name = ([string]$status).Trim()
        if ($counts.ContainsKey($name)) { $counts[$name]++ }
    }

    return [pscustomobject]@{
        Path      = $Path
        RowCount  = $rows.Count
        Succeeded = $counts['Succeeded']
        Failed    = $counts['Failed']
        Skipped   = $counts['Skipped']
        Planned   = $counts['Planned']
    }
}
