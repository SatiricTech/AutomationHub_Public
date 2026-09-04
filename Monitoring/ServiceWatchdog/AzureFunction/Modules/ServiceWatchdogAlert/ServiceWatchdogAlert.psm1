#Requires -Version 7.4

<#
.SYNOPSIS
    Configuration, validation, rendering, mail provider and Table storage helpers for the
    ServiceWatchdog Azure Function app.

.DESCRIPTION
    This module is bundled with the function app (AzureFunction/Modules) and is the only
    dependency of SendServiceWatchdogAlert/run.ps1 and SendServiceWatchdogDigest/run.ps1.
    It implements DESIGN.md sections 6.2 and 6.3:

      - Get-WatchdogConfig          reads the WATCHDOG_* app settings, applies defaults and
                                    enforces the Key Vault startup guard
      - Test-WatchdogPayload        validates an alert payload against the 4.8 contract
      - ConvertTo-WatchdogEmail     renders subject, plain-text and HTML bodies
      - Send-WatchdogMail           dispatches to SMTP2GO (REST) or an SMTP relay
      - Test-WatchdogRateLimit      per-host sliding-window rate limit (module scope)
      - Get-WatchdogStorageToken    managed-identity bearer token for Table storage, cached
      - Set-WatchdogHostEntity      insert-or-replace of the WatchdogHosts row
      - Test-WatchdogSentEvent /    read and write of the WatchdogSentEvents dedup row
        Set-WatchdogSentEvent
      - ConvertTo-WatchdogHostEntity, Get-WatchdogStaleHosts, ConvertTo-WatchdogKey
      - Write-WatchdogLog           structured log line for Application Insights

    Every network call goes through Invoke-WebRequest or Invoke-RestMethod so tests can mock
    it inside the module scope. No Az module is used; storage is reached through the Table
    REST API with a managed-identity token and mail through plain HTTPS or SMTP.

.NOTES
    Version : 1.0.0
    Created : 2026-09-04

    Checklist deviations from the powershell-authoring skill (Enterprise tier):
      - 2.1/2.2/2.3/2.4 (-Verbosity, -DryRun, Invoke-Action): this module runs inside the
        Azure Functions PowerShell worker, which owns the invocation contract. There is no
        console to gate and no operator invoking it interactively, so the Verbosity and
        DryRun switches are not implemented; the endpoint worker's -TestAlert is the
        supported way to exercise the mail path end to end.
      - 4.2/4.6/4.7 (Write-Log and the file log under $env:ProgramData): the worker has no
        durable local filesystem. Write-WatchdogLog writes structured lines to the
        Information/Warning/Error streams, which the Functions host forwards to Application
        Insights with the invocation id attached.
      - 5.2 (SecretManagement): secrets arrive as Key Vault references resolved into app
        settings by the platform; the module refuses to run with an unresolved reference.
      - 5.7 (code signing): shipped unsigned in the public repository.
      - 6.6/6.7: the operator acceptance run in DESIGN.md section 9 is the integration test;
        run time is bounded by the mail and table timeouts and the host functionTimeout.

    Developed with AI assistance (Claude); reviewed before publication.
#>

#region Configuration

$script:ModuleVersion = '1.0.0'
$script:TimestampFormat = 'yyyy-MM-ddTHH:mm:ssZ'
$script:TimestampPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
$script:HostNamePattern = '^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}$'
$script:KeyVaultReferencePrefix = '@Microsoft.KeyVault('
$script:MaxPayloadBytes = 256 * 1024
$script:MaxServices = 100
$script:MaxStringLength = 256
$script:MaxSummaryLength = 512
$script:MaxLastErrorLength = 1000
$script:MaxKeyLength = 64
$script:AllowedEventTypes = @('alert', 'flapping', 'reminder', 'recovered', 'remediated', 'test', 'heartbeat')
$script:AllowedStatuses = @('Healthy', 'Failed', 'Missing', 'Disabled', 'Unknown', 'Recovered', 'Remediated')
$script:AllowedStartTypes = @('Boot', 'System', 'Automatic', 'AutomaticDelayedStart', 'Manual', 'Disabled', 'Unknown')
$script:ProblemStatuses = @('Failed', 'Missing', 'Disabled')
$script:AllowedTopLevelKeys = @(
    'SchemaVersion', 'EventType', 'EventId', 'SiteName', 'HostName', 'Fqdn', 'TimestampUtc', 'RunId',
    'WatchdogVersion', 'Summary', 'Services'
)
$script:TableApiVersion = '2020-12-06'
$script:TableTimeoutSeconds = 10
$script:HostsTable = 'WatchdogHosts'
$script:SentEventsTable = 'WatchdogSentEvents'
$script:StorageResource = 'https://storage.azure.com/'
$script:TokenRefreshMarginMinutes = 5
$script:Smtp2GoRetryDelays = @(2, 5)
$script:Smtp2GoMaxRetryAfterSeconds = 30
$script:Smtp2GoMaxAttempts = 3

# Module-scope caches. Both are best effort and per worker process (DESIGN.md section 8).
$script:RateLimitWindows = @{}
$script:StorageToken = $null

#endregion

#region Helper Functions

function Get-WatchdogField {
    <#
    .SYNOPSIS
        Reads a named field from a hashtable-like or object-like value, or returns $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param (
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }
    return $null
}

function Test-WatchdogFieldPresent {
    <#
    .SYNOPSIS
        Returns $true when the field exists on the object, even if its value is null.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return [bool]$Object.Contains($Name)
    }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-WatchdogInteger {
    <#
    .SYNOPSIS
        Returns $true for integral numeric values as produced by the JSON deserializer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [AllowNull()]
        [object]$Value
    )

    return ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte])
}

function Test-WatchdogTimestamp {
    <#
    .SYNOPSIS
        Returns $true for a timestamp in the exact yyyy-MM-ddTHH:mm:ssZ form (DESIGN.md 4.4).

    .DESCRIPTION
        The Functions worker deserializes JSON before run.ps1 sees it and turns any ISO 8601
        string into a [datetime]. A value that arrived with the Z suffix has Kind Utc; one
        without it does not. A [datetime] is therefore accepted only when its Kind is Utc
        and it carries no fractional seconds, which is exactly what the string form allows.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [datetime]) {
        return ($Value.Kind -eq [DateTimeKind]::Utc -and ($Value.Ticks % [TimeSpan]::TicksPerSecond) -eq 0)
    }
    if ($Value -isnot [string] -or $Value -notmatch $script:TimestampPattern) {
        return $false
    }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal
    return [datetime]::TryParseExact(
        $Value, $script:TimestampFormat, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed
    )
}

function ConvertTo-WatchdogTimestamp {
    <#
    .SYNOPSIS
        Formats a [datetime] (or passes through a string) as yyyy-MM-ddTHH:mm:ssZ.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [datetime]) {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        return $Value.ToUniversalTime().ToString($script:TimestampFormat, $culture)
    }
    return [string]$Value
}

function ConvertFrom-WatchdogTimestamp {
    <#
    .SYNOPSIS
        Parses a stored timestamp (string or [datetime]) into a UTC [datetime], or $null.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime()
    }
    if ($Value -is [System.DateTimeOffset]) {
        return $Value.UtcDateTime
    }
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ([datetime]::TryParseExact([string]$Value, $script:TimestampFormat, $culture, $styles, [ref]$parsed)) {
        return $parsed
    }
    if ([datetime]::TryParse([string]$Value, $culture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-WatchdogSetting {
    <#
    .SYNOPSIS
        Reads one app setting from the environment hashtable, returning the default when
        the value is missing or blank.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Environment,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($Environment.ContainsKey($Name)) {
        $value = [string]$Environment[$Name]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }
    return $Default
}

function ConvertTo-WatchdogSettingInt {
    <#
    .SYNOPSIS
        Converts a setting value to [int], throwing a message that names the setting.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed)) {
        throw "App setting $Name must be an integer (got '$Value')"
    }
    return $parsed
}

function ConvertTo-WatchdogSettingBool {
    <#
    .SYNOPSIS
        Converts a setting value to [bool], throwing a message that names the setting.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in 'true', '1', 'yes' } { return $true }
        { $_ -in 'false', '0', 'no' } { return $false }
        default { throw "App setting $Name must be true or false (got '$Value')" }
    }
}

function ConvertTo-WatchdogSettingList {
    <#
    .SYNOPSIS
        Splits a semicolon-separated setting into trimmed, non-empty entries.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return , [string[]]@()
    }
    $entries = @($Value.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return , [string[]]$entries
}

function ConvertTo-WatchdogSingleLine {
    <#
    .SYNOPSIS
        Strips CR and LF so a value can never inject a header into the subject line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ''
    }
    return ($Value -replace '[\r\n]', '')
}

function ConvertTo-WatchdogDisplayValue {
    <#
    .SYNOPSIS
        Renders a nullable payload value for display, using '-' for null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return '-'
    }
    if ($Value -is [datetime]) {
        return (ConvertTo-WatchdogTimestamp -Value $Value)
    }
    return [string]$Value
}

function ConvertTo-WatchdogHtml {
    <#
    .SYNOPSIS
        HTML-encodes a display value. Every payload field in the HTML body passes through here.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Value
    )

    return [System.Net.WebUtility]::HtmlEncode((ConvertTo-WatchdogDisplayValue -Value $Value))
}

function Get-WatchdogHeaderValue {
    <#
    .SYNOPSIS
        Reads one response header from an Invoke-WebRequest result (values may be arrays).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Headers,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Headers) {
        return $null
    }
    $value = $null
    try {
        $value = $Headers[$Name]
    }
    catch {
        return $null
    }
    if ($null -eq $value) {
        return $null
    }
    return [string](@($value)[0])
}

function ConvertFrom-WatchdogSmtp2GoContent {
    <#
    .SYNOPSIS
        Parses an SMTP2GO response body and returns its data object (data or email_response).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }
    try {
        $parsed = $Content | ConvertFrom-Json
    }
    catch {
        return $null
    }
    # Older SMTP2GO SDK generations name the inner object email_response instead of data.
    foreach ($name in 'data', 'email_response') {
        $property = $parsed.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function New-WatchdogMailResult {
    <#
    .SYNOPSIS
        Builds the provider result hashtable returned by Send-WatchdogMail.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Builds an in-memory result object; it changes no state.'
    )]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [bool]$Sent,

        [AllowNull()]
        [string]$ProviderMessageId,

        [AllowNull()]
        [string]$Error,

        [AllowNull()]
        [System.Nullable[int]]$StatusCode
    )

    return @{
        Sent              = $Sent
        ProviderMessageId = $ProviderMessageId
        Error             = $Error
        StatusCode        = $StatusCode
    }
}

function Send-WatchdogMailSmtp2Go {
    <#
    .SYNOPSIS
        Sends the message through the SMTP2GO REST API with bounded retries.

    .DESCRIPTION
        POSTs to WATCHDOG_SMTP2GO_API_URL with the X-Smtp2go-Api-Key header. Success means
        data.succeeded >= 1; when data.failed > 0 alongside a success the failures are logged
        as a warning and the result is still Sent. 429 and 5xx are retried up to two more
        times (2 s, then 5 s, or the Retry-After header capped at 30 s). Other 4xx responses
        and transport errors (including timeouts) are returned without retry.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Subject,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$TextBody,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$HtmlBody
    )

    $requestBody = @{
        sender    = $Config.MailFrom
        to        = @($Config.MailTo)
        subject   = $Subject
        text_body = $TextBody
        html_body = $HtmlBody
    } | ConvertTo-Json -Depth 3 -Compress
    $headers = @{
        'X-Smtp2go-Api-Key' = $Config.Smtp2GoApiKey
        'Accept'            = 'application/json'
    }

    for ($attempt = 1; $attempt -le $script:Smtp2GoMaxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Method Post -Uri $Config.Smtp2GoApiUrl -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body $requestBody `
                -TimeoutSec $Config.MailTimeoutSeconds -SkipHttpErrorCheck -UseBasicParsing
        }
        catch {
            $message = "SMTP2GO request failed on attempt ${attempt}: $($_.Exception.Message)"
            Write-WatchdogLog -Message $message -Level Error
            return (New-WatchdogMailResult -Sent $false -Error $message)
        }

        $statusCode = [int]$response.StatusCode
        $data = ConvertFrom-WatchdogSmtp2GoContent -Content ([string]$response.Content)

        if ($statusCode -eq 200) {
            $succeeded = 0
            $failed = 0
            if ($null -ne $data) {
                $succeeded = [int](Get-WatchdogField -Object $data -Name 'succeeded')
                $failed = [int](Get-WatchdogField -Object $data -Name 'failed')
            }
            $emailId = [string](Get-WatchdogField -Object $data -Name 'email_id')
            if ($failed -gt 0) {
                $failures = @(Get-WatchdogField -Object $data -Name 'failures') -join '; '
                Write-WatchdogLog -Level Warning -Message ("SMTP2GO accepted $succeeded recipient(s) and rejected " +
                    "${failed}: $failures")
            }
            if ($succeeded -ge 1) {
                return (New-WatchdogMailResult -Sent $true -ProviderMessageId $emailId -StatusCode $statusCode)
            }
            $message = "SMTP2GO accepted the request but delivered to no recipient (failed=$failed)"
            Write-WatchdogLog -Message $message -Level Error
            return (New-WatchdogMailResult -Sent $false -Error $message -StatusCode $statusCode)
        }

        $providerError = [string](Get-WatchdogField -Object $data -Name 'error')
        if ([string]::IsNullOrWhiteSpace($providerError)) {
            $providerError = "HTTP $statusCode"
        }
        $retryable = ($statusCode -eq 429 -or $statusCode -ge 500)
        if ($retryable -and $attempt -lt $script:Smtp2GoMaxAttempts) {
            $delay = $script:Smtp2GoRetryDelays[$attempt - 1]
            $retryAfter = Get-WatchdogHeaderValue -Headers $response.Headers -Name 'Retry-After'
            $retryAfterSeconds = 0
            $hasRetryAfter = $null -ne $retryAfter -and [int]::TryParse($retryAfter, [ref]$retryAfterSeconds)
            if ($hasRetryAfter -and $retryAfterSeconds -gt 0) {
                $delay = [math]::Min($retryAfterSeconds, $script:Smtp2GoMaxRetryAfterSeconds)
            }
            Write-WatchdogLog -Level Warning -Message ("SMTP2GO returned HTTP $statusCode ($providerError) on " +
                "attempt ${attempt}; retrying in $delay s")
            Start-Sleep -Seconds $delay
            continue
        }

        $message = "SMTP2GO returned HTTP ${statusCode}: $providerError"
        Write-WatchdogLog -Message $message -Level Error
        return (New-WatchdogMailResult -Sent $false -Error $message -StatusCode $statusCode)
    }
}

function New-WatchdogSmtpClient {
    <#
    .SYNOPSIS
        Factory for the SMTP client so tests can substitute a recording fake.

    .DESCRIPTION
        System.Net.Mail.SmtpClient negotiates STARTTLS when EnableSsl is true. Implicit TLS
        on port 465 is not supported by this client; use 587 or 2525 with STARTTLS.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Factory that constructs a client object; it changes no state until Send is called.'
    )]
    [CmdletBinding()]
    [OutputType([System.Net.Mail.SmtpClient])]
    param (
        [Parameter(Mandatory)]
        [string]$SmtpHost,

        [Parameter(Mandatory)]
        [int]$Port
    )

    return [System.Net.Mail.SmtpClient]::new($SmtpHost, $Port)
}

function Send-WatchdogMailSmtp {
    <#
    .SYNOPSIS
        Sends the message through an authenticated SMTP relay with STARTTLS.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Subject,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$TextBody,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$HtmlBody
    )

    $client = $null
    $message = $null
    try {
        $client = New-WatchdogSmtpClient -SmtpHost $Config.SmtpHost -Port $Config.SmtpPort
        $client.EnableSsl = [bool]$Config.SmtpUseStartTls
        $client.Credentials = [System.Net.NetworkCredential]::new($Config.SmtpUsername, $Config.SmtpPassword)
        $client.Timeout = [int]$Config.MailTimeoutSeconds * 1000

        $message = [System.Net.Mail.MailMessage]::new()
        $message.From = [System.Net.Mail.MailAddress]::new($Config.MailFrom)
        foreach ($recipient in @($Config.MailTo)) {
            $message.To.Add($recipient)
        }
        $message.Subject = $Subject
        $message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $message.Body = $TextBody
        $message.BodyEncoding = [System.Text.Encoding]::UTF8
        $message.IsBodyHtml = $false
        $htmlView = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString(
            $HtmlBody, [System.Text.Encoding]::UTF8, 'text/html'
        )
        $message.AlternateViews.Add($htmlView)

        $client.Send($message)
        return (New-WatchdogMailResult -Sent $true)
    }
    catch {
        $errorText = "SMTP send via $($Config.SmtpHost):$($Config.SmtpPort) failed: $($_.Exception.Message)"
        Write-WatchdogLog -Message $errorText -Level Error
        return (New-WatchdogMailResult -Sent $false -Error $errorText)
    }
    finally {
        foreach ($disposable in @($message, $client)) {
            if ($disposable -is [System.IDisposable]) {
                $disposable.Dispose()
            }
        }
    }
}

function ConvertTo-WatchdogTableKeyLiteral {
    <#
    .SYNOPSIS
        URL-encodes a table key for the entity address, keeping single quotes doubled.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Key
    )

    return ([Uri]::EscapeDataString($Key) -replace '%27', "''")
}

function Invoke-WatchdogTableRequest {
    <#
    .SYNOPSIS
        Issues one Table REST call for a single entity and returns its status and content.

    .DESCRIPTION
        Builds <endpoint><Table>(PartitionKey='<pk>',RowKey='<rk>') with the headers from
        DESIGN.md 6.3. A PUT without If-Match is Insert Or Replace. Throws on transport
        errors; callers treat every failure as best effort.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Put')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Table,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PartitionKey,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$RowKey,

        [AllowNull()]
        [string]$Body
    )

    $token = Get-WatchdogStorageToken
    $uri = "{0}{1}(PartitionKey='{2}',RowKey='{3}')" -f $Config.TableEndpoint, $Table,
        (ConvertTo-WatchdogTableKeyLiteral -Key $PartitionKey), (ConvertTo-WatchdogTableKeyLiteral -Key $RowKey)
    $headers = @{
        'Authorization'         = "Bearer $token"
        'x-ms-version'          = $script:TableApiVersion
        'x-ms-date'             = [datetime]::UtcNow.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
        'Accept'                = 'application/json;odata=nometadata'
        'DataServiceVersion'    = '3.0;NetFx'
        'MaxDataServiceVersion' = '3.0;NetFx'
    }
    $request = @{
        Method             = $Method
        Uri                = $uri
        Headers            = $headers
        TimeoutSec         = $script:TableTimeoutSeconds
        SkipHttpErrorCheck = $true
        UseBasicParsing    = $true
    }
    if (-not [string]::IsNullOrEmpty($Body)) {
        $request['Body'] = $Body
        $request['ContentType'] = 'application/json'
    }
    $response = Invoke-WebRequest @request
    return @{
        StatusCode = [int]$response.StatusCode
        Content    = [string]$response.Content
    }
}

#endregion

#region Main Functions

function Write-WatchdogLog {
    <#
    .SYNOPSIS
        Writes one structured log line to the stream the Functions host maps to the level.

    .DESCRIPTION
        Information goes to the information stream, Warning to Write-Warning and Error to
        Write-Error as a non-terminating record, so logging an error never aborts the
        invocation. RunId and HostName are embedded for Application Insights correlation.

    .PARAMETER Message
        The log text. Callers never include secrets; the API key and SMTP password are
        never passed to this function.

    .PARAMETER Level
        Information, Warning or Error. Defaults to Information.

    .PARAMETER RunId
        The run or invocation id to embed, if known.

    .PARAMETER HostName
        The reporting host, if known.

    .EXAMPLE
        Write-WatchdogLog -Message 'Alert sent' -Level Information -RunId $runId -HostName 'SRV-EXAMPLE-01'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$HostName
    )

    $runText = if ([string]::IsNullOrEmpty($RunId)) { '-' } else { $RunId }
    $hostText = if ([string]::IsNullOrEmpty($HostName)) { '-' } else { $HostName }
    $line = "[ServiceWatchdog] [$Level] runId=$runText host=$hostText $Message"

    switch ($Level) {
        'Warning' { Write-Warning -Message $line }
        'Error' { Write-Error -Message $line -ErrorAction Continue }
        default { Write-Information -MessageData $line -InformationAction Continue }
    }
}

function Get-WatchdogConfig {
    <#
    .SYNOPSIS
        Reads and validates the WATCHDOG_* app settings and returns a config object.

    .DESCRIPTION
        Applies the defaults from DESIGN.md 6.2, requires WATCHDOG_MAIL_FROM,
        WATCHDOG_MAIL_TO and WATCHDOG_TABLE_ENDPOINT plus the secrets of the configured
        provider only (WATCHDOG_SMTP2GO_API_KEY for Smtp2GoApi; WATCHDOG_SMTP_HOST,
        WATCHDOG_SMTP_USERNAME and WATCHDOG_SMTP_PASSWORD for Smtp), and throws a
        terminating error naming any setting that is missing, malformed or still an
        unresolved @Microsoft.KeyVault( reference. Settings of the unused provider are
        never read, so an unresolved secret there is ignored.

    .PARAMETER Environment
        Hashtable of setting name to value. Defaults to the process environment.

    .EXAMPLE
        $config = Get-WatchdogConfig

    .EXAMPLE
        $config = Get-WatchdogConfig -Environment @{ WATCHDOG_MAIL_FROM = 'alerts@example.com'; ... }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [hashtable]$Environment
    )

    if ($null -eq $Environment) {
        $Environment = @{}
        foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $Environment[[string]$entry.Key] = [string]$entry.Value
        }
    }

    $providerRaw = Get-WatchdogSetting -Environment $Environment -Name 'WATCHDOG_MAIL_PROVIDER' -Default 'Smtp2GoApi'
    $provider = @('Smtp2GoApi', 'Smtp') | Where-Object { $_ -eq $providerRaw } | Select-Object -First 1
    if (-not $provider) {
        throw "App setting WATCHDOG_MAIL_PROVIDER must be Smtp2GoApi or Smtp (got '$providerRaw')"
    }

    $requiredNames = @('WATCHDOG_MAIL_FROM', 'WATCHDOG_MAIL_TO', 'WATCHDOG_TABLE_ENDPOINT')
    if ($provider -eq 'Smtp2GoApi') {
        $requiredNames += 'WATCHDOG_SMTP2GO_API_KEY'
    }
    else {
        $requiredNames += 'WATCHDOG_SMTP_HOST', 'WATCHDOG_SMTP_USERNAME', 'WATCHDOG_SMTP_PASSWORD'
    }
    $missing = @($requiredNames | Where-Object { $null -eq (Get-WatchdogSetting -Environment $Environment -Name $_) })
    if ($missing.Count -gt 0) {
        throw "Missing required app settings: $($missing -join ', ')"
    }

    # Every setting this provider reads is checked for an unresolved Key Vault reference.
    $readNames = @(
        'WATCHDOG_MAIL_PROVIDER', 'WATCHDOG_MAIL_FROM', 'WATCHDOG_MAIL_TO', 'WATCHDOG_MAIL_SUBJECT_PREFIX',
        'WATCHDOG_MAIL_TIMEOUT_SECONDS', 'WATCHDOG_TABLE_ENDPOINT', 'WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR',
        'WATCHDOG_ALLOWED_SITES', 'WATCHDOG_STALE_HOURS', 'WATCHDOG_DIGEST_ALWAYS_SEND'
    )
    if ($provider -eq 'Smtp2GoApi') {
        $readNames += 'WATCHDOG_SMTP2GO_API_URL', 'WATCHDOG_SMTP2GO_API_KEY'
    }
    else {
        $readNames += 'WATCHDOG_SMTP_HOST', 'WATCHDOG_SMTP_PORT', 'WATCHDOG_SMTP_USERNAME', 'WATCHDOG_SMTP_PASSWORD',
            'WATCHDOG_SMTP_USE_STARTTLS'
    }
    $unresolved = @($readNames | Where-Object {
            $value = Get-WatchdogSetting -Environment $Environment -Name $_
            $null -ne $value -and
            $value.StartsWith($script:KeyVaultReferencePrefix, [System.StringComparison]::OrdinalIgnoreCase)
        })
    if ($unresolved.Count -gt 0) {
        throw ("App setting $($unresolved -join ', ') is an unresolved Key Vault reference; check the function " +
            'identity, the Key Vault Secrets User role assignment and that the secret exists')
    }

    # Defaults from DESIGN.md 6.2. Settings are read once here so the block below stays readable.
    $defaults = @{
        WATCHDOG_MAIL_SUBJECT_PREFIX          = '[Service Watchdog]'
        WATCHDOG_MAIL_TIMEOUT_SECONDS         = '20'
        WATCHDOG_SMTP2GO_API_URL              = 'https://api.smtp2go.com/v3/email/send'
        WATCHDOG_SMTP_PORT                    = '587'
        WATCHDOG_SMTP_USE_STARTTLS            = 'true'
        WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR = '6'
        WATCHDOG_STALE_HOURS                  = '26'
        WATCHDOG_DIGEST_ALWAYS_SEND           = 'false'
    }
    $setting = @{}
    foreach ($name in $readNames) {
        $setting[$name] = Get-WatchdogSetting -Environment $Environment -Name $name -Default $defaults[$name]
    }

    $mailTo = ConvertTo-WatchdogSettingList -Value $setting['WATCHDOG_MAIL_TO']
    if ($mailTo.Count -eq 0) {
        throw 'App setting WATCHDOG_MAIL_TO must contain at least one recipient'
    }
    $tableEndpoint = $setting['WATCHDOG_TABLE_ENDPOINT']
    if (-not $tableEndpoint.EndsWith('/')) {
        $tableEndpoint = "$tableEndpoint/"
    }

    $config = [ordered]@{
        MailProvider            = $provider
        MailFrom                = $setting['WATCHDOG_MAIL_FROM']
        MailTo                  = $mailTo
        MailSubjectPrefix       = $setting['WATCHDOG_MAIL_SUBJECT_PREFIX']
        MailTimeoutSeconds      = ConvertTo-WatchdogSettingInt -Name 'WATCHDOG_MAIL_TIMEOUT_SECONDS' `
            -Value $setting['WATCHDOG_MAIL_TIMEOUT_SECONDS']
        Smtp2GoApiUrl           = $null
        Smtp2GoApiKey           = $null
        SmtpHost                = $null
        SmtpPort                = 587
        SmtpUsername            = $null
        SmtpPassword            = $null
        SmtpUseStartTls         = $true
        TableEndpoint           = $tableEndpoint
        MaxAlertsPerHostPerHour = ConvertTo-WatchdogSettingInt -Name 'WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR' `
            -Value $setting['WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR']
        AllowedSites            = ConvertTo-WatchdogSettingList -Value $setting['WATCHDOG_ALLOWED_SITES']
        StaleHours              = ConvertTo-WatchdogSettingInt -Name 'WATCHDOG_STALE_HOURS' `
            -Value $setting['WATCHDOG_STALE_HOURS']
        DigestAlwaysSend        = ConvertTo-WatchdogSettingBool -Name 'WATCHDOG_DIGEST_ALWAYS_SEND' `
            -Value $setting['WATCHDOG_DIGEST_ALWAYS_SEND']
    }

    if ($provider -eq 'Smtp2GoApi') {
        $config.Smtp2GoApiUrl = $setting['WATCHDOG_SMTP2GO_API_URL']
        $config.Smtp2GoApiKey = $setting['WATCHDOG_SMTP2GO_API_KEY']
    }
    else {
        $config.SmtpHost = $setting['WATCHDOG_SMTP_HOST']
        $config.SmtpPort = ConvertTo-WatchdogSettingInt -Name 'WATCHDOG_SMTP_PORT' -Value $setting['WATCHDOG_SMTP_PORT']
        $config.SmtpUsername = $setting['WATCHDOG_SMTP_USERNAME']
        $config.SmtpPassword = $setting['WATCHDOG_SMTP_PASSWORD']
        $config.SmtpUseStartTls = ConvertTo-WatchdogSettingBool -Name 'WATCHDOG_SMTP_USE_STARTTLS' `
            -Value $setting['WATCHDOG_SMTP_USE_STARTTLS']
    }

    return [pscustomobject]$config
}

function Test-WatchdogPayload {
    <#
    .SYNOPSIS
        Validates an alert payload against the DESIGN.md 4.8 contract and 6.3 limits.

    .DESCRIPTION
        Returns an array of error strings; an empty array means the payload is valid. Every
        violation is reported, not only the first, except that an oversize body is rejected
        immediately. Unknown top-level keys are errors that name the key. Fields the
        Functions worker has already deserialized (Int64 counters, UTC DateTime timestamps)
        are accepted as equivalent to their JSON text forms.

    .PARAMETER Payload
        The deserialized request body (a hashtable).

    .EXAMPLE
        $errors = Test-WatchdogPayload -Payload $Request.Body
        if ($errors.Count -gt 0) { ... }
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Payload
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Payload -isnot [System.Collections.IDictionary]) {
        $errors.Add('Payload must be a JSON object')
        return $errors.ToArray()
    }

    try {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress -WarningAction SilentlyContinue
        $byteCount = [System.Text.Encoding]::UTF8.GetByteCount([string]$json)
    }
    catch {
        $errors.Add("Payload could not be serialized: $($_.Exception.Message)")
        return $errors.ToArray()
    }
    if ($byteCount -gt $script:MaxPayloadBytes) {
        $errors.Add("Payload body is $byteCount bytes; the limit is 256 KB")
        return $errors.ToArray()
    }

    foreach ($key in @($Payload.Keys)) {
        if ($script:AllowedTopLevelKeys -cnotcontains [string]$key) {
            $errors.Add("Unknown top-level key '$key'")
        }
    }

    $requiredTopLevel = @(
        'SchemaVersion', 'EventType', 'EventId', 'SiteName', 'HostName', 'TimestampUtc', 'RunId', 'WatchdogVersion',
        'Summary', 'Services'
    )
    $present = @{}
    foreach ($name in $requiredTopLevel) {
        if (-not (Test-WatchdogFieldPresent -Object $Payload -Name $name)) {
            $errors.Add("Field '$name' is required")
        }
        elseif ($null -eq $Payload[$name]) {
            $errors.Add("Field '$name' must not be null")
        }
        else {
            $present[$name] = $true
        }
    }

    if ($present['SchemaVersion']) {
        $version = $Payload['SchemaVersion']
        if (-not (Test-WatchdogInteger -Value $version) -or [long]$version -ne 1) {
            $errors.Add("SchemaVersion must be 1 (got '$version')")
        }
    }
    if ($present['EventType']) {
        $eventType = $Payload['EventType']
        if ($eventType -isnot [string] -or $script:AllowedEventTypes -cnotcontains $eventType) {
            $errors.Add("EventType '$eventType' is not one of: $($script:AllowedEventTypes -join ', ')")
        }
    }
    foreach ($name in 'EventId', 'RunId') {
        if ($present[$name]) {
            $guid = [guid]::Empty
            $value = $Payload[$name]
            if ($value -isnot [string] -or -not [guid]::TryParse($value, [ref]$guid)) {
                $errors.Add("$name must be a GUID string")
            }
        }
    }
    if ($present['SiteName']) {
        $site = $Payload['SiteName']
        if ($site -isnot [string] -or $site.Length -lt 1 -or $site.Length -gt $script:MaxStringLength) {
            $errors.Add("SiteName must be a string of 1 to $($script:MaxStringLength) characters")
        }
    }
    if ($present['HostName']) {
        $hostName = $Payload['HostName']
        if ($hostName -isnot [string] -or $hostName -notmatch $script:HostNamePattern) {
            $errors.Add('HostName must match ^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}$')
        }
    }
    if ((Test-WatchdogFieldPresent -Object $Payload -Name 'Fqdn') -and $null -ne $Payload['Fqdn']) {
        $fqdn = $Payload['Fqdn']
        if ($fqdn -isnot [string] -or $fqdn.Length -gt $script:MaxStringLength) {
            $errors.Add("Fqdn must be null or a string of at most $($script:MaxStringLength) characters")
        }
    }
    if ($present['TimestampUtc'] -and -not (Test-WatchdogTimestamp -Value $Payload['TimestampUtc'])) {
        $errors.Add("TimestampUtc must be a UTC timestamp in the form $($script:TimestampFormat)")
    }
    if ($present['WatchdogVersion']) {
        $watchdogVersion = $Payload['WatchdogVersion']
        if ($watchdogVersion -isnot [string] -or $watchdogVersion.Length -gt $script:MaxStringLength) {
            $errors.Add("WatchdogVersion must be a string of at most $($script:MaxStringLength) characters")
        }
    }
    if ($present['Summary']) {
        $summary = $Payload['Summary']
        if ($summary -isnot [string] -or $summary.Length -gt $script:MaxSummaryLength) {
            $errors.Add("Summary must be a string of at most $($script:MaxSummaryLength) characters")
        }
    }

    if ($present['Services']) {
        $services = $Payload['Services']
        if ($services -is [string] -or $services -isnot [System.Collections.IList]) {
            $errors.Add('Services must be an array')
        }
        elseif ($services.Count -gt $script:MaxServices) {
            $errors.Add("Services may hold at most $($script:MaxServices) entries (got $($services.Count))")
        }
        else {
            for ($index = 0; $index -lt $services.Count; $index++) {
                $prefix = "Services[$index]"
                $service = $services[$index]
                if ($service -isnot [System.Collections.IDictionary]) {
                    $errors.Add("$prefix must be an object")
                    continue
                }
                Test-WatchdogServiceEntry -Service $service -Prefix $prefix -Errors $errors
            }
        }
    }

    return $errors.ToArray()
}

function Test-WatchdogServiceEntry {
    <#
    .SYNOPSIS
        Validates one Services[] entry, appending errors to the shared list.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Service,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Errors
    )

    $present = @{}
    foreach ($name in 'Name', 'Status', 'Attempts', 'FlapCount', 'Notify') {
        if (-not $Service.Contains($name)) {
            $Errors.Add("$Prefix.$name is required")
        }
        elseif ($null -eq $Service[$name]) {
            $Errors.Add("$Prefix.$name must not be null")
        }
        else {
            $present[$name] = $true
        }
    }

    if ($present['Name']) {
        $name = $Service['Name']
        if ($name -isnot [string] -or $name.Length -lt 1 -or $name.Length -gt $script:MaxStringLength) {
            $Errors.Add("$Prefix.Name must be a string of 1 to $($script:MaxStringLength) characters")
        }
    }
    if ($present['Status']) {
        $status = $Service['Status']
        if ($status -isnot [string] -or $script:AllowedStatuses -cnotcontains $status) {
            $Errors.Add("$Prefix.Status '$status' is not one of: $($script:AllowedStatuses -join ', ')")
        }
    }
    foreach ($counter in 'Attempts', 'FlapCount') {
        if ($present[$counter]) {
            $value = $Service[$counter]
            if (-not (Test-WatchdogInteger -Value $value) -or [long]$value -lt 0) {
                $Errors.Add("$Prefix.$counter must be a non-negative integer")
            }
        }
    }
    if ($present['Notify'] -and $Service['Notify'] -isnot [bool]) {
        $Errors.Add("$Prefix.Notify must be a boolean")
    }

    if ($Service.Contains('DisplayName') -and $null -ne $Service['DisplayName']) {
        $displayName = $Service['DisplayName']
        if ($displayName -isnot [string] -or $displayName.Length -gt $script:MaxStringLength) {
            $Errors.Add("$Prefix.DisplayName must be null or a string of at most $($script:MaxStringLength) characters")
        }
    }
    if ($Service.Contains('StartType') -and $null -ne $Service['StartType']) {
        $startType = $Service['StartType']
        if ($startType -isnot [string] -or $script:AllowedStartTypes -cnotcontains $startType) {
            $Errors.Add("$Prefix.StartType '$startType' is not null or one of: $($script:AllowedStartTypes -join ', ')")
        }
    }
    if ($Service.Contains('FirstFailedUtc') -and $null -ne $Service['FirstFailedUtc']) {
        if (-not (Test-WatchdogTimestamp -Value $Service['FirstFailedUtc'])) {
            $Errors.Add("$Prefix.FirstFailedUtc must be null or a UTC timestamp in the form $($script:TimestampFormat)")
        }
    }
    if ($Service.Contains('LastError') -and $null -ne $Service['LastError']) {
        $lastError = $Service['LastError']
        if ($lastError -isnot [string] -or $lastError.Length -gt $script:MaxLastErrorLength) {
            $limit = $script:MaxLastErrorLength
            $Errors.Add("$Prefix.LastError must be null or a string of at most $limit characters")
        }
    }
}

function ConvertTo-WatchdogEmail {
    <#
    .SYNOPSIS
        Renders the alert email: subject, plain-text body and HTML body.

    .DESCRIPTION
        Subject is "<prefix> <marker><HostName>: <Summary>" where the marker is [TEST],
        Reminder: or Flapping: for those event types; CR and LF are stripped from every
        embedded field. Every value in the HTML body is HTML-encoded; the plain-text body
        uses raw values. Both bodies list site, host, FQDN, time and event type, one row per
        service, and a footer with the watchdog version, run id and event id.

    .PARAMETER Payload
        A payload that has passed Test-WatchdogPayload.

    .PARAMETER Config
        The object returned by Get-WatchdogConfig (for the subject prefix).

    .EXAMPLE
        $email = ConvertTo-WatchdogEmail -Payload $payload -Config $config
        Send-WatchdogMail -Config $config -Subject $email.Subject -TextBody $email.TextBody -HtmlBody $email.HtmlBody
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Payload,

        [Parameter(Mandatory)]
        [object]$Config
    )

    $eventType = [string]$Payload['EventType']
    $hostName = [string]$Payload['HostName']
    $marker = switch ($eventType) {
        'test' { '[TEST] ' }
        'reminder' { 'Reminder: ' }
        'flapping' { 'Flapping: ' }
        default { '' }
    }
    $subjectParts = @(
        (ConvertTo-WatchdogSingleLine -Value $Config.MailSubjectPrefix),
        $marker,
        (ConvertTo-WatchdogSingleLine -Value $hostName),
        (ConvertTo-WatchdogSingleLine -Value ([string]$Payload['Summary']))
    )
    $subject = '{0} {1}{2}: {3}' -f $subjectParts

    $services = @($Payload['Services'])
    $header = [ordered]@{
        'Site'       = $Payload['SiteName']
        'Host'       = $hostName
        'FQDN'       = $Payload['Fqdn']
        'Time (UTC)' = $Payload['TimestampUtc']
        'Event type' = $eventType
        'Summary'    = $Payload['Summary']
    }
    $columns = @('Service', 'Display name', 'Status', 'Start type', 'Attempts', 'First failed (UTC)', 'Last error')
    $footer = 'ServiceWatchdog {0} | run {1} | event {2}' -f $Payload['WatchdogVersion'], $Payload['RunId'],
        $Payload['EventId']

    $text = [System.Text.StringBuilder]::new()
    $html = [System.Text.StringBuilder]::new()
    [void]$html.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"></head>')
    [void]$html.AppendLine('<body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222">')
    [void]$html.AppendLine('<h2 style="margin:0 0 8px 0">Service Watchdog notification</h2>')
    [void]$html.AppendLine('<table cellpadding="4" cellspacing="0" style="border-collapse:collapse">')
    [void]$text.AppendLine('Service Watchdog notification')
    [void]$text.AppendLine('')
    foreach ($label in $header.Keys) {
        [void]$text.AppendLine(('{0,-12} {1}' -f "${label}:", (ConvertTo-WatchdogDisplayValue -Value $header[$label])))
        [void]$html.AppendLine('<tr><th align="left">' + (ConvertTo-WatchdogHtml -Value $label) + '</th><td>' +
            (ConvertTo-WatchdogHtml -Value $header[$label]) + '</td></tr>')
    }
    [void]$html.AppendLine('</table>')
    [void]$text.AppendLine('')

    if ($services.Count -eq 0) {
        [void]$text.AppendLine('No services in this event.')
        [void]$html.AppendLine('<p>No services in this event.</p>')
    }
    else {
        [void]$text.AppendLine('Services (* = triggered this notification):')
        [void]$html.AppendLine('<h3 style="margin:16px 0 8px 0">Services</h3>')
        [void]$html.AppendLine('<table cellpadding="4" cellspacing="0" border="1" style="border-collapse:collapse">')
        $headerCells = @($columns | ForEach-Object {
                '<th align="left">' + (ConvertTo-WatchdogHtml -Value $_) + '</th>'
            })
        [void]$html.AppendLine('<tr>' + ($headerCells -join '') + '</tr>')
        foreach ($service in $services) {
            $flag = if ([bool](Get-WatchdogField -Object $service -Name 'Notify')) { '*' } else { ' ' }
            $values = @(
                (Get-WatchdogField -Object $service -Name 'Name'),
                (Get-WatchdogField -Object $service -Name 'DisplayName'),
                (Get-WatchdogField -Object $service -Name 'Status'),
                (Get-WatchdogField -Object $service -Name 'StartType'),
                (Get-WatchdogField -Object $service -Name 'Attempts'),
                (Get-WatchdogField -Object $service -Name 'FirstFailedUtc'),
                (Get-WatchdogField -Object $service -Name 'LastError')
            )
            $textValues = @($values | ForEach-Object { ConvertTo-WatchdogDisplayValue -Value $_ })
            $rowFormat = '  {0}{1} | {2} | {3} | {4} | attempts {5} | first failed {6}'
            [void]$text.AppendLine(($rowFormat -f $flag, $textValues[0], $textValues[1], $textValues[2], $textValues[3],
                    $textValues[4], $textValues[5]))
            [void]$text.AppendLine("      last error: $($textValues[6])")
            $htmlValues = @($values | ForEach-Object { ConvertTo-WatchdogHtml -Value $_ })
            if ($flag -eq '*') {
                $htmlValues[0] = $htmlValues[0] + ' *'
            }
            $cells = @($htmlValues | ForEach-Object { '<td>' + $_ + '</td>' }) -join ''
            [void]$html.AppendLine('<tr>' + $cells + '</tr>')
        }
        [void]$html.AppendLine('</table>')
        [void]$html.AppendLine('<p style="color:#666">* = triggered this notification</p>')
        $notifyNames = @($services | Where-Object { [bool](Get-WatchdogField -Object $_ -Name 'Notify') } |
                ForEach-Object { ConvertTo-WatchdogDisplayValue -Value (Get-WatchdogField -Object $_ -Name 'Name') })
        if ($notifyNames.Count -gt 0) {
            $triggeredBy = ConvertTo-WatchdogHtml -Value ($notifyNames -join ', ')
            [void]$html.AppendLine('<p>Triggered by: ' + $triggeredBy + '</p>')
        }
    }

    [void]$text.AppendLine('')
    [void]$text.AppendLine($footer)
    $footerHtml = ConvertTo-WatchdogHtml -Value $footer
    [void]$html.AppendLine('<hr><p style="color:#666;font-size:12px">' + $footerHtml + '</p>')
    [void]$html.AppendLine('</body></html>')

    return @{
        Subject  = $subject
        TextBody = $text.ToString()
        HtmlBody = $html.ToString()
    }
}

function Send-WatchdogMail {
    <#
    .SYNOPSIS
        Sends an email through the configured provider.

    .DESCRIPTION
        Dispatches to SMTP2GO (REST) or SMTP by Config.MailProvider and returns
        @{ Sent; ProviderMessageId; Error; StatusCode }. Never throws for provider failures;
        the caller decides how to report them. Sender and recipients always come from the
        configuration, never from the payload.

    .PARAMETER Config
        The object returned by Get-WatchdogConfig.

    .PARAMETER Subject
        Subject line (already line-break stripped by ConvertTo-WatchdogEmail).

    .PARAMETER TextBody
        Plain-text body.

    .PARAMETER HtmlBody
        HTML body.

    .EXAMPLE
        $result = Send-WatchdogMail -Config $config -Subject $s -TextBody $t -HtmlBody $h
        if (-not $result.Sent) { Write-WatchdogLog -Level Error -Message $result.Error }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Subject,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$TextBody,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$HtmlBody
    )

    switch ($Config.MailProvider) {
        'Smtp' {
            return (Send-WatchdogMailSmtp -Config $Config -Subject $Subject -TextBody $TextBody -HtmlBody $HtmlBody)
        }
        default {
            return (Send-WatchdogMailSmtp2Go -Config $Config -Subject $Subject -TextBody $TextBody -HtmlBody $HtmlBody)
        }
    }
}

function Test-WatchdogRateLimit {
    <#
    .SYNOPSIS
        Sliding one-hour window per host key; returns $true when another alert is allowed.

    .DESCRIPTION
        State lives in module scope, so it is per worker process and best effort. Entries
        older than one hour are dropped; when fewer than Limit remain the call is recorded
        and allowed.

    .PARAMETER HostKey
        The sanitized, upper-cased host key.

    .PARAMETER Limit
        Maximum alerts per rolling hour.

    .PARAMETER NowUtc
        Injected clock for tests. Defaults to [datetime]::UtcNow.

    .EXAMPLE
        if (-not (Test-WatchdogRateLimit -HostKey $hostKey -Limit $config.MaxAlertsPerHostPerHour)) { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$HostKey,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Limit,

        [datetime]$NowUtc = [datetime]::UtcNow
    )

    if (-not $script:RateLimitWindows.ContainsKey($HostKey)) {
        $script:RateLimitWindows[$HostKey] = [System.Collections.Generic.List[datetime]]::new()
    }
    $window = $script:RateLimitWindows[$HostKey]
    $windowStart = $NowUtc.AddHours(-1)
    for ($index = $window.Count - 1; $index -ge 0; $index--) {
        if ($window[$index] -le $windowStart) {
            $window.RemoveAt($index)
        }
    }
    if ($window.Count -ge $Limit) {
        return $false
    }
    $window.Add($NowUtc)
    return $true
}

function Get-WatchdogStorageToken {
    <#
    .SYNOPSIS
        Returns a managed-identity bearer token for Azure Storage, cached in module scope.

    .DESCRIPTION
        Calls $env:IDENTITY_ENDPOINT with the X-IDENTITY-HEADER for the
        https://storage.azure.com/ resource (api-version 2019-08-01) and caches the token
        until five minutes before expires_on. Throws when the identity endpoint is not
        available; callers treat that as a best-effort table failure.

    .PARAMETER Environment
        Hashtable providing IDENTITY_ENDPOINT and IDENTITY_HEADER. Defaults to the process
        environment.

    .EXAMPLE
        $token = Get-WatchdogStorageToken
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [hashtable]$Environment
    )

    if ($null -eq $Environment) {
        $Environment = @{
            IDENTITY_ENDPOINT = $env:IDENTITY_ENDPOINT
            IDENTITY_HEADER   = $env:IDENTITY_HEADER
        }
    }

    $refreshBefore = [System.DateTimeOffset]::UtcNow.AddMinutes($script:TokenRefreshMarginMinutes)
    if ($null -ne $script:StorageToken -and $script:StorageToken.ExpiresOn -gt $refreshBefore) {
        return $script:StorageToken.Token
    }

    $endpoint = [string]$Environment['IDENTITY_ENDPOINT']
    $header = [string]$Environment['IDENTITY_HEADER']
    if ([string]::IsNullOrWhiteSpace($endpoint) -or [string]::IsNullOrWhiteSpace($header)) {
        throw 'Managed identity is not available: IDENTITY_ENDPOINT and IDENTITY_HEADER are not set'
    }

    $uri = '{0}?resource={1}&api-version=2019-08-01' -f $endpoint, [Uri]::EscapeDataString($script:StorageResource)
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $header } `
        -TimeoutSec $script:TableTimeoutSeconds
    $expiresOn = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$response.expires_on)
    $script:StorageToken = @{
        Token     = [string]$response.access_token
        ExpiresOn = $expiresOn
    }
    return $script:StorageToken.Token
}

function ConvertTo-WatchdogKey {
    <#
    .SYNOPSIS
        Sanitizes a value for use as a table key or rate-limit key.

    .DESCRIPTION
        Replaces every character outside [A-Za-z0-9._ -] with an underscore and trims the
        result to 64 characters. -Upper upper-cases it (host keys).

    .PARAMETER Value
        The raw value (site name or host name).

    .PARAMETER Upper
        Upper-case the result.

    .EXAMPLE
        ConvertTo-WatchdogKey -Value 'Example Org/#?'          # Example Org___

    .EXAMPLE
        ConvertTo-WatchdogKey -Value 'srv-example-01' -Upper   # SRV-EXAMPLE-01
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [switch]$Upper
    )

    $key = $Value -replace '[^A-Za-z0-9._ -]', '_'
    if ($key.Length -gt $script:MaxKeyLength) {
        $key = $key.Substring(0, $script:MaxKeyLength)
    }
    if ($Upper) {
        $key = $key.ToUpperInvariant()
    }
    return $key
}

function ConvertTo-WatchdogHostEntity {
    <#
    .SYNOPSIS
        Builds the WatchdogHosts row for a payload.

    .DESCRIPTION
        LastSeenUtc is always the function's own receipt time (NowUtc), never the payload's
        TimestampUtc, so staleness never depends on the server's clock. ProblemServiceCount
        counts services whose status is Failed, Missing or Disabled; a test event stores 0/0.

    .PARAMETER Payload
        A validated payload.

    .PARAMETER NowUtc
        Injected receipt time for tests. Defaults to [datetime]::UtcNow.

    .EXAMPLE
        $entity = ConvertTo-WatchdogHostEntity -Payload $payload
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Payload,

        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $services = @($Payload['Services'])
    $problems = @($services | Where-Object {
            $script:ProblemStatuses -contains [string](Get-WatchdogField -Object $_ -Name 'Status')
        })
    return [ordered]@{
        PartitionKey          = ConvertTo-WatchdogKey -Value ([string]$Payload['SiteName'])
        RowKey                = ConvertTo-WatchdogKey -Value ([string]$Payload['HostName']) -Upper
        LastSeenUtc           = ConvertTo-WatchdogTimestamp -Value $NowUtc
        LastEventType         = [string]$Payload['EventType']
        WatchdogVersion       = [string]$Payload['WatchdogVersion']
        MonitoredServiceCount = $services.Count
        ProblemServiceCount   = $problems.Count
    }
}

function Set-WatchdogHostEntity {
    <#
    .SYNOPSIS
        Inserts or replaces the host's WatchdogHosts row. Best effort; never throws.

    .PARAMETER Config
        The object returned by Get-WatchdogConfig.

    .PARAMETER Payload
        A validated payload.

    .PARAMETER NowUtc
        Injected receipt time for tests.

    .EXAMPLE
        Set-WatchdogHostEntity -Config $config -Payload $payload
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Runs inside the Functions worker with no interactive host; the endpoint worker owns -DryRun.'
    )]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Payload,

        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $hostName = [string]$Payload['HostName']
    try {
        $entity = ConvertTo-WatchdogHostEntity -Payload $Payload -NowUtc $NowUtc
        $result = Invoke-WatchdogTableRequest -Config $Config -Method Put -Table $script:HostsTable `
            -PartitionKey $entity.PartitionKey -RowKey $entity.RowKey -Body ($entity | ConvertTo-Json -Compress)
        if ($result.StatusCode -ne 204) {
            Write-WatchdogLog -Level Warning -HostName $hostName -Message ("Host row write to $($script:HostsTable) " +
                "returned HTTP $($result.StatusCode); continuing")
        }
    }
    catch {
        Write-WatchdogLog -Level Warning -HostName $hostName -Message ("Host row write to $($script:HostsTable) " +
            "failed: $($_.Exception.Message); continuing")
    }
}

function Test-WatchdogSentEvent {
    <#
    .SYNOPSIS
        Returns $true when a WatchdogSentEvents row exists for the host and event id.

    .DESCRIPTION
        200 means the event was already sent; 404 means it was not. Any other status or a
        transport error is logged as a warning and treated as not sent, so a storage outage
        can at worst cause a repeat email, never a lost one.

    .PARAMETER Config
        The object returned by Get-WatchdogConfig.

    .PARAMETER HostKey
        The sanitized, upper-cased host key (partition key).

    .PARAMETER EventId
        The payload EventId (row key).

    .EXAMPLE
        if (Test-WatchdogSentEvent -Config $config -HostKey $hostKey -EventId $payload.EventId) { ... }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$HostKey,

        [Parameter(Mandatory)]
        [string]$EventId
    )

    try {
        $result = Invoke-WatchdogTableRequest -Config $Config -Method Get -Table $script:SentEventsTable `
            -PartitionKey $HostKey -RowKey $EventId
        switch ($result.StatusCode) {
            200 { return $true }
            404 { return $false }
            default {
                Write-WatchdogLog -Level Warning -HostName $HostKey -Message ("Dedup lookup in " +
                    "$($script:SentEventsTable) returned HTTP $($result.StatusCode); treating event as not sent")
                return $false
            }
        }
    }
    catch {
        Write-WatchdogLog -Level Warning -HostName $HostKey -Message ("Dedup lookup in $($script:SentEventsTable) " +
            "failed: $($_.Exception.Message); treating event as not sent")
        return $false
    }
}

function Set-WatchdogSentEvent {
    <#
    .SYNOPSIS
        Records that an event was emailed, in WatchdogSentEvents. Best effort; never throws.

    .PARAMETER Config
        The object returned by Get-WatchdogConfig.

    .PARAMETER HostKey
        The sanitized, upper-cased host key (partition key).

    .PARAMETER Payload
        The validated payload (EventId becomes the row key).

    .PARAMETER ProviderMessageId
        The provider's message id, if any.

    .PARAMETER NowUtc
        Injected send time for tests.

    .EXAMPLE
        Set-WatchdogSentEvent -Config $config -HostKey $hostKey -Payload $payload `
            -ProviderMessageId $result.ProviderMessageId
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Runs inside the Functions worker with no interactive host; the endpoint worker owns -DryRun.'
    )]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$HostKey,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Payload,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProviderMessageId,

        [datetime]$NowUtc = [datetime]::UtcNow
    )

    try {
        $eventId = [string]$Payload['EventId']
        $entity = [ordered]@{
            PartitionKey      = $HostKey
            RowKey            = $eventId
            SentUtc           = ConvertTo-WatchdogTimestamp -Value $NowUtc
            EventType         = [string]$Payload['EventType']
            ProviderMessageId = [string]$ProviderMessageId
        }
        $result = Invoke-WatchdogTableRequest -Config $Config -Method Put -Table $script:SentEventsTable `
            -PartitionKey $HostKey -RowKey $eventId -Body ($entity | ConvertTo-Json -Compress)
        if ($result.StatusCode -ne 204) {
            Write-WatchdogLog -Level Warning -HostName $HostKey -Message ("Sent-event write to " +
                "$($script:SentEventsTable) returned HTTP $($result.StatusCode); continuing")
        }
    }
    catch {
        Write-WatchdogLog -Level Warning -HostName $HostKey -Message ("Sent-event write to " +
            "$($script:SentEventsTable) failed: $($_.Exception.Message); continuing")
    }
}

function Get-WatchdogStaleHosts {
    <#
    .SYNOPSIS
        Splits WatchdogHosts rows into stale and fresh sets by age.

    .DESCRIPTION
        A row is stale when NowUtc minus LastSeenUtc is strictly greater than StaleHours; a
        row exactly at the threshold is fresh. A row whose LastSeenUtc cannot be read is
        reported as stale with a null AgeHours, because it cannot be shown to be fresh.

    .PARAMETER Rows
        Rows from the WatchdogHosts table input binding (hashtables or objects).

    .PARAMETER StaleHours
        The threshold in hours.

    .PARAMETER NowUtc
        Injected clock for tests. Defaults to [datetime]::UtcNow.

    .EXAMPLE
        $sets = Get-WatchdogStaleHosts -Rows $Hosts -StaleHours $config.StaleHours
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns',
        '',
        Justification = 'Name is fixed by the DESIGN.md 6.3 interface contract; it returns two host sets.'
    )]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$StaleHours,

        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $stale = [System.Collections.Generic.List[object]]::new()
    $fresh = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) {
        if ($null -eq $row) {
            continue
        }
        $lastSeen = ConvertFrom-WatchdogTimestamp -Value (Get-WatchdogField -Object $row -Name 'LastSeenUtc')
        $ageHours = $null
        if ($null -ne $lastSeen) {
            $ageHours = [math]::Round(($NowUtc.ToUniversalTime() - $lastSeen).TotalHours, 1)
        }
        $item = [pscustomobject]@{
            HostName              = [string](Get-WatchdogField -Object $row -Name 'RowKey')
            SiteName              = [string](Get-WatchdogField -Object $row -Name 'PartitionKey')
            LastSeenUtc           = ConvertTo-WatchdogTimestamp -Value $lastSeen
            AgeHours              = $ageHours
            LastEventType         = [string](Get-WatchdogField -Object $row -Name 'LastEventType')
            WatchdogVersion       = [string](Get-WatchdogField -Object $row -Name 'WatchdogVersion')
            MonitoredServiceCount = Get-WatchdogField -Object $row -Name 'MonitoredServiceCount'
            ProblemServiceCount   = Get-WatchdogField -Object $row -Name 'ProblemServiceCount'
        }
        if ($null -eq $ageHours -or $ageHours -gt $StaleHours) {
            $stale.Add($item)
        }
        else {
            $fresh.Add($item)
        }
    }
    return @{
        Stale = $stale.ToArray()
        Fresh = $fresh.ToArray()
    }
}

#endregion

#region Script Body

Export-ModuleMember -Function @(
    'Get-WatchdogConfig',
    'Test-WatchdogPayload',
    'ConvertTo-WatchdogEmail',
    'Send-WatchdogMail',
    'Test-WatchdogRateLimit',
    'Get-WatchdogStorageToken',
    'Set-WatchdogHostEntity',
    'Test-WatchdogSentEvent',
    'Set-WatchdogSentEvent',
    'ConvertTo-WatchdogHostEntity',
    'Get-WatchdogStaleHosts',
    'ConvertTo-WatchdogKey',
    'Write-WatchdogLog'
)

#endregion

#region Cleanup

$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    $script:RateLimitWindows = @{}
    $script:StorageToken = $null
}

#endregion
