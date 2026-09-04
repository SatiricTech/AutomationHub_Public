#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs the ServiceWatchdog worker and registers its scheduled task on a Windows server.

.DESCRIPTION
    Windows-only. Runs elevated on the server being monitored and performs the one-time setup
    for the ServiceWatchdog worker (Invoke-WinServiceWatchdog.ps1):

      1. Creates the install folder and copies the worker there. An existing worker is left
         alone unless -Force is set (exit 2 otherwise). If no ServiceWatchdog.json exists, the
         example config is copied into place and the script stops with exit 2 so the
         operator can edit it and re-run.
      2. Locks the install folder down with icacls: inheritance removed, SYSTEM and
         Administrators full control (well-known SIDs, locale-safe). The folder holds the
         config file with the function key and the state file the worker writes beside it,
         and Task Scheduler runs whatever is in it as SYSTEM, so nothing else may write
         there. Because only this folder is protected, -ConfigPath must point inside it; any
         other folder is refused with exit 2 before anything is created.
      3. Validates the config by running the worker with -ValidateConfig in a fresh
         Windows PowerShell process (exit 2 on failure), then checks that
         -ExecutionTimeLimitSeconds covers the worst-case run time
         MaxRunSeconds + 2 * (2 * Webhook.TimeoutSeconds + 5) + 15 (exit 2 if not).
      4. Registers the ServiceWatchdog event log source in the Application log if missing,
         through System.Diagnostics.EventLog so the step works from both powershell.exe and
         pwsh (New-EventLog exists only in Windows PowerShell).
      5. Registers the scheduled task (always with Register-ScheduledTask -Force, so re-runs
         that only change scheduling parameters succeed): runs as NT AUTHORITY\SYSTEM at the
         highest run level, a daily trigger repeating every -IntervalMinutes for 24 hours, a
         boot trigger delayed by -StartupDelayMinutes, one instance at a time (IgnoreNew),
         an execution time limit, StartWhenAvailable, and battery settings that never block
         it. The action runs powershell.exe hidden with -NoProfile -NonInteractive; no
         argument carries a secret because the worker reads its config beside itself.
      6. Optionally sets Service Control Manager failure actions on every configured
         service (-SetServiceRecovery) as a complementary safety net for crashes.
      7. Optionally starts the task (-RunNow) and sends a test alert (-TestAlert).
      8. Prints a summary: install path, task name, next run time, config path, log path.

    Every mutation goes through Invoke-Action, so -DryRun logs each step with a [DRYRUN]
    prefix and changes nothing; validation still runs because it is read-only.

.PARAMETER InstallPath
    Folder that receives the worker, config, state and logs.
    Defaults to $env:ProgramData\ServiceWatchdog.

.PARAMETER SourcePath
    Folder containing Invoke-WinServiceWatchdog.ps1 and ServiceWatchdog.example.json to copy
    from. Defaults to the folder this script runs from.

.PARAMETER ConfigPath
    Config file to validate and use. Defaults to <InstallPath>\ServiceWatchdog.json. It must
    live inside InstallPath (any file name), because that is the only folder step 2 protects
    and the worker writes its state file beside the config; a path outside InstallPath is
    refused with exit 2. When the name differs from the default, the task action passes
    -ConfigPath to the worker so both agree.

.PARAMETER TaskName
    Task name in the root Task Scheduler folder. Defaults to ServiceWatchdog.

.PARAMETER IntervalMinutes
    Repetition interval of the continuous schedule, 1 to 1440. Defaults to 5.

.PARAMETER StartupDelayMinutes
    Delay applied to the boot trigger, 0 to 1440. Defaults to 5.

.PARAMETER ExecutionTimeLimitSeconds
    Task execution limit, 60 to 86400. Defaults to 420. Must be at least the worst-case run
    time derived from the config (see step 3).

.PARAMETER SetServiceRecovery
    Also set SCM failure actions on each configured service with
    sc.exe failure <service> reset= 86400 actions= restart/60000/restart/120000/none/0.

.PARAMETER RunNow
    Start the task immediately after registration.

.PARAMETER TestAlert
    Run the worker with -TestAlert after registration so the operator can confirm the
    Azure side delivers mail. A failed delivery exits 10; the task stays registered.

.PARAMETER Force
    Overwrite a worker script that already exists in InstallPath.

.PARAMETER Verbosity
    Controls console output level. Valid values: Low, Medium, High.
    Low shows only errors and success. Medium adds warnings. High shows everything.
    The log file always receives every message.

.PARAMETER DryRun
    Simulates all actions without making changes. Logs what would happen with a [DRYRUN]
    prefix. The config is still validated because that step is read-only.

.PARAMETER LogPath
    Path to the log file. Defaults to
    $env:ProgramData\ServiceWatchdog\Logs\Register-WinServiceWatchdogTask-<timestamp>.log.

.EXAMPLE
    .\Register-WinServiceWatchdogTask.ps1

    First run on a server: copies the worker and example config, then stops with exit 2 so
    ServiceWatchdog.json can be edited. Run again afterwards to validate and register.

.EXAMPLE
    .\Register-WinServiceWatchdogTask.ps1 -SetServiceRecovery -RunNow -TestAlert -Verbosity High

    Registers the task, hardens each configured service's SCM recovery, starts the task and
    sends a test alert through the webhook.

.EXAMPLE
    .\Register-WinServiceWatchdogTask.ps1 -Force -IntervalMinutes 10 -DryRun

    Shows every step that a re-run with a 10-minute interval would perform, including the
    config validation result, without touching the server.

.NOTES
    Version:    1.0.0
    Created:    2026-09-04
    Platform:   Windows Server 2016 or later, Windows PowerShell 5.1 or PowerShell 7,
                elevated. #Requires -RunAsAdministrator stops the script before it runs when
                not elevated; the host reports exit 1 in that case.
    Exit codes: 0 success; 1 unexpected error; 2 config invalid, config not yet edited,
                config outside InstallPath, worker already present without -Force, or
                execution limit too small; 10 test alert not delivered (task registered);
                50 task registered but one or more -SetServiceRecovery steps failed.

    Checklist deviations from the powershell-authoring skill (Enterprise tier), per
    DESIGN.md section 4.1:
      - 3.1: targets Windows PowerShell 5.1 because Windows Server ships only 5.1; no
        PowerShell 7-only syntax is used.
      - 4.6: log root is $env:ProgramData\ServiceWatchdog\Logs (product-named) rather than
        $env:ProgramData\$MSPName\Logs, because the tool is deployed by end-client IT and
        the project is MSP-name-agnostic throughout.
      - 5.2: no SecretManagement vault. This script never reads the function key; the worker
        keeps it in the ACLed config file this script protects in step 2.
      - 5.7: ships unsigned in the public repository; adopters sign with their own
        certificate.
      - 6.6: the integration test is the operator acceptance run documented in the README.
      - 6.7: not applicable; the script runs once at install time.

    Developed with AI assistance (Claude); reviewed before publication.
#>

[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = (Join-Path $env:ProgramData 'ServiceWatchdog'),

    [ValidateNotNullOrEmpty()]
    [string]$SourcePath = $PSScriptRoot,

    [string]$ConfigPath,

    [ValidatePattern('^[^\\/]+$')]
    [string]$TaskName = 'ServiceWatchdog',

    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes = 5,

    [ValidateRange(0, 1440)]
    [int]$StartupDelayMinutes = 5,

    [ValidateRange(60, 86400)]
    [int]$ExecutionTimeLimitSeconds = 420,

    [switch]$SetServiceRecovery,

    [switch]$RunNow,

    [switch]$TestAlert,

    [switch]$Force,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Low',

    [switch]$DryRun,

    [string]$LogPath
)

#region Configuration & Constants

$ErrorActionPreference = 'Stop'
$script:Verbosity = $Verbosity
$script:DryRun = $DryRun.IsPresent

$script:ScriptVersion = '1.0.0'
$script:WorkerFileName = 'Invoke-WinServiceWatchdog.ps1'
$script:ExampleConfigFileName = 'ServiceWatchdog.example.json'
$script:ConfigFileName = 'ServiceWatchdog.json'
$script:EventLogName = 'Application'
$script:EventSourceName = 'ServiceWatchdog'
$script:SystemSid = 'S-1-5-18'
$script:AdministratorsSid = 'S-1-5-32-544'
$script:RepositoryName = 'AutomationHub_Public (Monitoring/ServiceWatchdog)'

# Spec 4.3 defaults, used for the execution-limit check when the config omits the keys.
$script:DefaultMaxRunSeconds = 240
$script:DefaultWebhookTimeoutSeconds = 30

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $InstallPath $script:ConfigFileName
}

# Product-named log root; see .NOTES deviation 4.6.
if (-not $LogPath) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
    $logRoot = Join-Path (Join-Path $env:ProgramData 'ServiceWatchdog') 'Logs'
    $LogPath = Join-Path $logRoot "$scriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}
$script:LogPath = $LogPath

try {
    $logDir = Split-Path -Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
}
catch {
    Write-Warning "Could not create log directory for '$($script:LogPath)': $_. Continuing without file logging."
    $script:LogPath = $null
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
            Add-Content -LiteralPath $script:LogPath -Value $logMessage
        }
        catch {
            Write-Warning "Failed to write to log file '$($script:LogPath)': $_"
        }
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

function Invoke-WatchdogWorker {
    # Runs the worker as an external Windows PowerShell process, the same way the scheduled
    # task will, and returns its exit code. Tests mock this function; the installer relies
    # only on the documented contract (-ValidateConfig exits 0 or 2, -TestAlert 0/10/2).
    param (
        [Parameter(Mandatory)]
        [string]$WorkerPath,

        [string[]]$Arguments = @()
    )

    $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $WorkerPath @Arguments
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output | Where-Object { $null -ne $_ })) {
        Write-Log "  worker> $line" -Level 'INFO'
    }
    return $exitCode
}

function Test-WatchdogEventSource {
    # Wrapped so tests can mock it: the .NET call is Windows-only.
    param (
        [Parameter(Mandatory)]
        [string]$Source
    )

    return [System.Diagnostics.EventLog]::SourceExists($Source)
}

function Add-WatchdogEventSource {
    # Wrapped so tests can mock it. The .NET call is what New-EventLog wraps, but unlike the
    # cmdlet it exists in both Windows PowerShell 5.1 and PowerShell 7 on Windows.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Called only inside Invoke-Action, which is the -DryRun gate; the script has no -WhatIf.'
    )]
    param (
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$LogName
    )

    [System.Diagnostics.EventLog]::CreateEventSource($Source, $LogName)
}

function Test-WatchdogPathInside {
    # True when Path is Container itself or anywhere below it. Both are normalized through
    # the provider so relative paths and mixed separators compare correctly on 5.1 and 7.
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Container
    )

    $pathProvider = $ExecutionContext.SessionState.Path
    $fullPath = $pathProvider.GetUnresolvedProviderPathFromPSPath($Path).TrimEnd('\', '/')
    $fullContainer = $pathProvider.GetUnresolvedProviderPathFromPSPath($Container).TrimEnd('\', '/')
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    if ($fullPath.Equals($fullContainer, $comparison)) {
        return $true
    }
    $prefix = $fullContainer + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, $comparison)
}

function Set-WatchdogInstallAcl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Called only inside Invoke-Action, which is the -DryRun gate; the script has no -WhatIf.'
    )]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Well-known SIDs for SYSTEM and Administrators keep the call locale-safe.
    $systemGrant = "*$($script:SystemSid):(OI)(CI)F"
    $administratorsGrant = "*$($script:AdministratorsSid):(OI)(CI)F"
    $output = & icacls $Path /inheritance:r /grant:r $systemGrant $administratorsGrant
    $exitCode = $LASTEXITCODE
    foreach ($line in @($output | Where-Object { $null -ne $_ })) {
        Write-Log "  icacls> $line" -Level 'DEBUG'
    }
    if ($exitCode -ne 0) {
        throw "icacls exited with code $exitCode while setting the ACL on '$Path'."
    }
}

function Get-WatchdogConfigValue {
    # Reads a nested integer from the parsed config, falling back to the spec default when
    # the key is absent. Works on the PSCustomObject that ConvertFrom-Json returns on 5.1.
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Config,

        [Parameter(Mandatory)]
        [string[]]$KeyPath,

        [Parameter(Mandatory)]
        [int]$Default
    )

    $current = $Config
    foreach ($key in $KeyPath) {
        if ($null -eq $current -or -not $current.PSObject.Properties[$key]) {
            return $Default
        }
        $current = $current.$key
    }
    if ($null -eq $current) {
        return $Default
    }
    return [int]$current
}

#endregion

#region Main Functions

function Install-WatchdogContent {
    # Step 1. Returns 0 to continue or 2 when the operator has to act first.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$InstallPath,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [switch]$Force
    )

    $sourceWorker = Join-Path $SourcePath $script:WorkerFileName
    $installedWorker = Join-Path $InstallPath $script:WorkerFileName
    $exampleConfig = Join-Path $SourcePath $script:ExampleConfigFileName

    if (-not (Test-Path -LiteralPath $sourceWorker -PathType Leaf)) {
        Write-Log ("Worker script '$($script:WorkerFileName)' not found in '$SourcePath'. " +
            'Use -SourcePath to point at the folder that contains it.') -Level 'ERROR'
        return 2
    }

    if ((Test-Path -LiteralPath $installedWorker -PathType Leaf) -and -not $Force) {
        Write-Log "Worker already present at '$installedWorker'. Re-run with -Force to overwrite it." -Level 'ERROR'
        return 2
    }

    $configExists = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    if (-not $configExists -and -not (Test-Path -LiteralPath $exampleConfig -PathType Leaf)) {
        Write-Log ("No config at '$ConfigPath' and no '$($script:ExampleConfigFileName)' in '$SourcePath' " +
            'to copy from.') -Level 'ERROR'
        return 2
    }

    if (-not $configExists) {
        # Nothing else is touched until a real config exists, so a first run leaves only the
        # example config behind for the operator to edit.
        Invoke-Action -Description "Copy example config to '$ConfigPath'" -Action {
            $configDir = Split-Path -Path $ConfigPath -Parent
            if ($configDir -and -not (Test-Path -LiteralPath $configDir)) {
                New-Item -Path $configDir -ItemType Directory -Force | Out-Null
            }
            Copy-Item -LiteralPath $exampleConfig -Destination $ConfigPath
        }
        Write-Log ("Config file created at '$ConfigPath'. Edit it (Services, Webhook.Url, Webhook.FunctionKey) " +
            'and re-run this script.') -Level 'ERROR'
        return 2
    }

    if (-not (Test-Path -LiteralPath $InstallPath -PathType Container)) {
        Invoke-Action -Description "Create install folder '$InstallPath'" -Action {
            New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
        }
    }

    Invoke-Action -Description "Copy worker '$sourceWorker' to '$installedWorker'" -Action {
        Copy-Item -LiteralPath $sourceWorker -Destination $installedWorker -Force
    }

    return 0
}

function Test-WatchdogInstallConfig {
    # Step 3. Returns 0 when the config is valid and the execution limit covers the
    # worst-case run, 2 otherwise.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$WorkerPath,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [int]$ExecutionTimeLimitSeconds
    )

    Write-Log "Validating '$ConfigPath' with the worker" -Level 'INFO'
    $validateArguments = @('-ValidateConfig', '-ConfigPath', $ConfigPath)
    $validateExit = Invoke-WatchdogWorker -WorkerPath $WorkerPath -Arguments $validateArguments
    if ($validateExit -ne 0) {
        Write-Log ("Config validation failed (worker exit code $validateExit). " +
            "Fix '$ConfigPath' and re-run.") -Level 'ERROR'
        return 2
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $maxRunSeconds = Get-WatchdogConfigValue -Config $config -KeyPath @('MaxRunSeconds') `
        -Default $script:DefaultMaxRunSeconds
    $timeoutSeconds = Get-WatchdogConfigValue -Config $config -KeyPath @('Webhook', 'TimeoutSeconds') `
        -Default $script:DefaultWebhookTimeoutSeconds

    # Spec 4.3: two webhook calls with one retry each, plus startup.
    $worstCaseSeconds = $maxRunSeconds + 2 * (2 * $timeoutSeconds + 5) + 15
    if ($ExecutionTimeLimitSeconds -lt $worstCaseSeconds) {
        Write-Log ("-ExecutionTimeLimitSeconds $ExecutionTimeLimitSeconds is below the worst-case run time of " +
            "$worstCaseSeconds seconds (MaxRunSeconds $maxRunSeconds, Webhook.TimeoutSeconds $timeoutSeconds). " +
            'Raise it or lower the config values.') -Level 'ERROR'
        return 2
    }

    Write-Log "Config valid; worst-case run $worstCaseSeconds s fits the $ExecutionTimeLimitSeconds s limit" `
        -Level 'INFO'
    return 0
}

function Register-WatchdogEventSource {
    # Step 4.
    [CmdletBinding()]
    param ()

    if (Test-WatchdogEventSource -Source $script:EventSourceName) {
        Write-Log "Event source '$($script:EventSourceName)' already registered" -Level 'INFO'
        return
    }

    $stepDescription = "Register event source '$($script:EventSourceName)' in the $($script:EventLogName) log"
    Invoke-Action -Description $stepDescription -Action {
        Add-WatchdogEventSource -Source $script:EventSourceName -LogName $script:EventLogName
    }
}

function Register-WatchdogTask {
    # Step 5. Builds the principal, triggers, settings and action, then registers the task.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$TaskName,

        [Parameter(Mandatory)]
        [string]$WorkerPath,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [int]$IntervalMinutes,

        [Parameter(Mandatory)]
        [int]$StartupDelayMinutes,

        [Parameter(Mandatory)]
        [int]$ExecutionTimeLimitSeconds
    )

    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest

    # The cmdlet exposes repetition only on its -Once parameter set, so build a throwaway
    # -Once trigger and copy its Repetition onto the daily trigger.
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At '00:00'
    $onceTrigger = New-ScheduledTaskTrigger -Once -At '00:00' `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 1)
    $dailyTrigger.Repetition = $onceTrigger.Repetition

    # -AtStartup offers only -RandomDelay; a fixed delay is set on the trigger object.
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $bootTrigger.Delay = "PT${StartupDelayMinutes}M"

    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Seconds $ExecutionTimeLimitSeconds) `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    # No secrets in the arguments: the worker reads its config beside itself. -ConfigPath is
    # added only when the operator gave the config a different name (the entry point has
    # already refused any folder other than InstallPath).
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WorkerPath`""
    $defaultConfigPath = Join-Path (Split-Path -Path $WorkerPath -Parent) $script:ConfigFileName
    if ($ConfigPath -ne $defaultConfigPath) {
        $arguments += " -ConfigPath `"$ConfigPath`""
    }
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

    $taskDescription = "ServiceWatchdog $($script:ScriptVersion) from $($script:RepositoryName): starts stopped " +
        "services every $IntervalMinutes minutes and $StartupDelayMinutes minutes after boot, and reports to IT."

    # Built outside the Invoke-Action block: a block runs as a child of Invoke-Action's scope,
    # where $Action and $Description already mean something else.
    $registerArgs = @{
        TaskName    = $TaskName
        Action      = $taskAction
        Trigger     = @($dailyTrigger, $bootTrigger)
        Principal   = $principal
        Settings    = $settings
        Description = $taskDescription
        Force       = $true
    }
    $stepDescription = "Register scheduled task '$TaskName' (SYSTEM, every $IntervalMinutes min, " +
        "boot +$StartupDelayMinutes min)"
    Invoke-Action -Description $stepDescription -Action {
        Register-ScheduledTask @registerArgs | Out-Null
    }
}

function Set-WatchdogServiceRecovery {
    # Step 6. Returns the number of services whose SCM failure actions could not be set.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Every sc.exe call is inside Invoke-Action, the -DryRun gate; the script has no -WhatIf.'
    )]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $services = @()
    if ($config.PSObject.Properties['Services']) {
        $services = @($config.Services | Where-Object { $_ })
    }
    if ($services.Count -eq 0) {
        Write-Log "No services listed in '$ConfigPath'; nothing to set recovery actions on" -Level 'WARNING'
        return 0
    }

    $failed = 0
    foreach ($service in $services) {
        $serviceName = [string]$service
        try {
            Invoke-Action -Description "Set SCM failure actions on service '$serviceName'" -Action {
                $output = & sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/120000/none/0
                $exitCode = $LASTEXITCODE
                foreach ($line in @($output | Where-Object { $null -ne $_ })) {
                    Write-Log "  sc> $line" -Level 'DEBUG'
                }
                if ($exitCode -ne 0) {
                    throw "sc.exe failure '$serviceName' exited with code $exitCode."
                }
            }
        }
        catch {
            # Already logged by Invoke-Action; keep going so one missing service does not
            # block recovery on the others.
            $failed++
        }
    }
    return $failed
}

function Write-WatchdogSummary {
    # Step 8.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$InstallPath,

        [Parameter(Mandatory)]
        [string]$TaskName,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $nextRun = 'n/a (dry run)'
    if (-not $script:DryRun) {
        try {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName
            $nextRun = [string]$info.NextRunTime
        }
        catch {
            $nextRun = "unknown ($_)"
        }
    }

    Write-Log "Install path: $InstallPath" -Level 'SUCCESS'
    Write-Log "Task name:    $TaskName (next run $nextRun)" -Level 'SUCCESS'
    Write-Log "Config path:  $ConfigPath" -Level 'SUCCESS'
    Write-Log "Log path:     $($script:LogPath)" -Level 'SUCCESS'
}

function Invoke-WatchdogRegistration {
    # Entry point. Returns the process exit code; the script body passes it to exit.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$InstallPath,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$TaskName,

        [Parameter(Mandatory)]
        [int]$IntervalMinutes,

        [Parameter(Mandatory)]
        [int]$StartupDelayMinutes,

        [Parameter(Mandatory)]
        [int]$ExecutionTimeLimitSeconds,

        [switch]$SetServiceRecovery,

        [switch]$RunNow,

        [switch]$TestAlert,

        [switch]$Force,

        [switch]$DryRun
    )

    $script:DryRun = $DryRun.IsPresent
    $startTime = Get-Date

    try {
        Write-Log "Script started (version $($script:ScriptVersion))" -Level 'INFO'
        Write-Log "Log file: $($script:LogPath)" -Level 'INFO'
        Write-Log ("Parameters: InstallPath=$InstallPath, SourcePath=$SourcePath, ConfigPath=$ConfigPath, " +
            "TaskName=$TaskName, IntervalMinutes=$IntervalMinutes, StartupDelayMinutes=$StartupDelayMinutes, " +
            "ExecutionTimeLimitSeconds=$ExecutionTimeLimitSeconds, SetServiceRecovery=$SetServiceRecovery, " +
            "RunNow=$RunNow, TestAlert=$TestAlert, Force=$Force, DryRun=$DryRun") -Level 'INFO'
        if ($script:DryRun) {
            Write-Log '*** DRYRUN MODE - No changes will be made ***' -Level 'WARNING'
        }

        # Only InstallPath receives the step 2 ACL, and the worker writes its state file
        # beside the config, so a config anywhere else would leave the function key under
        # whatever DACL that folder inherits. Refused before anything is created.
        $configFolder = Split-Path -Path $ConfigPath -Parent
        if (-not $configFolder -or -not (Test-WatchdogPathInside -Path $configFolder -Container $InstallPath)) {
            Write-Log ("-ConfigPath '$ConfigPath' is outside the install folder '$InstallPath', which is the only " +
                'folder this script protects. Place the config inside InstallPath (any file name) and re-run.') `
                -Level 'ERROR'
            return 2
        }

        $fileExit = Install-WatchdogContent -InstallPath $InstallPath -SourcePath $SourcePath `
            -ConfigPath $ConfigPath -Force:$Force
        if ($fileExit -ne 0) {
            return $fileExit
        }

        Invoke-Action -Description "Restrict '$InstallPath' to SYSTEM and Administrators" -Action {
            Set-WatchdogInstallAcl -Path $InstallPath
        }

        # Under -DryRun the worker was not copied, so validate with the source copy instead;
        # the two files are identical.
        $workerPath = Join-Path $InstallPath $script:WorkerFileName
        $validationWorker = $workerPath
        if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) {
            $validationWorker = Join-Path $SourcePath $script:WorkerFileName
        }
        $configExit = Test-WatchdogInstallConfig -WorkerPath $validationWorker -ConfigPath $ConfigPath `
            -ExecutionTimeLimitSeconds $ExecutionTimeLimitSeconds
        if ($configExit -ne 0) {
            return $configExit
        }

        Register-WatchdogEventSource

        Register-WatchdogTask -TaskName $TaskName -WorkerPath $workerPath -ConfigPath $ConfigPath `
            -IntervalMinutes $IntervalMinutes -StartupDelayMinutes $StartupDelayMinutes `
            -ExecutionTimeLimitSeconds $ExecutionTimeLimitSeconds

        $exitCode = 0
        if ($SetServiceRecovery) {
            $recoveryFailures = Set-WatchdogServiceRecovery -ConfigPath $ConfigPath
            if ($recoveryFailures -gt 0) {
                Write-Log ("Task registered, but SCM failure actions could not be set on $recoveryFailures " +
                    'service(s); see the log') -Level 'ERROR'
                $exitCode = 50
            }
        }

        if ($RunNow) {
            Invoke-Action -Description "Start scheduled task '$TaskName'" -Action {
                Start-ScheduledTask -TaskName $TaskName
            }
        }

        if ($TestAlert) {
            # Invoke-Action returns the action's output, so $testExit stays null under -DryRun.
            $testExit = Invoke-Action -Description 'Send a test alert through the worker' -Action {
                Invoke-WatchdogWorker -WorkerPath $workerPath -Arguments @('-TestAlert', '-ConfigPath', $ConfigPath)
            }
            if ($null -ne $testExit -and $testExit -ne 0) {
                Write-Log ("The test alert was not delivered (worker exit code $testExit). The task is registered; " +
                    "check the webhook settings in '$ConfigPath' and the worker log.") -Level 'ERROR'
                if ($exitCode -eq 0) {
                    $exitCode = 10
                }
            }
            elseif ($null -ne $testExit) {
                Write-Log 'Test alert delivered' -Level 'SUCCESS'
            }
        }

        Write-WatchdogSummary -InstallPath $InstallPath -TaskName $TaskName -ConfigPath $ConfigPath
        if ($exitCode -eq 0) {
            Write-Log 'ServiceWatchdog registration completed successfully' -Level 'SUCCESS'
        }
        return $exitCode
    }
    catch {
        Write-Log "Script failed: $_" -Level 'ERROR'
        Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
        return 1
    }
    finally {
        $duration = (Get-Date) - $startTime
        Write-Log "Total duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Level 'INFO'
    }
}

#endregion

#region Script Body

# Guarded so tests can dot-source the functions without running the installer.
if ($MyInvocation.InvocationName -ne '.') {
    $registrationArgs = @{
        InstallPath               = $InstallPath
        SourcePath                = $SourcePath
        ConfigPath                = $ConfigPath
        TaskName                  = $TaskName
        IntervalMinutes           = $IntervalMinutes
        StartupDelayMinutes       = $StartupDelayMinutes
        ExecutionTimeLimitSeconds = $ExecutionTimeLimitSeconds
        SetServiceRecovery        = $SetServiceRecovery
        RunNow                    = $RunNow
        TestAlert                 = $TestAlert
        Force                     = $Force
        DryRun                    = $DryRun
    }
    exit (Invoke-WatchdogRegistration @registrationArgs)
}

#endregion
