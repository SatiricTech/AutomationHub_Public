#Requires -Version 5.1

<#
.SYNOPSIS
    Downloads and silently installs the NinjaOne agent (Windows MSI) on a device that does not have it yet.

.DESCRIPTION
    Windows-only. Targets Windows PowerShell 5.1 so it runs on a stock endpoint; it must run elevated.

    Built for first-time deployment, before NinjaOne exists on the device (ScreenConnect, Intune,
    GPO, or by hand). Nothing here depends on the NinjaOne agent or its Ninja-Property cmdlets.

    Set the installer URL once in the -AgentUrl default at the top of the param block, or pass
    -AgentUrl on the command line. Get the URL from the NinjaOne console: Organization >
    Add device / Download installer (Windows MSI). The URL identifies the organization and
    location the device enrolls into, so treat it as sensitive and do not commit a real one.

    What it does:
      1. Validates the URL (https, path ends in .msi) and enforces TLS 1.2.
      2. Exits 0 without changes if the NinjaRMMAgent service already exists, unless -Force.
      3. Requires an elevated session (skipped for -DryRun).
      4. Downloads the MSI to a temp file and verifies its Authenticode signature (valid, signed by
         a certificate whose CN is in $AllowedSigners) before anything is executed.
      5. Runs msiexec /i /qn /norestart with verbose MSI logging.
      6. Treats MSI exit codes 0, 3010 and 1641 as success (3010/1641 mean a reboot is pending; the
         script never reboots the device).
      7. Polls up to 60 seconds for the NinjaRMMAgent service to appear.
      8. Removes the temp MSI.

    Exit codes:
      0   success, or already installed
      1   msiexec failed (including 1638) or unexpected error
      2   AgentUrl missing or invalid
      3   not running elevated
      10  download failed
      20  installer signature invalid or not signed by NinjaOne
      30  install reported success but the service did not appear

    Unattended launch: when a task or RMM job starts this in a user session, launch it headless so no
    console window flashes (-WindowStyle Hidden alone still flashes one). For example:
      conhost.exe --headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
          -WindowStyle Hidden -File .\Install-NinjaOneAgent.ps1 -AgentUrl '<url>'

.PARAMETER AgentUrl
    HTTPS URL of the NinjaOne Windows MSI installer. Defaults to the editable placeholder in the param
    block; the script fails with exit code 2 until it is set. The URL must use https, the host must be
    ninjarmm.com or ninjaone.com (or a subdomain such as eu.ninjarmm.com), and the path must end in .msi.
    The Authenticode check then requires an exact NinjaOne signer name before anything runs.

.PARAMETER Force
    Run the installer even if the NinjaRMMAgent service already exists. If the same or another version
    is already installed, msiexec may return 1638, which is treated as a failure (exit 1).

.PARAMETER DryRun
    Validates the URL and checks for an existing install, then logs the download and install that would
    run. Nothing is downloaded or installed.

.PARAMETER Verbosity
    Controls console output level. Valid values: Low, Medium, High.
    Low shows only errors and success. Medium adds warnings. High shows everything.

.PARAMETER LogPath
    Path to the log file. Defaults to $env:ProgramData\$MSPName\Logs\<scriptname>-<timestamp>.log.
    The MSI log is written next to it.

.EXAMPLE
    .\Install-NinjaOneAgent.ps1 -AgentUrl 'https://app.ninjarmm.com/agent/installer/<INSTALLER-ID>/<installer-name>.msi'

.EXAMPLE
    .\Install-NinjaOneAgent.ps1 -AgentUrl 'https://app.ninjarmm.com/agent/installer/<INSTALLER-ID>/<installer-name>.msi' -DryRun
    # Validates and reports what would happen; no download, no install

.NOTES
    Version:    1.0.0
    Created:    2026-10-06
    AI Assist:  Claude (Anthropic)
    Platform:   Windows only; run elevated.
#>

[CmdletBinding()]
param (
    # ==========================================================================================
    # EDIT THIS: paste the installer URL from NinjaOne console > Organization > Add device /
    # Download installer (Windows MSI)
    # ==========================================================================================
    [string]$AgentUrl = '',

    [switch]$Force,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Low',

    [string]$LogPath
)

#region Configuration & Constants

$MSPName = '{mspname}'   # <-- Replace with your MSP name (e.g., 'SentinelCyber')

$ErrorActionPreference = 'Stop'
$script:Verbosity = $Verbosity
$script:DryRun = $DryRun.IsPresent
$scriptStartTime = Get-Date

$ServiceName = 'NinjaRMMAgent'
$SuccessExitCodes = @(0, 3010, 1641)
# Regional hosts (eu., ca., oc., us2.) are subdomains; the pattern is anchored at both ends.
$AllowedHostPattern = '^([a-z0-9-]+\.)*(ninjarmm|ninjaone)\.com$'
# Code-signing certificate CNs NinjaOne has used. Add a name here if NinjaOne rotates its publisher.
$AllowedSigners = @('NinjaOne, LLC', 'NinjaOne LLC', 'NinjaRMM LLC', 'NinjaRMM, LLC')
$ServiceWaitSeconds = 60
$ServicePollSeconds = 5

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
        'Low'    { $Level -in 'ERROR', 'SUCCESS' }
        'Medium' { $Level -in 'ERROR', 'WARNING', 'SUCCESS' }
        'High'   { $true }
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

#endregion

#region Main Functions

function Test-AgentUrl {
    # Returns $null when the URL is usable, otherwise the reason it is not.
    param (
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -match '[<>]') {
        return 'AgentUrl is not set. Edit the AgentUrl default at the top of the script, or pass -AgentUrl.'
    }

    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) {
        return "AgentUrl is not a valid absolute URL: $Url"
    }
    if ($uri.Scheme -ne 'https') {
        return 'AgentUrl must use https.'
    }
    if ($uri.Host -notmatch $AllowedHostPattern) {
        return "AgentUrl host '$($uri.Host)' is not a NinjaOne domain (ninjarmm.com or ninjaone.com)."
    }
    if ($uri.AbsolutePath -notmatch '\.msi$') {
        return 'AgentUrl must point to a Windows MSI (path must end in .msi).'
    }
    return $null
}

function Test-AgentInstalled {
    return [bool](Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
}

function Get-AgentInstaller {
    param (
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$OutFile
    )

    # The 5.1 progress bar throttles large downloads.
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 600
}

function Test-ElevatedSession {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InstallerSignature {
    # Returns $null when the MSI is validly signed by a Ninja certificate, otherwise the reason it is not.
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        return "Installer signature status is '$($signature.Status)', expected 'Valid'."
    }
    # Exact CN match: a substring test would accept any publisher with "Ninja" in its name.
    $subject = [string]$signature.SignerCertificate.Subject
    $commonName = $null
    if ($subject -match '(?:^|,\s*)CN=(?:"(?<cn>[^"]*)"|(?<cn>[^,]*))') {
        $commonName = $Matches['cn'].Trim()
    }
    if ($commonName -notin $AllowedSigners) {
        return "Installer is not signed by NinjaOne (signer: $subject)."
    }
    return $null
}

function Start-MsiInstall {
    # Returns the msiexec exit code.
    param (
        [Parameter(Mandatory)]
        [string]$MsiPath,

        [Parameter(Mandatory)]
        [string]$MsiLogPath
    )

    $msiArgs = @('/i', "`"$MsiPath`"", '/qn', '/norestart', '/L*v', "`"$MsiLogPath`"")
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    return $process.ExitCode
}

function Wait-AgentService {
    param (
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-AgentInstalled) { return $true }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return (Test-AgentInstalled)
}

function Invoke-Main {
    # Returns the script exit code.
    param (
        [string]$Url,
        [switch]$Force,
        [switch]$DryRun,
        [string]$MsiLogPath
    )

    $script:DryRun = $DryRun.IsPresent

    # Enforce TLS 1.2 for the download
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $problem = Test-AgentUrl -Url $Url
    if ($problem) {
        Write-Log $problem -Level 'ERROR'
        return 2
    }
    $Url = $Url.Trim()

    if ((Test-AgentInstalled) -and -not $Force) {
        Write-Log "$ServiceName service already exists; nothing to do (use -Force to reinstall)." -Level 'SUCCESS'
        return 0
    }
    if ($Force) {
        Write-Log "-Force specified; installing even if $ServiceName exists." -Level 'WARNING'
    }

    if (-not (Test-ElevatedSession)) {
        if ($script:DryRun) {
            Write-Log 'Not elevated; a real run would stop here. Continuing because of -DryRun.' -Level 'WARNING'
        }
        else {
            Write-Log 'This script must run elevated (as Administrator or SYSTEM).' -Level 'ERROR'
            return 3
        }
    }

    $tempMsi = Join-Path ([System.IO.Path]::GetTempPath()) "NinjaOneAgent-$([guid]::NewGuid().ToString('N')).msi"

    try {
        try {
            $null = Invoke-Action -Description "Download installer to $tempMsi" -Action {
                Get-AgentInstaller -Url $Url -OutFile $tempMsi
            }
        }
        catch {
            Write-Log "Download failed: $_" -Level 'ERROR'
            return 10
        }

        if (-not $script:DryRun) {
            $sigProblem = Test-InstallerSignature -Path $tempMsi
            if ($sigProblem) {
                Write-Log "$sigProblem Refusing to run it." -Level 'ERROR'
                return 20
            }
            Write-Log 'Installer signature verified.' -Level 'INFO'
        }

        $installCode = Invoke-Action -Description "Run msiexec /i /qn /norestart (MSI log: $MsiLogPath)" -Action {
            Start-MsiInstall -MsiPath $tempMsi -MsiLogPath $MsiLogPath
        }

        if ($script:DryRun) {
            Write-Log 'Dry run complete; no changes were made.' -Level 'SUCCESS'
            return 0
        }

        if ($installCode -notin $SuccessExitCodes) {
            Write-Log "msiexec failed with exit code ${installCode}. See $MsiLogPath" -Level 'ERROR'
            return 1
        }
        if ($installCode -ne 0) {
            Write-Log "msiexec exit code ${installCode}: install succeeded, reboot pending (not rebooting)." -Level 'WARNING'
        }

        Write-Log "Waiting up to $ServiceWaitSeconds seconds for the $ServiceName service..." -Level 'INFO'
        if (-not (Wait-AgentService -TimeoutSeconds $ServiceWaitSeconds -PollSeconds $ServicePollSeconds)) {
            Write-Log "Install reported success but the $ServiceName service did not appear." -Level 'ERROR'
            return 30
        }
        Write-Log "NinjaOne agent installed; $ServiceName service is present." -Level 'SUCCESS'
        return 0
    }
    catch {
        Write-Log "Unexpected error: $_" -Level 'ERROR'
        return 1
    }
    finally {
        if (Test-Path -LiteralPath $tempMsi) {
            Remove-Item -LiteralPath $tempMsi -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

# Dot-sourcing (for Pester) loads the functions without running the script.
if ($MyInvocation.InvocationName -eq '.') { return }

#region Script Body

$exitCode = 1
try {
    if (-not $LogPath) {
        $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
        $logRoot    = Join-Path $env:ProgramData (Join-Path $MSPName 'Logs')
        $LogPath    = Join-Path $logRoot "$scriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    }
    $script:LogPath = $LogPath

    $logDir = Split-Path -Path $script:LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $msiLog = Join-Path $logDir "NinjaOneAgent-msi-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    Write-Log "Script started - MSP: $MSPName" -Level 'INFO'
    Write-Log "Log file: $($script:LogPath)" -Level 'INFO'
    # The URL identifies the target organization, so it is deliberately not logged.
    Write-Log "Parameters: Force=$Force, DryRun=$DryRun, Verbosity=$Verbosity" -Level 'INFO'
    if ($DryRun) {
        Write-Log '*** DRYRUN MODE - No changes will be made ***' -Level 'WARNING'
    }

    $exitCode = Invoke-Main -Url $AgentUrl -Force:$Force -DryRun:$DryRun -MsiLogPath $msiLog
}
catch {
    Write-Log "Script failed: $_" -Level 'ERROR'
    $exitCode = 1
}
finally {
    $duration = (Get-Date) - $scriptStartTime
    Write-Log "Total duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Level 'INFO'
}
exit $exitCode

#endregion
