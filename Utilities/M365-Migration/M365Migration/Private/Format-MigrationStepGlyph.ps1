function Format-MigrationStepGlyph {
    <#
    .SYNOPSIS
        Maps a scanned step state to the two-character glyph the phase view draws it with.

    .DESCRIPTION
        The board is read at a glance, so every state the scanner can return
        (Docs/Workbench-Design.md, section 6) gets a glyph and no state falls through to a
        blank: a step whose state is missing is drawn as not run, which is the safe reading.

    .PARAMETER State
        The workspace's per-step state object, or $null when the scan has none.

    .EXAMPLE
        Format-MigrationStepGlyph -State $workspace.Steps[0]

        Returns '[x]' for a completed step.

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

    $name = if ($null -eq $State) { 'NotRun' }
    else { [string](Get-MigrationProperty -InputObject $State -Name 'State' -Default 'NotRun') }

    switch ($name) {
        'Done' { return '[x]' }
        'DryRun' { return '[~]' }
        'PartlyFailed' { return '[!]' }
        'Failed' { return '[!]' }
        'WorkRemains' { return '[?]' }
        'Stale' { return '[s]' }
        default { return '[ ]' }
    }
}
