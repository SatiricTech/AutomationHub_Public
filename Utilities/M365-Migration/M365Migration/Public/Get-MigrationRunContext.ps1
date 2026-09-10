function Get-MigrationRunContext {
    <#
    .SYNOPSIS
        Returns the current run context, or $null when no run has been initialised.

    .DESCRIPTION
        Initialize-MigrationRun stores the run context in the module's own scope so the
        logger and the DryRun wrapper need no arguments beyond the message. Anything that
        needs the same facts - the output directory, the prefix, the log path, whether
        this is a rehearsal - reads them back through here rather than reaching into
        module state, which the caller cannot see.

        The object is the one Initialize-MigrationRun returned:
        OutputDirectory, Prefix, LogPath, ScriptName, StartedAt, DryRun, Verbosity.

        Returns $null before Initialize-MigrationRun has run, so a helper can fall back to
        sensible defaults instead of failing - which is what makes module functions
        testable without standing up a run first.

    .EXAMPLE
        $run = Get-MigrationRunContext
        if ($run) { $folder = $run.OutputDirectory }

        Reads the run's output folder, tolerating the not-yet-initialised case.

    .EXAMPLE
        if ((Get-MigrationRunContext).DryRun) { 'rehearsal' }

        Branches on the run's DryRun state.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    param()

    return $script:MigrationRun
}
