function Complete-MigrationRun {
    <#
    .SYNOPSIS
        Closes out a run, logging the elapsed time, and returns the exit code.

    .DESCRIPTION
        The last call in every toolkit script. It logs the duration and the outcome and
        hands back the exit code so the caller can 'exit (Complete-MigrationRun -ExitCode $code)'.

        Connections are deliberately left open: a technician usually runs several phase
        scripts back to back, and tearing down the Graph or Exchange session between
        them would force a fresh interactive sign-in each time. Callers that genuinely
        want to disconnect own that decision.

    .PARAMETER ExitCode
        0 for success, 1 for a fatal error, 2 when the run completed but some rows failed.

    .EXAMPLE
        exit (Complete-MigrationRun -ExitCode 0)

        Logs the duration and exits cleanly.

    .EXAMPLE
        exit (Complete-MigrationRun -ExitCode 2)

        Signals to the scheduler that the run finished with row-level failures.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [ValidateRange(0, 255)]
        [int]$ExitCode = 0
    )

    if ($script:MigrationRun) {
        $duration = (Get-Date) - $script:MigrationRun.StartedAt
        $elapsed = '{0:hh\:mm\:ss}' -f $duration
        $level = if ($ExitCode -eq 0) { 'SUCCESS' } else { 'WARNING' }
        Write-MigrationLog -Message "Finished $($script:MigrationRun.ScriptName) in $elapsed (exit code $ExitCode)" -Level $level
        if ($script:MigrationRun.LogPath) {
            Write-MigrationLog -Message "Log written to $($script:MigrationRun.LogPath)" -Level INFO
        }
    }
    else {
        Write-MigrationLog -Message "Run completed with exit code $ExitCode (no run context was initialised)" -Level WARNING
    }

    return $ExitCode
}
