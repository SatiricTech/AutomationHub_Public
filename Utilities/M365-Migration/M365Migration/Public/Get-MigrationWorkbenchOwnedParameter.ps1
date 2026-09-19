function Get-MigrationWorkbenchOwnedParameter {
    <#
    .SYNOPSIS
        Names the parameters the workbench decides for every run, whatever an operator types.

    .DESCRIPTION
        One list, held by the engine, read by all three front ends (Docs/Workbench-Design.md,
        sections 7.1 and 9). Each of these is set by something the operator already answered
        somewhere else, so a second way of setting it is not a convenience - it is a second
        source of truth that outranks the first silently:

          DryRun     the mode. Dry run or Run is the question the whole form is asking, and an
                     override that flipped it would rehearse a run the ledger records as live.
          Wave       the ledger's own truth. The waves are chosen once - the Waves prompt, the
                     checked list, -Wave - and the DryRunFirst gate compares a later live run
                     against the rehearsal's recorded waves. Two sources make that comparison
                     meaningless.
          OutputPath the workspace. Everything the migration reads and writes lives under the
                     folder the board is open on; a run that wrote somewhere else would be
                     invisible to the scanner that is meant to report it.
          TenantId   the expected tenant, from settings. It is what the child's own assertion
                     compares against, and what Invoke-MigrationStep verifies afterwards, so an
                     operator-supplied value would be the run marking its own homework.
          LogPath    derived by the script from -OutputPath, so naming it here would move the
                     logs out from under the workspace.
          Confirm    the driver sets -Confirm:$false for every script declaring
          WhatIf     SupportsShouldProcess, because the child runs -NonInteractive and cannot
          Verbose    answer a prompt; -WhatIf would turn a run into a rehearsal nothing
          Debug      recorded; -Verbose and -Debug would put Graph request bodies in the log.

        Returned as a plain array in this order rather than sorted, because the first four are
        the ones an operator actually reaches for and a list that reads by importance is easier
        to check a message against. Comparison is case-insensitive everywhere it is used:
        PowerShell parameter names are.

    .EXAMPLE
        Get-MigrationWorkbenchOwnedParameter

        Returns DryRun, Wave, OutputPath, TenantId, LogPath, Confirm, WhatIf, Verbose, Debug.

    .EXAMPLE
        'Wave' -in (Get-MigrationWorkbenchOwnedParameter)

        Returns $true - which is how a front end knows not to draw a control for it.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The singular reads as one name; the function returns the whole list by design.')]
    [OutputType([string[]])]
    param()

    return @('DryRun', 'Wave', 'OutputPath', 'TenantId', 'LogPath', 'Confirm', 'WhatIf', 'Verbose', 'Debug')
}
