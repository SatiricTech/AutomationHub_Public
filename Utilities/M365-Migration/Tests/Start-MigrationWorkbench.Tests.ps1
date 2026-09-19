#Requires -Version 7.4

<#
    The entry script: mode selection, the recent-workspace list and non-interactive runs.

    Two shapes are used, as Docs/Workbench-Design.md section 10 and the toolkit's own test
    conventions require:

      * The pure helpers are dot-sourced with -NoGui, which is exactly what that switch exists
        for - it loads the functions and builds no UI, so they can be exercised on macOS.
      * The Main region is invoked with the call operator against a scope-shadowing
        Invoke-MigrationStep defined in BeforeAll. PowerShell resolves a command from the
        innermost scope outwards, so that function wins over the module's exported one for
        everything the script calls, while the settings loader, the workspace scanner, the
        argument resolver, the gates and the driver writer all run for real. That is the
        point: the driver on disk is the evidence of what the run would have been.

    'exit' inside a script invoked with '&' ends that script only, so $LASTEXITCODE is readable
    and Pester carries on. Errors are captured by merging the error stream into the output
    stream (2>&1), which is how the stderr assertions below read what an operator would see.

    The workspace is always a copy of Tests/Fixtures/Workbench/Workspace1 under TestDrive: a
    run writes a driver, a log and a Workbench folder, and the committed fixture must stay
    exactly as scanned.

    Call logs live in $global: because a function defined in BeforeAll does not share the
    $script: scope Pester gives the It blocks.

    Author: AutomationHub
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Stubs defined in BeforeAll cannot see the $script: scope Pester gives the It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stub must bind every parameter the script passes, asserted on or not.')]
param()

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Start-MigrationWorkbench.ps1')).Path
    $script:FixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Workspace1')).Path

    # What the shadow saw, and what it should hand back. Reset before every run.
    $global:WorkbenchStepRuns = [System.Collections.Generic.List[object]]::new()
    $global:WorkbenchStepExitCode = 0
    $global:WorkbenchStepAborted = $false

    function Invoke-MigrationStep {
        param(
            $Step,
            $Driver,
            $Workspace,
            [string]$ExpectedTenantId,
            [scriptblock]$OutputWriter,
            [scriptblock]$Pump,
            [hashtable]$Environment,
            [int]$PollMilliseconds,
            [scriptblock]$CancelIf,
            [string[]]$GateOverrides,
            [string[]]$Wave,
            [switch]$DryRun
        )

        $global:WorkbenchStepRuns.Add([pscustomobject]@{
                StepId           = [string]$Step.Id
                DryRun           = [bool]$DryRun
                Wave             = @($Wave)
                GateOverrides    = @($GateOverrides)
                ExpectedTenantId = [string]$ExpectedTenantId
                DriverPath       = [string]$Driver.DriverPath
                HasEnvironment   = ($null -ne $Environment)
            })

        return [pscustomobject]@{
            ExitCode           = $global:WorkbenchStepExitCode
            Meaning            = 'Recorded by the test shadow'
            Aborted            = $global:WorkbenchStepAborted
            Files              = @()
            StdoutPath         = 'stdout.log'
            Summary            = $null
            TenantVerified     = $null
            ConnectedTenantIds = @()
        }
    }

    function Copy-FixtureWorkspace {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that copies the fixture into TestDrive.')]
        param([string]$Name)
        $destination = Join-Path $TestDrive $Name
        Copy-Item -LiteralPath $script:FixtureRoot -Destination $destination -Recurse -Force
        return $destination
    }

    # One non-interactive run, with the shadow's log cleared first and everything the operator
    # would have seen - host output and errors alike - captured as text.
    function Invoke-WorkbenchScript {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that runs the entry script under test.')]
        param([hashtable]$Parameter)

        $global:WorkbenchStepRuns = [System.Collections.Generic.List[object]]::new()
        $output = & $script:ScriptPath @Parameter 2>&1 | Out-String
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
            Runs     = @($global:WorkbenchStepRuns)
        }
    }
}

AfterAll {
    Remove-Variable -Scope Global -ErrorAction SilentlyContinue -Name `
        WorkbenchStepRuns, WorkbenchStepExitCode, WorkbenchStepAborted
}

Describe 'Start-MigrationWorkbench helpers (dot-sourced with -NoGui)' {

    BeforeAll {
        . $script:ScriptPath -NoGui
    }

    Context 'Select-WorkbenchMode' {

        It 'Chooses NonInteractive whenever a step is named, console or not' {
            Select-WorkbenchMode -Step 'New-Users' -OnWindows $true | Should -BeExactly 'NonInteractive'
            Select-WorkbenchMode -Step 'New-Users' -Console -OnWindows $false |
                Should -BeExactly 'NonInteractive'
        }

        It 'Chooses Gui on Windows when no step and no -Console' {
            Select-WorkbenchMode -OnWindows $true | Should -BeExactly 'Gui'
        }

        It 'Chooses Console on Windows when -Console forces it' {
            Select-WorkbenchMode -Console -OnWindows $true | Should -BeExactly 'Console'
        }

        It 'Chooses Console off Windows, where there is no window to open' {
            Select-WorkbenchMode -OnWindows $false | Should -BeExactly 'Console'
        }
    }

    Context 'Test-WorkbenchWindows' {

        It 'Agrees with the host it is running on' {
            Test-WorkbenchWindows | Should -Be ([bool]$IsWindows)
        }
    }

    Context 'Resolve-WorkbenchWorkspacePath' {

        It 'Returns the absolute path of a folder that exists' {
            $folder = Join-Path $TestDrive 'Resolvable'
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $resolved = Resolve-WorkbenchWorkspacePath -Workspace $folder -Mode 'Console'
            $resolved.Problem | Should -BeExactly ''
            $resolved.Path | Should -BeExactly ((Resolve-Path -LiteralPath $folder).Path)
        }

        It 'Refuses a workspace folder that is not there, naming it' {
            $missing = Join-Path $TestDrive 'NoSuchWorkspace'
            $resolved = Resolve-WorkbenchWorkspacePath -Workspace $missing -Mode 'NonInteractive'
            $resolved.Path | Should -BeNullOrEmpty
            $resolved.Problem | Should -BeLike "*NoSuchWorkspace*"
        }

        It 'Refuses a non-interactive run with no workspace at all' {
            $resolved = Resolve-WorkbenchWorkspacePath -Workspace '' -Mode 'NonInteractive'
            $resolved.Path | Should -BeNullOrEmpty
            $resolved.Problem | Should -BeLike '*-Workspace is required*'
        }

        It 'Leaves the console to pick when no workspace was given' {
            $resolved = Resolve-WorkbenchWorkspacePath -Workspace '' -Mode 'Console'
            $resolved.Path | Should -BeNullOrEmpty
            $resolved.Problem | Should -BeExactly ''
        }
    }

    Context 'The recent-workspace list' {

        BeforeEach {
            # The helpers read the file location from a script-scoped variable so the suite can
            # keep the operator's real list out of the way.
            $script:WorkbenchRecentPath = Join-Path $TestDrive (
                'recent-{0}.json' -f [guid]::NewGuid().ToString('N'))
        }

        It 'Reads an empty list when nothing has been remembered yet' {
            @(Get-WorkbenchRecentWorkspace) | Should -HaveCount 0
        }

        It 'Puts the newest workspace first' {
            Add-WorkbenchRecentWorkspace -Path (Join-Path $TestDrive 'One')
            Add-WorkbenchRecentWorkspace -Path (Join-Path $TestDrive 'Two')
            $recent = @(Get-WorkbenchRecentWorkspace)
            $recent | Should -HaveCount 2
            $recent[0] | Should -BeExactly (Join-Path $TestDrive 'Two')
        }

        It 'Moves a workspace already in the list back to the top rather than repeating it' {
            Add-WorkbenchRecentWorkspace -Path (Join-Path $TestDrive 'One')
            Add-WorkbenchRecentWorkspace -Path (Join-Path $TestDrive 'Two')
            Add-WorkbenchRecentWorkspace -Path (Join-Path $TestDrive 'One')
            $recent = @(Get-WorkbenchRecentWorkspace)
            $recent | Should -HaveCount 2
            $recent[0] | Should -BeExactly (Join-Path $TestDrive 'One')
        }

        It 'Keeps at most ten, dropping the oldest' {
            1..12 | ForEach-Object { Add-WorkbenchRecentWorkspace -Path (Join-Path $TestDrive "W$_") }
            $recent = @(Get-WorkbenchRecentWorkspace)
            $recent | Should -HaveCount 10
            $recent[0] | Should -BeExactly (Join-Path $TestDrive 'W12')
            $recent | Should -Not -Contain (Join-Path $TestDrive 'W1')
        }

        It 'Round-trips a list of one as a list, not as a bare string' {
            Add-WorkbenchRecentWorkspace -Path (Join-Path $TestDrive 'Only')
            $recent = @(Get-WorkbenchRecentWorkspace)
            $recent | Should -HaveCount 1
            $recent[0] | Should -BeExactly (Join-Path $TestDrive 'Only')
        }

        It 'Reads an empty list rather than throwing when the file is not JSON' {
            Set-Content -LiteralPath $script:WorkbenchRecentPath -Value 'not json at all'
            @(Get-WorkbenchRecentWorkspace) | Should -HaveCount 0
        }
    }
}

Describe 'Start-MigrationWorkbench - the workspace picker' {

    # The picker asks through Read-MigrationPrompt, so Set-MigrationPromptHandler is the whole
    # operator. Its menu is host output, captured by merging the information stream into the
    # output stream and then telling the two apart by record type - no Write-Host shadow, which
    # would also have meant overriding a built-in cmdlet in a file the analyzer reads.
    #
    # Get-MigrationDefaultOutputRoot is shadowed in the same scope the script is dot-sourced
    # into: a function resolves a command through the scope chain it was defined in, so a shadow
    # one block further down would never be reached.
    BeforeAll {
        . $script:ScriptPath -NoGui

        $script:WorkbenchRecentPath = Join-Path $TestDrive 'picker-recent.json'

        $script:PickerRoot = Join-Path $TestDrive 'PickerRoot'
        foreach ($name in @('Alpha', 'Beta')) {
            New-Item -ItemType Directory -Path (Join-Path $script:PickerRoot $name) -Force | Out-Null
        }

        function Get-MigrationDefaultOutputRoot { return $script:PickerRoot }

        # A scripted operator: the answers in order, and an exception the moment the picker asks
        # for one more than the test was written for, so a loop that never ends fails in a second
        # instead of hanging the suite. GetNewClosure keeps the queue alive after this returns.
        function Set-PickerAnswer {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Pester helper that installs the prompt handler for one picker session.')]
            param([string[]]$Answer)

            $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$Answer)
            Set-MigrationPromptHandler -Handler {
                param($Kind, $Message, $Choices, $Default)
                if ($queue.Count -eq 0) { throw "The picker asked one question too many: '$Message'." }
                $queue.Dequeue()
            }.GetNewClosure()
        }

        # Splits one picker session into what it returned and what it printed.
        function Invoke-Picker {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Pester helper that runs the picker and separates its streams.')]
            param([string[]]$Answer)

            Set-PickerAnswer -Answer $Answer
            $captured = @(Select-WorkbenchWorkspace 6>&1)
            $isMenu = { $args[0] -is [System.Management.Automation.InformationRecord] }
            # A picker the operator quit returns $null, which survives @() as one empty entry;
            # dropping the blanks is what makes 'chose nothing' an empty collection.
            return [pscustomobject]@{
                Chosen  = @($captured | Where-Object { -not (& $isMenu $_) } |
                        ForEach-Object { [string]$_ } | Where-Object { $_ })
                Printed = @($captured | Where-Object { & $isMenu $_ } | ForEach-Object { [string]$_ }) -join ' '
            }
        }
    }

    AfterAll {
        Set-MigrationPromptHandler
    }

    It 'Returns nothing when the operator quits' {
        (Invoke-Picker -Answer @('Q')).Chosen | Should -HaveCount 0
    }

    It 'Lists the folders under the default output root and returns the one chosen' {
        $session = Invoke-Picker -Answer @('2')
        $session.Chosen | Should -Be @((Join-Path $script:PickerRoot 'Beta'))
        $session.Printed | Should -BeLike '*Alpha*'
    }

    It 'Puts a remembered workspace above the folders under the root' {
        Add-WorkbenchRecentWorkspace -Path (Join-Path $script:PickerRoot 'Beta')
        (Invoke-Picker -Answer @('1')).Chosen | Should -Be @((Join-Path $script:PickerRoot 'Beta'))
    }

    It 'Takes a typed path that exists' {
        $elsewhere = Join-Path $TestDrive 'TypedWorkspace'
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        (Invoke-Picker -Answer @('P', $elsewhere)).Chosen |
            Should -Be @((Resolve-Path -LiteralPath $elsewhere).Path)
    }

    It 'Re-asks after a typed path that is not there, rather than creating it' {
        $missing = Join-Path $TestDrive 'TypedButAbsent'
        $session = Invoke-Picker -Answer @('P', $missing, 'Q')
        $session.Chosen | Should -HaveCount 0
        Test-Path -LiteralPath $missing | Should -BeFalse
        $session.Printed | Should -BeLike '*does not exist*'
    }

    It 'Creates a new workspace under the root from a label' {
        $session = Invoke-Picker -Answer @('N', 'Fabrikam')
        $session.Chosen | Should -Be @((Join-Path $script:PickerRoot 'Fabrikam'))
        Test-Path -LiteralPath $session.Chosen[0] -PathType Container | Should -BeTrue
    }

    It 'Refuses a label that is not a folder name and re-asks' {
        $session = Invoke-Picker -Answer @('N', "bad`0name", 'Q')
        $session.Chosen | Should -HaveCount 0
        $session.Printed | Should -BeLike '*not usable as a folder name*'
    }

    It 'Re-asks on an answer that is neither a number nor a key' {
        $session = Invoke-Picker -Answer @('zz', 'Q')
        $session.Chosen | Should -HaveCount 0
        $session.Printed | Should -BeLike '*is not one of the numbers*'
    }
}

Describe 'Start-MigrationWorkbench Main - a rehearsal of a step that clears its gates' {

    BeforeAll {
        $script:DryRunWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveDryRun'
        $script:DryRunResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:DryRunWorkspace
            Step      = 'New-Users'
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    It 'Exits with the step exit code' {
        $script:DryRunResult.ExitCode | Should -Be 0
    }

    It 'Ran the step exactly once' {
        $script:DryRunResult.Runs | Should -HaveCount 1
        $script:DryRunResult.Runs[0].StepId | Should -BeExactly 'New-Users'
    }

    It 'Told the runner it was a rehearsal' {
        $script:DryRunResult.Runs[0].DryRun | Should -BeTrue
    }

    It 'Passed the destination tenant as the tenant to verify' {
        $script:DryRunResult.Runs[0].ExpectedTenantId |
            Should -BeExactly '00000000-0000-0000-0000-000000000000'
    }

    It 'Generated a real driver for the run' {
        $script:DryRunResult.Runs[0].DriverPath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:DryRunResult.Runs[0].DriverPath | Should -BeTrue
    }

    It 'Wrote its own log under the workspace Workbench folder' {
        @(Get-ChildItem -LiteralPath (Join-Path $script:DryRunWorkspace 'Workbench') -Filter '*.log') |
            Should -Not -BeNullOrEmpty
    }
}

Describe 'Start-MigrationWorkbench Main - the step exit code is the script exit code' {

    BeforeAll {
        $global:WorkbenchStepExitCode = 2
        $script:ExitWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveExitCode'
        $script:ExitResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:ExitWorkspace
            Step      = 'New-Users'
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    AfterAll {
        $global:WorkbenchStepExitCode = 0
    }

    It 'Hands the step exit code back to the caller' {
        $script:ExitResult.ExitCode | Should -Be 2
    }
}

Describe 'Start-MigrationWorkbench Main - a run the operator aborted' {

    BeforeAll {
        $global:WorkbenchStepAborted = $true
        $script:AbortWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveAborted'
        $script:AbortResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:AbortWorkspace
            Step      = 'New-Users'
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    AfterAll {
        $global:WorkbenchStepAborted = $false
    }

    It 'Exits 130, the shell convention for a run that was interrupted' {
        $script:AbortResult.ExitCode | Should -Be 130
    }
}

Describe 'Start-MigrationWorkbench Main - a step id that is not in the catalogue' {

    BeforeAll {
        $script:UnknownWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveUnknownStep'
        $script:UnknownResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:UnknownWorkspace
            Step      = 'Nope'
            Verbosity = 'Low'
        }
    }

    It 'Exits 2' {
        $script:UnknownResult.ExitCode | Should -Be 2
    }

    It 'Names the id it was given and lists the ones it knows' {
        $script:UnknownResult.Output | Should -BeLike '*Nope*'
        $script:UnknownResult.Output | Should -BeLike '*New-Users*'
    }

    It 'Runs nothing' {
        $script:UnknownResult.Runs | Should -HaveCount 0
    }
}

Describe 'Start-MigrationWorkbench Main - a hard gate with nothing typed' {

    BeforeAll {
        $script:GateWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveHardGate'
        $script:GateResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:GateWorkspace
            Step      = 'DomainReferences-Remediate'
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    It 'Exits 2' {
        $script:GateResult.ExitCode | Should -Be 2
    }

    It 'Names the release domain the operator has to acknowledge' {
        $script:GateResult.Output | Should -BeLike '*newco.com*'
    }

    It 'Names the Acknowledge key, so the operator knows how to answer' {
        $script:GateResult.Output | Should -BeLike '*Acknowledge*'
    }

    It 'Runs nothing' {
        $script:GateResult.Runs | Should -HaveCount 0
    }
}

Describe 'Start-MigrationWorkbench Main - a hard gate acknowledged in the wrong case' {

    BeforeAll {
        $script:AckWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveAcknowledged'
        $script:AckResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:AckWorkspace
            Step      = 'DomainReferences-Remediate'
            DryRun    = $true
            Verbosity = 'Low'
            Set       = @{ Acknowledge = 'NEWCO.COM' }
        }
    }

    # DNS has no case, so an operator who typed NEWCO.COM typed the domain.
    It 'Accepts the domain without case and runs the step' {
        $script:AckResult.Runs | Should -HaveCount 1
        $script:AckResult.Runs[0].StepId | Should -BeExactly 'DomainReferences-Remediate'
    }

    It 'Exits with the step exit code' {
        $script:AckResult.ExitCode | Should -Be 0
    }

    It 'Records the soft gate it warned past as an override' {
        @($script:AckResult.Runs[0].GateOverrides) | Should -Not -BeNullOrEmpty
        ($script:AckResult.Runs[0].GateOverrides -join ' ') | Should -BeLike '*Prerequisite*'
    }

    It 'Did not pass Acknowledge on to the script as a parameter override' {
        # Acknowledge is the workbench's own key; a driver carrying it would not bind. Matched as
        # a splat key rather than as text, because the step really does fix the script's own
        # -AcknowledgeSourceTenant and that one belongs in the driver.
        $driver = Get-Content -LiteralPath $script:AckResult.Runs[0].DriverPath -Raw
        $driver | Should -Not -Match '(?m)^\s*Acknowledge\s*='
        $driver | Should -Match '(?m)^\s*AcknowledgeSourceTenant\s*='
    }
}

Describe 'Start-MigrationWorkbench Main - a step named with no workspace' {

    BeforeAll {
        $script:NoWorkspaceResult = Invoke-WorkbenchScript -Parameter @{
            Step      = 'New-Users'
            Verbosity = 'Low'
        }
    }

    It 'Exits 2' {
        $script:NoWorkspaceResult.ExitCode | Should -Be 2
    }

    It 'Says that -Workspace is required' {
        $script:NoWorkspaceResult.Output | Should -BeLike '*-Workspace is required*'
    }

    It 'Runs nothing' {
        $script:NoWorkspaceResult.Runs | Should -HaveCount 0
    }
}

Describe 'Start-MigrationWorkbench Main - a workspace folder that is not there' {

    BeforeAll {
        $script:MissingResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = (Join-Path $TestDrive 'NotAWorkspaceAtAll')
            Step      = 'New-Users'
            Verbosity = 'Low'
        }
    }

    It 'Exits 2 and names the folder' {
        $script:MissingResult.ExitCode | Should -Be 2
        $script:MissingResult.Output | Should -BeLike '*NotAWorkspaceAtAll*'
    }
}

Describe 'Start-MigrationWorkbench Main - a parameter override from -Set' {

    BeforeAll {
        $script:OverrideWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveOverride'
        $script:OverrideResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:OverrideWorkspace
            Step      = 'New-Users'
            DryRun    = $true
            Verbosity = 'Low'
            Set       = @{ PasswordLength = 20 }
        }
    }

    It 'Puts the operator value in the driver, above the settings default of 16' {
        $script:OverrideResult.Runs | Should -HaveCount 1
        Get-Content -LiteralPath $script:OverrideResult.Runs[0].DriverPath -Raw |
            Should -Match '(?m)^\s*PasswordLength\s*=\s*20\s*$'
    }
}

Describe 'Start-MigrationWorkbench Main - settings that will not load' {

    BeforeAll {
        $script:BadSettingsWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveBadSettings'
        Set-Content -LiteralPath (Join-Path $script:BadSettingsWorkspace 'M365Migration.settings.json') `
            -Value '{ this is not json'
        $script:BadSettingsResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:BadSettingsWorkspace
            Step      = 'New-Users'
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    It 'Exits 2 and says the settings cannot be used' {
        $script:BadSettingsResult.ExitCode | Should -Be 2
        $script:BadSettingsResult.Output | Should -BeLike '*settings*'
    }

    It 'Runs nothing' {
        $script:BadSettingsResult.Runs | Should -HaveCount 0
    }
}

Describe 'Start-MigrationWorkbench Main - a wave-limited run' {

    BeforeAll {
        $script:WaveWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveWave'
        $script:WaveResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:WaveWorkspace
            Step      = 'New-Users'
            Wave      = @('1')
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    It 'Passes the waves through to the runner, so the ledger records them' {
        $script:WaveResult.Runs | Should -HaveCount 1
        @($script:WaveResult.Runs[0].Wave) | Should -Be @('1')
    }
}

Describe 'Start-MigrationWorkbench GUI helpers (dot-sourced with -NoGui)' {

    <#
        The WinForms region cannot be run on macOS, and it is not meant to be: the window is
        built by exactly one function and everything it decides is decided by a pure helper that
        can. These are those helpers.

        Every variable here is deliberately named something the entry script's own param block
        does not declare. Dot-sourcing a script brings its parameters into this scope with their
        declared types, so a $step of our own would be coerced to [string] by the script's
        -Step and every property read off it would then fail.
    #>

    BeforeAll {
        . $script:ScriptPath -NoGui

        $script:GuiWorkspace = Get-MigrationWorkspace -Path $script:FixtureRoot

        # The shape Get-MigrationScriptParameter returns, built by hand so the corner cases the
        # 17 scripts do not happen to contain - a folder parameter, an array with a ValidateSet -
        # are still covered.
        function New-GuiParameterStub {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Pester helper that builds an in-memory parameter object.')]
            param(
                [string]$Name,
                [string]$TypeName = 'String',
                [bool]$IsSwitch = $false,
                [bool]$IsBool = $false,
                [bool]$IsArray = $false,
                [bool]$IsHashtable = $false,
                [string[]]$ValidValues = @()
            )

            return [pscustomobject]@{
                Name          = $Name
                TypeName      = $TypeName
                IsSwitch      = $IsSwitch
                IsBool        = $IsBool
                IsArray       = $IsArray
                IsHashtable   = $IsHashtable
                Mandatory     = $false
                MandatoryIn   = @()
                ParameterSets = @()
                ValidValues   = @($ValidValues)
                Pattern       = $null
                Range         = $null
                Default       = $null
                Aliases       = @()
                Help          = ''
                Common        = $false
            }
        }
    }

    Context 'The -NoGui guard' {

        It 'Loads the GUI helpers without building anything' {
            foreach ($name in @('Start-MigrationWorkbenchGui', 'Get-WorkbenchGuiStepList',
                    'ConvertTo-WorkbenchGuiControlKind', 'Format-WorkbenchGuiBanner',
                    'ConvertTo-WorkbenchGuiOverride', 'Test-WorkbenchGuiTypedConfirmation')) {
                Get-Command -Name $name -CommandType Function | Should -Not -BeNullOrEmpty
            }
        }

        It 'Leaves the window state empty, because no window was built' {
            $script:Gui | Should -BeNullOrEmpty
            $script:PaneWriter | Should -BeNullOrEmpty
            $script:UiPump | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-WorkbenchGuiControlKind' {

        It 'Offers a tick for a switch and for a [bool]' {
            ConvertTo-WorkbenchGuiControlKind -Parameter (
                New-GuiParameterStub -Name 'Force' -TypeName 'SwitchParameter' -IsSwitch $true) |
                Should -BeExactly 'CheckBox'
            ConvertTo-WorkbenchGuiControlKind -Parameter (
                New-GuiParameterStub -Name 'AutoMapping' -TypeName 'Boolean' -IsBool $true) |
                Should -BeExactly 'CheckBox'
        }

        It 'Offers the script''s own list rather than a box to type it into' {
            ConvertTo-WorkbenchGuiControlKind -Parameter (
                New-GuiParameterStub -Name 'Stage' -ValidValues @('Pre', 'Provisioned', 'Post')) |
                Should -BeExactly 'ComboBox'
        }

        It 'Offers a checked list when the list takes several values' {
            ConvertTo-WorkbenchGuiControlKind -Parameter (
                New-GuiParameterStub -Name 'Scope' -TypeName 'String[]' -IsArray $true `
                    -ValidValues @('Users', 'Groups')) |
                Should -BeExactly 'CheckedListBox'
        }

        It 'Offers a file picker for a path, a CSV and a file parameter' {
            foreach ($name in @('PlanPath', 'UsersCsv', 'ReferenceFile')) {
                ConvertTo-WorkbenchGuiControlKind -Parameter (New-GuiParameterStub -Name $name) |
                    Should -BeExactly 'FilePicker'
            }
        }

        It 'Offers a folder picker for -OutputPath, which ends in Path but is a folder' {
            ConvertTo-WorkbenchGuiControlKind -Parameter (New-GuiParameterStub -Name 'OutputPath') |
                Should -BeExactly 'FolderPicker'
            ConvertTo-WorkbenchGuiControlKind -Parameter (New-GuiParameterStub -Name 'ReportFolder') |
                Should -BeExactly 'FolderPicker'
        }

        It 'Offers the two-column editor for a hashtable' {
            ConvertTo-WorkbenchGuiControlKind -Parameter (
                New-GuiParameterStub -Name 'AliasDomainMap' -TypeName 'Hashtable' -IsHashtable $true) |
                Should -BeExactly 'MapEditor'
        }

        It 'Falls back to a text box' {
            ConvertTo-WorkbenchGuiControlKind -Parameter (New-GuiParameterStub -Name 'TargetDomain') |
                Should -BeExactly 'TextBox'
        }

        It 'Maps every non-common parameter of all 17 scripts to a control it knows' {
            $kinds = @('CheckBox', 'ComboBox', 'CheckedListBox', 'FilePicker', 'FolderPicker',
                'MapEditor', 'TextBox')
            foreach ($entry in @(Get-MigrationStep)) {
                foreach ($parameter in @($entry.Parameters | Where-Object { -not $_.Common })) {
                    ConvertTo-WorkbenchGuiControlKind -Parameter $parameter | Should -BeIn $kinds
                }
            }
        }
    }

    Context 'Get-WorkbenchGuiStepList' {

        It 'Lists exactly the steps the engine lists for the workspace''s scenario' {
            $guiIds = @((Get-WorkbenchGuiStepList -Workspace $script:GuiWorkspace).Steps.Id)
            $engineIds = @((Get-MigrationStep -Scenario 'TenantToTenant').Id)
            $guiIds | Should -Be $engineIds
        }

        It 'Groups them by phase, in the runbook''s order' {
            $phases = @((Get-WorkbenchGuiStepList -Workspace $script:GuiWorkspace).Phase)
            $phases | Should -Be @('Discover', 'Plan', 'Prepare', 'Cutover')
        }

        It 'Carries the console''s own glyph and last-run line for each step' {
            $entries = @((Get-WorkbenchGuiStepList -Workspace $script:GuiWorkspace).Steps)
            $inventory = @($entries | Where-Object { $_.Id -eq 'Inventory-Source' })[0]
            $inventory.Glyph | Should -BeExactly '[x]'
            $inventory.LastRun | Should -Not -BeNullOrEmpty
        }

        It 'Marks exactly the step the scanner called next' {
            $entries = @((Get-WorkbenchGuiStepList -Workspace $script:GuiWorkspace).Steps)
            $flagged = @($entries | Where-Object { $_.IsNext } | ForEach-Object { $_.Id })
            $flagged | Should -Be @($script:GuiWorkspace.NextStepId)
        }
    }

    Context 'Format-WorkbenchGuiBanner' {

        It 'Paints a source-side step amber and names the tenant' {
            $banner = Format-WorkbenchGuiBanner -Step (Get-MigrationStep -Id 'DomainReferences-Remediate') `
                -Settings $script:GuiWorkspace.Settings
            $banner.Colour | Should -BeExactly 'Amber'
            $banner.Text | Should -BeLike 'SOURCE*contoso.onmicrosoft.com*'
        }

        It 'Paints a destination-side step blue' {
            $banner = Format-WorkbenchGuiBanner -Step (Get-MigrationStep -Id 'New-Users') `
                -Settings $script:GuiWorkspace.Settings
            $banner.Colour | Should -BeExactly 'Blue'
            $banner.Text | Should -BeLike 'DESTINATION*newco.onmicrosoft.com*'
        }

        It 'Paints an offline step grey and says it signs in to nothing' {
            $banner = Format-WorkbenchGuiBanner -Step (Get-MigrationStep -Id 'New-IdentityPlan') `
                -Settings $script:GuiWorkspace.Settings
            $banner.Colour | Should -BeExactly 'Grey'
            $banner.Text | Should -BeLike 'OFFLINE*'
        }

        It 'Says so plainly when the settings hold no tenant for that side' {
            $banner = Format-WorkbenchGuiBanner -Step (Get-MigrationStep -Id 'New-Users') -Settings $null
            $banner.Colour | Should -BeExactly 'Blue'
            $banner.Text | Should -BeLike '*not set*'
        }

        It 'Has something to show before a step is picked' {
            (Format-WorkbenchGuiBanner -Step $null -Settings $null).Colour | Should -BeExactly 'Grey'
        }
    }

    Context 'ConvertTo-WorkbenchGuiOverride' {

        It 'Reads a tick as a boolean, whichever way it was written' {
            $tick = New-GuiParameterStub -Name 'Force' -TypeName 'SwitchParameter' -IsSwitch $true
            ConvertTo-WorkbenchGuiOverride -Parameter $tick -Text 'True' | Should -BeTrue
            ConvertTo-WorkbenchGuiOverride -Parameter $tick -Text 'yes' | Should -BeTrue
            ConvertTo-WorkbenchGuiOverride -Parameter $tick -Text 'False' | Should -BeFalse
            ConvertTo-WorkbenchGuiOverride -Parameter $tick -Text '' | Should -BeFalse
        }

        It 'Splits a list on lines and on commas, dropping the blanks' {
            $list = New-GuiParameterStub -Name 'Wave' -TypeName 'String[]' -IsArray $true
            @(ConvertTo-WorkbenchGuiOverride -Parameter $list -Text "1`n2") | Should -Be @('1', '2')
            @(ConvertTo-WorkbenchGuiOverride -Parameter $list -Text '1, 2 ,') | Should -Be @('1', '2')
        }

        It 'Reads one old=new rewrite per line into a map' {
            $map = New-GuiParameterStub -Name 'AliasDomainMap' -TypeName 'Hashtable' -IsHashtable $true
            $parsed = ConvertTo-WorkbenchGuiOverride -Parameter $map -Text "old.com=new.com`nnot a pair"
            $parsed | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
            @($parsed.Keys) | Should -Be @('old.com')
            $parsed['old.com'] | Should -BeExactly 'new.com'
        }

        It 'Reads a whole number as a number' {
            $number = New-GuiParameterStub -Name 'PasswordLength' -TypeName 'Int32'
            ConvertTo-WorkbenchGuiOverride -Parameter $number -Text ' 20 ' | Should -Be 20
        }

        It 'Keeps a number that will not parse as typed, so the validator names it' {
            $number = New-GuiParameterStub -Name 'PasswordLength' -TypeName 'Int32'
            ConvertTo-WorkbenchGuiOverride -Parameter $number -Text 'twenty' | Should -BeExactly 'twenty'
        }

        It 'Treats a cleared box as no override at all rather than as an empty value' {
            $text = New-GuiParameterStub -Name 'TargetDomain'
            ConvertTo-WorkbenchGuiOverride -Parameter $text -Text '   ' | Should -BeNullOrEmpty
        }

        It 'Trims what was typed' {
            $text = New-GuiParameterStub -Name 'TargetDomain'
            ConvertTo-WorkbenchGuiOverride -Parameter $text -Text '  newco.com ' | Should -BeExactly 'newco.com'
        }
    }

    Context 'Test-WorkbenchGuiTypedConfirmation' {

        It 'Accepts a domain without case, because DNS has none' {
            Test-WorkbenchGuiTypedConfirmation -Answer 'NEWCO.COM' -Required 'newco.com' | Should -BeTrue
            Test-WorkbenchGuiTypedConfirmation -Answer '  newco.com  ' -Required 'newco.com' | Should -BeTrue
        }

        It 'Demands the case of a keyword, because shouting it is the point' {
            Test-WorkbenchGuiTypedConfirmation -Answer 'REMOVE' -Required 'REMOVE' | Should -BeTrue
            Test-WorkbenchGuiTypedConfirmation -Answer 'remove' -Required 'REMOVE' | Should -BeFalse
        }

        It 'Refuses a gate that names nothing to type rather than treating it as satisfied' {
            Test-WorkbenchGuiTypedConfirmation -Answer '' -Required '' | Should -BeFalse
            Test-WorkbenchGuiTypedConfirmation -Answer 'anything' -Required '' | Should -BeFalse
        }

        It 'Agrees with the unattended path on the same fixture gate' {
            # The rule this helper applies is the one Invoke-WorkbenchNonInteractive applies, and
            # the fixture's release domain is what the hard gate asks for there.
            Test-WorkbenchGuiTypedConfirmation -Answer 'NEWCO.COM' -Required 'newco.com' | Should -BeTrue
        }
    }
}

Describe 'Start-MigrationWorkbench - WinForms is never loaded before the platform is known' {

    <#
        The one ordering rule the whole cross-platform story rests on: the WinForms assembly does
        not exist on macOS or Linux, and loading it to find that out would end the session on the
        platforms the console mode is the entire point of. Asserted against the parse tree rather
        than by running anything, because on this machine running it is exactly what must not
        happen.
    #>

    BeforeAll {
        $parseErrors = $null
        $script:WorkbenchAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$null, [ref]$parseErrors)
        @($parseErrors) | Should -HaveCount 0

        function Get-WorkbenchCommandAst {
            [CmdletBinding()]
            param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)

            return @($Ast.FindAll({
                        if ($args[0] -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                        $called = $args[0].GetCommandName()
                        $called -and (($called -split '\\')[-1] -ieq $Name)
                    }, $true))
        }

        function Get-WorkbenchEnclosingFunction {
            [CmdletBinding()]
            param([Parameter(Mandatory)]$Ast)

            $node = $Ast
            while ($null -ne $node) {
                if ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $node }
                $node = $node.Parent
            }
            return $null
        }
    }

    It 'Calls Add-Type only from the function that builds the window' {
        $calls = @(Get-WorkbenchCommandAst -Ast $script:WorkbenchAst -Name 'Add-Type')
        $calls | Should -Not -BeNullOrEmpty -Because 'the window has to load WinForms somewhere'

        foreach ($call in $calls) {
            $owner = Get-WorkbenchEnclosingFunction -Ast $call
            $owner | Should -Not -BeNullOrEmpty -Because 'an Add-Type at script level would run on every platform'
            $owner.Name | Should -BeLike 'Start-*Gui*'
        }
    }

    It 'Checks the platform before it loads WinForms' {
        $builder = @($script:WorkbenchAst.FindAll({
                    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $args[0].Name -eq 'Start-MigrationWorkbenchGui'
                }, $true))
        $builder | Should -HaveCount 1

        $platform = @(Get-WorkbenchCommandAst -Ast $builder[0] -Name 'Test-WorkbenchWindows')
        $addType = @(Get-WorkbenchCommandAst -Ast $builder[0] -Name 'Add-Type')
        $platform | Should -Not -BeNullOrEmpty
        $addType | Should -Not -BeNullOrEmpty

        $platform[0].Extent.StartOffset |
            Should -BeLessThan $addType[0].Extent.StartOffset -Because 'the refusal comes first'
    }

    It 'Builds no window and loads no assembly at load time: the GUI region is functions only' {
        # Everything between the region markers has to be a function definition. A statement there
        # would run the moment the script is dot-sourced - which is what -NoGui exists to make
        # safe on a machine with no WinForms at all.
        $lines = @(Get-Content -LiteralPath $script:ScriptPath)
        $start = (1..$lines.Count | Where-Object { $lines[$_ - 1] -match '^#region GUI\s*$' })[0]
        $end = (1..$lines.Count | Where-Object { $lines[$_ - 1] -match '^#endregion GUI\s*$' })[0]
        $start | Should -Not -BeNullOrEmpty
        $end | Should -BeGreaterThan $start

        $stray = @($script:WorkbenchAst.EndBlock.Statements | Where-Object {
                $_.Extent.StartLineNumber -gt $start -and $_.Extent.EndLineNumber -lt $end -and
                $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst]
            })
        $stray | Should -BeNullOrEmpty
    }
}
