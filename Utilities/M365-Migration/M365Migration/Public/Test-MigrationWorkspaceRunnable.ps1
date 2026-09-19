function Test-MigrationWorkspaceRunnable {
    <#
    .SYNOPSIS
        Decides whether this workspace is in a state anything may be run against, and says why not.

    .DESCRIPTION
        The one refusal all three front ends make (Docs/Workbench-Design.md, sections 8, 9 and
        10). A workspace whose settings will not load can still be opened and read - that is how
        an operator fixes them - but nothing may be run against it.

        With no valid settings there is no tenant GUID to assert against, so Invoke-MigrationStep
        is handed no -ExpectedTenantId and TenantVerified comes back $null; there is no label, so
        the prefix and the output folder fall back to whatever the workspace folder happens to be
        called; and one Yes on a soft gate would start a live writer against a tenant nobody
        checked. The window refuses with this reason in a box, the console board shows it and
        refuses the step form, and the unattended path exits 2 naming the keys.

        It is checked again after every rescan, not only when a workspace is opened. A settings
        file can stop validating while a session is open - a hand edit, a sync client's conflict
        copy, a .bak restored over it - and a front end that only asked at the start would go on
        offering runs against the state this refuses.

        The keys are named because they are what the operator has to fix: every settings error
        carries the dotted schema key it is about, and a form can put its message beside that
        field. A file-level problem - no file at all, or one that is not JSON - carries no key,
        and naming the file itself is the only useful thing to say.

        A pure function of the scan, so the refusal is testable on a machine with no display.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace, or $null when no workspace is open yet.

    .EXAMPLE
        (Test-MigrationWorkspaceRunnable -Workspace $ws).CanRun

        Returns $true for a workspace whose settings validate.

    .EXAMPLE
        (Test-MigrationWorkspaceRunnable -Workspace $ws).Reason

        Returns "The settings for this workspace are not usable yet: Label. Nothing can be run
        until they are fixed - open Settings." for a workspace whose Label was blanked.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        $Workspace
    )

    if ($null -eq $Workspace) {
        return [pscustomobject]@{
            CanRun = $false
            Keys   = @()
            Reason = 'Open a workspace first: a step runs against one migration folder.'
        }
    }

    $result = Get-MigrationProperty -InputObject $Workspace -Name 'SettingsResult' -Default $null
    if ([bool](Get-MigrationProperty -InputObject $result -Name 'IsValid' -Default $false)) {
        return [pscustomobject]@{ CanRun = $true; Keys = @(); Reason = '' }
    }

    $keys = [System.Collections.Generic.List[string]]::new()
    foreach ($problem in @(Get-MigrationProperty -InputObject $result -Name 'Errors' -Default @())) {
        $key = [string](Get-MigrationProperty -InputObject $problem -Name 'Key' -Default '')
        if (-not $key) { $key = '(the settings file itself)' }
        if (-not $keys.Contains($key)) { $keys.Add($key) }
    }
    if ($keys.Count -eq 0) { $keys.Add('(the settings file itself)') }

    return [pscustomobject]@{
        CanRun = $false
        Keys   = @($keys)
        Reason = ('The settings for this workspace are not usable yet: {0}. Nothing can be run ' -f
            (@($keys) -join ', ')) + 'until they are fixed - open Settings.'
    }
}
