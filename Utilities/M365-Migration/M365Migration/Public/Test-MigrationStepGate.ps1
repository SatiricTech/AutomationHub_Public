function Test-MigrationStepGate {
    <#
    .SYNOPSIS
        Returns the safety gates standing between a step and the run the operator asked for.

    .DESCRIPTION
        The gates of Docs/Workbench-Design.md section 7.2, computed as data. Neither front end
        decides when a live run is allowed: the console workbench and the WinForms workbench
        both render this list, so the rules cannot differ between them and the Pester suite can
        assert them without driving a UI.

        Every gate that applies is returned, satisfied ones included, because the list is a
        checklist. A gate the operator has already met is worth showing - it is how they know
        the rehearsal counted - and a list that only ever held problems would leave the panel
        empty on the one occasion the operator most wants reassurance.

        The gates:

          DryRunFirst       Soft. Write and Destructive steps only, and only for a live run:
                            a rehearsal is not gated by the demand to rehearse. Satisfied when
                            the ledger holds a dry run of this step for the same waves, started
                            after the plan was written. Where the ledger has no rehearsal of
                            this step on record, a -DryRun_ results file newer than the plan
                            counts instead - a run made from the command line is still a run.
                            With no plan in the workspace there is nothing for a rehearsal to
                            be newer than, so any rehearsal counts.
          TypedConfirmation Hard. Every Destructive step, and every write on the SOURCE tenant
                            whatever its impact, because the source tenant is the one with no
                            undo. The operator types RequiredInput exactly: the source vanity
                            domain (Domains.Target) for a source-side step, the word REMOVE
                            otherwise, and REMOVE as the fallback when no domain is configured.
                            Never satisfied here - it is satisfied by the operator typing it,
                            which is the point - and asked for on a rehearsal too, because a
                            rehearsal still signs in to the source tenant.
          Prerequisite      Soft. Steps with Requires. Lists what is not in hand, where a
                            requirement naming an artefact kind is met by the artefact being
                            there, whoever produced it.
          WaveRequired      Soft. Live runs of a step whose chosen parameter set takes -Wave.
                            A blank wave is legal and means the whole plan; the gate exists so
                            that it is a decision rather than an omission.

        TenantMismatch is the fifth kind in the vocabulary and is deliberately never produced
        here. It is a post-run gate: it compares the "Connected to ... tenant <guid>" lines in
        the child's log with the GUID the step should have reached, so it cannot be known until
        the child has run and Invoke-MigrationStep has its log to read.

    .PARAMETER Step
        The step instance from Get-MigrationStep.

    .PARAMETER Arguments
        The Resolve-MigrationStepArguments result for this run. The gates read the waves and
        the chosen parameter set off it, so they judge the run that would actually happen.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .PARAMETER Live
        The operator asked for a live run rather than a rehearsal.

    .EXAMPLE
        $resolved = Resolve-MigrationStepArguments -Step $step -Workspace $ws -Wave '1'
        Test-MigrationStepGate -Step $step -Arguments $resolved -Workspace $ws -Live

        Returns the checklist a live wave-1 run has to clear.

    .EXAMPLE
        $gates = Test-MigrationStepGate -Step $step -Arguments $resolved -Workspace $ws -Live
        @($gates | Where-Object { $_.Severity -eq 'Hard' -and -not $_.Satisfied })

        The hard gates, which no override may pass - the ones that need something typed.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Step,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Arguments,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [switch]$Live
    )

    $gates = [System.Collections.Generic.List[object]]::new()
    $title = if ($Step.Title) { $Step.Title } else { $Step.Id }

    $requestedWave = @()
    $waveArgument = @($Arguments.Arguments | Where-Object { $_.Name -eq 'Wave' })
    if ($waveArgument.Count -gt 0) { $requestedWave = @($waveArgument[0].Value) }
    $requestedKey = Get-MigrationWaveKey -Wave $requestedWave
    $waveText = if ($requestedKey) { " for wave $($requestedKey -replace '\|', ', ')" } else { '' }

    # --- DryRunFirst --------------------------------------------------------------------------

    if ($Live -and $Step.Impact -in @('Write', 'Destructive')) {
        $planStamp = $null
        if ($null -ne $Workspace.Plan) { $planStamp = $Workspace.Plan.Timestamp }

        $rehearsed = $false
        $rehearsals = @($Workspace.Ledger | Where-Object {
                $_.StepId -eq $Step.Id -and
                [bool](Get-MigrationProperty -InputObject $_ -Name 'DryRun' -Default $false)
            })

        if ($rehearsals.Count -gt 0) {
            foreach ($entry in $rehearsals) {
                if ((Get-MigrationWaveKey -Wave @($entry.Wave)) -ne $requestedKey) { continue }
                if ($null -eq $planStamp) { $rehearsed = $true; break }

                $started = Get-MigrationProperty -InputObject $entry -Name 'Started' -Default $null
                if ($started -is [datetime] -and $started -gt $planStamp) { $rehearsed = $true; break }
            }
        }
        else {
            # Nothing recorded for this step, so the files are the only witness. The scanner
            # has already picked the newest rehearsal out of them.
            $state = @($Workspace.Steps | Where-Object { $_.Id -eq $Step.Id })
            $lastDryRun = if ($state.Count -gt 0) { $state[0].LastDryRun } else { $null }
            if ($lastDryRun) {
                $rehearsed = ($null -eq $planStamp) -or
                    ($lastDryRun.Timestamp -is [datetime] -and $planStamp -is [datetime] -and
                    $lastDryRun.Timestamp -gt $planStamp)
            }
        }

        $message = if ($rehearsed) {
            "A rehearsal of this step$waveText, newer than the identity plan, is on record."
        }
        else {
            "No rehearsal of this step$waveText newer than the identity plan is on record. " +
            'Run it with -DryRun first, or override the gate - the override is recorded in the ledger.'
        }

        $gates.Add([pscustomobject]@{
                Kind          = 'DryRunFirst'
                Severity      = 'Soft'
                Satisfied     = $rehearsed
                Message       = $message
                RequiredInput = $null
            })
    }

    # --- TypedConfirmation ---------------------------------------------------------------------

    $onSource = ($Step.Side -eq 'Source')
    if ($Step.Impact -eq 'Destructive' -or ($onSource -and $Step.Impact -ne 'Read')) {
        # The source tenant is the one with no undo, so its writers are typed regardless of
        # impact; on the destination only a destructive step earns the keyboard.
        $required = 'REMOVE'
        if ($onSource) {
            $domain = Get-MigrationStepSettingsValue -Workspace $Workspace -Key 'Domains.Target'
            if ($domain) { $required = [string]$domain }
        }

        $message = if ($onSource) {
            "$title acts on the SOURCE tenant. Type '$required' exactly to continue; a keypress is not enough."
        }
        else {
            "$title is destructive. Type '$required' exactly to continue; a keypress is not enough."
        }

        $gates.Add([pscustomobject]@{
                Kind          = 'TypedConfirmation'
                Severity      = 'Hard'
                Satisfied     = $false
                Message       = $message
                RequiredInput = $required
            })
    }

    # --- Prerequisite ----------------------------------------------------------------------------

    $requires = @($Step.Requires)
    if ($requires.Count -gt 0) {
        $unmet = @($requires |
                Where-Object { -not (Test-MigrationStepRequirement -Requirement $_ -Workspace $Workspace) })

        $message = if ($unmet.Count -eq 0) {
            "Everything this step needs is in hand: $($requires -join ', ')."
        }
        else {
            "Not done yet: $($unmet -join ', ')."
        }

        $gates.Add([pscustomobject]@{
                Kind          = 'Prerequisite'
                Severity      = 'Soft'
                Satisfied     = ($unmet.Count -eq 0)
                Message       = $message
                RequiredInput = $null
            })
    }

    # --- WaveRequired -----------------------------------------------------------------------------

    if ($Live) {
        $waveParameter = @($Step.Parameters | Where-Object { $_.Name -eq 'Wave' })
        $takesWave = $false
        if ($waveParameter.Count -gt 0) {
            # A -Wave the chosen parameter set cannot hold is not a decision the operator has:
            # a -TestUser run of the password reset has no waves to pick from.
            $sets = @($waveParameter[0].ParameterSets)
            $takesWave = ($sets.Count -eq 0) -or ($sets -contains $Arguments.ParameterSet)
        }

        if ($takesWave) {
            $given = ($waveArgument.Count -gt 0)
            $message = if ($given) {
                "The run is limited to wave $($requestedKey -replace '\|', ', ')."
            }
            else {
                'No wave was given, so the whole plan will be processed. Name a wave to do less than that.'
            }

            $gates.Add([pscustomobject]@{
                    Kind          = 'WaveRequired'
                    Severity      = 'Soft'
                    Satisfied     = $given
                    Message       = $message
                    RequiredInput = $null
                })
        }
    }

    return @($gates)
}
