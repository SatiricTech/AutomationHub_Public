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
    $global:WorkbenchStepTenantVerified = $null

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
            ExpectedTenantId   = [string]$ExpectedTenantId
            TenantVerified     = $global:WorkbenchStepTenantVerified
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

    # When the suite started, so the AfterAll guard can tell a log this run wrote from one that
    # was already there.
    $global:WorkbenchSuiteStart = Get-Date

    # The litter guard's baseline: whether the operator's own default output root exists at all,
    # and everything in it, recursively. Recorded as a whole listing rather than as a pattern
    # because the front end's log lands in a Workbench subfolder of that root - a guard that
    # looked only for Start-MigrationWorkbench_*.log files directly in the root watched a folder
    # appear beside a technician's real migrations and said nothing.
    $global:WorkbenchStrayRoot = Get-MigrationDefaultOutputRoot
    $global:WorkbenchRootExisted = Test-Path -LiteralPath $global:WorkbenchStrayRoot -PathType Container
    $global:WorkbenchRootBefore = @()
    if ($global:WorkbenchRootExisted) {
        $global:WorkbenchRootBefore = @(Get-ChildItem -LiteralPath $global:WorkbenchStrayRoot -Recurse -Force `
                -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.FullName })
    }

    # One non-interactive run, with the shadow's log cleared first and everything the operator
    # would have seen - host output and errors alike - captured as text.
    #
    # The workbench's own log goes to <workspace>/Workbench/ when a workspace is known and under
    # the default output root when one is not - which is the operator's real ~/Migration-Automations
    # on the machine running this suite. So an invocation with no usable workspace has to name a
    # -LogPath under TestDrive, and this refuses rather than quietly writing there: a test that
    # litters a technician's own migration folder is a test nobody notices for months.
    function Invoke-WorkbenchScript {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that runs the entry script under test.')]
        param([hashtable]$Parameter)

        $hasWorkspace = $Parameter.ContainsKey('Workspace') -and
            (Test-Path -LiteralPath ([string]$Parameter['Workspace']) -PathType Container)
        if (-not $hasWorkspace -and -not $Parameter.ContainsKey('LogPath')) {
            throw ('This invocation has no workspace on disk, so the workbench would log to the real ' +
                'default output root. Pass -LogPath under TestDrive.')
        }

        $global:WorkbenchStepRuns = [System.Collections.Generic.List[object]]::new()

        # A refusal is a plain line on the process's own stderr, not a PowerShell error record,
        # so 2>&1 never sees it: the script writes it with [Console]::Error.WriteLine to keep
        # Write-Error's four-line position block out of an unattended run's output. Redirecting
        # Console.Error for the length of the call is the only way to read it back in-process,
        # and it is restored in a finally so a failing invocation cannot swallow the suite's own
        # error output for every test after it.
        $captured = [System.IO.StringWriter]::new()
        $previousError = [Console]::Error
        [Console]::SetError($captured)
        try {
            # Errors and warnings both: a soft gate the run warned past is a Write-Warning, and
            # the 2>&1 alone would have left every one of those out of what the assertions see.
            $output = & $script:ScriptPath @Parameter 2>&1 3>&1 | Out-String
        }
        finally {
            [Console]::SetError($previousError)
        }

        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output + $captured.ToString())
            Stderr   = $captured.ToString()
            Runs     = @($global:WorkbenchStepRuns)
        }
    }
}

AfterAll {
    # Nothing this suite ran may have added anything at all to the operator's own default output
    # root - not a log file, not a Workbench folder, and not the root itself where it did not
    # exist. The whole listing is compared with the one BeforeAll recorded, because the two ways
    # this front end has littered that folder both hid from a narrower check: a log file the root
    # never saw (it goes in a subfolder), and the subfolder itself, created by
    # Initialize-MigrationRun before the refusal that meant nothing was ever written to it.
    $root = [string]$global:WorkbenchStrayRoot
    $rootExistsNow = Test-Path -LiteralPath $root -PathType Container
    $after = @()
    if ($rootExistsNow) {
        $after = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { [string]$_.FullName })
    }

    $before = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($global:WorkbenchRootBefore), [System.StringComparer]::OrdinalIgnoreCase)
    $added = @(@($after) | Where-Object { -not $before.Contains($_) } | Sort-Object)

    # Cleaned up before the failure is raised, so a run that trips this does not leave the litter
    # behind as well - and then only what this front end could have written. That folder holds a
    # technician's real migrations, and this suite has no business deleting anything else, so
    # anything unexpected is reported and left exactly where it is.
    if (-not $global:WorkbenchRootExisted -and $rootExistsNow) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        $mine = @($added | Where-Object {
                $_ -like (Join-Path $root 'Workbench*') -or
                (Split-Path -Leaf $_) -like 'Start-MigrationWorkbench_*.log'
            })
        # Deepest first, so a folder is emptied before it is removed.
        foreach ($path in @($mine | Sort-Object -Property Length -Descending)) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    if (-not $global:WorkbenchRootExisted -and $rootExistsNow) {
        $problems.Add("it did not exist before this suite ran, and it does now")
    }
    if (@($added).Count -gt 0) {
        $problems.Add("it gained " + (@($added) -join ', '))
    }
    if ($problems.Count -gt 0) {
        throw ("This suite wrote into the operator's own output root '$root': " +
            ($problems -join '; ') + '. Every invocation needs a -Workspace on disk or a -LogPath ' +
            'under TestDrive, and a refusal the arguments alone decide must be made before ' +
            'Initialize-MigrationRun creates the run folder.')
    }

    Remove-Variable -Scope Global -ErrorAction SilentlyContinue -Name `
        WorkbenchStepRuns, WorkbenchStepExitCode, WorkbenchStepAborted, WorkbenchSuiteStart, `
        WorkbenchStrayRoot, WorkbenchRootExisted, WorkbenchRootBefore, WorkbenchStepTenantVerified
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

Describe 'Start-MigrationWorkbench Main - a run whose tenant did not verify' {

    <#
        Spec section 7.2: a tenant mismatch is flagged regardless of the exit code. The console
        and the window both shout it; the unattended path used to put it in the ledger and say
        nothing, so a scheduler reading the exit code saw a success. It now says so on stderr
        and exits 1 whatever the step returned.
    #>

    BeforeAll {
        $global:WorkbenchStepTenantVerified = $false
        $script:MismatchWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveMismatch'
        $script:MismatchResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:MismatchWorkspace
            Step      = 'New-Users'
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    AfterAll {
        $global:WorkbenchStepTenantVerified = $null
    }

    It 'Exits 1 even though the step itself returned 0' {
        $global:WorkbenchStepExitCode | Should -Be 0
        $script:MismatchResult.ExitCode | Should -Be 1
    }

    It 'Says so on stderr, where an unattended caller can capture it' {
        $script:MismatchResult.Stderr | Should -BeLike '*TENANT MISMATCH*'
    }

    It 'Names the expected tenant, because a run that printed no tenant line never signed in' {
        $script:MismatchResult.Stderr | Should -BeLike '*No tenant line was found*'
        $script:MismatchResult.Stderr | Should -BeLike '*00000000-0000-0000-0000-000000000000*'
        $script:MismatchResult.Stderr | Should -Not -BeLike '*no tenant at all*'
    }

    It 'Ran the step: the flag is post-run, not a refusal' {
        $script:MismatchResult.Runs | Should -HaveCount 1
    }
}

Describe 'Start-MigrationWorkbench Main - a child that reported no exit code' {

    BeforeAll {
        $global:WorkbenchStepExitCode = $null
        $script:NoCodeWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveNoExitCode'
        $script:NoCodeResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:NoCodeWorkspace
            Step      = 'New-Users'
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    AfterAll {
        $global:WorkbenchStepExitCode = 0
    }

    It 'Exits 1 rather than letting [int]$null read as success' {
        $script:NoCodeResult.ExitCode | Should -Be 1
    }
}

Describe 'Start-MigrationWorkbench Main - a refusal is printed once' {

    BeforeAll {
        $script:OnceWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveRefusalOnce'
        $script:OnceResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:OnceWorkspace
            Step      = 'Nope'
            Verbosity = 'Low'
        }
    }

    It 'Writes the sentence to stderr as a plain line, with no position block' {
        $script:OnceResult.Stderr | Should -BeLike '*Nope*'
        # Write-Error's block is what these two would come from.
        $script:OnceResult.Stderr | Should -Not -BeLike '*Line |*'
        $script:OnceResult.Stderr | Should -Not -BeLike '*~~~~*'
    }

    It 'Writes it exactly once' {
        @(@($script:OnceResult.Stderr -split "`r?`n") |
                Where-Object { $_ -like "*Step 'Nope' is not in the step catalogue*" }) | Should -HaveCount 1
    }
}

Describe 'Start-MigrationWorkbench Main - a hard gate is judged before the soft ones warn' {

    <#
        A run that is about to be refused must not first tell a scheduler's log what it waved
        through: the soft-gate warnings describe a run that never happened.
    #>

    BeforeAll {
        $script:GateOrderWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveGateOrder'
        $script:GateOrderResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:GateOrderWorkspace
            Step      = 'DomainReferences-Remediate'
            Verbosity = 'Low'
        }
    }

    It 'Exits 2 on the unanswered typed confirmation' {
        $script:GateOrderResult.ExitCode | Should -Be 2
    }

    It 'Emits no soft-gate override warning for a run it refused' {
        $script:GateOrderResult.Output | Should -Not -BeLike '*continuing anyway*'
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

    # A rehearsal clears only the hard gates - the same rule the console applies
    # (Docs/Workbench-Design.md, section 8) - so there is nothing to waive and nothing to record.
    # A soft-gate override in the ledger for a run that changed nothing would be a waiver the
    # next reader has to explain away.
    It 'Records no soft-gate override, because a rehearsal is not held to the soft gates' {
        @($script:AckResult.Runs[0].GateOverrides) | Should -HaveCount 0
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
            LogPath   = (Join-Path $TestDrive 'no-workspace.log')
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

    <#
        The litter this covers: the run context was opened before the refusal was raised, and
        Initialize-MigrationRun creates its -OutputPath whether or not anything is written there.
        A run that refused in its first second therefore left a Workbench folder behind under the
        operator's default output root - and, because -LogPath named a file and not a folder,
        it left it there even when the caller had redirected the log somewhere else entirely.
    #>

    BeforeAll {
        $script:MissingLogPath = Join-Path $TestDrive 'missing-workspace.log'
        $script:MissingResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = (Join-Path $TestDrive 'NotAWorkspaceAtAll')
            Step      = 'New-Users'
            Verbosity = 'Low'
            LogPath   = $script:MissingLogPath
        }
    }

    It 'Exits 2 and names the folder' {
        $script:MissingResult.ExitCode | Should -Be 2
        $script:MissingResult.Output | Should -BeLike '*NotAWorkspaceAtAll*'
    }

    It 'Opens no run at all: the refusal reaches the operator, not a log file' {
        Test-Path -LiteralPath $script:MissingLogPath | Should -BeFalse
    }

    It 'Creates nothing under the default output root' {
        # The suite-wide guard in AfterAll is the net; this is the one invocation that used to
        # fall through it, asserted where a reader will look for it.
        $root = Get-MigrationDefaultOutputRoot
        $workbenchFolder = Join-Path $root 'Workbench'
        if (Test-Path -LiteralPath $workbenchFolder -PathType Container) {
            @(Get-ChildItem -LiteralPath $workbenchFolder -Recurse -Force |
                    Where-Object { $_.LastWriteTime -ge $global:WorkbenchSuiteStart }) |
                Should -HaveCount 0
        }
        else {
            Test-Path -LiteralPath $workbenchFolder | Should -BeFalse
        }
    }
}

Describe 'Start-MigrationWorkbench Main - a step id that is refused before the run is opened' {

    BeforeAll {
        # A workspace that does exist, so the only thing wrong is the step id. The refusal is
        # still made before Initialize-MigrationRun, which is why no Workbench folder appears
        # inside the workspace either.
        $script:EarlyRefusalWorkspace = Copy-FixtureWorkspace -Name 'UnknownStepNoLog'
        $script:EarlyRefusalResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:EarlyRefusalWorkspace
            Step      = 'NoSuchStepAtAll'
            Verbosity = 'Low'
        }
    }

    It 'Exits 2 and names the id' {
        $script:EarlyRefusalResult.ExitCode | Should -Be 2
        $script:EarlyRefusalResult.Output | Should -BeLike '*NoSuchStepAtAll*'
    }

    It 'Wrote no workbench log into the workspace' {
        # The fixture ships a Workbench folder (it holds Runs.jsonl), so what is asserted is that
        # this invocation added no log file to it.
        @(Get-ChildItem -LiteralPath (Join-Path $script:EarlyRefusalWorkspace 'Workbench') `
                -Filter '*.log' -File -ErrorAction SilentlyContinue) | Should -HaveCount 0
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

    It 'Names the keys to fix, the same refusal the board and the window make' {
        # Test-MigrationWorkspaceRunnable's reason, so all three front ends say the same thing.
        $script:BadSettingsResult.Output | Should -BeLike '*not usable yet*'
        $script:BadSettingsResult.Output | Should -BeLike '*(the settings file itself)*'
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

Describe 'Start-MigrationWorkbench Main - a live run with no wave named' {

    <#
        The regression this covers: $waves was assigned with 'if ($Wave) { @($Wave) } else { @() }',
        and an if-statement used as an expression whose taken branch is an empty array yields
        nothing at all. $waves was therefore $null, every @($waves) downstream was @($null) - one
        blank wave - and the WaveRequired gate read that as a wave having been named. A live
        unattended run of a writer was silently reported as "limited to wave ." while it processed
        the whole plan.
    #>

    BeforeAll {
        $script:LiveWaveWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveLiveNoWave'
        $script:LiveWaveResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:LiveWaveWorkspace
            Step      = 'New-Users'
            Verbosity = 'Low'
        }
    }

    It 'Runs the step' {
        $script:LiveWaveResult.Runs | Should -HaveCount 1
    }

    It 'Tells the runner no wave at all, not one blank one' {
        @($script:LiveWaveResult.Runs[0].Wave) | Should -HaveCount 0
    }

    It 'Warns that the whole plan will be processed' {
        $script:LiveWaveResult.Output | Should -BeLike '*WaveRequired*'
        $script:LiveWaveResult.Output | Should -BeLike '*whole plan*'
    }

    It 'Records the unsatisfied WaveRequired gate as an override' {
        ($script:LiveWaveResult.Runs[0].GateOverrides -join ' ') | Should -BeLike '*WaveRequired*'
    }

    It 'Leaves Wave out of the driver entirely' {
        $driver = Get-Content -LiteralPath $script:LiveWaveResult.Runs[0].DriverPath -Raw
        $driver | Should -Not -Match '(?m)^\s*Wave\s*='
    }
}

Describe 'Start-MigrationWorkbench Main - a rehearsal is not held to the soft gates' {

    # Parity with the console (Docs/Workbench-Design.md, section 8): a rehearsal exists to be run
    # before the prerequisites are met, so it clears only the hard gates - and recording an
    # override for one would put a waiver in the ledger for a run that changed nothing.
    BeforeAll {
        $script:SoftGateWorkspace = Copy-FixtureWorkspace -Name 'NonInteractiveRehearsalSoftGates'
        $script:SoftGateResult = Invoke-WorkbenchScript -Parameter @{
            Workspace = $script:SoftGateWorkspace
            Step      = 'New-Users'
            DryRun    = $true
            Verbosity = 'Low'
        }
    }

    It 'Runs the step' {
        $script:SoftGateResult.Runs | Should -HaveCount 1
    }

    It 'Records no gate overrides at all' {
        @($script:SoftGateResult.Runs[0].GateOverrides) | Should -HaveCount 0
    }
}

Describe 'Start-MigrationWorkbench - a workspace path that is a file' {

    BeforeAll {
        . $script:ScriptPath -NoGui
    }

    It 'Says it is not a folder, rather than that it does not exist' {
        $file = Join-Path $TestDrive 'NotAFolder.txt'
        Set-Content -LiteralPath $file -Value 'a file, not a migration folder'
        $resolved = Resolve-WorkbenchWorkspacePath -Workspace $file -Mode 'NonInteractive'
        $resolved.Path | Should -BeNullOrEmpty
        $resolved.Problem | Should -BeLike '*is a file, not a folder*'
    }
}

Describe 'Start-MigrationWorkbench - the recent list treats one path as one workspace' {

    BeforeAll {
        . $script:ScriptPath -NoGui
    }

    BeforeEach {
        $script:WorkbenchRecentPath = Join-Path $TestDrive (
            'recent-canonical-{0}.json' -f [guid]::NewGuid().ToString('N'))
    }

    It 'Drops a trailing separator, so the same folder is one entry' {
        $folder = Join-Path $TestDrive 'Canonical'
        Add-WorkbenchRecentWorkspace -Path ($folder + [System.IO.Path]::DirectorySeparatorChar)
        Add-WorkbenchRecentWorkspace -Path $folder
        $recent = @(Get-WorkbenchRecentWorkspace)
        $recent | Should -HaveCount 1
        $recent[0] | Should -BeExactly $folder
    }

    It 'Treats two spellings of one path as one workspace' {
        $folder = Join-Path $TestDrive 'CaseFolded'
        Add-WorkbenchRecentWorkspace -Path $folder
        Add-WorkbenchRecentWorkspace -Path $folder.ToUpperInvariant()
        @(Get-WorkbenchRecentWorkspace) | Should -HaveCount 1
    }

    It 'Reads an empty list from JSON that is valid but is not an array of paths' {
        Set-Content -LiteralPath $script:WorkbenchRecentPath -Value '{ "Workspace": "/somewhere" }'
        @(Get-WorkbenchRecentWorkspace) | Should -HaveCount 0
    }

    It 'Reads an empty list from a JSON document that is only a string' {
        # Without -NoEnumerate a one-element array comes back unwrapped as a bare string, so this
        # and a real list of one would be indistinguishable and the picker would offer characters.
        Set-Content -LiteralPath $script:WorkbenchRecentPath -Value '"/somewhere"'
        @(Get-WorkbenchRecentWorkspace) | Should -HaveCount 0
    }

    It 'Still reads a list of exactly one path as a list' {
        Add-WorkbenchRecentWorkspace -Path (Join-Path $TestDrive 'Solo')
        @(Get-WorkbenchRecentWorkspace) | Should -HaveCount 1
    }

    It 'Skips entries that are not strings rather than offering @{...} as a folder' {
        Set-Content -LiteralPath $script:WorkbenchRecentPath -Value '["/a/real/path", { "not": "a path" }, 7]'
        $recent = @(Get-WorkbenchRecentWorkspace)
        $recent | Should -Be @('/a/real/path')
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
                    'ConvertTo-WorkbenchGuiOverride', 'Test-WorkbenchGuiFormParameter')) {
                Get-Command -Name $name -CommandType Function | Should -Not -BeNullOrEmpty
            }
        }

        It 'Keeps no second copy of a rule the engine now owns' {
            # Test-WorkbenchGuiCanRun and Test-WorkbenchGuiTypedConfirmation were the window's
            # own versions of two rules all three front ends apply. They are engine functions
            # now, and a script-local copy reappearing is a front end about to disagree with the
            # console and the unattended path about when a run is allowed.
            foreach ($name in @('Test-WorkbenchGuiCanRun', 'Test-WorkbenchGuiTypedConfirmation')) {
                Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue |
                    Should -BeNullOrEmpty
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
                'MapEditor', 'Secret', 'TextBox')
            foreach ($entry in @(Get-MigrationStep)) {
                foreach ($parameter in @($entry.Parameters | Where-Object { -not $_.Common })) {
                    ConvertTo-WorkbenchGuiControlKind -Parameter $parameter | Should -BeIn $kinds
                }
            }
        }

        It 'Offers no control at all for a [SecureString]' {
            ConvertTo-WorkbenchGuiControlKind -Parameter (
                New-GuiParameterStub -Name 'ClientSecret' -TypeName 'SecureString') |
                Should -BeExactly 'Secret'
        }

        It 'Reads the real VivaLearning-Import -ClientSecret as a secret, not as a text box' {
            # The regression: [SecureString] had no case of its own, so -ClientSecret fell through
            # to the bottom of the function and the form drew a clear-text box for it.
            $secret = @(@((Get-MigrationStep -Id 'VivaLearning-Import').Parameters) |
                    Where-Object { $_.Name -eq 'ClientSecret' })
            $secret | Should -HaveCount 1
            $secret[0].Common | Should -BeFalse -Because 'the form would otherwise skip it for another reason'
            ConvertTo-WorkbenchGuiControlKind -Parameter $secret[0] | Should -BeExactly 'Secret'
        }

        It 'Tells the operator where the secret comes from, in those words' {
            # The row's whole content, asserted verbatim: it is the only instruction an operator
            # gets, and the window has nowhere else to say it.
            $script:WorkbenchGuiSecretRowText | Should -BeExactly (
                'Set $env:M365MIGRATION_CLIENT_SECRET before Run ' + [char]0x2014 +
                ' the window never takes a secret.')
        }
    }

    Context 'Test-WorkbenchGuiFormParameter' {

        <#
            The regression this covers: -Wave is not a Common parameter, so the generated form
            drew a second control for it beside the Waves checked list of section 9. The two
            disagreed silently - -Override @{ Wave = '3' } outranks -Wave @('1') in the resolver
            - so the ledger recorded the ticked wave while the driver ran the typed one, and the
            DryRunFirst evidence for the next live run was evidence of a different run.
        #>

        It 'Draws no row for a parameter the workbench owns' {
            # The engine's list, not a copy of it: two lists is how a form comes to draw a box
            # whose value Resolve-MigrationStepArguments then drops without saying so.
            foreach ($name in @(Get-MigrationWorkbenchOwnedParameter)) {
                Test-WorkbenchGuiFormParameter -Parameter (New-GuiParameterStub -Name $name) |
                    Should -BeFalse -Because "the workbench decides -$name for every run"
            }
        }

        It 'Draws a row for a parameter that is the operator''s to fill in' {
            Test-WorkbenchGuiFormParameter -Parameter (New-GuiParameterStub -Name 'PlanPath') | Should -BeTrue
        }

        It 'Draws no row for the options the workbench sets for every step' {
            $common = New-GuiParameterStub -Name 'Prefix'
            $common.Common = $true
            Test-WorkbenchGuiFormParameter -Parameter $common | Should -BeFalse
        }

        It 'Leaves -Wave out of the form of every step that takes one' {
            # Read off the catalogue rather than off a stub: -Wave really is Common = $false, which
            # is what put it on the form in the first place.
            foreach ($entry in @(Get-MigrationStep)) {
                $drawn = @(@($entry.Parameters) |
                        Where-Object { Test-WorkbenchGuiFormParameter -Parameter $_ } |
                        ForEach-Object { [string]$_.Name })
                $drawn | Should -Not -Contain 'Wave' -Because 'the Waves checked list owns it'
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
            $list = New-GuiParameterStub -Name 'Scope' -TypeName 'String[]' -IsArray $true
            @(ConvertTo-WorkbenchGuiOverride -Parameter $list -Text "1`n2") | Should -Be @('1', '2')
            @(ConvertTo-WorkbenchGuiOverride -Parameter $list -Text '1, 2 ,') | Should -Be @('1', '2')
        }

        It 'Never returns a value for a parameter a dedicated control owns' {
            # The second lock on the disagreeing-wave bug: even a row that somehow reached the
            # form cannot become -Override @{ Wave = ... } and outrank the wave the run was given.
            $wave = New-GuiParameterStub -Name 'Wave' -TypeName 'String[]' -IsArray $true
            ConvertTo-WorkbenchGuiOverride -Parameter $wave -Text "1`n2" | Should -BeNullOrEmpty
            ConvertTo-WorkbenchGuiOverride -Parameter (New-GuiParameterStub -Name 'OutputPath') `
                -Text '/somewhere/else' | Should -BeNullOrEmpty
        }

        It 'Never returns a secret, whatever it was handed' {
            # A secret in an -Override hashtable is a secret in the driver file
            # New-MigrationStepDriver writes from it.
            $secret = New-GuiParameterStub -Name 'ClientSecret' -TypeName 'SecureString'
            ConvertTo-WorkbenchGuiOverride -Parameter $secret -Text 'not-a-real-secret' |
                Should -BeNullOrEmpty
            ConvertTo-WorkbenchGuiOverride -Parameter $secret -Text $script:WorkbenchGuiSecretRowText |
                Should -BeNullOrEmpty
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

    Context 'The typed-confirmation rule the window applies' {

        It 'Accepts a domain without case, because DNS has none' {
            Test-MigrationTypedConfirmation -Typed 'NEWCO.COM' -Required 'newco.com' | Should -BeTrue
            Test-MigrationTypedConfirmation -Typed '  newco.com  ' -Required 'newco.com' | Should -BeTrue
        }

        It 'Demands the case of a keyword, because shouting it is the point' {
            Test-MigrationTypedConfirmation -Typed 'REMOVE' -Required 'REMOVE' | Should -BeTrue
            Test-MigrationTypedConfirmation -Typed 'remove' -Required 'REMOVE' | Should -BeFalse
        }

        It 'Refuses a gate that names nothing to type rather than treating it as satisfied' {
            Test-MigrationTypedConfirmation -Typed '' -Required '' | Should -BeFalse
            Test-MigrationTypedConfirmation -Typed 'anything' -Required '' | Should -BeFalse
        }

        It 'Agrees with the unattended path on the same fixture gate' {
            # The rule this helper applies is the one Invoke-WorkbenchNonInteractive applies, and
            # the fixture's release domain is what the hard gate asks for there.
            Test-MigrationTypedConfirmation -Typed 'NEWCO.COM' -Required 'newco.com' | Should -BeTrue
        }
    }

    Context 'The runnable-workspace refusal the window applies' {

        <#
            The window may open a workspace whose settings do not validate - that is how an
            operator fixes them through the Settings dialog, and it is the one thing the window
            can do that the console cannot. What it must not do is run a step against one: with
            no settings there is no tenant GUID to assert against (TenantVerified comes back
            $null), no label (the prefix and the output folder fall back to Common), and one Yes
            on a soft gate would start a live writer nobody can say which tenant it reached. The
            console refuses outright and the unattended path exits 2; this is the window's
            version of the same refusal, and it is a pure function so it can be tested here.
        #>

        BeforeAll {
            $script:BrokenWorkspacePath = Join-Path $TestDrive 'GuiSettingsRefusal'
            Copy-Item -LiteralPath $script:FixtureRoot -Destination $script:BrokenWorkspacePath -Recurse -Force

            # Label blanked and nothing else: the smallest edit that makes a settings document
            # fail validation, and the one whose consequences the operator sees least.
            $settingsPath = Join-Path $script:BrokenWorkspacePath 'M365Migration.settings.json'
            $document = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            $document.Label = ''
            $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsPath
            $script:BrokenWorkspace = Get-MigrationWorkspace -Path $script:BrokenWorkspacePath
        }

        It 'Lets a workspace whose settings validate run' {
            $verdict = Test-MigrationWorkspaceRunnable -Workspace $script:GuiWorkspace
            $verdict.CanRun | Should -BeTrue
            $verdict.Reason | Should -BeExactly ''
        }

        It 'Refuses a workspace whose Label was blanked, and names Label' {
            $script:BrokenWorkspace.SettingsResult.IsValid | Should -BeFalse
            $verdict = Test-MigrationWorkspaceRunnable -Workspace $script:BrokenWorkspace
            $verdict.CanRun | Should -BeFalse
            $verdict.Keys | Should -Contain 'Label'
            $verdict.Reason | Should -BeLike '*Label*'
        }

        It 'Points the operator at the Settings dialog, which is the way out' {
            (Test-MigrationWorkspaceRunnable -Workspace $script:BrokenWorkspace).Reason |
                Should -BeLike '*Settings*'
        }

        It 'Refuses before a workspace is open at all' {
            $verdict = Test-MigrationWorkspaceRunnable -Workspace $null
            $verdict.CanRun | Should -BeFalse
            $verdict.Reason | Should -BeLike '*workspace*'
        }

        It 'Still lists the runbook for a workspace it refuses to run' {
            # The tree is drawn either way: a runbook an operator can read is how they work out
            # which settings they are missing.
            @((Get-WorkbenchGuiStepList -Workspace $script:BrokenWorkspace).Steps.Id) |
                Should -Not -BeNullOrEmpty
        }
    }

    Context 'The refusals the window returns to Main' {

        <#
            The window's two refusals are exit codes, not exceptions, and Main hands whatever it
            returns straight to Complete-MigrationRun. On this machine only the first is
            reachable - the STA branch needs Windows - so the platform refusal is run for real
            and the wiring that carries it out of the script is asserted against the parse tree.
        #>

        It 'Returns 2 off Windows, having loaded no WinForms assembly' -Skip:([bool]$IsWindows) {
            # The assemblies loaded into this AppDomain, before and after. Get-Module was the
            # wrong instrument entirely: WinForms is a .NET assembly, never a PowerShell module,
            # so that assertion passed whether or not Add-Type had ever run.
            #
            # Compared as sets rather than asserted empty, because a few System.Drawing.* pieces
            # are already in a .NET 8 process on macOS before this suite starts. What must not
            # happen is one appearing across the refusal - and System.Windows.Forms must not be
            # there at all, before or after: there is no such assembly to load on this platform,
            # and Add-Type would have ended the session rather than returned 2.
            $isUi = { $args[0].GetName().Name -like 'System.Windows.Forms*' -or
                $args[0].GetName().Name -like 'System.Drawing*' }
            $before = @([AppDomain]::CurrentDomain.GetAssemblies() |
                    Where-Object { & $isUi $_ } | ForEach-Object { $_.GetName().Name } | Sort-Object)
            @($before | Where-Object { $_ -like 'System.Windows.Forms*' }) | Should -HaveCount 0

            # The refusal is a plain line on the process's own stderr (Write-WorkbenchRefusal),
            # not a PowerShell error record, so 2>&1 never sees it: Console.Error is redirected
            # for the length of the call and restored in the finally.
            $captured = [System.IO.StringWriter]::new()
            $previousError = [Console]::Error
            [Console]::SetError($captured)
            try { $refusal = Start-MigrationWorkbenchGui -WorkspacePath '' 2>&1 }
            finally { [Console]::SetError($previousError) }

            @($refusal | Where-Object { $_ -is [int] }) | Should -Be @(2)
            $captured.ToString() | Should -BeLike '*Windows only*'

            $after = @([AppDomain]::CurrentDomain.GetAssemblies() |
                    Where-Object { & $isUi $_ } | ForEach-Object { $_.GetName().Name } | Sort-Object)
            @($after | Where-Object { $_ -notin $before }) |
                Should -HaveCount 0 -Because 'the refusal must come before Add-Type, not after it'
            @($after | Where-Object { $_ -like 'System.Windows.Forms*' }) | Should -HaveCount 0
        }

        It 'Is the exit code Main uses, not a value Main throws away' {
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$parseErrors)
            @($parseErrors) | Should -HaveCount 0

            # $exitCode = Start-MigrationWorkbenchGui ... - an assignment, not a bare call.
            $assignments = @($ast.FindAll({
                        $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $args[0].Left.Extent.Text -eq '$exitCode' -and
                        $args[0].Right.Extent.Text -like '*Start-MigrationWorkbenchGui*'
                    }, $true))
            $assignments | Should -HaveCount 1
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

    It 'Checks the apartment state before it loads WinForms' {
        # The other half of the ordering rule. WinForms needs a single-threaded apartment, and
        # the relaunch that gets one re-runs this script from the start - so loading the
        # assembly first would load it into the very process that is about to be replaced, in
        # the apartment it cannot be used from.
        $builder = @($script:WorkbenchAst.FindAll({
                    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $args[0].Name -eq 'Start-MigrationWorkbenchGui'
                }, $true))
        $builder | Should -HaveCount 1

        $apartment = @($builder[0].FindAll({
                    $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    [string]$args[0].Member.Value -eq 'GetApartmentState'
                }, $true))
        $addType = @(Get-WorkbenchCommandAst -Ast $builder[0] -Name 'Add-Type')
        $apartment | Should -Not -BeNullOrEmpty -Because 'the window has to know its apartment'
        $addType | Should -Not -BeNullOrEmpty

        $apartment[0].Extent.StartOffset |
            Should -BeLessThan $addType[0].Extent.StartOffset -Because 'the STA check comes first'
    }

    It 'Reaps an un-run preview driver when the window closes and when a workspace is opened' {
        # A driver written for Copy command and never run is not evidence of anything, and the
        # only two ways out of a step - closing the window, opening another workspace - would
        # otherwise leave a run folder in the workspace for a run that never happened. Asserted
        # against the parse tree because there is no window on this machine to close; the
        # reaper itself (Set-WorkbenchGuiPreview, which removes a folder only while it holds no
        # stdout.txt) is exercised by the step-change path.
        $closers = @($script:WorkbenchAst.FindAll({
                    $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    [string]$args[0].Member.Value -eq 'Add_FormClosed'
                }, $true))
        $closers | Should -HaveCount 1 -Because 'the window is closed in exactly one place'
        @(Get-WorkbenchCommandAst -Ast $closers[0] -Name 'Set-WorkbenchGuiPreview') |
            Should -Not -BeNullOrEmpty -Because 'closing the window must not leave a driver behind'

        $opener = @($script:WorkbenchAst.FindAll({
                    $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $args[0].Name -eq 'Invoke-WorkbenchGuiOpenWorkspaceAction'
                }, $true))
        $opener | Should -HaveCount 1

        $reap = @(Get-WorkbenchCommandAst -Ast $opener[0] -Name 'Set-WorkbenchGuiPreview')
        $reap | Should -Not -BeNullOrEmpty -Because 'opening another workspace must not leave one either'

        # Before the scan, so a workspace that will not open still clears the old preview.
        $scan = @(Get-WorkbenchCommandAst -Ast $opener[0] -Name 'Get-MigrationWorkspace')
        $scan | Should -Not -BeNullOrEmpty
        $reap[0].Extent.StartOffset | Should -BeLessThan $scan[0].Extent.StartOffset
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
