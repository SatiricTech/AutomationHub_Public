function Test-MigrationRunWindow {
    <#
    .SYNOPSIS
        Says whether a recorded run was in progress at the moment a filename stamp names.

    .DESCRIPTION
        Two instances of one script can write results under the same token into the same
        folder - the three readiness stages, the domain-release report and remediation - and
        the catalogue's rule is that such a file belongs to the run that produced it. A
        ledger entry that listed its files says so outright; one that did not is matched on
        its Started..Ended window instead, which is what this answers.

        Started is floored to the whole second before the comparison. Filename stamps carry
        seconds and nothing finer, so a run that began at 13:00:00.500 and wrote its results
        in that same second would otherwise appear to have started after the file it wrote.

        An entry with no readable Started owns nothing: without a start there is no window,
        and guessing would attribute a file to the wrong instance. An entry with a start but
        no end owns only a file stamped at its own second - that is all it can prove.

    .PARAMETER Entry
        The run-ledger entry, as Get-MigrationRunLedgerEntry returns it.

    .PARAMETER Timestamp
        The moment parsed out of the artefact's filename.

    .EXAMPLE
        Test-MigrationRunWindow -Entry $entry -Timestamp $artefact.Timestamp

        Returns $true when that run was in progress when the file was stamped.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Entry,

        [Parameter(Mandatory)]
        [datetime]$Timestamp
    )

    $started = Get-MigrationProperty -InputObject $Entry -Name 'Started' -Default $null
    if ($started -isnot [datetime]) { return $false }

    $from = $started.AddTicks( - ($started.Ticks % [timespan]::TicksPerSecond))
    $ended = Get-MigrationProperty -InputObject $Entry -Name 'Ended' -Default $null
    $to = if ($ended -is [datetime]) { $ended } else { $from }

    return ($Timestamp -ge $from -and $Timestamp -le $to)
}
