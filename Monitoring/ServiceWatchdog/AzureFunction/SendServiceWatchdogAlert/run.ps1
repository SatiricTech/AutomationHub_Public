#Requires -Version 7.4

<#
.SYNOPSIS
    HTTP-triggered Azure Function that relays a ServiceWatchdog event as an email.

.DESCRIPTION
    Entry point for the SendServiceWatchdogAlert function (DESIGN.md section 6.4). Receives
    the JSON payload POSTed by Invoke-WinServiceWatchdog.ps1 with a function key and runs
    this flow, producing exactly one HTTP response per invocation:

      1. Configuration guard (Get-WatchdogConfig) -> 500 config_unresolved
      2. Body must be a JSON object                -> 400 invalid_body
      3. Test-WatchdogPayload                       -> 400 invalid_payload (errors listed)
      4. Optional site allowlist                    -> 403 site_not_allowed
      5. Set-WatchdogHostEntity (best effort; never changes the response)
      6. heartbeat                                  -> 200, emailSent = false
      7. Dedup on (host, EventId) unless test       -> 200, duplicate = true
      8. Rate limit unless recovered                -> 429 rate_limited, Retry-After: 600
      9. Send-WatchdogMail                          -> 502 provider_failed on failure
     10. Set-WatchdogSentEvent (best effort)        -> 200 with providerMessageId

    Every 400 and 403 logs the caller's client IP from X-Forwarded-For or X-Azure-ClientIP.
    All responses carry Content-Type application/json. Recipients and sender always come
    from app settings; nothing in the payload can redirect mail.

.PARAMETER Request
    The HttpRequestContext supplied by the Functions runtime. Body is a hashtable when the
    caller sent valid JSON, otherwise a string.

.PARAMETER TriggerMetadata
    Trigger metadata supplied by the Functions runtime; sys.RandGuid is used as the run id
    in log lines.

.EXAMPLE
    # Invoked by the Functions runtime on POST /api/servicewatchdog/alert with the
    # x-functions-key header. From a workstation, exercise it with the endpoint worker:
    .\Invoke-WinServiceWatchdog.ps1 -TestAlert

.EXAMPLE
    # Local dry run: dot-source with a fake request and a stubbed Push-OutputBinding, as
    # Tests/SendServiceWatchdogAlert.Tests.ps1 does. No mail is sent when Send-WatchdogMail
    # is mocked; this is the DryRun path for the function.
    function Push-OutputBinding { param($Name, $Value) $Value }
    . .\run.ps1 -Request ([pscustomobject]@{ Body = $payload; Headers = @{} }) -TriggerMetadata @{}

.NOTES
    Version : 1.0.0
    Created : 2026-09-04

    Checklist deviations from the powershell-authoring skill (Enterprise tier):
      - 2.1/2.2/2.3/2.4 (-Verbosity, -DryRun, Invoke-Action): the Functions runtime owns
        this script's parameter contract (Request and TriggerMetadata only) and there is no
        console or operator. Dry runs are done by mocking Send-WatchdogMail in the Pester
        suite or by calling the deployed function with the worker's -TestAlert.
      - 4.2/4.6/4.7 (Write-Log, file log under $env:ProgramData): no durable filesystem in
        the worker; Write-WatchdogLog writes structured lines that the host forwards to
        Application Insights, which is the log of record for the function app.
      - 5.2 (SecretManagement): secrets arrive as Key Vault references resolved into app
        settings; an unresolved reference is refused with 500 config_unresolved.
      - 5.7 (code signing): shipped unsigned in the public repository.
      - 6.6/6.7: the operator acceptance run (DESIGN.md section 9) is the integration test;
        run time is bounded by the provider timeout and the host functionTimeout.

    Developed with AI assistance (Claude); reviewed before publication.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [object]$Request,

    [AllowNull()]
    [object]$TriggerMetadata
)

#region Configuration

$ErrorActionPreference = 'Stop'
$script:ResponseContentType = 'application/json'
$script:RateLimitRetryAfterSeconds = '600'
$script:HostsAlertFunctionName = 'SendServiceWatchdogAlert'

#endregion

#region Helper Functions

function Get-WatchdogRunId {
    <#
    .SYNOPSIS
        Returns the runtime's per-invocation GUID, or a fresh one when metadata is absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$TriggerMetadata
    )

    try {
        $sys = $null
        if ($TriggerMetadata -is [System.Collections.IDictionary]) {
            $sys = $TriggerMetadata['sys']
        }
        elseif ($null -ne $TriggerMetadata) {
            $sys = $TriggerMetadata.sys
        }
        $randGuid = $null
        if ($sys -is [System.Collections.IDictionary]) {
            $randGuid = $sys['RandGuid']
        }
        elseif ($null -ne $sys) {
            $randGuid = $sys.RandGuid
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$randGuid)) {
            return [string]$randGuid
        }
    }
    catch {
        Write-Verbose -Message 'Trigger metadata did not expose sys.RandGuid; generating a run id'
    }
    return [guid]::NewGuid().ToString()
}

function Get-WatchdogClientAddress {
    <#
    .SYNOPSIS
        Reads the caller's IP from X-Forwarded-For (first hop) or X-Azure-ClientIP.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [object]$Headers
    )

    if ($null -eq $Headers) {
        return 'unknown'
    }
    foreach ($name in 'X-Forwarded-For', 'X-Azure-ClientIP') {
        try {
            $value = [string]$Headers[$name]
        }
        catch {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return ($value.Split(',')[0]).Trim()
        }
    }
    return 'unknown'
}

function ConvertTo-WatchdogRejection {
    <#
    .SYNOPSIS
        Builds a non-200 response descriptor with the documented JSON error body.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [int]$StatusCode,

        [Parameter(Mandatory)]
        [ValidateSet('config_unresolved', 'invalid_body', 'invalid_payload', 'site_not_allowed', 'rate_limited',
            'provider_failed', 'internal_error')]
        [string]$Code,

        [AllowEmptyCollection()]
        [string[]]$Errors = @(),

        [hashtable]$Headers = @{}
    )

    return @{
        StatusCode = $StatusCode
        Body       = [ordered]@{
            accepted = $false
            error    = $Code
            errors   = @($Errors)
        }
        Headers    = $Headers
    }
}

function ConvertTo-WatchdogAcceptance {
    <#
    .SYNOPSIS
        Builds the 200 response descriptor.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [bool]$EmailSent,

        [bool]$Duplicate,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProviderMessageId
    )

    $messageId = $null
    if (-not [string]::IsNullOrEmpty($ProviderMessageId)) {
        $messageId = $ProviderMessageId
    }
    return @{
        StatusCode = 200
        Body       = [ordered]@{
            accepted          = $true
            emailSent         = $EmailSent
            duplicate         = $Duplicate
            providerMessageId = $messageId
        }
        Headers    = @{}
    }
}

function ConvertTo-WatchdogHttpResponse {
    <#
    .SYNOPSIS
        Converts a response descriptor into the value Push-OutputBinding expects.

    .DESCRIPTION
        Inside the Functions worker the HttpResponseContext type exists and the hashtable is
        converted to it. Outside the worker (Pester) the type is absent and the plain
        hashtable is pushed to the stubbed Push-OutputBinding instead.

        The conversion is explicit and guarded: if the worker's type ever rejects the
        hashtable (a renamed or added property, a setter that throws), the failure is logged
        as a Warning and the plain hashtable is returned so the caller still receives the
        status code and JSON body. This function never returns $null, because pushing $null
        would give the caller a bodiless response with nothing in the logs.

    .PARAMETER Response
        The response descriptor (StatusCode, Body, Headers) built by the flow.

    .PARAMETER RunId
        The invocation id embedded in the Warning when the conversion fails.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Response,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId
    )

    $context = @{
        StatusCode  = [int]$Response.StatusCode
        ContentType = $script:ResponseContentType
        Body        = ($Response.Body | ConvertTo-Json -Depth 5 -Compress)
        Headers     = $Response.Headers
    }
    $responseType = 'HttpResponseContext' -as [type]
    if ($null -eq $responseType) {
        return $context
    }

    $converted = $null
    $failure = 'conversion returned null'
    try {
        # Explicit conversion so a failure surfaces with its message; -as would swallow it and yield $null.
        $converted = [System.Management.Automation.LanguagePrimitives]::ConvertTo($context, $responseType)
    }
    catch {
        $failure = $_.Exception.Message
    }
    if ($null -eq $converted) {
        Write-WatchdogLog -Level Warning -RunId $RunId -Message ("HttpResponseContext conversion failed " +
            "($failure); pushing plain hashtable with status $($context.StatusCode)")
        return $context
    }
    return $converted
}

#endregion

#region Main Functions

function Invoke-WatchdogAlertFlow {
    <#
    .SYNOPSIS
        Runs the 6.4 flow and returns a response descriptor; never pushes a binding itself.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [object]$Request,

        [Parameter(Mandatory)]
        [string]$RunId
    )

    try {
        $config = Get-WatchdogConfig
    }
    catch {
        Write-WatchdogLog -Level Error -RunId $RunId -Message "Configuration guard failed: $($_.Exception.Message)"
        return (ConvertTo-WatchdogRejection -StatusCode 500 -Code 'config_unresolved' -Errors @($_.Exception.Message))
    }

    $clientAddress = Get-WatchdogClientAddress -Headers $Request.Headers
    $body = $Request.Body
    if ($body -isnot [System.Collections.IDictionary]) {
        Write-WatchdogLog -Level Warning -RunId $RunId -Message ("Rejected request from $clientAddress with 400: " +
            'body is not a JSON object')
        return (ConvertTo-WatchdogRejection -StatusCode 400 -Code 'invalid_body' `
            -Errors @('Request body must be a JSON object'))
    }

    $errors = @(Test-WatchdogPayload -Payload $body)
    if ($errors.Count -gt 0) {
        Write-WatchdogLog -Level Warning -RunId $RunId -Message ("Rejected request from $clientAddress with 400: " +
            "$($errors.Count) validation error(s): $($errors -join ' | ')")
        return (ConvertTo-WatchdogRejection -StatusCode 400 -Code 'invalid_payload' -Errors $errors)
    }

    $hostName = [string]$body['HostName']
    $eventType = [string]$body['EventType']
    $eventId = [string]$body['EventId']
    $siteName = [string]$body['SiteName']
    $allowedSites = @($config.AllowedSites)
    if ($allowedSites.Count -gt 0 -and $allowedSites -notcontains $siteName) {
        Write-WatchdogLog -Level Warning -RunId $RunId -HostName $hostName -Message ("Rejected request from " +
            "$clientAddress with 403: site '$siteName' is not in WATCHDOG_ALLOWED_SITES")
        return (ConvertTo-WatchdogRejection -StatusCode 403 -Code 'site_not_allowed' `
            -Errors @("Site '$siteName' is not allowed"))
    }

    try {
        Set-WatchdogHostEntity -Config $config -Payload $body
    }
    catch {
        Write-WatchdogLog -Level Warning -RunId $RunId -HostName $hostName -Message ("Host row write failed: " +
            "$($_.Exception.Message); continuing")
    }

    if ($eventType -eq 'heartbeat') {
        Write-WatchdogLog -RunId $RunId -HostName $hostName -Message "Heartbeat recorded for site '$siteName'"
        return (ConvertTo-WatchdogAcceptance -EmailSent $false -Duplicate $false)
    }

    $hostKey = ConvertTo-WatchdogKey -Value $hostName -Upper
    if ($eventType -ne 'test') {
        if (Test-WatchdogSentEvent -Config $config -HostKey $hostKey -EventId $eventId) {
            Write-WatchdogLog -RunId $RunId -HostName $hostName `
                -Message "Event $eventId was already sent; duplicate ignored"
            return (ConvertTo-WatchdogAcceptance -EmailSent $false -Duplicate $true)
        }
    }

    if ($eventType -ne 'recovered') {
        if (-not (Test-WatchdogRateLimit -HostKey $hostKey -Limit $config.MaxAlertsPerHostPerHour)) {
            Write-WatchdogLog -Level Warning -RunId $RunId -HostName $hostName -Message ("Rate limit of " +
                "$($config.MaxAlertsPerHostPerHour) alerts per hour reached; event $eventId not sent")
            return (ConvertTo-WatchdogRejection -StatusCode 429 -Code 'rate_limited' `
                -Errors @("Rate limit of $($config.MaxAlertsPerHostPerHour) alerts per host per hour reached") `
                -Headers @{ 'Retry-After' = $script:RateLimitRetryAfterSeconds })
        }
    }

    $email = ConvertTo-WatchdogEmail -Payload $body -Config $config
    $result = Send-WatchdogMail -Config $config -Subject $email.Subject -TextBody $email.TextBody `
        -HtmlBody $email.HtmlBody
    if (-not $result.Sent) {
        Write-WatchdogLog -Level Error -RunId $RunId -HostName $hostName -Message ("Mail provider failed for event " +
            "$eventId ($eventType): $($result.Error)")
        return (ConvertTo-WatchdogRejection -StatusCode 502 -Code 'provider_failed' -Errors @([string]$result.Error))
    }

    try {
        Set-WatchdogSentEvent -Config $config -HostKey $hostKey -Payload $body `
            -ProviderMessageId $result.ProviderMessageId
    }
    catch {
        Write-WatchdogLog -Level Warning -RunId $RunId -HostName $hostName -Message ("Sent-event write failed: " +
            "$($_.Exception.Message); continuing")
    }

    Write-WatchdogLog -RunId $RunId -HostName $hostName -Message ("Sent $eventType event $eventId via " +
        "$($config.MailProvider) (provider id $($result.ProviderMessageId))")
    return (ConvertTo-WatchdogAcceptance -EmailSent $true -Duplicate $false `
        -ProviderMessageId $result.ProviderMessageId)
}

#endregion

#region Script Body

$runId = Get-WatchdogRunId -TriggerMetadata $TriggerMetadata
$response = $null
try {
    # The Modules folder is on PSModulePath in the worker; an already-loaded module (tests) is reused.
    if (-not (Get-Module -Name 'ServiceWatchdogAlert')) {
        Import-Module -Name 'ServiceWatchdogAlert' -ErrorAction Stop
    }
    $response = Invoke-WatchdogAlertFlow -Request $Request -RunId $runId
}
catch {
    Write-WatchdogLog -Level Error -RunId $runId -Message ("Unexpected error in $($script:HostsAlertFunctionName): " +
        "$($_.Exception.Message) at $($_.ScriptStackTrace)")
    $response = ConvertTo-WatchdogRejection -StatusCode 500 -Code 'internal_error' `
        -Errors @('Unexpected error; see function logs')
}

# Exactly one push per invocation: every branch above returns a descriptor, never pushes.
Push-OutputBinding -Name Response -Value (ConvertTo-WatchdogHttpResponse -Response $response -RunId $runId)

#endregion

#region Cleanup

# Nothing to release: no files, connections or temporary resources are held open.

#endregion
