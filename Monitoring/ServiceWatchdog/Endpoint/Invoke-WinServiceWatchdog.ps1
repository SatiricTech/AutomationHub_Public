#Requires -Version 5.1

<#
.SYNOPSIS
    Keeps a configured set of Windows services running and reports outcomes to a webhook.

.DESCRIPTION
    Windows-only. Designed to run every 5 minutes (and shortly after boot) as SYSTEM under
    Task Scheduler, and to run unchanged on Windows PowerShell 5.1 and PowerShell 7.

    Each run reads ServiceWatchdog.json, checks every listed service, starts stopped ones in
    up to MaxStartAttempts rounds inside a MaxRunSeconds time budget, and compares the
    outcome with the previous run's state file to decide whether anything needs to be
    reported. When a service enters or leaves a problem state the worker POSTs one JSON
    event (alert, flapping, recovered, remediated or reminder) to the ServiceWatchdog
    Azure Function, which renders and emails it. A daily heartbeat event lets the Azure
    side notice a server whose watchdog has gone silent. Every decision is also written to
    the ServiceWatchdog source in the Application event log and to a daily log file.

    The worker never changes a service's start type, never starts a Disabled service, and
    never uses Start-Service (which blocks until the Service Control Manager resolves the
    start); it calls ServiceController.Start() and waits with WaitForStatus so a stuck
    service cannot consume the whole time budget.

    See DESIGN.md sections 4.1 to 4.10 for the full contract: configuration schema, state
    file, service handling, notification decisions, payload schema, event IDs and exit codes.

.PARAMETER ConfigPath
    Path to the JSON configuration file. Defaults to ServiceWatchdog.json beside this script.

.PARAMETER ServiceName
    One or more service names that replace the configured Services list for this run only.
    Logged as an override; state entries for services outside this list are pruned.

.PARAMETER ValidateConfig
    Parse and validate the configuration, print a summary and exit 0 (valid) or 2 (invalid).
    Performs no service checks and no webhook call. Mutually exclusive with -TestAlert and
    -SendHeartbeat.

.PARAMETER TestAlert
    Send a 'test' event through the webhook and exit 0 (delivered), 10 (delivery failed) or
    2 (config invalid). Performs no service checks and leaves the state file untouched.
    Mutually exclusive with -ValidateConfig and -SendHeartbeat.

.PARAMETER SendHeartbeat
    Force a heartbeat event this run regardless of the HeartbeatHours schedule. Follows the
    normal run exit codes.

.PARAMETER DryRun
    Performs every check and logs every intended action with a [DRYRUN] prefix, but never
    starts a service, never POSTs to the webhook, never writes the state file and never
    writes to the event log.

.PARAMETER Verbosity
    Console output level. Low (default) shows only errors and success lines, Medium adds
    warnings, High shows everything. The log file always receives every line.

.PARAMETER LogPath
    Override the log file path. By default the worker appends to
    <LogRoot>\ServiceWatchdog-<yyyyMMdd>.log, where LogRoot is Logging.LogRoot from the
    config or $env:ProgramData\ServiceWatchdog\Logs when that is empty.

.EXAMPLE
    .\Invoke-WinServiceWatchdog.ps1

    Normal scheduled run using ServiceWatchdog.json beside the script.

.EXAMPLE
    .\Invoke-WinServiceWatchdog.ps1 -ValidateConfig -Verbosity High

    Validates the configuration and prints a summary without touching any service.

.EXAMPLE
    .\Invoke-WinServiceWatchdog.ps1 -TestAlert

    Sends a test event through the webhook so the email path can be verified end to end.

.EXAMPLE
    .\Invoke-WinServiceWatchdog.ps1 -DryRun -Verbosity High

    Runs every check and logs what would be started, posted and written, with no changes.

.NOTES
    Version:    1.0.0
    Created:    2026-09-04
    Platform:   Windows only (Windows PowerShell 5.1 or PowerShell 7 on Windows).
    Runs as:    SYSTEM under Task Scheduler; also works interactively as an administrator.
    Exit codes: 0 healthy or remediated, 1 unexpected error, 2 configuration or parameters
                invalid, 10 notification or heartbeat delivery pending, 50 one or more
                services Failed, Missing or Disabled after retries (50 wins over 10).
    Event log:  entries are written through System.Diagnostics.EventLog rather than the
                *-EventLog cmdlets, which exist only in Windows PowerShell 5.1.
    Placeholders: configuration values containing the literal upper-case token REPLACE fail
                validation (case-sensitive). DESIGN.md 4.3 names Webhook.Url and
                Webhook.FunctionKey; this script extends the same check to SiteName.

    Checklist deviations from the powershell-authoring skill (Enterprise tier):
      - 3.1: targets Windows PowerShell 5.1 (#Requires -Version 5.1) instead of 7.4, because
        Windows Server ships only 5.1 and the worker must run there unchanged.
      - 4.6 / 4.7: the log root is $env:ProgramData\ServiceWatchdog\Logs (product-named, no
        $MSPName, because the tool is deployed by end-client IT) and the log file is one
        file per day rather than one per run, because a 5-minute task would otherwise
        create 288 files a day.
      - 5.2: the function key lives in the ACLed configuration file, because SYSTEM has no
        SecretManagement vault; DPAPI protection is a v2 item.
      - 5.7: scripts ship unsigned in the public repository; adopters sign with their own
        certificate.
      - 6.6: the integration test is the operator acceptance run documented in the README.
      - 6.7: not applicable; run time is bounded by MaxRunSeconds.

    Developed with AI assistance (Claude); reviewed before publication.
#>

[CmdletBinding()]
param (
    [string]$ConfigPath,

    [ValidateNotNullOrEmpty()]
    [string[]]$ServiceName,

    [switch]$ValidateConfig,

    [switch]$TestAlert,

    [switch]$SendHeartbeat,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Low',

    [string]$LogPath
)

#region Configuration & Constants

$ErrorActionPreference = 'Stop'

$script:WatchdogVersion = '1.0.0'
$script:EventSourceName = 'ServiceWatchdog'
$script:EventLogName = 'Application'
$script:UserAgent = "ServiceWatchdog/$script:WatchdogVersion"
$script:StateFileName = 'ServiceWatchdog.state.json'
$script:FlapWindowMinutes = 60
$script:FlapThreshold = 4
$script:RetryDelaySecondsOnDelivery = 5
$script:ProblemStatuses = @('Failed', 'Missing', 'Disabled')
$script:EventTypePriority = @('alert', 'flapping', 'recovered', 'remediated', 'reminder')

# Runtime settings that helper functions read; Invoke-WatchdogMain refreshes them from its
# parameters so tests can call it directly with different switches.
$script:Verbosity = $Verbosity
$script:DryRun = [bool]$DryRun
$script:LogPath = $LogPath
$script:EventSourceReady = $null
$script:RunStopwatch = $null
$script:MaxRunSeconds = 0

# Product-named log root (see .NOTES deviation 4.6). $env:ProgramData is empty on
# non-Windows hosts where only the unit tests run, so fall back to the temp folder there.
$script:DefaultLogRoot = if ($env:ProgramData) {
    Join-Path (Join-Path $env:ProgramData 'ServiceWatchdog') 'Logs'
}
else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'ServiceWatchdog'
}

if ($PSScriptRoot) {
    $script:DefaultConfigPath = Join-Path $PSScriptRoot 'ServiceWatchdog.json'
}
else {
    $script:DefaultConfigPath = Join-Path (Get-Location).Path 'ServiceWatchdog.json'
}

$script:RunOptions = @{
    ConfigPath     = $ConfigPath
    ServiceName    = $ServiceName
    ValidateConfig = [bool]$ValidateConfig
    TestAlert      = [bool]$TestAlert
    SendHeartbeat  = [bool]$SendHeartbeat
    DryRun         = [bool]$DryRun
    Verbosity      = $Verbosity
    LogPath        = $LogPath
}

# Configuration defaults and limits (DESIGN.md 4.3). Section '' is the top level.
$script:ConfigIntegerRules = @(
    @{ Section = ''; Key = 'MaxStartAttempts'; Min = 1; Max = 20; Default = 5 }
    @{ Section = ''; Key = 'RetryDelaySeconds'; Min = 0; Max = 300; Default = 30 }
    @{ Section = ''; Key = 'PostStartVerifySeconds'; Min = 0; Max = 120; Default = 10 }
    @{ Section = ''; Key = 'StartPendingWaitSeconds'; Min = 0; Max = 300; Default = 60 }
    @{ Section = ''; Key = 'MaxRunSeconds'; Min = 30; Max = 3600; Default = 240 }
    @{ Section = 'Webhook'; Key = 'TimeoutSeconds'; Min = 5; Max = 120; Default = 30 }
    @{ Section = 'Alerting'; Key = 'ReminderMinutes'; Min = 5; Max = 10080; Default = 240 }
    @{ Section = 'Alerting'; Key = 'RemediationCooldownMinutes'; Min = 0; Max = 10080; Default = 60 }
    @{ Section = 'Alerting'; Key = 'HeartbeatHours'; Min = 1; Max = 168; Default = 24 }
    @{ Section = 'Logging'; Key = 'LogRetentionDays'; Min = 1; Max = 365; Default = 30 }
)
$script:ConfigBooleanRules = @(
    @{ Section = 'Alerting'; Key = 'NotifyOnRemediation'; Default = $false }
    @{ Section = 'Logging'; Key = 'EventLogHealthyRuns'; Default = $false }
)
$script:ConfigKnownKeys = @{
    ''         = @('SchemaVersion', 'SiteName', 'Services', 'MaxStartAttempts', 'RetryDelaySeconds',
        'PostStartVerifySeconds', 'StartPendingWaitSeconds', 'MaxRunSeconds', 'Webhook', 'Alerting', 'Logging')
    'Webhook'  = @('Url', 'FunctionKey', 'TimeoutSeconds')
    'Alerting' = @('ReminderMinutes', 'NotifyOnRemediation', 'RemediationCooldownMinutes', 'HeartbeatHours')
    'Logging'  = @('LogRoot', 'LogRetentionDays', 'EventLogHealthyRuns')
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
        try {
            Add-Content -LiteralPath $script:LogPath -Value $logMessage -Encoding UTF8
        }
        catch {
            # Losing one log line must never abort a watchdog run; console output still shows it.
            Write-Warning "Failed to write to log file '$($script:LogPath)': $_"
        }
    }
}

function Invoke-Action {
    param (
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [ValidateSet('ERROR', 'WARNING')]
        [string]$FailureLevel = 'ERROR'
    )

    if ($script:DryRun) {
        Write-Log -Message "[DRYRUN] Would execute: $Description" -Level 'INFO'
    }
    else {
        Write-Log -Message "Executing: $Description" -Level 'INFO'
        try {
            & $Action
        }
        catch {
            Write-Log -Message "Failed: $Description - $_" -Level $FailureLevel
            throw
        }
    }
}

function Get-WatchdogUtcNow {
    # Single clock read point so tests can control time.
    return [datetime]::UtcNow
}

function ConvertTo-WatchdogTimestamp {
    param ([object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return $Value
    }
    return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertFrom-WatchdogTimestamp {
    param ([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    try {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
        [System.Globalization.DateTimeStyles]::AdjustToUniversal
        return [datetime]::ParseExact([string]$Value, 'yyyy-MM-ddTHH:mm:ssZ',
            [System.Globalization.CultureInfo]::InvariantCulture, $styles)
    }
    catch {
        return $null
    }
}

function ConvertTo-WatchdogHashtable {
    # Recursively converts ConvertFrom-Json output into case-insensitive hashtables so the
    # rest of the script can use one shape on both Windows PowerShell 5.1 and PowerShell 7.
    param ([object]$InputObject)

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [datetime]) {
        # PowerShell 7's ConvertFrom-Json turns ISO date strings into [datetime]; the state
        # and config contracts carry timestamps as strings only (DESIGN.md 4.4).
        return ConvertTo-WatchdogTimestamp -Value $InputObject
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $InputObject.Keys) {
            $table[[string]$key] = ConvertTo-WatchdogHashtable -InputObject $InputObject[$key]
        }
        return $table
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-WatchdogHashtable -InputObject $property.Value
        }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) {
            $list.Add((ConvertTo-WatchdogHashtable -InputObject $item))
        }
        return , $list.ToArray()
    }
    return $InputObject
}

function Get-WatchdogRemainingBudget {
    # Seconds left in the MaxRunSeconds budget for service checks and start rounds.
    if ($null -eq $script:RunStopwatch) {
        return $script:MaxRunSeconds
    }
    $remaining = $script:MaxRunSeconds - [int][math]::Floor($script:RunStopwatch.Elapsed.TotalSeconds)
    if ($remaining -lt 0) {
        return 0
    }
    return $remaining
}

function Get-WatchdogHostIdentity {
    $hostName = $env:COMPUTERNAME
    if (-not $hostName) {
        try {
            $hostName = [System.Net.Dns]::GetHostName()
        }
        catch {
            $hostName = 'UNKNOWN-HOST'
        }
    }
    $fqdn = $null
    try {
        $properties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        if ($properties.DomainName) {
            $fqdn = "$($properties.HostName).$($properties.DomainName)".ToLowerInvariant()
        }
    }
    catch {
        $fqdn = $null
    }
    return @{ HostName = $hostName; Fqdn = $fqdn }
}

function Test-WatchdogEventSource {
    try {
        return [System.Diagnostics.EventLog]::SourceExists($script:EventSourceName)
    }
    catch {
        return $false
    }
}

function Test-WatchdogElevation {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function ConvertTo-WatchdogSafeUrl {
    # The key travels in a header, but redact it anyway if an operator put it in the URL.
    param ([string]$Url)

    return [regex]::Replace($Url, '(?i)([?&]code=)[^&]*', '$1***')
}

function Limit-WatchdogString {
    param (
        [object]$Value,

        [Parameter(Mandatory)]
        [int]$MaxLength
    )

    if ($null -eq $Value) {
        return $null
    }
    $text = [string]$Value
    if ($text.Length -le $MaxLength) {
        return $text
    }
    return $text.Substring(0, $MaxLength) + ' [truncated]'
}

function Initialize-WatchdogTransportSecurity {
    # Windows PowerShell 5.1 does not enable TLS 1.2 by default; PowerShell 7 already does.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
        }
        catch {
            Write-Log -Message "Could not enable TLS 1.2: $_" -Level 'WARNING'
        }
    }
}

function Initialize-WatchdogLog {
    param ([Parameter(Mandatory)][string]$Path)

    $script:LogPath = $Path
    try {
        $logDir = Split-Path -Path $Path -Parent
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
    }
    catch {
        Write-Warning "Could not create log directory for '$Path': $_. Continuing without file logging."
        $script:LogPath = $null
    }
}

function Register-WatchdogEventSource {
    # The New-EventLog / Write-EventLog cmdlets exist only in Windows PowerShell 5.1; the
    # System.Diagnostics.EventLog API is present on both 5.1 and PowerShell 7 on Windows.
    # Kept as a separate command so tests can mock it (DESIGN.md 4.1, 4.9).
    param (
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$LogName
    )

    [System.Diagnostics.EventLog]::CreateEventSource($Source, $LogName)
}

function Write-WatchdogEventLogEntry {
    # Same rationale as Register-WatchdogEventSource: a mockable seam over the .NET API that
    # works on both hosts. The source determines the log, so no log name is needed here.
    param (
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [int]$EventId,

        [Parameter(Mandatory)]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $type = [System.Diagnostics.EventLogEntryType]$EntryType
    [System.Diagnostics.EventLog]::WriteEntry($Source, $Message, $type, $EventId)
}

function Write-WatchdogEvent {
    param (
        [Parameter(Mandatory)]
        [int]$EventId,

        [Parameter(Mandatory)]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($script:DryRun) {
        Write-Log -Message "[DRYRUN] Would write event log entry $EventId ($EntryType): $Message" -Level 'INFO'
        return
    }

    try {
        if ($null -eq $script:EventSourceReady) {
            if (Test-WatchdogEventSource) {
                $script:EventSourceReady = $true
            }
            elseif (Test-WatchdogElevation) {
                Register-WatchdogEventSource -Source $script:EventSourceName -LogName $script:EventLogName
                Write-Log -Message "Registered event source '$($script:EventSourceName)'." -Level 'INFO'
                $script:EventSourceReady = $true
            }
            else {
                $script:EventSourceReady = $false
                Write-Log -Message ("Event source '$($script:EventSourceName)' is not registered and this session is " +
                    'not elevated; continuing with file logging only.') -Level 'WARNING'
            }
        }
        if (-not $script:EventSourceReady) {
            return
        }
        Write-WatchdogEventLogEntry -Source $script:EventSourceName -EventId $EventId -EntryType $EntryType `
            -Message $Message
    }
    catch {
        Write-Log -Message "Could not write event $EventId to the event log: $_" -Level 'WARNING'
    }
}

function Remove-WatchdogOldLogs {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns',
        '',
        Justification = 'Function name is fixed by the DESIGN.md / task interface contract.'
    )]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Runs through Invoke-Action, the -DryRun gate; the worker is unattended and never prompts.'
    )]
    param (
        [Parameter(Mandatory)]
        [string]$LogRoot,

        [Parameter(Mandatory)]
        [int]$RetentionDays
    )

    if (-not (Test-Path -LiteralPath $LogRoot)) {
        return
    }
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    try {
        $oldFiles = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'ServiceWatchdog-*.log' -File |
                Where-Object { $_.Extension -eq '.log' -and $_.LastWriteTime -lt $cutoff })
    }
    catch {
        Write-Log -Message "Could not enumerate old logs in '$LogRoot': $_" -Level 'WARNING'
        return
    }
    foreach ($file in $oldFiles) {
        try {
            Invoke-Action -Description "Delete old log file $($file.Name)" -FailureLevel 'WARNING' -Action {
                Remove-Item -LiteralPath $file.FullName -Force
            }
        }
        catch {
            # Invoke-Action already logged the failure as a WARNING; retention never aborts a run.
            Write-Log -Message "Old log file $($file.Name) is left in place; retried next run." -Level 'DEBUG'
        }
    }
}

function Get-WatchdogConfigValue {
    param ([hashtable]$Config, [string]$Section, [string]$Key)

    $container = $Config
    if ($Section) {
        if (-not ($Config[$Section] -is [System.Collections.IDictionary])) {
            return @{ Present = $false; Value = $null }
        }
        $container = $Config[$Section]
    }
    if ($container.ContainsKey($Key)) {
        return @{ Present = $true; Value = $container[$Key] }
    }
    return @{ Present = $false; Value = $null }
}

function Test-WatchdogInteger {
    param ([object]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        return $false
    }
    try {
        $number = [double]$Value
    }
    catch {
        return $false
    }
    return ($number -eq [math]::Floor($number))
}

#endregion

#region Main Functions

function Import-WatchdogConfig {
    param ([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    }
    catch {
        throw "Configuration file '$Path' is not valid JSON: $_"
    }
    $table = ConvertTo-WatchdogHashtable -InputObject $parsed
    if (-not ($table -is [System.Collections.IDictionary])) {
        throw "Configuration file '$Path' must contain a JSON object."
    }
    return $table
}

function Test-WatchdogConfig {
    param ([Parameter(Mandatory)][hashtable]$Config)

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $normalized = @{ Webhook = @{}; Alerting = @{}; Logging = @{} }

    # Unknown keys warn so a newer config still works on an older worker.
    foreach ($section in $script:ConfigKnownKeys.Keys) {
        $container = if ($section) { $Config[$section] } else { $Config }
        if (-not ($container -is [System.Collections.IDictionary])) {
            continue
        }
        foreach ($key in $container.Keys) {
            if ($script:ConfigKnownKeys[$section] -notcontains $key) {
                $label = if ($section) { "$section.$key" } else { $key }
                $warnings.Add("Unknown key '$label' is ignored by this version of the watchdog.")
            }
        }
    }

    $schema = Get-WatchdogConfigValue -Config $Config -Section '' -Key 'SchemaVersion'
    if (-not $schema.Present -or -not (Test-WatchdogInteger -Value $schema.Value) -or [int]$schema.Value -ne 1) {
        $errors.Add('SchemaVersion must be 1.')
    }
    $normalized.SchemaVersion = 1

    $site = Get-WatchdogConfigValue -Config $Config -Section '' -Key 'SiteName'
    $siteName = if ($site.Present -and $null -ne $site.Value) { [string]$site.Value } else { '' }
    if ($siteName.Length -lt 1 -or $siteName.Length -gt 64 -or $siteName -match '[\x00-\x1F\x7F]') {
        $errors.Add('SiteName must be 1 to 64 printable characters.')
    }
    elseif ($siteName -cmatch 'REPLACE') {
        # Case-sensitive on purpose: DESIGN.md 4.3 names the literal upper-case token, and a
        # legitimate site name such as 'Replacement Parts Co' must not be rejected.
        $errors.Add("SiteName contains placeholder text; edit 'SiteName' in the configuration file.")
    }
    $normalized.SiteName = $siteName

    $services = Get-WatchdogConfigValue -Config $Config -Section '' -Key 'Services'
    $serviceList = @()
    if (-not $services.Present -or $null -eq $services.Value -or $services.Value -is [string] -or
        -not ($services.Value -is [System.Collections.IEnumerable])) {
        $errors.Add('Services must be a non-empty array of 1 to 100 service names.')
    }
    else {
        $serviceList = @($services.Value)
        if ($serviceList.Count -lt 1 -or $serviceList.Count -gt 100) {
            $errors.Add("Services must contain 1 to 100 entries (found $($serviceList.Count)).")
        }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $serviceList) {
            if (-not ($entry -is [string]) -or $entry.Trim().Length -lt 1 -or $entry.Length -gt 256) {
                $errors.Add("Services entries must be strings of 1 to 256 characters (offending entry: '$entry').")
            }
            elseif (-not $seen.Add($entry.Trim())) {
                $errors.Add("Services entries must be unique; '$entry' appears more than once.")
            }
        }
        $serviceList = @($serviceList | Where-Object { $_ -is [string] } | ForEach-Object { $_.Trim() })
    }
    $normalized.Services = $serviceList

    foreach ($rule in $script:ConfigIntegerRules) {
        $label = if ($rule.Section) { "$($rule.Section).$($rule.Key)" } else { $rule.Key }
        $found = Get-WatchdogConfigValue -Config $Config -Section $rule.Section -Key $rule.Key
        $value = $rule.Default
        if ($found.Present) {
            if (-not (Test-WatchdogInteger -Value $found.Value) -or
                [double]$found.Value -lt $rule.Min -or [double]$found.Value -gt $rule.Max) {
                $errors.Add("$label must be an integer from $($rule.Min) to $($rule.Max) (found '$($found.Value)').")
            }
            else {
                $value = [int]$found.Value
            }
        }
        if ($rule.Section) {
            $normalized[$rule.Section][$rule.Key] = $value
        }
        else {
            $normalized[$rule.Key] = $value
        }
    }

    foreach ($rule in $script:ConfigBooleanRules) {
        $label = "$($rule.Section).$($rule.Key)"
        $found = Get-WatchdogConfigValue -Config $Config -Section $rule.Section -Key $rule.Key
        $value = $rule.Default
        if ($found.Present) {
            if ($found.Value -is [bool]) {
                $value = $found.Value
            }
            else {
                $errors.Add("$label must be true or false (found '$($found.Value)').")
            }
        }
        $normalized[$rule.Section][$rule.Key] = $value
    }

    $url = Get-WatchdogConfigValue -Config $Config -Section 'Webhook' -Key 'Url'
    $urlText = if ($url.Present -and $null -ne $url.Value) { [string]$url.Value } else { '' }
    # -cmatch: only the literal upper-case REPLACE token is a placeholder (DESIGN.md 4.3), so a
    # function app named 'svc-replace-prod' validates cleanly.
    if ($urlText -cmatch 'REPLACE') {
        $errors.Add("Webhook.Url contains placeholder text; edit 'Webhook.Url' in the configuration file.")
    }
    elseif ($urlText -notmatch '^(?i)https://[^\s/]+') {
        $errors.Add('Webhook.Url must be an https:// URL.')
    }
    $normalized.Webhook.Url = $urlText

    $key = Get-WatchdogConfigValue -Config $Config -Section 'Webhook' -Key 'FunctionKey'
    $keyText = if ($key.Present -and $null -ne $key.Value) { [string]$key.Value } else { '' }
    if ($keyText -cmatch 'REPLACE') {
        $errors.Add("Webhook.FunctionKey contains placeholder text; edit 'Webhook.FunctionKey' in the " +
            'configuration file.')
    }
    elseif ([string]::IsNullOrWhiteSpace($keyText)) {
        $errors.Add('Webhook.FunctionKey must not be empty.')
    }
    $normalized.Webhook.FunctionKey = $keyText

    $logRoot = Get-WatchdogConfigValue -Config $Config -Section 'Logging' -Key 'LogRoot'
    $normalized.Logging.LogRoot = ''
    if ($logRoot.Present -and $null -ne $logRoot.Value) {
        $normalized.Logging.LogRoot = [string]$logRoot.Value
    }

    $waitTotal = $normalized.StartPendingWaitSeconds * $serviceList.Count
    if ($waitTotal -gt $normalized.MaxRunSeconds) {
        $warnings.Add(("StartPendingWaitSeconds ($($normalized.StartPendingWaitSeconds)) times the service count " +
                "($($serviceList.Count)) is $waitTotal seconds, which exceeds MaxRunSeconds " +
                "($($normalized.MaxRunSeconds)); not every wait can finish inside the budget."))
    }

    return [pscustomobject]@{
        IsValid  = ($errors.Count -eq 0)
        Errors   = @($errors.ToArray())
        Warnings = @($warnings.ToArray())
        Config   = $normalized
    }
}

function New-WatchdogEmptyState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Builds an in-memory hashtable only; no system state changes.'
    )]
    param ()

    return @{
        SchemaVersion       = 1
        HostName            = $null
        LastRunUtc          = $null
        LastHeartbeatUtc    = $null
        PendingNotification = $false
        PendingEventId      = $null
        PendingEventType    = $null
        PendingServices     = @()
        Services            = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
}

function Get-WatchdogState {
    param ([Parameter(Mandatory)][string]$Path)

    $empty = New-WatchdogEmptyState
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Log -Message "No state file at '$Path'; starting with empty state." -Level 'INFO'
        return $empty
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $loaded = ConvertTo-WatchdogHashtable -InputObject (ConvertFrom-Json -InputObject $raw -ErrorAction Stop)
        if (-not ($loaded -is [System.Collections.IDictionary]) -or
            -not (Test-WatchdogInteger -Value $loaded['SchemaVersion']) -or [int]$loaded['SchemaVersion'] -ne 1 -or
            -not ($loaded['Services'] -is [System.Collections.IDictionary])) {
            throw 'the file does not match state schema version 1'
        }
    }
    catch {
        $message = "State file '$Path' is unreadable or invalid ($_); resetting to empty state."
        Write-Log -Message $message -Level 'WARNING'
        Write-WatchdogEvent -EventId 1021 -EntryType 'Warning' -Message $message
        return $empty
    }

    foreach ($field in @('HostName', 'LastRunUtc', 'LastHeartbeatUtc', 'PendingEventId', 'PendingEventType')) {
        if ($loaded.ContainsKey($field)) {
            $empty[$field] = $loaded[$field]
        }
    }
    $empty.PendingNotification = ($loaded['PendingNotification'] -eq $true)
    $empty.PendingServices = @($loaded['PendingServices'] |
            Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    foreach ($name in $loaded['Services'].Keys) {
        $entry = $loaded['Services'][$name]
        if ($entry -is [System.Collections.IDictionary]) {
            $empty.Services[[string]$name] = $entry
        }
    }
    return $empty
}

function Save-WatchdogState {
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [hashtable]$State
    )

    $ordered = [ordered]@{
        SchemaVersion       = 1
        HostName            = $State.HostName
        LastRunUtc          = ConvertTo-WatchdogTimestamp -Value $State.LastRunUtc
        LastHeartbeatUtc    = ConvertTo-WatchdogTimestamp -Value $State.LastHeartbeatUtc
        PendingNotification = [bool]$State.PendingNotification
        PendingEventId      = $State.PendingEventId
        PendingEventType    = $State.PendingEventType
        PendingServices     = @($State.PendingServices)
        Services            = [ordered]@{}
    }
    foreach ($name in @($State.Services.Keys | Sort-Object)) {
        $entry = $State.Services[$name]
        $ordered.Services[$name] = [ordered]@{
            Status                 = $entry.Status
            FirstFailedUtc         = ConvertTo-WatchdogTimestamp -Value $entry.FirstFailedUtc
            LastNotifiedUtc        = ConvertTo-WatchdogTimestamp -Value $entry.LastNotifiedUtc
            LastRemediatedUtc      = ConvertTo-WatchdogTimestamp -Value $entry.LastRemediatedUtc
            LastError              = $entry.LastError
            FlapCount              = [int]$entry.FlapCount
            FlapWindowStartUtc     = ConvertTo-WatchdogTimestamp -Value $entry.FlapWindowStartUtc
            FlapSuppressedUntilUtc = ConvertTo-WatchdogTimestamp -Value $entry.FlapSuppressedUntilUtc
        }
    }
    $json = ConvertTo-Json -InputObject $ordered -Depth 10

    Invoke-Action -Description "Write state file $Path" -Action {
        $tempPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [System.IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
        }
        finally {
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Remove-WatchdogUnmonitoredState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Edits an in-memory hashtable only; the state file write is gated by Invoke-Action.'
    )]
    param (
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ServiceNames
    )

    foreach ($name in @($State.Services.Keys)) {
        if ($ServiceNames -contains $name) {
            continue
        }
        $status = [string]$State.Services[$name].Status
        $State.Services.Remove($name)
        if ($script:ProblemStatuses -contains $status) {
            $message = "Service '$name' was removed from the monitored list while its status was $status."
            Write-Log -Message $message -Level 'WARNING'
            Write-WatchdogEvent -EventId 1006 -EntryType 'Warning' -Message $message
        }
        else {
            Write-Log -Message "Dropped state for service '$name', which is no longer monitored." -Level 'INFO'
        }
    }
}

function ConvertTo-WatchdogStartType {
    param ([object]$StartMode, [object]$DelayedAutoStart)

    switch ([string]$StartMode) {
        'Boot' { return 'Boot' }
        'System' { return 'System' }
        'Auto' { if ($DelayedAutoStart -eq $true) { return 'AutomaticDelayedStart' } else { return 'Automatic' } }
        'Automatic' { if ($DelayedAutoStart -eq $true) { return 'AutomaticDelayedStart' } else { return 'Automatic' } }
        'Manual' { return 'Manual' }
        'Disabled' { return 'Disabled' }
        default { return 'Unknown' }
    }
}

function Get-WatchdogServiceStatus {
    # Reads one service. Returns Status 'Missing' when the service is not installed; throws
    # for any other failure so the caller can classify the service as Unknown.
    # Note: the script reads its own 'StartType' hashtable field with the indexer
    # ($x['StartType']) rather than member syntax, because the 5.1 compatibility scanner
    # flags every .StartType member access as the Get-Service property that 5.1 lacks.
    param ([Parameter(Mandatory)][string]$Name)

    # Get-Service treats [ ] * ? as wildcards, so escape the configured name for a literal match.
    $literal = [System.Management.Automation.WildcardPattern]::Escape($Name)
    $service = $null
    try {
        $service = @(Get-Service -Name $literal -ErrorAction Stop | Where-Object { $_.Name -eq $Name }) |
            Select-Object -First 1
    }
    catch {
        $service = $null
    }
    if ($null -eq $service) {
        try {
            $service = @(Get-Service -DisplayName $literal -ErrorAction Stop |
                    Where-Object { $_.DisplayName -eq $Name }) | Select-Object -First 1
        }
        catch {
            $service = $null
        }
        if ($null -ne $service) {
            $message = "Service '$Name' resolved by display name to short name '$($service.Name)'."
            Write-Log -Message $message -Level 'INFO'
        }
    }
    if ($null -eq $service) {
        return @{
            Name          = $Name
            ResolvedName  = $Name
            DisplayName   = $null
            StartType     = $null
            Status        = 'Missing'
            ServiceStatus = $null
        }
    }

    $shortName = [string]$service.Name
    $escaped = $shortName.Replace('\', '\\').Replace("'", "\'")
    $cim = Get-CimInstance -ClassName 'Win32_Service' -Filter "Name='$escaped'" -ErrorAction Stop
    $startType = ConvertTo-WatchdogStartType -StartMode $cim.StartMode -DelayedAutoStart $cim.DelayedAutoStart

    return @{
        Name          = $Name
        ResolvedName  = $shortName
        DisplayName   = [string]$service.DisplayName
        StartType     = $startType
        Status        = [string]$service.Status
        ServiceStatus = [string]$service.Status
    }
}

function Wait-WatchdogServiceStatus {
    # Wraps ServiceController.WaitForStatus so tests can mock it. Throws on timeout.
    param (
        [Parameter(Mandatory)]
        [object]$Service,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $Service.WaitForStatus($Status, [TimeSpan]::FromSeconds([math]::Max($TimeoutSeconds, 0)))
}

function Start-WatchdogService {
    # ServiceController.Start() does not block; Start-Service would block until the SCM
    # resolves the start and could consume the whole budget on one stuck service.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Call sites wrap this in Invoke-Action, the -DryRun gate; the worker is unattended, no prompts.'
    )]
    param (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$WaitSeconds
    )

    $service = Get-Service -Name ([System.Management.Automation.WildcardPattern]::Escape($Name)) -ErrorAction Stop
    $service.Start()
    try {
        Wait-WatchdogServiceStatus -Service $service -Status 'Running' -TimeoutSeconds $WaitSeconds
    }
    catch {
        # PowerShell wraps .NET method exceptions in MethodInvocationException, so look at
        # the inner exception too. Checked by name so the type need not exist off-Windows.
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception.GetType().Name -eq 'TimeoutException') {
                throw "Service '$Name' did not reach Running within $WaitSeconds seconds after the start request."
            }
            $exception = $exception.InnerException
        }
        throw
    }
}

function Invoke-WatchdogServiceCheck {
    # Classifies one service per DESIGN.md 4.5 and returns the mutable result record used by
    # the start rounds and the notification plan.
    param (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $result = @{
        Name          = $Name
        ResolvedName  = $Name
        DisplayName   = $null
        StartType     = $null
        Status        = 'Unknown'
        Eligible      = $false
        Remediated    = $false
        Attempts      = 0
        LastError     = $null
        ServiceStatus = $null
    }

    try {
        $status = Get-WatchdogServiceStatus -Name $Name
        $result.ResolvedName = $status.ResolvedName
        $result.DisplayName = $status.DisplayName
        $result['StartType'] = $status['StartType']
        $result.ServiceStatus = $status.Status

        if ($status.Status -eq 'Missing') {
            $result.Status = 'Missing'
            $result.LastError = "Service '$Name' is not installed."
            Write-Log -Message "Service '$Name' is not installed." -Level 'WARNING'
        }
        elseif ($status['StartType'] -eq 'Disabled') {
            $result.Status = 'Disabled'
            $result.LastError = "Service '$Name' is disabled; the watchdog never changes start types."
            Write-Log -Message "Service '$Name' is Disabled; skipped." -Level 'WARNING'
        }
        elseif ($status.Status -eq 'Running') {
            $result.Status = 'Healthy'
            Write-Log -Message "Service '$Name' is Running." -Level 'DEBUG'
        }
        elseif ($status.Status -eq 'StartPending') {
            $remaining = Get-WatchdogRemainingBudget
            $wait = [math]::Min($Config.StartPendingWaitSeconds, $remaining)
            $message = "Service '$Name' is StartPending; waiting up to $wait seconds (no new start issued)."
            Write-Log -Message $message -Level 'INFO'
            try {
                $literal = [System.Management.Automation.WildcardPattern]::Escape($status.ResolvedName)
                $service = Get-Service -Name $literal -ErrorAction Stop
                Wait-WatchdogServiceStatus -Service $service -Status 'Running' -TimeoutSeconds $wait
                $result.Status = 'Healthy'
                Write-Log -Message "Service '$Name' reached Running." -Level 'INFO'
            }
            catch {
                $result.Status = 'Failed'
                $result.LastError = ("Service '$Name' was still StartPending after waiting $wait seconds " +
                    "(time budget remaining: $remaining seconds).")
                Write-Log -Message $result.LastError -Level 'WARNING'
            }
        }
        else {
            $result.Status = 'Failed'
            $result.Eligible = $true
            $result.LastError = "Service '$Name' is $($status.Status)."
            Write-Log -Message "Service '$Name' is $($status.Status); eligible for start rounds." -Level 'WARNING'
        }
    }
    catch {
        $result.Status = 'Unknown'
        $result.Eligible = $false
        $result.LastError = "Check failed unexpectedly: $_"
        Write-Log -Message "Service '$Name' check threw an unexpected error: $_" -Level 'WARNING'
    }

    return $result
}

function Invoke-WatchdogStartRounds {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns',
        '',
        Justification = 'Function name is fixed by the DESIGN.md / task interface contract.'
    )]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $eligible = [System.Collections.Generic.List[object]]::new()
    foreach ($result in $Results) {
        if ($result.Eligible) {
            $eligible.Add($result)
        }
    }
    if ($eligible.Count -eq 0) {
        return
    }

    if ($script:DryRun) {
        foreach ($result in $eligible) {
            $message = "[DRYRUN] Would start service '$($result.Name)' (up to $($Config.MaxStartAttempts) rounds)."
            Write-Log -Message $message -Level 'INFO'
        }
        return
    }

    $round = 1
    while ($eligible.Count -gt 0 -and $round -le $Config.MaxStartAttempts) {
        $remaining = Get-WatchdogRemainingBudget
        if ($remaining -le 0) {
            break
        }
        $message = "Start round $round of $($Config.MaxStartAttempts): $($eligible.Count) service(s), " +
        "$remaining seconds left."
        Write-Log -Message $message -Level 'INFO'

        foreach ($result in @($eligible)) {
            $wait = [math]::Min($Config.PostStartVerifySeconds, (Get-WatchdogRemainingBudget))
            $result.Attempts = $round
            $started = $false
            try {
                $description = "Start service '$($result.ResolvedName)' (round $round)"
                Invoke-Action -Description $description -FailureLevel 'WARNING' -Action {
                    Start-WatchdogService -Name $result.ResolvedName -WaitSeconds $wait
                }
                $started = $true
            }
            catch {
                $result.LastError = [string]$_.Exception.Message
            }

            try {
                $current = Get-WatchdogServiceStatus -Name $result.ResolvedName
                $currentStatus = [string]$current.Status
            }
            catch {
                $currentStatus = 'Unknown'
                $result.LastError = "Re-read after start failed: $_"
            }

            if ($currentStatus -eq 'Running') {
                $result.Status = 'Healthy'
                $result.Eligible = $false
                $result.Remediated = $true
                $result.LastError = $null
                $eligible.Remove($result) | Out-Null
                $message = "Service '$($result.Name)' started successfully on attempt $round of " +
                "$($Config.MaxStartAttempts)."
                Write-Log -Message $message -Level 'SUCCESS'
                Write-WatchdogEvent -EventId 1001 -EntryType 'Information' -Message $message
            }
            elseif ($started) {
                $result.LastError = "Service '$($result.Name)' reached Running and then stopped again " +
                "($currentStatus) after the start on attempt $round."
                Write-Log -Message $result.LastError -Level 'WARNING'
            }
            else {
                $message = "Service '$($result.Name)' still $currentStatus after attempt $round`: $($result.LastError)"
                Write-Log -Message $message -Level 'WARNING'
            }
        }

        if ($eligible.Count -gt 0 -and $round -lt $Config.MaxStartAttempts) {
            $delay = [math]::Min($Config.RetryDelaySeconds, (Get-WatchdogRemainingBudget))
            if ($delay -gt 0) {
                Write-Log -Message "Waiting $delay seconds before the next round." -Level 'INFO'
                Start-Sleep -Seconds $delay
            }
        }
        $round++
    }

    foreach ($result in $eligible) {
        $result.Status = 'Failed'
        if ((Get-WatchdogRemainingBudget) -le 0 -and $result.Attempts -lt $Config.MaxStartAttempts) {
            $note = "Time budget of $($Config.MaxRunSeconds) seconds exhausted after $($result.Attempts) " +
            'start attempt(s).'
            if ($result.LastError) {
                $result.LastError = "$note Last error: $($result.LastError)"
            }
            else {
                $result.LastError = $note
            }
            Write-Log -Message "Service '$($result.Name)': $note" -Level 'WARNING'
        }
    }
}

function Update-WatchdogFlapState {
    # Maintains the rolling flap window and suppression fields on a state entry (DESIGN.md
    # 4.6). Returns the category override ('flapping' or $null), whether the service is
    # suppressed for this run, and the flap count to report in the payload.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Edits an in-memory hashtable only; the state file write is gated by Invoke-Action.'
    )]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Entry,

        [Parameter(Mandatory)]
        [bool]$Transition,

        [Parameter(Mandatory)]
        [datetime]$Now,

        [Parameter(Mandatory)]
        [int]$ReminderMinutes
    )

    $count = [int]$Entry.FlapCount
    $suppressedUntil = ConvertFrom-WatchdogTimestamp -Value $Entry.FlapSuppressedUntilUtc

    if ($null -ne $suppressedUntil) {
        if ($Now -lt $suppressedUntil) {
            if ($Transition) {
                $Entry.FlapCount = $count + 1
            }
            return @{ Category = $null; Suppressed = $true; FlapCount = [int]$Entry.FlapCount }
        }

        # Suppression has expired. FlapCount counted transitions during suppression.
        if ($count -eq 0 -and -not $Transition) {
            $Entry.FlapCount = 0
            $Entry.FlapWindowStartUtc = $null
            $Entry.FlapSuppressedUntilUtc = $null
            $message = 'Flap suppression released; the service held one status for the whole interval.'
            Write-Log -Message $message -Level 'INFO'
            return @{ Category = $null; Suppressed = $false; FlapCount = 0 }
        }
        if ($count -eq 0) {
            # Stable during suppression; this run's transition is the first of a new window.
            $Entry.FlapCount = 1
            $Entry.FlapWindowStartUtc = ConvertTo-WatchdogTimestamp -Value $Now
            $Entry.FlapSuppressedUntilUtc = $null
            $message = 'Flap suppression released; normal notification resumes with this transition.'
            Write-Log -Message $message -Level 'INFO'
            return @{ Category = $null; Suppressed = $false; FlapCount = 1 }
        }

        $reported = $count + $(if ($Transition) { 1 } else { 0 })
        $until = $Now.AddMinutes($ReminderMinutes)
        $Entry.FlapCount = 0
        $Entry.FlapWindowStartUtc = ConvertTo-WatchdogTimestamp -Value $Now
        $Entry.FlapSuppressedUntilUtc = ConvertTo-WatchdogTimestamp -Value $until
        $message = "Service is still flapping ($reported transition(s) during suppression); " +
        "notifications suppressed until $($Entry.FlapSuppressedUntilUtc)."
        Write-Log -Message $message -Level 'WARNING'
        Write-WatchdogEvent -EventId 1007 -EntryType 'Warning' -Message $message
        return @{ Category = 'flapping'; Suppressed = $true; FlapCount = $reported }
    }

    $windowStart = ConvertFrom-WatchdogTimestamp -Value $Entry.FlapWindowStartUtc
    $windowExpired = ($null -eq $windowStart) -or ($Now - $windowStart).TotalMinutes -ge $script:FlapWindowMinutes

    if (-not $Transition) {
        if ($windowExpired -and $count -gt 0) {
            $Entry.FlapCount = 0
            $Entry.FlapWindowStartUtc = $null
        }
        return @{ Category = $null; Suppressed = $false; FlapCount = [int]$Entry.FlapCount }
    }

    if ($windowExpired) {
        $Entry.FlapCount = 1
        $Entry.FlapWindowStartUtc = ConvertTo-WatchdogTimestamp -Value $Now
        return @{ Category = $null; Suppressed = $false; FlapCount = 1 }
    }

    $count++
    $Entry.FlapCount = $count
    if ($count -lt $script:FlapThreshold) {
        return @{ Category = $null; Suppressed = $false; FlapCount = $count }
    }

    $until = $Now.AddMinutes($ReminderMinutes)
    $Entry.FlapCount = 0
    $Entry.FlapWindowStartUtc = ConvertTo-WatchdogTimestamp -Value $Now
    $Entry.FlapSuppressedUntilUtc = ConvertTo-WatchdogTimestamp -Value $until
    $message = "Service is flapping ($count transitions within $($script:FlapWindowMinutes) minutes); " +
    "notifications suppressed until $($Entry.FlapSuppressedUntilUtc)."
    Write-Log -Message $message -Level 'WARNING'
    Write-WatchdogEvent -EventId 1007 -EntryType 'Warning' -Message $message
    return @{ Category = 'flapping'; Suppressed = $true; FlapCount = $count }
}

function Get-WatchdogNotificationPlan {
    # Applies the DESIGN.md 4.6 decision table to every service result and writes the
    # per-service events (1002 to 1005, 1007). Returns the run's event type, the per-service
    # items with their new state entries, and the names that trigger the notification.
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [datetime]$Now
    )

    $nowText = ConvertTo-WatchdogTimestamp -Value $Now
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($result in $Results) {
        $previous = $null
        if ($State.Services.ContainsKey($result.Name)) {
            $previous = $State.Services[$result.Name]
        }
        $previousStatus = if ($previous) { [string]$previous.Status } else { 'none' }
        $newStatus = [string]$result.Status
        $previousProblem = $script:ProblemStatuses -contains $previousStatus
        $newProblem = $script:ProblemStatuses -contains $newStatus

        $entry = @{
            Status                 = $newStatus
            FirstFailedUtc         = $(if ($previous) { $previous.FirstFailedUtc } else { $null })
            LastNotifiedUtc        = $(if ($previous) { $previous.LastNotifiedUtc } else { $null })
            LastRemediatedUtc      = $(if ($previous) { $previous.LastRemediatedUtc } else { $null })
            LastError              = $result.LastError
            FlapCount              = $(if ($previous) { [int]$previous.FlapCount } else { 0 })
            FlapWindowStartUtc     = $(if ($previous) { $previous.FlapWindowStartUtc } else { $null })
            FlapSuppressedUntilUtc = $(if ($previous) { $previous.FlapSuppressedUntilUtc } else { $null })
        }

        $category = $null
        if (-not $previousProblem -and $newProblem) {
            $category = 'alert'
            $entry.FirstFailedUtc = $nowText
        }
        elseif ($previousProblem -and $newProblem -and $previousStatus -eq $newStatus) {
            $lastNotified = ConvertFrom-WatchdogTimestamp -Value $previous.LastNotifiedUtc
            if ($null -eq $lastNotified -or ($Now - $lastNotified).TotalMinutes -ge $Config.Alerting.ReminderMinutes) {
                $category = 'reminder'
            }
            if (-not $entry.FirstFailedUtc) {
                $entry.FirstFailedUtc = $nowText
            }
        }
        elseif ($previousProblem -and $newProblem) {
            $category = 'alert'
            if (-not $entry.FirstFailedUtc) {
                $entry.FirstFailedUtc = $nowText
            }
        }
        elseif ($previousProblem -and -not $newProblem) {
            $category = 'recovered'
            $entry.FirstFailedUtc = $null
        }
        elseif ($result.Remediated) {
            $lastRemediated = ConvertFrom-WatchdogTimestamp -Value $entry.LastRemediatedUtc
            $cooldownOver = ($null -eq $lastRemediated) -or
            ($Now - $lastRemediated).TotalMinutes -ge $Config.Alerting.RemediationCooldownMinutes
            if ($Config.Alerting.NotifyOnRemediation -and $cooldownOver) {
                $category = 'remediated'
            }
            elseif ($Config.Alerting.NotifyOnRemediation) {
                $message = "Service '$($result.Name)' remediated inside the cooldown window; not notifying."
                Write-Log -Message $message -Level 'INFO'
            }
        }
        if ($result.Remediated) {
            $entry.LastRemediatedUtc = $nowText
        }

        $transition = ($previousProblem -ne $newProblem)
        $flap = Update-WatchdogFlapState -Entry $entry -Transition $transition -Now $Now `
            -ReminderMinutes $Config.Alerting.ReminderMinutes
        if ($flap.Category -eq 'flapping') {
            $category = 'flapping'
        }
        elseif ($flap.Suppressed) {
            if ($category) {
                $message = "Service '$($result.Name)' is flap-suppressed; '$category' notification withheld."
                Write-Log -Message $message -Level 'INFO'
            }
            $category = $null
        }

        $payloadStatus = $newStatus
        if ($category -eq 'recovered') {
            $payloadStatus = 'Recovered'
        }
        elseif ($result.Remediated) {
            $payloadStatus = 'Remediated'
        }

        if ($category -in @('alert', 'flapping', 'reminder')) {
            $detail = if ($result.LastError) { " Last error: $($result.LastError)" } else { '' }
            switch ($newStatus) {
                'Failed' {
                    $eventMessage = "Service '$($result.Name)' failed to start after $($result.Attempts) " +
                    "attempt(s).$detail"
                    Write-WatchdogEvent -EventId 1002 -EntryType 'Error' -Message $eventMessage
                }
                'Missing' {
                    $eventMessage = "Service '$($result.Name)' is not installed."
                    Write-WatchdogEvent -EventId 1003 -EntryType 'Warning' -Message $eventMessage
                }
                'Disabled' {
                    $eventMessage = "Service '$($result.Name)' is disabled and was skipped."
                    Write-WatchdogEvent -EventId 1004 -EntryType 'Warning' -Message $eventMessage
                }
            }
        }
        elseif ($category -eq 'recovered') {
            $eventMessage = "Service '$($result.Name)' recovered (previous status $previousStatus)."
            Write-WatchdogEvent -EventId 1005 -EntryType 'Information' -Message $eventMessage
        }

        if ($category) {
            $message = "Service '$($result.Name)': $previousStatus -> $newStatus, category '$category'."
            Write-Log -Message $message -Level 'INFO'
        }
        else {
            $message = "Service '$($result.Name)': $previousStatus -> $newStatus, nothing to notify."
            Write-Log -Message $message -Level 'DEBUG'
        }

        $items.Add(@{
                Name           = $result.Name
                ResolvedName   = $result.ResolvedName
                DisplayName    = $result.DisplayName
                StartType      = $result['StartType']
                Status         = $newStatus
                PayloadStatus  = $payloadStatus
                Category       = $category
                Notify         = [bool]$category
                Attempts       = [int]$result.Attempts
                LastError      = $result.LastError
                FirstFailedUtc = $entry.FirstFailedUtc
                FlapCount      = [int]$flap.FlapCount
                Entry          = $entry
                Previous       = $previous
            })
    }

    $eventType = $null
    foreach ($candidate in $script:EventTypePriority) {
        if (@($items | Where-Object { $_.Category -eq $candidate }).Count -gt 0) {
            $eventType = $candidate
            break
        }
    }
    $notifiable = @($items | Where-Object { $_.Notify } | ForEach-Object { $_.Name })

    return [pscustomobject]@{
        EventType       = $eventType
        Items           = @($items.ToArray())
        NotifiableNames = $notifiable
    }
}

function Get-WatchdogPendingServiceList {
    # Names that would be recorded in PendingServices if delivery failed: every notifiable
    # service except 'remediated' ones, which are informational and dropped on failure.
    param ([object]$Plan)

    return @($Plan.Items | Where-Object { $_.Notify -and $_.Category -ne 'remediated' } | ForEach-Object { $_.Name })
}

function Get-WatchdogEventId {
    param (
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$EventType,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ServiceNames
    )

    if ($State.PendingNotification -and $State.PendingEventId -and $State.PendingEventType -eq $EventType) {
        $pending = @($State.PendingServices | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
        $current = @($ServiceNames | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        if (($pending -join '|') -eq ($current -join '|')) {
            Write-Log -Message "Reusing pending EventId $($State.PendingEventId) for '$EventType'." -Level 'INFO'
            return [string]$State.PendingEventId
        }
    }
    return [guid]::NewGuid().ToString()
}

function New-WatchdogPayload {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Builds an in-memory payload only; no system state changes.'
    )]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('alert', 'flapping', 'reminder', 'recovered', 'remediated', 'test', 'heartbeat')]
        [string]$EventType,

        [Parameter(Mandatory)]
        [string]$EventId,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [string]$Summary,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [datetime]$Now
    )

    $identity = Get-WatchdogHostIdentity
    $services = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Items) {
        $services.Add([ordered]@{
                Name           = [string]$item.Name
                DisplayName    = Limit-WatchdogString -Value $item.DisplayName -MaxLength 256
                Status         = [string]$item.PayloadStatus
                StartType      = $item['StartType']
                Attempts       = [int]$item.Attempts
                FirstFailedUtc = ConvertTo-WatchdogTimestamp -Value $item.FirstFailedUtc
                LastError      = Limit-WatchdogString -Value $item.LastError -MaxLength 1000
                FlapCount      = [int]$item.FlapCount
                Notify         = ($EventType -ne 'heartbeat' -and [bool]$item.Notify)
            })
    }

    return [ordered]@{
        SchemaVersion   = 1
        EventType       = $EventType
        EventId         = $EventId
        SiteName        = [string]$Config.SiteName
        HostName        = [string]$identity.HostName
        Fqdn            = $identity.Fqdn
        TimestampUtc    = ConvertTo-WatchdogTimestamp -Value $Now
        RunId           = $RunId
        WatchdogVersion = $script:WatchdogVersion
        Summary         = Limit-WatchdogString -Value $Summary -MaxLength 512
        Services        = @($services.ToArray())
    }
}

function Get-WatchdogFailureDetail {
    # Extracts the HTTP status code and response body from a failed web request on both
    # Windows PowerShell 5.1 (WebException) and PowerShell 7 (HttpResponseException).
    param ([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $statusCode = $null
    $body = $null
    $response = $null
    try {
        $response = $ErrorRecord.Exception.Response
    }
    catch {
        $response = $null
    }
    if ($null -ne $response) {
        try {
            $statusCode = [int]$response.StatusCode
        }
        catch {
            $statusCode = $null
        }
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $body = $ErrorRecord.ErrorDetails.Message
        }
        else {
            try {
                $stream = $response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            }
            catch {
                $body = $null
            }
        }
    }
    return @{ StatusCode = $statusCode; Body = $body; Message = [string]$ErrorRecord.Exception.Message }
}

function Send-WatchdogEvent {
    # POSTs one payload (DESIGN.md 4.7). Returns Delivered ($true, $false, or $null under
    # -DryRun), StatusCode, FailureEventId (1011/1013/1014/1015) and Message.
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Payload,

        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $eventType = [string]$Payload.EventType
    $eventId = [string]$Payload.EventId
    $safeUrl = ConvertTo-WatchdogSafeUrl -Url $Config.Webhook.Url
    $json = ConvertTo-Json -InputObject $Payload -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    if ($script:DryRun) {
        $message = "[DRYRUN] Would POST '$eventType' event $eventId ($($bytes.Length) bytes) to $safeUrl"
        Write-Log -Message $message -Level 'INFO'
        return @{ Delivered = $null; StatusCode = $null; FailureEventId = $null; Message = 'dry run' }
    }

    $headers = @{
        'x-functions-key' = $Config.Webhook.FunctionKey
        'User-Agent'      = $script:UserAgent
    }
    $failureEventId = $null
    $failureMessage = $null
    $statusCode = $null

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $message = "POST '$eventType' event $eventId to $safeUrl (attempt $attempt of 2, $($bytes.Length) bytes)."
        Write-Log -Message $message -Level 'INFO'
        $retryable = $false
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Config.Webhook.Url -Headers $headers `
                -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec $Config.Webhook.TimeoutSeconds `
                -ErrorAction Stop
            $statusCode = [int]$response.StatusCode
            if ($statusCode -ge 200 -and $statusCode -lt 300) {
                $detail = ''
                try {
                    $parsed = ConvertFrom-Json -InputObject ([string]$response.Content) -ErrorAction Stop
                    $detail = " accepted=$($parsed.accepted) emailSent=$($parsed.emailSent) " +
                    "duplicate=$($parsed.duplicate)"
                }
                catch {
                    $detail = ''
                }
                $message = "Delivered '$eventType' event $eventId (HTTP $statusCode).$detail"
                Write-Log -Message $message -Level 'SUCCESS'
                $successEventId = switch ($eventType) {
                    'heartbeat' { 1012 }
                    'test' { 1030 }
                    default { 1010 }
                }
                Write-WatchdogEvent -EventId $successEventId -EntryType 'Information' -Message $message
                return @{ Delivered = $true; StatusCode = $statusCode; FailureEventId = $null; Message = $message }
            }
            $failureMessage = "Unexpected HTTP $statusCode from the webhook."
            $failureEventId = 1011
            $retryable = $true
        }
        catch {
            $detail = Get-WatchdogFailureDetail -ErrorRecord $_
            $statusCode = $detail.StatusCode
            $bodyText = ''
            if ($detail.Body) {
                $bodyText = " Response: $(Limit-WatchdogString -Value $detail.Body -MaxLength 500)"
            }
            if ($null -eq $statusCode) {
                $failureEventId = 1011
                $failureMessage = "Network, DNS or timeout error: $($detail.Message)"
                $retryable = $true
            }
            elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                $failureEventId = 1013
                $failureMessage = "HTTP $statusCode from the webhook; check the function key.$bodyText"
            }
            elseif ($statusCode -eq 429 -or $statusCode -ge 500) {
                $failureEventId = 1015
                $failureMessage = "HTTP $statusCode from the webhook.$bodyText"
                $retryable = $true
            }
            elseif ($statusCode -ge 400) {
                $failureEventId = 1014
                $failureMessage = "HTTP $statusCode from the webhook; payload rejected.$bodyText"
            }
            else {
                $failureEventId = 1011
                $failureMessage = "HTTP $statusCode from the webhook: $($detail.Message)"
                $retryable = $true
            }
        }

        if ($retryable -and $attempt -eq 1) {
            $message = "Delivery attempt $attempt failed ($failureMessage); retrying in " +
            "$($script:RetryDelaySecondsOnDelivery) seconds."
            Write-Log -Message $message -Level 'WARNING'
            Start-Sleep -Seconds $script:RetryDelaySecondsOnDelivery
            continue
        }
        break
    }

    $message = "Delivery of '$eventType' event $eventId failed: $failureMessage Will retry on the next run."
    Write-Log -Message $message -Level 'ERROR'
    Write-WatchdogEvent -EventId $failureEventId -EntryType 'Error' -Message $message
    return @{ Delivered = $false; StatusCode = $statusCode; FailureEventId = $failureEventId; Message = $message }
}

function Update-WatchdogState {
    # Commits the plan's new entries to the state per the DESIGN.md 4.6 delivery rules.
    # Delivered: $true on success, $false on failure, $null when nothing was sent.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Edits an in-memory hashtable only; the state file write is gated by Invoke-Action.'
    )]
    param (
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [object]$Plan,

        [AllowNull()]
        [object]$Delivered,

        [AllowNull()]
        [string]$EventId,

        [Parameter(Mandatory)]
        [datetime]$Now
    )

    $nowText = ConvertTo-WatchdogTimestamp -Value $Now
    $pendingNames = [System.Collections.Generic.List[string]]::new()
    $attempted = ($null -ne $Plan.EventType) -and ($null -ne $Delivered)

    foreach ($item in $Plan.Items) {
        $entry = $item.Entry
        if ($attempted -and $item.Notify) {
            if ($Delivered -eq $true) {
                $entry.LastNotifiedUtc = $nowText
            }
            elseif ($item.Category -eq 'remediated') {
                $message = "Service '$($item.Name)': remediated notification dropped after failed delivery " +
                '(informational only).'
                Write-Log -Message $message -Level 'WARNING'
            }
            else {
                # DESIGN.md 4.6: the previous Status, FirstFailedUtc and LastNotifiedUtc are
                # preserved so the next run computes the same transition again and re-sends.
                # The flap fields are restored as well: the preserved transition is counted
                # exactly once, when it is finally committed, instead of once per retry run
                # (which would turn a single outage into 'flapping' during a webhook outage).
                $previous = $item.Previous
                $entry.Status = $(if ($previous) { $previous.Status } else { 'Healthy' })
                $entry.FirstFailedUtc = $(if ($previous) { $previous.FirstFailedUtc } else { $null })
                $entry.LastNotifiedUtc = $(if ($previous) { $previous.LastNotifiedUtc } else { $null })
                $entry.FlapCount = $(if ($previous) { [int]$previous.FlapCount } else { 0 })
                $entry.FlapWindowStartUtc = $(if ($previous) { $previous.FlapWindowStartUtc } else { $null })
                $entry.FlapSuppressedUntilUtc = $(if ($previous) { $previous.FlapSuppressedUntilUtc } else { $null })
                $pendingNames.Add($item.Name)
            }
        }
        $State.Services[$item.Name] = $entry
    }

    if ($pendingNames.Count -gt 0) {
        $State.PendingNotification = $true
        $State.PendingEventId = $EventId
        $State.PendingEventType = $Plan.EventType
        $State.PendingServices = @($pendingNames.ToArray())
        $message = "Notification '$($Plan.EventType)' is pending for: $($pendingNames -join ', ')."
        Write-Log -Message $message -Level 'WARNING'
    }
    else {
        $State.PendingNotification = $false
        $State.PendingEventId = $null
        $State.PendingEventType = $null
        $State.PendingServices = @()
    }
}

function Test-WatchdogHeartbeatDue {
    param (
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [hashtable]$Config,

        [Parameter(Mandatory)]
        [datetime]$Now
    )

    $last = ConvertFrom-WatchdogTimestamp -Value $State.LastHeartbeatUtc
    if ($null -eq $last) {
        return $true
    }
    return (($Now - $last).TotalHours -ge $Config.Alerting.HeartbeatHours)
}

function Get-WatchdogSummary {
    param (
        [Parameter(Mandatory)]
        [string]$EventType,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [string]$HostName
    )

    $total = $Items.Count
    $problems = @($Items | Where-Object { $script:ProblemStatuses -contains $_.Status })
    $named = @($Items | Where-Object { $_.Notify } | ForEach-Object { $_.Name })
    $down = "$($problems.Count) of $total monitored services"
    switch ($EventType) {
        'alert' { return "$down are down" }
        'reminder' { return "Reminder: $down are still down" }
        'flapping' { return "Flapping: $($named -join ', ') ($down down)" }
        'recovered' { return "Recovered: $($named -join ', ') ($down down)" }
        'remediated' { return "Remediated: $($named -join ', ') ($down down)" }
        'heartbeat' { return "Heartbeat: $total monitored services, $($problems.Count) with problems" }
        default { return "Test alert from $HostName" }
    }
}

function Write-WatchdogConfigSummary {
    param ([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$ConfigPath)

    $logRoot = if ($Config.Logging.LogRoot) { $Config.Logging.LogRoot } else { $script:DefaultLogRoot }
    $lines = @(
        "Configuration valid: $ConfigPath"
        "  SiteName:                $($Config.SiteName)"
        "  Services ($($Config.Services.Count)):            $($Config.Services -join ', ')"
        "  MaxStartAttempts:        $($Config.MaxStartAttempts)"
        "  RetryDelaySeconds:       $($Config.RetryDelaySeconds)"
        "  PostStartVerifySeconds:  $($Config.PostStartVerifySeconds)"
        "  StartPendingWaitSeconds: $($Config.StartPendingWaitSeconds)"
        "  MaxRunSeconds:           $($Config.MaxRunSeconds)"
        "  Webhook.Url:             $(ConvertTo-WatchdogSafeUrl -Url $Config.Webhook.Url)"
        "  Webhook.FunctionKey:     ******** (set)"
        "  Webhook.TimeoutSeconds:  $($Config.Webhook.TimeoutSeconds)"
        "  ReminderMinutes:         $($Config.Alerting.ReminderMinutes)"
        "  NotifyOnRemediation:     $($Config.Alerting.NotifyOnRemediation)"
        "  RemediationCooldown:     $($Config.Alerting.RemediationCooldownMinutes) minutes"
        "  HeartbeatHours:          $($Config.Alerting.HeartbeatHours)"
        "  LogRoot:                 $logRoot"
        "  LogRetentionDays:        $($Config.Logging.LogRetentionDays)"
        "  EventLogHealthyRuns:     $($Config.Logging.EventLogHealthyRuns)"
    )
    foreach ($line in $lines) {
        Write-Host $line
        Write-Log -Message $line -Level 'INFO'
    }
}

function Invoke-WatchdogMain {
    param (
        [string]$ConfigPath = $script:RunOptions.ConfigPath,
        [string[]]$ServiceName = $script:RunOptions.ServiceName,
        [switch]$ValidateConfig = $script:RunOptions.ValidateConfig,
        [switch]$TestAlert = $script:RunOptions.TestAlert,
        [switch]$SendHeartbeat = $script:RunOptions.SendHeartbeat,
        [switch]$DryRun = $script:RunOptions.DryRun,
        [string]$Verbosity = $script:RunOptions.Verbosity,
        [string]$LogPath = $script:RunOptions.LogPath
    )

    $scriptStartTime = Get-Date
    $script:Verbosity = $Verbosity
    $script:DryRun = [bool]$DryRun
    $script:EventSourceReady = $null
    $script:RunStopwatch = $null
    if (-not $ConfigPath) {
        $ConfigPath = $script:DefaultConfigPath
    }
    $dailyLogName = "ServiceWatchdog-$(Get-Date -Format 'yyyyMMdd').log"
    if ($LogPath) {
        Initialize-WatchdogLog -Path $LogPath
    }
    else {
        Initialize-WatchdogLog -Path (Join-Path $script:DefaultLogRoot $dailyLogName)
    }

    $exitCode = 0
    try {
        $mode = if ($ValidateConfig) { 'ValidateConfig' } elseif ($TestAlert) { 'TestAlert' } else { 'Run' }
        $startMessage = "ServiceWatchdog $($script:WatchdogVersion) started. Mode=$mode, ConfigPath=$ConfigPath, " +
        "ServiceName=$(if ($ServiceName) { $ServiceName -join ',' } else { '(config)' }), " +
        "SendHeartbeat=$([bool]$SendHeartbeat), DryRun=$([bool]$DryRun), Verbosity=$Verbosity, " +
        "PowerShell=$($PSVersionTable.PSVersion)"
        Write-Log -Message $startMessage -Level 'INFO'
        if ($script:DryRun) {
            $message = '*** DRYRUN MODE - no service starts, webhook calls, state writes or event log entries ***'
            Write-Log -Message $message -Level 'WARNING'
        }

        $modeCount = @($ValidateConfig, $TestAlert, $SendHeartbeat | Where-Object { $_ }).Count
        if ($modeCount -gt 1) {
            Write-Log -Message '-ValidateConfig, -TestAlert and -SendHeartbeat are mutually exclusive.' -Level 'ERROR'
            return 2
        }

        # Configuration
        try {
            $rawConfig = Import-WatchdogConfig -Path $ConfigPath
        }
        catch {
            $message = "Configuration invalid: $_"
            Write-Log -Message $message -Level 'ERROR'
            Write-WatchdogEvent -EventId 1020 -EntryType 'Error' -Message $message
            return 2
        }
        $validation = Test-WatchdogConfig -Config $rawConfig
        foreach ($warning in $validation.Warnings) {
            Write-Log -Message "Configuration warning: $warning" -Level 'WARNING'
        }
        if (-not $validation.IsValid) {
            foreach ($violation in $validation.Errors) {
                Write-Log -Message "Configuration error: $violation" -Level 'ERROR'
            }
            $message = "Configuration file '$ConfigPath' is invalid ($($validation.Errors.Count) error(s)): " +
            ($validation.Errors -join ' | ')
            Write-WatchdogEvent -EventId 1020 -EntryType 'Error' -Message $message
            return 2
        }
        $config = $validation.Config

        if ($ServiceName) {
            $config.Services = @($ServiceName | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $message = "Service list override from -ServiceName: $($config.Services -join ', ') " +
            '(config list not used this run).'
            Write-Log -Message $message -Level 'WARNING'
        }

        $logRoot = if ($config.Logging.LogRoot) { $config.Logging.LogRoot } else { $script:DefaultLogRoot }
        if (-not $LogPath -and $config.Logging.LogRoot) {
            Initialize-WatchdogLog -Path (Join-Path $logRoot $dailyLogName)
            Write-Log -Message "Logging to configured LogRoot '$logRoot'." -Level 'INFO'
        }
        if ($ValidateConfig) {
            Write-WatchdogConfigSummary -Config $config -ConfigPath $ConfigPath
            Write-Log -Message 'Configuration validated successfully.' -Level 'SUCCESS'
            return 0
        }

        Remove-WatchdogOldLogs -LogRoot $logRoot -RetentionDays $config.Logging.LogRetentionDays
        Initialize-WatchdogTransportSecurity
        $identity = Get-WatchdogHostIdentity
        $runId = [guid]::NewGuid().ToString()
        Write-Log -Message "RunId=$runId Host=$($identity.HostName) Fqdn=$($identity.Fqdn)" -Level 'INFO'

        if ($TestAlert) {
            $now = Get-WatchdogUtcNow
            $payload = New-WatchdogPayload -EventType 'test' -EventId ([guid]::NewGuid().ToString()) -Config $config `
                -Items @() -Summary (Get-WatchdogSummary -EventType 'test' -Items @() -HostName $identity.HostName) `
                -RunId $runId -Now $now
            $delivery = Send-WatchdogEvent -Payload $payload -Config $config
            if ($delivery.Delivered -eq $false) {
                Write-Log -Message 'Test alert was not delivered.' -Level 'ERROR'
                return 10
            }
            Write-Log -Message 'Test alert completed.' -Level 'SUCCESS'
            return 0
        }

        # State
        $configFolder = Split-Path -Path (Resolve-Path -LiteralPath $ConfigPath).ProviderPath -Parent
        $statePath = Join-Path $configFolder $script:StateFileName
        $state = Get-WatchdogState -Path $statePath
        Remove-WatchdogUnmonitoredState -State $state -ServiceNames $config.Services

        # Service checks and start rounds inside the time budget
        $script:MaxRunSeconds = $config.MaxRunSeconds
        $script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $results = [System.Collections.Generic.List[object]]::new()
        foreach ($name in $config.Services) {
            $results.Add((Invoke-WatchdogServiceCheck -Name $name -Config $config))
        }
        Invoke-WatchdogStartRounds -Results @($results.ToArray()) -Config $config
        $script:RunStopwatch.Stop()

        # Notification decision and delivery
        $now = Get-WatchdogUtcNow
        $plan = Get-WatchdogNotificationPlan -Results @($results.ToArray()) -State $state -Config $config -Now $now
        $delivered = $null
        $eventId = $null
        if ($plan.EventType) {
            $pendingNames = Get-WatchdogPendingServiceList -Plan $plan
            $eventId = Get-WatchdogEventId -State $state -EventType $plan.EventType -ServiceNames $pendingNames
            $summary = Get-WatchdogSummary -EventType $plan.EventType -Items $plan.Items -HostName $identity.HostName
            $payload = New-WatchdogPayload -EventType $plan.EventType -EventId $eventId -Config $config `
                -Items $plan.Items -Summary $summary -RunId $runId -Now $now
            $delivery = Send-WatchdogEvent -Payload $payload -Config $config
            $delivered = $delivery.Delivered
        }
        else {
            Write-Log -Message 'No notification needed this run.' -Level 'INFO'
        }
        Update-WatchdogState -State $state -Plan $plan -Delivered $delivered -EventId $eventId -Now $now

        # Heartbeat
        $heartbeatFailed = $false
        if ($SendHeartbeat -or (Test-WatchdogHeartbeatDue -State $state -Config $config -Now $now)) {
            $reason = if ($SendHeartbeat) { 'forced by -SendHeartbeat' } else { 'due by schedule' }
            Write-Log -Message "Heartbeat $reason." -Level 'INFO'
            $summary = Get-WatchdogSummary -EventType 'heartbeat' -Items $plan.Items -HostName $identity.HostName
            $payload = New-WatchdogPayload -EventType 'heartbeat' -EventId ([guid]::NewGuid().ToString()) `
                -Config $config -Items $plan.Items -Summary $summary -RunId $runId -Now $now
            $heartbeat = Send-WatchdogEvent -Payload $payload -Config $config
            if ($heartbeat.Delivered -eq $true) {
                $state.LastHeartbeatUtc = ConvertTo-WatchdogTimestamp -Value $now
            }
            elseif ($heartbeat.Delivered -eq $false) {
                $heartbeatFailed = $true
            }
        }

        # Persist
        $state.HostName = $identity.HostName
        $state.LastRunUtc = ConvertTo-WatchdogTimestamp -Value $now
        Save-WatchdogState -Path $statePath -State $state

        # Exit code
        $problemNames = @($plan.Items | Where-Object { $script:ProblemStatuses -contains $_.Status } |
                ForEach-Object { $_.Name })
        $pending = ($delivered -eq $false -and $state.PendingNotification) -or $heartbeatFailed
        if ($problemNames.Count -gt 0) {
            $message = "$($problemNames.Count) service(s) unhealthy after retries: $($problemNames -join ', ')."
            Write-Log -Message $message -Level 'ERROR'
            $exitCode = 50
            if ($pending) {
                $message = 'A notification or heartbeat delivery is also pending; exit code 50 wins over 10.'
                Write-Log -Message $message -Level 'ERROR'
            }
        }
        elseif ($pending) {
            $message = 'All services healthy but a notification or heartbeat delivery is pending.'
            Write-Log -Message $message -Level 'ERROR'
            $exitCode = 10
        }
        else {
            $remediated = @($plan.Items | Where-Object { $_.PayloadStatus -eq 'Remediated' }).Count
            $message = "Run completed: all $($plan.Items.Count) monitored services healthy" +
            $(if ($remediated -gt 0) { " ($remediated remediated this run)." } else { '.' })
            Write-Log -Message $message -Level 'SUCCESS'
            if ($config.Logging.EventLogHealthyRuns) {
                Write-WatchdogEvent -EventId 1000 -EntryType 'Information' -Message $message
            }
        }
        return $exitCode
    }
    catch {
        $message = "Unexpected error: $_"
        Write-Log -Message $message -Level 'ERROR'
        Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
        Write-WatchdogEvent -EventId 1099 -EntryType 'Error' -Message $message
        return 1
    }
    finally {
        $duration = (Get-Date) - $scriptStartTime
        Write-Log -Message "Total duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Level 'INFO'
    }
}

#endregion

#region Script Body

# Guarded so tests can dot-source the functions without running the worker.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-WatchdogMain)
}

#endregion
