#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

<#
.SYNOPSIS
    Pester tests for Unregister-WinServiceWatchdogTask.ps1 (DESIGN.md section 5.2).

.DESCRIPTION
    The uninstaller is dot-sourced so its functions can be exercised without running the
    script body. ScheduledTasks cmdlets are declared as stub functions and mocked, and the
    event source wrappers (Test-WatchdogEventSource, Remove-WatchdogEventSource, which wrap
    the Windows-only System.Diagnostics.EventLog calls) are mocked, so the suite runs on any
    platform. File removal is real but confined to a per-run scratch folder under the
    platform temp directory, removed in AfterAll. $env:ProgramData is pointed at that
    scratch folder before the script is dot-sourced.
#>

# Stub functions carry the names of the Windows-only cmdlets they stand in for so Pester can
# mock them; they change nothing. The fixture builder writes only inside the scratch folder.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Stubs must carry real cmdlet names to be mockable; nothing here changes system state.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
    Justification = 'The stub declares SupportsShouldProcess only so -Confirm:$false binds; it is always mocked.')]
param ()

BeforeAll {
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "swd-unregister-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $script:TestRoot -ItemType Directory -Force | Out-Null

    $script:OriginalProgramData = $env:ProgramData
    $env:ProgramData = Join-Path $script:TestRoot 'ProgramData'

    function Get-ScheduledTask {
        [CmdletBinding()]
        param ($TaskName)
    }

    function Unregister-ScheduledTask {
        [CmdletBinding(SupportsShouldProcess)]
        param ($TaskName)
    }

    . (Join-Path $PSScriptRoot '..' 'Endpoint' 'Unregister-WinServiceWatchdogTask.ps1')

    function New-UnregisterFixture {
        # Builds an install folder with the files a real installation leaves behind and
        # returns the argument set for Invoke-WatchdogUnregistration.
        $id = [guid]::NewGuid().ToString('N')
        $install = Join-Path $script:TestRoot "install-$id"
        $logs = Join-Path $install 'Logs'
        New-Item -Path $logs -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $install 'Invoke-WinServiceWatchdog.ps1') -Value '# worker'
        Set-Content -LiteralPath (Join-Path $install 'ServiceWatchdog.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $install 'ServiceWatchdog.state.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $logs 'ServiceWatchdog-20260904.log') -Value 'log'

        @{
            TaskName    = 'ServiceWatchdog'
            InstallPath = $install
        }
    }

    function Get-LogText {
        if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) {
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

Describe 'Unregister-WinServiceWatchdogTask' {

    BeforeEach {
        $script:LogPath = Join-Path $script:TestRoot "unregister-$([guid]::NewGuid().ToString('N')).log"
        $script:Verbosity = 'Low'
        Mock Write-Host { }

        # Defaults: the task exists, the event source exists.
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = $TaskName; State = 'Ready' } }
        Mock Unregister-ScheduledTask { }
        Mock Test-WatchdogEventSource { return $true }
        Mock Remove-WatchdogEventSource { }
    }

    Context 'Script contract' {
        BeforeAll {
            $script:ScriptPath = Join-Path $PSScriptRoot '..' 'Endpoint' 'Unregister-WinServiceWatchdogTask.ps1'
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

        It 'supports ShouldProcess with a high confirm impact' {
            $script:ScriptCommand.Parameters.ContainsKey('WhatIf') | Should -BeTrue
            $script:ScriptCommand.Parameters.ContainsKey('Confirm') | Should -BeTrue
            $cmdletBinding = $script:ScriptAst.ParamBlock.Attributes |
                Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
            $impact = $cmdletBinding.NamedArguments | Where-Object { $_.ArgumentName -eq 'ConfirmImpact' }
            $impact.Argument.Value | Should -Be 'High'
        }

        It 'exposes the 5.2 parameter set' {
            foreach ($name in @('TaskName', 'InstallPath', 'RemoveEventSource', 'RemoveFiles', 'Force',
                    'DryRun', 'Verbosity', 'LogPath')) {
                $script:ScriptCommand.Parameters.ContainsKey($name) |
                    Should -BeTrue -Because "parameter $name is in the spec"
            }
            $verbositySet = $script:ScriptCommand.Parameters['Verbosity'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $verbositySet.ValidValues | Should -Be @('Low', 'Medium', 'High')
        }
    }

    Context 'Task removal' {
        It 'unregisters the task when it is present' {
            $fixture = New-UnregisterFixture

            $exitCode = Invoke-WatchdogUnregistration @fixture

            $exitCode | Should -Be 0
            Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
                $TaskName -eq 'ServiceWatchdog'
            }
            Should -Invoke Remove-WatchdogEventSource -Times 0
            Test-Path -LiteralPath $fixture.InstallPath | Should -BeTrue
        }

        It 'exits 0 with a message when the task is absent' {
            $fixture = New-UnregisterFixture
            Mock Get-ScheduledTask { $null }

            $exitCode = Invoke-WatchdogUnregistration @fixture

            $exitCode | Should -Be 0
            Should -Invoke Unregister-ScheduledTask -Times 0
            Get-LogText | Should -Match 'not registered'
        }

        It 'looks up the task by the supplied name' {
            $fixture = New-UnregisterFixture
            $fixture.TaskName = 'CustomWatchdog'

            Invoke-WatchdogUnregistration @fixture | Should -Be 0

            Should -Invoke Get-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'CustomWatchdog' }
            Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter {
                $TaskName -eq 'CustomWatchdog'
            }
        }

        It 'exits 1 when Unregister-ScheduledTask throws' {
            $fixture = New-UnregisterFixture
            Mock Unregister-ScheduledTask { throw 'Access is denied' }

            $exitCode = Invoke-WatchdogUnregistration @fixture -RemoveEventSource

            $exitCode | Should -Be 1
            Get-LogText | Should -Match 'Access is denied'
            Should -Invoke Remove-WatchdogEventSource -Times 0
        }
    }

    Context 'Event source' {
        It 'removes the event source with -RemoveEventSource when it exists' {
            $fixture = New-UnregisterFixture

            Invoke-WatchdogUnregistration @fixture -RemoveEventSource | Should -Be 0

            Should -Invoke Remove-WatchdogEventSource -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'ServiceWatchdog'
            }
        }

        It 'skips removal when the event source does not exist' {
            $fixture = New-UnregisterFixture
            Mock Test-WatchdogEventSource { return $false }

            Invoke-WatchdogUnregistration @fixture -RemoveEventSource | Should -Be 0

            Should -Invoke Remove-WatchdogEventSource -Times 0
            Get-LogText | Should -Match 'event source'
        }
    }

    Context 'File removal' {
        It 'leaves the install folder alone without -RemoveFiles' {
            $fixture = New-UnregisterFixture

            Invoke-WatchdogUnregistration @fixture -Force | Should -Be 0

            Test-Path -LiteralPath (Join-Path $fixture.InstallPath 'ServiceWatchdog.json') | Should -BeTrue
        }

        It 'does not remove anything with -WhatIf' {
            $fixture = New-UnregisterFixture

            $exitCode = Invoke-WatchdogUnregistration @fixture -RemoveFiles -RemoveEventSource -WhatIf

            $exitCode | Should -Be 0
            Test-Path -LiteralPath (Join-Path $fixture.InstallPath 'ServiceWatchdog.json') | Should -BeTrue
            Should -Invoke Unregister-ScheduledTask -Times 0
            Should -Invoke Remove-WatchdogEventSource -Times 0
        }

        It 'removes the whole install folder recursively with -Force' {
            $fixture = New-UnregisterFixture

            $exitCode = Invoke-WatchdogUnregistration @fixture -RemoveFiles -Force

            $exitCode | Should -Be 0
            Test-Path -LiteralPath $fixture.InstallPath | Should -BeFalse
        }

        It 'removes the install folder with -Confirm:$false' {
            $fixture = New-UnregisterFixture

            Invoke-WatchdogUnregistration @fixture -RemoveFiles -Confirm:$false | Should -Be 0

            Test-Path -LiteralPath $fixture.InstallPath | Should -BeFalse
        }

        It 'keeps running when its own log file lives inside the removed folder' {
            $fixture = New-UnregisterFixture
            $script:LogPath = Join-Path (Join-Path $fixture.InstallPath 'Logs') 'Unregister-test.log'

            $exitCode = Invoke-WatchdogUnregistration @fixture -RemoveFiles -Force

            $exitCode | Should -Be 0
            Test-Path -LiteralPath $fixture.InstallPath | Should -BeFalse
        }

        It 'exits 0 and logs when the install folder is already gone' {
            $fixture = New-UnregisterFixture
            Remove-Item -LiteralPath $fixture.InstallPath -Recurse -Force

            $exitCode = Invoke-WatchdogUnregistration @fixture -RemoveFiles -Force

            $exitCode | Should -Be 0
            Get-LogText | Should -Match 'not found'
        }

        It 'refuses to remove a filesystem root or a Windows system folder' {
            $fixture = New-UnregisterFixture
            $root = [System.IO.Path]::GetPathRoot($fixture.InstallPath)

            $fixture.InstallPath = $root
            Invoke-WatchdogUnregistration @fixture -RemoveFiles -Force | Should -Be 2

            $fixture.InstallPath = $env:ProgramData
            Invoke-WatchdogUnregistration @fixture -RemoveFiles -Force | Should -Be 2

            Should -Invoke Unregister-ScheduledTask -Times 0
            Test-Path -LiteralPath $env:ProgramData | Should -BeTrue
        }
    }

    Context 'Console verbosity' {
        It 'adds warnings but not info at Medium' {
            $script:Verbosity = 'Medium'
            $fixture = New-UnregisterFixture

            Invoke-WatchdogUnregistration @fixture -DryRun | Should -Be 0

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*[[]WARNING[]]*DRYRUN*' }
            Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like '*[[]INFO[]]*' }
        }
    }

    Context 'DryRun' {
        It 'performs zero mutations' {
            $fixture = New-UnregisterFixture

            $exitCode = Invoke-WatchdogUnregistration @fixture -RemoveFiles -RemoveEventSource -Force -DryRun

            $exitCode | Should -Be 0
            Should -Invoke Unregister-ScheduledTask -Times 0
            Should -Invoke Remove-WatchdogEventSource -Times 0
            Test-Path -LiteralPath (Join-Path $fixture.InstallPath 'ServiceWatchdog.state.json') | Should -BeTrue
            Get-LogText | Should -Match '\[DRYRUN\]'
        }
    }
}
