#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Removes the ServiceWatchdog scheduled task and, optionally, its event source and files.

.DESCRIPTION
    Windows-only. Runs elevated on a server where Register-WinServiceWatchdogTask.ps1 was
    used and reverses it:

      1. Unregisters the scheduled task if it exists. A task that is already absent is not
         an error; the script reports it and exits 0.
      2. With -RemoveEventSource, removes the ServiceWatchdog event log source through
         System.Diagnostics.EventLog, so the step works from both powershell.exe and pwsh
         (Remove-EventLog exists only in Windows PowerShell). Events already written to the
         Application log stay readable.
      3. With -RemoveFiles, deletes the install folder including the worker, the config
         file (which holds the function key), the state file and the logs. This step asks
         for confirmation because it is destructive; -Force or -Confirm:$false skips the
         prompt so unattended runs never block. A filesystem root or a Windows system
         folder is refused with exit 2.

    Service Control Manager failure actions set by the installer's -SetServiceRecovery are
    left in place; they are harmless without the watchdog.

    Every mutation goes through Invoke-Action, so -DryRun logs each step with a [DRYRUN]
    prefix and changes nothing. -WhatIf behaves the same way.

.PARAMETER TaskName
    Task name in the root Task Scheduler folder. Defaults to ServiceWatchdog.

.PARAMETER InstallPath
    Folder the installer created. Only used with -RemoveFiles.
    Defaults to $env:ProgramData\ServiceWatchdog.

.PARAMETER RemoveEventSource
    Also remove the ServiceWatchdog event log source.

.PARAMETER RemoveFiles
    Also delete the install folder with the worker, config, state and logs. Prompts for
    confirmation unless -Force or -Confirm:$false is given.

.PARAMETER Force
    Skip the -RemoveFiles confirmation prompt.

.PARAMETER Verbosity
    Controls console output level. Valid values: Low, Medium, High.
    Low shows only errors and success. Medium adds warnings. High shows everything.
    The log file always receives every message.

.PARAMETER DryRun
    Simulates all actions without making changes. Logs what would happen with a [DRYRUN]
    prefix.

.PARAMETER LogPath
    Path to the log file. Defaults to
    $env:ProgramData\ServiceWatchdog\Logs\Unregister-WinServiceWatchdogTask-<timestamp>.log.
    When -RemoveFiles deletes the folder that holds this file, the remaining messages go to
    the console only.

.EXAMPLE
    .\Unregister-WinServiceWatchdogTask.ps1

    Removes the scheduled task and leaves the event source and files in place, so the
    watchdog can be re-registered later without editing the config again.

.EXAMPLE
    .\Unregister-WinServiceWatchdogTask.ps1 -RemoveEventSource -RemoveFiles -Force

    Complete unattended removal: task, event source and the whole install folder.

.EXAMPLE
    .\Unregister-WinServiceWatchdogTask.ps1 -RemoveFiles -DryRun -Verbosity High

    Lists every step a full removal would perform without touching the server.

.NOTES
    Version:    1.0.0
    Created:    2026-09-04
    Platform:   Windows Server 2016 or later, Windows PowerShell 5.1 or PowerShell 7,
                elevated. #Requires -RunAsAdministrator stops the script before it runs when
                not elevated; the host reports exit 1 in that case.
    Exit codes: 0 success (including task already absent); 1 unexpected error;
                2 invalid parameters (for example -RemoveFiles on a protected folder).

    Checklist deviations from the powershell-authoring skill (Enterprise tier), per
    DESIGN.md section 4.1:
      - 3.1: targets Windows PowerShell 5.1 because Windows Server ships only 5.1; no
        PowerShell 7-only syntax is used.
      - 4.6: log root is $env:ProgramData\ServiceWatchdog\Logs (product-named) rather than
        $env:ProgramData\$MSPName\Logs, because the tool is deployed by end-client IT and
        the project is MSP-name-agnostic throughout.
      - 5.2: not applicable; this script handles no secrets. It only deletes the config
        file that holds one, and never reads it.
      - 5.7: ships unsigned in the public repository; adopters sign with their own
        certificate.
      - 6.6: the integration test is the operator acceptance run documented in the README.
      - 6.7: not applicable; the script runs once at removal time.

    Developed with AI assistance (Claude); reviewed before publication.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [ValidatePattern('^[^\\/]+$')]
    [string]$TaskName = 'ServiceWatchdog',

    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = (Join-Path $env:ProgramData 'ServiceWatchdog'),

    [switch]$RemoveEventSource,

    [switch]$RemoveFiles,

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
$script:EventSourceName = 'ServiceWatchdog'

# Product-named log root; see .NOTES deviation 4.6.
if (-not $LogPath) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
    $logRoot = Join-Path (Join-Path $env:ProgramData 'ServiceWatchdog') 'Logs'
    $LogPath = Join-Path $logRoot "$scriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}
$script:LogPath = $LogPath

try {
    # -WhatIf:$false / -Confirm:$false: the log is bookkeeping, not one of the operations
    # the operator is confirming or previewing.
    $logDir = Split-Path -Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force -WhatIf:$false -Confirm:$false | Out-Null
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
            Add-Content -LiteralPath $script:LogPath -Value $logMessage -WhatIf:$false -Confirm:$false
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

function Test-WatchdogEventSource {
    # Wrapped so tests can mock it: the .NET call is Windows-only.
    param (
        [Parameter(Mandatory)]
        [string]$Source
    )

    return [System.Diagnostics.EventLog]::SourceExists($Source)
}

function Remove-WatchdogEventSource {
    # Wrapped so tests can mock it. The .NET call is what Remove-EventLog -Source wraps, but
    # unlike the cmdlet it exists in both Windows PowerShell 5.1 and PowerShell 7 on Windows.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Called only inside Invoke-Action, which honors -DryRun and -WhatIf for the whole run.'
    )]
    param (
        [Parameter(Mandatory)]
        [string]$Source
    )

    [System.Diagnostics.EventLog]::DeleteEventSource($Source)
}

function Test-WatchdogProtectedPath {
    # True for a filesystem root or a Windows system folder, which -RemoveFiles must never
    # delete even when an operator mistypes -InstallPath.
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $trimmed = $Path.TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ($null -ne $root -and $trimmed -eq $root.TrimEnd('\', '/')) {
        return $true
    }

    $protected = @($env:ProgramData, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemDrive)
    foreach ($candidate in $protected) {
        if ($candidate -and $trimmed -eq $candidate.TrimEnd('\', '/')) {
            return $true
        }
    }
    return $false
}

#endregion

#region Main Functions

function Remove-WatchdogTask {
    # Step 1.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Gated by Invoke-Action (-DryRun, -WhatIf); the task removal carries no confirmation by design.'
    )]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$TaskName
    )

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Log "Scheduled task '$TaskName' is not registered; nothing to remove" -Level 'SUCCESS'
        return
    }

    Invoke-Action -Description "Unregister scheduled task '$TaskName'" -Action {
        # The cmdlet prompts on its own; the script's confirmation applies to -RemoveFiles only.
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function Unregister-WatchdogEventSource {
    # Step 2.
    [CmdletBinding()]
    param ()

    if (-not (Test-WatchdogEventSource -Source $script:EventSourceName)) {
        Write-Log "Event source '$($script:EventSourceName)' is not registered; nothing to remove" -Level 'INFO'
        return
    }

    Invoke-Action -Description "Remove event source '$($script:EventSourceName)'" -Action {
        Remove-WatchdogEventSource -Source $script:EventSourceName
    }
}

function Remove-WatchdogInstallFolder {
    # Step 3. The caller has already passed ShouldProcess.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'The entry point evaluates ShouldProcess before calling this; Invoke-Action gates -DryRun.'
    )]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$InstallPath
    )

    # The default log file lives inside the folder about to be removed; keep the run going
    # on the console rather than failing every later Write-Log.
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $folderPrefix = $InstallPath.TrimEnd('\', '/') + $separator
    if ($script:LogPath -and $script:LogPath.StartsWith($folderPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Log "Log file '$($script:LogPath)' is inside the install folder; remaining output goes to the console" `
            -Level 'WARNING'
        $script:LogPath = $null
    }

    Invoke-Action -Description "Remove install folder '$InstallPath' (worker, config, state, logs)" -Action {
        Remove-Item -LiteralPath $InstallPath -Recurse -Force
    }
}

function Invoke-WatchdogUnregistration {
    # Entry point. Returns the process exit code; the script body passes it to exit.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory)]
        [string]$TaskName,

        [Parameter(Mandatory)]
        [string]$InstallPath,

        [switch]$RemoveEventSource,

        [switch]$RemoveFiles,

        [switch]$Force,

        [switch]$DryRun
    )

    if ($Force) {
        $ConfirmPreference = 'None'
    }
    # -WhatIf is honored the same way as -DryRun: every step is logged and nothing changes.
    $script:DryRun = $DryRun.IsPresent -or $WhatIfPreference
    $startTime = Get-Date

    try {
        Write-Log "Script started (version $($script:ScriptVersion))" -Level 'INFO'
        Write-Log "Log file: $($script:LogPath)" -Level 'INFO'
        Write-Log ("Parameters: TaskName=$TaskName, InstallPath=$InstallPath, RemoveEventSource=$RemoveEventSource, " +
            "RemoveFiles=$RemoveFiles, Force=$Force, DryRun=$($script:DryRun)") -Level 'INFO'
        if ($script:DryRun) {
            Write-Log '*** DRYRUN MODE - No changes will be made ***' -Level 'WARNING'
        }

        if ($RemoveFiles -and (Test-WatchdogProtectedPath -Path $InstallPath)) {
            Write-Log "Refusing to remove '$InstallPath': it is a filesystem root or a Windows system folder" `
                -Level 'ERROR'
            return 2
        }

        Remove-WatchdogTask -TaskName $TaskName

        if ($RemoveEventSource) {
            Unregister-WatchdogEventSource
        }

        if ($RemoveFiles) {
            if (-not (Test-Path -LiteralPath $InstallPath -PathType Container)) {
                Write-Log "Install folder '$InstallPath' not found; nothing to remove" -Level 'INFO'
            }
            elseif ($script:DryRun) {
                Write-Log "[DRYRUN] Would execute: Remove install folder '$InstallPath' (worker, config, state, logs)" `
                    -Level 'INFO'
            }
            elseif ($PSCmdlet.ShouldProcess($InstallPath, 'Remove install folder including config, state and logs')) {
                Remove-WatchdogInstallFolder -InstallPath $InstallPath
            }
            else {
                Write-Log "Install folder '$InstallPath' kept: removal declined at the prompt" -Level 'WARNING'
            }
        }

        Write-Log 'ServiceWatchdog removal completed successfully' -Level 'SUCCESS'
        return 0
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

# Guarded so tests can dot-source the functions without running the uninstaller.
if ($MyInvocation.InvocationName -ne '.') {
    $unregistrationArgs = @{
        TaskName          = $TaskName
        InstallPath       = $InstallPath
        RemoveEventSource = $RemoveEventSource
        RemoveFiles       = $RemoveFiles
        Force             = $Force
        DryRun            = $DryRun
    }
    exit (Invoke-WatchdogUnregistration @unregistrationArgs)
}

#endregion
