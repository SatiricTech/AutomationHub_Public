#Requires -Version 7.4

<#
    Invoke-MigrationStep runs one generated driver in a child pwsh, streams its output back
    line by line, works out which tenant it actually reached, collects what it produced and
    appends one line to Workbench/Runs.jsonl (Docs/Workbench-Design.md, sections 7.3 and 7.4).

    Every test below starts a real child process against a real driver written by
    New-MigrationStepDriver. There is no mock of Start-Process anywhere: the things that go
    wrong in a child - a value that did not bind, output that never arrives, a process that
    will not die - are exactly the things a mock would hide.

    The runner is the one piece that later has to work under WinForms on Windows, so the two
    seams that front end needs are asserted here on macOS: -OutputWriter (the log pane) and
    -Pump (DoEvents). Nothing in the runner knows what a form is.
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:EchoPath = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Echo-Parameters.ps1')).Path
    $script:SyntheticTenant = '11111111-1111-1111-1111-111111111111'
    $script:OtherTenant = '22222222-2222-2222-2222-222222222222'

    $script:EchoStep = InModuleScope M365Migration -Parameters @{ Path = $script:EchoPath } {
        param($Path)
        $introspection = Get-MigrationScriptParameter -ScriptPath $Path
        $entry = @{
            Title     = 'Echo the parameters'
            Phase     = 'Prepare'
            Side      = 'Destination'
            Impact    = 'Write'
            ExitCodes = @{ 0 = 'Completed'; 1 = 'Failed'; 2 = 'Some rows failed'; 3 = 'Work remains' }
        }
        New-MigrationStepObject -Entry $entry -Instance @{ Id = 'Echo-Step' } -Id 'Echo-Step' `
            -Script 'Echo-Parameters' -ScriptPath $Path -Introspection $introspection
    }

    function New-TestWorkspace {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that creates an empty workspace folder under TestDrive.')]
        param([string]$Name = 'Workspace')
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path (Join-Path $path 'Contoso') -Force | Out-Null
        return [pscustomobject]@{ Path = $path; Label = 'Contoso' }
    }

    function Get-TestArgumentSet {
        param([hashtable]$Value = @{})
        $arguments = foreach ($name in @($Value.Keys | Sort-Object)) {
            [pscustomobject]@{
                Name       = $name
                Value      = $Value[$name]
                Source     = 'Operator'
                Warning    = $null
                Candidates = @()
            }
        }
        return [pscustomobject]@{
            Arguments        = @($arguments)
            ParameterSet     = 'Plan'
            MissingMandatory = @()
            Warnings         = @()
        }
    }

    # One run, end to end: resolve nothing, write a real driver, start a real child.
    function Invoke-TestEchoStep {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that runs the echo fixture through the real runner.')]
        param(
            [pscustomobject]$Workspace,
            [hashtable]$Value = @{},
            [hashtable]$Runner = @{},
            [System.Collections.Generic.List[string]]$Captured
        )

        $driver = New-MigrationStepDriver -Step $script:EchoStep -Arguments (Get-TestArgumentSet -Value $Value) `
            -Workspace $Workspace

        $parameters = @{
            Step      = $script:EchoStep
            Driver    = $driver
            Workspace = $Workspace
        }
        foreach ($key in $Runner.Keys) { $parameters[$key] = $Runner[$key] }
        # An empty List is falsy in PowerShell, so this has to be a null test, not a truth test.
        if ($null -ne $Captured) {
            $parameters['OutputWriter'] = { param($Line) $Captured.Add($Line) }.GetNewClosure()
        }

        return Invoke-MigrationStep @parameters
    }

    function Get-LedgerText {
        param([pscustomobject]$Workspace)
        $path = Join-Path $Workspace.Path 'Workbench' 'Runs.jsonl'
        if (-not (Test-Path -LiteralPath $path)) { return @() }
        return @(Get-Content -LiteralPath $path -Encoding utf8 | Where-Object { $_ })
    }
}

Describe 'Invoke-MigrationStep' {

    Context 'a run that completes' {

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'RunOk'
            $script:Captured = [System.Collections.Generic.List[string]]::new()
            $script:Result = Invoke-TestEchoStep -Workspace $script:Workspace -Captured $script:Captured `
                -Value @{ Prefix = 'Contoso'; Wave = @('1'); ExitWith = 0 }
        }

        It 'returns the run id the driver was written under' {
            $script:Result.RunId | Should -Match '^\d{8}-\d{6}_Echo-Step$'
            $script:Result.StepId | Should -BeExactly 'Echo-Step'
        }

        It 'reads the exit code from the process and names it from the catalogue' {
            $script:Result.ExitCode | Should -Be 0
            $script:Result.Meaning | Should -BeExactly 'Completed'
            $script:Result.Aborted | Should -BeFalse
        }

        It 'records when the run started and ended' {
            $script:Result.Started | Should -BeOfType [datetime]
            $script:Result.Ended | Should -BeOfType [datetime]
            $script:Result.Ended | Should -BeGreaterOrEqual $script:Result.Started
        }

        It 'writes stdout and stderr into the run folder' {
            Test-Path -LiteralPath $script:Result.StdoutPath -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $script:Result.StderrPath -PathType Leaf | Should -BeTrue
            [System.IO.Path]::GetFileName($script:Result.StdoutPath) | Should -BeExactly 'stdout.txt'
            [System.IO.Path]::GetFileName($script:Result.StderrPath) | Should -BeExactly 'stderr.txt'
        }

        It 'hands every stdout line to the writer, one line at a time' {
            $script:Captured.Count | Should -BeGreaterThan 0
            $echoed = $script:Captured[0] | ConvertFrom-Json
            @($echoed.Wave).Count | Should -Be 1
            $echoed.Prefix | Should -BeExactly 'Contoso'
        }

        It 'leaves the whole of stdout on disk as well' {
            $stdout = Get-Content -LiteralPath $script:Result.StdoutPath -Raw
            $stdout | Should -Match '"Prefix":"Contoso"'
        }
    }

    Context 'exit codes the catalogue knows, and one it does not' {

        It 'names exit 2 from the catalogue' {
            $workspace = New-TestWorkspace -Name 'RunTwo'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ ExitWith = 2 }
            $result.ExitCode | Should -Be 2
            $result.Meaning | Should -BeExactly 'Some rows failed'
        }

        It 'names exit 3 from the catalogue' {
            $workspace = New-TestWorkspace -Name 'RunThree'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ ExitWith = 3 }
            $result.ExitCode | Should -Be 3
            $result.Meaning | Should -BeExactly 'Work remains'
        }

        It 'fails a run whose splat never reached the script, and marks the stderr lines' {
            # A parameter the script does not declare is what a resolver bug looks like from
            # the child's side: the splat does not bind, so the script never runs. The driver's
            # guard turns that into exit 1 - without it $LASTEXITCODE would be unset and the
            # child would exit 0, and the workbench would record 'Completed' for a step that
            # did nothing. The binding error must also reach the log pane, marked.
            $workspace = New-TestWorkspace -Name 'RunStderr'
            $captured = [System.Collections.Generic.List[string]]::new()
            $result = Invoke-TestEchoStep -Workspace $workspace -Captured $captured `
                -Value @{ NotAParameter = 'x' }

            $result.ExitCode | Should -Be 1
            $result.Meaning | Should -BeExactly 'Failed'
            @($captured | Where-Object { $_ -like '  ! *' }).Count | Should -BeGreaterThan 0
            @($captured) -join "`n" | Should -Match 'NotAParameter'
        }

        It 'fails a run the script rejected before doing anything' {
            # The other half of the same guard: the parameter exists but the value does not
            # satisfy its ValidateSet, so again the script never starts.
            $workspace = New-TestWorkspace -Name 'RunRejected'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ ConnectAs = 'Nonsense' }
            $result.ExitCode | Should -Be 1
            $result.Meaning | Should -BeExactly 'Failed'
        }

        It 'sends an unknown exit code to the log rather than inventing a meaning' {
            $workspace = New-TestWorkspace -Name 'RunSeven'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ ExitWith = 7 }
            $result.ExitCode | Should -Be 7
            $result.Meaning | Should -BeExactly 'See the log'
        }
    }

    Context 'which tenant the child actually reached' {

        It 'collects the tenant GUID out of the connection line' {
            $workspace = New-TestWorkspace -Name 'TenantFound'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ TenantId = $script:SyntheticTenant }
            @($result.ConnectedTenantIds) | Should -Contain $script:SyntheticTenant
        }

        It 'collects the tenant GUID out of an Exchange Online connection line' {
            # Exchange names the organisation as well as the tenant, so the GUID sits inside
            # brackets rather than straight after the word 'tenant'.
            $workspace = New-TestWorkspace -Name 'TenantExchange'
            $result = Invoke-TestEchoStep -Workspace $workspace `
                -Value @{ TenantId = $script:SyntheticTenant; ConnectAs = 'Exchange' } `
                -Runner @{ ExpectedTenantId = $script:SyntheticTenant }
            @($result.ConnectedTenantIds) | Should -Contain $script:SyntheticTenant
            $result.TenantVerified | Should -BeTrue
        }

        It 'collects the tenant GUID out of a reused Exchange Online session line' {
            $workspace = New-TestWorkspace -Name 'TenantExchangeCached'
            $result = Invoke-TestEchoStep -Workspace $workspace `
                -Value @{ TenantId = $script:SyntheticTenant; ConnectAs = 'ExchangeCached' } `
                -Runner @{ ExpectedTenantId = $script:OtherTenant }
            @($result.ConnectedTenantIds) | Should -Contain $script:SyntheticTenant
            $result.TenantVerified | Should -BeFalse
        }

        It 'verifies the tenant when it is the one that was expected' {
            $workspace = New-TestWorkspace -Name 'TenantOk'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ TenantId = $script:SyntheticTenant } `
                -Runner @{ ExpectedTenantId = $script:SyntheticTenant }
            $result.TenantVerified | Should -BeTrue
        }

        It 'fails verification when the child signed in somewhere else' {
            $workspace = New-TestWorkspace -Name 'TenantWrong'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ TenantId = $script:OtherTenant } `
                -Runner @{ ExpectedTenantId = $script:SyntheticTenant }
            $result.TenantVerified | Should -BeFalse
        }

        It 'fails verification when a tenant was expected and nothing connected' {
            # Silence is not agreement: a step that was supposed to connect and printed no
            # connection line proved nothing about which tenant it wrote to.
            $workspace = New-TestWorkspace -Name 'TenantSilent'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ Prefix = 'Contoso' } `
                -Runner @{ ExpectedTenantId = $script:SyntheticTenant }
            @($result.ConnectedTenantIds).Count | Should -Be 0
            $result.TenantVerified | Should -BeFalse
        }

        It 'treats the same tenant written two ways as one tenant' {
            $workspace = New-TestWorkspace -Name 'TenantCase'
            $upper = $script:SyntheticTenant.ToUpperInvariant()
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ TenantId = $upper } `
                -Runner @{ ExpectedTenantId = $script:SyntheticTenant }
            @($result.ConnectedTenantIds).Count | Should -Be 1
            @($result.ConnectedTenantIds)[0] | Should -BeExactly $script:SyntheticTenant
            $result.TenantVerified | Should -BeTrue
        }

        It 'has no opinion when nothing was expected' {
            $workspace = New-TestWorkspace -Name 'TenantNone'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ TenantId = $script:SyntheticTenant }
            $result.TenantVerified | Should -BeNullOrEmpty
            $null -eq $result.TenantVerified | Should -BeTrue
        }
    }

    Context 'the environment the child runs in' {

        It 'gives the child a variable the parent never sees' {
            $workspace = New-TestWorkspace -Name 'RunEnvironment'
            $captured = [System.Collections.Generic.List[string]]::new()
            $result = Invoke-TestEchoStep -Workspace $workspace -Captured $captured `
                -Runner @{ Environment = @{ M365MIGRATION_TEST = 'child-only' } }

            @($captured) -join "`n" | Should -Match 'M365MIGRATION_TEST=child-only'
            $result.ExitCode | Should -Be 0
            # The whole point of the seam: a secret handed to one child is gone afterwards.
            [Environment]::GetEnvironmentVariable('M365MIGRATION_TEST') | Should -BeNullOrEmpty
        }

        It 'survives a workspace path with an apostrophe in it' {
            # The driver path reaches the child through Start-Process -ArgumentList, which
            # quotes nothing, and reaches the operator through CommandLine, which is a literal.
            $workspace = New-TestWorkspace -Name "Ren's Run"
            $captured = [System.Collections.Generic.List[string]]::new()
            $result = Invoke-TestEchoStep -Workspace $workspace -Captured $captured `
                -Value @{ Prefix = 'Contoso' }
            $result.ExitCode | Should -Be 0
            $captured.Count | Should -BeGreaterThan 0
        }

        It 'survives a workspace path with a space in it' {
            $workspace = New-TestWorkspace -Name 'Run With Space'
            $captured = [System.Collections.Generic.List[string]]::new()
            $result = Invoke-TestEchoStep -Workspace $workspace -Captured $captured `
                -Value @{ Prefix = 'Contoso' }
            $result.ExitCode | Should -Be 0
            $captured.Count | Should -BeGreaterThan 0
        }
    }

    Context 'cancelling a run' {

        It 'kills the child and records the abort' {
            $workspace = New-TestWorkspace -Name 'RunCancel'
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ SleepSeconds = 10 } `
                -Runner @{ CancelIf = { $true }; PollMilliseconds = 100 }
            $stopwatch.Stop()

            $result.Aborted | Should -BeTrue
            $result.Meaning | Should -BeExactly 'Aborted by the operator'
            $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 5
        }

        It 'does not call a run that finished during the poll an abort' {
            # The child exits while the loop is asleep, so by the time -CancelIf is asked there
            # is nothing left to kill. Recording that as "aborted by the operator" would tell
            # the next reader of the workspace that a step which completed never ran.
            $workspace = New-TestWorkspace -Name 'RunCancelRace'
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ ExitWith = 2 } `
                -Runner @{ CancelIf = { $true }; PollMilliseconds = 2000 }

            $result.Aborted | Should -BeFalse
            $result.ExitCode | Should -Be 2
            $result.Meaning | Should -BeExactly 'Some rows failed'

            $entry = @(Get-MigrationRunLedger -Workspace $workspace)[0]
            $entry.Aborted | Should -BeFalse
            $entry.Meaning | Should -BeExactly 'Some rows failed'
        }

        It 'records the abort in the ledger too' {
            $workspace = New-TestWorkspace -Name 'RunCancelLedger'
            Invoke-TestEchoStep -Workspace $workspace -Value @{ SleepSeconds = 10 } `
                -Runner @{ CancelIf = { $true }; PollMilliseconds = 100 } | Out-Null
            $entry = @(Get-MigrationRunLedger -Workspace $workspace)[0]
            $entry.Aborted | Should -BeTrue
        }
    }

    Context 'the pump the WinForms front end needs' {

        It 'calls the pump while the child is running and collects what the run produced' {
            $workspace = New-TestWorkspace -Name 'RunPump'
            $script:PumpCount = 0
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            $script:PumpResultPath = Join-Path $workspace.Path 'Contoso' "Contoso_Echo-Step-Results_$stamp.csv"

            # The pump stands in for DoEvents; here it also writes the results file the child
            # would have written, which is how Files and Summary get something real to find.
            $pump = {
                $script:PumpCount++
                if (-not (Test-Path -LiteralPath $script:PumpResultPath)) {
                    $rows = @('Identity,Action,Status,Detail',
                        'a@contoso.com,Create,Succeeded,',
                        'b@contoso.com,Create,Failed,denied')
                    Set-Content -LiteralPath $script:PumpResultPath -Value $rows -Encoding utf8
                }
            }

            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ SleepSeconds = 2 } `
                -Runner @{ Pump = $pump; PollMilliseconds = 100 }

            $script:PumpCount | Should -BeGreaterThan 0
            @($result.Files) | Should -Contain $script:PumpResultPath
            $result.Summary.Succeeded | Should -Be 1
            $result.Summary.Failed | Should -Be 1
        }
    }

    Context 'a front end whose seams throw' {

        It 'survives a writer that throws, records the run and leaves no child behind' {
            # The WinForms writer touches a form: a disposed control, a closed window or a
            # cross-thread call throws. That must cost the live log, not the run - and above
            # all it must not leave a child process writing to a tenant with nobody watching
            # and no ledger line to say it happened.
            $workspace = New-TestWorkspace -Name 'RunWriterThrows'
            $script:WriterCalls = 0
            $before = @(Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue).Count

            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ Prefix = 'Contoso' } `
                -Runner @{
                OutputWriter     = { param($Line) $script:WriterCalls++; throw "the log pane is gone: $Line" }
                PollMilliseconds = 100
                WarningAction    = 'SilentlyContinue'
            }

            $result.ExitCode | Should -Be 0
            $result.Meaning | Should -BeExactly 'Completed'
            # Called once, then disabled for the rest of the run.
            $script:WriterCalls | Should -Be 1
            @(Get-MigrationRunLedger -Workspace $workspace).Count | Should -Be 1
            @(Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue).Count | Should -BeLessOrEqual $before
        }

        It 'survives a cancel check that throws and keeps polling' {
            $workspace = New-TestWorkspace -Name 'RunCancelThrows'
            $script:CancelCalls = 0
            $before = @(Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue).Count

            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ SleepSeconds = 1 } `
                -Runner @{
                CancelIf         = { $script:CancelCalls++; throw 'the cancel button is gone' }
                PollMilliseconds = 100
                WarningAction    = 'SilentlyContinue'
            }

            $result.ExitCode | Should -Be 0
            $result.Aborted | Should -BeFalse
            $script:CancelCalls | Should -Be 1
            @(Get-MigrationRunLedger -Workspace $workspace).Count | Should -Be 1
            @(Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue).Count | Should -BeLessOrEqual $before
        }

        It 'survives a pump that throws' {
            $workspace = New-TestWorkspace -Name 'RunPumpThrows'
            $script:PumpThrowCalls = 0
            $result = Invoke-TestEchoStep -Workspace $workspace -Value @{ SleepSeconds = 1 } `
                -Runner @{
                Pump             = { $script:PumpThrowCalls++; throw 'DoEvents on a disposed form' }
                PollMilliseconds = 100
                WarningAction    = 'SilentlyContinue'
            }

            $result.ExitCode | Should -Be 0
            $script:PumpThrowCalls | Should -Be 1
            @(Get-MigrationRunLedger -Workspace $workspace).Count | Should -Be 1
        }
    }

    Context 'the ledger' {

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'RunLedger'
            Invoke-TestEchoStep -Workspace $script:Workspace -Value @{ ExitWith = 0 } `
                -Runner @{ Wave = @('1'); DryRun = $true; ExpectedTenantId = $script:SyntheticTenant } | Out-Null
            Start-Sleep -Milliseconds 1100
            $script:Second = Invoke-TestEchoStep -Workspace $script:Workspace -Value @{ ExitWith = 2 } `
                -Runner @{ Wave = @('1', '2'); GateOverrides = @('DryRunFirst') }
            $script:Lines = Get-LedgerText -Workspace $script:Workspace
        }

        It 'appends exactly one line per run' {
            $script:Lines.Count | Should -Be 2
        }

        It 'records DryRun as a boolean, never as a string or a number' {
            $script:Lines[0] | Should -Match '"DryRun":true'
            $script:Lines[1] | Should -Match '"DryRun":false'
        }

        It 'records Wave as an array even when it is empty or has one element' {
            $script:Lines[0] | Should -Match '"Wave":\["1"\]'
            $script:Lines[1] | Should -Match '"Wave":\["1","2"\]'
        }

        It 'records the gate overrides the operator accepted' {
            $script:Lines[1] | Should -Match '"GateOverrides":\["DryRunFirst"\]'
        }

        It 'records the step, the script, the side and the expected tenant' {
            $entry = $script:Lines[0] | ConvertFrom-Json
            $entry.StepId | Should -BeExactly 'Echo-Step'
            $entry.Script | Should -BeExactly 'Echo-Parameters'
            $entry.Side | Should -BeExactly 'Destination'
            $entry.TenantId | Should -BeExactly $script:SyntheticTenant
        }

        It 'records an empty tenant rather than a null when nothing was expected' {
            $script:Lines[1] | Should -Match '"TenantId":""'
        }

        It 'records the driver as a workspace-relative path' {
            $entry = $script:Lines[1] | ConvertFrom-Json
            $entry.Driver | Should -BeLike 'Workbench/Runs/*_Echo-Step/driver.ps1'
        }

        It 'returns the entry it wrote on the result object' {
            $script:Second.LedgerEntry.ExitCode | Should -Be 2
            $script:Second.LedgerEntry.Meaning | Should -BeExactly 'Some rows failed'
        }

        It 'never writes a field whose name reads like a secret' {
            $pattern = 'password|passphrase|secret|credential|token|apikey|api-key|certificate|thumbprint|key$'
            foreach ($line in $script:Lines) {
                foreach ($property in ($line | ConvertFrom-Json).PSObject.Properties) {
                    $property.Name | Should -Not -Match $pattern
                }
            }
        }

        It 'never carries a value that was handed to the child as an environment secret' {
            $workspace = New-TestWorkspace -Name 'RunLedgerSecret'
            Invoke-TestEchoStep -Workspace $workspace `
                -Runner @{ Environment = @{ M365MIGRATION_TEST = 'synthetic-not-a-secret' } } | Out-Null
            (Get-LedgerText -Workspace $workspace) -join "`n" | Should -Not -Match 'synthetic-not-a-secret'
        }
    }

    Context 'Get-MigrationRunLedger' {

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'ReadLedger'
            Invoke-TestEchoStep -Workspace $script:Workspace -Value @{ ExitWith = 0 } | Out-Null
            Start-Sleep -Milliseconds 1100
            Invoke-TestEchoStep -Workspace $script:Workspace -Value @{ ExitWith = 2 } | Out-Null
        }

        It 'returns the runs newest first' {
            $entries = @(Get-MigrationRunLedger -Workspace $script:Workspace)
            $entries.Count | Should -Be 2
            $entries[0].ExitCode | Should -Be 2
            $entries[1].ExitCode | Should -Be 0
            $entries[0].Started | Should -BeGreaterThan $entries[1].Started
        }

        It 'warns about a damaged line instead of losing the ledger' {
            $path = Join-Path $script:Workspace.Path 'Workbench' 'Runs.jsonl'
            Add-Content -LiteralPath $path -Value 'this is not json' -Encoding utf8
            $warnings = @()
            $entries = @(Get-MigrationRunLedger -Workspace $script:Workspace -WarningVariable warnings)
            $entries.Count | Should -Be 2
            @($warnings).Count | Should -BeGreaterThan 0
        }

        It 'treats a workspace with no ledger as an empty ledger' {
            $empty = New-TestWorkspace -Name 'ReadLedgerEmpty'
            @(Get-MigrationRunLedger -Workspace $empty).Count | Should -Be 0
        }
    }
}

Describe 'Read-MigrationFileTail' {

    It 'returns only complete lines and resumes from where it stopped' {
        InModuleScope M365Migration -Parameters @{ Drive = $TestDrive } {
            param($Drive)
            $path = Join-Path $Drive 'tail.txt'
            Set-Content -LiteralPath $path -Value "first`nsecond`npart" -NoNewline -Encoding utf8

            $offset = [long]0
            $lines = @(Read-MigrationFileTail -Path $path -Offset ([ref]$offset))
            $lines.Count | Should -Be 2
            $lines[0] | Should -BeExactly 'first'
            $lines[1] | Should -BeExactly 'second'

            # The partial line is left for the next call rather than shown cut in half.
            Add-Content -LiteralPath $path -Value "ial`n" -NoNewline -Encoding utf8
            $more = @(Read-MigrationFileTail -Path $path -Offset ([ref]$offset))
            $more.Count | Should -Be 1
            $more[0] | Should -BeExactly 'partial'
        }
    }

    It 'returns the trailing partial line only when it is flushed' {
        InModuleScope M365Migration -Parameters @{ Drive = $TestDrive } {
            param($Drive)
            $path = Join-Path $Drive 'flush.txt'
            Set-Content -LiteralPath $path -Value 'no newline at the end' -NoNewline -Encoding utf8

            $offset = [long]0
            @(Read-MigrationFileTail -Path $path -Offset ([ref]$offset)).Count | Should -Be 0

            # The final read after the child exits: this is all that line will ever be.
            $flushed = @(Read-MigrationFileTail -Path $path -Offset ([ref]$offset) -Flush)
            $flushed.Count | Should -Be 1
            $flushed[0] | Should -BeExactly 'no newline at the end'
        }
    }

    It 'returns nothing for a file that is not there yet' {
        InModuleScope M365Migration -Parameters @{ Drive = $TestDrive } {
            param($Drive)
            $offset = [long]0
            $missing = Join-Path $Drive 'never-written.txt'
            @(Read-MigrationFileTail -Path $missing -Offset ([ref]$offset)).Count | Should -Be 0
            $offset | Should -Be 0
        }
    }

    It 'reads a line the writer still has open' {
        InModuleScope M365Migration -Parameters @{ Drive = $TestDrive } {
            param($Drive)
            $path = Join-Path $Drive 'open.txt'
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("held open`n")
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()

                $offset = [long]0
                $lines = @(Read-MigrationFileTail -Path $path -Offset ([ref]$offset))
                $lines[0] | Should -BeExactly 'held open'
            }
            finally { $stream.Dispose() }
        }
    }
}
