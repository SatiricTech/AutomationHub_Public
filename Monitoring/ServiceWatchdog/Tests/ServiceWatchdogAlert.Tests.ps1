<#
.SYNOPSIS
    Pester tests for the ServiceWatchdogAlert module.

.DESCRIPTION
    Unit tests for every exported function of the Azure Function module described in
    DESIGN.md sections 6.2 and 6.3: configuration loading and the Key Vault startup guard,
    payload validation against the 4.8 contract, email rendering (HTML encoding and subject
    line-break stripping), the SMTP2GO and SMTP providers, the per-host rate limit, the
    managed-identity storage token cache, the Table REST helpers, stale-host computation,
    key sanitizing and structured logging.

    Every network call (Invoke-WebRequest, Invoke-RestMethod) and every sleep is mocked
    inside the module scope. No test touches the network, the filesystem or real
    environment variables other than a short-lived WATCHDOG_* set that is removed again.
#>

BeforeAll {
    $script:ModuleName = 'ServiceWatchdogAlert'
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'AzureFunction' 'Modules' $script:ModuleName `
        "$($script:ModuleName).psd1"
    Import-Module $script:ModulePath -Force
    $script:TableEndpoint = 'https://example.table.core.windows.net/'
    $script:EventId = '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
    $script:KeyVaultReference = '@Microsoft.KeyVault(SecretUri=https://example.vault.azure.net/secrets/Example)'

    function New-TestEnvironment {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory hashtable.'
        )]
        param (
            [string]$Provider = 'Smtp2GoApi',

            [hashtable]$Overrides = @{},

            [string[]]$Remove = @()
        )

        $environment = @{
            WATCHDOG_MAIL_PROVIDER   = $Provider
            WATCHDOG_MAIL_FROM       = 'Service Watchdog <alerts@example.com>'
            WATCHDOG_MAIL_TO         = 'it@example.com; oncall@example.com'
            WATCHDOG_SMTP2GO_API_KEY = 'unit-test-api-key'
            WATCHDOG_SMTP_HOST       = 'mail.example.com'
            WATCHDOG_SMTP_USERNAME   = 'smtp-user'
            WATCHDOG_SMTP_PASSWORD   = 'unit-test-smtp-password'
            WATCHDOG_TABLE_ENDPOINT  = $script:TableEndpoint
        }
        foreach ($key in $Overrides.Keys) {
            $environment[$key] = $Overrides[$key]
        }
        foreach ($key in $Remove) {
            $environment.Remove($key)
        }
        return $environment
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

            [hashtable]$Overrides = @{},

            [object[]]$Services
        )

        if (-not $PSBoundParameters.ContainsKey('Services')) {
            $Services = @((New-TestService))
        }
        $payload = @{
            SchemaVersion   = 1
            EventType       = $EventType
            EventId         = '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
            SiteName        = 'Example Org'
            HostName        = 'SRV-EXAMPLE-01'
            Fqdn            = 'srv-example-01.example.com'
            TimestampUtc    = '2026-09-04T18:05:02Z'
            RunId           = '3f9c7a44-1c2e-4b1a-9e6b-0b2a4c9d8e11'
            WatchdogVersion = '1.0.0'
            Summary         = '1 of 1 monitored services are down'
            Services        = @($Services)
        }
        foreach ($key in $Overrides.Keys) {
            $payload[$key] = $Overrides[$key]
        }
        return $payload
    }

    function New-Smtp2GoResponse {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory object.'
        )]
        param (
            [int]$StatusCode = 200,

            [int]$Succeeded = 1,

            [int]$Failed = 0,

            [string]$Error,

            [hashtable]$Headers = @{}
        )

        if ($StatusCode -eq 200) {
            $failures = @()
            if ($Failed -gt 0) {
                $failures = @('bad@example.invalid: rejected')
            }
            $content = @{
                request_id = 'req-1'
                data       = @{ succeeded = $Succeeded; failed = $Failed; failures = $failures; email_id = 'email-123' }
            }
        }
        else {
            $content = @{
                request_id = 'req-1'
                data       = @{ error_code = 'E_TEST'; error = $Error }
            }
        }
        return [pscustomobject]@{
            StatusCode = $StatusCode
            Headers    = $Headers
            Content    = ($content | ConvertTo-Json -Depth 5 -Compress)
        }
    }

    function New-TableResponse {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture builder returning an in-memory object.'
        )]
        param (
            [int]$StatusCode = 204,

            [string]$Content = ''
        )

        return [pscustomobject]@{ StatusCode = $StatusCode; Headers = @{}; Content = $Content }
    }
}

Describe 'ServiceWatchdogAlert module' {

    BeforeAll {
        Mock -ModuleName $script:ModuleName Write-WatchdogLog { }
    }

    Context 'Module manifest' {

        It 'exports exactly the documented public functions' {
            $expected = @(
                'Get-WatchdogConfig', 'Test-WatchdogPayload', 'ConvertTo-WatchdogEmail', 'Send-WatchdogMail',
                'Test-WatchdogRateLimit', 'Test-WatchdogGlobalRateLimit', 'Get-WatchdogStorageToken',
                'Set-WatchdogHostEntity',
                'Test-WatchdogSentEvent', 'Set-WatchdogSentEvent', 'ConvertTo-WatchdogHostEntity',
                'Get-WatchdogStaleHosts', 'ConvertTo-WatchdogKey', 'Write-WatchdogLog'
            )
            $exported = (Get-Module $script:ModuleName).ExportedFunctions.Keys | Sort-Object
            $exported | Should -Be ($expected | Sort-Object)
        }

        It 'declares version 1.0.0' {
            (Get-Module $script:ModuleName).Version.ToString() | Should -Be '1.0.0'
        }
    }

    Context 'Get-WatchdogConfig' {

        It 'throws naming every missing required setting' {
            $environment = New-TestEnvironment -Remove 'WATCHDOG_MAIL_FROM', 'WATCHDOG_MAIL_TO'
            $act = { Get-WatchdogConfig -Environment $environment }
            $act | Should -Throw -ExpectedMessage '*WATCHDOG_MAIL_FROM*'
            $act | Should -Throw -ExpectedMessage '*WATCHDOG_MAIL_TO*'
        }

        It 'throws naming the table endpoint when it is missing' {
            $environment = New-TestEnvironment -Remove 'WATCHDOG_TABLE_ENDPOINT'
            { Get-WatchdogConfig -Environment $environment } |
                Should -Throw -ExpectedMessage '*WATCHDOG_TABLE_ENDPOINT*'
        }

        It 'throws naming the setting when the SMTP2GO key is an unresolved Key Vault reference' {
            $environment = New-TestEnvironment -Overrides @{
                WATCHDOG_SMTP2GO_API_KEY = $script:KeyVaultReference
            }
            { Get-WatchdogConfig -Environment $environment } |
                Should -Throw -ExpectedMessage '*WATCHDOG_SMTP2GO_API_KEY*'
        }

        It 'throws naming the setting when the SMTP password is an unresolved Key Vault reference' {
            $environment = New-TestEnvironment -Provider 'Smtp' -Overrides @{
                WATCHDOG_SMTP_PASSWORD = $script:KeyVaultReference
            }
            { Get-WatchdogConfig -Environment $environment } | Should -Throw -ExpectedMessage '*WATCHDOG_SMTP_PASSWORD*'
        }

        It 'ignores an unresolved secret that belongs to the unused provider' {
            $environment = New-TestEnvironment -Provider 'Smtp2GoApi' -Overrides @{
                WATCHDOG_SMTP_PASSWORD = $script:KeyVaultReference
            }
            { Get-WatchdogConfig -Environment $environment } | Should -Not -Throw
        }

        It 'never exposes the unused provider secrets on the config object' {
            $environment = New-TestEnvironment -Provider 'Smtp2GoApi'
            $config = Get-WatchdogConfig -Environment $environment
            $config.SmtpPassword | Should -BeNullOrEmpty
        }

        It 'requires host, username and password for the Smtp provider' {
            $environment = New-TestEnvironment -Provider 'Smtp' `
                -Remove 'WATCHDOG_SMTP_HOST', 'WATCHDOG_SMTP_USERNAME', 'WATCHDOG_SMTP_PASSWORD'
            $act = { Get-WatchdogConfig -Environment $environment }
            $act | Should -Throw -ExpectedMessage '*WATCHDOG_SMTP_HOST*'
            $act | Should -Throw -ExpectedMessage '*WATCHDOG_SMTP_USERNAME*'
            $act | Should -Throw -ExpectedMessage '*WATCHDOG_SMTP_PASSWORD*'
        }

        It 'does not require the SMTP2GO key for the Smtp provider' {
            $environment = New-TestEnvironment -Provider 'Smtp' -Remove 'WATCHDOG_SMTP2GO_API_KEY'
            $config = Get-WatchdogConfig -Environment $environment
            $config.MailProvider | Should -Be 'Smtp'
            $config.SmtpHost | Should -Be 'mail.example.com'
        }

        It 'rejects an unknown mail provider' {
            $environment = New-TestEnvironment -Provider 'Carrier Pigeon'
            { Get-WatchdogConfig -Environment $environment } | Should -Throw -ExpectedMessage '*WATCHDOG_MAIL_PROVIDER*'
        }

        It 'applies the documented defaults' {
            $environment = New-TestEnvironment -Remove 'WATCHDOG_MAIL_PROVIDER'
            $config = Get-WatchdogConfig -Environment $environment
            $config.MailProvider | Should -Be 'Smtp2GoApi'
            $config.MailSubjectPrefix | Should -Be '[Service Watchdog]'
            $config.MailTimeoutSeconds | Should -Be 20
            $config.Smtp2GoApiUrl | Should -Be 'https://api.smtp2go.com/v3/email/send'
            $config.SmtpPort | Should -Be 587
            $config.SmtpUseStartTls | Should -BeTrue
            $config.MaxAlertsPerHostPerHour | Should -Be 6
            $config.MaxEmailsPerHour | Should -Be 60
            $config.AllowedSites | Should -BeNullOrEmpty
            $config.StaleHours | Should -Be 26
            $config.DigestAlwaysSend | Should -BeFalse
        }

        It 'splits recipients and allowed sites on semicolons and trims them' {
            $environment = New-TestEnvironment -Overrides @{ WATCHDOG_ALLOWED_SITES = ' Example Org ;Other Org;; ' }
            $config = Get-WatchdogConfig -Environment $environment
            $config.MailTo | Should -Be @('it@example.com', 'oncall@example.com')
            $config.AllowedSites | Should -Be @('Example Org', 'Other Org')
        }

        It 'parses numeric and boolean settings' {
            $environment = New-TestEnvironment -Provider 'Smtp' -Overrides @{
                WATCHDOG_MAIL_TIMEOUT_SECONDS        = '45'
                WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR = '3'
                WATCHDOG_MAX_EMAILS_PER_HOUR         = '25'
                WATCHDOG_STALE_HOURS                 = '48'
                WATCHDOG_DIGEST_ALWAYS_SEND          = 'true'
                WATCHDOG_SMTP_PORT                   = '2525'
                WATCHDOG_SMTP_USE_STARTTLS           = 'false'
            }
            $config = Get-WatchdogConfig -Environment $environment
            $config.MailTimeoutSeconds | Should -Be 45
            $config.MaxAlertsPerHostPerHour | Should -Be 3
            $config.MaxEmailsPerHour | Should -Be 25
            $config.StaleHours | Should -Be 48
            $config.DigestAlwaysSend | Should -BeTrue
            $config.SmtpPort | Should -Be 2525
            $config.SmtpUseStartTls | Should -BeFalse
        }

        It 'rejects a non-numeric numeric setting naming it' {
            $environment = New-TestEnvironment -Overrides @{ WATCHDOG_STALE_HOURS = 'soon' }
            { Get-WatchdogConfig -Environment $environment } | Should -Throw -ExpectedMessage '*WATCHDOG_STALE_HOURS*'
        }

        It 'appends a trailing slash to the table endpoint when missing' {
            $endpoint = $script:TableEndpoint.TrimEnd('/')
            $environment = New-TestEnvironment -Overrides @{ WATCHDOG_TABLE_ENDPOINT = $endpoint }
            (Get-WatchdogConfig -Environment $environment).TableEndpoint | Should -Be $script:TableEndpoint
        }

        It 'reads the process environment when -Environment is omitted' {
            $names = @(
                'WATCHDOG_MAIL_PROVIDER', 'WATCHDOG_MAIL_FROM', 'WATCHDOG_MAIL_TO', 'WATCHDOG_SMTP2GO_API_KEY',
                'WATCHDOG_TABLE_ENDPOINT', 'WATCHDOG_MAIL_SUBJECT_PREFIX'
            )
            $saved = @{}
            foreach ($name in $names) {
                $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            try {
                [Environment]::SetEnvironmentVariable('WATCHDOG_MAIL_PROVIDER', 'Smtp2GoApi')
                [Environment]::SetEnvironmentVariable('WATCHDOG_MAIL_FROM', 'alerts@example.com')
                [Environment]::SetEnvironmentVariable('WATCHDOG_MAIL_TO', 'it@example.com')
                [Environment]::SetEnvironmentVariable('WATCHDOG_SMTP2GO_API_KEY', 'unit-test-api-key')
                [Environment]::SetEnvironmentVariable('WATCHDOG_TABLE_ENDPOINT', $script:TableEndpoint)
                [Environment]::SetEnvironmentVariable('WATCHDOG_MAIL_SUBJECT_PREFIX', '[Env Prefix]')
                $config = Get-WatchdogConfig
                $config.MailSubjectPrefix | Should -Be '[Env Prefix]'
                $config.MailTo | Should -Be @('it@example.com')
            }
            finally {
                foreach ($name in $names) {
                    [Environment]::SetEnvironmentVariable($name, $saved[$name])
                }
            }
        }
    }

    Context 'Test-WatchdogPayload' {

        It 'accepts a valid <EventType> payload' -ForEach @(
            @{ EventType = 'alert' }
            @{ EventType = 'flapping' }
            @{ EventType = 'reminder' }
            @{ EventType = 'recovered' }
            @{ EventType = 'remediated' }
            @{ EventType = 'heartbeat' }
        ) {
            $payload = New-TestPayload -EventType $EventType
            @(Test-WatchdogPayload -Payload $payload) | Should -BeNullOrEmpty
        }

        It 'accepts a valid test payload with an empty service list' {
            $payload = New-TestPayload -EventType 'test' -Services @()
            @(Test-WatchdogPayload -Payload $payload) | Should -BeNullOrEmpty
        }

        It 'accepts nulls in every nullable field' {
            $service = New-TestService -Overrides @{
                DisplayName = $null; StartType = $null; FirstFailedUtc = $null; LastError = $null; Status = 'Missing'
            }
            $payload = New-TestPayload -Overrides @{ Fqdn = $null } -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) | Should -BeNullOrEmpty
        }

        It 'accepts timestamps the JSON deserializer already turned into UTC DateTime values' {
            $service = New-TestService -Overrides @{
                FirstFailedUtc = [datetime]::new(2026, 9, 4, 17, 50, 1, [DateTimeKind]::Utc)
            }
            $payload = New-TestPayload -Overrides @{
                TimestampUtc = [datetime]::new(2026, 9, 4, 18, 5, 2, [DateTimeKind]::Utc)
            } -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) | Should -BeNullOrEmpty
        }

        It 'rejects a DateTime timestamp that did not carry the Z suffix' {
            $payload = New-TestPayload -Overrides @{
                TimestampUtc = [datetime]::new(2026, 9, 4, 18, 5, 2, [DateTimeKind]::Unspecified)
            }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*TimestampUtc*'
        }

        It 'rejects a body over 256 KB' {
            $payload = New-TestPayload -Overrides @{ Summary = ('x' * 300000) }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*256 KB*'
        }

        It 'rejects more than 100 services' {
            $services = @(1..101 | ForEach-Object { New-TestService -Overrides @{ Name = "Svc$_" } })
            $payload = New-TestPayload -Services $services
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*Services*100*'
        }

        It 'rejects a host name that fails the pattern' {
            $payload = New-TestPayload -Overrides @{ HostName = 'srv one' }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*HostName*'
        }

        It 'rejects an unknown event type' {
            $payload = New-TestPayload -EventType 'panic'
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*EventType*panic*'
        }

        It 'rejects SchemaVersion 2' {
            $payload = New-TestPayload -Overrides @{ SchemaVersion = 2 }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*SchemaVersion*'
        }

        It 'rejects a timestamp that is not in the exact format' {
            $payload = New-TestPayload -Overrides @{ TimestampUtc = '2026-09-04 18:05:02' }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*TimestampUtc*'
        }

        It 'rejects a FirstFailedUtc with fractional seconds' {
            $service = New-TestService -Overrides @{ FirstFailedUtc = '2026-09-04T17:50:01.123Z' }
            $payload = New-TestPayload -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*FirstFailedUtc*'
        }

        It 'rejects RunId and EventId that are not GUIDs' {
            $payload = New-TestPayload -Overrides @{ RunId = 'run-1'; EventId = 'event-1' }
            $errors = @(Test-WatchdogPayload -Payload $payload)
            $errors -join ' ' | Should -BeLike '*RunId*'
            $errors -join ' ' | Should -BeLike '*EventId*'
        }

        It 'rejects LastError over 1000 characters' {
            $service = New-TestService -Overrides @{ LastError = ('e' * 1001) }
            $payload = New-TestPayload -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*LastError*1000*'
        }

        It 'accepts LastError of exactly 1000 characters' {
            $service = New-TestService -Overrides @{ LastError = ('e' * 1000) }
            $payload = New-TestPayload -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) | Should -BeNullOrEmpty
        }

        It 'rejects Summary over 512 characters' {
            $payload = New-TestPayload -Overrides @{ Summary = ('s' * 513) }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*Summary*512*'
        }

        It 'rejects a general string field over 256 characters' {
            $service = New-TestService -Overrides @{ DisplayName = ('d' * 257) }
            $payload = New-TestPayload -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*DisplayName*256*'
        }

        It 'rejects an unknown top-level key naming it' {
            $payload = New-TestPayload -Overrides @{ Extra = 'nope' }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike "*Unknown top-level key 'Extra'*"
        }

        It 'rejects a bad service Status' {
            $service = New-TestService -Overrides @{ Status = 'Broken' }
            $payload = New-TestPayload -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*Status*Broken*'
        }

        It 'rejects a bad StartType' {
            $service = New-TestService -Overrides @{ StartType = 'Sometimes' }
            $payload = New-TestPayload -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*StartType*'
        }

        It 'rejects a missing required top-level field' {
            $payload = New-TestPayload
            $payload.Remove('Summary')
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*Summary*required*'
        }

        It 'rejects a null required top-level field' {
            $payload = New-TestPayload -Overrides @{ HostName = $null }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*HostName*'
        }

        It 'rejects Services that is not an array' {
            $payload = New-TestPayload -Overrides @{ Services = 'Spooler' }
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*Services*array*'
        }

        It 'rejects a service that is not an object' {
            $payload = New-TestPayload -Services @('Spooler')
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*Services[[]0]*'
        }

        It 'rejects non-integer Attempts and FlapCount' {
            $service = New-TestService -Overrides @{ Attempts = 'five'; FlapCount = 1.5 }
            $payload = New-TestPayload -Services @($service)
            $errors = @(Test-WatchdogPayload -Payload $payload)
            $errors -join ' ' | Should -BeLike '*Attempts*'
            $errors -join ' ' | Should -BeLike '*FlapCount*'
        }

        It 'accepts Int64 counters as produced by the JSON deserializer' {
            $service = New-TestService -Overrides @{ Attempts = [long]5; FlapCount = [long]0 }
            $payload = New-TestPayload -Overrides @{ SchemaVersion = [long]1 } -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) | Should -BeNullOrEmpty
        }

        It 'rejects a non-boolean Notify' {
            $service = New-TestService -Overrides @{ Notify = 'yes' }
            $payload = New-TestPayload -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*Notify*'
        }

        It 'rejects a missing service Name' {
            $service = New-TestService
            $service.Remove('Name')
            $payload = New-TestPayload -Services @($service)
            @(Test-WatchdogPayload -Payload $payload) -join ' ' | Should -BeLike '*Name*required*'
        }

        It 'reports every violation, not only the first' {
            $payload = New-TestPayload -Overrides @{ SchemaVersion = 2; EventType = 'panic'; HostName = 'bad host' }
            @(Test-WatchdogPayload -Payload $payload).Count | Should -BeGreaterOrEqual 3
        }
    }

    Context 'ConvertTo-WatchdogEmail' {

        BeforeAll {
            $script:Config = Get-WatchdogConfig -Environment (New-TestEnvironment)
        }

        It 'HTML-encodes hostile strings and keeps them raw in the text body' {
            $hostile = '<script>alert(1)</script>"onmouseover'
            $service = New-TestService -Overrides @{ Name = $hostile; LastError = $hostile; DisplayName = $hostile }
            $payload = New-TestPayload -Overrides @{ SiteName = $hostile; Summary = $hostile } -Services @($service)
            $email = ConvertTo-WatchdogEmail -Payload $payload -Config $script:Config

            $email.HtmlBody | Should -Not -BeLike '*<script>*'
            $email.HtmlBody | Should -Not -BeLike '*"onmouseover*'
            $email.HtmlBody | Should -BeLike '*&lt;script&gt;*'
            $email.HtmlBody | Should -BeLike '*&quot;onmouseover*'
            $email.TextBody | Should -BeLike '*<script>alert(1)</script>"onmouseover*'
        }

        It 'HTML-encodes a hostile host name and FQDN' {
            $payload = New-TestPayload -Overrides @{ HostName = 'SRV<b>1'; Fqdn = 'srv<b>1.example.com' }
            $email = ConvertTo-WatchdogEmail -Payload $payload -Config $script:Config
            $email.HtmlBody | Should -Not -BeLike '*SRV<b>1*'
            $email.HtmlBody | Should -BeLike '*SRV&lt;b&gt;1*'
            $email.HtmlBody | Should -BeLike '*srv&lt;b&gt;1.example.com*'
            $email.TextBody | Should -BeLike '*SRV<b>1*'
        }

        It 'strips CR and LF from the subject' {
            $payload = New-TestPayload -Overrides @{
                HostName = "SRV-EXAMPLE-01`r`nBcc: x"
                Summary  = "down`nX-Injected: 1"
            }
            $email = ConvertTo-WatchdogEmail -Payload $payload -Config $script:Config
            $email.Subject | Should -Not -Match '[\r\n]'
            $email.Subject | Should -BeLike '*SRV-EXAMPLE-01Bcc: x*'
        }

        It 'builds the subject from prefix, host and summary' {
            $payload = New-TestPayload -EventType 'alert'
            $email = ConvertTo-WatchdogEmail -Payload $payload -Config $script:Config
            $email.Subject | Should -Be '[Service Watchdog] SRV-EXAMPLE-01: 1 of 1 monitored services are down'
        }

        It 'marks a <EventType> subject with <Marker>' -ForEach @(
            @{ EventType = 'test'; Marker = '[TEST]' }
            @{ EventType = 'reminder'; Marker = 'Reminder:' }
            @{ EventType = 'flapping'; Marker = 'Flapping:' }
        ) {
            $payload = New-TestPayload -EventType $EventType
            $email = ConvertTo-WatchdogEmail -Payload $payload -Config $script:Config
            $escapedMarker = [WildcardPattern]::Escape($Marker)
            $email.Subject | Should -BeLike "[[]Service Watchdog] $escapedMarker SRV-EXAMPLE-01: *"
        }

        It 'does not mark a recovered subject' {
            $email = ConvertTo-WatchdogEmail -Payload (New-TestPayload -EventType 'recovered') -Config $script:Config
            $email.Subject | Should -Not -BeLike '*Reminder:*'
            $email.Subject | Should -Not -BeLike '*Flapping:*'
            $email.Subject | Should -Not -BeLike '*[[]TEST]*'
        }

        It 'renders a row for every service in both bodies' {
            $services = @(
                (New-TestService -Overrides @{ Name = 'Spooler'; Status = 'Failed' })
                (New-TestService -Overrides @{ Name = 'W3SVC'; Status = 'Healthy'; Notify = $false; LastError = $null })
                (New-TestService -Overrides @{
                        Name = 'MSSQLSERVER'; Status = 'Missing'; StartType = $null; DisplayName = $null
                    })
            )
            $email = ConvertTo-WatchdogEmail -Payload (New-TestPayload -Services $services) -Config $script:Config
            foreach ($name in 'Spooler', 'W3SVC', 'MSSQLSERVER') {
                $email.HtmlBody | Should -BeLike "*$name*"
                $email.TextBody | Should -BeLike "*$name*"
            }
            $servicesHtml = $email.HtmlBody.Substring($email.HtmlBody.IndexOf('<h3'))
            ([regex]::Matches($servicesHtml, '<tr>')).Count | Should -Be 4
        }

        It 'includes site, host, FQDN, time and event type sections' {
            $email = ConvertTo-WatchdogEmail -Payload (New-TestPayload) -Config $script:Config
            $expected = 'Example Org', 'SRV-EXAMPLE-01', 'srv-example-01.example.com', '2026-09-04T18:05:02Z', 'alert'
            foreach ($value in $expected) {
                $email.HtmlBody | Should -BeLike "*$value*"
                $email.TextBody | Should -BeLike "*$value*"
            }
        }

        It 'names the watchdog version, run id and event id in the footer' {
            $email = ConvertTo-WatchdogEmail -Payload (New-TestPayload) -Config $script:Config
            $expected = '1.0.0', '3f9c7a44-1c2e-4b1a-9e6b-0b2a4c9d8e11', '8b1d6e2a-4f3c-4a7e-9c1d-2e5f6a7b8c9d'
            foreach ($value in $expected) {
                $email.HtmlBody | Should -BeLike "*$value*"
                $email.TextBody | Should -BeLike "*$value*"
            }
        }

        It 'renders a test event with no services without failing' {
            $payload = New-TestPayload -EventType 'test' -Services @()
            $email = ConvertTo-WatchdogEmail -Payload $payload -Config $script:Config
            $email.HtmlBody | Should -BeLike '*No services*'
            $email.TextBody | Should -BeLike '*No services*'
        }
    }

    Context 'Send-WatchdogMail via SMTP2GO' {

        BeforeAll {
            $script:Config = Get-WatchdogConfig -Environment (New-TestEnvironment)
            Mock -ModuleName $script:ModuleName Start-Sleep { }
        }

        It 'sends the API key header and the documented JSON body' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-Smtp2GoResponse }
            $result = Send-WatchdogMail -Config $script:Config -Subject 'Subj' -TextBody 'Text' -HtmlBody '<p>Html</p>'

            $result.Sent | Should -BeTrue
            $result.ProviderMessageId | Should -Be 'email-123'
            $result.StatusCode | Should -Be 200
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $body = $Body | ConvertFrom-Json
                $Method -eq 'Post' -and
                $Uri -eq 'https://api.smtp2go.com/v3/email/send' -and
                $Headers['X-Smtp2go-Api-Key'] -eq 'unit-test-api-key' -and
                $ContentType -like 'application/json*' -and
                $body.sender -eq 'Service Watchdog <alerts@example.com>' -and
                @($body.to).Count -eq 2 -and
                $body.to[0] -eq 'it@example.com' -and
                $body.subject -eq 'Subj' -and
                $body.text_body -eq 'Text' -and
                $body.html_body -eq '<p>Html</p>' -and
                $TimeoutSec -eq 20
            }
        }

        It 'reports Sent with a warning when the provider accepts one recipient and rejects another' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-Smtp2GoResponse -Succeeded 1 -Failed 1 }
            $result = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            $result.Sent | Should -BeTrue
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*bad@example.invalid*'
            }
        }

        It 'reports not sent when nothing succeeded' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-Smtp2GoResponse -Succeeded 0 -Failed 1 }
            $result = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            $result.Sent | Should -BeFalse
            $result.Error | Should -Not -BeNullOrEmpty
        }

        It 'returns the provider error text on 400 and does not retry' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                New-Smtp2GoResponse -StatusCode 400 -Error 'sender not verified'
            }
            $result = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            $result.Sent | Should -BeFalse
            $result.StatusCode | Should -Be 400
            $result.Error | Should -BeLike '*sender not verified*'
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly
            Should -Invoke -ModuleName $script:ModuleName Start-Sleep -Times 0 -Exactly
        }

        It 'retries after 429 honoring Retry-After and succeeds' {
            # The mock body runs in the module scope and a closure sees only what it captured, so the
            # responses are built here and the counter travels inside a captured hashtable.
            $calls = @{ Count = 0 }
            $throttled = New-Smtp2GoResponse -StatusCode 429 -Error 'throttled' -Headers @{ 'Retry-After' = @('7') }
            $accepted = New-Smtp2GoResponse
            Mock -ModuleName $script:ModuleName Invoke-WebRequest ({
                    $calls.Count++
                    if ($calls.Count -eq 1) {
                        return $throttled
                    }
                    return $accepted
                }.GetNewClosure())
            $result = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            $result.Sent | Should -BeTrue
            $calls.Count | Should -Be 2
            Should -Invoke -ModuleName $script:ModuleName Start-Sleep -Times 1 -Exactly -ParameterFilter {
                $Seconds -eq 7
            }
        }

        It 'caps Retry-After at 30 seconds' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                New-Smtp2GoResponse -StatusCode 503 -Error 'busy' -Headers @{ 'Retry-After' = @('600') }
            }
            $null = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            Should -Invoke -ModuleName $script:ModuleName Start-Sleep -Times 2 -Exactly -ParameterFilter {
                $Seconds -eq 30
            }
        }

        It 'gives up after three 503 responses' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-Smtp2GoResponse -StatusCode 503 -Error 'busy' }
            $result = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            $result.Sent | Should -BeFalse
            $result.StatusCode | Should -Be 503
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 3 -Exactly
            foreach ($delay in 2, 5) {
                Should -Invoke -ModuleName $script:ModuleName Start-Sleep -Times 1 -Exactly -ParameterFilter {
                    $Seconds -eq $delay
                }
            }
        }

        It 'returns an error when the request times out' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                throw 'The request was canceled due to the configured HttpClient.Timeout'
            }
            $result = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            $result.Sent | Should -BeFalse
            $result.Error | Should -BeLike '*Timeout*'
            $result.StatusCode | Should -BeNullOrEmpty
        }

        It 'never writes the API key to the log' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-Smtp2GoResponse -StatusCode 400 -Error 'bad' }
            $null = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -Times 0 -Exactly -ParameterFilter {
                $Message -like '*unit-test-api-key*'
            }
        }
    }

    Context 'Send-WatchdogMail via SMTP' {

        BeforeAll {
            $script:Config = Get-WatchdogConfig -Environment (New-TestEnvironment -Provider 'Smtp' -Overrides @{
                WATCHDOG_SMTP_PORT = '2525'
            })
        }

        BeforeEach {
            $script:FakeSmtpClient = [pscustomobject]@{
                Host        = $null
                Port        = 0
                EnableSsl   = $false
                Credentials = $null
                Timeout     = 0
                Sent        = [System.Collections.ArrayList]::new()
            }
            # Snapshot what matters at send time: the module disposes the message afterwards.
            $script:FakeSmtpClient | Add-Member -MemberType ScriptMethod -Name Send -Value {
                param($Message)
                $null = $this.Sent.Add(@{
                        Subject            = $Message.Subject
                        From               = $Message.From.Address
                        ToCount            = $Message.To.Count
                        Body               = $Message.Body
                        AlternateViewCount = $Message.AlternateViews.Count
                        HtmlViewMediaType  = $Message.AlternateViews[0].ContentType.MediaType
                    })
            }
            # The mock body runs in the module scope; a closure hands it the fake client. The
            # factory arguments are asserted with a parameter filter because a closure cannot see
            # the mock's bound parameters.
            $fake = $script:FakeSmtpClient
            Mock -ModuleName $script:ModuleName New-WatchdogSmtpClient ({ return $fake }.GetNewClosure())
        }

        It 'configures the client with host, port, STARTTLS and credentials and sends the message' {
            $result = Send-WatchdogMail -Config $script:Config -Subject 'Subj' -TextBody 'Text' -HtmlBody '<p>Html</p>'
            $result.Sent | Should -BeTrue

            Should -Invoke -ModuleName $script:ModuleName New-WatchdogSmtpClient -Times 1 -Exactly -ParameterFilter {
                $SmtpHost -eq 'mail.example.com' -and $Port -eq 2525
            }
            $client = $script:FakeSmtpClient
            $client.EnableSsl | Should -BeTrue
            $client.Credentials.UserName | Should -Be 'smtp-user'
            $client.Credentials.Password | Should -Be 'unit-test-smtp-password'
            $client.Timeout | Should -Be 20000
            $client.Sent.Count | Should -Be 1
            $message = $client.Sent[0]
            $message.Subject | Should -Be 'Subj'
            $message.From | Should -Be 'alerts@example.com'
            $message.ToCount | Should -Be 2
            $message.Body | Should -Be 'Text'
            $message.AlternateViewCount | Should -Be 1
            $message.HtmlViewMediaType | Should -Be 'text/html'
        }

        It 'returns an error when the client throws' {
            $script:FakeSmtpClient | Add-Member -MemberType ScriptMethod -Name Send -Force -Value {
                throw 'Mailbox unavailable'
            }
            $result = Send-WatchdogMail -Config $script:Config -Subject 'S' -TextBody 'T' -HtmlBody 'H'
            $result.Sent | Should -BeFalse
            $result.Error | Should -BeLike '*Mailbox unavailable*'
        }
    }

    Context 'Test-WatchdogRateLimit' {

        It 'allows six alerts and denies the seventh inside an hour' {
            $hostKey = "RL-$([guid]::NewGuid())"
            $now = [datetime]::new(2026, 9, 4, 12, 0, 0, [DateTimeKind]::Utc)
            foreach ($i in 1..6) {
                Test-WatchdogRateLimit -HostKey $hostKey -Limit 6 -NowUtc $now.AddMinutes($i) | Should -BeTrue
            }
            Test-WatchdogRateLimit -HostKey $hostKey -Limit 6 -NowUtc $now.AddMinutes(7) | Should -BeFalse
        }

        It 'slides the window so old entries expire' {
            $hostKey = "RL-$([guid]::NewGuid())"
            $now = [datetime]::new(2026, 9, 4, 12, 0, 0, [DateTimeKind]::Utc)
            foreach ($i in 1..6) {
                $null = Test-WatchdogRateLimit -HostKey $hostKey -Limit 6 -NowUtc $now.AddMinutes($i)
            }
            Test-WatchdogRateLimit -HostKey $hostKey -Limit 6 -NowUtc $now.AddMinutes(30) | Should -BeFalse
            Test-WatchdogRateLimit -HostKey $hostKey -Limit 6 -NowUtc $now.AddMinutes(62) | Should -BeTrue
        }

        It 'keeps an independent window per host key' {
            $first = "RL-$([guid]::NewGuid())"
            $second = "RL-$([guid]::NewGuid())"
            $now = [datetime]::UtcNow
            foreach ($i in 1..2) {
                $null = Test-WatchdogRateLimit -HostKey $first -Limit 2 -NowUtc $now
            }
            Test-WatchdogRateLimit -HostKey $first -Limit 2 -NowUtc $now | Should -BeFalse
            Test-WatchdogRateLimit -HostKey $second -Limit 2 -NowUtc $now | Should -BeTrue
        }
    }

    Context 'Test-WatchdogGlobalRateLimit' {

        BeforeAll {
            $script:Config = Get-WatchdogConfig -Environment (New-TestEnvironment)
            $script:Now = [datetime]::new(2026, 9, 4, 18, 40, 0, [DateTimeKind]::Utc)
        }

        BeforeEach {
            Mock -ModuleName $script:ModuleName Get-WatchdogStorageToken { 'test-bearer-token' }
            Mock -ModuleName $script:ModuleName Write-WatchdogLog { }
        }

        It 'creates the hourly counter row without If-Match when none exists and allows the email' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                if ($Method -eq 'Get') { return (New-TableResponse -StatusCode 404) }
                return (New-TableResponse -StatusCode 204)
            }
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $script:Now | Should -BeTrue
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Put' -and
                $Uri -like "*WatchdogSentEvents(PartitionKey='_RateLimit',RowKey='2026090418')" -and
                -not $Headers.ContainsKey('If-Match') -and
                ($Body | ConvertFrom-Json).Count -eq 1
            }
        }

        It 'increments an existing counter with the ETag as If-Match' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                if ($Method -eq 'Get') {
                    return [pscustomobject]@{
                        StatusCode = 200
                        Headers    = @{ ETag = @('W/"datetime''2026-09-04T18%3A39%3A00Z''"') }
                        Content    = '{"PartitionKey":"_RateLimit","RowKey":"2026090418","Count":41}'
                    }
                }
                return (New-TableResponse -StatusCode 204)
            }
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $script:Now | Should -BeTrue
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Put' -and
                $Headers['If-Match'] -eq 'W/"datetime''2026-09-04T18%3A39%3A00Z''"' -and
                ($Body | ConvertFrom-Json).Count -eq 42
            }
        }

        It 'refuses the email without writing once the hourly count has reached the limit' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                if ($Method -eq 'Get') {
                    return (New-TableResponse -StatusCode 200 -Content '{"Count":60}')
                }
                return (New-TableResponse -StatusCode 204)
            }
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $script:Now | Should -BeFalse
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 0 -Exactly -ParameterFilter {
                $Method -eq 'Put'
            }
        }

        It 're-reads after a 412 conflict and refuses after three conflicting attempts' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                if ($Method -eq 'Get') {
                    return (New-TableResponse -StatusCode 200 -Content '{"Count":5}')
                }
                return (New-TableResponse -StatusCode 412)
            }
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $script:Now | Should -BeFalse
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 3 -Exactly -ParameterFilter {
                $Method -eq 'Put'
            }
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*conflicting attempts*'
            }
        }

        It 'succeeds on the retry after a single 412 conflict' {
            $script:PutCalls = 0
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                if ($Method -eq 'Get') {
                    return (New-TableResponse -StatusCode 200 -Content '{"Count":5}')
                }
                $script:PutCalls++
                if ($script:PutCalls -eq 1) { return (New-TableResponse -StatusCode 412) }
                return (New-TableResponse -StatusCode 204)
            }
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $script:Now | Should -BeTrue
            $script:PutCalls | Should -Be 2
        }

        It 'allows the email with a warning when the table is unreachable or answers unexpectedly' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { throw 'connection refused' }
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $script:Now | Should -BeTrue

            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-TableResponse -StatusCode 503 }
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $script:Now | Should -BeTrue

            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                if ($Method -eq 'Get') { return (New-TableResponse -StatusCode 404) }
                return (New-TableResponse -StatusCode 500)
            }
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $script:Now | Should -BeTrue
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -Times 3 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*allowing the email*'
            }
        }

        It 'keys the counter on the UTC clock hour' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                if ($Method -eq 'Get') { return (New-TableResponse -StatusCode 404) }
                return (New-TableResponse -StatusCode 204)
            }
            $local = [datetime]::new(2026, 9, 4, 23, 30, 0, [DateTimeKind]::Utc)
            Test-WatchdogGlobalRateLimit -Config $script:Config -Limit 60 -NowUtc $local | Should -BeTrue
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Get' -and $Uri -like "*RowKey='2026090423')"
            }
        }
    }

    Context 'Get-WatchdogStorageToken' {

        BeforeEach {
            InModuleScope $script:ModuleName { $script:StorageToken = $null }
            $script:IdentityEnvironment = @{
                IDENTITY_ENDPOINT = 'http://127.0.0.1:41000/msi/token'
                IDENTITY_HEADER   = 'identity-header-value'
            }
        }

        AfterAll {
            InModuleScope $script:ModuleName { $script:StorageToken = $null }
        }

        It 'requests a token for storage with the identity header and caches it' {
            $expiresOn = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
            Mock -ModuleName $script:ModuleName Invoke-RestMethod {
                [pscustomobject]@{ access_token = 'token-a'; expires_on = "$expiresOn"; token_type = 'Bearer' }
            }
            Get-WatchdogStorageToken -Environment $script:IdentityEnvironment | Should -Be 'token-a'
            Get-WatchdogStorageToken -Environment $script:IdentityEnvironment | Should -Be 'token-a'
            Should -Invoke -ModuleName $script:ModuleName Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -like 'http://127.0.0.1:41000/msi/token?*resource=https%3A%2F%2Fstorage.azure.com%2F*' -and
                $Uri -like '*api-version=2019-08-01*' -and
                $Headers['X-IDENTITY-HEADER'] -eq 'identity-header-value'
            }
        }

        It 'fetches a new token when the cached one is within five minutes of expiry' {
            $nearExpiry = [DateTimeOffset]::UtcNow.AddMinutes(4).ToUnixTimeSeconds()
            Mock -ModuleName $script:ModuleName Invoke-RestMethod {
                [pscustomobject]@{ access_token = 'token-b'; expires_on = "$nearExpiry"; token_type = 'Bearer' }
            }
            $null = Get-WatchdogStorageToken -Environment $script:IdentityEnvironment
            $null = Get-WatchdogStorageToken -Environment $script:IdentityEnvironment
            Should -Invoke -ModuleName $script:ModuleName Invoke-RestMethod -Times 2 -Exactly
        }

        It 'throws when the managed identity endpoint is not available' {
            { Get-WatchdogStorageToken -Environment @{} } | Should -Throw -ExpectedMessage '*IDENTITY_ENDPOINT*'
        }
    }

    Context 'Table REST helpers' {

        BeforeAll {
            $script:Config = Get-WatchdogConfig -Environment (New-TestEnvironment)
            $script:Now = [datetime]::new(2026, 9, 4, 19, 30, 0, [DateTimeKind]::Utc)
            Mock -ModuleName $script:ModuleName Get-WatchdogStorageToken { 'test-bearer-token' }
        }

        It 'Set-WatchdogHostEntity issues an Insert Or Replace PUT with the required headers and encoded keys' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-TableResponse -StatusCode 204 }
            $payload = New-TestPayload -Overrides @{ SiteName = 'Example Org & Co/#?'; HostName = 'srv-example-01' }

            Set-WatchdogHostEntity -Config $script:Config -Payload $payload -NowUtc $script:Now

            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                # ConvertFrom-Json would turn LastSeenUtc into a DateTime, so the raw JSON text is checked.
                $entity = $Body | ConvertFrom-Json
                $Method -eq 'Put' -and
                $Uri -eq ($script:TableEndpoint +
                    "WatchdogHosts(PartitionKey='Example%20Org%20_%20Co___',RowKey='SRV-EXAMPLE-01')") -and
                $Headers['Authorization'] -eq 'Bearer test-bearer-token' -and
                $Headers['x-ms-version'] -eq '2020-12-06' -and
                $Headers['x-ms-date'] -match 'GMT$' -and
                $Headers['Accept'] -eq 'application/json;odata=nometadata' -and
                $Headers['DataServiceVersion'] -eq '3.0;NetFx' -and
                $Headers['MaxDataServiceVersion'] -eq '3.0;NetFx' -and
                $ContentType -eq 'application/json' -and
                $TimeoutSec -eq 10 -and
                -not $Headers.ContainsKey('If-Match') -and
                $entity.PartitionKey -eq 'Example Org _ Co___' -and
                $entity.RowKey -eq 'SRV-EXAMPLE-01' -and
                $Body -like '*"LastSeenUtc":"2026-09-04T19:30:00Z"*' -and
                $entity.LastEventType -eq 'alert'
            }
        }

        It 'doubles a single quote in a key literal and encodes the rest' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-TableResponse -StatusCode 404 }
            $null = Test-WatchdogSentEvent -Config $script:Config -HostKey "O'NEIL 1" -EventId 'e1'
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq ($script:TableEndpoint + "WatchdogSentEvents(PartitionKey='O''NEIL%201',RowKey='e1')")
            }
        }

        It 'Set-WatchdogHostEntity logs a warning on 403 and does not throw' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                New-TableResponse -StatusCode 403 -Content '{"odata.error":{}}'
            }
            { Set-WatchdogHostEntity -Config $script:Config -Payload (New-TestPayload) -NowUtc $script:Now } |
                Should -Not -Throw
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*403*'
            }
        }

        It 'Set-WatchdogHostEntity logs a warning when the token cannot be obtained and does not throw' {
            Mock -ModuleName $script:ModuleName Get-WatchdogStorageToken { throw 'IDENTITY_ENDPOINT is not set' }
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-TableResponse -StatusCode 204 }
            { Set-WatchdogHostEntity -Config $script:Config -Payload (New-TestPayload) -NowUtc $script:Now } |
                Should -Not -Throw
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*IDENTITY_ENDPOINT*'
            }
        }

        It 'Test-WatchdogSentEvent returns true on 200' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                New-TableResponse -StatusCode 200 -Content '{"PartitionKey":"SRV-EXAMPLE-01"}'
            }
            Test-WatchdogSentEvent -Config $script:Config -HostKey 'SRV-EXAMPLE-01' -EventId $script:EventId |
                Should -BeTrue
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'Get' -and
                $Uri -eq ($script:TableEndpoint +
                    "WatchdogSentEvents(PartitionKey='SRV-EXAMPLE-01',RowKey='$($script:EventId)')")
            }
        }

        It 'Test-WatchdogSentEvent returns false on 404 without a warning' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest {
                New-TableResponse -StatusCode 404 -Content '{"odata.error":{}}'
            }
            Test-WatchdogSentEvent -Config $script:Config -HostKey 'SRV-EXAMPLE-01' -EventId 'e1' | Should -BeFalse
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -Times 0 -Exactly -ParameterFilter {
                $Level -eq 'Warning'
            }
        }

        It 'Test-WatchdogSentEvent returns false with a warning on other errors' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-TableResponse -StatusCode 500 }
            Test-WatchdogSentEvent -Config $script:Config -HostKey 'SRV-EXAMPLE-01' -EventId 'e1' | Should -BeFalse
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*500*'
            }
        }

        It 'Test-WatchdogSentEvent returns false with a warning when the request throws' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { throw 'connection refused' }
            Test-WatchdogSentEvent -Config $script:Config -HostKey 'SRV-EXAMPLE-01' -EventId 'e1' | Should -BeFalse
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*connection refused*'
            }
        }

        It 'Set-WatchdogSentEvent writes the dedup row with sent time, event type and provider id' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-TableResponse -StatusCode 204 }
            $payload = New-TestPayload -EventType 'flapping'
            Set-WatchdogSentEvent -Config $script:Config -HostKey 'SRV-EXAMPLE-01' -Payload $payload `
                -ProviderMessageId 'email-123' -NowUtc $script:Now
            Should -Invoke -ModuleName $script:ModuleName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $entity = $Body | ConvertFrom-Json
                $Method -eq 'Put' -and
                $Uri -eq ($script:TableEndpoint +
                    "WatchdogSentEvents(PartitionKey='SRV-EXAMPLE-01',RowKey='$($script:EventId)')") -and
                $entity.PartitionKey -eq 'SRV-EXAMPLE-01' -and
                $entity.RowKey -eq $script:EventId -and
                $Body -like '*"SentUtc":"2026-09-04T19:30:00Z"*' -and
                $entity.EventType -eq 'flapping' -and
                $entity.ProviderMessageId -eq 'email-123'
            }
        }

        It 'Set-WatchdogSentEvent tolerates a null provider id and a failing write' {
            Mock -ModuleName $script:ModuleName Invoke-WebRequest { New-TableResponse -StatusCode 500 }
            {
                Set-WatchdogSentEvent -Config $script:Config -HostKey 'SRV-EXAMPLE-01' -Payload (New-TestPayload) `
                    -ProviderMessageId $null
            } | Should -Not -Throw
            Should -Invoke -ModuleName $script:ModuleName Write-WatchdogLog -ParameterFilter { $Level -eq 'Warning' }
        }
    }

    Context 'ConvertTo-WatchdogHostEntity' {

        BeforeAll {
            $script:Now = [datetime]::new(2026, 9, 4, 19, 30, 0, [DateTimeKind]::Utc)
        }

        It 'uses the injected receipt time for LastSeenUtc, never the payload timestamp' {
            $entity = ConvertTo-WatchdogHostEntity -Payload (New-TestPayload) -NowUtc $script:Now
            $entity.LastSeenUtc | Should -Be '2026-09-04T19:30:00Z'
            $entity.LastSeenUtc | Should -Not -Be '2026-09-04T18:05:02Z'
        }

        It 'sanitizes the keys and counts monitored and problem services' {
            $services = @(
                (New-TestService -Overrides @{ Name = 'A'; Status = 'Failed' })
                (New-TestService -Overrides @{ Name = 'B'; Status = 'Missing' })
                (New-TestService -Overrides @{ Name = 'C'; Status = 'Disabled' })
                (New-TestService -Overrides @{ Name = 'D'; Status = 'Healthy' })
                (New-TestService -Overrides @{ Name = 'E'; Status = 'Recovered' })
            )
            $payload = New-TestPayload -Overrides @{ SiteName = 'Example Org/#?'; HostName = 'srv-example-01' } `
                -Services $services
            $entity = ConvertTo-WatchdogHostEntity -Payload $payload -NowUtc $script:Now
            $entity.PartitionKey | Should -Be 'Example Org___'
            $entity.RowKey | Should -Be 'SRV-EXAMPLE-01'
            $entity.LastEventType | Should -Be 'alert'
            $entity.WatchdogVersion | Should -Be '1.0.0'
            $entity.MonitoredServiceCount | Should -Be 5
            $entity.ProblemServiceCount | Should -Be 3
        }

        It 'counts 0/0 for a payload with no services (heartbeat from an empty list)' {
            $payload = New-TestPayload -EventType 'heartbeat' -Services @()
            $entity = ConvertTo-WatchdogHostEntity -Payload $payload -NowUtc $script:Now
            $entity.MonitoredServiceCount | Should -Be 0
            $entity.ProblemServiceCount | Should -Be 0
        }

        It 'defaults to the current UTC time when -NowUtc is omitted' {
            $before = [datetime]::UtcNow.AddSeconds(-1)
            $entity = ConvertTo-WatchdogHostEntity -Payload (New-TestPayload)
            $styles = 'AssumeUniversal, AdjustToUniversal'
            $seen = [datetime]::ParseExact($entity.LastSeenUtc, 'yyyy-MM-ddTHH:mm:ssZ', $null, $styles)
            $seen | Should -BeGreaterOrEqual $before
        }
    }

    Context 'Get-WatchdogStaleHosts' {

        BeforeAll {
            $script:Now = [datetime]::new(2026, 9, 5, 7, 0, 0, [DateTimeKind]::Utc)
        }

        It 'separates rows older than the threshold from fresh ones' {
            $rows = @(
                @{ PartitionKey = 'Example Org'; RowKey = 'SRV-OLD'; LastSeenUtc = '2026-09-03T06:00:00Z' }
                @{ PartitionKey = 'Example Org'; RowKey = 'SRV-NEW'; LastSeenUtc = '2026-09-05T06:30:00Z' }
            )
            $result = Get-WatchdogStaleHosts -Rows $rows -StaleHours 26 -NowUtc $script:Now
            @($result.Stale).Count | Should -Be 1
            $result.Stale[0].HostName | Should -Be 'SRV-OLD'
            $result.Stale[0].SiteName | Should -Be 'Example Org'
            $result.Stale[0].AgeHours | Should -Be 49
            @($result.Fresh).Count | Should -Be 1
            $result.Fresh[0].HostName | Should -Be 'SRV-NEW'
        }

        It 'compares the exact age, so a host 26h02m old is stale against 26 hours even though it rounds to 26.0' {
            $rows = @(@{ PartitionKey = 'Example Org'; RowKey = 'SRV-EDGE'; LastSeenUtc = '2026-09-04T04:58:00Z' })
            $result = Get-WatchdogStaleHosts -Rows $rows -StaleHours 26 -NowUtc $script:Now
            @($result.Stale).Count | Should -Be 1
            $result.Stale[0].AgeHours | Should -Be 26
        }

        It 'treats a row exactly at the threshold as fresh' {
            $rows = @(@{ PartitionKey = 'Example Org'; RowKey = 'SRV-EDGE'; LastSeenUtc = '2026-09-04T05:00:00Z' })
            $result = Get-WatchdogStaleHosts -Rows $rows -StaleHours 26 -NowUtc $script:Now
            @($result.Stale).Count | Should -Be 0
            @($result.Fresh).Count | Should -Be 1
        }

        It 'returns two empty sets for no rows' {
            $result = Get-WatchdogStaleHosts -Rows @() -StaleHours 26 -NowUtc $script:Now
            @($result.Stale).Count | Should -Be 0
            @($result.Fresh).Count | Should -Be 0
        }

        It 'accepts rows whose LastSeenUtc is already a DateTime' {
            $lastSeen = [datetime]::new(2026, 9, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $rows = @(@{ PartitionKey = 'Example Org'; RowKey = 'SRV-DT'; LastSeenUtc = $lastSeen })
            $result = Get-WatchdogStaleHosts -Rows $rows -StaleHours 26 -NowUtc $script:Now
            @($result.Stale).Count | Should -Be 1
        }

        It 'treats a row with an unreadable LastSeenUtc as stale' {
            $rows = @(@{ PartitionKey = 'Example Org'; RowKey = 'SRV-BAD'; LastSeenUtc = 'never' })
            $result = Get-WatchdogStaleHosts -Rows $rows -StaleHours 26 -NowUtc $script:Now
            @($result.Stale).Count | Should -Be 1
            $result.Stale[0].AgeHours | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-WatchdogKey' {

        It 'replaces every character outside the safe set with an underscore' {
            ConvertTo-WatchdogKey -Value 'Example Org/#?' | Should -Be 'Example Org___'
        }

        It 'upper-cases when requested' {
            ConvertTo-WatchdogKey -Value 'srv-example-01.example.com' -Upper | Should -Be 'SRV-EXAMPLE-01.EXAMPLE.COM'
        }

        It 'trims to 64 characters' {
            (ConvertTo-WatchdogKey -Value ('a' * 100)).Length | Should -Be 64
        }

        It 'keeps letters, digits, dot, underscore, space and hyphen' {
            ConvertTo-WatchdogKey -Value 'A z0.9_ -' | Should -Be 'A z0.9_ -'
        }
    }
}

Describe 'Write-WatchdogLog' {

    BeforeAll {
        Mock -ModuleName $script:ModuleName Write-Information { }
        Mock -ModuleName $script:ModuleName Write-Warning { }
        Mock -ModuleName $script:ModuleName Write-Error { }
    }

    It 'writes an Information line carrying run id and host name' {
        Write-WatchdogLog -Message 'Hello' -Level Information -RunId 'run-1' -HostName 'SRV-EXAMPLE-01'
        Should -Invoke -ModuleName $script:ModuleName Write-Information -Times 1 -Exactly -ParameterFilter {
            $MessageData -like '*run-1*' -and $MessageData -like '*SRV-EXAMPLE-01*' -and $MessageData -like '*Hello*'
        }
    }

    It 'routes Warning to the warning stream' {
        Write-WatchdogLog -Message 'Careful' -Level Warning -RunId 'run-1'
        Should -Invoke -ModuleName $script:ModuleName Write-Warning -Times 1 -Exactly -ParameterFilter {
            $Message -like '*Careful*'
        }
    }

    It 'routes Error to the error stream without throwing' {
        { Write-WatchdogLog -Message 'Broken' -Level Error -RunId 'run-1' } | Should -Not -Throw
        Should -Invoke -ModuleName $script:ModuleName Write-Error -Times 1 -Exactly -ParameterFilter {
            $Message -like '*Broken*'
        }
    }

    It 'defaults to Information and tolerates a missing host name' {
        Write-WatchdogLog -Message 'Plain' -RunId 'run-1'
        Should -Invoke -ModuleName $script:ModuleName Write-Information -Times 1 -Exactly -ParameterFilter {
            $MessageData -like '*Plain*'
        }
    }
}
