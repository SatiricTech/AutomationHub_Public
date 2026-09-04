<#
.SYNOPSIS
    Pester tests for the SendServiceWatchdogAlert HTTP function (run.ps1).

.DESCRIPTION
    Exercises every branch of the request flow in DESIGN.md section 6.4 by dot-sourcing
    run.ps1 with a fake $Request and $TriggerMetadata. The Azure Functions runtime is not
    available locally, so Push-OutputBinding is a stub function that is mocked to capture
    the single response each invocation must produce. Every ServiceWatchdogAlert module
    function the script calls is mocked so no network, mail or table call ever happens.
#>

BeforeAll {
    $script:ModuleName = 'ServiceWatchdogAlert'
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'AzureFunction' 'Modules' $script:ModuleName `
        "$($script:ModuleName).psd1"
    Import-Module $script:ModulePath -Force
    $script:RunPath = Join-Path $PSScriptRoot '..' 'AzureFunction' 'SendServiceWatchdogAlert' 'run.ps1'
    $script:FunctionJsonPath = Join-Path $PSScriptRoot '..' 'AzureFunction' 'SendServiceWatchdogAlert' 'function.json'

    # The Functions worker provides this cmdlet; locally it is a stub for Mock to replace.
    function Push-OutputBinding {
        param (
            [string]$Name,

            [object]$Value,

            [switch]$Clobber
        )
    }

    function New-TestService {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory hashtable.'
        )]
        param (
            [hashtable]$Overrides = @{}
        )

        $service = @{
            Name           = 'Spooler'
            DisplayName    = 'Print Spooler'
            Status         = 'Failed'
            StartType      = 'Automatic'
            Attempts       = 5
            FirstFailedUtc = '2026-09-04T17:50:01Z'
            LastError      = "Cannot start service Spooler on computer '.'"
            FlapCount      = 0
            Notify         = $true
        }
        foreach ($key in $Overrides.Keys) {
            $service[$key] = $Overrides[$key]
        }
        return $service
    }

    function New-TestPayload {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory hashtable.'
        )]
        param (
            [string]$EventType = 'alert',

            [hashtable]$Overrides = @{}
        )

        $services = @((New-TestService))
        if ($EventType -eq 'test') {
            $services = @()
        }
        $payload = @{
            SchemaVersion   = 1
            EventType       = $EventType
            EventId         = [guid]::NewGuid().ToString()
            SiteName        = 'Example Org'
            HostName        = 'SRV-EXAMPLE-01'
            Fqdn            = 'srv-example-01.example.com'
            TimestampUtc    = '2026-09-04T18:05:02Z'
            RunId           = [guid]::NewGuid().ToString()
            WatchdogVersion = '1.0.0'
            Summary         = '1 of 1 monitored services are down'
            Services        = $services
        }
        foreach ($key in $Overrides.Keys) {
            $payload[$key] = $Overrides[$key]
        }
        return $payload
    }

    function New-TestRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory object.'
        )]
        param (
            [object]$Body,

            [hashtable]$Headers = @{ 'X-Forwarded-For' = '203.0.113.5:51234' }
        )

        return [pscustomobject]@{
            Body    = $Body
            Headers = $Headers
            Method  = 'POST'
            Query   = @{}
            Params  = @{}
            Url     = 'https://REPLACE-ME.azurewebsites.net/api/servicewatchdog/alert'
        }
    }

    function Invoke-AlertFunction {
        param (
            [Parameter(Mandatory)]
            [object]$Request
        )

        $triggerMetadata = @{
            sys = @{
                MethodName = 'SendServiceWatchdogAlert'
                UtcNow     = [datetime]::UtcNow
                RandGuid   = [guid]::NewGuid().ToString()
            }
        }
        . $script:RunPath -Request $Request -TriggerMetadata $triggerMetadata
    }

    function Get-PushedResponse {
        $responses = @($script:Pushed | Where-Object { $_.Name -eq 'Response' })
        $responses.Count | Should -Be 1
        $value = $responses[0].Value
        return [pscustomobject]@{
            StatusCode  = $value.StatusCode
            ContentType = $value.ContentType
            Headers     = $value.Headers
            Body        = ($value.Body | ConvertFrom-Json)
        }
    }

    function New-TestConfig {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory object.'
        )]
        param (
            [Parameter(Mandatory)]
            [hashtable]$Environment
        )

        # Runs inside the module scope so the real Get-WatchdogConfig is used even while the
        # test scope has it mocked.
        $module = Get-Module -Name $script:ModuleName
        return (& $module { param($Environment) Get-WatchdogConfig -Environment $Environment } $Environment)
    }

    $script:BaseEnvironment = @{
        WATCHDOG_MAIL_PROVIDER   = 'Smtp2GoApi'
        WATCHDOG_MAIL_FROM       = 'Service Watchdog <alerts@example.com>'
        WATCHDOG_MAIL_TO         = 'it@example.com'
        WATCHDOG_SMTP2GO_API_KEY = 'unit-test-api-key'
        WATCHDOG_TABLE_ENDPOINT  = 'https://example.table.core.windows.net/'
    }
}

Describe 'SendServiceWatchdogAlert run.ps1' {

    BeforeEach {
        $script:Pushed = [System.Collections.ArrayList]::new()
        $script:TestConfig = New-TestConfig -Environment $script:BaseEnvironment

        Mock Push-OutputBinding { $null = $script:Pushed.Add(@{ Name = $Name; Value = $Value }) }
        Mock Write-WatchdogLog { }
        Mock Get-WatchdogConfig { $script:TestConfig }
        Mock Set-WatchdogHostEntity { }
        Mock Test-WatchdogSentEvent { $false }
        Mock Test-WatchdogRateLimit { $true }
        Mock Test-WatchdogGlobalRateLimit { $true }
        Mock Send-WatchdogMail { @{ Sent = $true; ProviderMessageId = 'email-123'; Error = $null; StatusCode = 200 } }
        Mock Set-WatchdogSentEvent { }
    }

    Context 'function.json' {

        It 'declares a POST-only function-key HTTP trigger on the documented route and one http output' {
            $json = Get-Content -LiteralPath $script:FunctionJsonPath -Raw | ConvertFrom-Json
            $trigger = $json.bindings | Where-Object { $_.type -eq 'httpTrigger' }
            $trigger.authLevel | Should -Be 'function'
            @($trigger.methods) | Should -Be @('post')
            $trigger.route | Should -Be 'servicewatchdog/alert'
            $trigger.name | Should -Be 'Request'
            $output = @($json.bindings | Where-Object { $_.direction -eq 'out' })
            $output.Count | Should -Be 1
            $output[0].type | Should -Be 'http'
            $output[0].name | Should -Be 'Response'
        }
    }

    Context 'Rejections' {

        It 'returns 400 invalid_body for a string body' {
            Invoke-AlertFunction -Request (New-TestRequest -Body '{not json')
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 400
            $response.ContentType | Should -Be 'application/json'
            $response.Body.accepted | Should -BeFalse
            $response.Body.error | Should -Be 'invalid_body'
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
        }

        It 'returns 400 invalid_payload with the validation errors and logs the client IP' {
            $payload = New-TestPayload -Overrides @{ EventType = 'panic'; Extra = 1 }
            Invoke-AlertFunction -Request (New-TestRequest -Body $payload)
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 400
            $response.Body.error | Should -Be 'invalid_payload'
            @($response.Body.errors).Count | Should -BeGreaterOrEqual 2
            ($response.Body.errors -join ' ') | Should -BeLike '*EventType*'
            Should -Invoke Write-WatchdogLog -ParameterFilter { $Message -like '*203.0.113.5*' }
            Should -Invoke Set-WatchdogHostEntity -Times 0 -Exactly
        }

        It 'logs the X-Azure-ClientIP when X-Forwarded-For is absent' {
            $request = New-TestRequest -Body 'nope' -Headers @{ 'X-Azure-ClientIP' = '198.51.100.7' }
            Invoke-AlertFunction -Request $request
            Should -Invoke Write-WatchdogLog -ParameterFilter { $Message -like '*198.51.100.7*' }
        }

        It 'returns 500 config_unresolved when configuration cannot be loaded' {
            Mock Get-WatchdogConfig {
                throw 'App setting WATCHDOG_SMTP2GO_API_KEY is an unresolved Key Vault reference'
            }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 500
            $response.Body.error | Should -Be 'config_unresolved'
            ($response.Body.errors -join ' ') | Should -BeLike '*WATCHDOG_SMTP2GO_API_KEY*'
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
        }

        It 'returns 403 site_not_allowed for a site outside the allowlist and logs the client IP' {
            $environment = $script:BaseEnvironment + @{ WATCHDOG_ALLOWED_SITES = 'Other Org' }
            $script:TestConfig = New-TestConfig -Environment $environment
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 403
            $response.Body.error | Should -Be 'site_not_allowed'
            Should -Invoke Write-WatchdogLog -ParameterFilter { $Message -like '*203.0.113.5*' }
            Should -Invoke Set-WatchdogHostEntity -Times 0 -Exactly
        }

        It 'accepts a site that is on the allowlist' {
            $environment = $script:BaseEnvironment + @{ WATCHDOG_ALLOWED_SITES = 'Other Org;Example Org' }
            $script:TestConfig = New-TestConfig -Environment $environment
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            (Get-PushedResponse).StatusCode | Should -Be 200
        }
    }

    Context 'Heartbeat' {

        It 'records the host and returns 200 without sending mail' {
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload -EventType 'heartbeat'))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 200
            $response.Body.accepted | Should -BeTrue
            $response.Body.emailSent | Should -BeFalse
            $response.Body.duplicate | Should -BeFalse
            Should -Invoke Set-WatchdogHostEntity -Times 1 -Exactly
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
            Should -Invoke Test-WatchdogSentEvent -Times 0 -Exactly
            Should -Invoke Test-WatchdogRateLimit -Times 0 -Exactly
        }

        It 'accepts a second heartbeat from the same host' {
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload -EventType 'heartbeat'))
            $script:Pushed = [System.Collections.ArrayList]::new()
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload -EventType 'heartbeat'))
            (Get-PushedResponse).StatusCode | Should -Be 200
            Should -Invoke Set-WatchdogHostEntity -Times 2 -Exactly
        }
    }

    Context 'Deduplication' {

        It 'returns 200 duplicate for an already-sent event and does not send' {
            Mock Test-WatchdogSentEvent { $true }
            $payload = New-TestPayload
            Invoke-AlertFunction -Request (New-TestRequest -Body $payload)
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 200
            $response.Body.duplicate | Should -BeTrue
            $response.Body.emailSent | Should -BeFalse
            Should -Invoke Test-WatchdogSentEvent -Times 1 -Exactly -ParameterFilter {
                $HostKey -eq 'SRV-EXAMPLE-01' -and $EventId -eq $payload.EventId
            }
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
            Should -Invoke Set-WatchdogHostEntity -Times 1 -Exactly
        }

        It 'skips the dedup check for a test event' {
            Mock Test-WatchdogSentEvent { $true }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload -EventType 'test'))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 200
            $response.Body.emailSent | Should -BeTrue
            Should -Invoke Test-WatchdogSentEvent -Times 0 -Exactly
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly
        }

        It 'never records a host row for a test event' {
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload -EventType 'test'))
            (Get-PushedResponse).StatusCode | Should -Be 200
            Should -Invoke Set-WatchdogHostEntity -Times 0 -Exactly
            Should -Invoke Write-WatchdogLog -ParameterFilter { $Message -like '*host row not recorded*' }
        }

        It 'records a host row for every non-test event type' -ForEach @(
            @{ EventType = 'alert' }
            @{ EventType = 'recovered' }
            @{ EventType = 'heartbeat' }
        ) {
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload -EventType $EventType))
            Should -Invoke Set-WatchdogHostEntity -Times 1 -Exactly
        }
    }

    Context 'Rate limiting' {

        It 'returns 429 rate_limited with Retry-After 600' {
            Mock Test-WatchdogRateLimit { $false }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 429
            $response.Body.error | Should -Be 'rate_limited'
            $response.Headers['Retry-After'] | Should -Be '600'
            Should -Invoke Test-WatchdogRateLimit -Times 1 -Exactly -ParameterFilter {
                $HostKey -eq 'SRV-EXAMPLE-01' -and $Limit -eq 6
            }
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
        }

        It 'lets a recovered event bypass the per-host rate limit' {
            Mock Test-WatchdogRateLimit { $false }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload -EventType 'recovered'))
            (Get-PushedResponse).StatusCode | Should -Be 200
            Should -Invoke Test-WatchdogRateLimit -Times 0 -Exactly
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly
        }

        It 'returns 429 rate_limited from the global cap with the configured limit' {
            Mock Test-WatchdogGlobalRateLimit { $false }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 429
            $response.Body.error | Should -Be 'rate_limited'
            $response.Body.errors[0] | Should -BeLike '*60 emails per hour*'
            $response.Headers['Retry-After'] | Should -Be '600'
            Should -Invoke Test-WatchdogGlobalRateLimit -Times 1 -Exactly -ParameterFilter { $Limit -eq 60 }
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
        }

        It 'applies the global cap to recovered and test events too' -ForEach @(
            @{ EventType = 'recovered' }
            @{ EventType = 'test' }
        ) {
            Mock Test-WatchdogGlobalRateLimit { $false }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload -EventType $EventType))
            (Get-PushedResponse).StatusCode | Should -Be 429
            Should -Invoke Send-WatchdogMail -Times 0 -Exactly
        }

        It 'checks the global cap only after the per-host limit and the dedup check pass' {
            Mock Test-WatchdogRateLimit { $false }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            Should -Invoke Test-WatchdogGlobalRateLimit -Times 0 -Exactly

            Mock Test-WatchdogRateLimit { $true }
            Mock Test-WatchdogSentEvent { $true }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            Should -Invoke Test-WatchdogGlobalRateLimit -Times 0 -Exactly
        }
    }

    Context 'Sending' {

        It 'returns 502 provider_failed and records nothing when the provider fails' {
            Mock Send-WatchdogMail {
                @{ Sent = $false; ProviderMessageId = $null; Error = 'sender not verified'; StatusCode = 400 }
            }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 502
            $response.Body.error | Should -Be 'provider_failed'
            ($response.Body.errors -join ' ') | Should -BeLike '*sender not verified*'
            Should -Invoke Set-WatchdogSentEvent -Times 0 -Exactly
        }

        It 'returns 200 with the provider message id and records the sent event' {
            $payload = New-TestPayload
            Invoke-AlertFunction -Request (New-TestRequest -Body $payload)
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 200
            $response.ContentType | Should -Be 'application/json'
            $response.Body.accepted | Should -BeTrue
            $response.Body.emailSent | Should -BeTrue
            $response.Body.duplicate | Should -BeFalse
            $response.Body.providerMessageId | Should -Be 'email-123'
            Should -Invoke Send-WatchdogMail -Times 1 -Exactly -ParameterFilter {
                $Subject -like '*SRV-EXAMPLE-01*' -and $HtmlBody -like '*Spooler*' -and $TextBody -like '*Spooler*'
            }
            Should -Invoke Set-WatchdogSentEvent -Times 1 -Exactly -ParameterFilter {
                $HostKey -eq 'SRV-EXAMPLE-01' -and
                $ProviderMessageId -eq 'email-123' -and
                $Payload.EventId -eq $payload.EventId
            }
        }

        It 'still returns 200 emailSent when the host row write throws' {
            Mock Set-WatchdogHostEntity { throw 'table unavailable' }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 200
            $response.Body.emailSent | Should -BeTrue
            Should -Invoke Write-WatchdogLog -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*table unavailable*'
            }
        }

        It 'still returns 200 when recording the sent event throws' {
            Mock Set-WatchdogSentEvent { throw 'table unavailable' }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            (Get-PushedResponse).StatusCode | Should -Be 200
        }

        It 'returns 500 with a JSON body when an unexpected error escapes' {
            Mock Send-WatchdogMail { throw 'unexpected' }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $response = Get-PushedResponse
            $response.StatusCode | Should -Be 500
            $response.Body.accepted | Should -BeFalse
            $response.Body.error | Should -Be 'internal_error'
            Should -Invoke Write-WatchdogLog -ParameterFilter { $Level -eq 'Error' -and $Message -like '*unexpected*' }
        }
    }

    Context 'Response contract' {

        It 'pushes exactly one JSON Response for <Name>' -ForEach @(
            @{ Name = 'string body' }
            @{ Name = 'invalid payload' }
            @{ Name = 'heartbeat' }
            @{ Name = 'duplicate' }
            @{ Name = 'rate limited' }
            @{ Name = 'globally rate limited' }
            @{ Name = 'provider failure' }
            @{ Name = 'success' }
        ) {
            $body = New-TestPayload
            switch ($Name) {
                'string body' { $body = 'x' }
                'invalid payload' { $body = @{ SchemaVersion = 1 } }
                'heartbeat' { $body = New-TestPayload -EventType 'heartbeat' }
                'duplicate' { Mock Test-WatchdogSentEvent { $true } }
                'rate limited' { Mock Test-WatchdogRateLimit { $false } }
                'globally rate limited' { Mock Test-WatchdogGlobalRateLimit { $false } }
                'provider failure' { Mock Send-WatchdogMail { @{ Sent = $false; Error = 'x' } } }
            }
            Invoke-AlertFunction -Request (New-TestRequest -Body $body)
            Should -Invoke Push-OutputBinding -Times 1 -Exactly
            $response = Get-PushedResponse
            $response.ContentType | Should -Be 'application/json'
            $response.Body.accepted | Should -BeOfType [bool]
        }
    }

    Context 'HttpResponseContext conversion' {

        BeforeAll {
            # Stand-in for the worker's HttpResponseContext so 'HttpResponseContext' -as [type]
            # resolves exactly as it does inside the Functions host. Add-Type is process-wide,
            # so this context runs last: every context above exercises the type-absent path.
            # FailNext makes the StatusCode setter throw once, which is how a mismatched
            # worker type would surface during hashtable-to-object conversion.
            if (-not ('HttpResponseContext' -as [type])) {
                Add-Type -TypeDefinition @'
public class HttpResponseContext
{
    public static bool FailNext;
    private object statusCode;
    public object Body { get; set; }
    public string ContentType { get; set; }
    public System.Collections.Hashtable Headers { get; set; }
    public object StatusCode
    {
        get { return statusCode; }
        set
        {
            if (FailNext)
            {
                FailNext = false;
                throw new System.InvalidOperationException("simulated worker type mismatch");
            }
            statusCode = value;
        }
    }
}
'@
            }
        }

        BeforeEach {
            [HttpResponseContext]::FailNext = $false
        }

        It 'pushes a typed HttpResponseContext when the worker type is present' {
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $pushed = @($script:Pushed | Where-Object { $_.Name -eq 'Response' })
            $pushed.Count | Should -Be 1
            $pushed[0].Value | Should -BeOfType [HttpResponseContext]
            $pushed[0].Value.StatusCode | Should -Be 200
            $pushed[0].Value.ContentType | Should -Be 'application/json'
            ($pushed[0].Value.Body | ConvertFrom-Json).accepted | Should -BeTrue
        }

        It 'keeps the Retry-After header through the typed conversion' {
            Mock Test-WatchdogRateLimit { $false }
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            $pushed = @($script:Pushed | Where-Object { $_.Name -eq 'Response' })
            $pushed[0].Value | Should -BeOfType [HttpResponseContext]
            $pushed[0].Value.StatusCode | Should -Be 429
            $pushed[0].Value.Headers['Retry-After'] | Should -Be '600'
        }

        It 'never pushes null: falls back to the hashtable and logs a Warning when conversion fails' {
            [HttpResponseContext]::FailNext = $true
            Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))
            Should -Invoke Push-OutputBinding -Times 1 -Exactly
            $pushed = @($script:Pushed | Where-Object { $_.Name -eq 'Response' })
            $pushed.Count | Should -Be 1
            $pushed[0].Value | Should -Not -BeNullOrEmpty
            $pushed[0].Value | Should -BeOfType [hashtable]
            $pushed[0].Value.StatusCode | Should -Be 200
            $pushed[0].Value.ContentType | Should -Be 'application/json'
            ($pushed[0].Value.Body | ConvertFrom-Json).emailSent | Should -BeTrue
            Should -Invoke Write-WatchdogLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*HttpResponseContext conversion failed*'
            }
        }
    }
}

Describe 'SendServiceWatchdogAlert run.ps1 cold-start failure' {
    # Separate Describe: the block above mocks the module functions, which would mask the
    # case this covers, where the module never loaded and none of them exist.

    BeforeEach {
        $script:Pushed = [System.Collections.ArrayList]::new()
        Mock Push-OutputBinding { $null = $script:Pushed.Add(@{ Name = $Name; Value = $Value }) }
        Mock Write-Error { }
        Remove-Module -Name $script:ModuleName -Force -ErrorAction SilentlyContinue
        Mock Import-Module { throw 'The specified module was not loaded because no valid module file was found' }
    }

    AfterEach {
        # Invoked through the cmdlet's CommandInfo so the Import-Module mock above (which
        # also intercepts module-qualified calls) does not swallow the restore.
        & (Get-Command -Name 'Import-Module' -CommandType Cmdlet) $script:ModulePath -Force
    }

    It 'still pushes exactly one 500 internal_error JSON response when Import-Module fails' {
        Get-Module -Name $script:ModuleName | Should -BeNullOrEmpty

        Invoke-AlertFunction -Request (New-TestRequest -Body (New-TestPayload))

        Should -Invoke Push-OutputBinding -Times 1 -Exactly
        $response = Get-PushedResponse
        $response.StatusCode | Should -Be 500
        $response.ContentType | Should -Be 'application/json'
        $response.Body.accepted | Should -BeFalse
        $response.Body.error | Should -Be 'internal_error'
        Should -Invoke Write-Error -Times 1 -Exactly -ParameterFilter {
            $Message -like '*no valid module file was found*' -and $Message -like '*runId=*'
        }
    }
}
