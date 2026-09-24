function Invoke-MigrationStepSeam {
    <#
    .SYNOPSIS
        Calls one of the runner's front-end scriptblocks, and disables it if it throws.

    .DESCRIPTION
        Invoke-MigrationStep hands three scriptblocks to whichever front end is driving it: the
        output writer, the message pump and the cancel check (Docs/Workbench-Design.md, section
        7.3). All three are somebody else's code, and under WinForms all three touch a form -
        a disposed control, a closed window or a call from the wrong thread throws.

        None of that may reach the child process. A step that is signing users in to a tenant
        must not be abandoned mid-run because a log pane went away, and the run must still be
        recorded. So a seam that throws is reported once through Write-Warning, marked broken
        in the shared state, and never called again for that run; the poll loop carries on.

        The three seams fail differently and that is deliberate: a broken writer costs the live
        log (the whole of stdout is still on disk), a broken pump costs the repaint, and a
        broken cancel check costs the cancel button - which is why its failure is worth a
        warning the operator can act on by killing the process themselves.

    .PARAMETER Name
        The seam's name, used as the key in -State and in the warning.

    .PARAMETER Seam
        The scriptblock to call.

    .PARAMETER Argument
        Positional arguments for the scriptblock.

    .PARAMETER State
        A hashtable of seam name -> broken, shared across the run. A hashtable rather than
        variables because the poll loop mutates it from inside a nested scriptblock.

    .EXAMPLE
        Invoke-MigrationStepSeam -Name 'OutputWriter' -Seam $writer -Argument @($line) -State $broken

        Writes the line, or warns once and stops using the writer for the rest of the run.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [scriptblock]$Seam,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Argument,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$State
    )

    if ($State[$Name]) { return $null }

    try {
        return (& $Seam @Argument)
    }
    catch {
        $State[$Name] = $true
        Write-Warning ("The $Name supplied by the front end failed and will not be called again " +
            "for this run: $($_.Exception.Message)")
        return $null
    }
}
