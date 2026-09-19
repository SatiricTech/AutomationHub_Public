function Format-MigrationWorkbenchView {
    <#
    .SYNOPSIS
        Renders a workspace scan as the lines of one console workbench screen.

    .DESCRIPTION
        The console's whole picture of a migration, as data (Docs/Workbench-Design.md,
        section 8). Nothing here writes to the host: it returns the lines and the caller
        prints them, which is what lets the Pester suite assert the board - the glyphs, the
        next-step marker, the plan line - without a console, and what would let a second front
        end reuse the same wording.

        Every view opens with the same three lines, because they answer the three questions an
        operator asks before touching anything: which workbench and which folder, which two
        tenants, and which plan. Tenant GUIDs are shortened to their first eight characters:
        the banner exists to catch "this is the wrong tenant", and eight characters do that
        while a full GUID pushes the display name off the line.

        Phases is the runbook: the step instances of the workspace's own scenario, in order,
        grouped by phase, each with the state the scanner derived, when it last ran and what
        it counted. The numbering is the phase view's own, one-based and continuous across the
        phase blocks, because that is what the operator types to choose a step.

          [x] Done    [ ] NotRun    [~] DryRun    [!] PartlyFailed or Failed
          [?] WorkRemains           [s] Stale

        Tools is the flat toolbox: the 17 scripts with their own synopses, for the operator
        who knows which script they want and does not want the runbook's opinion about it.
        A synopsis costs a Get-Help parse of the whole script, so they are memoised for the
        session.

        Results is the ledger the scan already read, newest first and capped at 20 - the last
        20 runs is a screen, and a migration's whole history is a file the operator can open.
        Each entry names its run folder, because the driver, the stdout and the stderr of that
        run are in it. It is the scan's copy rather than a fresh read of the file so that the
        board and this screen can only ever describe the same moment.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .PARAMETER View
        Phases (the default), Tools or Results.

    .PARAMETER Version
        The workbench version shown in the header. Defaults to the module's version.

    .EXAMPLE
        Format-MigrationWorkbenchView -Workspace $ws | ForEach-Object { Write-Host $_ }

        Prints the phase view - the console workbench's default screen.

    .EXAMPLE
        Format-MigrationWorkbenchView -Workspace $ws -View 'Results' -Version '1.0.0'

        Returns the last 20 runs, newest first, with their exit codes and run folders.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [ValidateSet('Phases', 'Tools', 'Results')]
        [string]$View = 'Phases',

        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    if (-not $PSBoundParameters.ContainsKey('Version')) {
        $moduleVersion = $MyInvocation.MyCommand.Module.Version
        $Version = if ($moduleVersion) { [string]$moduleVersion } else { 'unknown' }
    }

    $lines = [System.Collections.Generic.List[string]]::new()

    # --- the header, the same on every view -----------------------------------------------------

    $scenario = [string](Get-MigrationProperty -InputObject $Workspace -Name 'Scenario' -Default '')
    if (-not $scenario) { $scenario = 'TenantToTenant' }
    $lines.Add(('M365 Migration Workbench {0} · {1} · {2}' -f $Version, $Workspace.Path, $scenario))

    $sideText = {
        param([string]$Section)
        $name = [string](Get-MigrationSettingsLeaf -Workspace $Workspace -Key "$Section.DisplayName")
        # An onmicrosoft domain is a name an operator recognises just as well as a display
        # name, and it is the field they are far more likely to have filled in.
        if (-not $name) {
            $name = [string](Get-MigrationSettingsLeaf -Workspace $Workspace -Key "$Section.OnMicrosoftDomain")
        }
        $guid = [string](Get-MigrationSettingsLeaf -Workspace $Workspace -Key "$Section.TenantId")
        $short = if ($guid.Length -ge 8) { $guid.Substring(0, 8) + '-…' } else { $guid }
        $parts = @(@($name, $short) | Where-Object { $_ })
        if ($parts.Count -eq 0) { return '(not set)' }
        return ($parts -join ' ')
    }

    $label = [string](Get-MigrationProperty -InputObject $Workspace -Name 'Label' -Default '')
    if (-not $label) { $label = '(no label)' }
    $lines.Add(('{0} · SOURCE {1} -> DESTINATION {2}' -f $label,
        (& $sideText 'Source'), (& $sideText 'Destination')))

    $plan = Get-MigrationProperty -InputObject $Workspace -Name 'Plan' -Default $null
    if ($null -eq $plan) {
        $lines.Add('Plan: none yet')
    }
    else {
        $pinned = if ([bool](Get-MigrationProperty -InputObject $plan -Name 'Pinned' -Default $false)) {
            'pinned'
        }
        else { 'newest' }

        $planParts = [System.Collections.Generic.List[string]]::new()
        $planParts.Add(('Plan: {0} ({1})' -f (Split-Path -Path ([string]$plan.Path) -Leaf), $pinned))
        $planParts.Add(('{0} rows' -f $plan.RowCount))

        $waves = @($plan.Waves.Keys)
        if ($waves.Count -gt 0) { $planParts.Add('waves ' + ($waves -join ', ')) }

        # Planned is the norm; only the statuses that need a decision are worth the line.
        foreach ($status in @($plan.Statuses.Keys)) {
            if ($status -eq 'Planned') { continue }
            # The extra parentheses matter: a method call splits its arguments on commas, so
            # without them the format operator would be handed only its first value.
            $planParts.Add(('{0} {1}' -f $plan.Statuses[$status], $status))
        }
        $lines.Add($planParts -join ' · ')
    }

    $lines.Add('')

    # --- the body ---------------------------------------------------------------------------------

    switch ($View) {
        'Tools' {
            $lines.Add('All tools · every script with every option free')
            $lines.Add('')

            $scripts = @(@(Get-MigrationStep) | ForEach-Object { [string]$_.Script } | Sort-Object -Unique)
            $width = (@($scripts | ForEach-Object { $_.Length + 4 }) | Measure-Object -Maximum).Maximum
            $number = 0
            foreach ($name in $scripts) {
                $number++
                $entry = Get-MigrationStep -Script $name
                $file = [System.IO.Path]::GetFileName([string]$entry.ScriptPath)
                $lines.Add(('  {0,2}  {1}  {2}' -f $number, $file.PadRight($width),
                    (Get-MigrationScriptSynopsisText -Path ([string]$entry.ScriptPath))))
            }

            $lines.Add('')
            $lines.Add(('[1-{0}] tool · [P] phases · [S] settings · [R] results & logs · [Q] quit' -f $number))
        }

        'Results' {
            $lines.Add('Results & logs · newest first')
            $lines.Add('')

            # The scan's own ledger, not a second read of the file: the board and the results
            # screen must describe the same moment, and re-reading would let a run appear on
            # one and not the other. Newest first, which is the question the screen answers.
            $entries = @(@($Workspace.Ledger) |
                    Sort-Object -Property Started, LineNumber -Descending |
                    Select-Object -First 20)
            if ($entries.Count -eq 0) {
                $lines.Add('  No runs recorded yet.')
            }
            foreach ($entry in $entries) {
                $verified = Get-MigrationProperty -InputObject $entry -Name 'TenantVerified' -Default $null
                $tenantMark = if ($null -eq $verified) { '–' } elseif ([bool]$verified) { '✓' } else { '✗' }
                $rehearsal = if ([bool](Get-MigrationProperty -InputObject $entry -Name 'DryRun' -Default $false)) {
                    '  DryRun'
                }
                else { '' }

                $lines.Add(('{0}  {1}  exit {2}  {3}  tenant {4}{5}' -f
                    (Format-MigrationRunStamp -Value (Get-MigrationProperty -InputObject $entry `
                                -Name 'Started' -Default $null)),
                    [string]$entry.StepId,
                    [string](Get-MigrationProperty -InputObject $entry -Name 'ExitCode' -Default '?'),
                    [string](Get-MigrationProperty -InputObject $entry -Name 'Meaning' -Default ''),
                    $tenantMark, $rehearsal))

                # The driver's folder, not the driver: stdout.txt and stderr.txt are beside it,
                # and that folder is what the operator opens when a run needs explaining.
                $driver = [string](Get-MigrationProperty -InputObject $entry -Name 'Driver' -Default '')
                if ($driver) { $lines.Add('              ' + (Split-Path -Path $driver -Parent)) }
            }

            $lines.Add('')
            $lines.Add('[P] phases · [A] all tools · [S] settings · [Q] quit')
        }

        default {
            $stateById = @{}
            foreach ($state in @($Workspace.Steps)) { $stateById[[string]$state.Id] = $state }

            $steps = @(Get-MigrationStep -Scenario $scenario)
            $titleWidth = (@(@($steps | ForEach-Object { ([string]$_.Title).Length }) + 20) |
                    Measure-Object -Maximum).Maximum
            $nextId = [string](Get-MigrationProperty -InputObject $Workspace -Name 'NextStepId' -Default '')

            $phase = ''
            $number = 0
            foreach ($step in $steps) {
                if ([string]$step.Phase -ne $phase) {
                    $phase = [string]$step.Phase
                    $lines.Add($phase)
                }
                $number++

                $state = if ($stateById.ContainsKey([string]$step.Id)) { $stateById[[string]$step.Id] } else { $null }
                $marker = if ([string]$step.Id -eq $nextId) { '  <- next' } else { '' }

                $lines.Add(('  {0} {1,2}  {2}  {3}{4}' -f
                    (Format-MigrationStepGlyph -State $state),
                    $number,
                    ([string]$step.Title).PadRight($titleWidth),
                    (Format-MigrationStepLastRun -State $state),
                    $marker).TrimEnd())
            }

            $warnings = @(Get-MigrationProperty -InputObject $Workspace -Name 'Warnings' -Default @())
            if ($warnings.Count -gt 0) {
                $lines.Add('')
                $lines.Add('Warnings:')
                foreach ($warning in $warnings) { $lines.Add('  - ' + [string]$warning) }
            }

            $lines.Add('')
            $lines.Add(('[1-{0}] step · [A] all tools · [S] settings · [R] results & logs · [Q] quit' -f $number))
        }
    }

    return $lines.ToArray()
}
