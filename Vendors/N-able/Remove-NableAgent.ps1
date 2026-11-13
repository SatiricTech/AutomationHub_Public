#Requires -Version 5.1

<#
.SYNOPSIS
    Finds and removes all N-able (SolarWinds MSP / LogicNow / GFI MAX) agent software from a Windows endpoint.

.DESCRIPTION
    Scorched-earth removal of N-able RMM software from devices taken over from other MSPs.
    Written in response to the November 2026 N-central "Able2Shell" / "Agent2Shell" disclosures, where
    agent-side exploitation can give SYSTEM on endpoints that still run an N-able agent.

    Products covered:
      - N-central Windows Agent, Windows Agent Maintenance Service, Windows (Software) Probe
      - Patch Management Engine (PME), Request Handler Agent, File Cache Service Agent, Ecosystem Agent
      - Take Control (BeAnywhere / MSP Anywhere, BASupSrvc*), GetSupportService / GetSupportService_N-Central
      - N-sight RMM "Advanced Monitoring Agent" (+ GP, Network Management, Web Protection, patchman)
      - Cove Data Protection / N-able Backup "Backup Manager" (C:\Program Files\Backup Manager, C:\ProgramData\MXB)
      - Passportal agent
      - Automation Manager and any other entry published by N-able / SolarWinds MSP / LogicNow / MspPlatform

    Method. The script does not trust a fixed list of names, because N-able service names and MSI GUIDs change
    between versions. It discovers artifacts by publisher, by install path, and by a small set of unambiguous
    names, then removes them in four phases:
      1. Vendor uninstallers, in dependency order. The N-central Windows Agent goes first, because it
         reinstalls PME within about an hour if it stays. Every uninstaller has a timeout, because an
         uninstall-protection prompt or hidden dialog would otherwise hang a SYSTEM job forever.
      2. Forced stop: disable services (watchdogs and updaters first, so they cannot restart the main
         services), stop them, and kill remaining processes.
      3. Forced cleanup: delete services, scheduled tasks, firewall rules, folders, registry keys, and the
         N-central asset-tag WMI class. Files that are locked are queued for deletion at the next reboot.
      4. Verification: discovery runs again and the script reports what is left.

    Out of scope by design:
      - SentinelOne. N-able EDR is a stock SentinelOne agent and cannot be told apart from our own S1 by
        name or path. Anything that matches the protected-vendor pattern (SentinelOne, NinjaOne, Huntress,
        ThreatLocker, Blackpoint, ScreenConnect, BeyondTrust, Bitdefender) is never touched.
      - N-able Managed Antivirus (Bitdefender-based). The official removal needs a support-only tool run in
        Safe Mode. The script reports MAV and leaves it, unless -IncludeManagedAntivirus is set, in which
        case it only runs the registered MAV uninstaller.
      - Windows Update policy left by N-able patching. The script reports it but does not change it,
        because NinjaOne patch management writes to the same keys.

    The script never reboots the device. It logs when a reboot is needed.

    Windows-only. Must run elevated (SYSTEM via RMM, or an elevated admin session). If started as a 32-bit
    process on a 64-bit OS, it relaunches itself in 64-bit PowerShell so it sees the real registry.

.PARAMETER Verbosity
    Console output level: Low (errors and success), Medium (adds warnings and findings), High (everything).
    The log file always gets everything. Default is Medium so that RMM activity output shows what was found.

.PARAMETER DryRun
    Runs full discovery and logs every action it would take, without changing anything.

.PARAMETER LogPath
    Log file path. Defaults to $env:ProgramData\<MSPName>\Logs\Remove-NableAgent-<timestamp>.log.

.PARAMETER UninstallerTimeoutSeconds
    Maximum run time for each vendor uninstaller before the script kills it and moves on. Default 300.

.PARAMETER KeepCoveData
    Do not delete C:\ProgramData\MXB (Cove / N-able Backup configuration and local cache).

.PARAMETER RemovePassportalLsaHook
    Remove 'adpasswordchangenotifier' from the LSA Notification Packages value and queue the DLL for deletion.
    Off by default, because this is an LSA change. On a domain controller, review it before use.

.PARAMETER IncludeManagedAntivirus
    Also run the registered uninstaller for N-able Managed Antivirus entries. The script still does not
    force-delete MAV services, drivers, or folders.

.EXAMPLE
    .\Remove-NableAgent.ps1 -DryRun -Verbosity High
    # Shows every N-able artifact found and every action the script would take. Changes nothing.

.EXAMPLE
    .\Remove-NableAgent.ps1
    # Removes all N-able software found. Exit 0 = clean, 50 = items remain (see log).

.EXAMPLE
    .\Remove-NableAgent.ps1 -KeepCoveData -UninstallerTimeoutSeconds 600
    # Removes everything but keeps the Cove configuration folder, and allows slower uninstallers.

.NOTES
    Author:     Sentinel Cyber
    Version:    1.0.0
    Created:    2026-11-12
    AI Assist:  Drafted with Claude Code (Claude Opus 5.5). Reviewed before production use.

    Exit codes:
      0   No N-able artifacts remain (a reboot can still be needed; see log).
      1   Unexpected fatal error.
      2   Not elevated, or not Windows.
      50  Partial: some artifacts remain, or manual follow-up items exist (Managed AV, LSA hook).

    Sources (November 2026):
      - N-able: Silent uninstall of Windows Agent; Agent Removal/Cleanup; Take Control clean uninstall;
        N-sight "Uninstall the agent" (winagent /removequiet); Agent Uninstall Protection;
        Cove "Uninstall Backup Manager silently" (QuietUninstallString); Passportal manual AD agent uninstall;
        MAV Bitdefender clean uninstall.
      - github.com/N-able/ScriptsAndAutomationPolicies (Uninstall-NCentralAgent.ps1)
      - github.com/noc-cnrit/N-Able (FullyRemoveRMM.ps1, FullyRemoveTakeControl.ps1)

    Run time: usually a few minutes. The worst case is (number of N-able uninstallers) x
    UninstallerTimeoutSeconds, when each uninstaller hangs on an uninstall-protection prompt. A device with
    N-sight, N-central, Take Control, and Cove has 10 to 14 uninstallers. Set the NinjaOne script timeout
    to 60 minutes, or lower -UninstallerTimeoutSeconds (for example 120) for fleet runs.

    Known gaps: many service short names and all MSI GUIDs come from discovery at run time, not from vendor
    documentation. Run with -DryRun on one inherited device first and review the log.
#>

[CmdletBinding()]
param (
    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium',

    [switch]$DryRun,

    [string]$LogPath,

    [ValidateRange(30, 3600)]
    [int]$UninstallerTimeoutSeconds = 300,

    [switch]$KeepCoveData,

    [switch]$RemovePassportalLsaHook,

    [switch]$IncludeManagedAntivirus
)

#region Configuration & Constants

# A 32-bit host (some RMM runners) sees WOW6432Node as HKLM\SOFTWARE and Program Files (x86) as Program Files.
# Relaunch in 64-bit PowerShell so discovery sees the real layout.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $PSCommandPath) {
    $sysnativePs = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysnativePs) {
        $relaunchArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        foreach ($entry in $PSBoundParameters.GetEnumerator()) {
            if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
                if ($entry.Value.IsPresent) { $relaunchArgs += "-$($entry.Key)" }
            }
            else {
                $relaunchArgs += "-$($entry.Key)"
                $relaunchArgs += "$($entry.Value)"
            }
        }
        # Preset to 1 so that a child that fails to start is not reported as success.
        $global:LASTEXITCODE = 1
        & $sysnativePs @relaunchArgs
        exit $global:LASTEXITCODE
    }
}

# Set this to your MSP name. It names the log folder: $env:ProgramData\<MSPName>\Logs.
$MSPName = '{MSP Name}'

$ErrorActionPreference = 'Stop'
$script:Verbosity       = $Verbosity
$script:DryRun          = [bool]$DryRun
$script:TimeoutMs       = $UninstallerTimeoutSeconds * 1000
$script:FailureCount    = 0
$script:RebootRequired  = $false
$script:PendingReboot   = New-Object System.Collections.Generic.List[string]
$script:PendingServices = New-Object System.Collections.Generic.List[string]
$script:InnoArgs        = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
$script:ManualItems     = New-Object System.Collections.Generic.List[string]
$scriptStartTime        = Get-Date

if (-not $LogPath) {
    $scriptName = 'Remove-NableAgent'
    if ($PSCommandPath) { $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) }
    $logRoot = Join-Path (Join-Path $env:ProgramData $MSPName) 'Logs'
    $LogPath = Join-Path $logRoot "$scriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}
$script:LogPath = $LogPath
$script:LogDir  = Split-Path -Path $script:LogPath -Parent
if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -Path $script:LogDir -ItemType Directory -Force | Out-Null
}

$pf   = $env:ProgramFiles
$pf86 = ${env:ProgramFiles(x86)}
$pd   = $env:ProgramData

# Install-path fingerprint for every N-able product. Matched against service ImagePath, process paths,
# uninstall strings, scheduled task actions, and firewall programs. Each alternative is anchored to a
# folder name so that unrelated software cannot match by accident ("Backup Manager" only in Program Files).
$script:PathPattern = '(?i)(' + (@(
    '\\N-able Technologies(\\|$|")'
    '\\N-able(\\|$|")'
    '\\SolarWinds MSP(\\|$|")'
    '\\MspPlatform(\\|$|")'
    '\\LogicNow(\\|$|")'
    '\\GFI MAX'
    '\\MAXfocus'
    '\\BeAnywhere Support Express(\\|$|")'
    '\\GetSupportService'
    '\\Take Control Agent(\\|$|")'
    '\\Advanced Monitoring Agent'
    '\\Program Files( \(x86\))?\\Backup Manager(\\|$|")'
    '\\ProgramData\\MXB(\\|$|")'
    '\\Passportal(\\|$|")'
    '\\\{FE6265DF-9CF3-4C58-8B89-F6D8C0976573\}(\\|$|")'
) -join '|') + ')'

# Publisher values seen on N-able uninstall entries across the product's rebrands.
$script:PublisherPattern = '(?i)^(N-able|SolarWinds MSP|LogicNow|GFI MAX|MAXfocus|MspPlatform|' +
    'BeAnywhere|Passportal|IASO)'

# Display names that identify an N-able product on their own. "Windows Agent" and "Automation Manager"
# are too generic to trust alone; they only count with an N-able publisher or path.
$script:DisplayNamePattern = '(?i)^(Windows Software Probe|Patch Management Service Controller|Request Handler Agent|' +
    'File Cache Service Agent|Ecosystem Agent|Take Control Agent|N-able .+|Advanced Monitoring Agent.*|Passportal.*)$'

# Service short or display names that identify an N-able service on their own.
$script:ServiceNamePattern = '(?i)^(Advanced Monitoring Agent|BASupSrvc|BASupportExpress|N-able|SolarWinds\.MSP|' +
    'SolarWinds MSP|PME\.Agent|Passportal)'

# Names for scheduled tasks and firewall rules.
$script:LabelPattern = '(?i)(N-able|SolarWinds MSP|MspPlatform|Take Control|BASup|Advanced Monitoring Agent|Passportal)'

# N-able Managed Antivirus. Reported, not force-removed.
$script:MavPattern = '(?i)(Managed Antivirus|\\ManagedAntivirus)'

# Never touch anything that matches this, even if another rule matches it. SentinelOne is here because
# N-able EDR is a stock S1 agent and our own S1 must survive. Bitdefender is here because MAV needs the
# vendor tool, and a generic Bitdefender install may not be N-able's.
$script:ProtectedPattern = '(?i)(Sentinel|NinjaRMM|NinjaOne|Ninja\\|Huntress|ThreatLocker|Blackpoint|' +
    'ScreenConnect|BeyondTrust|Bitdefender)'

# Process names unique to N-able. Other N-able processes are found by path.
$script:KnownProcessNames = @(
    'winagent', '_new_winagent', 'BASupSrvc', 'BASupSrvcCnfg', 'BASupSrvcUpdater', 'BASupTSHelper',
    'PME.Agent', 'RequestHandlerAgent', 'FileCacheServiceAgent', 'BackupFP'
)

# Folders that only N-able products use. A folder is deleted only if Test-SafeDeletePath also accepts it.
$script:KnownFolders = New-Object System.Collections.Generic.List[string]
foreach ($root in @($pf, $pf86)) {
    if (-not $root) { continue }
    foreach ($name in @(
            'N-able Technologies', 'N-able', 'SolarWinds MSP', 'MspPlatform', 'LogicNow',
            'BeAnywhere Support Express', 'Take Control Agent', 'Advanced Monitoring Agent',
            'Advanced Monitoring Agent GP', 'Advanced Monitoring Agent Network Management',
            'Advanced Monitoring Agent Web Protection', 'Passportal', 'Backup Manager')) {
        $script:KnownFolders.Add((Join-Path $root $name))
    }
}
foreach ($name in @(
        'N-able Technologies', 'N-able', 'SolarWinds MSP', 'MspPlatform', 'LogicNow', 'BeAnywhere Support Express',
        'GetSupportService', 'GetSupportService_N-Central', 'Advanced Monitoring Agent', 'Passportal',
        '{FE6265DF-9CF3-4C58-8B89-F6D8C0976573}')) {
    $script:KnownFolders.Add((Join-Path $pd $name))
}
if (-not $KeepCoveData) { $script:KnownFolders.Add((Join-Path $pd 'MXB')) }

# Vendor registry roots. Uninstall and service keys are found by discovery.
$script:KnownRegistryKeys = @()
foreach ($hive in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
    foreach ($name in @('N-able Technologies', 'N-able', 'SolarWinds MSP', 'MspPlatform', 'LogicNow',
            'BeAnyWhere Support Express', 'Advanced Monitoring Agent', 'Passportal')) {
        $script:KnownRegistryKeys += "$hive\$name"
    }
}

$script:UninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

#endregion

#region Helper Functions

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
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

    try { Add-Content -LiteralPath $script:LogPath -Value $logMessage -ErrorAction Stop }
    catch { Write-Host "[$timestamp] [ERROR] Cannot write log file: $_" -ForegroundColor Red }
}

function Invoke-Action {
    <#
        DryRun-aware wrapper for every mutation. Unlike the standard template it does not rethrow:
        a scorched-earth removal must continue past one failed step. It counts failures and returns
        $true on success.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if ($script:DryRun) {
        Write-Log "[DRYRUN] Would execute: $Description" -Level 'INFO'
        return $true
    }

    Write-Log "Executing: $Description" -Level 'INFO'
    try {
        & $Action
        return $true
    }
    catch {
        $script:FailureCount++
        Write-Log "Failed: $Description - $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}

function Test-Protected {
    # True if any value belongs to a protected vendor. Logged so a skip is never silent.
    param ([string[]]$Value)

    $joined = ($Value | Where-Object { $_ }) -join ' | '
    if ($joined -and $joined -match $script:ProtectedPattern) {
        Write-Log "PROTECTED, skipped: $joined" -Level 'WARNING'
        return $true
    }
    return $false
}

function Test-SafeDeletePath {
    # A folder is deleted only if it sits below Program Files, Program Files (x86), or ProgramData,
    # is not one of those roots, matches the N-able path fingerprint, and is not protected.
    param ([Parameter(Mandatory)][string]$Path)

    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') }
    catch { return $false }

    $roots = @($pf, $pf86, $pd) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    if ($roots -contains $full) { return $false }

    $underRoot = $false
    foreach ($root in $roots) {
        if ($full.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase)) { $underRoot = $true }
    }
    if (-not $underRoot) { return $false }
    if ($full -notmatch $script:PathPattern) { return $false }
    if ($full -match $script:ProtectedPattern) { return $false }
    return $true
}

function Split-CommandLine {
    # Splits an UninstallString into executable and arguments. Handles quoted and unquoted paths.
    param ([Parameter(Mandatory)][string]$CommandLine)

    # Quotes never stay in FilePath: a stray quote makes Test-Path throw under ErrorAction Stop.
    $line = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($line.StartsWith('"')) {
        $end = $line.IndexOf('"', 1)
        if ($end -gt 1) {
            return [pscustomobject]@{
                FilePath  = $line.Substring(1, $end - 1).Trim()
                Arguments = $line.Substring($end + 1).Trim()
            }
        }
        $line = $line.TrimStart('"')   # Unbalanced opening quote.
    }
    $match = [regex]::Match($line, '^(.+?\.exe)\s*(.*)$', 'IgnoreCase')
    if ($match.Success) {
        return [pscustomobject]@{
            FilePath  = $match.Groups[1].Value.Trim('"', ' ')
            Arguments = $match.Groups[2].Value.Trim()
        }
    }
    return [pscustomobject]@{ FilePath = $line.Trim('"', ' '); Arguments = '' }
}

function Register-DeleteOnReboot {
    # Queues a locked file or empty folder for deletion by the Session Manager at the next boot.
    param ([Parameter(Mandatory)][string]$Path)

    if (-not ('NableCleanup.NativeMethods' -as [type])) {
        Add-Type -Namespace NableCleanup -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool MoveFileEx(string lpExistingFileName, string lpNewFileName, int dwFlags);
'@
    }
    # 4 = MOVEFILE_DELAY_UNTIL_REBOOT
    if ([NableCleanup.NativeMethods]::MoveFileEx($Path, $null, 4)) {
        $script:PendingReboot.Add($Path)
        $script:RebootRequired = $true
        return $true
    }
    return $false
}

function Invoke-Uninstaller {
    # Runs one vendor uninstaller with a hard timeout. A timeout or bad exit code is a logged failure,
    # not a stop: the forced phase removes what the uninstaller left.
    param (
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyString()][string]$Arguments = '',
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $FilePath -ErrorAction SilentlyContinue)) {
        Write-Log "Uninstaller not found for '$Label': $FilePath" -Level 'DEBUG'
        return
    }

    $null = Invoke-Action -Description "Uninstall '$Label': `"$FilePath`" $Arguments" -Action {
        $startParams = @{ FilePath = $FilePath; PassThru = $true; WindowStyle = 'Hidden' }
        if ($Arguments) { $startParams.ArgumentList = $Arguments }
        $proc = Start-Process @startParams
        $null = $proc.Handle   # Cache the handle so ExitCode is readable after exit.

        if (-not $proc.WaitForExit($script:TimeoutMs)) {
            # Through cmd.exe: in 5.1, taskkill stderr under ErrorAction Stop would replace the real error.
            & cmd.exe /c "taskkill.exe /T /F /PID $($proc.Id) >nul 2>&1"
            throw "Timed out after $($script:TimeoutMs / 1000) s and was killed (uninstall protection prompt?)"
        }
        # 1605 = product not installed, 1614 = product uninstalled, 3010/1641 = success, reboot needed.
        $code = $proc.ExitCode
        if ($code -in 3010, 1641) { $script:RebootRequired = $true }
        if ($code -notin 0, 1605, 1614, 3010, 1641) { throw "Exit code $code" }
        Write-Log "Uninstaller for '$Label' exited with code $code" -Level 'INFO'
    }
}

function Remove-RegistryKey {
    # Deletes a registry key. Falls back to reg.exe, because the registry provider can refuse a delete
    # (seen in testing: "Requested registry access is not allowed") that reg.exe completes.
    param ([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        $native = $Path -replace '^.*?Registry::', '' -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\'
        & cmd.exe /c "reg.exe delete `"$native`" /f >nul 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "Remove-Item and reg.exe both failed for '$native'" }
    }
}

#endregion

#region Discovery Functions

function Get-NableUninstallEntry {
    $entries = foreach ($root in $script:UninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            try { $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop }
            catch { continue }

            $displayName = [string]$p.DisplayName
            $publisher   = [string]$p.Publisher
            $location    = ([string]$p.InstallLocation).Trim().Trim('"')
            $uninstall   = [string]$p.UninstallString
            $quiet       = [string]$p.QuietUninstallString
            # Joined with '" "' so that a path with no trailing backslash still ends at a pattern delimiter.
            $paths       = @($location, $uninstall, $quiet) -join '" "'

            $isMav = $displayName -match $script:MavPattern
            $publisherHit = $publisher -and $publisher -match $script:PublisherPattern
            $pathHit = $paths -match $script:PathPattern
            $nameHit = $displayName -and $displayName -match $script:DisplayNamePattern
            if (-not ($isMav -or $publisherHit -or $pathHit -or $nameHit)) { continue }
            if (Test-Protected -Value @($displayName, $publisher, $paths)) { continue }

            [pscustomobject]@{
                KeyPath              = $key.PSPath
                KeyName              = $key.PSChildName
                DisplayName          = $displayName
                Publisher            = $publisher
                InstallLocation      = $location
                UninstallString      = $uninstall
                QuietUninstallString = $quiet
                IsMav                = [bool]$isMav
                Priority             = Get-RemovalPriority -DisplayName $displayName
            }
        }
    }
    return @($entries)
}

function Get-RemovalPriority {
    # Order matters: N-central Windows Agent first (it reinstalls PME), then its child components,
    # then Take Control, then N-sight sub-components before the main agent, then the rest.
    param ([string]$DisplayName)

    switch -Regex ($DisplayName) {
        '^Windows Agent'                                                  { return 10 }
        'Probe'                                                           { return 20 }
        'Ecosystem|File Cache|Request Handler|Patch Management|PME'       { return 30 }
        'Take Control|BeAnywhere|MSP Anywhere'                            { return 40 }
        '^Advanced Monitoring Agent (Network|Web)'                        { return 50 }
        '^Advanced Monitoring Agent'                                      { return 60 }
        '^Backup Manager'                                                 { return 70 }
        'Passportal'                                                      { return 80 }
        default                                                           { return 90 }
    }
}

function Get-NableService {
    $services = foreach ($svc in Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue) {
        $path = [string]$svc.PathName
        $isMav = $path -match $script:MavPattern -or $svc.DisplayName -match $script:MavPattern
        $hit = $isMav -or ($path -match $script:PathPattern) -or
            ($svc.Name -match $script:ServiceNamePattern) -or ($svc.DisplayName -match $script:ServiceNamePattern)
        if (-not $hit) { continue }
        if (Test-Protected -Value @($svc.Name, $svc.DisplayName, $path)) { continue }
        [pscustomobject]@{
            Name        = $svc.Name
            DisplayName = $svc.DisplayName
            PathName    = $path
            State       = $svc.State
            ProcessId   = $svc.ProcessId
            IsMav       = [bool]$isMav
            # Watchdogs and updaters restart the main services, so they are stopped first.
            IsWatcher   = [bool]("$($svc.Name) $($svc.DisplayName)" -match '(?i)Updater|Maintenance|Watchdog')
        }
    }
    return @($services)
}

function Get-NableProcess {
    $procs = foreach ($proc in Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue) {
        $path = [string]$proc.ExecutablePath
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$proc.Name)
        $hit = ($path -and $path -match $script:PathPattern) -or ($script:KnownProcessNames -contains $baseName)
        if (-not $hit) { continue }
        if ($path -match $script:MavPattern) { continue }
        if (Test-Protected -Value @($proc.Name, $path)) { continue }
        [pscustomobject]@{ Id = $proc.ProcessId; Name = $proc.Name; Path = $path }
    }
    return @($procs)
}

function Get-NableFolder {
    param ([object[]]$UninstallEntries, [object[]]$Services)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $script:KnownFolders) { $candidates.Add($folder) }

    # Add install folders reported by discovered entries and services (covers custom install paths).
    foreach ($entry in $UninstallEntries) {
        if ($entry.IsMav) { continue }
        if ($entry.InstallLocation) { $candidates.Add($entry.InstallLocation) }
    }
    foreach ($svc in $Services) {
        if ($svc.IsMav -or -not $svc.PathName) { continue }
        try {
            $exe = (Split-CommandLine -CommandLine $svc.PathName).FilePath
            if ($exe) { $candidates.Add((Split-Path -Path $exe -Parent)) }
        }
        catch { Write-Log "Cannot parse ImagePath of '$($svc.Name)': $($svc.PathName)" -Level 'DEBUG' }
    }

    $result = foreach ($candidate in ($candidates | Sort-Object -Unique)) {
        if (-not $candidate) { continue }
        $folder = $candidate.Trim().Trim('"')
        if (-not (Test-Path -LiteralPath $folder -PathType Container -ErrorAction SilentlyContinue)) { continue }
        # "Backup Manager" is a common folder name. Only treat it as Cove if Cove binaries are inside.
        if ($folder -match '\\Backup Manager\\?$' -and
            -not (Test-Path -LiteralPath (Join-Path $folder 'BackupFP.exe') -ErrorAction SilentlyContinue) -and
            -not (Test-Path -LiteralPath (Join-Path $folder 'ClientTool.exe') -ErrorAction SilentlyContinue)) {
            Write-Log "Skipped '$folder': no Cove binaries inside" -Level 'DEBUG'
            continue
        }
        if (-not (Test-SafeDeletePath -Path $folder)) {
            Write-Log "Skipped '$folder': fails the safe-delete check" -Level 'DEBUG'
            continue
        }
        # A vendor folder must not hold another vendor's install (for example an N-able EDR build of
        # SentinelOne, or MAV/Bitdefender). If it does, leave the folder and report it. Only folder names
        # are checked: N-able caches deployment payloads such as SentinelInstaller.msi, and those files
        # must not block the cleanup. The Cove data folder (MXB) is skipped; it can hold many GB.
        $foreign = @()
        if ($folder -notmatch '\\MXB$') {
            $foreign = @(Get-ChildItem -LiteralPath $folder -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $script:ProtectedPattern -or $_.Name -match $script:MavPattern } |
                Select-Object -First 1)
        }
        if ($foreign.Count -gt 0) {
            Write-Log "PROTECTED, skipped folder '$folder': contains '$($foreign[0].FullName)'" -Level 'WARNING'
            if ($script:ManualItems -notcontains "Review folder '$folder' by hand (holds protected-vendor files).") {
                $script:ManualItems.Add("Review folder '$folder' by hand (holds protected-vendor files).")
            }
            continue
        }
        $folder.TrimEnd('\')
    }

    # Delete the parent before the child is pointless; keep only the top-most folders.
    $sorted = @($result | Sort-Object -Unique | Sort-Object Length)
    $topLevel = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $sorted) {
        $covered = $false
        foreach ($parent in $topLevel) {
            if ($folder.StartsWith("$parent\", [System.StringComparison]::OrdinalIgnoreCase)) { $covered = $true }
        }
        if (-not $covered) { $topLevel.Add($folder) }
    }
    return @($topLevel)
}

function Get-NableScheduledTask {
    if (-not (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @() }
    $tasks = foreach ($task in Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $actions = ($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
        $hit = ("$($task.TaskPath)$($task.TaskName)" -match $script:LabelPattern) -or
            ($actions -match $script:PathPattern)
        if (-not $hit) { continue }
        if (Test-Protected -Value @($task.TaskName, $task.TaskPath, $actions)) { continue }
        $task
    }
    return @($tasks)
}

function Get-NableFirewallRule {
    if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) { return @() }
    $byName = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $script:LabelPattern })
    $byProgram = @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.Program -and $_.Program -match $script:PathPattern } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue)
    $rules = foreach ($rule in (@($byName) + @($byProgram) | Sort-Object -Property Name -Unique)) {
        if (Test-Protected -Value @($rule.DisplayName)) { continue }
        $rule
    }
    return @($rules)
}

function Get-NableServiceKey {
    # Orphan service keys (service deleted from SCM view but key left, or kernel drivers such as the
    # Web Protection filter driver, which Win32_Service does not list).
    $servicesRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    $keys = foreach ($key in Get-ChildItem -LiteralPath $servicesRoot -ErrorAction SilentlyContinue) {
        $props = Get-ItemProperty -LiteralPath $key.PSPath -Name ImagePath -ErrorAction SilentlyContinue
        $image = [string]$props.ImagePath
        if (-not $image -or $image -notmatch $script:PathPattern) { continue }
        if ($image -match $script:MavPattern) { continue }
        if (Test-Protected -Value @($key.PSChildName, $image)) { continue }
        [pscustomobject]@{ Name = $key.PSChildName; KeyPath = $key.PSPath; ImagePath = $image }
    }
    return @($keys)
}

function Get-NableInventory {
    $entries  = Get-NableUninstallEntry
    $services = Get-NableService
    $assetClass = Get-CimClass -Namespace 'root\cimv2' -ClassName 'NCentralAsset' -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        UninstallEntries = $entries
        Services         = $services
        Processes        = Get-NableProcess
        Folders          = Get-NableFolder -UninstallEntries $entries -Services $services
        ScheduledTasks   = Get-NableScheduledTask
        FirewallRules    = Get-NableFirewallRule
        ServiceKeys      = Get-NableServiceKey
        RegistryKeys     = @($script:KnownRegistryKeys | Where-Object { Test-Path -LiteralPath $_ })
        AssetWmiClass    = [bool]$assetClass
    }
}

function Write-Inventory {
    param ([Parameter(Mandatory)]$Inventory, [Parameter(Mandatory)][string]$Heading)

    Write-Log "---- $Heading ----" -Level 'WARNING'
    foreach ($e in $Inventory.UninstallEntries) {
        $tag = ''
        if ($e.IsMav) { $tag = ' [MANAGED AV]' }
        Write-Log "FOUND app: $($e.DisplayName) | $($e.Publisher) | $($e.KeyName)$tag" -Level 'WARNING'
    }
    foreach ($s in $Inventory.Services) {
        $tag = ''
        if ($s.IsMav) { $tag = ' [MANAGED AV]' }
        Write-Log "FOUND service: $($s.Name) ($($s.DisplayName)) [$($s.State)] $($s.PathName)$tag" -Level 'WARNING'
    }
    foreach ($p in $Inventory.Processes) {
        Write-Log "FOUND process: $($p.Name) [$($p.Id)] $($p.Path)" -Level 'WARNING'
    }
    foreach ($f in $Inventory.Folders) { Write-Log "FOUND folder: $f" -Level 'WARNING' }
    foreach ($t in $Inventory.ScheduledTasks) { Write-Log "FOUND task: $($t.TaskPath)$($t.TaskName)" -Level 'WARNING' }
    foreach ($r in $Inventory.FirewallRules) { Write-Log "FOUND firewall rule: $($r.DisplayName)" -Level 'WARNING' }
    foreach ($k in $Inventory.ServiceKeys) {
        Write-Log "FOUND service key: $($k.Name) $($k.ImagePath)" -Level 'WARNING'
    }
    foreach ($k in $Inventory.RegistryKeys) { Write-Log "FOUND registry key: $k" -Level 'WARNING' }
    if ($Inventory.AssetWmiClass) { Write-Log 'FOUND WMI class: root\cimv2:NCentralAsset' -Level 'WARNING' }
}

function Get-InventoryCount {
    param ([Parameter(Mandatory)]$Inventory, [switch]$ExcludeMav)

    $entries  = @($Inventory.UninstallEntries)
    # Services marked for deletion disappear at reboot; they are not failures.
    $services = @($Inventory.Services | Where-Object { $script:PendingServices -notcontains $_.Name })
    $serviceKeys = @($Inventory.ServiceKeys | Where-Object { $script:PendingServices -notcontains $_.Name })
    if ($ExcludeMav) {
        $entries  = @($entries | Where-Object { -not $_.IsMav })
        $services = @($services | Where-Object { -not $_.IsMav })
    }
    # Folders that are queued for deletion at reboot are not counted as failures.
    $folders = @($Inventory.Folders | Where-Object { $script:PendingReboot -notcontains $_ })
    $count = $entries.Count + $services.Count + @($Inventory.Processes).Count + $folders.Count +
        @($Inventory.ScheduledTasks).Count + @($Inventory.FirewallRules).Count +
        $serviceKeys.Count + @($Inventory.RegistryKeys).Count
    if ($Inventory.AssetWmiClass) { $count++ }
    return $count
}

#endregion

#region Main Functions

function Initialize-Script {
    Write-Log "Script started - MSP: $MSPName - Host: $env:COMPUTERNAME" -Level 'INFO'
    Write-Log "Log file: $($script:LogPath)" -Level 'INFO'
    Write-Log ("Parameters: Verbosity=$Verbosity, DryRun=$DryRun, " +
        "UninstallerTimeoutSeconds=$UninstallerTimeoutSeconds, " +
        "KeepCoveData=$KeepCoveData, RemovePassportalLsaHook=$RemovePassportalLsaHook, " +
        "IncludeManagedAntivirus=$IncludeManagedAntivirus") -Level 'INFO'
    Write-Log "PowerShell $($PSVersionTable.PSVersion) - 64-bit process: $([Environment]::Is64BitProcess)" -Level 'INFO'

    if ($script:DryRun) { Write-Log '*** DRYRUN MODE - No changes will be made ***' -Level 'WARNING' }

    # $script:exitCode is set before exit so that the finally block logs the real code.
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        Write-Log 'This script runs on Windows only.' -Level 'ERROR'
        $script:exitCode = 2
        exit 2
    }
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log 'This script must run elevated (SYSTEM or administrator).' -Level 'ERROR'
        $script:exitCode = 2
        exit 2
    }
}

function Invoke-EntryUninstall {
    # Picks and runs the silent uninstall method for one registered entry.
    param ([Parameter(Mandatory)]$Entry)

    $label = $Entry.DisplayName
    if (-not $label) { $label = $Entry.KeyName }
    $uninstall = [string]$Entry.UninstallString

    # N-sight agent: the vendor-documented silent switch. It fails if Uninstall Protection is on;
    # phase 3 then removes the agent by force.
    if ($Entry.DisplayName -match '^Advanced Monitoring Agent( GP)?$' -and $Entry.InstallLocation) {
        $winagent = Join-Path $Entry.InstallLocation 'winagent.exe'
        if (Test-Path -LiteralPath $winagent -ErrorAction SilentlyContinue) {
            Invoke-Uninstaller -FilePath $winagent -Arguments '/removequiet' -Label $label
            return
        }
    }

    # MSI: build our own silent command from the product code, so the msiexec log lands next to ours.
    $productCode = $null
    if ($Entry.KeyName -match '^\{[0-9A-Fa-f\-]{36}\}$' -and $uninstall -match '(?i)msiexec') {
        $productCode = $Entry.KeyName
    }
    elseif ($uninstall -match '(?i)msiexec.*(\{[0-9A-Fa-f\-]{36}\})') {
        $productCode = $Matches[1]
    }
    if ($productCode) {
        $msiExe  = Join-Path $env:WINDIR 'System32\msiexec.exe'
        $msiLog  = Join-Path $script:LogDir "msi-uninstall-$($productCode.Trim('{}')).log"
        $msiArgs = "/x $productCode /qn /norestart REBOOT=ReallySuppress /l*v `"$msiLog`""
        Invoke-Uninstaller -FilePath $msiExe -Arguments $msiArgs -Label $label
        return
    }

    # Vendor-supplied quiet command (Cove Backup Manager publishes one).
    if ($Entry.QuietUninstallString) {
        $cmd = Split-CommandLine -CommandLine $Entry.QuietUninstallString
        Invoke-Uninstaller -FilePath $cmd.FilePath -Arguments $cmd.Arguments -Label $label
        return
    }

    if ($uninstall) {
        $cmd = Split-CommandLine -CommandLine $uninstall
        $exeName = ($cmd.FilePath -split '\\')[-1]
        if ($exeName -match '(?i)^unins\d+\.exe$') {
            # Inno Setup (PME, Request Handler, File Cache, Ecosystem, Web Protection, Network Management).
            Invoke-Uninstaller -FilePath $cmd.FilePath -Arguments $script:InnoArgs -Label $label
            return
        }
        if ($exeName -match '(?i)^uninstall\.exe$') {
            # NSIS (Take Control).
            Invoke-Uninstaller -FilePath $cmd.FilePath -Arguments '/S' -Label $label
            return
        }
    }
    Write-Log "No known silent uninstall method for '$label'. Phase 3 removes it by force." -Level 'WARNING'
}

function Get-OnDiskUninstaller {
    # Uninstallers on disk that have no Uninstall registry entry (broken or partial installs).
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($root in (@($pf86, $pf) | Where-Object { $_ })) {
        $tcRoot = Join-Path $root 'BeAnywhere Support Express'
        foreach ($dir in @(Get-ChildItem -LiteralPath $tcRoot -Directory -ErrorAction SilentlyContinue)) {
            $found.Add(@{
                Path = (Join-Path $dir.FullName 'uninstall.exe'); Args = '/S'; Label = "Take Control ($($dir.Name))"
            })
        }
        $found.Add(@{
            Path = (Join-Path $root 'Take Control Agent\uninstall.exe'); Args = '/S'; Label = 'Take Control Agent'
        })

        foreach ($vendorDir in @('MspPlatform', 'SolarWinds MSP', 'N-able', 'Advanced Monitoring Agent')) {
            $vendorRoot = Join-Path $root $vendorDir
            foreach ($dir in @(Get-ChildItem -LiteralPath $vendorRoot -Directory -ErrorAction SilentlyContinue)) {
                $unins = @(Get-ChildItem -LiteralPath $dir.FullName -Filter 'unins*.exe' -File `
                    -ErrorAction SilentlyContinue)
                foreach ($exe in $unins) {
                    $found.Add(@{ Path = $exe.FullName; Args = $script:InnoArgs; Label = "$vendorDir\$($dir.Name)" })
                }
            }
        }
    }
    return $found
}

function Invoke-VendorUninstall {
    # Phase 1: vendor uninstallers, registered entries first, then known uninstallers on disk.
    # Each entry is isolated: one bad registry value must not stop phases 2 and 3, which do the real work.
    param ([Parameter(Mandatory)]$Inventory)

    Write-Log '==== Phase 1: vendor uninstallers ====' -Level 'INFO'

    foreach ($entry in ($Inventory.UninstallEntries | Sort-Object Priority, DisplayName)) {
        if ($entry.IsMav -and -not $IncludeManagedAntivirus) {
            Write-Log "Managed AV left in place: $($entry.DisplayName) (use -IncludeManagedAntivirus)" -Level 'WARNING'
            continue
        }
        try {
            Invoke-EntryUninstall -Entry $entry
        }
        catch {
            $script:FailureCount++
            $reason = $_.Exception.Message
            Write-Log "Uninstall step failed for '$($entry.DisplayName)' ($($entry.KeyName)): $reason" -Level 'ERROR'
        }
    }

    try {
        foreach ($item in (Get-OnDiskUninstaller)) {
            if (-not (Test-Path -LiteralPath $item.Path -ErrorAction SilentlyContinue)) { continue }
            if (Test-Protected -Value @($item.Path)) { continue }
            Invoke-Uninstaller -FilePath $item.Path -Arguments $item.Args -Label $item.Label
        }
    }
    catch {
        $script:FailureCount++
        Write-Log "On-disk uninstaller sweep failed: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Stop-NableComponent {
    # Phase 2: disable and stop services (watchers first), then kill processes.
    Write-Log '==== Phase 2: stop services and processes ====' -Level 'INFO'

    $watchersFirst = @{ Expression = 'IsWatcher'; Descending = $true }
    $services = @(Get-NableService | Where-Object { -not $_.IsMav } | Sort-Object $watchersFirst, Name)

    foreach ($svc in $services) {
        $name = $svc.Name
        $null = Invoke-Action -Description "Disable service '$name'" -Action {
            $out = & sc.exe config "$name" start= disabled 2>&1
            if ($LASTEXITCODE -ne 0) { throw "sc.exe config returned $LASTEXITCODE : $out" }
        }
    }
    foreach ($svc in $services) {
        if ($svc.State -eq 'Stopped') { continue }
        $name = $svc.Name
        $svcPid = $svc.ProcessId
        $svcPath = $svc.PathName
        $null = Invoke-Action -Description "Stop service '$name'" -Action {
            & sc.exe stop "$name" 2>&1 | Out-Null
            $deadline = (Get-Date).AddSeconds(30)
            do {
                Start-Sleep -Milliseconds 500
                $current = Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
                $state = $current.State
            } while ($state -and $state -ne 'Stopped' -and (Get-Date) -lt $deadline)

            # Kill the host process only if it is the N-able binary itself, never a shared host.
            if ($state -and $state -ne 'Stopped' -and $svcPid -gt 0 -and $svcPath -match $script:PathPattern) {
                Stop-Process -Id $svcPid -Force -ErrorAction Stop
            }
        }
    }

    foreach ($proc in Get-NableProcess) {
        $procId = $proc.Id
        $null = Invoke-Action -Description "Kill process $($proc.Name) [$procId] $($proc.Path)" -Action {
            Stop-Process -Id $procId -Force -ErrorAction Stop
        }
    }
}

function Remove-NableFolder {
    param ([Parameter(Mandatory)][string]$Path)

    $null = Invoke-Action -Description "Delete folder '$Path'" -Action {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        catch {
            # Locked files (loaded drivers, in-use DLLs): queue them, then the empty folders, for reboot.
            $queued = 0
            foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)) {
                try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop }
                catch { if (Register-DeleteOnReboot -Path $file.FullName) { $queued++ } }
            }
            $dirs = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending)
            foreach ($dir in $dirs) {
                try { Remove-Item -LiteralPath $dir.FullName -Force -Recurse -ErrorAction Stop }
                catch { $null = Register-DeleteOnReboot -Path $dir.FullName }
            }
            try { Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop }
            catch {
                if (-not (Register-DeleteOnReboot -Path $Path)) { throw }
                Write-Log "Folder '$Path' queued for deletion at reboot ($queued locked files)" -Level 'WARNING'
            }
        }
    }
}

function Remove-NableArtifact {
    # Phase 3: forced cleanup of everything the uninstallers left.
    Write-Log '==== Phase 3: forced cleanup ====' -Level 'INFO'
    $inv = Get-NableInventory

    foreach ($svc in ($inv.Services | Where-Object { -not $_.IsMav })) {
        $name = $svc.Name
        $null = Invoke-Action -Description "Delete service '$name'" -Action {
            $out = & sc.exe delete "$name" 2>&1
            $code = $LASTEXITCODE
            # 1060 = service does not exist; 1072 = already marked for deletion.
            if ($code -notin 0, 1060, 1072) { throw "sc.exe delete returned $code : $out" }
            # A service that still runs is only marked for deletion. The SCM removes it at reboot.
            if (Get-CimInstance -ClassName Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue) {
                $script:PendingServices.Add($name)
                $script:RebootRequired = $true
                Write-Log "Service '$name' is marked for deletion and goes away at reboot" -Level 'WARNING'
            }
        }
    }
    $deletedServices = @($inv.Services | ForEach-Object { $_.Name })

    foreach ($task in $inv.ScheduledTasks) {
        $taskName = $task.TaskName
        $taskPath = $task.TaskPath
        $null = Invoke-Action -Description "Delete scheduled task '$taskPath$taskName'" -Action {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
        }
    }

    foreach ($rule in $inv.FirewallRules) {
        $ruleName = $rule.Name
        $null = Invoke-Action -Description "Delete firewall rule '$($rule.DisplayName)'" -Action {
            Remove-NetFirewallRule -Name $ruleName -ErrorAction Stop
        }
    }

    # Kill anything that restarted after phase 2, then delete files.
    foreach ($proc in Get-NableProcess) {
        $procId = $proc.Id
        $null = Invoke-Action -Description "Kill process $($proc.Name) [$procId]" -Action {
            Stop-Process -Id $procId -Force -ErrorAction Stop
        }
    }
    foreach ($folder in $inv.Folders) { Remove-NableFolder -Path $folder }

    # Only orphan keys and drivers here: sc.exe delete above already removed the keys of normal services.
    foreach ($key in ($inv.ServiceKeys | Where-Object { $deletedServices -notcontains $_.Name })) {
        $keyPath = $key.KeyPath
        $isDriver = $key.ImagePath -match '(?i)\.sys\b'
        $null = Invoke-Action -Description "Delete service key '$($key.Name)' ($($key.ImagePath))" -Action {
            Remove-RegistryKey -Path $keyPath
            if ($isDriver) { $script:RebootRequired = $true }   # A loaded driver stays in memory until reboot.
        }
    }

    foreach ($entry in ($inv.UninstallEntries | Where-Object { -not $_.IsMav })) {
        $keyPath = $entry.KeyPath
        $entryDescription = "Delete uninstall entry '$($entry.DisplayName)' ($($entry.KeyName))"
        $null = Invoke-Action -Description $entryDescription -Action {
            Remove-RegistryKey -Path $keyPath
        }
    }

    foreach ($keyPath in $inv.RegistryKeys) {
        $null = Invoke-Action -Description "Delete registry key '$keyPath'" -Action {
            Remove-RegistryKey -Path $keyPath
        }
    }

    if ($inv.AssetWmiClass) {
        $null = Invoke-Action -Description 'Delete WMI class root\cimv2:NCentralAsset (N-central asset tag)' -Action {
            ([wmiclass]'root\cimv2:NCentralAsset').Delete()
        }
    }

    Remove-PassportalLsaHook
}

function Remove-PassportalLsaHook {
    $lsaKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $valueName = 'Notification Packages'
    $lsa = Get-ItemProperty -LiteralPath $lsaKey -Name $valueName -ErrorAction SilentlyContinue
    $packages = @($lsa.$valueName)
    if ($packages -notcontains 'adpasswordchangenotifier') { return }

    if (-not $RemovePassportalLsaHook) {
        $script:ManualItems.Add(
            "Passportal LSA hook 'adpasswordchangenotifier' is still registered (use -RemovePassportalLsaHook).")
        Write-Log 'Passportal LSA notification package present; left in place' -Level 'WARNING'
        return
    }

    $remaining = [string[]]@($packages | Where-Object { $_ -and $_ -ne 'adpasswordchangenotifier' })
    $null = Invoke-Action -Description "Remove 'adpasswordchangenotifier' from LSA Notification Packages" -Action {
        Set-ItemProperty -LiteralPath $lsaKey -Name $valueName -Value $remaining -Type MultiString -ErrorAction Stop
        $script:RebootRequired = $true
    }
    $dll = Join-Path $env:WINDIR 'System32\adpasswordchangenotifier.dll'
    if (Test-Path -LiteralPath $dll) {
        $null = Invoke-Action -Description "Queue '$dll' for deletion at reboot" -Action {
            if (-not (Register-DeleteOnReboot -Path $dll)) { throw 'MoveFileEx failed' }
        }
    }
}

function Write-FollowUpReport {
    param ([Parameter(Mandatory)]$Inventory)

    $mavLeft = @($Inventory.UninstallEntries | Where-Object { $_.IsMav }).Count +
        @($Inventory.Services | Where-Object { $_.IsMav }).Count
    if ($mavLeft -gt 0) {
        $script:ManualItems.Add('N-able Managed Antivirus is present. Remove it with the N-able MAV tool in Safe Mode.')
    }

    # Bitdefender alone is not a failure: another MSP's GravityZone is common on inherited devices.
    # It is a manual item only when N-able MAV is also present.
    $bitdefender = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { "$($_.PathName)" -match '(?i)\\Bitdefender' })
    if ($bitdefender.Count -gt 0) {
        $bdMessage = "Bitdefender services found ($($bitdefender.Count)). Not touched."
        if ($mavLeft -gt 0) {
            $script:ManualItems.Add("$bdMessage They are probably N-able MAV: use the MAV uninstall tool.")
        }
        else {
            Write-Log $bdMessage -Level 'INFO'
        }
    }

    $s1 = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^Sentinel' -or "$($_.PathName)" -match '(?i)\\SentinelOne\\' })
    if ($s1.Count -gt 0) {
        Write-Log ('SentinelOne is installed and was not touched. If this device had N-able EDR, check in the S1 ' +
            'console that the agent reports to our site, not the previous MSP site.') -Level 'WARNING'
    }

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate') {
        Write-Log ('Windows Update policy keys exist (HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate). ' +
            'N-able patching can leave these behind. Not changed: NinjaOne patching uses the same keys.') -Level 'INFO'
    }
}

#endregion

#region Script Body

$exitCode = 0
try {
    Initialize-Script

    $before = Get-NableInventory
    $foundCount = Get-InventoryCount -Inventory $before
    if ($foundCount -eq 0) {
        Write-Log 'No N-able artifacts found.' -Level 'SUCCESS'
        Write-FollowUpReport -Inventory $before
    }
    else {
        Write-Inventory -Inventory $before -Heading "Discovery: $foundCount N-able artifacts"

        Invoke-VendorUninstall -Inventory $before
        Stop-NableComponent
        Remove-NableArtifact

        Write-Log '==== Phase 4: verification ====' -Level 'INFO'
        $after = Get-NableInventory
        Write-FollowUpReport -Inventory $after

        if ($script:DryRun) {
            Write-Log "DRYRUN complete: $foundCount artifacts found. No changes made." -Level 'SUCCESS'
        }
        else {
            $remaining = Get-InventoryCount -Inventory $after -ExcludeMav
            if ($remaining -gt 0) {
                Write-Inventory -Inventory $after -Heading "Remaining after removal: $remaining"
                Write-Log "$remaining N-able artifacts remain. See the list above and the log." -Level 'ERROR'
                $exitCode = 50
            }
            else {
                $doneMessage = "All $foundCount N-able artifacts removed. " +
                    "Errors during the run: $($script:FailureCount)"
                Write-Log $doneMessage -Level 'SUCCESS'
            }
        }
    }

    foreach ($item in $script:ManualItems) { Write-Log "MANUAL: $item" -Level 'WARNING' }
    if ($script:ManualItems.Count -gt 0 -and -not $script:DryRun) { $exitCode = 50 }

    foreach ($path in $script:PendingReboot) { Write-Log "Deleted at next reboot: $path" -Level 'INFO' }
    if ($script:RebootRequired) {
        Write-Log 'A reboot is required to finish the removal. This script does not reboot.' -Level 'WARNING'
    }
}
catch {
    Write-Log "Script failed: $($_.Exception.Message)" -Level 'ERROR'
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
    $exitCode = 1
}
finally {
    $duration = (Get-Date) - $scriptStartTime
    Write-Log "Total duration: $($duration.ToString('hh\:mm\:ss\.fff')) - exit code $exitCode" -Level 'INFO'
}

exit $exitCode

#endregion
