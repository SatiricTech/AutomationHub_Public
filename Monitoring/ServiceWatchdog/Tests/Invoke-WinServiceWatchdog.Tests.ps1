<#
.SYNOPSIS
    Pester tests for Invoke-WinServiceWatchdog.ps1.

.DESCRIPTION
    Exercises the endpoint worker against DESIGN.md sections 4.1 to 4.10: parameter rules,
    configuration validation, state file handling, service classification, start rounds,
    flap tracking, notification decisions, payload shape, webhook delivery and retry,
    heartbeat scheduling, -DryRun, -TestAlert, log retention and exit codes.

    The worker is dot-sourced (its script body is guarded so nothing runs on dot-source).
    Windows-only cmdlets do not exist on macOS/Linux, so stub functions with the same
    parameter surface are declared before the dot-source and then mocked. Every network
    call, sleep, clock read and event-log write is mocked; the tests never touch a real
    service, the event log, or the network.
#>

BeforeAll {
    $script:WorkerPath = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '../Endpoint/Invoke-WinServiceWatchdog.ps1'))
    $script:ExampleConfigPath = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '../Endpoint/ServiceWatchdog.example.json'))

    # Windows-only cmdlets are absent on this platform; Pester can only mock commands that
    # exist, so declare stubs with the parameters the worker uses.
    function Get-Service {
        [CmdletBinding()]
        param ([string]$Name, [string]$DisplayName)
        throw 'Get-Service stub: not mocked'
    }
    function Get-CimInstance {
        [CmdletBinding()]
        param ([string]$ClassName, [string]$Filter)
        throw 'Get-CimInstance stub: not mocked'
    }
    function Start-Service {
        [CmdletBinding()]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only stub for a Windows cmdlet absent on this platform; always mocked.'
        )]
        param ([string]$Name)
        throw 'Start-Service must never be called by the watchdog'
    }

    . $script:WorkerPath

    $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) "ServiceWatchdogTests-$([guid]::NewGuid())"
    New-Item -Path $script:Scratch -ItemType Directory -Force | Out-Null
    $script:LogPath = Join-Path $script:Scratch 'ServiceWatchdog-test.log'
    $script:Verbosity = 'Low'
    $script:DryRun = $false

    $script:Now = [datetime]::new(2026, 9, 4, 18, 0, 0, [System.DateTimeKind]::Utc)

    function Get-TestTimestamp {
        param ([int]$MinutesFromNow = 0)
        return $script:Now.AddMinutes($MinutesFromNow).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    function New-TestRawConfig {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([hashtable]$Overrides = @{}, [string[]]$Remove = @())

        $raw = @{
            SchemaVersion           = 1
            SiteName                = 'Example Org'
            Services                = @('Spooler', 'W3SVC')
            MaxStartAttempts        = 3
            RetryDelaySeconds       = 0
            PostStartVerifySeconds  = 5
            StartPendingWaitSeconds = 10
            MaxRunSeconds           = 240
            Webhook                 = @{
                Url            = 'https://watchdog.example.com/api/servicewatchdog/alert'
                FunctionKey    = 'unit-test-function-key-value'
                TimeoutSeconds = 30
            }
            Alerting                = @{
                ReminderMinutes            = 240
                NotifyOnRemediation        = $false
                RemediationCooldownMinutes = 60
                HeartbeatHours             = 24
            }
            Logging                 = @{
                LogRoot             = ''
                LogRetentionDays    = 30
                EventLogHealthyRuns = $false
            }
        }
        foreach ($key in $Overrides.Keys) {
            if ($Overrides[$key] -is [hashtable] -and $raw[$key] -is [hashtable]) {
                foreach ($inner in $Overrides[$key].Keys) {
                    $raw[$key][$inner] = $Overrides[$key][$inner]
                }
            }
            else {
                $raw[$key] = $Overrides[$key]
            }
        }
        foreach ($path in $Remove) {
            $parts = $path.Split('.')
            if ($parts.Count -eq 1) {
                $raw.Remove($parts[0])
            }
            else {
                $raw[$parts[0]].Remove($parts[1])
            }
        }
        return $raw
    }

    function New-TestConfig {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([hashtable]$Overrides = @{}, [string[]]$Remove = @())
        $validation = Test-WatchdogConfig -Config (New-TestRawConfig -Overrides $Overrides -Remove $Remove)
        if (-not $validation.IsValid) {
            throw "Test config is invalid: $($validation.Errors -join '; ')"
        }
        return $validation.Config
    }

    function New-TestResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param (
            [string]$Name,
            [string]$Status = 'Healthy',
            [bool]$Remediated = $false,
            [int]$Attempts = 0,
            [string]$LastError = $null,
            [string]$StartType = 'Automatic',
            [bool]$Eligible = $false
        )
        return @{
            Name          = $Name
            ResolvedName  = $Name
            DisplayName   = "$Name Display"
            StartType     = $StartType
            Status        = $Status
            Eligible      = $Eligible
            Remediated    = $Remediated
            Attempts      = $Attempts
            LastError     = $LastError
            ServiceStatus = $null
        }
    }

    function New-TestEntry {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param (
            [string]$Status = 'Healthy',
            [string]$FirstFailedUtc = $null,
            [string]$LastNotifiedUtc = $null,
            [string]$LastRemediatedUtc = $null,
            [string]$LastError = $null,
            [int]$FlapCount = 0,
            [string]$FlapWindowStartUtc = $null,
            [string]$FlapSuppressedUntilUtc = $null
        )
        return @{
            Status                 = $Status
            FirstFailedUtc         = $FirstFailedUtc
            LastNotifiedUtc        = $LastNotifiedUtc
            LastRemediatedUtc      = $LastRemediatedUtc
            LastError              = $LastError
            FlapCount              = $FlapCount
            FlapWindowStartUtc     = $FlapWindowStartUtc
            FlapSuppressedUntilUtc = $FlapSuppressedUntilUtc
        }
    }

    function New-TestState {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([hashtable]$Services = @{}, [hashtable]$Overrides = @{})
        $state = @{
            SchemaVersion       = 1
            HostName            = 'SRV-EXAMPLE-01'
            LastRunUtc          = $null
            LastHeartbeatUtc    = $null
            PendingNotification = $false
            PendingEventId      = $null
            PendingEventType    = $null
            PendingServices     = @()
            Services            = @{}
        }
        foreach ($name in $Services.Keys) {
            $state.Services[$name] = $Services[$name]
        }
        foreach ($key in $Overrides.Keys) {
            $state[$key] = $Overrides[$key]
        }
        return $state
    }

    function New-TestHttpException {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([int]$StatusCode)
        $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$StatusCode)
        return [Microsoft.PowerShell.Commands.HttpResponseException]::new("HTTP $StatusCode", $response)
    }

    function New-TestConfigFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([hashtable]$Overrides = @{}, [string]$Name = 'ServiceWatchdog.json')
        $folder = Join-Path $script:Scratch ([guid]::NewGuid().ToString('N'))
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
        $path = Join-Path $folder $Name
        $raw = New-TestRawConfig -Overrides $Overrides
        Set-Content -LiteralPath $path -Value ($raw | ConvertTo-Json -Depth 10) -Encoding utf8
        return $path
    }

    function New-FakeService {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([string]$Name = 'Spooler', [string]$DisplayName = 'Print Spooler', [string]$Status = 'Running')
        return [pscustomobject]@{ Name = $Name; DisplayName = $DisplayName; Status = $Status }
    }

    function New-FakeCim {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([string]$StartMode = 'Auto', [bool]$Delayed = $false)
        return [pscustomobject]@{ StartMode = $StartMode; DelayedAutoStart = $Delayed }
    }

    function New-TestStatus {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param (
            [string]$Name,
            [string]$DisplayName = "$Name Display",
            [string]$StartType = 'Automatic',
            [string]$Status = 'Running'
        )
        return @{
            Name = $Name; ResolvedName = $Name; DisplayName = $DisplayName; StartType = $StartType; Status = $Status
        }
    }

    function New-TestResponse {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([string]$Content = '{"accepted":true}')
        return [pscustomobject]@{ StatusCode = 200; Content = $Content }
    }

    function Get-TestPlan {
        param ([object[]]$Results, [hashtable]$State, [hashtable]$Config = $script:Config)
        return Get-WatchdogNotificationPlan -Results $Results -State $State -Config $Config -Now $script:Now
    }

    function New-TestPayload {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; it touches nothing outside the ephemeral scratch directory.'
        )]
        param ([string]$EventType, [object[]]$Items = @(), [string]$Summary = 'summary')
        return New-WatchdogPayload -EventType $EventType -EventId ([guid]::NewGuid().ToString()) `
            -Config $script:Config -Items $Items -Summary $Summary -RunId ([guid]::NewGuid().ToString()) `
            -Now $script:Now
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-WinServiceWatchdog' {

    BeforeAll {
        Mock Write-Host { }
        # The worker's .NET event-log seams; the real API throws off Windows, so always mocked.
        Mock Write-WatchdogEventLogEntry { }
        Mock Register-WatchdogEventSource { }
        Mock Start-Sleep { }
        Mock Get-WatchdogUtcNow { $script:Now }
        Mock Test-WatchdogEventSource { $true }
        Mock Get-WatchdogHostIdentity { @{ HostName = 'SRV-EXAMPLE-01'; Fqdn = 'srv-example-01.example.com' } }
    }

    Context 'Parameter validation' {

        It 'rejects an invalid -Verbosity value' {
            { & $script:WorkerPath -Verbosity 'Bogus' } |
                Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
        }

        It 'rejects -TestAlert combined with -ValidateConfig with exit 2' {
            $code = Invoke-WatchdogMain -ConfigPath 'x.json' -TestAlert -ValidateConfig -LogPath $script:LogPath
            $code | Should -Be 2
        }

        It 'rejects -TestAlert combined with -SendHeartbeat with exit 2' {
            $code = Invoke-WatchdogMain -ConfigPath 'x.json' -TestAlert -SendHeartbeat -LogPath $script:LogPath
            $code | Should -Be 2
        }

        It 'rejects -ValidateConfig combined with -SendHeartbeat with exit 2' {
            $code = Invoke-WatchdogMain -ConfigPath 'x.json' -ValidateConfig -SendHeartbeat -LogPath $script:LogPath
            $code | Should -Be 2
        }
    }

    Context 'Import-WatchdogConfig' {

        It 'throws when the file does not exist' {
            { Import-WatchdogConfig -Path (Join-Path $script:Scratch 'missing.json') } | Should -Throw
        }

        It 'throws on invalid JSON' {
            $path = Join-Path $script:Scratch 'bad.json'
            Set-Content -LiteralPath $path -Value '{ not json' -Encoding utf8
            { Import-WatchdogConfig -Path $path } | Should -Throw
        }

        It 'returns nested hashtables for a valid file' {
            $path = New-TestConfigFile
            $raw = Import-WatchdogConfig -Path $path
            $raw | Should -BeOfType [hashtable]
            $raw.Webhook | Should -BeOfType [hashtable]
            $raw.Webhook.TimeoutSeconds | Should -Be 30
            @($raw.Services) | Should -HaveCount 2
        }

        It 'parses the shipped example config and fails only on its placeholders' {
            $raw = Import-WatchdogConfig -Path $script:ExampleConfigPath
            $validation = Test-WatchdogConfig -Config $raw
            $validation.IsValid | Should -BeFalse
            $validation.Warnings | Should -BeNullOrEmpty
            $validation.Errors | Should -HaveCount 2
            ($validation.Errors -join ' ') | Should -Match 'Webhook\.Url'
            ($validation.Errors -join ' ') | Should -Match 'Webhook\.FunctionKey'
        }
    }

    Context 'Test-WatchdogConfig' {

        It 'accepts a valid config with no errors or warnings' {
            $validation = Test-WatchdogConfig -Config (New-TestRawConfig)
            $validation.IsValid | Should -BeTrue
            $validation.Errors | Should -BeNullOrEmpty
            $validation.Warnings | Should -BeNullOrEmpty
        }

        It 'applies defaults for missing optional keys' {
            $raw = New-TestRawConfig -Remove @(
                'MaxStartAttempts', 'RetryDelaySeconds', 'PostStartVerifySeconds',
                'StartPendingWaitSeconds', 'MaxRunSeconds', 'Alerting', 'Logging', 'Webhook.TimeoutSeconds'
            )
            $validation = Test-WatchdogConfig -Config $raw
            $validation.IsValid | Should -BeTrue
            $cfg = $validation.Config
            $cfg.MaxStartAttempts | Should -Be 5
            $cfg.RetryDelaySeconds | Should -Be 30
            $cfg.PostStartVerifySeconds | Should -Be 10
            $cfg.StartPendingWaitSeconds | Should -Be 60
            $cfg.MaxRunSeconds | Should -Be 240
            $cfg.Webhook.TimeoutSeconds | Should -Be 30
            $cfg.Alerting.ReminderMinutes | Should -Be 240
            $cfg.Alerting.NotifyOnRemediation | Should -BeFalse
            $cfg.Alerting.RemediationCooldownMinutes | Should -Be 60
            $cfg.Alerting.HeartbeatHours | Should -Be 24
            $cfg.Logging.LogRoot | Should -Be ''
            $cfg.Logging.LogRetentionDays | Should -Be 30
            $cfg.Logging.EventLogHealthyRuns | Should -BeFalse
        }

        It 'reports range violation for <Key> = <Value> by name' -TestCases @(
            @{ Key = 'MaxStartAttempts'; Section = ''; Value = 0 }
            @{ Key = 'MaxStartAttempts'; Section = ''; Value = 21 }
            @{ Key = 'RetryDelaySeconds'; Section = ''; Value = 301 }
            @{ Key = 'PostStartVerifySeconds'; Section = ''; Value = 121 }
            @{ Key = 'StartPendingWaitSeconds'; Section = ''; Value = -1 }
            @{ Key = 'MaxRunSeconds'; Section = ''; Value = 29 }
            @{ Key = 'MaxRunSeconds'; Section = ''; Value = 3601 }
            @{ Key = 'TimeoutSeconds'; Section = 'Webhook'; Value = 4 }
            @{ Key = 'ReminderMinutes'; Section = 'Alerting'; Value = 4 }
            @{ Key = 'RemediationCooldownMinutes'; Section = 'Alerting'; Value = 10081 }
            @{ Key = 'HeartbeatHours'; Section = 'Alerting'; Value = 0 }
            @{ Key = 'LogRetentionDays'; Section = 'Logging'; Value = 366 }
            @{ Key = 'MaxStartAttempts'; Section = ''; Value = 'five' }
        ) {
            param ($Key, $Section, $Value)
            if ($Section) {
                $raw = New-TestRawConfig -Overrides @{ $Section = @{ $Key = $Value } }
                $expected = "$Section.$Key"
            }
            else {
                $raw = New-TestRawConfig -Overrides @{ $Key = $Value }
                $expected = $Key
            }
            $validation = Test-WatchdogConfig -Config $raw
            $validation.IsValid | Should -BeFalse
            ($validation.Errors -join ' ') | Should -Match ([regex]::Escape($expected))
        }

        It 'rejects SchemaVersion other than 1' {
            $validation = Test-WatchdogConfig -Config (New-TestRawConfig -Overrides @{ SchemaVersion = 2 })
            $validation.IsValid | Should -BeFalse
            ($validation.Errors -join ' ') | Should -Match 'SchemaVersion'
        }

        It 'rejects an empty or over-long SiteName' {
            (Test-WatchdogConfig -Config (New-TestRawConfig -Overrides @{ SiteName = '' })).IsValid | Should -BeFalse
            $long = 'x' * 65
            (Test-WatchdogConfig -Config (New-TestRawConfig -Overrides @{ SiteName = $long })).IsValid | Should -BeFalse
        }

        It 'rejects more than 100 services' {
            $many = 1..101 | ForEach-Object { "Svc$_" }
            $validation = Test-WatchdogConfig -Config (New-TestRawConfig -Overrides @{ Services = $many })
            $validation.IsValid | Should -BeFalse
            ($validation.Errors -join ' ') | Should -Match 'Services'
        }

        It 'rejects an empty service list and duplicate names' {
            (Test-WatchdogConfig -Config (New-TestRawConfig -Overrides @{ Services = @() })).IsValid | Should -BeFalse
            $dup = Test-WatchdogConfig -Config (New-TestRawConfig -Overrides @{ Services = @('Spooler', 'spooler') })
            $dup.IsValid | Should -BeFalse
            ($dup.Errors -join ' ') | Should -Match 'unique'
        }

        It 'rejects a missing Services key' {
            $validation = Test-WatchdogConfig -Config (New-TestRawConfig -Remove 'Services')
            $validation.IsValid | Should -BeFalse
            ($validation.Errors -join ' ') | Should -Match 'Services'
        }

        It 'detects placeholder values and names the key to edit' {
            $raw = New-TestRawConfig -Overrides @{ Webhook = @{ FunctionKey = 'REPLACE_WITH_FUNCTION_KEY' } }
            $validation = Test-WatchdogConfig -Config $raw
            $validation.IsValid | Should -BeFalse
            ($validation.Errors -join ' ') | Should -Match 'Webhook\.FunctionKey'
            ($validation.Errors -join ' ') | Should -Match 'placeholder'
        }

        It 'detects the upper-case REPLACE placeholder in <Key>' -TestCases @(
            @{ Key = 'SiteName'; Overrides = @{ SiteName = 'REPLACE-ME' } }
            @{ Key = 'Webhook.Url'; Overrides = @{ Webhook = @{ Url = 'https://REPLACE-ME.example.com/api/alert' } } }
            @{ Key = 'Webhook.FunctionKey'; Overrides = @{ Webhook = @{ FunctionKey = 'REPLACE_WITH_FUNCTION_KEY' } } }
        ) {
            $validation = Test-WatchdogConfig -Config (New-TestRawConfig -Overrides $Overrides)
            $validation.IsValid | Should -BeFalse
            $validation.Errors | Should -HaveCount 1
            $validation.Errors[0] | Should -Match ([regex]::Escape($Key))
            $validation.Errors[0] | Should -Match 'placeholder'
        }

        It 'accepts legitimate values that merely contain the word replace in another case' {
            # The placeholder token is the literal upper-case REPLACE (DESIGN.md 4.3); a
            # function app named svc-replace or a site called Replacement Parts is not one.
            $raw = New-TestRawConfig -Overrides @{
                SiteName = 'Replacement Parts'
                Webhook  = @{ Url = 'https://svc-replace.example.com/api'; FunctionKey = 'key-to-replace-later' }
            }
            $validation = Test-WatchdogConfig -Config $raw
            $validation.IsValid | Should -BeTrue
            $validation.Errors | Should -HaveCount 0
            $validation.Config.SiteName | Should -Be 'Replacement Parts'
            $validation.Config.Webhook.Url | Should -Be 'https://svc-replace.example.com/api'
        }

        It 'requires an https webhook URL and a non-empty key' {
            $http = New-TestRawConfig -Overrides @{ Webhook = @{ Url = 'http://watchdog.example.com/api' } }
            ($http = Test-WatchdogConfig -Config $http).IsValid | Should -BeFalse
            ($http.Errors -join ' ') | Should -Match 'https'
            $noKey = Test-WatchdogConfig -Config (New-TestRawConfig -Overrides @{ Webhook = @{ FunctionKey = '' } })
            $noKey.IsValid | Should -BeFalse
            $noSection = Test-WatchdogConfig -Config (New-TestRawConfig -Remove 'Webhook')
            $noSection.IsValid | Should -BeFalse
            ($noSection.Errors -join ' ') | Should -Match 'Webhook\.Url'
        }

        It 'requires boolean values for the boolean keys' {
            $raw = New-TestRawConfig -Overrides @{ Alerting = @{ NotifyOnRemediation = 'yes' } }
            $validation = Test-WatchdogConfig -Config $raw
            $validation.IsValid | Should -BeFalse
            ($validation.Errors -join ' ') | Should -Match 'Alerting\.NotifyOnRemediation'
        }

        It 'warns about unknown keys without failing' {
            $raw = New-TestRawConfig -Overrides @{ FutureKey = 1; Webhook = @{ Extra = 'x' } }
            $validation = Test-WatchdogConfig -Config $raw
            $validation.IsValid | Should -BeTrue
            ($validation.Warnings -join ' ') | Should -Match 'FutureKey'
            ($validation.Warnings -join ' ') | Should -Match 'Webhook\.Extra'
        }

        It 'warns when StartPendingWaitSeconds times the service count exceeds MaxRunSeconds' {
            $raw = New-TestRawConfig -Overrides @{ StartPendingWaitSeconds = 200; MaxRunSeconds = 240 }
            $validation = Test-WatchdogConfig -Config $raw
            $validation.IsValid | Should -BeTrue
            ($validation.Warnings -join ' ') | Should -Match 'StartPendingWaitSeconds'
        }

        It 'lists every violation at once' {
            $raw = New-TestRawConfig -Overrides @{ MaxStartAttempts = 0; MaxRunSeconds = 1; SiteName = '' }
            $validation = Test-WatchdogConfig -Config $raw
            $validation.Errors.Count | Should -BeGreaterOrEqual 3
        }
    }

    Context 'Timestamps' {

        It 'formats datetimes as yyyy-MM-ddTHH:mm:ssZ in UTC' {
            $local = [datetime]::new(2026, 9, 4, 18, 5, 2, [System.DateTimeKind]::Utc).ToLocalTime()
            ConvertTo-WatchdogTimestamp -Value $local | Should -Be '2026-09-04T18:05:02Z'
        }

        It 'returns null for null input' {
            ConvertTo-WatchdogTimestamp -Value $null | Should -BeNullOrEmpty
        }

        It 'parses the format back to a UTC datetime and null for junk' {
            $parsed = ConvertFrom-WatchdogTimestamp -Value '2026-09-04T18:05:02Z'
            $parsed.Kind | Should -Be 'Utc'
            $parsed.Hour | Should -Be 18
            ConvertFrom-WatchdogTimestamp -Value 'not-a-date' | Should -BeNullOrEmpty
            ConvertFrom-WatchdogTimestamp -Value $null | Should -BeNullOrEmpty
        }
    }

    Context 'State file' {

        BeforeAll {
            Mock Write-WatchdogEvent { }
        }

        It 'returns an empty state when the file is missing' {
            $state = Get-WatchdogState -Path (Join-Path $script:Scratch 'nope.state.json')
            $state.PendingNotification | Should -BeFalse
            $state.Services.Count | Should -Be 0
            $state.SchemaVersion | Should -Be 1
            Should -Invoke Write-WatchdogEvent -Times 0
        }

        It 'treats corrupt JSON as empty with a warning and event 1021' {
            Mock Write-Log { }
            $path = Join-Path $script:Scratch 'corrupt.state.json'
            Set-Content -LiteralPath $path -Value '{{{' -Encoding utf8
            $state = Get-WatchdogState -Path $path
            $state.Services.Count | Should -Be 0
            Should -Invoke Write-Log -ParameterFilter { $Level -eq 'WARNING' } -Times 1
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1021 } -Times 1 -Exactly
        }

        It 'treats a structurally invalid state (wrong schema) as empty with event 1021' {
            $path = Join-Path $script:Scratch 'wrongschema.state.json'
            Set-Content -LiteralPath $path -Value '{"SchemaVersion": 7, "Services": "x"}' -Encoding utf8
            $state = Get-WatchdogState -Path $path
            $state.Services.Count | Should -Be 0
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1021 } -Times 1 -Exactly
        }

        It 'loads a valid state file with case-insensitive service keys' {
            $path = Join-Path $script:Scratch 'good.state.json'
            $entry = New-TestEntry -Status 'Failed' -FirstFailedUtc (Get-TestTimestamp -60)
            Save-WatchdogState -Path $path -State (New-TestState -Services @{ Spooler = $entry })
            $state = Get-WatchdogState -Path $path
            $state.Services['spooler'].Status | Should -Be 'Failed'
            $state.Services['Spooler'].FirstFailedUtc | Should -Be (Get-TestTimestamp -60)
        }

        It 'writes the state atomically through a temp file and a move' {
            Mock Move-Item { }
            $path = Join-Path $script:Scratch 'atomic.state.json'
            Save-WatchdogState -Path $path -State (New-TestState)
            Should -Invoke Move-Item -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -like '*.tmp' -and $Destination -eq $path -and $Force
            }
            Test-Path -LiteralPath $path | Should -BeFalse
        }

        It 'serializes timestamps as strings in the 4.4 format' {
            $path = Join-Path $script:Scratch 'ts.state.json'
            $overrides = @{ LastRunUtc = Get-TestTimestamp; LastHeartbeatUtc = Get-TestTimestamp -30 }
            $state = New-TestState -Overrides $overrides
            Save-WatchdogState -Path $path -State $state
            $json = Get-Content -LiteralPath $path -Raw
            $json | Should -Match '"LastRunUtc":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
            $json | Should -Not -Match '\\/Date\('
            Get-ChildItem -LiteralPath $script:Scratch -Filter '*.tmp' | Should -BeNullOrEmpty
        }

        It 'does not write the state file under -DryRun' {
            $script:DryRun = $true
            try {
                $path = Join-Path $script:Scratch 'dryrun.state.json'
                Save-WatchdogState -Path $path -State (New-TestState)
                Test-Path -LiteralPath $path | Should -BeFalse
            }
            finally {
                $script:DryRun = $false
            }
        }

        It 'removes entries no longer configured and writes 1006 only for unhealthy ones' {
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Failed'
                OldBad  = New-TestEntry -Status 'Missing'
                OldGood = New-TestEntry -Status 'Healthy'
            }
            Remove-WatchdogUnmonitoredState -State $state -ServiceNames @('Spooler')
            $state.Services.Keys | Should -Be @('Spooler')
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1006 -and $Message -like '*OldBad*' } `
                -Times 1 -Exactly
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1006 -and $Message -like '*OldGood*' } `
                -Times 0
        }
    }

    Context 'Service status' {

        BeforeAll {
            Mock Write-Log { }
            Mock Get-WatchdogRemainingBudget { 240 }
            Mock Start-WatchdogService { }
            Mock Wait-WatchdogServiceStatus { }
            $script:Config = New-TestConfig
        }

        It 'reports Missing with a null StartType when Get-Service throws' {
            Mock Get-Service { throw 'Cannot find any service with service name' }
            $result = Invoke-WatchdogServiceCheck -Name 'Ghost' -Config $script:Config
            $result.Status | Should -Be 'Missing'
            $result.StartType | Should -BeNullOrEmpty
            $result.Eligible | Should -BeFalse
        }

        It 'reports Disabled and never starts when StartMode is Disabled' {
            Mock Get-Service { New-FakeService -Status 'Stopped' }
            Mock Get-CimInstance { New-FakeCim -StartMode 'Disabled' }
            $result = Invoke-WatchdogServiceCheck -Name 'Spooler' -Config $script:Config
            $result.Status | Should -Be 'Disabled'
            $result.StartType | Should -Be 'Disabled'
            $result.Eligible | Should -BeFalse
            $result.DisplayName | Should -Be 'Print Spooler'
        }

        It 'reports Healthy for a Running service' {
            Mock Get-Service { New-FakeService -Status 'Running' }
            Mock Get-CimInstance { New-FakeCim }
            $result = Invoke-WatchdogServiceCheck -Name 'Spooler' -Config $script:Config
            $result.Status | Should -Be 'Healthy'
            $result.Eligible | Should -BeFalse
            $result.StartType | Should -Be 'Automatic'
        }

        It 'waits on StartPending with the wait capped by the remaining budget and issues no start' {
            Mock Get-Service { New-FakeService -Status 'StartPending' }
            Mock Get-CimInstance { New-FakeCim }
            Mock Get-WatchdogRemainingBudget { 7 }
            $result = Invoke-WatchdogServiceCheck -Name 'Spooler' -Config $script:Config
            $result.Status | Should -Be 'Healthy'
            Should -Invoke Wait-WatchdogServiceStatus -Times 1 -Exactly -ParameterFilter {
                $Status -eq 'Running' -and $TimeoutSeconds -eq 7
            }
            Should -Invoke Start-WatchdogService -Times 0
        }

        It 'marks a StartPending service Failed with a budget note when the wait times out' {
            Mock Get-Service { New-FakeService -Status 'StartPending' }
            Mock Get-CimInstance { New-FakeCim }
            Mock Wait-WatchdogServiceStatus { throw [System.TimeoutException]::new('Time out has expired') }
            $result = Invoke-WatchdogServiceCheck -Name 'Spooler' -Config $script:Config
            $result.Status | Should -Be 'Failed'
            $result.Eligible | Should -BeFalse
            $result.LastError | Should -Match 'StartPending'
            $result.LastError | Should -Match 'budget'
            Should -Invoke Start-WatchdogService -Times 0
        }

        It 'marks a Stopped service Failed and eligible for start rounds' {
            Mock Get-Service { New-FakeService -Status 'Stopped' }
            Mock Get-CimInstance { New-FakeCim -StartMode 'Manual' }
            $result = Invoke-WatchdogServiceCheck -Name 'Spooler' -Config $script:Config
            $result.Status | Should -Be 'Failed'
            $result.Eligible | Should -BeTrue
            $result.StartType | Should -Be 'Manual'
        }

        It 'reports Unknown when the check throws unexpectedly' {
            Mock Get-Service { New-FakeService -Status 'Running' }
            Mock Get-CimInstance { throw 'WMI is broken' }
            $result = Invoke-WatchdogServiceCheck -Name 'Spooler' -Config $script:Config
            $result.Status | Should -Be 'Unknown'
            $result.Eligible | Should -BeFalse
            $result.LastError | Should -Match 'WMI is broken'
        }

        It 'maps StartMode <StartMode> (delayed=<Delayed>) to <Expected>' -TestCases @(
            @{ StartMode = 'Auto'; Delayed = $false; Expected = 'Automatic' }
            @{ StartMode = 'Auto'; Delayed = $true; Expected = 'AutomaticDelayedStart' }
            @{ StartMode = 'Manual'; Delayed = $false; Expected = 'Manual' }
            @{ StartMode = 'Boot'; Delayed = $false; Expected = 'Boot' }
            @{ StartMode = 'System'; Delayed = $false; Expected = 'System' }
            @{ StartMode = 'Disabled'; Delayed = $false; Expected = 'Disabled' }
            @{ StartMode = 'Strange'; Delayed = $false; Expected = 'Unknown' }
        ) {
            param ($StartMode, $Delayed, $Expected)
            Mock Get-Service { New-FakeService -Status 'Running' }
            Mock Get-CimInstance { New-FakeCim -StartMode $StartMode -Delayed $Delayed }
            (Get-WatchdogServiceStatus -Name 'Spooler').StartType | Should -Be $Expected
        }

        It 'resolves a display name to the short name and logs it' {
            Mock Get-Service -ParameterFilter { $Name } { throw 'no such service' }
            Mock Get-Service -ParameterFilter { $DisplayName } {
                [pscustomobject]@{ Name = 'Spooler'; DisplayName = 'Print Spooler'; Status = 'Running' }
            }
            Mock Get-CimInstance { New-FakeCim }
            $status = Get-WatchdogServiceStatus -Name 'Print Spooler'
            $status.ResolvedName | Should -Be 'Spooler'
            $status.Status | Should -Be 'Running'
            Should -Invoke Write-Log -ParameterFilter { $Message -like '*resolved*Spooler*' }
        }

        It 'escapes wildcard characters so a name with brackets is matched literally' {
            Mock Get-Service { New-FakeService -Name 'Svc[1]' -DisplayName 'Svc One' -Status 'Running' }
            Mock Get-CimInstance { New-FakeCim }
            (Get-WatchdogServiceStatus -Name 'Svc[1]').Status | Should -Be 'Running'
            Should -Invoke Get-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'Svc`[1`]' }
        }

        It 'escapes single quotes in the WQL filter' {
            Mock Get-Service { [pscustomobject]@{ Name = "O'Svc"; DisplayName = "O'Svc"; Status = 'Running' } }
            Mock Get-CimInstance { New-FakeCim }
            Get-WatchdogServiceStatus -Name "O'Svc" | Out-Null
            Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter {
                $ClassName -eq 'Win32_Service' -and $Filter -eq "Name='O\'Svc'"
            }
        }
    }

    Context 'Start-WatchdogService' {

        BeforeAll {
            Mock Write-Log { }
        }

        It 'calls Start() then waits for Running with the given timeout' {
            $script:StartCalls = 0
            $script:WaitArgs = $null
            $fake = [pscustomobject]@{ Name = 'Spooler'; Status = 'Stopped' }
            $fake | Add-Member -MemberType ScriptMethod -Name Start -Value { $script:StartCalls++ }
            $fake | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
                param ($DesiredStatus, $Timeout)
                $script:WaitArgs = @{ Status = $DesiredStatus; Timeout = $Timeout }
            }
            Mock Get-Service { $fake }
            Start-WatchdogService -Name 'Spooler' -WaitSeconds 12
            $script:StartCalls | Should -Be 1
            $script:WaitArgs.Status | Should -Be 'Running'
            $script:WaitArgs.Timeout | Should -Be ([TimeSpan]::FromSeconds(12))
        }

        It 'throws a descriptive error when the wait times out' {
            $fake = [pscustomobject]@{ Name = 'Spooler'; Status = 'Stopped' }
            $fake | Add-Member -MemberType ScriptMethod -Name Start -Value { }
            $fake | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
                throw [System.TimeoutException]::new('Time out has expired')
            }
            Mock Get-Service { $fake }
            { Start-WatchdogService -Name 'Spooler' -WaitSeconds 3 } | Should -Throw '*did not reach Running*'
        }
    }

    Context 'Start rounds' {

        BeforeAll {
            Mock Write-Log { }
            Mock Write-WatchdogEvent { }
            Mock Start-Service { throw 'Start-Service must never be called' }
            Mock Get-WatchdogRemainingBudget { 240 }
        }

        It 'records Attempts = 2 and event 1001 when the second round succeeds' {
            $script:Reads = 0
            Mock Start-WatchdogService { }
            Mock Get-WatchdogServiceStatus {
                $script:Reads++
                $status = if ($script:Reads -ge 2) { 'Running' } else { 'Stopped' }
                New-TestStatus -Name 'Spooler' -DisplayName 'Print Spooler' -Status $status
            }
            $config = New-TestConfig -Overrides @{ MaxStartAttempts = 3 }
            $result = New-TestResult -Name 'Spooler' -Status 'Failed' -Eligible $true
            Invoke-WatchdogStartRounds -Results @($result) -Config $config
            $result.Status | Should -Be 'Healthy'
            $result.Remediated | Should -BeTrue
            $result.Attempts | Should -Be 2
            $result.LastError | Should -BeNullOrEmpty
            Should -Invoke Start-WatchdogService -Times 2 -Exactly
            Should -Invoke Write-WatchdogEvent -Times 1 -Exactly -ParameterFilter {
                $EventId -eq 1001 -and $Message -like '*2*'
            }
            Should -Invoke Start-Service -Times 0
        }

        It 'records the last error after MaxStartAttempts failures' {
            Mock Start-WatchdogService { throw "Cannot start service Spooler on computer '.'" }
            Mock Get-WatchdogServiceStatus { @{ Name = 'Spooler'; Status = 'Stopped' } }
            $config = New-TestConfig -Overrides @{ MaxStartAttempts = 3 }
            $result = New-TestResult -Name 'Spooler' -Status 'Failed' -Eligible $true
            Invoke-WatchdogStartRounds -Results @($result) -Config $config
            $result.Status | Should -Be 'Failed'
            $result.Attempts | Should -Be 3
            $result.LastError | Should -Match 'Cannot start service Spooler'
            Should -Invoke Start-WatchdogService -Times 3 -Exactly
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1001 } -Times 0
            Should -Invoke Start-Service -Times 0
        }

        It 'treats a service that started then stopped again as failed with a flapping message' {
            Mock Start-WatchdogService { }
            Mock Get-WatchdogServiceStatus { @{ Name = 'Spooler'; Status = 'Stopped' } }
            $config = New-TestConfig -Overrides @{ MaxStartAttempts = 2 }
            $result = New-TestResult -Name 'Spooler' -Status 'Failed' -Eligible $true
            Invoke-WatchdogStartRounds -Results @($result) -Config $config
            $result.Status | Should -Be 'Failed'
            $result.LastError | Should -Match 'stopped again'
            $result.Attempts | Should -Be 2
        }

        It 'stops rounds when the time budget is exhausted and annotates LastError' {
            $script:BudgetCalls = 0
            Mock Get-WatchdogRemainingBudget {
                $script:BudgetCalls++
                if ($script:BudgetCalls -le 2) { 100 } else { 0 }
            }
            Mock Start-WatchdogService { }
            Mock Get-WatchdogServiceStatus { @{ Name = 'Spooler'; Status = 'Stopped' } }
            $config = New-TestConfig -Overrides @{ MaxStartAttempts = 5 }
            $result = New-TestResult -Name 'Spooler' -Status 'Failed' -Eligible $true
            Invoke-WatchdogStartRounds -Results @($result) -Config $config
            $result.Status | Should -Be 'Failed'
            $result.Attempts | Should -Be 1
            $result.LastError | Should -Match 'budget'
            Should -Invoke Start-WatchdogService -Times 1 -Exactly
        }

        It 'marks eligible services Failed with a budget note when no time remains before the first round' {
            Mock Get-WatchdogRemainingBudget { 0 }
            Mock Start-WatchdogService { }
            $config = New-TestConfig
            $result = New-TestResult -Name 'Spooler' -Status 'Failed' -Eligible $true
            Invoke-WatchdogStartRounds -Results @($result) -Config $config
            $result.Attempts | Should -Be 0
            $result.LastError | Should -Match 'budget'
            Should -Invoke Start-WatchdogService -Times 0
        }

        It 'sleeps RetryDelaySeconds between rounds, capped by the remaining budget' {
            $script:BudgetCalls = 0
            Mock Get-WatchdogRemainingBudget { 5 }
            Mock Start-WatchdogService { }
            Mock Get-WatchdogServiceStatus { @{ Name = 'Spooler'; Status = 'Stopped' } }
            $config = New-TestConfig -Overrides @{ MaxStartAttempts = 2; RetryDelaySeconds = 30 }
            $result = New-TestResult -Name 'Spooler' -Status 'Failed' -Eligible $true
            Invoke-WatchdogStartRounds -Results @($result) -Config $config
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        }

        It 'caps the post-start wait at the remaining budget' {
            Mock Get-WatchdogRemainingBudget { 3 }
            Mock Start-WatchdogService { }
            Mock Get-WatchdogServiceStatus { @{ Name = 'Spooler'; Status = 'Running' } }
            $config = New-TestConfig -Overrides @{ PostStartVerifySeconds = 60 }
            $result = New-TestResult -Name 'Spooler' -Status 'Failed' -Eligible $true
            Invoke-WatchdogStartRounds -Results @($result) -Config $config
            Should -Invoke Start-WatchdogService -Times 1 -Exactly -ParameterFilter { $WaitSeconds -eq 3 }
        }

        It 'leaves non-eligible services untouched' {
            Mock Start-WatchdogService { }
            $config = New-TestConfig
            $missing = New-TestResult -Name 'Ghost' -Status 'Missing' -StartType $null
            Invoke-WatchdogStartRounds -Results @($missing) -Config $config
            $missing.Status | Should -Be 'Missing'
            $missing.Attempts | Should -Be 0
            Should -Invoke Start-WatchdogService -Times 0
        }

        It 'does not start anything under -DryRun and logs the intended action' {
            Mock Start-WatchdogService { }
            $script:DryRun = $true
            try {
                $config = New-TestConfig
                $result = New-TestResult -Name 'Spooler' -Status 'Failed' -Eligible $true
                Invoke-WatchdogStartRounds -Results @($result) -Config $config
                Should -Invoke Start-WatchdogService -Times 0
                Should -Invoke Write-Log -ParameterFilter { $Message -like '*`[DRYRUN`]*Spooler*' }
                $result.Status | Should -Be 'Failed'
            }
            finally {
                $script:DryRun = $false
            }
        }
    }

    Context 'Flap tracking' {

        BeforeAll {
            Mock Write-Log { }
            Mock Write-WatchdogEvent { }
        }

        It 'counts transitions inside the 60-minute window and flags flapping on the fourth' {
            $entry = New-TestEntry -FlapCount 3 -FlapWindowStartUtc (Get-TestTimestamp -30)
            $flap = Update-WatchdogFlapState -Entry $entry -Transition $true -Now $script:Now -ReminderMinutes 240
            $flap.Category | Should -Be 'flapping'
            $flap.FlapCount | Should -Be 4
            $entry.FlapSuppressedUntilUtc | Should -Be (Get-TestTimestamp 240)
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1007 } -Times 1 -Exactly
        }

        It 'does not flag flapping below four transitions' {
            $entry = New-TestEntry -FlapCount 2 -FlapWindowStartUtc (Get-TestTimestamp -30)
            $flap = Update-WatchdogFlapState -Entry $entry -Transition $true -Now $script:Now -ReminderMinutes 240
            $flap.Category | Should -BeNullOrEmpty
            $flap.Suppressed | Should -BeFalse
            $entry.FlapCount | Should -Be 3
            $entry.FlapSuppressedUntilUtc | Should -BeNullOrEmpty
        }

        It 'restarts the window when 60 minutes have passed since it began' {
            $entry = New-TestEntry -FlapCount 3 -FlapWindowStartUtc (Get-TestTimestamp -61)
            $flap = Update-WatchdogFlapState -Entry $entry -Transition $true -Now $script:Now -ReminderMinutes 240
            $flap.Category | Should -BeNullOrEmpty
            $entry.FlapCount | Should -Be 1
            $entry.FlapWindowStartUtc | Should -Be (Get-TestTimestamp)
        }

        It 'resets an expired window when no transition occurs' {
            $entry = New-TestEntry -FlapCount 2 -FlapWindowStartUtc (Get-TestTimestamp -61)
            Update-WatchdogFlapState -Entry $entry -Transition $false -Now $script:Now -ReminderMinutes 240 | Out-Null
            $entry.FlapCount | Should -Be 0
            $entry.FlapWindowStartUtc | Should -BeNullOrEmpty
        }

        It 'reports suppressed while the suppression time has not passed' {
            $entry = New-TestEntry -FlapSuppressedUntilUtc (Get-TestTimestamp 100)
            $flap = Update-WatchdogFlapState -Entry $entry -Transition $true -Now $script:Now -ReminderMinutes 240
            $flap.Suppressed | Should -BeTrue
            $flap.Category | Should -BeNullOrEmpty
            $entry.FlapCount | Should -Be 1
            Should -Invoke Write-WatchdogEvent -Times 0
        }

        It 'releases suppression and resets the flap fields after a stable interval' {
            $entry = New-TestEntry -FlapCount 0 -FlapSuppressedUntilUtc (Get-TestTimestamp -1)
            $flap = Update-WatchdogFlapState -Entry $entry -Transition $false -Now $script:Now -ReminderMinutes 240
            $flap.Suppressed | Should -BeFalse
            $flap.Category | Should -BeNullOrEmpty
            $entry.FlapCount | Should -Be 0
            $entry.FlapWindowStartUtc | Should -BeNullOrEmpty
            $entry.FlapSuppressedUntilUtc | Should -BeNullOrEmpty
        }

        It 're-sends flapping and extends suppression when the service was unstable during suppression' {
            $entry = New-TestEntry -FlapCount 2 -FlapSuppressedUntilUtc (Get-TestTimestamp -1)
            $flap = Update-WatchdogFlapState -Entry $entry -Transition $false -Now $script:Now -ReminderMinutes 240
            $flap.Category | Should -Be 'flapping'
            $flap.Suppressed | Should -BeTrue
            $entry.FlapSuppressedUntilUtc | Should -Be (Get-TestTimestamp 240)
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1007 } -Times 1 -Exactly
        }
    }

    Context 'Notification plan' {

        BeforeAll {
            Mock Write-Log { }
            Mock Write-WatchdogEvent { }
            $script:Config = New-TestConfig
        }

        It 'categorizes <Previous> to <New> as alert and sets FirstFailedUtc' -TestCases @(
            @{ Previous = $null; New = 'Failed' }
            @{ Previous = 'Healthy'; New = 'Missing' }
            @{ Previous = 'Unknown'; New = 'Disabled' }
        ) {
            param ($Previous, $New)
            $services = @{}
            if ($Previous) { $services['Spooler'] = New-TestEntry -Status $Previous }
            $state = New-TestState -Services $services
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status $New)) `
                -State $state -Config $script:Config -Now $script:Now
            $plan.EventType | Should -Be 'alert'
            $plan.Items[0].Category | Should -Be 'alert'
            $plan.Items[0].Notify | Should -BeTrue
            $plan.Items[0].Entry.FirstFailedUtc | Should -Be (Get-TestTimestamp)
            $plan.Items[0].Entry.Status | Should -Be $New
            $plan.NotifiableNames | Should -Be @('Spooler')
        }

        It 'writes 1002, 1003 or 1004 for an alert depending on status' -TestCases @(
            @{ New = 'Failed'; Expected = 1002 }
            @{ New = 'Missing'; Expected = 1003 }
            @{ New = 'Disabled'; Expected = 1004 }
        ) {
            param ($New, $Expected)
            $state = New-TestState
            Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status $New)) `
                -State $state -Config $script:Config -Now $script:Now | Out-Null
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq $Expected } -Times 1 -Exactly
        }

        It 'sends a reminder only when ReminderMinutes has elapsed since LastNotifiedUtc' {
            $due = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Failed' -FirstFailedUtc (Get-TestTimestamp -600) `
                    -LastNotifiedUtc (Get-TestTimestamp -300)
            }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Failed')) `
                -State $due -Config $script:Config -Now $script:Now
            $plan.EventType | Should -Be 'reminder'
            $plan.Items[0].Entry.FirstFailedUtc | Should -Be (Get-TestTimestamp -600)
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1002 } -Times 1 -Exactly

            $notDue = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Failed' -FirstFailedUtc (Get-TestTimestamp -600) `
                    -LastNotifiedUtc (Get-TestTimestamp -100)
            }
            $plan2 = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Failed')) `
                -State $notDue -Config $script:Config -Now $script:Now
            $plan2.EventType | Should -BeNullOrEmpty
            $plan2.Items[0].Category | Should -BeNullOrEmpty
            $plan2.Items[0].Notify | Should -BeFalse
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1002 } -Times 1 -Exactly
        }

        It 'treats a different problem (Missing to Failed) as a new alert' {
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Missing' -FirstFailedUtc (Get-TestTimestamp -600) `
                    -LastNotifiedUtc (Get-TestTimestamp -10)
            }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Failed')) `
                -State $state -Config $script:Config -Now $script:Now
            $plan.EventType | Should -Be 'alert'
            $plan.Items[0].Entry.FirstFailedUtc | Should -Be (Get-TestTimestamp -600)
        }

        It 'categorizes a problem to Healthy as recovered, clears FirstFailedUtc and writes 1005' {
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Failed' -FirstFailedUtc (Get-TestTimestamp -600) `
                    -LastNotifiedUtc (Get-TestTimestamp -10)
            }
            $result = New-TestResult -Name 'Spooler' -Status 'Healthy' -Remediated $true
            $plan = Get-TestPlan -Results @($result) -State $state
            $plan.EventType | Should -Be 'recovered'
            $plan.Items[0].Entry.FirstFailedUtc | Should -BeNullOrEmpty
            $plan.Items[0].PayloadStatus | Should -Be 'Recovered'
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1005 } -Times 1 -Exactly
        }

        It 'categorizes Unknown after a problem as recovered' {
            $state = New-TestState -Services @{ Spooler = New-TestEntry -Status 'Missing' }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Unknown')) `
                -State $state -Config $script:Config -Now $script:Now
            $plan.EventType | Should -Be 'recovered'
        }

        It 'sends remediated only when NotifyOnRemediation is on and the cooldown has elapsed' {
            $config = New-TestConfig -Overrides @{ Alerting = @{ NotifyOnRemediation = $true } }
            $result = New-TestResult -Name 'Spooler' -Status 'Healthy' -Remediated $true -Attempts 1
            $plan = Get-TestPlan -Results @($result) -State (New-TestState) -Config $config
            $plan.EventType | Should -Be 'remediated'
            $plan.Items[0].PayloadStatus | Should -Be 'Remediated'
            $plan.Items[0].Entry.LastRemediatedUtc | Should -Be (Get-TestTimestamp)
            Should -Invoke Write-WatchdogEvent -Times 0

            $cooling = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Healthy' -LastRemediatedUtc (Get-TestTimestamp -30)
            }
            $plan2 = Get-WatchdogNotificationPlan -Results @($result) -State $cooling -Config $config -Now $script:Now
            $plan2.EventType | Should -BeNullOrEmpty
            $plan2.Items[0].PayloadStatus | Should -Be 'Remediated'
            $plan2.Items[0].Entry.LastRemediatedUtc | Should -Be (Get-TestTimestamp)

            $plan3 = Get-TestPlan -Results @($result) -State (New-TestState)
            $plan3.EventType | Should -BeNullOrEmpty
            $plan3.Items[0].Entry.LastRemediatedUtc | Should -Be (Get-TestTimestamp)
        }

        It 'produces no event when nothing changed' {
            $state = New-TestState -Services @{ Spooler = New-TestEntry -Status 'Healthy' }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Healthy')) `
                -State $state -Config $script:Config -Now $script:Now
            $plan.EventType | Should -BeNullOrEmpty
            $plan.NotifiableNames | Should -BeNullOrEmpty
            $plan.Items[0].PayloadStatus | Should -Be 'Healthy'
            Should -Invoke Write-WatchdogEvent -Times 0
        }

        It 'orders event types alert > flapping > recovered > remediated > reminder' -TestCases @(
            @{ Combo = 'alert+recovered'; Expected = 'alert' }
            @{ Combo = 'flapping+recovered'; Expected = 'flapping' }
            @{ Combo = 'recovered+remediated'; Expected = 'recovered' }
            @{ Combo = 'remediated+reminder'; Expected = 'remediated' }
            @{ Combo = 'reminder'; Expected = 'reminder' }
        ) {
            param ($Combo, $Expected)
            $config = New-TestConfig -Overrides @{ Alerting = @{ NotifyOnRemediation = $true } }
            $services = @{}
            $results = @()
            $i = 0
            foreach ($cat in $Combo.Split('+')) {
                $i++
                $name = "Svc$i"
                switch ($cat) {
                    'alert' { $results += New-TestResult -Name $name -Status 'Failed' }
                    'flapping' {
                        $services[$name] = New-TestEntry -Status 'Healthy' -FlapCount 3 `
                            -FlapWindowStartUtc (Get-TestTimestamp -10)
                        $results += New-TestResult -Name $name -Status 'Failed'
                    }
                    'recovered' {
                        $services[$name] = New-TestEntry -Status 'Failed' -FirstFailedUtc (Get-TestTimestamp -20)
                        $results += New-TestResult -Name $name -Status 'Healthy'
                    }
                    'remediated' { $results += New-TestResult -Name $name -Status 'Healthy' -Remediated $true }
                    'reminder' {
                        $services[$name] = New-TestEntry -Status 'Failed' -FirstFailedUtc (Get-TestTimestamp -900) `
                            -LastNotifiedUtc (Get-TestTimestamp -500)
                        $results += New-TestResult -Name $name -Status 'Failed'
                    }
                }
            }
            $plan = Get-TestPlan -Results $results -State (New-TestState -Services $services) -Config $config
            $plan.EventType | Should -Be $Expected
            @($plan.Items | Where-Object { $_.Notify }).Count | Should -Be $results.Count
        }

        It 'marks Notify only on services with a category' {
            $results = @(
                (New-TestResult -Name 'Bad' -Status 'Failed'),
                (New-TestResult -Name 'Fine' -Status 'Healthy')
            )
            $plan = Get-TestPlan -Results $results -State (New-TestState)
            ($plan.Items | Where-Object { $_.Name -eq 'Bad' }).Notify | Should -BeTrue
            ($plan.Items | Where-Object { $_.Name -eq 'Fine' }).Notify | Should -BeFalse
            $plan.NotifiableNames | Should -Be @('Bad')
        }

        It 'replaces alert with flapping on the fourth transition and writes 1007' {
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Healthy' -FlapCount 3 -FlapWindowStartUtc (Get-TestTimestamp -20)
            }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Failed')) `
                -State $state -Config $script:Config -Now $script:Now
            $plan.EventType | Should -Be 'flapping'
            $plan.Items[0].Category | Should -Be 'flapping'
            $plan.Items[0].FlapCount | Should -Be 4
            $plan.Items[0].Entry.FlapSuppressedUntilUtc | Should -Be (Get-TestTimestamp 240)
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1007 } -Times 1 -Exactly
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1002 } -Times 1 -Exactly
        }

        It 'produces no alert or recovered category while a service is suppressed, but still tracks status' {
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Healthy' -FlapSuppressedUntilUtc (Get-TestTimestamp 100)
            }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Failed')) `
                -State $state -Config $script:Config -Now $script:Now
            $plan.EventType | Should -BeNullOrEmpty
            $plan.Items[0].Category | Should -BeNullOrEmpty
            $plan.Items[0].Entry.Status | Should -Be 'Failed'
            $plan.Items[0].PayloadStatus | Should -Be 'Failed'
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1002 } -Times 0

            $state2 = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Failed' -FlapSuppressedUntilUtc (Get-TestTimestamp 100)
            }
            $plan2 = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Healthy')) `
                -State $state2 -Config $script:Config -Now $script:Now
            $plan2.EventType | Should -BeNullOrEmpty
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1005 } -Times 0
        }

        It 'resumes normal notification after a stable suppression interval' {
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Healthy' -FlapCount 0 -FlapSuppressedUntilUtc (Get-TestTimestamp -1)
            }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Failed')) `
                -State $state -Config $script:Config -Now $script:Now
            $plan.EventType | Should -Be 'alert'
            $plan.Items[0].Entry.FlapSuppressedUntilUtc | Should -BeNullOrEmpty
        }

        It 're-sends flapping for a service still unstable when suppression expires' {
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Failed' -FlapCount 3 -FlapSuppressedUntilUtc (Get-TestTimestamp -1)
            }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Failed')) `
                -State $state -Config $script:Config -Now $script:Now
            $plan.EventType | Should -Be 'flapping'
            $plan.Items[0].Entry.FlapSuppressedUntilUtc | Should -Be (Get-TestTimestamp 240)
        }

        It 'carries the current LastError and result details into the new entry' {
            $result = New-TestResult -Name 'Spooler' -Status 'Failed' -LastError 'boom' -Attempts 3
            $plan = Get-TestPlan -Results @($result) -State (New-TestState)
            $plan.Items[0].Entry.LastError | Should -Be 'boom'
            $plan.Items[0].Entry.Keys.Count | Should -Be 8
        }
    }

    Context 'Event identity' {

        It 'generates a new GUID when nothing is pending' {
            $id = Get-WatchdogEventId -State (New-TestState) -EventType 'alert' -ServiceNames @('Spooler')
            [guid]::TryParse($id, [ref]([guid]::Empty)) | Should -BeTrue
        }

        It 'reuses the pending id when the category and service set match regardless of order' {
            $state = New-TestState -Overrides @{
                PendingNotification = $true
                PendingEventId      = '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
                PendingEventType    = 'alert'
                PendingServices     = @('W3SVC', 'Spooler')
            }
            Get-WatchdogEventId -State $state -EventType 'alert' -ServiceNames @('spooler', 'W3SVC') |
                Should -Be '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
        }

        It 'generates a new id when the category or service set differ' {
            $state = New-TestState -Overrides @{
                PendingNotification = $true
                PendingEventId      = '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
                PendingEventType    = 'alert'
                PendingServices     = @('Spooler')
            }
            Get-WatchdogEventId -State $state -EventType 'reminder' -ServiceNames @('Spooler') |
                Should -Not -Be '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
            Get-WatchdogEventId -State $state -EventType 'alert' -ServiceNames @('Spooler', 'W3SVC') |
                Should -Not -Be '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
        }
    }

    Context 'Payload' {

        BeforeAll {
            Mock Write-Log { }
            $script:Config = New-TestConfig
        }

        It 'builds the 4.8 schema with exact keys and order' {
            $item = @{
                Name = 'Spooler'; DisplayName = 'Print Spooler'; PayloadStatus = 'Failed'; StartType = 'Automatic'
                Attempts = 5; FirstFailedUtc = Get-TestTimestamp -15
                LastError = "Cannot start service Spooler on computer '.'"
                FlapCount = 0; Notify = $true
            }
            $payload = New-WatchdogPayload -EventType 'alert' -EventId '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d' `
                -Config $script:Config -Items @($item) -Summary '1 of 1 monitored services are down' `
                -RunId '3f9c7a44-1c2e-4b1a-9e6b-0b2a4c9d8e11' -Now $script:Now
            @($payload.Keys) | Should -Be @(
                'SchemaVersion', 'EventType', 'EventId', 'SiteName', 'HostName', 'Fqdn', 'TimestampUtc',
                'RunId', 'WatchdogVersion', 'Summary', 'Services'
            )
            $payload.SchemaVersion | Should -Be 1
            $payload.EventType | Should -Be 'alert'
            $payload.SiteName | Should -Be 'Example Org'
            $payload.HostName | Should -Be 'SRV-EXAMPLE-01'
            $payload.Fqdn | Should -Be 'srv-example-01.example.com'
            $payload.TimestampUtc | Should -Be '2026-09-04T18:00:00Z'
            $payload.WatchdogVersion | Should -Be '1.0.0'
            @($payload.Services[0].Keys) | Should -Be @(
                'Name', 'DisplayName', 'Status', 'StartType', 'Attempts', 'FirstFailedUtc', 'LastError',
                'FlapCount', 'Notify'
            )
            $payload.Services[0].Attempts | Should -BeOfType [int]
            $payload.Services[0].Notify | Should -BeTrue
        }

        It 'truncates LastError to 1000, Summary to 512 and DisplayName to 256 with a marker' {
            $item = @{
                Name = 'Spooler'; DisplayName = ('d' * 300); PayloadStatus = 'Failed'; StartType = 'Automatic'
                Attempts = 1; FirstFailedUtc = $null; LastError = ('e' * 1500); FlapCount = 0; Notify = $true
            }
            $payload = New-TestPayload -EventType 'alert' -Items @($item) -Summary ('s' * 600)
            $payload.Services[0].LastError.Length | Should -Be 1012
            $payload.Services[0].LastError | Should -Match ' \[truncated\]$'
            $payload.Summary.Length | Should -Be 524
            $payload.Services[0].DisplayName.Length | Should -Be 268
        }

        It 'keeps nullable fields null for a Missing service' {
            $item = @{
                Name = 'Ghost'; DisplayName = $null; PayloadStatus = 'Missing'; StartType = $null
                Attempts = 0; FirstFailedUtc = $null; LastError = $null; FlapCount = 0; Notify = $true
            }
            $payload = New-TestPayload -EventType 'alert' -Items @($item) -Summary 'x'
            $json = $payload | ConvertTo-Json -Depth 10
            $json | Should -Match '"StartType":\s*null'
            $json | Should -Match '"DisplayName":\s*null'
            $payload.Services[0].FlapCount | Should -Be 0
        }

        It 'emits an empty Services array for a test event' {
            $payload = New-TestPayload -EventType 'test' -Items @() -Summary 'Test alert'
            $json = $payload | ConvertTo-Json -Depth 10 -Compress
            $json | Should -Match '"Services":\[\]'
        }

        It 'forces Notify false on every service for a heartbeat' {
            $item = @{
                Name = 'Spooler'; DisplayName = 'Print Spooler'; PayloadStatus = 'Failed'; StartType = 'Automatic'
                Attempts = 0; FirstFailedUtc = $null; LastError = $null; FlapCount = 0; Notify = $true
            }
            $payload = New-TestPayload -EventType 'heartbeat' -Items @($item) -Summary 'hb'
            $payload.Services[0].Notify | Should -BeFalse
        }

        It 'redacts a key that appears in a URL query string' {
            ConvertTo-WatchdogSafeUrl -Url 'https://watchdog.example.com/api/alert?code=abc123&x=1' |
                Should -Be 'https://watchdog.example.com/api/alert?code=***&x=1'
        }
    }

    Context 'Send-WatchdogEvent' {

        BeforeAll {
            Mock Write-WatchdogEvent { }
            $script:Config = New-TestConfig
            $script:LogLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log { $script:LogLines.Add($Message) }
            $script:Payload = New-TestPayload -EventType 'alert' -Items @() -Summary 'x'
        }

        BeforeEach {
            $script:LogLines.Clear()
        }

        It 'posts the JSON as UTF-8 bytes with the required headers and options' {
            Mock Invoke-WebRequest { New-TestResponse -Content '{"accepted":true,"emailSent":true}' }
            Mock ConvertTo-Json { '{"SchemaVersion":1,"Summary":"café"}' }
            $result = Send-WatchdogEvent -Payload $script:Payload -Config $script:Config
            $result.Delivered | Should -BeTrue
            $result.StatusCode | Should -Be 200
            Should -Invoke ConvertTo-Json -ParameterFilter { $Depth -eq 10 } -Times 1 -Exactly
            $expectedJson = '{"SchemaVersion":1,"Summary":"café"}'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $UseBasicParsing -and
                $Method -eq 'Post' -and
                $Uri -eq 'https://watchdog.example.com/api/servicewatchdog/alert' -and
                $Headers['x-functions-key'] -eq 'unit-test-function-key-value' -and
                $Headers['User-Agent'] -eq 'ServiceWatchdog/1.0.0' -and
                $ContentType -eq 'application/json; charset=utf-8' -and
                $Body -is [byte[]] -and
                [System.Text.Encoding]::UTF8.GetString($Body) -eq $expectedJson -and
                $TimeoutSec -eq 30
            }
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1010 } -Times 1 -Exactly
        }

        It 'never writes the function key to the log' {
            Mock Invoke-WebRequest { throw [System.Net.WebException]::new('The operation has timed out') }
            Send-WatchdogEvent -Payload $script:Payload -Config $script:Config | Out-Null
            $script:LogLines.Count | Should -BeGreaterThan 0
            ($script:LogLines -join "`n") | Should -Not -Match 'unit-test-function-key-value'
            ($script:LogLines -join "`n") | Should -Match 'watchdog\.example\.com'
        }

        It 'retries once after 5 seconds on a timeout or network error and writes 1011' {
            Mock Invoke-WebRequest { throw [System.Net.WebException]::new('The operation has timed out') }
            $result = Send-WatchdogEvent -Payload $script:Payload -Config $script:Config
            $result.Delivered | Should -BeFalse
            $result.FailureEventId | Should -Be 1011
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1011 } -Times 1 -Exactly
        }

        It 'does not retry on 401 or 403 and writes 1013' -TestCases @(@{ Code = 401 }, @{ Code = 403 }) {
            param ($Code)
            Mock Invoke-WebRequest { throw (New-TestHttpException -StatusCode $Code) }
            $result = Send-WatchdogEvent -Payload $script:Payload -Config $script:Config
            $result.Delivered | Should -BeFalse
            $result.StatusCode | Should -Be $Code
            $result.FailureEventId | Should -Be 1013
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1013 } -Times 1 -Exactly
        }

        It 'does not retry on 400 and writes 1014' {
            Mock Invoke-WebRequest { throw (New-TestHttpException -StatusCode 400) }
            $result = Send-WatchdogEvent -Payload $script:Payload -Config $script:Config
            $result.FailureEventId | Should -Be 1014
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1014 } -Times 1 -Exactly
        }

        It 'retries once on 503 or 429 and writes 1015' -TestCases @(@{ Code = 503 }, @{ Code = 429 }) {
            param ($Code)
            Mock Invoke-WebRequest { throw (New-TestHttpException -StatusCode $Code) }
            $result = Send-WatchdogEvent -Payload $script:Payload -Config $script:Config
            $result.FailureEventId | Should -Be 1015
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1015 } -Times 1 -Exactly
        }

        It 'succeeds on the retry after a transient failure' {
            $script:Calls = 0
            Mock Invoke-WebRequest {
                $script:Calls++
                if ($script:Calls -eq 1) { throw (New-TestHttpException -StatusCode 502) }
                [pscustomobject]@{ StatusCode = 200; Content = '{"accepted":true}' }
            }
            $result = Send-WatchdogEvent -Payload $script:Payload -Config $script:Config
            $result.Delivered | Should -BeTrue
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }

        It 'writes 1012 for a delivered heartbeat and 1030 for a delivered test' {
            Mock Invoke-WebRequest { New-TestResponse }
            $hb = New-TestPayload -EventType 'heartbeat' -Items @() -Summary 'hb'
            Send-WatchdogEvent -Payload $hb -Config $script:Config | Out-Null
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1012 } -Times 1 -Exactly
            $test = New-TestPayload -EventType 'test' -Items @() -Summary 'test'
            Send-WatchdogEvent -Payload $test -Config $script:Config | Out-Null
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1030 } -Times 1 -Exactly
        }

        It 'does not call Invoke-WebRequest under -DryRun' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
            $script:DryRun = $true
            try {
                $result = Send-WatchdogEvent -Payload $script:Payload -Config $script:Config
                $result.Delivered | Should -BeNullOrEmpty
                Should -Invoke Invoke-WebRequest -Times 0
                ($script:LogLines -join "`n") | Should -Match '\[DRYRUN\]'
            }
            finally {
                $script:DryRun = $false
            }
        }
    }

    Context 'State commit after delivery' {

        BeforeAll {
            Mock Write-Log { }
            Mock Write-WatchdogEvent { }
            $script:Config = New-TestConfig
        }

        It 'stamps LastNotifiedUtc and clears pending on success' {
            $state = New-TestState -Overrides @{
                PendingNotification = $true; PendingEventId = 'old'; PendingEventType = 'alert'
                PendingServices     = @('Spooler')
            }
            $results = @(
                (New-TestResult -Name 'Spooler' -Status 'Failed'),
                (New-TestResult -Name 'W3SVC' -Status 'Healthy')
            )
            $plan = Get-WatchdogNotificationPlan -Results $results -State $state -Config $script:Config -Now $script:Now
            Update-WatchdogState -State $state -Plan $plan -Delivered $true -EventId 'new-id' -Now $script:Now
            $state.Services.Spooler.Status | Should -Be 'Failed'
            $state.Services.Spooler.LastNotifiedUtc | Should -Be (Get-TestTimestamp)
            $state.Services.W3SVC.Status | Should -Be 'Healthy'
            $state.Services.W3SVC.LastNotifiedUtc | Should -BeNullOrEmpty
            $state.PendingNotification | Should -BeFalse
            $state.PendingEventId | Should -BeNullOrEmpty
            $state.PendingEventType | Should -BeNullOrEmpty
            @($state.PendingServices) | Should -HaveCount 0
        }

        It 'preserves previous Status, FirstFailedUtc and LastNotifiedUtc for notifiable services on failure' {
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Healthy' -LastNotifiedUtc (Get-TestTimestamp -1000) -LastError 'old'
                W3SVC   = New-TestEntry -Status 'Healthy'
            }
            $results = @(
                (New-TestResult -Name 'Spooler' -Status 'Failed' -LastError 'new error' -Attempts 3),
                (New-TestResult -Name 'W3SVC' -Status 'Missing')
            )
            $plan = Get-WatchdogNotificationPlan -Results $results -State $state -Config $script:Config -Now $script:Now
            Update-WatchdogState -State $state -Plan $plan -Delivered $false -EventId 'evt-1' -Now $script:Now
            $state.Services.Spooler.Status | Should -Be 'Healthy'
            $state.Services.Spooler.FirstFailedUtc | Should -BeNullOrEmpty
            $state.Services.Spooler.LastNotifiedUtc | Should -Be (Get-TestTimestamp -1000)
            $state.Services.Spooler.LastError | Should -Be 'new error'
            $state.PendingNotification | Should -BeTrue
            $state.PendingEventId | Should -Be 'evt-1'
            $state.PendingEventType | Should -Be 'alert'
            @($state.PendingServices) | Should -HaveCount 2
            @($state.PendingServices) | Should -Contain 'W3SVC'
        }

        It 'restores the flap fields for notifiable services on failure so the transition counts once' {
            $windowStart = Get-TestTimestamp -20
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Healthy' -FlapCount 2 -FlapWindowStartUtc $windowStart
            }
            $results = @((New-TestResult -Name 'Spooler' -Status 'Failed' -LastError 'boom'))
            $plan = Get-WatchdogNotificationPlan -Results $results -State $state -Config $script:Config -Now $script:Now
            $plan.Items[0].Entry.FlapCount | Should -Be 3
            Update-WatchdogState -State $state -Plan $plan -Delivered $false -EventId 'evt-5' -Now $script:Now
            $state.Services.Spooler.Status | Should -Be 'Healthy'
            $state.Services.Spooler.FlapCount | Should -Be 2
            $state.Services.Spooler.FlapWindowStartUtc | Should -Be $windowStart
            $state.Services.Spooler.FlapSuppressedUntilUtc | Should -BeNullOrEmpty
            $state.Services.Spooler.LastError | Should -Be 'boom'
            $state.PendingNotification | Should -BeTrue
        }

        It 'restores a null flap window for a service with no previous entry on failure' {
            $state = New-TestState
            $results = @((New-TestResult -Name 'Spooler' -Status 'Failed'))
            $plan = Get-WatchdogNotificationPlan -Results $results -State $state -Config $script:Config -Now $script:Now
            $plan.Items[0].Entry.FlapCount | Should -Be 1
            Update-WatchdogState -State $state -Plan $plan -Delivered $false -EventId 'evt-6' -Now $script:Now
            $state.Services.Spooler.FlapCount | Should -Be 0
            $state.Services.Spooler.FlapWindowStartUtc | Should -BeNullOrEmpty
            $state.Services.Spooler.FlapSuppressedUntilUtc | Should -BeNullOrEmpty
        }

        It 'does not restore the flap fields when a flap-suppressed service is not notifiable' {
            $until = Get-TestTimestamp 50
            $state = New-TestState -Services @{
                Spooler = New-TestEntry -Status 'Failed' -FlapCount 0 -FlapSuppressedUntilUtc $until
                W3SVC   = New-TestEntry -Status 'Healthy'
            }
            $results = @(
                (New-TestResult -Name 'Spooler' -Status 'Healthy'),
                (New-TestResult -Name 'W3SVC' -Status 'Failed')
            )
            $plan = Get-WatchdogNotificationPlan -Results $results -State $state -Config $script:Config -Now $script:Now
            Update-WatchdogState -State $state -Plan $plan -Delivered $false -EventId 'evt-7' -Now $script:Now
            # Suppressed Spooler commits normally: status and the transition counted during suppression.
            $state.Services.Spooler.Status | Should -Be 'Healthy'
            $state.Services.Spooler.FlapCount | Should -Be 1
            $state.Services.Spooler.FlapSuppressedUntilUtc | Should -Be $until
            @($state.PendingServices) | Should -Be @('W3SVC')
        }

        It 'commits non-notifiable services normally when delivery fails' {
            $fine = New-TestEntry -Status 'Failed' -FlapSuppressedUntilUtc (Get-TestTimestamp 50)
            $state = New-TestState -Services @{ Fine = $fine }
            $results = @((New-TestResult -Name 'Bad' -Status 'Failed'), (New-TestResult -Name 'Fine' -Status 'Healthy'))
            $plan = Get-WatchdogNotificationPlan -Results $results -State $state -Config $script:Config -Now $script:Now
            Update-WatchdogState -State $state -Plan $plan -Delivered $false -EventId 'evt-2' -Now $script:Now
            $state.Services.Fine.Status | Should -Be 'Healthy'
            @($state.PendingServices) | Should -Be @('Bad')
        }

        It 'drops a remediated notification whose delivery failed' {
            $config = New-TestConfig -Overrides @{ Alerting = @{ NotifyOnRemediation = $true } }
            $state = New-TestState
            $results = @((New-TestResult -Name 'Spooler' -Status 'Healthy' -Remediated $true -Attempts 1))
            $plan = Get-WatchdogNotificationPlan -Results $results -State $state -Config $config -Now $script:Now
            $plan.EventType | Should -Be 'remediated'
            Update-WatchdogState -State $state -Plan $plan -Delivered $false -EventId 'evt-3' -Now $script:Now
            $state.PendingNotification | Should -BeFalse
            $state.Services.Spooler.Status | Should -Be 'Healthy'
            $state.Services.Spooler.LastRemediatedUtc | Should -Be (Get-TestTimestamp)
            Should -Invoke Write-Log -ParameterFilter { $Message -like '*remediated*dropped*' }
        }

        It 'excludes remediated services from PendingServices in a mixed failed delivery' {
            $config = New-TestConfig -Overrides @{ Alerting = @{ NotifyOnRemediation = $true } }
            $state = New-TestState
            $results = @(
                (New-TestResult -Name 'Bad' -Status 'Failed'),
                (New-TestResult -Name 'Fixed' -Status 'Healthy' -Remediated $true -Attempts 1)
            )
            $plan = Get-WatchdogNotificationPlan -Results $results -State $state -Config $config -Now $script:Now
            Update-WatchdogState -State $state -Plan $plan -Delivered $false -EventId 'evt-4' -Now $script:Now
            @($state.PendingServices) | Should -Be @('Bad')
            $state.Services.Fixed.Status | Should -Be 'Healthy'
        }

        It 'clears a stale pending marker when nothing needs sending' {
            $state = New-TestState -Overrides @{
                PendingNotification = $true; PendingEventId = 'old'; PendingEventType = 'alert'
                PendingServices     = @('Spooler')
            }
            $plan = Get-WatchdogNotificationPlan -Results @((New-TestResult -Name 'Spooler' -Status 'Healthy')) `
                -State $state -Config $script:Config -Now $script:Now
            Update-WatchdogState -State $state -Plan $plan -Delivered $null -EventId $null -Now $script:Now
            $state.PendingNotification | Should -BeFalse
        }
    }

    Context 'Heartbeat scheduling' {

        BeforeAll {
            $script:Config = New-TestConfig
        }

        It 'is due when there is no LastHeartbeatUtc' {
            Test-WatchdogHeartbeatDue -State (New-TestState) -Config $script:Config -Now $script:Now | Should -BeTrue
        }

        It 'is due when HeartbeatHours have elapsed and not before' {
            $old = New-TestState -Overrides @{ LastHeartbeatUtc = Get-TestTimestamp (-24 * 60) }
            Test-WatchdogHeartbeatDue -State $old -Config $script:Config -Now $script:Now | Should -BeTrue
            $recent = New-TestState -Overrides @{ LastHeartbeatUtc = Get-TestTimestamp (-23 * 60) }
            Test-WatchdogHeartbeatDue -State $recent -Config $script:Config -Now $script:Now | Should -BeFalse
        }
    }

    Context 'Log retention' {

        BeforeAll {
            Mock Write-Log { }
        }

        BeforeEach {
            $script:LogRoot = Join-Path $script:Scratch "logs-$([guid]::NewGuid().ToString('N'))"
            New-Item -Path $script:LogRoot -ItemType Directory -Force | Out-Null
            foreach ($spec in @(
                    @{ Name = 'ServiceWatchdog-20260101.log'; Days = 40 }
                    @{ Name = 'ServiceWatchdog-20260901.log'; Days = 3 }
                    @{ Name = 'Other-20260101.log'; Days = 40 }
                    @{ Name = 'ServiceWatchdog-20260102.txt'; Days = 40 }
                )) {
                $file = Join-Path $script:LogRoot $spec.Name
                Set-Content -LiteralPath $file -Value 'x'
                (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddDays(-$spec.Days)
            }
        }

        It 'deletes only ServiceWatchdog-*.log files older than the retention period' {
            Remove-WatchdogOldLogs -LogRoot $script:LogRoot -RetentionDays 30
            $remaining = (Get-ChildItem -LiteralPath $script:LogRoot).Name | Sort-Object
            $expected = @('Other-20260101.log', 'ServiceWatchdog-20260102.txt', 'ServiceWatchdog-20260901.log')
            $remaining | Should -Be $expected
        }

        It 'only warns when a file cannot be deleted' {
            Mock Remove-Item { throw 'The process cannot access the file because it is being used by another process.' }
            { Remove-WatchdogOldLogs -LogRoot $script:LogRoot -RetentionDays 30 } | Should -Not -Throw
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'WARNING' -and $Message -like '*ServiceWatchdog-20260101.log*'
            }
            Should -Invoke Write-Log -ParameterFilter { $Level -eq 'ERROR' } -Times 0
        }

        It 'does nothing when the log root does not exist' {
            $absent = Join-Path $script:Scratch 'absent'
            { Remove-WatchdogOldLogs -LogRoot $absent -RetentionDays 30 } | Should -Not -Throw
        }

        It 'does not delete under -DryRun' {
            $script:DryRun = $true
            try {
                Remove-WatchdogOldLogs -LogRoot $script:LogRoot -RetentionDays 30
                (Get-ChildItem -LiteralPath $script:LogRoot).Count | Should -Be 4
                Should -Invoke Write-Log -ParameterFilter { $Message -like '*`[DRYRUN`]*20260101*' }
            }
            finally {
                $script:DryRun = $false
            }
        }
    }

    Context 'Event log writer' {

        BeforeAll {
            Mock Write-Log { }
        }

        BeforeEach {
            $script:EventSourceReady = $null
        }

        It 'writes through the .NET seam with the ServiceWatchdog source' {
            Write-WatchdogEvent -EventId 1001 -EntryType 'Information' -Message 'started'
            Should -Invoke Write-WatchdogEventLogEntry -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'ServiceWatchdog' -and $EventId -eq 1001 -and
                $EntryType -eq 'Information' -and $Message -eq 'started'
            }
        }

        It 'does not use the Windows PowerShell-only *-EventLog cmdlets' {
            # New-EventLog and Write-EventLog do not exist on PowerShell 7 (DESIGN.md 4.1).
            $source = Get-Content -LiteralPath $script:WorkerPath -Raw
            $source | Should -Not -Match '(?m)^\s*(New|Write)-EventLog\b'
            $source | Should -Match '\[System\.Diagnostics\.EventLog\]::CreateEventSource\('
            $source | Should -Match '\[System\.Diagnostics\.EventLog\]::WriteEntry\('
        }

        It 'registers the source when missing and elevated' {
            Mock Test-WatchdogEventSource { $false }
            Mock Test-WatchdogElevation { $true }
            Write-WatchdogEvent -EventId 1001 -EntryType 'Information' -Message 'x'
            Should -Invoke Register-WatchdogEventSource -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'ServiceWatchdog' -and $LogName -eq 'Application'
            }
            Should -Invoke Write-WatchdogEventLogEntry -Times 1 -Exactly
        }

        It 'warns and skips when the source is missing and not elevated' {
            Mock Test-WatchdogEventSource { $false }
            Mock Test-WatchdogElevation { $false }
            Write-WatchdogEvent -EventId 1001 -EntryType 'Information' -Message 'x'
            Write-WatchdogEvent -EventId 1002 -EntryType 'Error' -Message 'y'
            Should -Invoke Register-WatchdogEventSource -Times 0
            Should -Invoke Write-WatchdogEventLogEntry -Times 0
            Should -Invoke Write-Log -ParameterFilter { $Level -eq 'WARNING' } -Times 1 -Exactly
        }

        It 'only warns when the event log write throws' {
            Mock Write-WatchdogEventLogEntry { throw 'log full' }
            { Write-WatchdogEvent -EventId 1001 -EntryType 'Information' -Message 'x' } | Should -Not -Throw
            Should -Invoke Write-Log -ParameterFilter { $Level -eq 'WARNING' } -Times 1 -Exactly
        }

        It 'only warns when source registration throws' {
            Mock Test-WatchdogEventSource { $false }
            Mock Test-WatchdogElevation { $true }
            Mock Register-WatchdogEventSource { throw 'access denied' }
            { Write-WatchdogEvent -EventId 1001 -EntryType 'Information' -Message 'x' } | Should -Not -Throw
            Should -Invoke Write-WatchdogEventLogEntry -Times 0
            Should -Invoke Write-Log -ParameterFilter { $Level -eq 'WARNING' } -Times 1 -Exactly
        }

        It 'logs the intended entry and writes nothing under -DryRun' {
            $script:DryRun = $true
            try {
                Write-WatchdogEvent -EventId 1002 -EntryType 'Error' -Message 'x'
                Should -Invoke Write-WatchdogEventLogEntry -Times 0
                Should -Invoke Write-Log -ParameterFilter { $Message -like '*`[DRYRUN`]*1002*' } -Times 1 -Exactly
            }
            finally {
                $script:DryRun = $false
            }
        }
    }

    Context 'Main run' {

        BeforeAll {
            Mock Write-WatchdogEvent { }
            Mock Get-WatchdogRemainingBudget { 240 }
            Mock Start-WatchdogService { }
            Mock Invoke-WebRequest { New-TestResponse }
        }

        BeforeEach {
            $script:StatusMap = @{
                Spooler = New-TestStatus -Name 'Spooler' -DisplayName 'Print Spooler'
                W3SVC   = New-TestStatus -Name 'W3SVC' -DisplayName 'World Wide Web'
            }
            Mock Get-WatchdogServiceStatus {
                $entry = $script:StatusMap[$Name]
                if (-not $entry) { throw "no map entry for $Name" }
                return @{} + $entry
            }
            $script:ConfigFile = New-TestConfigFile
            $script:StateFile = Join-Path (Split-Path -Parent $script:ConfigFile) 'ServiceWatchdog.state.json'
        }

        It 'exits 0 and writes state when every service is healthy' {
            $code = Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath
            $code | Should -Be 0
            Test-Path -LiteralPath $script:StateFile | Should -BeTrue
            $state = Get-WatchdogState -Path $script:StateFile
            $state.Services.Spooler.Status | Should -Be 'Healthy'
            $state.LastRunUtc | Should -Be (Get-TestTimestamp)
            $state.HostName | Should -Be 'SRV-EXAMPLE-01'
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1000 } -Times 0
        }

        It 'writes event 1000 for a healthy run when EventLogHealthyRuns is on' {
            $cfg = New-TestConfigFile -Overrides @{ Logging = @{ EventLogHealthyRuns = $true } }
            Invoke-WatchdogMain -ConfigPath $cfg -LogPath $script:LogPath | Should -Be 0
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1000 } -Times 1 -Exactly
        }

        It 'sends the heartbeat when due and stamps LastHeartbeatUtc after success' {
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                ([System.Text.Encoding]::UTF8.GetString($Body)) -match '"EventType":\s*"heartbeat"'
            }
            (Get-WatchdogState -Path $script:StateFile).LastHeartbeatUtc | Should -Be (Get-TestTimestamp)
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1012 } -Times 1 -Exactly
        }

        It 'skips the heartbeat when not due and forces it with -SendHeartbeat' {
            $seed = New-TestState -Overrides @{ LastHeartbeatUtc = Get-TestTimestamp -60 }
            Save-WatchdogState -Path $script:StateFile -State $seed
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath -SendHeartbeat | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            (Get-WatchdogState -Path $script:StateFile).LastHeartbeatUtc | Should -Be (Get-TestTimestamp)
        }

        It 'leaves LastHeartbeatUtc unchanged and exits 10 when the heartbeat fails' {
            Mock Invoke-WebRequest { throw (New-TestHttpException -StatusCode 503) }
            $seed = New-TestState -Overrides @{ LastHeartbeatUtc = Get-TestTimestamp -3000 }
            Save-WatchdogState -Path $script:StateFile -State $seed
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 10
            (Get-WatchdogState -Path $script:StateFile).LastHeartbeatUtc | Should -Be (Get-TestTimestamp -3000)
        }

        It 'exits 50 when a service stays failed and posts an alert' {
            $script:StatusMap.Spooler.Status = 'Stopped'
            Mock Get-CimInstance { }
            $code = Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath
            $code | Should -Be 50
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                ([System.Text.Encoding]::UTF8.GetString($Body)) -match '"EventType":\s*"alert"'
            }
            $state = Get-WatchdogState -Path $script:StateFile
            $state.Services.Spooler.Status | Should -Be 'Failed'
            $state.Services.Spooler.FirstFailedUtc | Should -Be (Get-TestTimestamp)
        }

        It 'posts the alert before the heartbeat when both are due' {
            $script:StatusMap.Spooler.Status = 'Stopped'
            $script:Order = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest {
                $json = [System.Text.Encoding]::UTF8.GetString($Body)
                $script:Order.Add(([regex]::Match($json, '"EventType":\s*"(\w+)"').Groups[1].Value))
                [pscustomobject]@{ StatusCode = 200; Content = '{"accepted":true}' }
            }
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 50
            $script:Order | Should -Be @('alert', 'heartbeat')
        }

        It 'exits 0 when a stopped service is remediated this run' {
            $script:StatusMap.Spooler.Status = 'Stopped'
            Mock Start-WatchdogService { $script:StatusMap.Spooler.Status = 'Running' }
            $code = Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath
            $code | Should -Be 0
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1001 } -Times 1 -Exactly
            $state = Get-WatchdogState -Path $script:StateFile
            $state.Services.Spooler.LastRemediatedUtc | Should -Be (Get-TestTimestamp)
        }

        It 'exits 10 when the notification is pending and no service is failed' {
            Save-WatchdogState -Path $script:StateFile -State (New-TestState -Services @{
                    Spooler = New-TestEntry -Status 'Failed' -FirstFailedUtc (Get-TestTimestamp -30)
                } -Overrides @{ LastHeartbeatUtc = Get-TestTimestamp -10 })
            Mock Invoke-WebRequest { throw [System.Net.WebException]::new('timeout') }
            $code = Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath
            $code | Should -Be 10
            $state = Get-WatchdogState -Path $script:StateFile
            $state.PendingNotification | Should -BeTrue
            $state.PendingEventType | Should -Be 'recovered'
            $state.Services.Spooler.Status | Should -Be 'Failed'
        }

        It 'reuses the pending EventId on the retry run' {
            Save-WatchdogState -Path $script:StateFile -State (New-TestState -Services @{
                    Spooler = New-TestEntry -Status 'Failed' -FirstFailedUtc (Get-TestTimestamp -30)
                } -Overrides @{ LastHeartbeatUtc = Get-TestTimestamp -10 })
            Mock Invoke-WebRequest { throw [System.Net.WebException]::new('timeout') }
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 10
            $pendingId = (Get-WatchdogState -Path $script:StateFile).PendingEventId
            $script:SentIds = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest {
                $json = [System.Text.Encoding]::UTF8.GetString($Body)
                $script:SentIds.Add(([regex]::Match($json, '"EventId":\s*"([^"]+)"').Groups[1].Value))
                [pscustomobject]@{ StatusCode = 200; Content = '{"accepted":true}' }
            }
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 0
            $script:SentIds | Should -Be @($pendingId)
            $state = Get-WatchdogState -Path $script:StateFile
            $state.PendingNotification | Should -BeFalse
            $state.Services.Spooler.Status | Should -Be 'Healthy'
        }

        It 'does not turn one outage into flapping across four failed deliveries and re-sends it as an alert' {
            # Reviewer scenario: Healthy -> Failed once, webhook down for four consecutive runs,
            # back on the fifth. The transition must count toward the flap threshold exactly
            # once, and the fifth run must POST 'alert' with the EventId chosen on run 1.
            $script:StatusMap.Spooler.Status = 'Stopped'
            Mock Get-CimInstance { }
            Mock Invoke-WebRequest { throw [System.Net.WebException]::new('timeout') }
            # Recent heartbeat so only the alert is POSTed on each run.
            Save-WatchdogState -Path $script:StateFile -State (New-TestState -Overrides @{
                    LastHeartbeatUtc = Get-TestTimestamp -10
                })
            Mock Get-WatchdogUtcNow { $script:Now.AddMinutes($script:RunOffsetMinutes) }
            $pendingId = $null
            for ($run = 1; $run -le 4; $run++) {
                $script:RunOffsetMinutes = 5 * $run
                Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 50
                $state = Get-WatchdogState -Path $script:StateFile
                $state.PendingNotification | Should -BeTrue
                $state.PendingEventType | Should -Be 'alert'
                if ($run -eq 1) { $pendingId = $state.PendingEventId }
                $state.PendingEventId | Should -Be $pendingId
                $state.Services.Spooler.Status | Should -Be 'Healthy'
                $state.Services.Spooler.FlapCount | Should -Be 0
                $state.Services.Spooler.FlapSuppressedUntilUtc | Should -BeNullOrEmpty
            }
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1007 } -Times 0
            Should -Invoke Invoke-WebRequest -Times 8 -Exactly

            $script:SentEvents = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest {
                $json = [System.Text.Encoding]::UTF8.GetString($Body)
                $type = [regex]::Match($json, '"EventType":\s*"(\w+)"').Groups[1].Value
                $id = [regex]::Match($json, '"EventId":\s*"([^"]+)"').Groups[1].Value
                $script:SentEvents.Add("$type|$id")
                [pscustomobject]@{ StatusCode = 200; Content = '{"accepted":true}' }
            }
            $script:RunOffsetMinutes = 25
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 50
            $script:SentEvents | Should -Be @("alert|$pendingId")
            $state = Get-WatchdogState -Path $script:StateFile
            $state.PendingNotification | Should -BeFalse
            $state.Services.Spooler.Status | Should -Be 'Failed'
            $state.Services.Spooler.FlapCount | Should -Be 1
            $state.Services.Spooler.FlapSuppressedUntilUtc | Should -BeNullOrEmpty
            $state.Services.Spooler.LastNotifiedUtc | Should -Be (Get-TestTimestamp 25)
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1007 } -Times 0
        }

        It 'lets 50 win over 10 and logs both conditions' {
            $script:LogLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log { $script:LogLines.Add("[$Level] $Message") }
            $script:StatusMap.Spooler.Status = 'Stopped'
            Mock Invoke-WebRequest { throw [System.Net.WebException]::new('timeout') }
            $code = Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath
            $code | Should -Be 50
            ($script:LogLines -join "`n") | Should -Match 'pending'
            ($script:LogLines -join "`n") | Should -Match 'Spooler'
        }

        It 'exits 2 and writes 1020 when the config is invalid' {
            $bad = New-TestConfigFile -Overrides @{ MaxStartAttempts = 99 }
            Invoke-WatchdogMain -ConfigPath $bad -LogPath $script:LogPath | Should -Be 2
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1020 } -Times 1 -Exactly
            Should -Invoke Get-WatchdogServiceStatus -Times 0
        }

        It 'exits 2 when the config file is missing' {
            $absent = Join-Path $script:Scratch 'absent.json'
            Invoke-WatchdogMain -ConfigPath $absent -LogPath $script:LogPath | Should -Be 2
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1020 } -Times 1 -Exactly
        }

        It 'exits 1 and writes 1099 on an unexpected error' {
            Mock Get-WatchdogState { throw 'disk on fire' }
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath | Should -Be 1
            Should -Invoke Write-WatchdogEvent -Times 1 -Exactly -ParameterFilter {
                $EventId -eq 1099 -and $Message -like '*disk on fire*'
            }
        }

        It 'uses the -ServiceName override for the run, logs it and prunes state accordingly' {
            $script:LogLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log { $script:LogLines.Add($Message) }
            $script:StatusMap['Custom'] = New-TestStatus -Name 'Custom' -DisplayName 'Custom' -StartType 'Manual'
            $seed = New-TestState -Services @{ W3SVC = New-TestEntry -Status 'Failed' }
            Save-WatchdogState -Path $script:StateFile -State $seed
            $code = Invoke-WatchdogMain -ConfigPath $script:ConfigFile -LogPath $script:LogPath -ServiceName 'Custom'
            $code | Should -Be 0
            Should -Invoke Get-WatchdogServiceStatus -Times 1 -Exactly -ParameterFilter { $Name -eq 'Custom' }
            Should -Invoke Get-WatchdogServiceStatus -Times 0 -ParameterFilter { $Name -eq 'Spooler' }
            ($script:LogLines -join "`n") | Should -Match 'override'
            Should -Invoke Write-WatchdogEvent -Times 1 -Exactly -ParameterFilter {
                $EventId -eq 1006 -and $Message -like '*W3SVC*'
            }
            $state = Get-WatchdogState -Path $script:StateFile
            @($state.Services.Keys) | Should -Be @('Custom')
        }

        It 'switches to the configured LogRoot and names the daily file' {
            $logRoot = Join-Path $script:Scratch "root-$([guid]::NewGuid().ToString('N'))"
            $cfg = New-TestConfigFile -Overrides @{ Logging = @{ LogRoot = $logRoot } }
            Invoke-WatchdogMain -ConfigPath $cfg | Should -Be 0
            $expected = Join-Path $logRoot ("ServiceWatchdog-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
            Test-Path -LiteralPath $expected | Should -BeTrue
        }
    }

    Context 'ValidateConfig mode' {

        BeforeAll {
            Mock Write-WatchdogEvent { }
            Mock Get-WatchdogServiceStatus { throw 'must not check services' }
            Mock Invoke-WebRequest { throw 'must not call the webhook' }
        }

        It 'exits 0 for a valid config, prints a summary and touches nothing' {
            $cfg = New-TestConfigFile
            $stateFile = Join-Path (Split-Path -Parent $cfg) 'ServiceWatchdog.state.json'
            Invoke-WatchdogMain -ConfigPath $cfg -ValidateConfig -LogPath $script:LogPath | Should -Be 0
            Should -Invoke Write-Host -ParameterFilter { $Object -like '*Spooler*' }
            Should -Invoke Get-WatchdogServiceStatus -Times 0
            Should -Invoke Invoke-WebRequest -Times 0
            Test-Path -LiteralPath $stateFile | Should -BeFalse
        }

        It 'exits 2 for an invalid config listing every violation' {
            $script:LogLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log { $script:LogLines.Add("[$Level] $Message") }
            $cfg = New-TestConfigFile -Overrides @{ MaxStartAttempts = 0; SiteName = '' }
            Invoke-WatchdogMain -ConfigPath $cfg -ValidateConfig -LogPath $script:LogPath | Should -Be 2
            ($script:LogLines -join "`n") | Should -Match 'MaxStartAttempts'
            ($script:LogLines -join "`n") | Should -Match 'SiteName'
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1020 } -Times 1 -Exactly
        }
    }

    Context 'TestAlert mode' {

        BeforeAll {
            Mock Write-WatchdogEvent { }
            Mock Get-WatchdogServiceStatus { throw 'must not check services' }
        }

        BeforeEach {
            $script:ConfigFile = New-TestConfigFile
            $script:StateFile = Join-Path (Split-Path -Parent $script:ConfigFile) 'ServiceWatchdog.state.json'
        }

        It 'posts a test event with empty Services and exits 0 on 200' {
            Mock Invoke-WebRequest { New-TestResponse -Content '{"accepted":true,"emailSent":true}' }
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -TestAlert -LogPath $script:LogPath | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $json = [System.Text.Encoding]::UTF8.GetString($Body)
                $json -match '"EventType":\s*"test"' -and $json -match '"Services":\s*\[\s*\]'
            }
            Should -Invoke Get-WatchdogServiceStatus -Times 0
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1030 } -Times 1 -Exactly
            Test-Path -LiteralPath $script:StateFile | Should -BeFalse
        }

        It 'exits 10 when the test delivery fails' {
            Mock Invoke-WebRequest { throw (New-TestHttpException -StatusCode 401) }
            Invoke-WatchdogMain -ConfigPath $script:ConfigFile -TestAlert -LogPath $script:LogPath | Should -Be 10
            Should -Invoke Write-WatchdogEvent -ParameterFilter { $EventId -eq 1013 } -Times 1 -Exactly
            Test-Path -LiteralPath $script:StateFile | Should -BeFalse
        }

        It 'exits 2 when the config is invalid' {
            $bad = New-TestConfigFile -Overrides @{ Webhook = @{ FunctionKey = 'REPLACE_WITH_FUNCTION_KEY' } }
            Invoke-WatchdogMain -ConfigPath $bad -TestAlert -LogPath $script:LogPath | Should -Be 2
        }
    }

    Context 'DryRun mode' {

        BeforeAll {
            Mock Get-WatchdogRemainingBudget { 240 }
            Mock Start-WatchdogService { }
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
            Mock Move-Item { }
            Mock Get-WatchdogServiceStatus {
                New-TestStatus -Name $Name -DisplayName $Name -Status 'Stopped'
            }
            $script:LogLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Log { $script:LogLines.Add($Message) }
        }

        It 'runs every check but performs zero mutations' {
            $cfg = New-TestConfigFile -Overrides @{ Logging = @{ EventLogHealthyRuns = $true } }
            $stateFile = Join-Path (Split-Path -Parent $cfg) 'ServiceWatchdog.state.json'
            $code = Invoke-WatchdogMain -ConfigPath $cfg -DryRun -LogPath $script:LogPath
            $code | Should -Be 50
            Should -Invoke Get-WatchdogServiceStatus -Times 2 -Exactly
            Should -Invoke Start-WatchdogService -Times 0
            Should -Invoke Invoke-WebRequest -Times 0
            Should -Invoke Write-WatchdogEventLogEntry -Times 0
            Should -Invoke Register-WatchdogEventSource -Times 0
            Should -Invoke Move-Item -Times 0
            Test-Path -LiteralPath $stateFile | Should -BeFalse
            $dry = $script:LogLines | Where-Object { $_ -like '*[DRYRUN]*' }
            ($dry -join "`n") | Should -Match 'start'
            ($dry -join "`n") | Should -Match 'POST'
            ($dry -join "`n") | Should -Match 'state'
            ($dry -join "`n") | Should -Match 'event'
        }

        It 'does not POST a test alert under -DryRun' {
            $cfg = New-TestConfigFile
            Invoke-WatchdogMain -ConfigPath $cfg -DryRun -TestAlert -LogPath $script:LogPath | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    Context 'Script guard' {

        It 'ends with the dot-source guard and defines the main function' {
            $content = Get-Content -LiteralPath $script:WorkerPath -Raw
            $guard = "if \(\`$MyInvocation\.InvocationName -ne '\.'\) \{\s*exit \(Invoke-WatchdogMain\)\s*\}"
            $content | Should -Match $guard
            Get-Command Invoke-WatchdogMain | Should -Not -BeNullOrEmpty
        }
    }
}
