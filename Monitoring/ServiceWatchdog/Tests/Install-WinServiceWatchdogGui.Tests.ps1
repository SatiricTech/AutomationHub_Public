#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for the pure helper functions in Install-WinServiceWatchdogGui.ps1.

.DESCRIPTION
    Pester 5 and 6 compatible. The GUI script is dot-sourced with -NoGui, which loads every
    helper and stops before any WinForms call, so this suite runs on macOS and Linux as well as
    on Windows. Nothing here touches the real C:\ProgramData\ServiceWatchdog path, the scheduled
    task, or the pinned Endpoint\ scripts.

    Covered: settings validation (missing file, unedited REPLACE placeholders, missing key, bad
    URL, happy path), the config merge against the public ServiceWatchdog.example.json schema,
    the service sort order, the exit-code map for all three public scripts, the log-label round
    trip and the secret scrubber.

.NOTES
    Version:    1.0.0
    Created:    2026-09-17
    Run with:   Invoke-Pester -Path .\Tests\Install-WinServiceWatchdogGui.Tests.ps1

    Developed with AI assistance (Claude); reviewed before use.
#>

BeforeAll {
    $script:GuiScript = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'Package') `
        'Install-WinServiceWatchdogGui.ps1'
    . $script:GuiScript -NoGui

    # A settings file shaped like the real ServiceWatchdog.settings.json but with no real secret in it.
    $script:GoodSettings = @{
        SchemaVersion = 1
        ClientName    = 'Test Client'
        Webhook       = @{
            Url            = 'https://func-test.azurewebsites.net/api/servicewatchdog/alert'
            FunctionKey    = 'aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee'
            TimeoutSeconds = 45
        }
        Defaults      = @{
            MaxStartAttempts        = 4
            RetryDelaySeconds       = 25
            PostStartVerifySeconds  = 15
            StartPendingWaitSeconds = 45
            MaxRunSeconds           = 200
            Alerting                = @{
                ReminderMinutes            = 120
                NotifyOnRemediation        = $true
                RemediationCooldownMinutes = 90
                HeartbeatHours             = 12
            }
            Logging                 = @{
                LogRoot             = ''
                LogRetentionDays    = 14
                EventLogHealthyRuns = $true
            }
        }
    }

    function New-TestSettingsFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture writing to a temp file; -WhatIf would serve no purpose.')]
        [CmdletBinding()]
        param ([hashtable]$Settings)
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("wdsettings-{0}.json" -f [guid]::NewGuid())
        ($Settings | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
        return $path
    }
}

Describe 'Resolve-WatchdogGuiSettings' {

    It 'reports the copy-the-example message when the settings file is missing' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("wd-absent-{0}.json" -f [guid]::NewGuid())
        $result = Resolve-WatchdogGuiSettings -Path $missing
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'ServiceWatchdog\.settings\.example\.json to ServiceWatchdog\.settings\.json'
        ($result.Errors -join ' ') | Should -Match 'FunctionKey'
    }

    It 'rejects an empty path' {
        (Resolve-WatchdogGuiSettings -Path '').IsValid | Should -BeFalse
    }

    It 'rejects a file that is not valid JSON' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("wd-bad-{0}.json" -f [guid]::NewGuid())
        'this is not json' | Set-Content -LiteralPath $path -Encoding UTF8
        try {
            $result = Resolve-WatchdogGuiSettings -Path $path
            $result.IsValid | Should -BeFalse
            ($result.Errors -join ' ') | Should -Match 'not valid JSON'
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts a fully populated settings file and returns the parsed settings' {
        $path = New-TestSettingsFile -Settings $script:GoodSettings
        try {
            $result = Resolve-WatchdogGuiSettings -Path $path
            $result.IsValid | Should -BeTrue
            $result.Errors.Count | Should -Be 0
            $result.Settings['Webhook']['TimeoutSeconds'] | Should -Be 45
            $result.Settings['Defaults']['Alerting']['ReminderMinutes'] | Should -Be 120
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-WatchdogGuiSettings' {

    It 'rejects the example file placeholder function key' {
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{
                Url            = 'https://func-test.azurewebsites.net/api/servicewatchdog/alert'
                FunctionKey    = 'REPLACE_WITH_FUNCTION_KEY'
                TimeoutSeconds = 30
            }
        }
        $result = Test-WatchdogGuiSettings -Settings $settings
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'REPLACE'
        ($result.Errors -join ' ') | Should -Match 'ServiceWatchdog\.settings\.example\.json'
    }

    It 'rejects a REPLACE placeholder in the webhook URL' {
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{ Url = 'https://REPLACE-ME.azurewebsites.net/api/x'; FunctionKey = 'abcdefghijkl' }
        }
        (Test-WatchdogGuiSettings -Settings $settings).IsValid | Should -BeFalse
    }

    It 'rejects a missing function key' {
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{ Url = 'https://func-test.azurewebsites.net/api/x'; TimeoutSeconds = 30 }
        }
        $result = Test-WatchdogGuiSettings -Settings $settings
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'FunctionKey must not be empty'
    }

    It 'rejects an empty function key' {
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{ Url = 'https://func-test.azurewebsites.net/api/x'; FunctionKey = '   ' }
        }
        (Test-WatchdogGuiSettings -Settings $settings).IsValid | Should -BeFalse
    }

    It 'rejects a missing Webhook section' {
        $result = Test-WatchdogGuiSettings -Settings @{ SchemaVersion = 1 }
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'Webhook section is missing'
    }

    It 'rejects a non-https webhook URL' {
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{ Url = 'http://func-test.local/api/x'; FunctionKey = 'abcdefghijkl' }
        }
        (Test-WatchdogGuiSettings -Settings $settings).IsValid | Should -BeFalse
    }

    It 'rejects a schema version other than 1' {
        $settings = @{
            SchemaVersion = 2
            Webhook       = @{ Url = 'https://func-test.azurewebsites.net/api/x'; FunctionKey = 'abcdefghijkl' }
        }
        (Test-WatchdogGuiSettings -Settings $settings).IsValid | Should -BeFalse
    }

    It 'is case-sensitive about REPLACE so a real name containing "Replace" survives' {
        $settings = @{
            SchemaVersion = 1
            ClientName    = 'Replacement Parts Co'
            Webhook       = @{
                Url         = 'https://func-test.azurewebsites.net/api/x'
                FunctionKey = 'aaaaaaaabbbbbbbbcccccccc'
            }
        }
        (Test-WatchdogGuiSettings -Settings $settings).IsValid | Should -BeTrue
    }

    It 'rejects settings that are not an object' {
        (Test-WatchdogGuiSettings -Settings 'nope').IsValid | Should -BeFalse
    }
}

Describe 'Get-WatchdogGuiWorstCaseRunSeconds' {

    It 'matches the registrar formula MaxRunSeconds + 2 * (2 * TimeoutSeconds + 5) + 15' {
        # 200 + 2 * (2 * 45 + 5) + 15 = 405
        Get-WatchdogGuiWorstCaseRunSeconds -Settings $script:GoodSettings | Should -Be 405
    }

    It 'uses the public defaults when the settings omit the values' {
        # 240 + 2 * (2 * 30 + 5) + 15 = 385
        Get-WatchdogGuiWorstCaseRunSeconds -Settings @{ SchemaVersion = 1 } | Should -Be 385
    }

    It 'tolerates settings that are not a dictionary' {
        Get-WatchdogGuiWorstCaseRunSeconds -Settings $null | Should -Be 385
    }
}

Describe 'Test-WatchdogGuiSettings execution time limit guard' {

    It 'rejects settings whose worst-case run exceeds the 420 second task limit' {
        # 300 + 2 * (2 * 45 + 5) + 15 = 505, which the registrar's default 420 s limit cannot cover.
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{
                Url            = 'https://func-test.azurewebsites.net/api/x'
                FunctionKey    = 'aaaaaaaabbbbbbbbcccccccc'
                TimeoutSeconds = 45
            }
            Defaults      = @{ MaxRunSeconds = 300 }
        }
        $result = Test-WatchdogGuiSettings -Settings $settings
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'MaxRunSeconds 300'
        ($result.Errors -join ' ') | Should -Match 'TimeoutSeconds 45'
        ($result.Errors -join ' ') | Should -Match '505 seconds'
        ($result.Errors -join ' ') | Should -Match '420 second execution limit'
        ($result.Errors -join ' ') | Should -Match 'Lower Defaults\.MaxRunSeconds to 215 or less'
    }

    It 'accepts the largest MaxRunSeconds that still fits' {
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{
                Url            = 'https://func-test.azurewebsites.net/api/x'
                FunctionKey    = 'aaaaaaaabbbbbbbbcccccccc'
                TimeoutSeconds = 30
            }
            Defaults      = @{ MaxRunSeconds = 275 }
        }
        Get-WatchdogGuiWorstCaseRunSeconds -Settings $settings | Should -Be 420
        (Test-WatchdogGuiSettings -Settings $settings).IsValid | Should -BeTrue
    }

    It 'rejects one second more than fits' {
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{
                Url            = 'https://func-test.azurewebsites.net/api/x'
                FunctionKey    = 'aaaaaaaabbbbbbbbcccccccc'
                TimeoutSeconds = 30
            }
            Defaults      = @{ MaxRunSeconds = 276 }
        }
        (Test-WatchdogGuiSettings -Settings $settings).IsValid | Should -BeFalse
    }

    It 'reports a non-numeric MaxRunSeconds as an error instead of throwing' {
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{
                Url            = 'https://func-test.azurewebsites.net/api/x'
                FunctionKey    = 'aaaaaaaabbbbbbbbcccccccc'
                TimeoutSeconds = 30
            }
            Defaults      = @{ MaxRunSeconds = 'soon' }
        }
        $result = Test-WatchdogGuiSettings -Settings $settings
        $result.IsValid | Should -BeFalse
        ($result.Errors -join ' ') | Should -Match 'must be whole numbers'
    }

    It 'still validates a settings file the GUI would accept in production' {
        # The shipped ServiceWatchdog.settings.json values: 240 s with a 30 s webhook timeout.
        $settings = @{
            SchemaVersion = 1
            Webhook       = @{
                Url            = 'https://func-test.azurewebsites.net/api/x'
                FunctionKey    = 'aaaaaaaabbbbbbbbcccccccc'
                TimeoutSeconds = 30
            }
            Defaults      = @{ MaxRunSeconds = 240 }
        }
        (Test-WatchdogGuiSettings -Settings $settings).IsValid | Should -BeTrue
    }
}

Describe 'Format-WatchdogGuiTaskResult' {

    It 'names the Task Scheduler status codes a technician actually meets' {
        Format-WatchdogGuiTaskResult -LastTaskResult 267011 | Should -Match 'has not run yet'
        Format-WatchdogGuiTaskResult -LastTaskResult 267009 | Should -Match 'running now'
        Format-WatchdogGuiTaskResult -LastTaskResult 267014 | Should -Match 'stopped before it finished'
    }

    It 'maps a real worker exit code through the exit-code map' {
        Format-WatchdogGuiTaskResult -LastTaskResult 0 | Should -Match 'Healthy'
        Format-WatchdogGuiTaskResult -LastTaskResult 50 | Should -Match 'Failed, Missing or Disabled'
    }

    It 'is what Format-WatchdogGuiTaskStatus uses, so a fresh task does not read as a fault' {
        $info = [pscustomobject]@{ LastRunTime = $null; NextRunTime = $null; LastTaskResult = 267011 }
        $lines = Format-WatchdogGuiTaskStatus -TaskState 'Ready' -TaskInfo $info -ConfigPresent
        $lines[0] | Should -Match 'has not run yet'
        $lines[0] | Should -Not -Match 'Unrecognised'
    }
}

Describe 'Read-WatchdogGuiFileTail' {

    BeforeEach {
        $script:TailPath = Join-Path ([System.IO.Path]::GetTempPath()) ("wdtail-{0}.log" -f [guid]::NewGuid())
    }

    AfterEach {
        Remove-Item -LiteralPath $script:TailPath -Force -ErrorAction SilentlyContinue
    }

    It 'returns nothing for a file that does not exist' {
        $result = Read-WatchdogGuiFileTail -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'wd-no-such-file.log')
        $result.Text | Should -Be ''
        $result.Offset | Should -Be 0
    }

    It 'reads complete lines and reports the offset to resume from' {
        [System.IO.File]::WriteAllText($script:TailPath, "first`nsecond`n")
        $result = Read-WatchdogGuiFileTail -Path $script:TailPath
        $result.Text | Should -Be "first`nsecond`n"
        $result.Offset | Should -Be 13
    }

    It 'holds back a partial final line until it is complete' {
        [System.IO.File]::WriteAllText($script:TailPath, "done`npartial")
        $first = Read-WatchdogGuiFileTail -Path $script:TailPath
        $first.Text | Should -Be "done`n"
        $first.Offset | Should -Be 5

        [System.IO.File]::WriteAllText($script:TailPath, "done`npartial line`n")
        $second = Read-WatchdogGuiFileTail -Path $script:TailPath -Offset $first.Offset
        $second.Text | Should -Be "partial line`n"
    }

    It 'returns nothing when the file has not grown, so a poll loop stays quiet' {
        [System.IO.File]::WriteAllText($script:TailPath, "only`n")
        $first = Read-WatchdogGuiFileTail -Path $script:TailPath
        $second = Read-WatchdogGuiFileTail -Path $script:TailPath -Offset $first.Offset
        $second.Text | Should -Be ''
        $second.Offset | Should -Be $first.Offset
    }

    It 'reads a file that is still open for writing' {
        $stream = New-Object System.IO.FileStream($script:TailPath, [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("streamed`n")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            (Read-WatchdogGuiFileTail -Path $script:TailPath).Text | Should -Be "streamed`n"
        }
        finally { $stream.Dispose() }
    }
}

Describe 'Test-WatchdogGuiSingleThreadedApartment' {

    It 'returns a boolean without throwing on any host' {
        Test-WatchdogGuiSingleThreadedApartment | Should -BeOfType [bool]
    }
}

Describe 'New-WatchdogGuiConfig' {

    BeforeAll {
        $script:Config = New-WatchdogGuiConfig -Settings $script:GoodSettings -SiteName 'HQ File Server' `
            -Service @('Spooler', 'W3SVC')
    }

    It 'produces exactly the keys of the public ServiceWatchdog.example.json schema, in order' {
        @($script:Config.Keys) | Should -Be @('SchemaVersion', 'SiteName', 'Services', 'MaxStartAttempts',
            'RetryDelaySeconds', 'PostStartVerifySeconds', 'StartPendingWaitSeconds', 'MaxRunSeconds',
            'Webhook', 'Alerting', 'Logging')
        @($script:Config['Webhook'].Keys) | Should -Be @('Url', 'FunctionKey', 'TimeoutSeconds')
        @($script:Config['Alerting'].Keys) | Should -Be @('ReminderMinutes', 'NotifyOnRemediation',
            'RemediationCooldownMinutes', 'HeartbeatHours')
        @($script:Config['Logging'].Keys) | Should -Be @('LogRoot', 'LogRetentionDays', 'EventLogHealthyRuns')
    }

    It 'carries the site name and the selected services' {
        $script:Config['SchemaVersion'] | Should -Be 1
        $script:Config['SiteName'] | Should -Be 'HQ File Server'
        @($script:Config['Services']) | Should -Be @('Spooler', 'W3SVC')
    }

    It 'flattens the settings Defaults onto the top level' {
        $script:Config['MaxStartAttempts'] | Should -Be 4
        $script:Config['RetryDelaySeconds'] | Should -Be 25
        $script:Config['PostStartVerifySeconds'] | Should -Be 15
        $script:Config['StartPendingWaitSeconds'] | Should -Be 45
        $script:Config['MaxRunSeconds'] | Should -Be 200
    }

    It 'copies the webhook block including the timeout' {
        $script:Config['Webhook']['Url'] | Should -Be $script:GoodSettings.Webhook.Url
        $script:Config['Webhook']['FunctionKey'] | Should -Be $script:GoodSettings.Webhook.FunctionKey
        $script:Config['Webhook']['TimeoutSeconds'] | Should -Be 45
    }

    It 'nests the Alerting and Logging defaults with their original types' {
        $script:Config['Alerting']['ReminderMinutes'] | Should -Be 120
        $script:Config['Alerting']['NotifyOnRemediation'] | Should -BeOfType [bool]
        $script:Config['Alerting']['NotifyOnRemediation'] | Should -BeTrue
        $script:Config['Alerting']['RemediationCooldownMinutes'] | Should -Be 90
        $script:Config['Alerting']['HeartbeatHours'] | Should -Be 12
        $script:Config['Logging']['LogRoot'] | Should -Be ''
        $script:Config['Logging']['LogRetentionDays'] | Should -Be 14
        $script:Config['Logging']['EventLogHealthyRuns'] | Should -BeTrue
    }

    It 'falls back to the public defaults when the settings omit a Defaults block' {
        $bare = @{
            SchemaVersion = 1
            Webhook       = @{ Url = 'https://func-test.azurewebsites.net/api/x'; FunctionKey = 'abcdefghijkl' }
        }
        $config = New-WatchdogGuiConfig -Settings $bare -SiteName 'Site' -Service @('Spooler')
        $config['MaxStartAttempts'] | Should -Be 5
        $config['RetryDelaySeconds'] | Should -Be 30
        $config['MaxRunSeconds'] | Should -Be 240
        $config['Webhook']['TimeoutSeconds'] | Should -Be 30
        $config['Alerting']['ReminderMinutes'] | Should -Be 240
        $config['Alerting']['NotifyOnRemediation'] | Should -BeFalse
        $config['Logging']['LogRetentionDays'] | Should -Be 30
    }

    It 'trims and de-duplicates service names case-insensitively, keeping the ticked order' {
        $config = New-WatchdogGuiConfig -Settings $script:GoodSettings -SiteName 'Site' `
            -Service @(' Spooler ', 'SPOOLER', 'W3SVC', 'w3svc')
        @($config['Services']) | Should -Be @('Spooler', 'W3SVC')
    }

    It 'trims the site name' {
        (New-WatchdogGuiConfig -Settings $script:GoodSettings -SiteName '  HQ  ' `
                -Service @('Spooler'))['SiteName'] | Should -Be 'HQ'
    }

    It 'serialises Services as a JSON array even with one service' {
        $config = New-WatchdogGuiConfig -Settings $script:GoodSettings -SiteName 'Site' -Service @('Spooler')
        $json = $config | ConvertTo-Json -Depth 6
        $json | Should -Match '"Services":\s*\['
    }

    It 'round-trips through JSON with the same values' {
        $json = $script:Config | ConvertTo-Json -Depth 6
        $back = $json | ConvertFrom-Json
        $back.SiteName | Should -Be 'HQ File Server'
        @($back.Services) | Should -Be @('Spooler', 'W3SVC')
        $back.Logging.LogRetentionDays | Should -Be 14
    }

    It 'refuses a selection that contains no usable service name' {
        { New-WatchdogGuiConfig -Settings $script:GoodSettings -SiteName 'Site' -Service @('   ') } |
            Should -Throw -ExpectedMessage '*At least one service*'
    }

    It 'refuses settings with no Webhook section' {
        { New-WatchdogGuiConfig -Settings @{ SchemaVersion = 1 } -SiteName 'Site' -Service @('Spooler') } |
            Should -Throw -ExpectedMessage '*no Webhook section*'
    }
}

Describe 'Get-WatchdogGuiSortedServiceList' {

    BeforeAll {
        $script:Services = @(
            [pscustomobject]@{ Name = 'zzz'; DisplayName = 'Zeta Service'; Status = 'Stopped' }
            [pscustomobject]@{ Name = 'bbb'; DisplayName = 'Beta Service'; Status = 'Running' }
            [pscustomobject]@{ Name = 'aaa'; DisplayName = 'Alpha Service'; Status = 'Stopped' }
            [pscustomobject]@{ Name = 'ccc'; DisplayName = 'Charlie Service'; Status = 'Running' }
        )
    }

    It 'puts running services first, then sorts alphabetically by display name' {
        $sorted = Get-WatchdogGuiSortedServiceList -Service $script:Services
        @($sorted | ForEach-Object { $_.Name }) | Should -Be @('bbb', 'ccc', 'aaa', 'zzz')
    }

    It 'sorts by display name, not by short name' {
        $services = @(
            [pscustomobject]@{ Name = 'aaa'; DisplayName = 'Zulu'; Status = 'Running' }
            [pscustomobject]@{ Name = 'zzz'; DisplayName = 'Alpha'; Status = 'Running' }
        )
        @((Get-WatchdogGuiSortedServiceList -Service $services) | ForEach-Object { $_.Name }) | Should -Be @('zzz', 'aaa')
    }

    It 'falls back to the short name when a service has no display name' {
        $services = @(
            [pscustomobject]@{ Name = 'mmm'; DisplayName = ''; Status = 'Running' }
            [pscustomobject]@{ Name = 'aaa'; DisplayName = 'Zulu'; Status = 'Running' }
        )
        @((Get-WatchdogGuiSortedServiceList -Service $services) | ForEach-Object { $_.Name }) | Should -Be @('mmm', 'aaa')
    }

    It 'treats any non-Running status as stopped' {
        $services = @(
            [pscustomobject]@{ Name = 'aaa'; DisplayName = 'Alpha'; Status = 'StartPending' }
            [pscustomobject]@{ Name = 'bbb'; DisplayName = 'Beta'; Status = 'Running' }
        )
        @((Get-WatchdogGuiSortedServiceList -Service $services) | ForEach-Object { $_.Name }) | Should -Be @('bbb', 'aaa')
    }

    It 'returns an empty result for an empty list' {
        @(Get-WatchdogGuiSortedServiceList -Service @()).Count | Should -Be 0
    }
}

Describe 'Get-WatchdogGuiExitCodeMeaning' {

    It 'maps the registrar exit codes documented in Register-WinServiceWatchdogTask.ps1' {
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 0 -Script 'Register').IsSuccess | Should -BeTrue
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 0 -Script 'Register').Severity | Should -Be 'Success'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 1 -Script 'Register').Severity | Should -Be 'Error'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 2 -Script 'Register').Severity | Should -Be 'Error'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 10 -Script 'Register').Severity | Should -Be 'Warning'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 10 -Script 'Register').Meaning | Should -Match 'test alert was not delivered'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 50 -Script 'Register').Severity | Should -Be 'Warning'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 50 -Script 'Register').Meaning | Should -Match 'service recovery'
    }

    It 'maps the worker exit codes documented in Invoke-WinServiceWatchdog.ps1' {
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 0 -Script 'Worker').IsSuccess | Should -BeTrue
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 2 -Script 'Worker').Meaning | Should -Match 'Configuration or parameters'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 10 -Script 'Worker').Severity | Should -Be 'Warning'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 10 -Script 'Worker').Meaning | Should -Match 'delivery pending'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 50 -Script 'Worker').Severity | Should -Be 'Warning'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 50 -Script 'Worker').Meaning | Should -Match 'Failed, Missing or Disabled'
    }

    It 'maps the unregistrar exit codes documented in Unregister-WinServiceWatchdogTask.ps1' {
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 0 -Script 'Unregister').IsSuccess | Should -BeTrue
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 0 -Script 'Unregister').Meaning | Should -Match 'already absent'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 1 -Script 'Unregister').Severity | Should -Be 'Error'
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 2 -Script 'Unregister').Severity | Should -Be 'Error'
    }

    It 'does not treat the registrar 10 and 50 codes as the worker meanings' {
        (Get-WatchdogGuiExitCodeMeaning -ExitCode 50 -Script 'Register').Meaning |
            Should -Not -Be (Get-WatchdogGuiExitCodeMeaning -ExitCode 50 -Script 'Worker').Meaning
    }

    It 'reports an unknown exit code as an error rather than a success' {
        $result = Get-WatchdogGuiExitCodeMeaning -ExitCode 77 -Script 'Worker'
        $result.IsSuccess | Should -BeFalse
        $result.Severity | Should -Be 'Error'
        $result.Meaning | Should -Match 'Unrecognised exit code 77'
    }

    It 'rejects an unknown script name' {
        { Get-WatchdogGuiExitCodeMeaning -ExitCode 0 -Script 'Nope' } | Should -Throw
    }
}

Describe 'Format-WatchdogGuiTaskStatus' {

    It 'reports not installed when there is no task' {
        $lines = Format-WatchdogGuiTaskStatus -TaskState $null -TaskInfo $null
        $lines[0] | Should -Match '^Not installed'
        $lines[0] | Should -Match 'config not present'
    }

    It 'notes a leftover config when the task is gone but the config remains' {
        (Format-WatchdogGuiTaskStatus -TaskState $null -TaskInfo $null -ConfigPresent)[0] | Should -Match 'config present'
    }

    It 'summarises the task state and maps the last result through the worker exit codes' {
        $info = [pscustomobject]@{
            LastRunTime    = [datetime]'2026-09-17 08:30:00'
            NextRunTime    = [datetime]'2026-09-17 08:35:00'
            LastTaskResult = 50
        }
        $lines = Format-WatchdogGuiTaskStatus -TaskState 'Ready' -TaskInfo $info -ConfigPresent
        $lines[0] | Should -Match '^Installed'
        $lines[0] | Should -Match 'is Ready'
        $lines[0] | Should -Match '2026-09-17 08:30:00'
        $lines[0] | Should -Match 'Failed, Missing or Disabled'
        ($lines -join "`n") | Should -Match 'Next run:'
        ($lines -join "`n") | Should -Match 'Application, source ServiceWatchdog'
    }

    It 'copes with a task that has never run' {
        $info = [pscustomobject]@{ LastRunTime = $null; NextRunTime = $null; LastTaskResult = $null }
        $lines = Format-WatchdogGuiTaskStatus -TaskState 'Ready' -TaskInfo $info
        $lines[0] | Should -Match 'last run never'
        $lines[0] | Should -Match 'no result yet'
    }
}

Describe 'Get-WatchdogGuiShortNameFromLabel' {

    It 'round-trips a label produced by Format-WatchdogGuiServiceLabel' {
        $service = [pscustomobject]@{ Name = 'W3SVC'; DisplayName = 'World Wide Web Publishing Service'
            Status                         = 'Running'
        }
        $label = Format-WatchdogGuiServiceLabel -Service $service
        $label | Should -Be 'World Wide Web Publishing Service (W3SVC) [Running]'
        Get-WatchdogGuiShortNameFromLabel -Label $label | Should -Be 'W3SVC'
    }

    It 'handles a display name that itself contains parentheses' {
        $service = [pscustomobject]@{ Name = 'MSSQL$SQLEXPRESS'; DisplayName = 'SQL Server (SQLEXPRESS)'
            Status                         = 'Stopped'
        }
        Get-WatchdogGuiShortNameFromLabel -Label (Format-WatchdogGuiServiceLabel -Service $service) | Should -Be 'MSSQL$SQLEXPRESS'
    }

    It 'falls back to the short name when a service has no display name' {
        $service = [pscustomobject]@{ Name = 'odd'; DisplayName = ''; Status = 'Running' }
        Format-WatchdogGuiServiceLabel -Service $service | Should -Be 'odd (odd) [Running]'
    }

    It 'returns unmatched text unchanged' {
        Get-WatchdogGuiShortNameFromLabel -Label 'nothing like a label' | Should -Be 'nothing like a label'
    }
}

Describe 'Remove-WatchdogGuiSecretText' {

    It 'redacts a known secret wherever it appears' {
        $secret = 'aaaaaaaabbbbbbbbcccccccc'
        $text = "POST https://x/api?code=$secret failed"
        Remove-WatchdogGuiSecretText -Text $text -Secret @($secret) | Should -Be 'POST https://x/api?code=******** failed'
    }

    It 'leaves text alone when there is no secret to redact' {
        Remove-WatchdogGuiSecretText -Text 'nothing secret here' -Secret @() | Should -Be 'nothing secret here'
    }

    It 'ignores short or empty secrets that would mangle unrelated output' {
        Remove-WatchdogGuiSecretText -Text 'the key is abc' -Secret @('abc', '', $null) | Should -Be 'the key is abc'
    }

    It 'passes through empty input' {
        Remove-WatchdogGuiSecretText -Text '' -Secret @('aaaaaaaabbbbbbbb') | Should -Be ''
    }
}

Describe 'Get-WatchdogGuiPackagePath' {

    It 'derives the Endpoint script paths from the package root' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'WatchdogGuiPackage'
        $paths = Get-WatchdogGuiPackagePath -Root $root
        $paths.EndpointPath | Should -Be (Join-Path $root 'Endpoint')
        $paths.Register | Should -Be (Join-Path (Join-Path $root 'Endpoint') 'Register-WinServiceWatchdogTask.ps1')
        $paths.Unregister | Should -Be (Join-Path (Join-Path $root 'Endpoint') 'Unregister-WinServiceWatchdogTask.ps1')
        $paths.Worker | Should -Be (Join-Path (Join-Path $root 'Endpoint') 'Invoke-WinServiceWatchdog.ps1')
        $paths.SettingsPath | Should -Be (Join-Path $root 'ServiceWatchdog.settings.json')
        $paths.ExamplePath | Should -Be (Join-Path $root 'ServiceWatchdog.settings.example.json')
    }

    It 'honours an explicit settings file override' {
        $override = Join-Path ([System.IO.Path]::GetTempPath()) 'elsewhere.json'
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'WatchdogGuiPackage'
        (Get-WatchdogGuiPackagePath -Root $root -SettingsFile $override).SettingsPath | Should -Be $override
    }
}

Describe 'Format-WatchdogGuiCommandLine' {

    It 'quotes paths containing spaces and keeps the switches bare' {
        $line = Format-WatchdogGuiCommandLine -ScriptPath 'C:\Program Files\x\Register.ps1' `
            -ArgumentList @('-ConfigPath', 'C:\ProgramData\ServiceWatchdog\ServiceWatchdog.json', '-TestAlert')
        $line | Should -Be ('powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ' +
            '"C:\Program Files\x\Register.ps1" -ConfigPath ' +
            'C:\ProgramData\ServiceWatchdog\ServiceWatchdog.json -TestAlert')
    }
}
