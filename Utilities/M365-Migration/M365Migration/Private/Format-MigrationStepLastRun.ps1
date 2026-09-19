function Format-MigrationStepLastRun {
    <#
    .SYNOPSIS
        Describes when a step last ran and what it counted, in one line.

    .DESCRIPTION
        'When did this last run, and did it work' is the phase view's second column. A live
        run is dated; a rehearsal says so, because a rehearsal that reads like a run is how an
        operator comes to believe a step is done when it is not. Counts are appended only when
        there are any, so an inventory - which writes no results file and therefore counts
        nothing - shows a date and nothing else.

        The counts are ordered Planned, Succeeded, Failed, Skipped: what the run intended
        first, because on a rehearsal that is the only number that exists, then what it
        achieved, then what went wrong, then what it passed over.

    .PARAMETER State
        The workspace's per-step state object, or $null.

    .EXAMPLE
        Format-MigrationStepLastRun -State $state

        Returns 'dry run 18 Sep 10:31: 2 Planned, 1 Skipped'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $State
    )

    if ($null -eq $State) { return '' }

    $isDryRun = ([string](Get-MigrationProperty -InputObject $State -Name 'State' -Default '') -eq 'DryRun')
    $artefact = if ($isDryRun) {
        Get-MigrationProperty -InputObject $State -Name 'LastDryRun' -Default $null
    }
    else { Get-MigrationProperty -InputObject $State -Name 'LastRun' -Default $null }

    if ($null -eq $artefact) { return '' }

    $stamp = Format-MigrationRunStamp -Value (Get-MigrationProperty -InputObject $artefact `
            -Name 'Timestamp' -Default $null)
    if (-not $stamp) { return '' }

    $text = if ($isDryRun) { "dry run $stamp" } else { $stamp }

    $summary = Get-MigrationProperty -InputObject $State -Name 'Summary' -Default $null
    $counts = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('Planned', 'Succeeded', 'Failed', 'Skipped')) {
        $count = [int](Get-MigrationProperty -InputObject $summary -Name $name -Default 0)
        if ($count -gt 0) { $counts.Add("$count $name") }
    }
    if ($counts.Count -gt 0) { $text = $text + ': ' + ($counts -join ', ') }

    return $text
}
