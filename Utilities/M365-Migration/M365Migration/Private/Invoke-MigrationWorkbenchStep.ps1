function Invoke-MigrationWorkbenchStep {
    <#
    .SYNOPSIS
        Runs one step from the console: the wave, the arguments, the gates, the command, the run.

    .DESCRIPTION
        The console's step form (Docs/Workbench-Design.md, section 8). It holds no rules of its
        own - every decision it renders comes from Resolve-MigrationStepArguments,
        Test-MigrationStepGate, New-MigrationStepDriver and Invoke-MigrationStep - so the
        console and the WinForms front end cannot end up disagreeing about when a run is
        allowed.

        The order is the order the questions actually depend on each other in:

          1. The wave. A writer with -Wave and a plan with waves is asked which one, because
             running a whole plan when a wave was meant is not something a later gate can undo.
             A reader is not asked: reading the whole plan costs time and nothing else.
          2. The arguments, each with the rung of the precedence ladder that decided it, and
             anything the chosen parameter set still needs. E re-asks one of them; the answer
             becomes an Operator override, which outranks everything but the instance's own
             fixed values.
          3. The gates. A live run must clear them all: a soft gate is confirmed and the
             override is recorded in the ledger, a hard one is typed out in full. A rehearsal
             clears only the hard ones - a rehearsal exists to be run before the prerequisites
             are met, and gating it on them would leave the operator with nothing safe to do.
             The arguments are resolved again the moment live-or-rehearsal is known, and the
             gates, the driver, the preview and the run all read that one resolution. Resolving
             once at the top of the form and reading the key afterwards is how a driver ends up
             rehearsing while the ledger records a live run - and, the other way round, how a
             live run of a destructive step gets through on a rehearsal's much shorter gate
             list.
          4. The command, printed as both the line an operator would have typed and the one
             that will actually start the child, and then one last confirmation.
          5. The outcome: what the exit code means, what was counted, what was written, and -
             loudly - whether the child reached the tenant it was supposed to.

        Nothing here is allowed to take the session down with it. Every engine call is inside
        one guard: a plan that will not parse, a driver that cannot be written, a workspace
        that moved - the operator loses the step and goes back to the board, not the workbench
        they are running the migration from.

        The Viva Learning client secret is the one value that never goes through the argument
        resolver. Where the script takes a -ClientSecret and no certificate thumbprint is
        configured, it is prompted for as a SecureString and handed to the child through an
        environment variable that exists for the life of that process; the driver is told to
        read it from there. It is never printed, never logged and never written to disk.

    .PARAMETER Step
        The step instance from Get-MigrationStep, or a bare script entry from the tools view.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .PARAMETER Live
        Offer a live run rather than a rehearsal as the suggested action. The operator's own
        answer still decides.

    .PARAMETER Version
        The workbench version recorded in the driver header.

    .EXAMPLE
        Invoke-MigrationWorkbenchStep -Step (Get-MigrationStep -Id 'New-Users') -Workspace $ws

        Shows the provisioning step's form and returns the run result, or $null if nothing ran.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'This is the console front end; the step form is host output by definition.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The operator confirms the run at the prompt; a second -Confirm would be noise.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Step,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [switch]$Live,

        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    $driverParameters = @{}
    if ($PSBoundParameters.ContainsKey('Version')) { $driverParameters['Version'] = $Version }

    # --- 1. the wave -------------------------------------------------------------------------

    $wave = @()
    $planWaves = @()
    if ($null -ne $Workspace.Plan) { $planWaves = @($Workspace.Plan.Waves.Keys) }
    $takesWave = (@(@($Step.Parameters) | Where-Object { $_.Name -eq 'Wave' }).Count -gt 0)

    if ($takesWave -and $planWaves.Count -gt 0 -and $Step.Impact -in @('Write', 'Destructive')) {
        $chosen = [string](Read-MigrationPrompt -Kind 'Choice' -Message 'Which wave?' `
                -Choices (@('all') + $planWaves) -Default 'all')
        if ($chosen -and $chosen -ne 'all') { $wave = @($chosen) }
    }

    # --- 2. the arguments --------------------------------------------------------------------

    $renderValue = {
        param([AllowNull()]$Value)
        if ($null -eq $Value) { return '' }
        if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
        if ($Value -is [System.Management.Automation.SwitchParameter]) {
            return $(if ($Value.IsPresent) { '$true' } else { '$false' })
        }
        if ($Value -is [System.Collections.IDictionary]) {
            return (@(@($Value.Keys) | ForEach-Object { '{0}={1}' -f $_, $Value[$_] }) -join ';')
        }
        if ($Value -isnot [string] -and $Value -is [System.Collections.IEnumerable]) {
            return (@($Value) -join ',')
        }
        return [string]$Value
    }


    # One place that draws the argument table, because it is drawn twice: once for the form,
    # and again when choosing live or rehearsal changes what would actually be passed.
    $showArguments = {
        param($Resolved)
        $names = @(@($Resolved.Arguments) | ForEach-Object { ([string]$_.Name).Length })
        $width = (@($names + 8) | Measure-Object -Maximum).Maximum
        foreach ($argument in @($Resolved.Arguments)) {
            Write-Host ('  {0}  {1}  ({2})' -f ([string]$argument.Name).PadRight($width),
                (& $renderValue $argument.Value), $argument.Source)
            $warning = [string](Get-MigrationProperty -InputObject $argument -Name 'Warning' -Default '')
            if ($warning) { Write-Host ('  ' + ' ' * $width + '  ' + $warning) -ForegroundColor Yellow }
        }

        foreach ($warning in @($Resolved.Warnings)) { Write-Host "  ! $warning" -ForegroundColor Yellow }

        $missing = @($Resolved.MissingMandatory)
        if ($missing.Count -gt 0) {
            Write-Host ''
            Write-Host ('  This run still needs: ' + ($missing -join ', ')) -ForegroundColor Red
        }
    }

    # A driver 'C' wrote and nothing ran. It is kept so the command line it printed still
    # points at a file the operator can paste, and it is either reused by the next run of the
    # same thing or removed - a form pass must not leave evidence of a run that never happened.
    $preview = $null
    # Takes the preview as an argument and the caller clears its own variable afterwards: a
    # scriptblock invoked with '&' runs in a child scope, so an assignment inside it would
    # create a local and leave the form still holding a driver it had just deleted.
    $removePreview = {
        param([AllowNull()]$Candidate)
        if ($null -eq $Candidate) { return }
        $folder = [string]$Candidate.Driver.RunFolder
        # Only ever a folder this function created and nothing has run in: the presence of
        # stdout.txt means Invoke-MigrationStep owns it now.
        if ($folder -and (Test-Path -LiteralPath $folder -PathType Container) -and
            -not (Test-Path -LiteralPath (Join-Path $folder 'stdout.txt') -PathType Leaf)) {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $overrides = @{}
    $isLive = [bool]$Live
    # Bumped by anything that changes what would run, so a driver built for an earlier state
    # is never silently reused for a later one.
    $revision = 0

    # The whole form is guarded: an engine call that throws - an unreadable plan, a driver that
    # cannot be written, a workspace that moved under the session - must cost the operator this
    # step and not the workbench they are running the migration from.
    try {
        while ($true) {
            $displayedLive = $isLive
            $resolved = Resolve-MigrationStepArguments -Step $Step -Workspace $Workspace `
                -Override $overrides -Wave $wave -DryRun:(-not $isLive)

            Write-Host ''
            Write-Host ('{0} - {1}' -f $Step.Id, $Step.Title)
            Write-Host ('{0} · {1} tenant · impact {2}' -f
                [System.IO.Path]::GetFileName([string]$Step.ScriptPath), $Step.Side, $Step.Impact)
            if ($Step.Notes) { Write-Host ('  ' + [string]$Step.Notes) -ForegroundColor DarkGray }
            Write-Host ''

            & $showArguments $resolved

            Write-Host ''
            $action = ([string](Read-MigrationPrompt -Kind 'Text' `
                        -Message '[E] edit a value  [D] dry run  [R] run  [C] command only  [B] back' `
                        -Default $(if ($isLive) { 'R' } else { 'D' }))).Trim().ToUpperInvariant()

            if ($action -eq 'B') {
                & $removePreview $preview
                $preview = $null
                return $null
            }

            if ($action -eq 'E') {
                $typed = ([string](Read-MigrationPrompt -Kind 'Text' -Message 'Which parameter?')).Trim()
                $match = @(@($Step.Parameters) | Where-Object { $_.Name -ieq $typed })
                if ($match.Count -eq 0) {
                    Write-Host "  '$typed' is not a parameter of $($Step.Script)." -ForegroundColor Yellow
                    continue
                }

                $parameter = $match[0]
                $edited = $true
                if ($parameter.IsSwitch -or $parameter.IsBool) {
                    $overrides[$parameter.Name] = [bool](Read-MigrationPrompt -Kind 'Confirm' `
                            -Message $parameter.Name)
                }
                elseif (@($parameter.ValidValues).Count -gt 0) {
                    $overrides[$parameter.Name] = [string](Read-MigrationPrompt -Kind 'Choice' `
                            -Message $parameter.Name -Choices @($parameter.ValidValues))
                }
                else {
                    $entered = [string](Read-MigrationPrompt -Kind 'Text' -Message $parameter.Name)
                    if ($parameter.IsArray) {
                        $overrides[$parameter.Name] = @(@($entered -split ',') |
                                ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    }
                    elseif ([string]$parameter.TypeName -in @('Int32', 'Int64')) {
                        $number = 0
                        if ([int]::TryParse($entered, [ref]$number)) { $overrides[$parameter.Name] = $number }
                        else {
                            Write-Host "  '$entered' is not a whole number." -ForegroundColor Yellow
                            $edited = $false
                        }
                    }
                    else { $overrides[$parameter.Name] = $entered }
                }
                if ($edited) {
                    $revision++
                    & $removePreview $preview
                    $preview = $null
                }
                continue
            }

            if ($action -eq 'C') {
                # A real driver, not a preview: the point of 'command only' is a command the
                # operator can paste, and the command line starts the driver file. So it is
                # written, kept for this form pass, and reused by the run if nothing changes.
                if ($null -eq $preview -or $preview.Revision -ne $revision -or $preview.Live -ne $isLive) {
                    & $removePreview $preview
                    $preview = [pscustomobject]@{
                        Driver   = (New-MigrationStepDriver -Step $Step -Arguments $resolved `
                                -Workspace $Workspace @driverParameters)
                        Revision = $revision
                        Live     = $isLive
                    }
                }
                Write-Host ''
                Write-Host $preview.Driver.DisplayLine
                Write-Host $preview.Driver.CommandLine
                continue
            }

            if ($action -notin @('D', 'R')) {
                Write-Host "  '$action' is not one of E, D, R, C or B." -ForegroundColor Yellow
                continue
            }

            $isLive = ($action -eq 'R')

            # Everything from here - the gates, the driver, the command preview and the run -
            # reads this one resolution, and it is resolved for the mode the operator just
            # chose rather than the one the form happened to be showing. Resolving once at the
            # top and reading the key afterwards is how a driver ends up rehearsing while the
            # ledger records a live run, and how a live run ends up cleared by a rehearsal's
            # much shorter gate list.
            if ($isLive -ne $displayedLive) {
                $resolved = Resolve-MigrationStepArguments -Step $Step -Workspace $Workspace `
                    -Override $overrides -Wave $wave -DryRun:(-not $isLive)
                Write-Host ''
                Write-Host $(if ($isLive) { 'Resolved for a live run:' } else { 'Resolved for a rehearsal:' })
                & $showArguments $resolved
            }

            # --- 3. the gates ----------------------------------------------------------------

            $gates = @(Test-MigrationStepGate -Step $Step -Arguments $resolved -Workspace $Workspace `
                    -Live:$isLive)
            if ($gates.Count -gt 0) {
                Write-Host ''
                foreach ($gate in $gates) {
                    $mark = if ($gate.Satisfied) { 'ok' } else { '!!' }
                    Write-Host ('  [{0}] {1}: {2}' -f $mark, $gate.Kind, $gate.Message)
                }
            }

            $gateOverrides = [System.Collections.Generic.List[string]]::new()
            $refused = $false

            # Soft gates first, so the typed confirmation is the last thing between the operator
            # and the run - which is where a deliberate act belongs.
            if ($isLive) {
                foreach ($gate in @($gates | Where-Object { $_.Severity -eq 'Soft' -and -not $_.Satisfied })) {
                    if ([bool](Read-MigrationPrompt -Kind 'Confirm' `
                                -Message "Override the $($gate.Kind) gate?" -Default 'n')) {
                        # The extra parentheses matter: a method call splits its arguments on
                        # commas, so without them the format operator gets only its first value.
                        $gateOverrides.Add(('{0}:{1}' -f $gate.Kind, $gate.Message))
                        continue
                    }
                    Write-Host '  The run was not started.' -ForegroundColor Yellow
                    $refused = $true
                    break
                }
            }

            if (-not $refused) {
                foreach ($gate in @($gates | Where-Object { $_.Severity -eq 'Hard' -and -not $_.Satisfied })) {
                    $required = [string]$gate.RequiredInput

                    # A hard gate exists to make the operator type something. One that names
                    # nothing to type cannot be cleared by typing, and treating "nothing
                    # expected" as "anything is accepted" would turn the strongest gate in the
                    # toolkit into no gate at all.
                    if (-not $required) {
                        Write-Host ("  The run was not started: the $($gate.Kind) gate expects a typed " +
                            'confirmation but names no input.') -ForegroundColor Red
                        $refused = $true
                        break
                    }

                    $typed = ([string](Read-MigrationPrompt -Kind 'Text' `
                                -Message "Type '$required' exactly to continue")).Trim()

                    # A domain is compared without case, because DNS has none and an operator
                    # who typed NewCo.com has typed the domain; a keyword such as REMOVE is
                    # compared with case, because shouting it is the point.
                    $accepted = if ($required -like '*.*') { $typed -ieq $required } else { $typed -ceq $required }
                    if ($accepted) { continue }

                    Write-Host "  The run was not started: '$required' was expected, not '$typed'." `
                        -ForegroundColor Red
                    $refused = $true
                    break
                }
            }

            if ($refused) { continue }

            # --- 4. the secret, the command and the last confirmation ------------------------

            $environment = $null
            $secretMapping = @()
            if (@(@($Step.Parameters) | Where-Object { $_.Name -eq 'ClientSecret' }).Count -gt 0) {
                $thumbprint = Get-MigrationStepSettingsValue -Workspace $Workspace `
                    -Key 'VivaLearning.CertificateThumbprint'
                if (-not $thumbprint) {
                    $secure = Read-MigrationPrompt -Kind 'Secret' -Message 'Client secret'
                    # Plain text only long enough to reach the child's environment block; it is
                    # never printed, never logged and never written to the driver.
                    $plain = [System.Net.NetworkCredential]::new('', $secure).Password
                    if ($plain) {
                        $environment = @{ M365MIGRATION_CLIENT_SECRET = $plain }
                        $secretMapping = @('ClientSecret=M365MIGRATION_CLIENT_SECRET')
                    }
                    else {
                        # An empty answer must not become an empty secret: the driver would fail
                        # on the conversion, and the operator would be left reading the child's
                        # log to find out that they had pressed Enter.
                        Write-Host '  No secret was entered, so none will be passed.' -ForegroundColor Yellow
                    }
                }
            }

            # The driver 'C' already wrote, when it was written for this exact state and this
            # exact mode and carries no secret; otherwise a fresh one, and the stale preview
            # goes rather than sitting in the workspace looking like a run.
            $reusable = ($null -ne $preview -and $preview.Revision -eq $revision -and
                $preview.Live -eq $isLive -and $secretMapping.Count -eq 0)
            if ($reusable) {
                $driver = $preview.Driver
                $preview = $null
            }
            else {
                & $removePreview $preview
                $preview = $null
                $driver = New-MigrationStepDriver -Step $Step -Arguments $resolved -Workspace $Workspace `
                    -SecretEnvironmentVariable $secretMapping @driverParameters
            }

            Write-Host ''
            Write-Host $driver.DisplayLine
            Write-Host $driver.CommandLine
            Write-Host ''

            if (-not [bool](Read-MigrationPrompt -Kind 'Confirm' -Message 'Run now?' -Default 'y')) {
                Write-Host '  The run was not started.' -ForegroundColor Yellow
                # The driver just written is this form pass's preview from here on, so it is
                # reused or removed like any other rather than left behind.
                $preview = [pscustomobject]@{ Driver = $driver; Revision = $revision; Live = $isLive }
                # A driver carrying a secret mapping is never reused: the next pass may not be
                # given a secret at all, and the file would then bind an empty one.
                if ($secretMapping.Count -gt 0) {
                    & $removePreview $preview
                    $preview = $null
                }
                continue
            }

            # --- 5. the run ------------------------------------------------------------------

            $runParameters = @{
                Step          = $Step
                Driver        = $driver
                Workspace     = $Workspace
                OutputWriter  = { param($Line) Write-Host $Line }
                Wave          = @($wave)
                GateOverrides = @($gateOverrides)
            }
            # Both passed explicitly, even when false or null: a runner that behaved differently
            # for an unbound switch than for -DryRun:$false would be a difference nothing can see.
            $runParameters['DryRun'] = (-not $isLive)
            $runParameters['Environment'] = $environment

            if ([string]$Step.Side -in @('Source', 'Destination')) {
                $expected = [string](Get-MigrationStepSettingsValue -Workspace $Workspace `
                        -Key ('{0}.TenantId' -f $Step.Side))
                if ($expected) { $runParameters['ExpectedTenantId'] = $expected }
            }

            Write-Host ''
            $result = Invoke-MigrationStep @runParameters

            # The secret's last reference in this process; the child has its own copy and this
            # one has no further use.
            $environment = $null

            Write-Host ''
            Write-Host ('Exit {0}: {1}' -f $result.ExitCode, $result.Meaning)

            $summary = Get-MigrationProperty -InputObject $result -Name 'Summary' -Default $null
            $counts = [System.Collections.Generic.List[string]]::new()
            foreach ($name in @('Planned', 'Succeeded', 'Failed', 'Skipped')) {
                $count = [int](Get-MigrationProperty -InputObject $summary -Name $name -Default 0)
                if ($count -gt 0) { $counts.Add("$count $name") }
            }
            if ($counts.Count -gt 0) { Write-Host ('  ' + ($counts -join ', ')) }

            foreach ($file in @($result.Files)) { Write-Host "  wrote $file" }
            Write-Host "  log  $($result.StdoutPath)"

            $verified = Get-MigrationProperty -InputObject $result -Name 'TenantVerified' -Default $null
            if ($verified -eq $false) {
                Write-Host ''
                Write-Host '!! TENANT MISMATCH' -ForegroundColor Red
                $connected = @($result.ConnectedTenantIds)
                $text = if ($connected.Count -gt 0) { $connected -join ', ' } else { 'no tenant at all' }
                Write-Host "   This run signed in to $text, which is not the tenant it was given." `
                    -ForegroundColor Red
            }
            elseif ($verified -eq $true) {
                Write-Host '  tenant verified'
            }

            return $result
        }
    }
    catch {
        # Printed rather than thrown: the workbench is the operator's whole session, and a step
        # that could not be resolved, driven or run must cost them the step and not the board.
        Write-Host ''
        Write-Host "  This step could not be run: $($_.Exception.Message)" -ForegroundColor Red
        & $removePreview $preview
        return $null
    }
}
