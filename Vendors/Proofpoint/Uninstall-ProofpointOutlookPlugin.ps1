#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Silently uninstalls the Proofpoint Encryption Plug-in for Microsoft Outlook.

.DESCRIPTION
    Detect-first removal of the Proofpoint Outlook plug-in, safe to run on a schedule.

    1. Searches the 64-bit and 32-bit HKLM uninstall registry hives for any product whose
       DisplayName matches -NameFilter (default "*Proofpoint*").
    2. If nothing matches, exits 0 immediately. Outlook is NOT touched - this makes the script
       safe to attach to a recurring RMM policy without disrupting users on clean machines.
    3. Only when a match is found does it close Outlook (Proofpoint requires this before
       install/uninstall). It asks Outlook to close gracefully first and only force-kills after
       -OutlookCloseTimeoutSeconds elapse.
    4. Runs each match's uninstaller silently. MSI products are normalized to
       "msiexec /x {ProductCode} /qn /norestart"; EXE uninstallers get a silent switch appended
       if the vendor string doesn't already carry one.
    5. Re-scans the registry to confirm removal and sets the exit code accordingly.

    No product GUID is hardcoded, so it keeps working across plug-in builds/versions.

    Windows-only. Intended to run as SYSTEM via an RMM (e.g. NinjaOne).

    Exit codes:
        0 = nothing to do, or removal confirmed (a 3010 from msiexec still counts as success;
            a reboot-pending WARNING is logged)
        1 = product still present after uninstall, or an uninstall step failed

.PARAMETER NameFilter
    Wildcard matched against DisplayName in the uninstall registry. Default "*Proofpoint*".
    Tighten it (e.g. "*Proofpoint Encryption Plug-in*") if other Proofpoint products are
    installed and must be left alone.

.PARAMETER OutlookCloseTimeoutSeconds
    How long to wait for Outlook to close gracefully before force-terminating it. Default 30.

.PARAMETER Verbosity
    Controls console output level. Valid values: Low, Medium, High.
    Low shows only errors and success. Medium adds warnings. High shows everything.
    The log file always receives everything.

.PARAMETER DryRun
    Runs detection and reports what would happen without closing Outlook or running any
    uninstaller. Use this first on a pilot device to see exactly which registry entries match.

.PARAMETER LogPath
    Path to the log file. Defaults to $env:ProgramData\$MSPName\Logs\<scriptname>-<timestamp>.log.

.EXAMPLE
    .\Uninstall-ProofpointOutlookPlugin.ps1
    # Standard unattended run - detect, close Outlook only if needed, uninstall, verify.

.EXAMPLE
    .\Uninstall-ProofpointOutlookPlugin.ps1 -DryRun -Verbosity High
    # Show every matching product and every action that would be taken. No changes made.

.EXAMPLE
    .\Uninstall-ProofpointOutlookPlugin.ps1 -NameFilter "*Proofpoint Encryption Plug-in*"
    # Narrow the match when other Proofpoint software must stay installed.

.NOTES
    Author:     Ramon DeWitt
    Version:    1.0.0
    Created:    2026-08-17
    AI Assist:  Claude Code
    Requires:   Windows PowerShell 5.1+, elevated (SYSTEM or local admin).
#>

[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [string]$NameFilter = '*Proofpoint*',

    [ValidateRange(0, 600)]
    [int]$OutlookCloseTimeoutSeconds = 30,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Low',

    [switch]$DryRun,

    [string]$LogPath
)

#region Configuration & Constants

$MSPName = "YourMSPName"   # <-- Replace with your MSP name (e.g. 'SentinelCyber')

$ErrorActionPreference = 'Stop'
$script:Verbosity = $Verbosity
$script:DryRun    = [bool]$DryRun
$scriptStartTime  = Get-Date

# HKLM only: the plug-in is a per-machine install and this script runs as SYSTEM, which cannot
# see or uninstall per-user (HKCU) products anyway.
$uninstallKeyPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# msiexec exit codes that mean the product is gone.
$msiSuccessCodes = @(0, 1605, 3010)   # 1605 = not installed, 3010 = success + reboot required

# Derive log path from central location if not explicitly provided.
# PS 5.1 Join-Path only accepts two segments, hence the nested call.
if (-not $LogPath) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
    $logRoot    = Join-Path (Join-Path $env:ProgramData $MSPName) 'Logs'
    $LogPath    = Join-Path $logRoot "$scriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}
$script:LogPath = $LogPath

$logDir = Split-Path -Path $script:LogPath -Parent
if (-not (Test-Path $logDir)) {
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

    $timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logMessage = "[$timestamp] [$Level] $Message"

    $writeToConsole = switch ($script:Verbosity) {
        'Low'    { $Level -in 'ERROR', 'SUCCESS' }
        'Medium' { $Level -in 'ERROR', 'WARNING', 'SUCCESS' }
        default  { $true }
    }

    if ($writeToConsole) {
        $color = switch ($Level) {
            'ERROR'   { 'Red' }
            'WARNING' { 'Yellow' }
            'SUCCESS' { 'Green' }
            'DEBUG'   { 'Cyan' }
            default   { 'White' }
        }
        Write-Host $logMessage -ForegroundColor $color
    }

    if ($script:LogPath) {
        try { Add-Content -Path $script:LogPath -Value $logMessage -ErrorAction Stop }
        catch { Write-Host "Failed to write to log file: $_" -ForegroundColor Yellow }
    }
}

function Invoke-Action {
    <#
        DryRun-aware wrapper. Every mutation (closing Outlook, running an uninstaller)
        goes through here so -DryRun guarantees zero changes on the endpoint.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if ($script:DryRun) {
        Write-Log "[DRYRUN] Would execute: $Description" -Level 'INFO'
        return $null
    }

    Write-Log "Executing: $Description" -Level 'INFO'
    try {
        return (& $Action)
    }
    catch {
        Write-Log "Failed: $Description - $_" -Level 'ERROR'
        throw
    }
}

#endregion

#region Main Functions

function Get-MatchingInstalledProduct {
    <#
        Returns uninstall-registry entries whose DisplayName matches the filter.
        Filter left: Where-Object runs directly on the registry read.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Filter
    )

    return @(
        Get-ItemProperty -Path $uninstallKeyPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $Filter }
    )
}

function Close-OutlookIfRunning {
    <#
        Only called once a matching product has been found. Tries a graceful close first
        so Outlook can flush its data files; force-kills only after the timeout.
    #>
    param (
        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $outlookProcesses = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
    if ($outlookProcesses.Count -eq 0) {
        Write-Log 'Outlook is not running - no need to close it.' -Level 'INFO'
        return
    }

    Write-Log "Outlook is running ($($outlookProcesses.Count) process(es)). It must be closed before the plug-in can be removed." -Level 'WARNING'

    Invoke-Action -Description "Close Outlook (graceful, then force after $TimeoutSeconds s)" -Action {
        foreach ($proc in $outlookProcesses) {
            # CloseMainWindow returns $false when there is no window to signal (e.g. running
            # in a different session than SYSTEM) - that's fine, we fall through to Stop-Process.
            try { $null = $proc.CloseMainWindow() }
            catch { Write-Log "  CloseMainWindow failed for PID $($proc.Id): $_ (will force-stop if still running)" -Level 'DEBUG' }
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Seconds 2
        }

        $remaining = @(Get-Process -Name 'OUTLOOK' -ErrorAction SilentlyContinue)
        if ($remaining.Count -gt 0) {
            Write-Log 'Outlook did not close gracefully - force-terminating.' -Level 'WARNING'
            $remaining | Stop-Process -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
        }
        else {
            Write-Log 'Outlook closed gracefully.' -Level 'INFO'
        }
    } | Out-Null
}

function Get-UninstallCommand {
    <#
        Turns a raw UninstallString into a normalized (FilePath, ArgumentList, IsMsi) triple.
        Returns $null when the string cannot be parsed safely.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$UninstallString
    )

    if ($UninstallString -match 'msiexec') {
        if ($UninstallString -match '\{[0-9A-Fa-f\-]{36}\}') {
            return [pscustomobject]@{
                FilePath     = 'msiexec.exe'
                ArgumentList = "/x $($Matches[0]) /qn /norestart"
                IsMsi        = $true
            }
        }
        return $null
    }

    # EXE-based uninstaller: separate the executable from any vendor-supplied arguments.
    if ($UninstallString -match '^"([^"]+)"\s*(.*)$') {
        $exePath      = $Matches[1]
        $existingArgs = $Matches[2]
    }
    else {
        $parts        = $UninstallString -split ' ', 2
        $exePath      = $parts[0]
        $existingArgs = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    }

    if ($existingArgs -notmatch '/S\b|/silent|/quiet|/qn|/verysilent') {
        $existingArgs = "$existingArgs /S /norestart".Trim()
    }

    return [pscustomobject]@{
        FilePath     = $exePath
        ArgumentList = $existingArgs
        IsMsi        = $false
    }
}

function Uninstall-Product {
    <#
        Runs the uninstaller for one registry entry. Returns $true on success, $false on failure.
        Never throws - the caller aggregates results and decides the exit code.
    #>
    param (
        [Parameter(Mandatory)]
        $Product
    )

    $displayName     = $Product.DisplayName
    $uninstallString = $Product.UninstallString

    if ([string]::IsNullOrWhiteSpace($uninstallString)) {
        Write-Log "'$displayName' has no UninstallString - skipping (registry key: $($Product.PSChildName))." -Level 'WARNING'
        return $false
    }

    $command = Get-UninstallCommand -UninstallString $uninstallString
    if (-not $command) {
        Write-Log "Could not parse an uninstall command for '$displayName' from: $uninstallString" -Level 'ERROR'
        return $false
    }

    if (-not $command.IsMsi -and -not (Test-Path -LiteralPath $command.FilePath)) {
        Write-Log "Uninstaller executable not found for '$displayName': $($command.FilePath)" -Level 'ERROR'
        return $false
    }

    Write-Log "Uninstalling '$displayName' (version: $($Product.DisplayVersion); key: $($Product.PSChildName))" -Level 'INFO'
    Write-Log "  Command: `"$($command.FilePath)`" $($command.ArgumentList)" -Level 'DEBUG'

    try {
        $exitCode = Invoke-Action -Description "Run uninstaller for '$displayName'" -Action {
            $proc = Start-Process -FilePath $command.FilePath -ArgumentList $command.ArgumentList -Wait -PassThru -ErrorAction Stop
            return $proc.ExitCode
        }
    }
    catch {
        Write-Log "  Uninstall attempt threw an error: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }

    if ($script:DryRun) { return $true }

    if ($command.IsMsi) {
        if ($exitCode -eq 3010) {
            Write-Log "  msiexec returned 3010 - uninstall succeeded but a reboot is required to finish." -Level 'WARNING'
            $script:RebootRequired = $true
            return $true
        }
        if ($exitCode -in $msiSuccessCodes) {
            Write-Log "  msiexec returned $exitCode - success." -Level 'INFO'
            return $true
        }
        Write-Log "  msiexec returned $exitCode - treating as failure." -Level 'ERROR'
        return $false
    }

    # EXE uninstallers are less consistent; 0 is the only exit code we trust as success here.
    # Final registry verification is the real arbiter regardless.
    if ($exitCode -eq 0) {
        Write-Log "  Uninstaller returned 0 - success." -Level 'INFO'
        return $true
    }
    Write-Log "  Uninstaller returned $exitCode - will rely on registry verification." -Level 'WARNING'
    return $false
}

#endregion

#region Script Body

$script:RebootRequired = $false

try {
    Write-Log "Script started - MSP: $MSPName" -Level 'INFO'
    Write-Log "Log file: $($script:LogPath)" -Level 'INFO'
    Write-Log "Parameters: NameFilter=$NameFilter, OutlookCloseTimeoutSeconds=$OutlookCloseTimeoutSeconds, Verbosity=$Verbosity, DryRun=$DryRun" -Level 'INFO'
    if ($DryRun) {
        Write-Log '*** DRYRUN MODE - No changes will be made ***' -Level 'WARNING'
    }

    # 1. Detect FIRST. If the plug-in isn't here there is nothing to do and Outlook stays open -
    #    this is what makes the script safe to run from a recurring policy.
    $installedProducts = Get-MatchingInstalledProduct -Filter $NameFilter

    if ($installedProducts.Count -eq 0) {
        Write-Log "No installed product matching '$NameFilter' found. Nothing to do; Outlook was not touched." -Level 'SUCCESS'
        exit 0
    }

    Write-Log "Found $($installedProducts.Count) product(s) matching '$NameFilter':" -Level 'INFO'
    foreach ($p in $installedProducts) {
        Write-Log "  - $($p.DisplayName) [$($p.DisplayVersion)] ($($p.PSChildName))" -Level 'INFO'
    }

    # 2. Only now close Outlook - the plug-in DLLs are locked while it runs.
    Close-OutlookIfRunning -TimeoutSeconds $OutlookCloseTimeoutSeconds

    # 3. Uninstall each match.
    $failures = 0
    foreach ($product in $installedProducts) {
        if (-not (Uninstall-Product -Product $product)) { $failures++ }
    }

    if ($DryRun) {
        Write-Log "[DRYRUN] Detection complete. $($installedProducts.Count) product(s) would be uninstalled." -Level 'SUCCESS'
        exit 0
    }

    # 4. Verify. Give MSI a moment to commit registry changes.
    Start-Sleep -Seconds 5
    $stillPresent = Get-MatchingInstalledProduct -Filter $NameFilter

    if ($stillPresent.Count -gt 0) {
        Write-Log "'$NameFilter' still present after uninstall: $(($stillPresent | ForEach-Object { $_.DisplayName }) -join ', '). Manual follow-up needed." -Level 'ERROR'
        exit 1
    }

    if ($failures -gt 0) {
        Write-Log "No matching entries remain, but $failures uninstall step(s) reported errors. Review the log." -Level 'ERROR'
        exit 1
    }

    if ($script:RebootRequired) {
        Write-Log 'A reboot is required to complete removal (msiexec 3010).' -Level 'WARNING'
    }
    Write-Log "Confirmed removed: no product matching '$NameFilter' remains in the uninstall registry." -Level 'SUCCESS'
    exit 0
}
catch {
    Write-Log "Script failed: $_" -Level 'ERROR'
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
    exit 1
}
finally {
    $duration = (Get-Date) - $scriptStartTime
    Write-Log "Total duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Level 'INFO'
}

#endregion
