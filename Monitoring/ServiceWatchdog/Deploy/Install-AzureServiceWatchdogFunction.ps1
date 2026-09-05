#Requires -Version 7.4
#Requires -Modules Az.Accounts, Az.Resources, Az.Websites, Az.KeyVault

<#
.SYNOPSIS
    Deploys the ServiceWatchdog alert relay (Function App, Key Vault, storage, App Insights) to Azure.

.DESCRIPTION
    Runs from an operator workstation with a signed-in Az session and performs the whole
    Azure side of a ServiceWatchdog rollout (DESIGN.md section 7.2):

      1. Checks prerequisites: the Az modules, the Bicep CLI on PATH, the template and the
         function source folder, and a signed-in context on the requested subscription.
         Resolves the deploying identity (user or service principal) so the template can
         grant it Key Vault Secrets Officer.
      2. Creates the resource group when it does not exist (-Location required then).
      3. Deploys Deploy\main.bicep with New-AzResourceGroupDeployment.
      4. Seeds the mail provider secret in Key Vault (Smtp2GoApiKey or SmtpPassword,
         whichever -MailProvider needs), retrying on 403 while the role assignment
         propagates.
      5. Packages the AzureFunction folder (host.json at the archive root, local.settings
         files excluded) and publishes it with Publish-AzWebApp.
      6. Restarts the app so the Key Vault references resolve and waits for
         SendServiceWatchdogAlert to be listed.
      7. Creates the named function key and reads it back. A key of that name left by an
         earlier run is reused, never regenerated, so servers already configured keep working.
      8. Prints the alert URL, the key and the two lines to paste into ServiceWatchdog.json
         to the console only. The key is never written to the log file.
      9. Verifies that admin endpoint isolation (functionsRuntimeAdminIsolationEnabled) is
         on, patching it on when the site does not report it. Deliberately after step 8: the
         property is absent from the ARM schema, so a platform that drops it from the GET
         response must never withhold the key from an otherwise finished deployment. A
         value that still reads false is logged with the raw response and ends the run
         with exit 50 after the remaining steps.
     10. Optionally posts a test event to the new endpoint (-SendTestEmail) and reports the
         function's verdict, including its error code when the event is rejected.

    Every step is idempotent, so the script can be re-run after fixing a failure (or to
    change -MailTo or redeploy the function code). Under -DryRun the template is evaluated
    with -WhatIf and nothing is changed.

.PARAMETER SubscriptionId
    Subscription to deploy into. When omitted the subscription of the current Az context is
    used; when given and different from the context, Set-AzContext selects it first.

.PARAMETER ResourceGroupName
    Resource group that receives every resource. Created when missing (see -Location).

.PARAMETER Location
    Azure region used only when the resource group has to be created, e.g. eastus2. Every
    resource inherits the resource group location.

.PARAMETER BaseName
    Prefix for every resource name: 3 to 14 lowercase letters, digits or hyphens. Storage,
    Key Vault and Function App names get a six-character unique suffix from the template.

.PARAMETER MailProvider
    Smtp2GoApi (default) sends through the SMTP2GO REST API and needs -Smtp2GoApiKey. Smtp
    sends through an authenticated relay with STARTTLS and needs -SmtpHost and -SmtpCredential.

.PARAMETER MailFrom
    Sender for every alert, e.g. "Service Watchdog <alerts@example.com>". Must be a verified
    sender at the provider.

.PARAMETER MailTo
    Semicolon-separated list of recipient addresses.

.PARAMETER MailSubjectPrefix
    Text prepended to every alert subject. Default "[Service Watchdog]".

.PARAMETER Smtp2GoApiKey
    SMTP2GO API key as a SecureString, stored in Key Vault as secret Smtp2GoApiKey. Required
    when -MailProvider is Smtp2GoApi. Never logged.

.PARAMETER SmtpHost
    SMTP relay host name, e.g. mail.example.com. Required when -MailProvider is Smtp.

.PARAMETER SmtpPort
    SMTP relay port. Default 587; 2525 is the usual alternative. Port 25 is blocked on most
    Azure subscriptions.

.PARAMETER SmtpCredential
    Relay credential. The user name goes into the app settings, the password into Key Vault
    as secret SmtpPassword. Required when -MailProvider is Smtp. Never logged.

.PARAMETER SmtpUseStartTls
    Upgrade the SMTP session with STARTTLS. Default $true. Implicit TLS on port 465 is not
    supported by the function.

.PARAMETER PowerShellVersion
    Functions PowerShell worker version, 7.4 (default) or 7.6.

.PARAMETER FunctionKeyName
    Name of the function key created for the endpoint scripts. Default watchdog. Use a
    different name per site or when rotating keys. When a key of this name already exists
    on the function (a re-run), its value is read back and reused; the script never
    regenerates an existing key. To rotate, deploy with a new name, update every server,
    then delete the old key, as the README describes.

.PARAMETER SourcePath
    Folder containing the function app (host.json at its root). Defaults to the
    AzureFunction folder beside this script's parent folder.

.PARAMETER SendTestEmail
    After deployment, POST a test event to the alert URL with the new key and report the
    function's response; a rejection is logged with the HTTP status and the function's
    error code (invalid_payload, site_not_allowed, rate_limited, provider_failed, ...).
    This sends a real email to -MailTo.

.PARAMETER DryRun
    Validates prerequisites and the sign-in, runs the template with -WhatIf and prints the
    change summary. Creates, changes and sends nothing.

.PARAMETER Verbosity
    Console output level: Low (errors and success only, default), Medium (adds warnings),
    High (everything). The log file always receives every line.

.PARAMETER LogPath
    Log file path. Defaults to
    $env:ProgramData\ServiceWatchdog\Logs\Install-AzureServiceWatchdogFunction-<timestamp>.log, or
    $HOME/.ServiceWatchdog/Logs/... where ProgramData is not defined (macOS, Linux).

.EXAMPLE
    $apiKey = Read-Host -Prompt 'SMTP2GO API key' -AsSecureString
    .\Install-AzureServiceWatchdogFunction.ps1 -ResourceGroupName 'rg-servicewatchdog' -Location 'eastus2' `
        -BaseName 'svcwatchdog' -MailFrom 'Service Watchdog <alerts@example.com>' -MailTo 'it@example.com' `
        -Smtp2GoApiKey $apiKey -SendTestEmail -Verbosity Medium

    Deploys with the SMTP2GO REST provider, creates the resource group if needed, and sends
    a test email at the end.

.EXAMPLE
    .\Install-AzureServiceWatchdogFunction.ps1 -ResourceGroupName 'rg-servicewatchdog' -BaseName 'svcwatchdog' `
        -MailProvider Smtp -SmtpHost 'mail.example.com' -SmtpPort 587 -SmtpCredential (Get-Credential) `
        -MailFrom 'alerts@example.com' -MailTo 'it@example.com;oncall@example.com'

    Deploys with an authenticated SMTP relay into an existing resource group.

.EXAMPLE
    .\Install-AzureServiceWatchdogFunction.ps1 -ResourceGroupName 'rg-servicewatchdog' -BaseName 'svcwatchdog' `
        -MailFrom 'alerts@example.com' -MailTo 'it@example.com' -Smtp2GoApiKey $apiKey -DryRun -Verbosity High

    Checks prerequisites and the sign-in, then prints the template what-if summary. Nothing
    is created or changed.

.NOTES
    Version:    1.0.0
    Created:    2026-09-04
    Requires:   PowerShell 7.4 or later (Windows, macOS or Linux); Az 9.7.1 or later
                (Az.Accounts, Az.Resources, Az.Websites, Az.KeyVault) so Publish-AzWebApp
                can fall back to Entra ID authentication; the Bicep CLI on PATH
                (https://aka.ms/bicep-install); Contributor plus User Access Administrator
                (or Owner) on the target resource group, and permission to read the
                signed-in user or service principal in Entra ID.
    Exit codes: 0 success; 1 unexpected error; 2 prerequisites or parameters; 20 not signed
                in or not authorized; 50 deployed, but a post-deployment step failed (the
                log names the step; re-run after fixing the cause).
    Key rotation, SCM basic-auth policy errors and Key Vault name reuse after deleting a
    resource group are documented in the README.
    Checklist deviations (powershell-authoring): 4.6 the log root is product-named
    ($env:ProgramData\ServiceWatchdog\Logs) rather than $MSPName because the tool is deployed
    by end-client IT; 5.2 secrets arrive as SecureString or PSCredential parameters and are
    written straight into Key Vault, which this script provisions, so no SecretManagement
    vault is read; 5.7 the script ships unsigned in the public repository, adopters sign it
    with their own certificate; 6.6 the integration test is the -SendTestEmail acceptance
    run; 6.7 not applicable, run time is bounded by the fixed 5-minute propagation windows.
    Developed with AI assistance (Claude); reviewed before publication.
#>

[CmdletBinding()]
param (
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._()\-]{1,90}$')]
    [string]$ResourceGroupName,

    [ValidatePattern('^[A-Za-z0-9 ]{2,40}$')]
    [string]$Location,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9-]{3,14}$')]
    [string]$BaseName,

    [ValidateSet('Smtp2GoApi', 'Smtp')]
    [string]$MailProvider = 'Smtp2GoApi',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MailFrom,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MailTo,

    [ValidateNotNullOrEmpty()]
    [string]$MailSubjectPrefix = '[Service Watchdog]',

    [securestring]$Smtp2GoApiKey,

    [string]$SmtpHost,

    [ValidateRange(1, 65535)]
    [int]$SmtpPort = 587,

    [pscredential]$SmtpCredential,

    [bool]$SmtpUseStartTls = $true,

    [ValidateSet('7.4', '7.6')]
    [string]$PowerShellVersion = '7.4',

    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')]
    [string]$FunctionKeyName = 'watchdog',

    [string]$SourcePath,

    [switch]$SendTestEmail,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Low',

    [string]$LogPath
)

#region Configuration & Constants

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.0.0'
$script:Verbosity = $Verbosity
$script:DryRun = $DryRun.IsPresent
$scriptStartTime = Get-Date

# Values that must never reach the log file (the function key once it is known). Write-Log
# masks every occurrence.
$script:SensitiveValues = [System.Collections.Generic.List[string]]::new()

$script:RequiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Websites', 'Az.KeyVault')
$script:AlertFunctionName = 'SendServiceWatchdogAlert'
$script:WebApiVersion = '2024-04-01'
$script:Smtp2GoSecretName = 'Smtp2GoApiKey'
$script:SmtpPasswordSecretName = 'SmtpPassword'

# Role assignments, package sync and key storage all need a propagation window (7.2 steps
# 4, 6 and 7): poll every 15 seconds for up to 5 minutes.
$script:PropagationTimeoutSeconds = 300
$script:PropagationIntervalSeconds = 15
$script:TestEmailTimeoutSeconds = 90

$script:TemplatePath = Join-Path -Path $PSScriptRoot -ChildPath 'main.bicep'
if (-not $SourcePath) {
    $SourcePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'AzureFunction'
}
$SourcePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourcePath)

# Log path: product-named root per DESIGN.md section 3; workstations without ProgramData
# (macOS, Linux) log under the user's home folder.
if (-not $LogPath) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
    if (-not $scriptName) { $scriptName = 'Install-AzureServiceWatchdogFunction' }
    if ($env:ProgramData) {
        $logRoot = Join-Path -Path $env:ProgramData -ChildPath 'ServiceWatchdog' -AdditionalChildPath 'Logs'
    }
    else {
        $logRoot = Join-Path -Path $HOME -ChildPath '.ServiceWatchdog' -AdditionalChildPath 'Logs'
    }
    $LogPath = Join-Path -Path $logRoot -ChildPath "$scriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}
$script:LogPath = $LogPath

$logDir = Split-Path -Path $script:LogPath -Parent
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

#endregion

#region Helper Functions

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    foreach ($secret in $script:SensitiveValues) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $Message = $Message.Replace($secret, '***')
        }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logMessage = "[$timestamp] [$Level] $Message"

    $writeToConsole = switch ($script:Verbosity) {
        'Low' { $Level -in 'ERROR', 'SUCCESS' }
        'Medium' { $Level -in 'ERROR', 'WARNING', 'SUCCESS' }
        'High' { $true }
        default { $true }
    }

    if ($writeToConsole) {
        $color = switch ($Level) {
            'ERROR' { 'Red' }
            'WARNING' { 'Yellow' }
            'SUCCESS' { 'Green' }
            'DEBUG' { 'Cyan' }
            default { 'White' }
        }
        Write-Host $logMessage -ForegroundColor $color
    }

    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $logMessage
    }
}

function Invoke-Action {
    param (
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if ($script:DryRun) {
        Write-Log "[DRYRUN] Would execute: $Description" -Level 'INFO'
    }
    else {
        Write-Log "Executing: $Description" -Level 'INFO'
        try {
            & $Action
        }
        catch {
            Write-Log "Failed: $Description - $_" -Level 'ERROR'
            throw
        }
    }
}

function Invoke-WatchdogRetry {
    <#
    .SYNOPSIS
        Runs an action until it returns a value, sleeping between attempts.
    .DESCRIPTION
        A $null result means "not ready yet" and is retried. An error is retried only when
        -RetryOn returns $true for it; otherwise it is rethrown at once. When the window is
        exhausted the function throws naming the description.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [ValidateRange(1, 600)]
        [int]$IntervalSeconds,

        [scriptblock]$RetryOn = { $false }
    )

    $maxAttempts = [math]::Max(1, [math]::Ceiling($TimeoutSeconds / $IntervalSeconds))
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $result = & $Action
            if ($null -ne $result) {
                return $result
            }
            Write-Log "Waiting for $Description (attempt $attempt of $maxAttempts)" -Level 'INFO'
        }
        catch {
            if (-not (& $RetryOn $_)) {
                throw
            }
            Write-Log "Attempt $attempt of $maxAttempts for $Description failed: $_" -Level 'WARNING'
        }
        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for $Description."
}

function Test-WatchdogForbiddenError {
    # True for the 403 an Az cmdlet raises while a role assignment is still propagating.
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    if ($exception.PSObject.Properties['Status'] -and [int]$exception.Status -eq 403) {
        return $true
    }
    return ($exception.Message -match '\b403\b|Forbidden')
}

function Test-WatchdogAuthorizationError {
    # True when Azure refused a call for lack of permissions (exit code 20 territory).
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if (Test-WatchdogForbiddenError -ErrorRecord $ErrorRecord) {
        return $true
    }
    # ExpiredAuthenticationToken / InvalidAuthenticationToken are ARM's codes for a stale
    # sign-in; Az.Accounts phrases the same condition as "Run Connect-AzAccount to login".
    return ($ErrorRecord.Exception.Message -match ('AuthorizationFailed|does not have authorization|\b401\b|' +
        'ExpiredAuthenticationToken|InvalidAuthenticationToken|Connect-AzAccount'))
}

function Test-WatchdogNotFoundError {
    # True when an Az cmdlet reports that the requested resource does not exist, as opposed
    # to any other failure (expired token, 403, network) that must not be read as "missing".
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    if ($exception.PSObject.Properties['Status'] -and [int]$exception.Status -eq 404) {
        return $true
    }
    return ($exception.Message -match 'ResourceGroupNotFound|ResourceNotFound|does not exist|could not be found')
}

function Get-WatchdogModuleVersion {
    # Wrapped so tests can mock module discovery.
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    $module = Get-Module -ListAvailable -Name $Name | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($module) {
        return $module.Version
    }
    return $null
}

function Get-WatchdogBicepVersion {
    # Wrapped so tests can mock the external process.
    $output = & bicep --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "bicep --version exited with code $LASTEXITCODE."
    }
    return ($output | Select-Object -First 1)
}

function Get-WatchdogRestErrorText {
    # Turns a failed Invoke-AzRestMethod response into "code: message" from the ARM
    # DefaultErrorResponse body, or the trimmed raw body when it is not that shape, so a
    # non-2xx status is logged with the reason the service gave and not just the number.
    param (
        [Parameter(Mandatory)]
        [object]$Response
    )

    $content = [string]$Response.Content
    if ([string]::IsNullOrWhiteSpace($content)) {
        return ''
    }
    try {
        $parsed = $content | ConvertFrom-Json -Depth 20
        if ($parsed -and $parsed.error) {
            $code = [string]$parsed.error.code
            $message = [string]$parsed.error.message
            if ($code -or $message) {
                return (@($code, $message) | Where-Object { $_ }) -join ': '
            }
        }
    }
    catch {
        Write-Log "Response body is not JSON: $($_.Exception.Message)" -Level 'DEBUG'
    }
    $text = ($content -replace '\s+', ' ').Trim()
    if ($text.Length -gt 300) {
        $text = $text.Substring(0, 300) + '...'
    }
    return $text
}

function ConvertFrom-WatchdogRestContent {
    # Parses the JSON body of an Invoke-AzRestMethod response; empty bodies become $null.
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }
    return ($Content | ConvertFrom-Json -Depth 20)
}

function Show-WatchdogSummary {
    # Console only, on purpose: the key must never reach the log file (7.2 step 8).
    param (
        [Parameter(Mandatory)]
        [string]$FunctionAppName,

        [Parameter(Mandatory)]
        [string]$AlertUrl,

        [Parameter(Mandatory)]
        [string]$FunctionKey,

        [Parameter(Mandatory)]
        [string]$KeyVaultName
    )

    $line = '=' * 78
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host 'ServiceWatchdog alert relay deployed' -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host "Function App : $FunctionAppName"
    Write-Host "Alert URL    : $AlertUrl"
    Write-Host "Function key : $FunctionKey"
    Write-Host "Key Vault    : $KeyVaultName"
    Write-Host ''
    Write-Host 'Paste these two lines into the "Webhook" section of ServiceWatchdog.json on every server:'
    Write-Host "    `"Url`": `"$AlertUrl`","
    Write-Host "    `"FunctionKey`": `"$FunctionKey`","
    Write-Host ''
    Write-Host 'The key is shown once and is not written to the log. Read it again later with:'
    Write-Host ("    Invoke-AzRestMethod -Method POST -Path '<site resource id>/functions/" +
        "$script:AlertFunctionName/listkeys?api-version=$script:WebApiVersion'")
    Write-Host $line -ForegroundColor Cyan
    Write-Host ''
}

#endregion

#region Main Functions

function Test-WatchdogDeploymentParameter {
    # Returns one message per parameter problem; an empty result means the set is valid.
    param (
        [Parameter(Mandatory)]
        [string]$MailProvider,

        [securestring]$Smtp2GoApiKey,

        [string]$SmtpHost,

        [pscredential]$SmtpCredential,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$TemplatePath
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    if ($MailProvider -eq 'Smtp2GoApi' -and -not $Smtp2GoApiKey) {
        $problems.Add('-Smtp2GoApiKey is required when -MailProvider is Smtp2GoApi.')
    }
    if ($MailProvider -eq 'Smtp') {
        if ([string]::IsNullOrWhiteSpace($SmtpHost)) {
            $problems.Add('-SmtpHost is required when -MailProvider is Smtp.')
        }
        if (-not $SmtpCredential) {
            $problems.Add('-SmtpCredential is required when -MailProvider is Smtp.')
        }
    }

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        $problems.Add("Bicep template not found: $TemplatePath")
    }

    $hostJson = Join-Path -Path $SourcePath -ChildPath 'host.json'
    if (-not (Test-Path -LiteralPath $hostJson -PathType Leaf)) {
        $problems.Add("Function source folder must contain host.json; not found at $hostJson (check -SourcePath).")
    }

    return $problems.ToArray()
}

function Test-WatchdogPrerequisite {
    # Returns one message per missing tool; an empty result means everything is present.
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($moduleName in $script:RequiredModules) {
        $version = Get-WatchdogModuleVersion -Name $moduleName
        if ($version) {
            Write-Log "Module $moduleName $version found" -Level 'DEBUG'
        }
        else {
            $problems.Add("Module $moduleName is not installed. Run: Install-Module Az -Scope CurrentUser (Az 9.7.1+).")
        }
    }

    $bicep = Get-Command -Name 'bicep' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $bicep) {
        $problems.Add('Bicep CLI not found on PATH. Install it from https://aka.ms/bicep-install (Az does not ship it)')
    }
    else {
        try {
            $bicepVersion = Get-WatchdogBicepVersion
            Write-Log "Bicep CLI: $bicepVersion" -Level 'DEBUG'
        }
        catch {
            $problems.Add("Bicep CLI is on PATH but 'bicep --version' failed: $_")
        }
    }

    return $problems.ToArray()
}

function Get-WatchdogDeployer {
    <#
    .SYNOPSIS
        Confirms the Az sign-in and resolves the deploying identity for the template.
    #>
    param (
        [string]$SubscriptionId
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or -not $context.Account) {
        throw 'No Azure context. Run Connect-AzAccount (add -Tenant/-Subscription as needed) and re-run.'
    }

    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        Write-Log "Selecting subscription $SubscriptionId (context was on $($context.Subscription.Id))" -Level 'INFO'
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
    if (-not $context.Subscription -or -not $context.Subscription.Id) {
        throw 'The Azure context has no subscription. Run Connect-AzAccount -Subscription <id> and re-run.'
    }

    $accountType = [string]$context.Account.Type
    Write-Log ("Signed in as {0} ({1}) on subscription {2} ({3})" -f $context.Account.Id, $accountType,
        $context.Subscription.Name, $context.Subscription.Id) -Level 'INFO'

    if ($accountType -eq 'User') {
        $user = Get-AzADUser -SignedIn -ErrorAction Stop
        if (-not $user -or -not $user.Id) {
            throw 'Get-AzADUser -SignedIn returned nothing; the account needs permission to read its own object.'
        }
        $objectId = [string]$user.Id
        $principalType = 'User'
    }
    else {
        $servicePrincipal = Get-AzADServicePrincipal -ApplicationId $context.Account.Id -ErrorAction Stop
        if (-not $servicePrincipal -or -not $servicePrincipal.Id) {
            throw "No service principal found for application id $($context.Account.Id)."
        }
        $objectId = [string]$servicePrincipal.Id
        $principalType = 'ServicePrincipal'
    }
    Write-Log "Deployer object id $objectId ($principalType) receives Key Vault Secrets Officer" -Level 'INFO'

    return @{
        ObjectId       = $objectId
        PrincipalType  = $principalType
        SubscriptionId = [string]$context.Subscription.Id
        TenantId       = [string]$context.Tenant.Id
    }
}

function Get-WatchdogResourceGroup {
    # Returns the resource group, or $null only when Azure says it does not exist. Every
    # other failure (stale token, 403, network) is rethrown so the caller can route it to
    # exit 20 or 1 instead of trying to create a group that may well be there.
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        return (Get-AzResourceGroup -Name $Name -ErrorAction Stop)
    }
    catch {
        if (Test-WatchdogNotFoundError -ErrorRecord $_) {
            Write-Log "Get-AzResourceGroup reports $Name as missing: $_" -Level 'DEBUG'
            return $null
        }
        throw
    }
}

function Get-WatchdogTemplateParameter {
    # Builds the parameter object for main.bicep. Secrets never appear here: the template
    # holds Key Vault references and the install script seeds the secrets afterwards.
    param (
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [hashtable]$Deployer
    )

    $smtpUsername = ''
    if ($Settings.SmtpCredential) {
        $smtpUsername = [string]$Settings.SmtpCredential.UserName
    }

    return @{
        baseName              = $Settings.BaseName
        powerShellVersion     = $Settings.PowerShellVersion
        mailProvider          = $Settings.MailProvider
        mailFrom              = $Settings.MailFrom
        mailTo                = $Settings.MailTo
        mailSubjectPrefix     = $Settings.MailSubjectPrefix
        smtpHost              = [string]$Settings.SmtpHost
        smtpPort              = [int]$Settings.SmtpPort
        smtpUsername          = $smtpUsername
        smtpUseStartTls       = [bool]$Settings.SmtpUseStartTls
        deployerObjectId      = $Deployer.ObjectId
        deployerPrincipalType = $Deployer.PrincipalType
    }
}

function Invoke-WatchdogTemplateDeployment {
    # Returns the deployment result, or $null under -DryRun after the what-if summary.
    param (
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [Parameter(Mandatory)]
        [hashtable]$TemplateParameter
    )

    $deploymentName = "ServiceWatchdog-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $deploymentArguments = @{
        Name                    = $deploymentName
        ResourceGroupName       = $ResourceGroupName
        TemplateFile            = $TemplatePath
        TemplateParameterObject = $TemplateParameter
        Mode                    = 'Incremental'
        ErrorAction             = 'Stop'
    }

    if ($script:DryRun) {
        Write-Log "[DRYRUN] Would deploy $TemplatePath to $ResourceGroupName; running what-if instead" -Level 'INFO'
        New-AzResourceGroupDeployment @deploymentArguments -WhatIf
        return $null
    }

    $description = "Deploy $TemplatePath to resource group $ResourceGroupName as $deploymentName"
    $result = Invoke-Action -Description $description -Action { New-AzResourceGroupDeployment @deploymentArguments }
    Write-Log "Deployment $deploymentName finished with state $($result.ProvisioningState)" -Level 'INFO'
    return $result
}

function Get-WatchdogDeploymentOutput {
    # Reads the named template outputs into a hashtable; throws naming the first missing one.
    param (
        [Parameter(Mandatory)]
        $Deployment,

        [Parameter(Mandatory)]
        [string[]]$Name
    )

    $outputs = @{}
    foreach ($outputName in $Name) {
        $entry = $null
        if ($Deployment.Outputs) {
            $entry = $Deployment.Outputs[$outputName]
        }
        if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            throw "The deployment returned no '$outputName' output; check main.bicep and the deployment in the portal."
        }
        $outputs[$outputName] = [string]$entry.Value
        Write-Log "Output ${outputName}: $($outputs[$outputName])" -Level 'INFO'
    }
    return $outputs
}

function Save-WatchdogSecret {
    # Seeds one Key Vault secret, retrying on 403 while the Secrets Officer assignment
    # from the template propagates (7.2 step 4).
    param (
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [securestring]$SecretValue
    )

    Invoke-Action -Description "Seed Key Vault secret '$Name' in $VaultName" -Action {
        Invoke-WatchdogRetry -Description "Set-AzKeyVaultSecret $Name (role assignment propagation)" `
            -TimeoutSeconds $script:PropagationTimeoutSeconds -IntervalSeconds $script:PropagationIntervalSeconds `
            -RetryOn { param ($ErrorRecord) Test-WatchdogForbiddenError -ErrorRecord $ErrorRecord } `
            -Action {
                Set-AzKeyVaultSecret -VaultName $VaultName -Name $Name -SecretValue $SecretValue -ErrorAction Stop |
                    Out-Null
                return $true
            } | Out-Null
    }
}

function Compress-WatchdogPackage {
    # Zips the contents of the function folder so host.json sits at the archive root,
    # leaving out local.settings*.json (7.2 step 5). Returns the archive path.
    param (
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    $uniquePart = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $archiveName = "ServiceWatchdog-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$uniquePart.zip"
    $archivePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $archiveName

    $items = @(Get-ChildItem -LiteralPath $SourcePath | Where-Object { $_.Name -notlike 'local.settings*.json' })
    if ($items.Count -eq 0) {
        throw "Nothing to package in $SourcePath."
    }
    $excluded = @(Get-ChildItem -LiteralPath $SourcePath -Filter 'local.settings*.json' |
            Select-Object -ExpandProperty Name)
    if ($excluded.Count -gt 0) {
        Write-Log "Excluding from the package: $($excluded -join ', ')" -Level 'INFO'
    }

    Invoke-Action -Description "Package $($items.Count) items from $SourcePath into $archivePath" -Action {
        Compress-Archive -Path $items.FullName -DestinationPath $archivePath -CompressionLevel Optimal -Force
    }
    return $archivePath
}

function Publish-WatchdogPackage {
    param (
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ArchivePath
    )

    try {
        Invoke-Action -Description "Publish $ArchivePath to function app $Name" -Action {
            Publish-AzWebApp -ResourceGroupName $ResourceGroupName -Name $Name -ArchivePath $ArchivePath -Force `
                -ErrorAction Stop | Out-Null
        }
    }
    catch {
        if ($_.Exception.Message -match '\b401\b|Unauthorized') {
            throw ('Publish-AzWebApp was refused (401): SCM basic authentication is disabled on this app or by ' +
                "policy. Allow it on the app's basicPublishingCredentialsPolicies 'scm' resource (see README " +
                'troubleshooting) or update Az so Publish-AzWebApp can use Entra ID authentication, then re-run. ' +
                "Original error: $_")
        }
        throw
    }
}

function Get-WatchdogAdminIsolationState {
    param (
        [Parameter(Mandatory)]
        [string]$SiteResourceId
    )

    $response = Invoke-AzRestMethod -Method GET -Path "${SiteResourceId}?api-version=$script:WebApiVersion"
    if ($response.StatusCode -ne 200) {
        throw "Reading the site returned HTTP $($response.StatusCode)."
    }
    $site = ConvertFrom-WatchdogRestContent -Content $response.Content
    $raw = $null
    if ($site.properties -and $site.properties.PSObject.Properties['functionsRuntimeAdminIsolationEnabled']) {
        $raw = $site.properties.functionsRuntimeAdminIsolationEnabled
    }
    $shown = if ($null -eq $raw) { '<absent from the response>' } else { [string]$raw }
    Write-Log "Site reports functionsRuntimeAdminIsolationEnabled = $shown" -Level 'INFO'
    return ($raw -eq $true)
}

function Confirm-WatchdogAdminIsolation {
    # The template sets functionsRuntimeAdminIsolationEnabled, but the property is missing
    # from the ARM schema (BCP037), so verify it and patch it on when needed (7.2 step 6).
    param (
        [Parameter(Mandatory)]
        [string]$SiteResourceId
    )

    if (Get-WatchdogAdminIsolationState -SiteResourceId $SiteResourceId) {
        Write-Log 'functionsRuntimeAdminIsolationEnabled is true' -Level 'INFO'
        return
    }

    Write-Log 'functionsRuntimeAdminIsolationEnabled is not true; patching it on' -Level 'WARNING'
    Invoke-Action -Description 'Enable functionsRuntimeAdminIsolationEnabled on the function app' -Action {
        $payload = '{"properties":{"functionsRuntimeAdminIsolationEnabled":true}}'
        $response = Invoke-AzRestMethod -Method PATCH -Path "${SiteResourceId}?api-version=$script:WebApiVersion" `
            -Payload $payload
        if ($response.StatusCode -notin 200, 202) {
            throw "PATCH returned HTTP $($response.StatusCode)."
        }
    }

    if (-not (Get-WatchdogAdminIsolationState -SiteResourceId $SiteResourceId)) {
        throw 'functionsRuntimeAdminIsolationEnabled is still not true after the PATCH; check the site in the portal.'
    }
    Write-Log 'functionsRuntimeAdminIsolationEnabled is now true' -Level 'INFO'
}

function Wait-WatchdogFunction {
    # Polls the ARM functions list until the alert function has been synced from the package.
    param (
        [Parameter(Mandatory)]
        [string]$SiteResourceId,

        [Parameter(Mandatory)]
        [string]$FunctionName
    )

    $listPath = "$SiteResourceId/functions?api-version=$script:WebApiVersion"
    Invoke-WatchdogRetry -Description "function $FunctionName to be listed on the app" `
        -TimeoutSeconds $script:PropagationTimeoutSeconds -IntervalSeconds $script:PropagationIntervalSeconds `
        -Action {
            $response = Invoke-AzRestMethod -Method GET -Path $listPath
            if ($response.StatusCode -ne 200) {
                Write-Log "Functions list returned HTTP $($response.StatusCode)" -Level 'WARNING'
                return $null
            }
            $list = ConvertFrom-WatchdogRestContent -Content $response.Content
            $match = @($list.value) | Where-Object {
                $_.properties.name -eq $FunctionName -or $_.name -eq $FunctionName -or $_.name -like "*/$FunctionName"
            }
            if ($match) {
                return $true
            }
            return $null
        } | Out-Null
    Write-Log "Function $FunctionName is listed" -Level 'INFO'
}

function Get-WatchdogFunctionKeyValue {
    # Reads the named key through listkeys. Returns $null when the call fails or the key is
    # not there; the caller decides whether that is "create it" or an error.
    param (
        [Parameter(Mandatory)]
        [string]$SiteResourceId,

        [Parameter(Mandatory)]
        [string]$FunctionName,

        [Parameter(Mandatory)]
        [string]$KeyName
    )

    $listPath = "$SiteResourceId/functions/$FunctionName/listkeys?api-version=$script:WebApiVersion"
    $response = Invoke-AzRestMethod -Method POST -Path $listPath
    if ($response.StatusCode -ne 200) {
        $detail = Get-WatchdogRestErrorText -Response $response
        if ($detail) { $detail = " ($detail)" }
        Write-Log "listkeys on $FunctionName returned HTTP $($response.StatusCode)$detail" -Level 'WARNING'
        return $null
    }
    $keys = ConvertFrom-WatchdogRestContent -Content $response.Content
    $value = $null
    if ($keys -and $keys.properties) {
        $value = [string]$keys.properties.$KeyName
    }
    if ([string]::IsNullOrEmpty($value)) {
        return $null
    }
    return $value
}

function Request-WatchdogFunctionKey {
    # Returns the named key (7.2 step 7). A key that already exists (re-run) is reused as
    # is: a PUT without a value would make the service generate a fresh one and every
    # server configured with the old value would start getting 401s. Only a missing key is
    # created (the service generates the value) and then read back. The value is registered
    # as sensitive so Write-Log masks it from here on.
    param (
        [Parameter(Mandatory)]
        [string]$SiteResourceId,

        [Parameter(Mandatory)]
        [string]$FunctionName,

        [Parameter(Mandatory)]
        [string]$KeyName
    )

    $existing = Get-WatchdogFunctionKeyValue -SiteResourceId $SiteResourceId -FunctionName $FunctionName `
        -KeyName $KeyName
    if ($existing) {
        $script:SensitiveValues.Add($existing)
        Write-Log ("Existing function key '$KeyName' reused ($($existing.Length) characters); delete it on the " +
            'function or pass another -FunctionKeyName to generate a new one') -Level 'INFO'
        return $existing
    }

    $keyPath = "$SiteResourceId/functions/$FunctionName/keys/${KeyName}?api-version=$script:WebApiVersion"
    # ARM wants the KeyInfo wrapped in a properties object (the REST reference shows the
    # flattened shape, but the service answers 400 "Properties object is not present" without
    # it). No value is sent, so the service generates the key.
    $payload = @{ properties = @{ name = $KeyName } } | ConvertTo-Json -Compress -Depth 3

    Invoke-Action -Description "Create function key '$KeyName' on $FunctionName" -Action {
        Invoke-WatchdogRetry -Description "function key '$KeyName' to be accepted" `
            -TimeoutSeconds $script:PropagationTimeoutSeconds -IntervalSeconds $script:PropagationIntervalSeconds `
            -Action {
                $response = Invoke-AzRestMethod -Method PUT -Path $keyPath -Payload $payload
                if ($response.StatusCode -in 200, 201) {
                    return $true
                }
                if ($response.StatusCode -eq 404 -or $response.StatusCode -ge 500) {
                    Write-Log "Key PUT returned HTTP $($response.StatusCode); the app may still be syncing" `
                        -Level 'WARNING'
                    return $null
                }
                $detail = Get-WatchdogRestErrorText -Response $response
                if ($detail) { $detail = " ($detail)" }
                throw "Creating function key '$KeyName' returned HTTP $($response.StatusCode)$detail."
            } | Out-Null
    }

    $value = Get-WatchdogFunctionKeyValue -SiteResourceId $SiteResourceId -FunctionName $FunctionName `
        -KeyName $KeyName
    if (-not $value) {
        throw "listkeys did not return a key named '$KeyName' after creating it."
    }
    $script:SensitiveValues.Add($value)
    Write-Log "Function key '$KeyName' created and read back ($($value.Length) characters)" -Level 'INFO'
    return $value
}

function Send-WatchdogTestEmail {
    # Posts a spec 4.8 'test' event exactly as the endpoint worker would (7.2 step 9).
    param (
        [Parameter(Mandatory)]
        [string]$AlertUrl,

        [Parameter(Mandatory)]
        [string]$FunctionKey
    )

    $hostName = ([Environment]::MachineName -replace '[^A-Za-z0-9.\-]', '-').TrimStart('.', '-')
    if ([string]::IsNullOrEmpty($hostName)) {
        $hostName = 'operator-workstation'
    }
    $payload = [ordered]@{
        SchemaVersion   = 1
        EventType       = 'test'
        EventId         = [guid]::NewGuid().ToString()
        SiteName        = 'ServiceWatchdog deployment'
        HostName        = $hostName
        Fqdn            = $null
        TimestampUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        RunId           = [guid]::NewGuid().ToString()
        WatchdogVersion = $script:ScriptVersion
        Summary         = 'Test alert sent by Install-AzureServiceWatchdogFunction.ps1'
        Services        = @()
    }
    $body = $payload | ConvertTo-Json -Depth 10
    $headers = @{
        'x-functions-key' = $FunctionKey
        'User-Agent'      = "ServiceWatchdog/$script:ScriptVersion"
    }

    # Every rejection (spec 6.4) is a non-200 with { accepted, error, errors } in the body.
    # Invoke-RestMethod throws on non-2xx and would hide that body, so the status check is
    # skipped and the code is read separately; transport failures still throw as before.
    $response = Invoke-Action -Description "Send a test event to $AlertUrl" -Action {
        $result = Invoke-RestMethod -Method Post -Uri $AlertUrl -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec $script:TestEmailTimeoutSeconds `
            -SkipHttpErrorCheck -StatusCodeVariable 'status' -ErrorAction Stop
        [pscustomobject]@{ StatusCode = $status; Body = $result }
    }
    $verdict = $response.Body
    $hasVerdict = $verdict -and $verdict.PSObject.Properties['accepted']
    if (-not $hasVerdict -or -not $verdict.accepted) {
        $detail = ''
        if ($hasVerdict) {
            $detail = " ($($verdict.error): $(@($verdict.errors) -join '; '))"
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$verdict)) {
            $text = ([string]$verdict) -replace '\s+', ' '
            if ($text.Length -gt 200) { $text = $text.Substring(0, 200) + '...' }
            $detail = " (body: $text)"
        }
        throw "The function did not accept the test event: HTTP $($response.StatusCode)$detail."
    }
    Write-Log ("Test event accepted (HTTP {0}): emailSent={1}, duplicate={2}, providerMessageId={3}" -f
        $response.StatusCode, $verdict.emailSent, $verdict.duplicate, $verdict.providerMessageId) -Level 'SUCCESS'
}

function Invoke-WatchdogDeployment {
    <#
    .SYNOPSIS
        Runs the whole deployment and returns the exit code (see .NOTES of the script).
    #>
    [CmdletBinding()]
    param (
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [string]$Location,

        [Parameter(Mandatory)]
        [string]$BaseName,

        [ValidateSet('Smtp2GoApi', 'Smtp')]
        [string]$MailProvider = 'Smtp2GoApi',

        [Parameter(Mandatory)]
        [string]$MailFrom,

        [Parameter(Mandatory)]
        [string]$MailTo,

        [string]$MailSubjectPrefix = '[Service Watchdog]',

        [securestring]$Smtp2GoApiKey,

        [string]$SmtpHost,

        [int]$SmtpPort = 587,

        [pscredential]$SmtpCredential,

        [bool]$SmtpUseStartTls = $true,

        [string]$PowerShellVersion = '7.4',

        [string]$FunctionKeyName = 'watchdog',

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [switch]$SendTestEmail,

        [switch]$DryRun
    )

    $script:DryRun = $DryRun.IsPresent
    $started = Get-Date

    Write-Log "Install-AzureServiceWatchdogFunction $script:ScriptVersion started" -Level 'INFO'
    Write-Log "Log file: $script:LogPath" -Level 'INFO'
    $secretState = @{ $true = '<set>'; $false = '<not set>' }
    Write-Log ("Parameters: SubscriptionId={0}, ResourceGroupName={1}, Location={2}, BaseName={3}, MailProvider={4}, " +
        "MailFrom={5}, MailTo={6}, MailSubjectPrefix={7}, Smtp2GoApiKey={8}, SmtpHost={9}, SmtpPort={10}, " +
        "SmtpCredential={11}, SmtpUseStartTls={12}, PowerShellVersion={13}, FunctionKeyName={14}, SourcePath={15}, " +
        "SendTestEmail={16}, DryRun={17}, Verbosity={18}" -f $SubscriptionId, $ResourceGroupName, $Location, $BaseName,
        $MailProvider, $MailFrom, $MailTo, $MailSubjectPrefix, $secretState[[bool]$Smtp2GoApiKey], $SmtpHost, $SmtpPort,
        $secretState[[bool]$SmtpCredential], $SmtpUseStartTls, $PowerShellVersion, $FunctionKeyName, $SourcePath,
        $SendTestEmail.IsPresent, $script:DryRun, $script:Verbosity) -Level 'INFO'
    if ($script:DryRun) {
        Write-Log '*** DRYRUN MODE - no resources are created or changed ***' -Level 'WARNING'
    }

    try {
        $protocols = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        [Net.ServicePointManager]::SecurityProtocol = $protocols
    }
    catch {
        Write-Log "Could not pin TLS 1.2+ on ServicePointManager: $_" -Level 'DEBUG'
    }

    # Step 1a: parameters and tools (exit 2).
    $problems = @()
    $problems += Test-WatchdogDeploymentParameter -MailProvider $MailProvider -Smtp2GoApiKey $Smtp2GoApiKey `
        -SmtpHost $SmtpHost -SmtpCredential $SmtpCredential -SourcePath $SourcePath -TemplatePath $TemplatePath
    $problems += Test-WatchdogPrerequisite
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            Write-Log $problem -Level 'ERROR'
        }
        Write-Log "Fix the $($problems.Count) problem(s) above and re-run (exit 2)." -Level 'ERROR'
        return 2
    }

    # Step 1b: sign-in and deployer (exit 20).
    try {
        $deployer = Get-WatchdogDeployer -SubscriptionId $SubscriptionId
    }
    catch {
        Write-Log "Sign-in check failed: $_" -Level 'ERROR'
        return 20
    }

    # Step 2: resource group.
    try {
        $group = Get-WatchdogResourceGroup -Name $ResourceGroupName
        if ($group) {
            Write-Log "Resource group $ResourceGroupName exists in $($group.Location)" -Level 'INFO'
        }
        else {
            if ([string]::IsNullOrWhiteSpace($Location)) {
                Write-Log "Resource group $ResourceGroupName does not exist; pass -Location to create it (exit 2)." `
                    -Level 'ERROR'
                return 2
            }
            Invoke-Action -Description "Create resource group $ResourceGroupName in $Location" -Action {
                New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
            }
            if ($script:DryRun) {
                Write-Log ("The what-if preview needs an existing resource group; create $ResourceGroupName or " +
                    're-run without -DryRun to see the template changes.') -Level 'WARNING'
                Write-Log 'Dry run complete: prerequisites and sign-in verified, nothing changed.' -Level 'SUCCESS'
                return 0
            }
        }
    }
    catch {
        Write-Log "Resource group step failed: $_" -Level 'ERROR'
        if (Test-WatchdogAuthorizationError -ErrorRecord $_) {
            return 20
        }
        return 1
    }

    # Step 3: template deployment.
    $settings = @{
        BaseName          = $BaseName
        PowerShellVersion = $PowerShellVersion
        MailProvider      = $MailProvider
        MailFrom          = $MailFrom
        MailTo            = $MailTo
        MailSubjectPrefix = $MailSubjectPrefix
        SmtpHost          = $SmtpHost
        SmtpPort          = $SmtpPort
        SmtpCredential    = $SmtpCredential
        SmtpUseStartTls   = $SmtpUseStartTls
    }
    $templateParameter = Get-WatchdogTemplateParameter -Settings $settings -Deployer $deployer
    try {
        $deployment = Invoke-WatchdogTemplateDeployment -ResourceGroupName $ResourceGroupName `
            -TemplatePath $TemplatePath -TemplateParameter $templateParameter
    }
    catch {
        Write-Log "Template deployment failed: $_" -Level 'ERROR'
        if (Test-WatchdogAuthorizationError -ErrorRecord $_) {
            return 20
        }
        return 1
    }
    if ($script:DryRun) {
        Write-Log 'Dry run complete: review the what-if summary above. Nothing was changed.' -Level 'SUCCESS'
        return 0
    }

    # Steps 4 to 9: everything after the template is a post-deployment step (exit 50).
    $step = 'read the deployment outputs'
    $packagePath = $null
    $isolationFailure = $null
    try {
        $outputs = Get-WatchdogDeploymentOutput -Deployment $deployment `
            -Name @('functionAppName', 'functionAppHostName', 'alertUrl', 'keyVaultName')
        $siteResourceId = "/subscriptions/$($deployer.SubscriptionId)/resourceGroups/$ResourceGroupName" +
            "/providers/Microsoft.Web/sites/$($outputs.functionAppName)"

        $step = 'seed the Key Vault secrets'
        if ($MailProvider -eq 'Smtp2GoApi') {
            Save-WatchdogSecret -VaultName $outputs.keyVaultName -Name $script:Smtp2GoSecretName `
                -SecretValue $Smtp2GoApiKey
        }
        else {
            Save-WatchdogSecret -VaultName $outputs.keyVaultName -Name $script:SmtpPasswordSecretName `
                -SecretValue $SmtpCredential.Password
        }

        $step = 'package the function app'
        $packagePath = Compress-WatchdogPackage -SourcePath $SourcePath

        $step = 'publish the function app package'
        Publish-WatchdogPackage -ResourceGroupName $ResourceGroupName -Name $outputs.functionAppName `
            -ArchivePath $packagePath

        $step = 'restart the function app'
        Invoke-Action -Description "Restart function app $($outputs.functionAppName) so Key Vault references resolve" `
            -Action {
                Restart-AzWebApp -ResourceGroupName $ResourceGroupName -Name $outputs.functionAppName `
                    -ErrorAction Stop | Out-Null
            }

        $step = "wait for $script:AlertFunctionName to be listed"
        Wait-WatchdogFunction -SiteResourceId $siteResourceId -FunctionName $script:AlertFunctionName

        $step = "create the function key '$FunctionKeyName'"
        $functionKey = Request-WatchdogFunctionKey -SiteResourceId $siteResourceId `
            -FunctionName $script:AlertFunctionName -KeyName $FunctionKeyName

        Show-WatchdogSummary -FunctionAppName $outputs.functionAppName -AlertUrl $outputs.alertUrl `
            -FunctionKey $functionKey -KeyVaultName $outputs.keyVaultName

        # After the key is shown on purpose (7.2 step 9): the property is outside the ARM
        # schema, so a response that drops it must not withhold the deployment's one
        # deliverable. A failure here is reported at the end as exit 50.
        $step = 'verify admin endpoint isolation'
        try {
            Confirm-WatchdogAdminIsolation -SiteResourceId $siteResourceId
        }
        catch {
            $isolationFailure = [string]$_
            Write-Log "Admin endpoint isolation could not be verified: $isolationFailure" -Level 'ERROR'
        }

        if ($SendTestEmail) {
            $step = 'send the test email'
            Send-WatchdogTestEmail -AlertUrl $outputs.alertUrl -FunctionKey $functionKey
        }
    }
    catch {
        Write-Log "Deployed, but the post-deployment step '$step' failed: $_" -Level 'ERROR'
        Write-Log 'Fix the cause and re-run the script; every step is idempotent (exit 50).' -Level 'ERROR'
        return 50
    }
    finally {
        if ($packagePath -and (Test-Path -LiteralPath $packagePath)) {
            Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($isolationFailure) {
        Write-Log ('Deployed and the function key was shown above, but functionsRuntimeAdminIsolationEnabled could ' +
            "not be confirmed: $isolationFailure Check the site in the portal or set the property by hand " +
            '(README troubleshooting) and re-run to verify (exit 50).') -Level 'ERROR'
        return 50
    }

    $elapsed = (Get-Date) - $started
    Write-Log "Deployment complete in $($elapsed.ToString('hh\:mm\:ss')): alert URL $($outputs.alertUrl)" `
        -Level 'SUCCESS'
    return 0
}

#endregion

#region Script Body

# Guarded so tests can dot-source the functions without running the deployment.
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        $deploymentArguments = @{
            SubscriptionId    = $SubscriptionId
            ResourceGroupName = $ResourceGroupName
            Location          = $Location
            BaseName          = $BaseName
            MailProvider      = $MailProvider
            MailFrom          = $MailFrom
            MailTo            = $MailTo
            MailSubjectPrefix = $MailSubjectPrefix
            SmtpHost          = $SmtpHost
            SmtpPort          = $SmtpPort
            SmtpUseStartTls   = $SmtpUseStartTls
            PowerShellVersion = $PowerShellVersion
            FunctionKeyName   = $FunctionKeyName
            SourcePath        = $SourcePath
            TemplatePath      = $script:TemplatePath
            SendTestEmail     = $SendTestEmail
            DryRun            = $DryRun
        }
        if ($Smtp2GoApiKey) { $deploymentArguments.Smtp2GoApiKey = $Smtp2GoApiKey }
        if ($SmtpCredential) { $deploymentArguments.SmtpCredential = $SmtpCredential }

        $exitCode = Invoke-WatchdogDeployment @deploymentArguments
    }
    catch {
        Write-Log "Script failed: $_" -Level 'ERROR'
        Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
        $exitCode = 1
    }
}

#endregion

#region Cleanup

if ($MyInvocation.InvocationName -ne '.') {
    $duration = (Get-Date) - $scriptStartTime
    Write-Log "Total duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Level 'INFO'
    exit $exitCode
}

#endregion
