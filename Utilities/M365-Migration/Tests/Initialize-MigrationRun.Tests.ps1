#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Run-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Initialize-MigrationRun' {

    It 'Returns the documented run-context shape' {
        $run = Initialize-MigrationRun -ScriptName 'Test-Script' -OutputPath $script:workspace
        @($run.Keys | Sort-Object) | Should -Be @(
            'DryRun', 'LogPath', 'OutputDirectory', 'Prefix', 'ScriptName', 'StartedAt', 'Verbosity'
        )
        $run.ScriptName | Should -BeExactly 'Test-Script'
        $run.DryRun | Should -BeFalse
        $run.Verbosity | Should -BeExactly 'Medium'
    }

    It 'Creates the output directory and opens a timestamped log' {
        $run = Initialize-MigrationRun -ScriptName 'Test-Script' -OutputPath (Join-Path $script:workspace 'created')
        Test-Path -LiteralPath $run.OutputDirectory | Should -BeTrue
        [System.IO.Path]::GetFileName($run.LogPath) | Should -Match '^Test-Script_\d{8}-\d{6}\.log$'
        Test-Path -LiteralPath $run.LogPath | Should -BeTrue
    }

    It 'Puts output under a prefix subfolder and prefixes the log name' {
        $run = Initialize-MigrationRun -ScriptName 'Test-Script' -OutputPath $script:workspace -Prefix 'Contoso'
        $run.OutputDirectory | Should -BeExactly (Join-Path $script:workspace 'Contoso')
        [System.IO.Path]::GetFileName($run.LogPath) | Should -Match '^Contoso_Test-Script_'
    }

    It 'Sanitises a prefix containing characters a filesystem rejects' {
        $run = Initialize-MigrationRun -ScriptName 'Test-Script' -OutputPath $script:workspace -Prefix 'Contoso Wave/1'
        $run.Prefix | Should -BeExactly 'Contoso-Wave-1'
    }

    It 'Honours an explicit -LogPath' {
        $logPath = Join-Path $script:workspace 'explicit.log'
        $run = Initialize-MigrationRun -ScriptName 'Test-Script' -OutputPath $script:workspace -LogPath $logPath
        $run.LogPath | Should -BeExactly $logPath
    }

    It 'Records bound parameters in the log' {
        $run = Initialize-MigrationRun -ScriptName 'Test-Script' -OutputPath $script:workspace -Verbosity High `
            -BoundParameters @{ PlanPath = 'C:\plan.csv'; Wave = '1' }
        $log = Get-Content -LiteralPath $run.LogPath -Raw
        $log | Should -Match 'Parameter PlanPath = C:\\plan.csv'
        $log | Should -Match 'Parameter Wave = 1'
    }

    It 'Masks anything whose parameter name reads like a secret' {
        $run = Initialize-MigrationRun -ScriptName 'Test-Script' -OutputPath $script:workspace -Verbosity High `
            -BoundParameters @{
                ClientSecret       = 'super-secret-value'
                Password           = 'hunter2'
                CertificateThumbprint = 'AABBCCDD'
                ApiKey             = 'abc123'
                Wave               = '1'
            }
        $log = Get-Content -LiteralPath $run.LogPath -Raw
        $log | Should -Not -Match 'super-secret-value'
        $log | Should -Not -Match 'hunter2'
        $log | Should -Not -Match 'AABBCCDD'
        $log | Should -Not -Match 'abc123'
        $log | Should -Match 'Parameter Wave = 1'
    }

    It 'Announces DryRun' {
        $run = Initialize-MigrationRun -ScriptName 'Test-Script' -OutputPath $script:workspace -DryRun
        $run.DryRun | Should -BeTrue
        (Get-Content -LiteralPath $run.LogPath -Raw) | Should -Match 'DryRun is enabled'
    }
}

Describe 'Write-MigrationLog' {

    It 'Writes every level to the log file regardless of verbosity' {
        $run = Initialize-MigrationRun -ScriptName 'Log-Test' -OutputPath $script:workspace -Verbosity Low
        foreach ($level in @('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')) {
            Write-MigrationLog -Message "level $level" -Level $level
        }
        $log = Get-Content -LiteralPath $run.LogPath -Raw
        foreach ($level in @('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')) {
            $log | Should -Match "\[$level\] level $level"
        }
    }

    It 'Stamps each line with a millisecond timestamp' {
        $run = Initialize-MigrationRun -ScriptName 'Log-Stamp' -OutputPath $script:workspace
        Write-MigrationLog -Message 'stamped' -Level ERROR
        (Get-Content -LiteralPath $run.LogPath -Raw) |
            Should -Match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \[ERROR\] stamped'
    }

    It 'Rejects an unknown level' {
        { Write-MigrationLog -Message 'x' -Level 'CRITICAL' } | Should -Throw
    }
}

Describe 'Invoke-MigrationAction' {

    It 'Runs the action and logs it on a real run' {
        $null = Initialize-MigrationRun -ScriptName 'Action-Test' -OutputPath $script:workspace
        $script:ran = $false
        Invoke-MigrationAction -Description 'set a flag' -Action { $script:ran = $true }
        $script:ran | Should -BeTrue
    }

    It 'Does not run the action under DryRun' {
        $run = Initialize-MigrationRun -ScriptName 'Action-DryRun' -OutputPath $script:workspace -DryRun
        $script:ran = $false
        $result = Invoke-MigrationAction -Description 'set a flag' -Action { $script:ran = $true }
        $script:ran | Should -BeFalse
        $result | Should -BeNullOrEmpty
        (Get-Content -LiteralPath $run.LogPath -Raw) | Should -Match '\[DRYRUN\] Would: set a flag'
    }

    It 'Returns the action output only with -PassThru' {
        $null = Initialize-MigrationRun -ScriptName 'Action-PassThru' -OutputPath $script:workspace
        Invoke-MigrationAction -Description 'produce a value' -Action { 'result' } | Should -BeNullOrEmpty
        Invoke-MigrationAction -Description 'produce a value' -Action { 'result' } -PassThru | Should -BeExactly 'result'
    }

    It 'Logs and re-throws a failure' {
        $run = Initialize-MigrationRun -ScriptName 'Action-Fail' -OutputPath $script:workspace
        { Invoke-MigrationAction -Description 'explode' -Action { throw 'boom' } } |
            Should -Throw -ExpectedMessage '*boom*'
        (Get-Content -LiteralPath $run.LogPath -Raw) | Should -Match '\[ERROR\] Failed: explode - boom'
    }
}

Describe 'Complete-MigrationRun' {

    It 'Returns the exit code it was given' {
        $null = Initialize-MigrationRun -ScriptName 'Complete-Test' -OutputPath $script:workspace
        Complete-MigrationRun -ExitCode 2 | Should -Be 2
    }

    It 'Logs the script name and the elapsed time' {
        $run = Initialize-MigrationRun -ScriptName 'Complete-Test' -OutputPath $script:workspace
        $null = Complete-MigrationRun -ExitCode 0
        (Get-Content -LiteralPath $run.LogPath -Raw) |
            Should -Match 'Finished Complete-Test in \d{2}:\d{2}:\d{2} \(exit code 0\)'
    }

    It 'Defaults to exit code 0' {
        $null = Initialize-MigrationRun -ScriptName 'Complete-Test' -OutputPath $script:workspace
        Complete-MigrationRun | Should -Be 0
    }
}
