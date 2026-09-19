function Get-MigrationPlanFacts {
    <#
    .SYNOPSIS
        Summarises an identity plan CSV: how many rows, in which waves, at which statuses.

    .DESCRIPTION
        What the workbench shows about a plan without opening it - "134 rows, waves 1 and 2,
        3 collisions" - and what Get-MigrationWorkspace hangs off its Plan property. The file
        is read through Import-MigrationPlan, so a plan missing a canonical column is rejected
        here exactly as it would be by the script that consumes it next; the scanner catches
        that and turns it into a warning rather than a failed scan.

        Waves come back in the order an operator reads them - numeric waves ascending, then
        anything else alphabetically - and statuses in the plan schema's own vocabulary order,
        with any status the schema does not know appended alphabetically. Both are [ordered]
        so a caller can render them straight out without sorting again.

        The timestamp is parsed from the filename, never from the file's mtime: sync clients
        rewrite mtimes and would make an untouched plan look freshly written.

    .PARAMETER Path
        The identity plan CSV to summarise.

    .EXAMPLE
        Get-MigrationPlanFacts -Path .\Contoso_IdentityPlan_20260918-101500.csv

        Returns { Path; Timestamp; RowCount; Waves; Statuses; DivergentRows } for the plan.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Facts names the set of measurements the workbench design asks this helper for.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # Import-MigrationPlan throws on a plan that is not a plan; that is the caller's cue to
    # warn and carry on, so nothing is caught here.
    $rows = @(Import-MigrationPlan -Path $Path)

    $waveCounts = @{}
    $statusCounts = @{}
    foreach ($row in $rows) {
        $wave = [string](Get-MigrationProperty -InputObject $row -Name 'Wave' -Default '')
        $status = [string](Get-MigrationProperty -InputObject $row -Name 'PlanStatus' -Default '')
        $waveCounts[$wave] = 1 + [int](Get-MigrationDictionaryValue -Dictionary $waveCounts -Key $wave -Default 0)
        $statusCounts[$status] = 1 + [int](Get-MigrationDictionaryValue -Dictionary $statusCounts -Key $status `
                -Default 0)
    }

    # '10' must sort after '2', so a numeric wave sorts on its value behind a '0' marker and
    # everything else sorts as text behind a '1' - one Sort-Object, no numeric/text branches.
    $waveKeys = @($waveCounts.Keys | Sort-Object -Property @{ Expression = {
                $number = 0
                if ([int]::TryParse([string]$_, [ref]$number)) { '0{0:D10}' -f $number } else { "1$_" }
            }
        })

    $waves = [ordered]@{}
    foreach ($key in $waveKeys) { $waves[[string]$key] = $waveCounts[$key] }

    $knownStatuses = @((Get-MigrationPlanSchema).PlanStatuses)
    $statuses = [ordered]@{}
    foreach ($status in $knownStatuses) {
        if ($statusCounts.ContainsKey($status)) { $statuses[$status] = $statusCounts[$status] }
    }
    foreach ($status in @($statusCounts.Keys | Where-Object { $knownStatuses -notcontains $_ } | Sort-Object)) {
        $statuses[[string]$status] = $statusCounts[$status]
    }

    $parsed = ConvertFrom-MigrationOutputPath -Path $Path

    return [pscustomobject]@{
        Path          = $Path
        Timestamp     = if ($parsed) { $parsed.Timestamp } else { $null }
        RowCount      = $rows.Count
        Waves         = $waves
        Statuses      = $statuses
        DivergentRows = [int](Get-MigrationDictionaryValue -Dictionary $statusCounts -Key 'UpnSmtpDiverge' -Default 0)
    }
}
