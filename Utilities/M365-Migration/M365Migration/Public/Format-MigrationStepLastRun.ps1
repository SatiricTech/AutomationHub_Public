function Format-MigrationStepLastRun {
    <#
    .SYNOPSIS
        Describes the run a step's state is based on, in one line.

    .DESCRIPTION
        'When did this last run, and did it work' is the phase view's second column, and the
        answer has to be about one run. The scanner already knows which one - it is the run it
        derived the state and the counts from - and it names it on each step state as
        StateSource, StateRun and StateDryRun (Docs/Workbench-Design.md, section 6). This
        renders that run and nothing else.

        The alternative, and the bug this replaced, is to date the line from the newest file
        the step left behind. That is not the same run: a log written an hour after the results
        file would date an 11:00 summary 12:00, and a rehearsal that failed after a live run
        would put the rehearsal's counts on the live run's timestamp with no hint that a
        rehearsal was involved at all. A run recorded only in the ledger - a child that died
        before it wrote anything - had no date at all.

        A rehearsal says so, because a rehearsal that reads like a run is how an operator comes
        to believe a step is done when it is not. Counts are appended only when there are any,
        so an inventory - which writes no results file and therefore counts nothing - shows a
        date and nothing else.

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
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $State
    )

    if ($null -eq $State) { return '' }

    $source = [string](Get-MigrationProperty -InputObject $State -Name 'StateSource' -Default 'None')
    $run = Get-MigrationProperty -InputObject $State -Name 'StateRun' -Default $null
    if ($source -eq 'None' -or $null -eq $run) { return '' }

    # An artefact is dated by the timestamp in its filename; a ledger entry by when the run
    # started, which is the only record there is of a run that left nothing behind.
    $moment = if ($source -eq 'Ledger') {
        Get-MigrationProperty -InputObject $run -Name 'Started' -Default $null
    }
    else {
        Get-MigrationProperty -InputObject $run -Name 'Timestamp' -Default $null
    }

    $stamp = Format-MigrationRunStamp -Value $moment
    if (-not $stamp) { return '' }

    $isDryRun = [bool](Get-MigrationProperty -InputObject $State -Name 'StateDryRun' -Default $false)
    $text = if ($isDryRun) { "dry run $stamp" } else { $stamp }

    # The counts of that same run: the scanner's own Summary when it read the artefact, and
    # the entry's recorded Summary when the ledger is all there is.
    $summary = if ($source -eq 'Ledger') {
        Get-MigrationProperty -InputObject $run -Name 'Summary' -Default $null
    }
    else {
        Get-MigrationProperty -InputObject $State -Name 'Summary' -Default $null
    }

    $counts = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('Planned', 'Succeeded', 'Failed', 'Skipped')) {
        $count = [int](Get-MigrationProperty -InputObject $summary -Name $name -Default 0)
        if ($count -gt 0) { $counts.Add("$count $name") }
    }
    if ($counts.Count -gt 0) { $text = $text + ': ' + ($counts -join ', ') }

    return $text
}
