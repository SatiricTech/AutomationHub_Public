#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
.SYNOPSIS
    Pester tests for Register-WinServiceWatchdogTask.ps1 (DESIGN.md section 5.1).

.DESCRIPTION
    The installer is dot-sourced so its functions can be exercised without running the
    script body. Every Windows-only command (ScheduledTasks cmdlets, icacls, sc.exe,
    powershell.exe) is declared as a stub function and mocked, and the event source wrappers
    (Test-WatchdogEventSource, Add-WatchdogEventSource, which wrap the Windows-only
    System.Diagnostics.EventLog calls) are mocked, so the suite runs on any platform. The
    worker is never executed: the installer reaches it only through the Invoke-WatchdogWorker
    helper, which these tests mock per the -ValidateConfig contract (exit 0 valid, exit 2
    invalid).

    File-system effects are real but confined to a per-run scratch folder under the
    platform temp directory, removed in AfterAll. $env:ProgramData is pointed at that
    scratch folder before the script is dot-sourced so default paths never touch the host.
#>

# Stub functions carry the names of the Windows-only cmdlets they stand in for so Pester can
# mock them; they change nothing. The fixture builder writes only inside the scratch folder.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Stubs must carry real cmdlet names to be mockable; nothing here changes system state.')]
param ()

BeforeAll {
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "swd-register-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null

    $script:OriginalProgramData = $env:ProgramData
    $env:ProgramData = Join-Path $script:TestRoot 'ProgramData'

    $script:WorkerFileName = 'Invoke-WinServiceWatchdog.ps1'
    $script:ExampleConfigFileName = 'ServiceWatchdog.example.json'
    $script:ExampleConfigJson = @'
{
  "SchemaVersion": 1,
  "SiteName": "Example Org",
  "Services": [ "Spooler", "W3SVC" ],
  "MaxRunSeconds": 240,
  "Webhook": {
    "Url": "https://REPLACE-ME.azurewebsites.net/api/servicewatchdog/alert",
    "FunctionKey": "REPLACE_WITH_FUNCTION_KEY",
    "TimeoutSeconds": 30
  }
}
'@

    # Stubs for Windows-only commands. Pester can only mock a command that exists, and none
    # of these do on macOS/Linux. Shapes mirror the real cmdlets closely enough for the
    # installer to work with the objects they return (settable Delay/Repetition on triggers,
    # ISO 8601 durations on the settings set, as the real CIM objects expose).
    function New-ScheduledTaskPrincipal {
        [CmdletBinding()]
        param ($UserId, $RunLevel)
        [pscustomobject]@{ UserId = $UserId; RunLevel = $RunLevel }
    }

    function New-ScheduledTaskTrigger {
        [CmdletBinding()]
        param (
            [switch]$AtStartup,
            [switch]$Daily,
            [switch]$Once,
            $At,
            [timespan]$RepetitionInterval,
            [timespan]$RepetitionDuration
        )
        $repetition = [pscustomobject]@{ Interval = $null; Duration = $null }
        if ($PSBoundParameters.ContainsKey('RepetitionInterval')) {
            $repetition.Interval = [System.Xml.XmlConvert]::ToString($RepetitionInterval)
        }
        if ($PSBoundParameters.ContainsKey('RepetitionDuration')) {
            $repetition.Duration = [System.Xml.XmlConvert]::ToString($RepetitionDuration)
        }
        $kind = if ($AtStartup) { 'Boot' } elseif ($Daily) { 'Daily' } else { 'Once' }
        [pscustomobject]@{ Kind = $kind; At = $At; Delay = $null; Repetition = $repetition }
    }

    function New-ScheduledTaskSettingsSet {
        [CmdletBinding()]
        param (
            $MultipleInstances,
            [timespan]$ExecutionTimeLimit,
            [switch]$StartWhenAvailable,
            [switch]$AllowStartIfOnBatteries,
            [switch]$DontStopIfGoingOnBatteries
        )
        [pscustomobject]@{
            MultipleInstances          = $MultipleInstances
            ExecutionTimeLimit         = [System.Xml.XmlConvert]::ToString($ExecutionTimeLimit)
            StartWhenAvailable         = $StartWhenAvailable.IsPresent
            AllowStartIfOnBatteries    = $AllowStartIfOnBatteries.IsPresent
            DontStopIfGoingOnBatteries = $DontStopIfGoingOnBatteries.IsPresent
        }
    }

    function New-ScheduledTaskAction {
        [CmdletBinding()]
        param ($Execute, $Argument)
        [pscustomobject]@{ Execute = $Execute; Argument = $Argument }
    }

    function Register-ScheduledTask {
        [CmdletBinding()]
        param ($TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force)
    }

    function Start-ScheduledTask {
        [CmdletBinding()]
        param ($TaskName)
    }

    function Get-ScheduledTaskInfo {
        [CmdletBinding()]
        param ($TaskName)
        [pscustomobject]@{ TaskName = $TaskName; NextRunTime = (Get-Date).AddMinutes(5) }
    }

    function icacls { }
    function sc.exe { }
    function powershell.exe { }

    . (Join-Path $PSScriptRoot '..' 'Endpoint' 'Register-WinServiceWatchdogTask.ps1')

    function New-RegisterFixture {
        # Builds an isolated source folder (worker + example config) and install folder and
        # returns the full argument set for Invoke-WatchdogRegistration with defaults from
        # DESIGN.md 5.1. Tests override individual keys.
        param (
            [switch]$WithConfig,
            [switch]$WithInstalledWorker,
            [switch]$WithSourceConfig,
            [string]$ConfigJson = $script:ExampleConfigJson
        )
        $id = [guid]::NewGuid().ToString('N')
        $source = Join-Path $script:TestRoot "source-$id"
        $install = Join-Path $script:TestRoot "install-$id"
        New-Item -Path $source -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source $script:WorkerFileName) -Value '# worker source'
        Set-Content -LiteralPath (Join-Path $source $script:ExampleConfigFileName) -Value $script:ExampleConfigJson

        if ($WithSourceConfig) {
            # A pre-filled config sitting in the source folder, marked so tests can tell it
            # apart from both the example config and an existing install-folder config.
            Set-Content -LiteralPath (Join-Path $source 'ServiceWatchdog.json') `
                -Value ($script:ExampleConfigJson -replace 'Example Org', 'Seeded From Source')
        }

        if ($WithConfig -or $WithInstalledWorker) {
            New-Item -Path $install -ItemType Directory -Force | Out-Null
        }
        if ($WithConfig) {
            Set-Content -LiteralPath (Join-Path $install 'ServiceWatchdog.json') -Value $ConfigJson
        }
        if ($WithInstalledWorker) {
            Set-Content -LiteralPath (Join-Path $install $script:WorkerFileName) -Value '# previously installed worker'
        }

        @{
            InstallPath               = $install
            SourcePath                = $source
            ConfigPath                = Join-Path $install 'ServiceWatchdog.json'
            TaskName                  = 'ServiceWatchdog'
            IntervalMinutes           = 5
            StartupDelayMinutes       = 5
            ExecutionTimeLimitSeconds = 420
        }
    }

    function Get-LogText {
        if (Test-Path -LiteralPath $script:LogPath) {
            return (Get-Content -LiteralPath $script:LogPath -Raw)
        }
        return ''
    }
}

AfterAll {
    $env:ProgramData = $script:OriginalProgramData
    if ($script:TestRoot -and (Test-Path -LiteralPath $script:TestRoot)) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Register-WinServiceWatchdogTask' {

    BeforeEach {
        # Fresh log file per test so assertions on log content are isolated; console output
        # is swallowed so the test run stays quiet.
        $script:LogPath = Join-Path $script:TestRoot "register-$([guid]::NewGuid().ToString('N')).log"
        $script:Verbosity = 'Low'
        Mock Write-Host { }

        # Happy-path defaults: worker validates, event source already exists, icacls succeeds,
        # nothing else is touched.
        Mock Invoke-WatchdogWorker { return 0 }
        Mock Test-WatchdogEventSource { return $true }
        Mock icacls { $global:LASTEXITCODE = 0 }
        Mock Get-WatchdogPathOwnerSid { 'S-1-5-32-544' }
        Mock Get-WatchdogPathAccessRule {
            @(
                @{ Sid = 'S-1-5-18'; IsInherited = $false; Type = 'Allow' }
                @{ Sid = 'S-1-5-32-544'; IsInherited = $false; Type = 'Allow' }
            )
        }
        Mock sc.exe { $global:LASTEXITCODE = 0 }
        Mock Add-WatchdogEventSource { }
        Mock Register-ScheduledTask { }
        Mock Start-ScheduledTask { }
    }

    Context 'Script contract' {
        BeforeAll {
            $script:ScriptPath = Join-Path $PSScriptRoot '..' 'Endpoint' 'Register-WinServiceWatchdogTask.ps1'
            $tokens = $null
            $errors = $null
            $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$tokens, [ref]$errors)
            $script:ScriptCommand = Get-Command -Name $script:ScriptPath
        }

        It 'requires Windows PowerShell 5.1 and elevation' {
            $script:ScriptAst.ScriptRequirements.RequiredPSVersion | Should -Be ([version]'5.1')
            $script:ScriptAst.ScriptRequirements.IsElevationRequired | Should -BeTrue
        }

        It 'exposes the 5.1 parameter set with spec defaults' {
            $parameters = $script:ScriptCommand.Parameters
            foreach ($name in @('InstallPath', 'SourcePath', 'ConfigPath', 'TaskName', 'IntervalMinutes',
                    'StartupDelayMinutes', 'ExecutionTimeLimitSeconds', 'SetServiceRecovery', 'RunNow',
                    'TestAlert', 'Force', 'DryRun', 'Verbosity', 'LogPath')) {
                $parameters.ContainsKey($name) | Should -BeTrue -Because "parameter $name is in the spec"
            }
            $verbositySet = $parameters['Verbosity'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $verbositySet.ValidValues | Should -Be @('Low', 'Medium', 'High')
        }

        It 'rejects an interval or time limit outside its range' {
            $intervalRange = $script:ScriptCommand.Parameters['IntervalMinutes'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $intervalRange.MinRange | Should -Be 1
            $limitRange = $script:ScriptCommand.Parameters['ExecutionTimeLimitSeconds'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $limitRange.MinRange | Should -BeGreaterThan 0
        }

        It 'does not run the script body when dot-sourced' {
            # The BeforeAll dot-source above would have called exit if the guard were missing;
            # reaching this assertion proves the guard. Also confirm the entry point exists.
            Get-Command -Name Invoke-WatchdogRegistration -CommandType Function | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Step 1: files' {
        It 'exits 2 without copying when the worker is already installed and -Force is absent' {
            $fixture = New-RegisterFixture -WithConfig -WithInstalledWorker
            $installedWorker = Join-Path $fixture.InstallPath $script:WorkerFileName

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Get-Content -LiteralPath $installedWorker -Raw | Should -Match 'previously installed'
            Get-LogText | Should -Match '-Force'
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'overwrites the installed worker when -Force is set' {
            $fixture = New-RegisterFixture -WithConfig -WithInstalledWorker
            $installedWorker = Join-Path $fixture.InstallPath $script:WorkerFileName

            $exitCode = Invoke-WatchdogRegistration @fixture -Force

            $exitCode | Should -Be 0
            Get-Content -LiteralPath $installedWorker -Raw | Should -Match 'worker source'
        }

        It 'copies the worker into a new install folder' {
            $fixture = New-RegisterFixture -WithConfig

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 0
            Get-Content -LiteralPath (Join-Path $fixture.InstallPath $script:WorkerFileName) -Raw |
                Should -Match 'worker source'
        }

        It 'exits 2 when the source worker is missing' {
            $fixture = New-RegisterFixture -WithConfig
            Remove-Item -LiteralPath (Join-Path $fixture.SourcePath $script:WorkerFileName)

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match ([regex]::Escape($script:WorkerFileName))
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'copies the example config and exits 2 naming the file when no config exists' {
            $fixture = New-RegisterFixture

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Test-Path -LiteralPath $fixture.ConfigPath | Should -BeTrue
            Get-Content -LiteralPath $fixture.ConfigPath -Raw | Should -Match 'REPLACE_WITH_FUNCTION_KEY'
            Get-LogText | Should -Match ([regex]::Escape($fixture.ConfigPath))
            Should -Invoke Invoke-WatchdogWorker -Times 0
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'seeds the config from a ServiceWatchdog.json in the source folder and registers in one pass' {
            $fixture = New-RegisterFixture -WithSourceConfig

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 0
            Get-Content -LiteralPath $fixture.ConfigPath -Raw | Should -Match 'Seeded From Source'
            Should -Invoke Invoke-WatchdogWorker -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains '-ValidateConfig' -and $Arguments -contains $fixture.ConfigPath
            }
            Should -Invoke Register-ScheduledTask -Times 1 -Exactly
        }

        It 'seeds inside the locked folder, after the ACL is applied' {
            $fixture = New-RegisterFixture -WithSourceConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $log = Get-LogText
            $log.IndexOf('Restrict') | Should -BeLessThan $log.IndexOf('Copy source config')
        }

        It 'keeps an existing install config and logs that the source-folder config was ignored' {
            $fixture = New-RegisterFixture -WithConfig -WithSourceConfig

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 0
            $config = Get-Content -LiteralPath $fixture.ConfigPath -Raw
            $config | Should -Match 'Example Org'
            $config | Should -Not -Match 'Seeded From Source'
            Get-LogText | Should -Match 'ignored'
        }

        It 'still copies the example config and exits 2 when the source folder holds no real config' {
            $fixture = New-RegisterFixture

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Get-Content -LiteralPath $fixture.ConfigPath -Raw | Should -Match 'REPLACE_WITH_FUNCTION_KEY'
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'copies nothing under -DryRun but validates the source config and reports exit 0' {
            $fixture = New-RegisterFixture -WithSourceConfig

            $exitCode = Invoke-WatchdogRegistration @fixture -DryRun

            $exitCode | Should -Be 0
            Test-Path -LiteralPath $fixture.ConfigPath | Should -BeFalse
            Should -Invoke Invoke-WatchdogWorker -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains (Join-Path $fixture.SourcePath 'ServiceWatchdog.json')
            }
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'locks the install folder on the first run, before the example config is copied' {
            $fixture = New-RegisterFixture

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Test-Path -LiteralPath $fixture.ConfigPath | Should -BeTrue
            Should -Invoke icacls -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq $fixture.InstallPath -and $args -contains '/inheritance:r'
            }
            $log = Get-LogText
            $log.IndexOf('Restrict') | Should -BeLessThan $log.IndexOf('Copy example config')
        }

        It 'refuses an existing install folder owned by another account with exit 2 and touches nothing' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Get-WatchdogPathOwnerSid { 'S-1-5-21-1000000000-2000000000-3000000000-1001' }

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'S-1-5-21-1000000000-2000000000-3000000000-1001'
            Test-Path -LiteralPath (Join-Path $fixture.InstallPath $script:WorkerFileName) | Should -BeFalse
            Should -Invoke icacls -Times 0
            Should -Invoke Invoke-WatchdogWorker -Times 0
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'accepts an existing install folder owned by SYSTEM' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Get-WatchdogPathOwnerSid { 'S-1-5-18' }

            Invoke-WatchdogRegistration @fixture | Should -Be 0
        }

        It 'creates the install folder when it does not exist and the config has a custom name inside it' {
            $fixture = New-RegisterFixture
            New-Item -Path $fixture.InstallPath -ItemType Directory -Force | Out-Null
            $custom = Join-Path $fixture.InstallPath 'Site-A.json'
            Set-Content -LiteralPath $custom -Value $script:ExampleConfigJson
            $fixture.ConfigPath = $custom

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $fixture.InstallPath $script:WorkerFileName) | Should -BeTrue
        }

        It 'refuses a config outside the install folder with exit 2 before creating anything' {
            $fixture = New-RegisterFixture
            $elsewhereFolder = Join-Path $script:TestRoot "ops-$([guid]::NewGuid().ToString('N'))"
            New-Item -Path $elsewhereFolder -ItemType Directory -Force | Out-Null
            $elsewhere = Join-Path $elsewhereFolder 'ServiceWatchdog.json'
            Set-Content -LiteralPath $elsewhere -Value $script:ExampleConfigJson
            $fixture.ConfigPath = $elsewhere

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Test-Path -LiteralPath $fixture.InstallPath | Should -BeFalse
            Should -Invoke icacls -Times 0
            Should -Invoke Invoke-WatchdogWorker -Times 0
            Should -Invoke Register-ScheduledTask -Times 0
            $log = Get-LogText
            $log | Should -Match ([regex]::Escape($fixture.InstallPath))
            $log | Should -Match 'outside the install folder'
        }

        It 'refuses a config outside the install folder even when it does not exist yet' {
            # Without the guard, step 1 would create the foreign folder and copy the example
            # config into it, leaving the function key under that folder's inherited DACL.
            $fixture = New-RegisterFixture
            $elsewhereFolder = Join-Path $script:TestRoot "ops-$([guid]::NewGuid().ToString('N'))"
            $fixture.ConfigPath = Join-Path $elsewhereFolder 'ServiceWatchdog.json'

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Test-Path -LiteralPath $elsewhereFolder | Should -BeFalse
            Test-Path -LiteralPath $fixture.InstallPath | Should -BeFalse
        }

        It 'treats a sibling folder that shares the install folder name as a prefix as outside' {
            $fixture = New-RegisterFixture
            $lookalike = $fixture.InstallPath + '-other'
            New-Item -Path $lookalike -ItemType Directory -Force | Out-Null
            $fixture.ConfigPath = Join-Path $lookalike 'ServiceWatchdog.json'
            Set-Content -LiteralPath $fixture.ConfigPath -Value $script:ExampleConfigJson

            Invoke-WatchdogRegistration @fixture | Should -Be 2

            Should -Invoke icacls -Times 0
        }

        It 'accepts a config in a subfolder of the install folder' {
            $fixture = New-RegisterFixture
            $sub = Join-Path $fixture.InstallPath 'Config'
            New-Item -Path $sub -ItemType Directory -Force | Out-Null
            $fixture.ConfigPath = Join-Path $sub 'ServiceWatchdog.json'
            Set-Content -LiteralPath $fixture.ConfigPath -Value $script:ExampleConfigJson

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            Should -Invoke icacls -Times 3 -Exactly -ParameterFilter { $args[0] -eq $fixture.InstallPath }
        }

        It 'exits 2 when neither a config nor the example config exists' {
            $fixture = New-RegisterFixture
            Remove-Item -LiteralPath (Join-Path $fixture.SourcePath $script:ExampleConfigFileName)

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Test-Path -LiteralPath $fixture.ConfigPath | Should -BeFalse
            Get-LogText | Should -Match ([regex]::Escape($script:ExampleConfigFileName))
        }
    }

    Context 'Step 1: path canonicalization' {
        It 'bakes absolute paths into the task action and the ACL call when InstallPath is relative' {
            $fixture = New-RegisterFixture -WithConfig
            $absoluteInstall = $fixture.InstallPath
            $fixture.InstallPath = Split-Path -Path $absoluteInstall -Leaf
            $fixture.ConfigPath = Join-Path $fixture.InstallPath 'ServiceWatchdog.json'
            $script:TaskAction = $null
            Mock Register-ScheduledTask { $script:TaskAction = $Action }

            Push-Location -LiteralPath $script:TestRoot
            try {
                $exitCode = Invoke-WatchdogRegistration @fixture
            }
            finally {
                Pop-Location
            }

            $exitCode | Should -Be 0
            $script:TaskAction.Argument | Should -BeLike "*-File `"$absoluteInstall*Invoke-WinServiceWatchdog.ps1`"*"
            $script:TaskAction.Argument | Should -Not -BeLike "*-File `"$($fixture.InstallPath)*"
            Should -Invoke icacls -Times 3 -Exactly -ParameterFilter { $args[0] -eq $absoluteInstall }
            Should -Invoke Invoke-WatchdogWorker -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains (Join-Path $absoluteInstall 'ServiceWatchdog.json')
            }
        }

        It 'collapses .. segments before the containment check, the ACL call and the task action' {
            $fixture = New-RegisterFixture -WithConfig
            $absoluteInstall = $fixture.InstallPath
            $fixture.InstallPath = Join-Path (Join-Path $absoluteInstall 'sub') '..'
            $script:TaskAction = $null
            Mock Register-ScheduledTask { $script:TaskAction = $Action }

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $script:TaskAction.Argument | Should -Not -Match '\.\.'
            $script:TaskAction.Argument | Should -BeLike "*-File `"$absoluteInstall*"
            Should -Invoke icacls -Times 3 -Exactly -ParameterFilter { $args[0] -eq $absoluteInstall }
        }

        It 'refuses an InstallPath that resolves to ProgramData through .. with exit 2 and no icacls call' {
            $fixture = New-RegisterFixture -WithConfig
            $fixture.InstallPath = Join-Path (Join-Path $env:ProgramData 'ServiceWatchdog') '..'
            $fixture.ConfigPath = Join-Path $env:ProgramData 'ServiceWatchdog.json'

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match 'filesystem root or a Windows system folder'
            Should -Invoke icacls -Times 0
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'refuses a filesystem root as InstallPath' {
            $fixture = New-RegisterFixture -WithConfig
            $fixture.InstallPath = [System.IO.Path]::GetPathRoot($fixture.InstallPath)
            $fixture.ConfigPath = Join-Path $fixture.InstallPath 'ServiceWatchdog.json'

            Invoke-WatchdogRegistration @fixture | Should -Be 2
            Should -Invoke icacls -Times 0
        }
    }

    Context 'Step 2: ACL' {
        It 'locks the install folder to SYSTEM and Administrators with inheritance removed' {
            $fixture = New-RegisterFixture -WithConfig

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 0
            Should -Invoke icacls -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq $fixture.InstallPath -and
                $args -contains '/inheritance:r' -and
                $args -contains '/grant:r' -and
                $args -contains '*S-1-5-18:(OI)(CI)F' -and
                $args -contains '*S-1-5-32-544:(OI)(CI)F'
            }
        }

        It 'resets explicit entries first and takes ownership of the whole tree afterwards' {
            $script:IcaclsCalls = [System.Collections.Generic.List[string]]::new()
            Mock icacls { $script:IcaclsCalls.Add(($args -join ' ')); $global:LASTEXITCODE = 0 }
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $script:IcaclsCalls.Count | Should -Be 3
            $script:IcaclsCalls[0] | Should -Be "$($fixture.InstallPath) /reset /T"
            $script:IcaclsCalls[1] | Should -Match '/inheritance:r /grant:r'
            $script:IcaclsCalls[2] | Should -Be "$($fixture.InstallPath) /setowner *S-1-5-32-544 /T"
            Should -Invoke Get-WatchdogPathAccessRule -Times 1 -Exactly -ParameterFilter {
                $Path -eq $fixture.InstallPath
            }
        }

        It 'fails the run with exit 1 when the ACL read back still carries a foreign entry' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Get-WatchdogPathAccessRule {
                @(
                    @{ Sid = 'S-1-5-18'; IsInherited = $false; Type = 'Allow' }
                    @{ Sid = 'S-1-5-32-544'; IsInherited = $false; Type = 'Allow' }
                    @{ Sid = 'S-1-5-21-1000000000-2000000000-3000000000-1001'; IsInherited = $false; Type = 'Allow' }
                )
            }

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 1
            Get-LogText | Should -Match 'S-1-5-21-1000000000-2000000000-3000000000-1001'
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'fails the run when the read back is missing one of the expected entries or one is inherited' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Get-WatchdogPathAccessRule { @(@{ Sid = 'S-1-5-18'; IsInherited = $false; Type = 'Allow' }) }
            Invoke-WatchdogRegistration @fixture | Should -Be 1
            Get-LogText | Should -Match 'missing the entry for SID S-1-5-32-544'

            Mock Get-WatchdogPathAccessRule {
                @(
                    @{ Sid = 'S-1-5-18'; IsInherited = $false; Type = 'Allow' }
                    @{ Sid = 'S-1-5-32-544'; IsInherited = $true; Type = 'Allow' }
                )
            }
            Invoke-WatchdogRegistration @fixture -Force | Should -Be 1
        }

        It 'fails the run with exit 1 and no task when icacls returns non-zero' {
            $fixture = New-RegisterFixture -WithConfig
            Mock icacls { $global:LASTEXITCODE = 5 }

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 1
            Get-LogText | Should -Match 'icacls'
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'Set-WatchdogInstallAcl throws on a non-zero icacls exit code' {
            Mock icacls { $global:LASTEXITCODE = 1332 }
            { Set-WatchdogInstallAcl -Path (Join-Path $script:TestRoot 'acl-probe') } | Should -Throw '*1332*'
        }
    }

    Context 'Step 3: config validation' {
        It 'does not pass -DryRun to the worker on a real run' {
            $fixture = New-RegisterFixture -WithConfig
            Invoke-WatchdogRegistration @fixture | Should -Be 0
            Should -Invoke Invoke-WatchdogWorker -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains '-ValidateConfig' -and $Arguments -notcontains '-DryRun'
            }
        }

        It 'validates through the worker with -ValidateConfig and the config path' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Out-Null

            Should -Invoke Invoke-WatchdogWorker -Times 1 -Exactly -ParameterFilter {
                $WorkerPath -eq (Join-Path $fixture.InstallPath $script:WorkerFileName) -and
                $Arguments -contains '-ValidateConfig' -and
                $Arguments -contains $fixture.ConfigPath
            }
        }

        It 'exits 2 and does not register the task when the worker reports invalid config' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Invoke-WatchdogWorker { return 2 }

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Should -Invoke Register-ScheduledTask -Times 0
            Should -Invoke Add-WatchdogEventSource -Times 0
        }

        It 'exits 2 when the execution limit is below MaxRunSeconds + 2*(2*TimeoutSeconds+5) + 15' {
            # 240 + 2 * (2 * 30 + 5) + 15 = 385
            $fixture = New-RegisterFixture -WithConfig
            $fixture.ExecutionTimeLimitSeconds = 384

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 2
            Get-LogText | Should -Match '385'
            Should -Invoke Register-ScheduledTask -Times 0
        }

        It 'accepts an execution limit exactly at the worst-case run time' {
            $fixture = New-RegisterFixture -WithConfig
            $fixture.ExecutionTimeLimitSeconds = 385

            Invoke-WatchdogRegistration @fixture | Should -Be 0
        }

        It 'uses the spec defaults for MaxRunSeconds and TimeoutSeconds when the config omits them' {
            $minimal = '{ "SchemaVersion": 1, "Services": [ "Spooler" ], "Webhook": { "Url": "https://example.com/" } }'
            $fixture = New-RegisterFixture -WithConfig -ConfigJson $minimal
            $fixture.ExecutionTimeLimitSeconds = 384

            Invoke-WatchdogRegistration @fixture | Should -Be 2
        }

        It 'honors larger values from the config' {
            $slow = '{ "Services": [ "Spooler" ], "MaxRunSeconds": 600, "Webhook": { "TimeoutSeconds": 60 } }'
            $fixture = New-RegisterFixture -WithConfig -ConfigJson $slow
            # 600 + 2 * (2 * 60 + 5) + 15 = 865
            $fixture.ExecutionTimeLimitSeconds = 864

            Invoke-WatchdogRegistration @fixture | Should -Be 2
            $fixture.ExecutionTimeLimitSeconds = 865
            Invoke-WatchdogRegistration @fixture -Force | Should -Be 0
        }
    }

    Context 'Step 4: event source' {
        It 'registers the event source only when it does not exist' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Test-WatchdogEventSource { return $false }

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            Should -Invoke Add-WatchdogEventSource -Times 1 -Exactly -ParameterFilter {
                $LogName -eq 'Application' -and $Source -eq 'ServiceWatchdog'
            }
        }

        It 'leaves an existing event source alone' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            Should -Invoke Add-WatchdogEventSource -Times 0
        }
    }

    Context 'Step 5: task registration' {
        BeforeEach {
            Mock Register-ScheduledTask {
                $script:Registered = @{
                    TaskName    = $TaskName
                    Action      = $Action
                    Trigger     = @($Trigger)
                    Principal   = $Principal
                    Settings    = $Settings
                    Description = $Description
                    Force       = $Force.IsPresent
                }
            }
        }

        It 'registers with -Force as SYSTEM at the highest run level' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            Should -Invoke Register-ScheduledTask -Times 1 -Exactly
            $script:Registered.TaskName | Should -Be 'ServiceWatchdog'
            $script:Registered.Force | Should -BeTrue
            $script:Registered.Principal.UserId | Should -Be 'NT AUTHORITY\SYSTEM'
            $script:Registered.Principal.RunLevel | Should -Be 'Highest'
        }

        It 'uses a boot trigger delayed by StartupDelayMinutes and a daily trigger repeating every IntervalMinutes' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $triggers = $script:Registered.Trigger
            $triggers.Count | Should -Be 2
            $boot = $triggers | Where-Object { $_.Kind -eq 'Boot' }
            $daily = $triggers | Where-Object { $_.Kind -eq 'Daily' }
            $boot | Should -Not -BeNullOrEmpty
            $boot.Delay | Should -Be 'PT5M'
            $daily | Should -Not -BeNullOrEmpty
            $daily.Repetition.Interval | Should -Be 'PT5M'
            $daily.Repetition.Duration | Should -Be 'P1D'
        }

        It 'honors custom interval and startup delay values' {
            $fixture = New-RegisterFixture -WithConfig
            $fixture.IntervalMinutes = 10
            $fixture.StartupDelayMinutes = 3

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            ($script:Registered.Trigger | Where-Object { $_.Kind -eq 'Boot' }).Delay | Should -Be 'PT3M'
            ($script:Registered.Trigger | Where-Object { $_.Kind -eq 'Daily' }).Repetition.Interval | Should -Be 'PT10M'
        }

        It 'applies the settings from the spec' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $settings = $script:Registered.Settings
            $settings.MultipleInstances | Should -Be 'IgnoreNew'
            $settings.ExecutionTimeLimit | Should -Be 'PT7M'
            $settings.StartWhenAvailable | Should -BeTrue
            $settings.AllowStartIfOnBatteries | Should -BeTrue
            $settings.DontStopIfGoingOnBatteries | Should -BeTrue
        }

        It 'runs the installed worker hidden with no profile and no secrets in the arguments' {
            $fixture = New-RegisterFixture -WithConfig
            $workerPath = Join-Path $fixture.InstallPath $script:WorkerFileName

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $action = $script:Registered.Action
            $action.Execute | Should -Be 'powershell.exe'
            $expected = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$workerPath`""
            $action.Argument | Should -BeLike "*$expected*"
            $action.Argument | Should -Not -Match 'ConfigPath'
            $action.Argument | Should -Not -Match 'FunctionKey'
        }

        It 'passes -ConfigPath to the worker only when the config has a non-default name' {
            $fixture = New-RegisterFixture -WithConfig
            $custom = Join-Path $fixture.InstallPath 'Site-A.json'
            Move-Item -LiteralPath $fixture.ConfigPath -Destination $custom
            $fixture.ConfigPath = $custom

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $script:Registered.Action.Argument | Should -BeLike "*-ConfigPath `"$custom`"*"
            $script:Registered.Action.Argument | Should -Not -Match 'FunctionKey'
        }

        It 'names the repository and version in the description' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $script:Registered.Description | Should -Match 'AutomationHub'
            $script:Registered.Description | Should -Match '1\.0\.0'
        }

        It 'exits 1 when Register-ScheduledTask throws' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Register-ScheduledTask { throw 'Access is denied' }

            $exitCode = Invoke-WatchdogRegistration @fixture

            $exitCode | Should -Be 1
            Get-LogText | Should -Match 'Access is denied'
            Should -Invoke Start-ScheduledTask -Times 0
        }
    }

    Context 'Step 6: service recovery' {
        It 'sets SCM failure actions once per configured service' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture -SetServiceRecovery | Should -Be 0

            Should -Invoke sc.exe -Times 2 -Exactly
            foreach ($service in @('Spooler', 'W3SVC')) {
                Should -Invoke sc.exe -Times 1 -Exactly -ParameterFilter {
                    ($args -join ' ') -eq "failure $service reset= 86400 actions= restart/60000/restart/120000/none/0"
                }
            }
        }

        It 'does not touch SCM failure actions without the switch' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            Should -Invoke sc.exe -Times 0
        }

        It 'warns and exits 0 when the config lists no services' {
            $empty = '{ "Services": [], "MaxRunSeconds": 240, "Webhook": { "TimeoutSeconds": 30 } }'
            $fixture = New-RegisterFixture -WithConfig -ConfigJson $empty

            Invoke-WatchdogRegistration @fixture -SetServiceRecovery | Should -Be 0

            Should -Invoke sc.exe -Times 0
            Get-LogText | Should -Match 'No services'
        }

        It 'continues past a failing service and exits 50' {
            $fixture = New-RegisterFixture -WithConfig
            Mock sc.exe { $global:LASTEXITCODE = 1060 } -ParameterFilter { $args[1] -eq 'Spooler' }

            $exitCode = Invoke-WatchdogRegistration @fixture -SetServiceRecovery

            $exitCode | Should -Be 50
            Should -Invoke sc.exe -Times 2 -Exactly
            Get-LogText | Should -Match 'Spooler.*1060'
        }
    }

    Context 'Step 7: RunNow and TestAlert' {
        It 'starts the task when -RunNow is set' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture -RunNow | Should -Be 0

            Should -Invoke Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'ServiceWatchdog' }
        }

        It 'does not start the task without -RunNow' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            Should -Invoke Start-ScheduledTask -Times 0
        }

        It 'sends a test alert through the worker when -TestAlert is set' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture -TestAlert | Should -Be 0

            Should -Invoke Invoke-WatchdogWorker -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains '-TestAlert' -and $Arguments -contains $fixture.ConfigPath
            }
        }

        It 'exits 10 when the test alert is not delivered' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Invoke-WatchdogWorker { return 10 } -ParameterFilter { $Arguments -contains '-TestAlert' }

            $exitCode = Invoke-WatchdogRegistration @fixture -TestAlert

            $exitCode | Should -Be 10
            Get-LogText | Should -Match 'test alert'
        }
    }

    Context 'Step 8: summary' {
        It 'reports install path, task name, config path and log path' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture | Should -Be 0

            $log = Get-LogText
            $log | Should -Match ([regex]::Escape($fixture.InstallPath))
            $log | Should -Match 'ServiceWatchdog'
            $log | Should -Match ([regex]::Escape($fixture.ConfigPath))
            $log | Should -Match ([regex]::Escape($script:LogPath))
        }
    }

    Context 'Console verbosity' {
        It 'shows only errors and success at Low' {
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture -DryRun | Should -Be 0

            Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*[[]WARNING[]]*' }
            Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*[[]INFO[]]*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*[[]SUCCESS[]]*' }
        }

        It 'shows warnings and info at High' {
            $script:Verbosity = 'High'
            $fixture = New-RegisterFixture -WithConfig

            Invoke-WatchdogRegistration @fixture -DryRun | Should -Be 0

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*[[]WARNING[]]*DRYRUN*' }
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*[[]INFO[]]*' }
        }
    }

    Context 'DryRun' {
        It 'performs zero mutations while still validating' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Test-WatchdogEventSource { return $false }

            $exitCode = Invoke-WatchdogRegistration @fixture -DryRun -SetServiceRecovery -RunNow -TestAlert

            $exitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $fixture.InstallPath $script:WorkerFileName) | Should -BeFalse
            Should -Invoke icacls -Times 0
            Should -Invoke Add-WatchdogEventSource -Times 0
            Should -Invoke Register-ScheduledTask -Times 0
            Should -Invoke sc.exe -Times 0
            Should -Invoke Start-ScheduledTask -Times 0
            Should -Invoke Invoke-WatchdogWorker -Times 0 -ParameterFilter { $Arguments -contains '-TestAlert' }
            Should -Invoke Invoke-WatchdogWorker -Times 1 -Exactly -ParameterFilter {
                $Arguments -contains '-ValidateConfig' -and $Arguments -contains '-DryRun'
            }
            Get-LogText | Should -Match '\[DRYRUN\]'
        }

        It 'does not copy the example config when it is missing' {
            $fixture = New-RegisterFixture

            $exitCode = Invoke-WatchdogRegistration @fixture -DryRun

            $exitCode | Should -Be 2
            Test-Path -LiteralPath $fixture.ConfigPath | Should -BeFalse
            Test-Path -LiteralPath $fixture.InstallPath | Should -BeFalse
        }

        It 'still exits 2 when validation fails' {
            $fixture = New-RegisterFixture -WithConfig
            Mock Invoke-WatchdogWorker { return 2 }

            Invoke-WatchdogRegistration @fixture -DryRun | Should -Be 2
        }
    }
}

Describe 'Invoke-WatchdogWorker' {
    # Separate Describe: the block above mocks Invoke-WatchdogWorker itself, and here the real
    # helper is under test with only the process launch mocked.
    BeforeEach {
        $script:LogPath = Join-Path $script:TestRoot "worker-$([guid]::NewGuid().ToString('N')).log"
        $script:Verbosity = 'Low'
        Mock Write-Host { }
    }

    It 'runs the worker in a fresh Windows PowerShell process and returns its exit code' {
        Mock powershell.exe { 'summary line'; $global:LASTEXITCODE = 2 }
        $worker = Join-Path $script:TestRoot 'worker-probe.ps1'
        $arguments = @('-ValidateConfig', '-ConfigPath', 'c.json')

        $exitCode = Invoke-WatchdogWorker -WorkerPath $worker -Arguments $arguments

        $exitCode | Should -Be 2
        $expected = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker " +
            '-ValidateConfig -ConfigPath c.json'
        Should -Invoke powershell.exe -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq $expected }
        Get-LogText | Should -Match 'summary line'
    }

    It 'returns 0 and logs nothing extra when the worker prints nothing' {
        Mock powershell.exe { $global:LASTEXITCODE = 0 }

        $exitCode = Invoke-WatchdogWorker -WorkerPath 'w.ps1' -Arguments @('-TestAlert')

        $exitCode | Should -Be 0
        Get-LogText | Should -Not -Match 'worker>'
    }
}
