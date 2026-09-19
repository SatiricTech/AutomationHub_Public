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
          4. The command, printed as both the line an operator would have typed and the one
             that will actually start the child, and then one last confirmation.
          5. The outcome: what the exit code means, what was counted, what was written, and -
             loudly - whether the child reached the tenant it was supposed to.

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

    $overrides = @{}
    $isLive = [bool]$Live
    $resolved = $null

    while ($true) {
        $resolveParameters = @{
            Step = $Step; Workspace = $Workspace; Override = $overrides; Wave = $wave
            DryRun = (-not $isLive)
        }
        $resolved = Resolve-MigrationStepArguments @resolveParameters

        Write-Host ''
        Write-Host ('{0} - {1}' -f $Step.Id, $Step.Title)
        Write-Host ('{0} · {1} tenant · impact {2}' -f
            [System.IO.Path]::GetFileName([string]$Step.ScriptPath), $Step.Side, $Step.Impact)
        if ($Step.Notes) { Write-Host ('  ' + [string]$Step.Notes) -ForegroundColor DarkGray }
        Write-Host ''

        $names = @(@($resolved.Arguments) | ForEach-Object { ([string]$_.Name).Length })
        $width = (@($names + 8) | Measure-Object -Maximum).Maximum
        foreach ($argument in @($resolved.Arguments)) {
            Write-Host ('  {0}  {1}  ({2})' -f ([string]$argument.Name).PadRight($width),
                (& $renderValue $argument.Value), $argument.Source)
            $warning = [string](Get-MigrationProperty -InputObject $argument -Name 'Warning' -Default '')
            if ($warning) { Write-Host ('  ' + ' ' * $width + '  ' + $warning) -ForegroundColor Yellow }
        }

        foreach ($warning in @($resolved.Warnings)) { Write-Host "  ! $warning" -ForegroundColor Yellow }

        $missing = @($resolved.MissingMandatory)
        if ($missing.Count -gt 0) {
            Write-Host ''
            Write-Host ("  This run still needs: " + ($missing -join ', ')) -ForegroundColor Red
        }

        Write-Host ''
        $action = ([string](Read-MigrationPrompt -Kind 'Text' `
                    -Message '[E] edit a value  [D] dry run  [R] run  [C] command only  [B] back' `
                    -Default $(if ($isLive) { 'R' } else { 'D' }))).Trim().ToUpperInvariant()

        if ($action -eq 'B') { return $null }

        if ($action -eq 'E') {
            $typed = ([string](Read-MigrationPrompt -Kind 'Text' -Message 'Which parameter?')).Trim()
            $match = @(@($Step.Parameters) | Where-Object { $_.Name -ieq $typed })
            if ($match.Count -eq 0) {
                Write-Host "  '$typed' is not a parameter of $($Step.Script)." -ForegroundColor Yellow
                continue
            }

            $parameter = $match[0]
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
                    }
                }
                else { $overrides[$parameter.Name] = $entered }
            }
            continue
        }

        if ($action -eq 'C') {
            # A real driver, not a preview: the point of "command only" is a command the
            # operator can paste, and the command line starts the driver file.
            $preview = New-MigrationStepDriver -Step $Step -Arguments $resolved -Workspace $Workspace `
                @driverParameters
            Write-Host ''
            Write-Host $preview.DisplayLine
            Write-Host $preview.CommandLine
            continue
        }

        if ($action -notin @('D', 'R')) {
            Write-Host "  '$action' is not one of E, D, R, C or B." -ForegroundColor Yellow
            continue
        }

        $isLive = ($action -eq 'R')

        # --- 3. the gates --------------------------------------------------------------------

        $gates = @(Test-MigrationStepGate -Step $Step -Arguments $resolved -Workspace $Workspace -Live:$isLive)
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
                $typed = ([string](Read-MigrationPrompt -Kind 'Text' `
                            -Message "Type '$required' exactly to continue")).Trim()

                # A domain is compared without case, because a domain has none; a keyword such
                # as REMOVE is compared with it, because shouting it is the point.
                $accepted = if ($required -like '*.*') { $typed -ieq $required } else { $typed -ceq $required }
                if ($accepted) { continue }

                Write-Host "  The run was not started: '$required' was expected, not '$typed'." `
                    -ForegroundColor Red
                $refused = $true
                break
            }
        }

        if ($refused) { continue }

        # --- 4. the secret, the command and the last confirmation ----------------------------

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
                    # An empty answer must not become an empty secret: the driver would fail on
                    # the conversion, and the operator would be left reading the child's log to
                    # find out that they had pressed Enter.
                    Write-Host '  No secret was entered, so none will be passed.' -ForegroundColor Yellow
                }
            }
        }

        $driver = New-MigrationStepDriver -Step $Step -Arguments $resolved -Workspace $Workspace `
            -SecretEnvironmentVariable $secretMapping @driverParameters

        Write-Host ''
        Write-Host $driver.DisplayLine
        Write-Host $driver.CommandLine
        Write-Host ''

        if (-not [bool](Read-MigrationPrompt -Kind 'Confirm' -Message 'Run now?' -Default 'y')) {
            Write-Host '  The run was not started.' -ForegroundColor Yellow
            continue
        }

        # --- 5. the run ----------------------------------------------------------------------

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

        # The secret's last reference in this process; the child has its own copy and this one
        # has no further use.
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
