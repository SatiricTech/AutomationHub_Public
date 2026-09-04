<#
.SYNOPSIS
    Contract tests between the endpoint worker's payload builder and the Azure Function's
    payload validator.

.DESCRIPTION
    DESIGN.md section 9 requires that the worker's payload for every event type passes the
    function module's Test-WatchdogPayload with zero errors. These tests drive the worker's
    real code paths (Invoke-WatchdogServiceCheck, Invoke-WatchdogStartRounds,
    Get-WatchdogNotificationPlan, Get-WatchdogEventId, Get-WatchdogSummary,
    New-WatchdogPayload and Send-WatchdogEvent) against a fake service catalog, capture the
    UTF-8 bytes the worker hands to Invoke-WebRequest, deserialize them the way the
    Functions host does (ConvertFrom-Json -AsHashtable), and pass the result to the
    module's Test-WatchdogPayload.

    The second group asserts that the worker's truncation limits (DESIGN.md 4.8) and the
    module's payload limits (DESIGN.md 6.3) agree, so a truncated value can never be
    rejected by the function.

    Windows-only cmdlets do not exist on macOS/Linux, so stub functions with the same
    parameter surface are declared before the dot-source and then mocked. No test touches a
    real service, the event log, the filesystem outside a scratch folder, or the network.
#>

BeforeAll {
    $script:WorkerPath = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '../Endpoint/Invoke-WinServiceWatchdog.ps1'))
    $script:ModulePath = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '../AzureFunction/Modules/ServiceWatchdogAlert/ServiceWatchdogAlert.psd1'))

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
    Import-Module $script:ModulePath -Force

    $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) "ServiceWatchdogContract-$([guid]::NewGuid())"
    New-Item -Path $script:Scratch -ItemType Directory -Force | Out-Null
    $script:LogPath = Join-Path $script:Scratch 'ServiceWatchdogContract.log'
    $script:Verbosity = 'Low'
    $script:DryRun = $false
    $script:Now = [datetime]::new(2026, 9, 4, 18, 0, 0, [System.DateTimeKind]::Utc)
    $script:HostName = 'SRV-EXAMPLE-01'
    $script:TruncationPattern = ' \[truncated\]$'

    # The module's 6.3 limits, read from its private scope so the tests follow the code.
    $script:ModuleLimits = & (Get-Module -Name 'ServiceWatchdogAlert') {
        @{
            String    = $script:MaxStringLength
            Summary   = $script:MaxSummaryLength
            LastError = $script:MaxLastErrorLength
            Services  = $script:MaxServices
        }
    }

    # Fake service catalog consulted by the Get-Service, Get-CimInstance and
    # Start-WatchdogService mocks. Each entry: Installed, DisplayName, Status, StartMode,
    # Delayed and StartOutcome ('Running' = the start works, 'Throw' = the SCM refuses,
    # 'Stopped' = the start request is accepted but the service never reaches Running).
    $script:Catalog = @{}
    $script:CapturedBody = $null

    function Get-ContractTimestamp {
        param ([int]$MinutesFromNow = 0)
        return $script:Now.AddMinutes($MinutesFromNow).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    function Get-ContractCatalogEntry {
        param ([string]$Name)
        if (-not $script:Catalog.ContainsKey($Name)) {
            throw "Cannot find any service with service name '$Name'."
        }
        $entry = $script:Catalog[$Name]
        if (-not $entry.Installed) {
            throw "Cannot find any service with service name '$Name'."
        }
        return $entry
    }

    function New-ContractCatalogEntry {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory hashtable.'
        )]
        param (
            [string]$DisplayName = 'Example Service',
            [string]$Status = 'Running',
            [string]$StartMode = 'Auto',
            [bool]$Delayed = $false,
            [bool]$Installed = $true,
            [string]$StartOutcome = 'Throw',
            [string]$StartError = "Cannot start service on computer '.'"
        )
        return @{
            DisplayName  = $DisplayName
            Status       = $Status
            StartMode    = $StartMode
            Delayed      = $Delayed
            Installed    = $Installed
            StartOutcome = $StartOutcome
            StartError   = $StartError
        }
    }

    function New-ContractConfig {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder; validates a config through the worker''s own validator.'
        )]
        param (
            [string[]]$Services,
            [hashtable]$Alerting = @{}
        )
        $raw = @{
            SchemaVersion           = 1
            SiteName                = 'Example Org'
            Services                = $Services
            MaxStartAttempts        = 3
            RetryDelaySeconds       = 0
            PostStartVerifySeconds  = 1
            StartPendingWaitSeconds = 1
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
        foreach ($key in $Alerting.Keys) {
            $raw.Alerting[$key] = $Alerting[$key]
        }
        $validation = Test-WatchdogConfig -Config $raw
        if (-not $validation.IsValid) {
            throw "Contract test config is invalid: $($validation.Errors -join '; ')"
        }
        return $validation.Config
    }

    function New-ContractState {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory hashtable.'
        )]
        param ([hashtable]$Services = @{}, [hashtable]$Overrides = @{})
        $state = New-WatchdogEmptyState
        $state.HostName = $script:HostName
        foreach ($name in $Services.Keys) {
            $entry = @{
                Status                 = 'Healthy'
                FirstFailedUtc         = $null
                LastNotifiedUtc        = $null
                LastRemediatedUtc      = $null
                LastError              = $null
                FlapCount              = 0
                FlapWindowStartUtc     = $null
                FlapSuppressedUntilUtc = $null
            }
            foreach ($key in $Services[$name].Keys) {
                $entry[$key] = $Services[$name][$key]
            }
            $state.Services[$name] = $entry
        }
        foreach ($key in $Overrides.Keys) {
            $state[$key] = $Overrides[$key]
        }
        return $state
    }

    function Invoke-ContractRun {
        # Runs the worker's real service checks, start rounds and notification plan against
        # the fake catalog, exactly as Invoke-WatchdogMain sequences them.
        param (
            [Parameter(Mandatory)]
            [hashtable]$Catalog,

            [Parameter(Mandatory)]
            [hashtable]$Config,

            [hashtable]$State = (New-ContractState)
        )
        $script:Catalog = $Catalog
        $script:MaxRunSeconds = $Config.MaxRunSeconds
        $script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($name in $Config.Services) {
            $results.Add((Invoke-WatchdogServiceCheck -Name $name -Config $Config))
        }
        Invoke-WatchdogStartRounds -Results @($results.ToArray()) -Config $Config
        $script:RunStopwatch.Stop()
        return Get-WatchdogNotificationPlan -Results @($results.ToArray()) -State $State -Config $Config -Now $script:Now
    }

    function Invoke-ContractDelivery {
        # Builds the payload the way Invoke-WatchdogMain does for the given event type, sends
        # it through Send-WatchdogEvent (Invoke-WebRequest mocked), and returns the request
        # body deserialized the way the Functions host hands it to run.ps1.
        param (
            [Parameter(Mandatory)]
            [string]$EventType,

            [Parameter(Mandatory)]
            [hashtable]$Config,

            [object[]]$Items = @(),

            [hashtable]$State = (New-ContractState),

            [string]$Summary,

            [object]$Plan
        )
        $eventId = [guid]::NewGuid().ToString()
        if ($Plan -and $Plan.EventType) {
            # Mirrors Invoke-WatchdogMain: @() keeps a remediated-only run's empty pending
            # list as an empty array instead of $null.
            $pendingNames = @(Get-WatchdogPendingServiceList -Plan $Plan)
            $eventId = Get-WatchdogEventId -State $State -EventType $Plan.EventType -ServiceNames $pendingNames
        }
        if (-not $Summary) {
            $Summary = Get-WatchdogSummary -EventType $EventType -Items $Items -HostName $script:HostName
        }
        $payload = New-WatchdogPayload -EventType $EventType -EventId $eventId -Config $Config -Items $Items `
            -Summary $Summary -RunId ([guid]::NewGuid().ToString()) -Now $script:Now

        $script:CapturedBody = $null
        $delivery = Send-WatchdogEvent -Payload $payload -Config $Config
        if ($delivery.Delivered -ne $true) {
            throw "Send-WatchdogEvent did not deliver: $($delivery.Message)"
        }
        if ($script:CapturedBody -isnot [byte[]]) {
            throw 'Send-WatchdogEvent did not hand Invoke-WebRequest a byte[] body.'
        }
        $json = [System.Text.Encoding]::UTF8.GetString($script:CapturedBody)
        return ConvertFrom-Json -InputObject $json -AsHashtable
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module -Name 'ServiceWatchdogAlert' -Force -ErrorAction SilentlyContinue
}

Describe 'ServiceWatchdog payload contract' {

    BeforeAll {
        Mock Write-Log { }
        Mock Write-WatchdogEvent { }
        Mock Start-Sleep { }
        Mock Get-WatchdogHostIdentity { @{ HostName = $script:HostName; Fqdn = 'srv-example-01.example.com' } }
        Mock Get-Service {
            $key = if ($Name) { $Name } else { $DisplayName }
            $entry = Get-ContractCatalogEntry -Name $key
            return [pscustomobject]@{ Name = $key; DisplayName = $entry.DisplayName; Status = $entry.Status }
        }
        Mock Get-CimInstance {
            if ($Filter -notmatch "^Name='(.+)'$") {
                throw "Unexpected CIM filter '$Filter'"
            }
            $entry = Get-ContractCatalogEntry -Name ($Matches[1].Replace("\'", "'").Replace('\\', '\'))
            return [pscustomobject]@{ StartMode = $entry.StartMode; DelayedAutoStart = $entry.Delayed }
        }
        Mock Start-WatchdogService {
            $entry = Get-ContractCatalogEntry -Name $Name
            switch ($entry.StartOutcome) {
                'Running' { $entry.Status = 'Running' }
                'Throw' { throw $entry.StartError }
                default { }
            }
        }
        Mock Invoke-WebRequest {
            $script:CapturedBody = $Body
            return [pscustomobject]@{
                StatusCode = 200
                Content    = '{"accepted":true,"emailSent":true,"duplicate":false,"providerMessageId":null}'
            }
        }
    }

    Context 'Every event type passes Test-WatchdogPayload' {

        It 'alert: Failed after retries, Missing and Disabled alongside a healthy service' {
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName 'Print Spooler' -Status 'Stopped' `
                    -StartOutcome 'Throw' -StartError "Cannot start service Spooler on computer '.'"
                Ghost   = New-ContractCatalogEntry -Installed $false
                Legacy  = New-ContractCatalogEntry -DisplayName 'Legacy Agent' -Status 'Stopped' -StartMode 'Disabled'
                W3SVC   = New-ContractCatalogEntry -DisplayName 'World Wide Web Publishing Service' `
                    -StartMode 'Auto' -Delayed $true
            }
            $config = New-ContractConfig -Services @('Spooler', 'Ghost', 'Legacy', 'W3SVC')
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config
            $plan.EventType | Should -Be 'alert'

            $body = Invoke-ContractDelivery -EventType $plan.EventType -Config $config -Items $plan.Items -Plan $plan
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.EventType | Should -Be 'alert'
            $body.HostName | Should -Be 'SRV-EXAMPLE-01'
            $body.Summary | Should -Be '3 of 4 monitored services are down'
            $body.Services.Count | Should -Be 4
            $spooler = $body.Services | Where-Object { $_.Name -eq 'Spooler' }
            $spooler.Status | Should -Be 'Failed'
            $spooler.Attempts | Should -Be 3
            $spooler.LastError | Should -Be "Cannot start service Spooler on computer '.'"
            $spooler.StartType | Should -Be 'Automatic'
            $spooler.Notify | Should -BeTrue
            $ghost = $body.Services | Where-Object { $_.Name -eq 'Ghost' }
            $ghost.Status | Should -Be 'Missing'
            $ghost.StartType | Should -BeNullOrEmpty
            $ghost.DisplayName | Should -BeNullOrEmpty
            ($body.Services | Where-Object { $_.Name -eq 'Legacy' }).Status | Should -Be 'Disabled'
            $web = $body.Services | Where-Object { $_.Name -eq 'W3SVC' }
            $web.Status | Should -Be 'Healthy'
            $web.StartType | Should -Be 'AutomaticDelayedStart'
            $web.Notify | Should -BeFalse
        }

        It 'alert: a retried delivery reuses the pending EventId and still validates' {
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName 'Print Spooler' -Status 'Stopped' -StartOutcome 'Throw'
            }
            $config = New-ContractConfig -Services @('Spooler')
            $pendingId = '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
            $state = New-ContractState -Overrides @{
                PendingNotification = $true
                PendingEventId      = $pendingId
                PendingEventType    = 'alert'
                PendingServices     = @('Spooler')
            }
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config -State $state
            $plan.EventType | Should -Be 'alert'

            $body = Invoke-ContractDelivery -EventType $plan.EventType -Config $config -Items $plan.Items `
                -State $state -Plan $plan
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.EventId | Should -Be $pendingId
        }

        It 'flapping: the fourth transition inside the window' {
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName 'Print Spooler' -Status 'Stopped' -StartOutcome 'Throw'
            }
            $config = New-ContractConfig -Services @('Spooler')
            $state = New-ContractState -Services @{
                Spooler = @{ Status = 'Healthy'; FlapCount = 3; FlapWindowStartUtc = (Get-ContractTimestamp -20) }
            }
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config -State $state
            $plan.EventType | Should -Be 'flapping'

            $body = Invoke-ContractDelivery -EventType $plan.EventType -Config $config -Items $plan.Items `
                -State $state -Plan $plan
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.EventType | Should -Be 'flapping'
            $body.Summary | Should -Be 'Flapping: Spooler (1 of 1 monitored services down)'
            $body.Services[0].FlapCount | Should -Be 4
            $body.Services[0].Status | Should -Be 'Failed'
            $body.Services[0].Notify | Should -BeTrue
        }

        It 'reminder: the same problem past ReminderMinutes' {
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName 'Print Spooler' -Status 'Stopped' -StartOutcome 'Throw'
            }
            $config = New-ContractConfig -Services @('Spooler')
            $state = New-ContractState -Services @{
                Spooler = @{
                    Status          = 'Failed'
                    FirstFailedUtc  = (Get-ContractTimestamp -600)
                    LastNotifiedUtc = (Get-ContractTimestamp -300)
                }
            }
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config -State $state
            $plan.EventType | Should -Be 'reminder'

            $body = Invoke-ContractDelivery -EventType $plan.EventType -Config $config -Items $plan.Items `
                -State $state -Plan $plan
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.EventType | Should -Be 'reminder'
            $body.Summary | Should -Be 'Reminder: 1 of 1 monitored services are still down'
            $body.Services[0].FirstFailedUtc | Should -Not -BeNullOrEmpty
        }

        It 'recovered: a previously failed service is Running again without our action' {
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName 'Print Spooler' -Status 'Running'
            }
            $config = New-ContractConfig -Services @('Spooler')
            $state = New-ContractState -Services @{
                Spooler = @{ Status = 'Failed'; FirstFailedUtc = (Get-ContractTimestamp -30) }
            }
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config -State $state
            $plan.EventType | Should -Be 'recovered'

            $body = Invoke-ContractDelivery -EventType $plan.EventType -Config $config -Items $plan.Items `
                -State $state -Plan $plan
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.EventType | Should -Be 'recovered'
            $body.Services[0].Status | Should -Be 'Recovered'
            $body.Services[0].FirstFailedUtc | Should -BeNullOrEmpty
            $body.Services[0].Notify | Should -BeTrue
        }

        It 'remediated: our start succeeded and NotifyOnRemediation is on' {
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName 'Print Spooler' -Status 'Stopped' -StartOutcome 'Running'
            }
            $config = New-ContractConfig -Services @('Spooler') -Alerting @{ NotifyOnRemediation = $true }
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config
            $plan.EventType | Should -Be 'remediated'

            $body = Invoke-ContractDelivery -EventType $plan.EventType -Config $config -Items $plan.Items -Plan $plan
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.EventType | Should -Be 'remediated'
            $body.Services[0].Status | Should -Be 'Remediated'
            $body.Services[0].Attempts | Should -Be 1
            $body.Services[0].LastError | Should -BeNullOrEmpty
        }

        It 'test: an empty service list and a summary line' {
            $config = New-ContractConfig -Services @('Spooler')
            $body = Invoke-ContractDelivery -EventType 'test' -Config $config -Items @()
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.EventType | Should -Be 'test'
            $body.Summary | Should -Be 'Test alert from SRV-EXAMPLE-01'
            $body.Services.Count | Should -Be 0
        }

        It 'heartbeat: the full service list with Notify false everywhere' {
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName 'Print Spooler' -Status 'Stopped' -StartOutcome 'Throw'
                W3SVC   = New-ContractCatalogEntry -DisplayName 'World Wide Web Publishing Service'
            }
            $config = New-ContractConfig -Services @('Spooler', 'W3SVC')
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config
            $plan.EventType | Should -Be 'alert'

            $body = Invoke-ContractDelivery -EventType 'heartbeat' -Config $config -Items $plan.Items
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.EventType | Should -Be 'heartbeat'
            $body.Summary | Should -Be 'Heartbeat: 2 monitored services, 1 with problems'
            $body.Services.Count | Should -Be 2
            @($body.Services | Where-Object { $_.Notify }).Count | Should -Be 0
        }

        It 'control: the validator still rejects an unknown top-level key' {
            $config = New-ContractConfig -Services @('Spooler')
            $body = Invoke-ContractDelivery -EventType 'test' -Config $config -Items @()
            $body['Extra'] = 1
            @(Test-WatchdogPayload -Payload $body) -join ' ' | Should -BeLike "*Unknown top-level key 'Extra'*"
        }
    }

    Context 'Endpoint truncation limits agree with the function limits' {

        It 'a truncated LastError, DisplayName and Summary still pass validation' {
            $longError = 'e' * ($script:ModuleLimits.LastError + 500)
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName ('d' * ($script:ModuleLimits.String + 100)) `
                    -Status 'Stopped' -StartOutcome 'Throw' -StartError $longError
            }
            $config = New-ContractConfig -Services @('Spooler')
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config
            $plan.EventType | Should -Be 'alert'

            $body = Invoke-ContractDelivery -EventType $plan.EventType -Config $config -Items $plan.Items -Plan $plan `
                -Summary ('s' * ($script:ModuleLimits.Summary + 100))
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty

            $body.Services[0].LastError.Length | Should -Be $script:ModuleLimits.LastError
            $body.Services[0].LastError | Should -Match $script:TruncationPattern
            $body.Services[0].DisplayName.Length | Should -Be $script:ModuleLimits.String
            $body.Services[0].DisplayName | Should -Match $script:TruncationPattern
            $body.Summary.Length | Should -Be $script:ModuleLimits.Summary
            $body.Summary | Should -Match $script:TruncationPattern
        }

        It 'values exactly at the function limits are sent untouched' {
            $exactError = 'e' * $script:ModuleLimits.LastError
            $catalog = @{
                Spooler = New-ContractCatalogEntry -DisplayName ('d' * $script:ModuleLimits.String) `
                    -Status 'Stopped' -StartOutcome 'Throw' -StartError $exactError
            }
            $config = New-ContractConfig -Services @('Spooler')
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config

            $body = Invoke-ContractDelivery -EventType $plan.EventType -Config $config -Items $plan.Items -Plan $plan `
                -Summary ('s' * $script:ModuleLimits.Summary)
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.Services[0].LastError | Should -Be $exactError
            $body.Services[0].DisplayName.Length | Should -Be $script:ModuleLimits.String
            $body.Summary.Length | Should -Be $script:ModuleLimits.Summary
        }

        It 'the largest service list the config allows fits the function limit' {
            $names = @(1..$script:ModuleLimits.Services | ForEach-Object { "Service$_" })
            $catalog = @{}
            foreach ($name in $names) {
                $catalog[$name] = New-ContractCatalogEntry -DisplayName "$name Display"
            }
            # The worker's config validator caps Services at 100 (DESIGN.md 4.3); it must not
            # accept more than the function does.
            $config = New-ContractConfig -Services $names
            $config.Services.Count | Should -Be $script:ModuleLimits.Services
            $plan = Invoke-ContractRun -Catalog $catalog -Config $config

            $body = Invoke-ContractDelivery -EventType 'heartbeat' -Config $config -Items $plan.Items
            @(Test-WatchdogPayload -Payload $body) | Should -BeNullOrEmpty
            $body.Services.Count | Should -Be $script:ModuleLimits.Services
        }
    }
}
