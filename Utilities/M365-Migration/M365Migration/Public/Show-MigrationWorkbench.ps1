function Show-MigrationWorkbench {
    <#
    .SYNOPSIS
        Runs the console migration workbench against a workspace folder, until the operator quits.

    .DESCRIPTION
        The console front end of Docs/Workbench-Design.md, section 8. It is a loop over four
        screens and one step form, and it holds no rules of its own: the board comes from
        Get-MigrationWorkspace and Format-MigrationWorkbenchView, the step form from
        Invoke-MigrationWorkbenchStep, the settings form from Edit-MigrationSettingsInteractive.
        Everything it asks goes through Read-MigrationPrompt, which is what lets the Pester
        suite drive a whole session with scripted answers and no console at all.

        A workspace with no settings - or with settings the loader will not accept - opens the
        settings form first. There is nothing useful to show before that: without a label the
        scanner cannot attribute a single file to a step, and without the tenant GUIDs no run
        can assert which tenant it reached.

        The keys, from any screen: a number picks the step (or, in the all-tools view, the
        script) at that position, A shows all tools, P the phases, S the settings, R the runs,
        Q leaves. The workspace is rescanned after anything that could have changed it - a run,
        a settings edit - because a board drawn from a stale scan is a board that tells an
        operator mid-migration that a step they just ran has not run.

        Returns the last run's result, or $null where the session ran nothing, so a caller that
        drove one step non-interactively has the exit code to act on.

    .PARAMETER Path
        The workspace folder. Everything the migration reads and writes lives under it.

    .PARAMETER Version
        The workbench version shown in the banner and recorded in each driver's header.
        Defaults to the module's version.

    .EXAMPLE
        Show-MigrationWorkbench -Path ~/Migration-Automations/Contoso

        Opens the workbench on that workspace and returns when the operator presses Q.

    .EXAMPLE
        Set-MigrationPromptHandler -Handler { 'Q' }
        Show-MigrationWorkbench -Path $workspace

        Draws the board once and leaves - the shape a test or a screenshot uses.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'This is the console front end; the board is host output by definition.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "The workspace folder '$Path' does not exist. Create it first, or point -Path at an existing one."
    }

    if (-not $PSBoundParameters.ContainsKey('Version')) {
        $moduleVersion = $MyInvocation.MyCommand.Module.Version
        $Version = if ($moduleVersion) { [string]$moduleVersion } else { 'unknown' }
    }

    # The workbench's own log lines only exist when a run context does; the module has to work
    # without one, because a caller can import it and call this directly.
    $hasRunContext = ($null -ne (Get-MigrationRunContext))
    if ($hasRunContext) { Write-MigrationLog -Message "Workbench opened on $Path" -Level INFO }

    $workspace = Get-MigrationWorkspace -Path $Path

    if (-not $workspace.SettingsResult.IsValid) {
        Write-Host ''
        foreach ($problem in @($workspace.SettingsResult.Errors)) { Write-Host "  $problem" -ForegroundColor Yellow }
        Edit-MigrationSettingsInteractive -Workspace $workspace | Out-Null
        $workspace = Get-MigrationWorkspace -Path $Path
    }

    $view = 'Phases'
    $lastResult = $null

    while ($true) {
        foreach ($line in @(Format-MigrationWorkbenchView -Workspace $workspace -View $view -Version $Version)) {
            Write-Host $line
        }

        $answer = ([string](Read-MigrationPrompt -Kind 'Text' -Message 'Choose a step, or a key')).Trim()
        if (-not $answer) { continue }

        $key = $answer.ToUpperInvariant()

        if ($key -eq 'Q') { break }
        if ($key -eq 'A') { $view = 'Tools'; continue }
        if ($key -eq 'P') { $view = 'Phases'; continue }
        if ($key -eq 'R') { $view = 'Results'; continue }

        if ($key -eq 'S') {
            Edit-MigrationSettingsInteractive -Workspace $workspace | Out-Null
            $workspace = Get-MigrationWorkspace -Path $Path
            continue
        }

        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number)) {
            Write-Host "  '$answer' is not a step number or one of A, P, S, R, Q." -ForegroundColor Yellow
            continue
        }

        # The tools view numbers the 17 scripts; every other view numbers the runbook. A script
        # entry carries no fixed values, which is what makes the all-tools form the free one.
        $choices = if ($view -eq 'Tools') {
            @(@(@(Get-MigrationStep) | ForEach-Object { [string]$_.Script } | Sort-Object -Unique) |
                    ForEach-Object { Get-MigrationStep -Script $_ })
        }
        else {
            @(Get-MigrationStep -Scenario $workspace.Scenario)
        }

        if ($number -lt 1 -or $number -gt $choices.Count) {
            Write-Host "  There is no $number here; the list runs from 1 to $($choices.Count)." `
                -ForegroundColor Yellow
            continue
        }

        $step = $choices[$number - 1]
        $result = Invoke-MigrationWorkbenchStep -Step $step -Workspace $workspace -Version $Version

        # Rescanned whether or not anything ran: the step form can have written a driver, and a
        # run that did happen has changed every state the board draws.
        $workspace = Get-MigrationWorkspace -Path $Path

        if ($null -ne $result) {
            $lastResult = $result
            if ($hasRunContext) {
                Write-MigrationLog -Message ("Step $($step.Id) finished with exit code " +
                    "$($result.ExitCode) ($($result.Meaning))") -Level INFO
            }
            # The board is about to be redrawn from a fresh scan, and the run's own output
            # would scroll off the top with it.
            Read-MigrationPrompt -Kind 'Text' -Message 'Press Enter to return to the menu' | Out-Null
        }
    }

    if ($hasRunContext) { Write-MigrationLog -Message 'Workbench closed' -Level INFO }
    return $lastResult
}
