#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!#
#  ╔═══╗ ╔═══╗ ╔═╗ ╔╗ ╔════╗ ╔══╗ ╔═╗ ╔╗ ╔═══╗ ╔╗     #
#  ║╔═╗║ ║╔══╝ ║║╚╗║║ ║╔╗╔╗║ ╚╣╠╝ ║║╚╗║║ ║╔══╝ ║║     #
#  ║╚══╗ ║╚══╗ ║╔╗╚╝║ ╚╝║║╚╝  ║║  ║╔╗╚╝║ ║╚══╗ ║║     #
#  ╚══╗║ ║╔══╝ ║║╚╗║║   ║║    ║║  ║║╚╗║║ ║╔══╝ ║║     #
#  ║╚═╝║ ║╚══╗ ║║ ║║║  ╔╝╚╗  ╔╣╠╗ ║║ ║║║ ║╚══╗ ║╚══╗  #
#  ╚═══╝ ╚═══╝ ╚╝ ╚═╝  ╚══╝  ╚══╝ ╚╝ ╚═╝ ╚═══╝ ╚═══╝  #
#>>>>>>>>>>>>>>>>>>>> [SYSTEM::ACTIVE] <<<<<<<<<<<<<<<<<<<<<<<<#
#######################CYBER DEFENSE ###########################
#####################╔═╗╔═╗╔═╗╔ ╗╦═╗╔═╗#########################
#####################╚═╗║╣ ║  ║ ║╠╦╝║╣ #########################
#####################╚═╝╚═╝╚═╝╚═╝╩╚═╚═╝#########################
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!#

#############################
# Author: Ramon DeWitt
# Last Updated: 2026-05-23
# Version: 1.0
# Description: Ad-hoc enforcement of the Huntress SIEM-recommended Windows
#              Advanced Audit Policy baseline + recommended hardening
#              (security log size/retention, PowerShell logging, command-line
#              auditing, AuditBaseObjects). Interactive: shows drift, asks
#              before changing. Use -Force to skip the prompt, -ShowOnly to
#              report drift without modifying anything.
#
#              Reference:
#              https://support.huntress.io/hc/en-us/articles/49363914702867-Enforcing-Windows-Logging-Audit-Policies
#
#              Notes:
#              - "Process Creation" defaults to No Auditing (Huntress EDR
#                covers process telemetry). Pass -NoHuntressEDR to set it
#                to Success instead.
#              - By default, this script removes local Group Policy
#                audit.csv files (backed up first) so the auditpol baseline
#                isn't overwritten on the next GP refresh / reboot. This is
#                the "Alternative" path from the Huntress article. Pass
#                -KeepLocalGPOAudit to skip the removal if you actively
#                manage audit policy via Local Group Policy Editor.
#              - Reboot is NOT required; auditpol changes apply immediately.
#              - This script does NOT touch domain GPO. If a domain GPO is
#                pushing different audit settings, those will reapply at
#                next refresh.
#############################

#############################
# Huntress Audit Policy - Ad-Hoc Enforcement
#############################

#!ps
#timeout=180000

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$Force,
    [switch]$ShowOnly,
    [switch]$NoHuntressEDR,
    [switch]$KeepLocalGPOAudit
)

#############################
# Config
#############################
$OrgFolder = 'SentinelCyber'
$LogDir    = "C:\ProgramData\$OrgFolder\Logs"
$LogFile   = Join-Path $LogDir 'Set-HuntressAuditPolicy.log'
$BackupRoot = "C:\ProgramData\$OrgFolder\Backups"

# Local GPO audit.csv locations (article: "Common Issues" / "Alternative")
$LocalGPOAuditCsvFiles = @(
    'C:\Windows\security\audit\audit.csv'
    'C:\Windows\System32\GroupPolicy\Machine\Microsoft\WindowsNT\Audit\audit.csv'
)

# Recommended Security log size from the article (512 MB)
$SecurityLogMaxKB = 512000

#############################
# Huntress Advanced Audit Policy baseline (subcategory -> Success/Failure)
# Names match auditpol.exe /list /subcategory:* output.
#############################
$ProcessCreationSetting = if ($NoHuntressEDR) { @{ Success = 'enable';  Failure = 'disable' } } `
                                         else { @{ Success = 'disable'; Failure = 'disable' } }

$AuditBaseline = @(
    # Success + Failure
    @{ Name = 'Credential Validation';              Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Kerberos Authentication Service';    Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Kerberos Service Ticket Operations'; Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Computer Account Management';        Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Distribution Group Management';      Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Security Group Management';          Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'User Account Management';            Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Directory Service Access';           Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Logon';                              Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Network Policy Server';              Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Other Logon/Logoff Events';          Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Detailed File Share';                Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'File Share';                         Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Kernel Object';                      Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Other Object Access Events';         Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Removable Storage';                  Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'MPSSVC Rule-Level Policy Change';    Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Other Policy Change Events';         Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Sensitive Privilege Use';            Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'Other System Events';                Success = 'enable';  Failure = 'enable'  }
    @{ Name = 'System Integrity';                   Success = 'enable';  Failure = 'enable'  }

    # Success only
    @{ Name = 'Other Account Management Events';    Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Plug and Play Events';               Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Directory Service Changes';          Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Logoff';                             Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Special Logon';                      Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Audit Policy Change';                Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Authentication Policy Change';       Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Authorization Policy Change';        Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Filtering Platform Policy Change';   Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Security State Change';              Success = 'enable';  Failure = 'disable' }
    @{ Name = 'Security System Extension';          Success = 'enable';  Failure = 'disable' }

    # Failure only
    @{ Name = 'Account Lockout';                    Success = 'disable'; Failure = 'enable'  }
    @{ Name = 'Filtering Platform Connection';      Success = 'disable'; Failure = 'enable'  }

    # Process Creation - flips with -NoHuntressEDR
    @{ Name = 'Process Creation';                   Success = $ProcessCreationSetting.Success; Failure = $ProcessCreationSetting.Failure }

    # No Auditing - explicitly disabled to satisfy Huntress baseline (would otherwise show as misconfigured)
    @{ Name = 'Other Account Logon Events';         Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Application Group Management';       Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Process Termination';                Success = 'disable'; Failure = 'disable' }
    @{ Name = 'DPAPI Activity';                     Success = 'disable'; Failure = 'disable' }
    @{ Name = 'RPC Events';                         Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Token Right Adjustment';             Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Detailed Directory Service Replication'; Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Directory Service Replication';      Success = 'disable'; Failure = 'disable' }
    @{ Name = 'User / Device Claims';               Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Group Membership';                   Success = 'disable'; Failure = 'disable' }
    @{ Name = 'IPsec Extended Mode';                Success = 'disable'; Failure = 'disable' }
    @{ Name = 'IPsec Main Mode';                    Success = 'disable'; Failure = 'disable' }
    @{ Name = 'IPsec Quick Mode';                   Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Application Generated';              Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Certification Services';             Success = 'disable'; Failure = 'disable' }
    @{ Name = 'File System';                        Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Filtering Platform Packet Drop';     Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Handle Manipulation';                Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Registry';                           Success = 'disable'; Failure = 'disable' }
    @{ Name = 'SAM';                                Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Central Access Policy Staging';      Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Non Sensitive Privilege Use';        Success = 'disable'; Failure = 'disable' }
    @{ Name = 'Other Privilege Use Events';         Success = 'disable'; Failure = 'disable' }
    @{ Name = 'IPsec Driver';                       Success = 'disable'; Failure = 'disable' }
)

#############################
# Registry baseline
#############################
$RegistryBaseline = @(
    # Force Advanced Audit Policy to override legacy basic audit (article: Common Issues / required for auditpol to stick)
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa';
       Name = 'SCENoApplyLegacyAuditPolicy'; Type = 'DWord'; Value = 1 }

    # "Audit the access of global system objects" -> Disabled. Required so Kernel Object auditing isn't a firehose.
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa';
       Name = 'AuditBaseObjects'; Type = 'DWord'; Value = 0 }

    # Include command line in Event ID 4688 (only meaningful if Process Creation is enabled, harmless otherwise)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit';
       Name = 'ProcessCreationIncludeCmdLine_Enabled'; Type = 'DWord'; Value = 1 }

    # PowerShell Script Block Logging (Event 4104) - main hive
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging';
       Name = 'EnableScriptBlockLogging'; Type = 'DWord'; Value = 1 }

    # PowerShell Module Logging (Event 4103) - main hive
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging';
       Name = 'EnableModuleLogging'; Type = 'DWord'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames';
       Name = '*'; Type = 'String'; Value = '*' }

    # Same values under Wow6432Node (article calls this path out explicitly for the 32-bit PS host)
    @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging';
       Name = 'EnableScriptBlockLogging'; Type = 'DWord'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\PowerShell\ModuleLogging';
       Name = 'EnableModuleLogging'; Type = 'DWord'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames';
       Name = '*'; Type = 'String'; Value = '*' }
)

#############################
# Helpers
#############################
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','DRIFT')] [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AuditSubcategoryState {
    param([string]$Subcategory)
    # auditpol /r output: header row + "Machine,Subcategory,GUID,Setting"
    $raw = & auditpol.exe /get /subcategory:"$Subcategory" /r 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    $row = $raw | Select-Object -Skip 1 | Where-Object { $_ -match ',' } | Select-Object -First 1
    if (-not $row) { return $null }
    $setting = ($row -split ',')[-1].Trim()
    [pscustomobject]@{
        SuccessEnabled = ($setting -match 'Success')
        FailureEnabled = ($setting -match 'Failure')
        Raw            = $setting
    }
}

function Test-AuditDrift {
    $drift = @()
    foreach ($item in $AuditBaseline) {
        $current = Get-AuditSubcategoryState -Subcategory $item.Name
        $wantSuccess = ($item.Success -eq 'enable')
        $wantFailure = ($item.Failure -eq 'enable')
        if (-not $current) {
            # subcategory name not recognized on this OS - skip silently
            continue
        }
        if ($current.SuccessEnabled -ne $wantSuccess -or $current.FailureEnabled -ne $wantFailure) {
            $drift += [pscustomobject]@{
                Item    = $item.Name
                Current = $current.Raw
                Desired = "S=$($item.Success) F=$($item.Failure)"
                Ref     = $item
            }
        }
    }
    return $drift
}

function Test-RegistryDrift {
    $drift = @()
    foreach ($item in $RegistryBaseline) {
        $current = $null
        if (Test-Path -LiteralPath $item.Path) {
            $current = (Get-ItemProperty -LiteralPath $item.Path -Name $item.Name -ErrorAction SilentlyContinue).$($item.Name)
        }
        if ($null -eq $current -or $current -ne $item.Value) {
            $drift += [pscustomobject]@{
                Item    = "$($item.Path)\$($item.Name)"
                Current = if ($null -eq $current) { '<missing>' } else { $current }
                Desired = $item.Value
                Ref     = $item
            }
        }
    }
    return $drift
}

function Test-SecurityLogDrift {
    try {
        $log = Get-WinEvent -ListLog Security -ErrorAction Stop
        $maxKB = [int]($log.MaximumSizeInBytes / 1KB)
        if ($maxKB -lt $SecurityLogMaxKB -or $log.LogMode -ne 'Circular') {
            return [pscustomobject]@{
                Item    = 'Security log (size/mode)'
                Current = "$maxKB KB / $($log.LogMode)"
                Desired = "$SecurityLogMaxKB KB / Circular"
            }
        }
    } catch {
        Write-Log "Could not query Security log: $_" 'WARN'
    }
    return $null
}

function Set-AuditSubcategory {
    param($Item)
    $out = & auditpol.exe /set /subcategory:"$($Item.Name)" /success:$($Item.Success) /failure:$($Item.Failure) 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "audit set '$($Item.Name)' -> S=$($Item.Success) F=$($Item.Failure)" 'OK'
        return $true
    }
    Write-Log "audit FAIL '$($Item.Name)' :: $out" 'ERROR'
    return $false
}

function Set-RegistryValueEnsured {
    param($Item)
    try {
        if (-not (Test-Path -LiteralPath $Item.Path)) {
            New-Item -Path $Item.Path -Force | Out-Null
        }
        New-ItemProperty -Path $Item.Path -Name $Item.Name -Value $Item.Value -PropertyType $Item.Type -Force | Out-Null
        Write-Log "reg set '$($Item.Path)\$($Item.Name)' = $($Item.Value)" 'OK'
        return $true
    } catch {
        Write-Log "reg FAIL '$($Item.Path)\$($Item.Name)' :: $_" 'ERROR'
        return $false
    }
}

function Set-SecurityLogBaseline {
    try {
        Limit-EventLog -LogName Security -MaximumSize ($SecurityLogMaxKB * 1KB) -OverflowAction OverwriteAsNeeded -ErrorAction Stop
        Write-Log "Security log set to $SecurityLogMaxKB KB, OverwriteAsNeeded" 'OK'
        return $true
    } catch {
        Write-Log "Security log FAIL :: $_" 'ERROR'
        return $false
    }
}

function Remove-LocalGPOAuditCsv {
    $present = $LocalGPOAuditCsvFiles | Where-Object { Test-Path -LiteralPath $_ }
    if (-not $present) {
        Write-Log "No local GPO audit.csv files present; nothing to remove." 'INFO'
        return $true
    }
    $backupDir = Join-Path $BackupRoot ("audit-csv-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        foreach ($file in $present) {
            $safeName = ($file -replace '[:\\\/]', '_').TrimStart('_')
            Copy-Item -LiteralPath $file -Destination (Join-Path $backupDir $safeName) -Force
            Rename-Item -LiteralPath $file -NewName ((Split-Path $file -Leaf) + '.bak') -Force
            Write-Log "Backed up + renamed local GPO audit file: $file (backup: $backupDir)" 'OK'
        }
        & gpupdate.exe /force /target:computer 2>&1 | Out-Null
        Write-Log "gpupdate /force completed after audit.csv removal" 'OK'
        return $true
    } catch {
        Write-Log "Failed to remove local GPO audit.csv: $_" 'ERROR'
        return $false
    }
}

#############################
# Main
#############################
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

Write-Log "=== Huntress Audit Policy Enforcement (Ad-Hoc) ===" 'INFO'
Write-Log "Host: $env:COMPUTERNAME  User: $env:USERNAME  EDR-mode: $(-not $NoHuntressEDR)" 'INFO'

if (-not (Test-IsAdmin)) {
    Write-Log "Must run elevated (Administrator)." 'ERROR'
    exit 2
}

$auditDrift = Test-AuditDrift
$regDrift   = Test-RegistryDrift
$logDrift   = Test-SecurityLogDrift

$total = $auditDrift.Count + $regDrift.Count + $(if ($logDrift) { 1 } else { 0 })

if ($total -eq 0) {
    Write-Log "Compliant with Huntress baseline. Nothing to do." 'OK'
    exit 0
}

Write-Log "Drift found: $($auditDrift.Count) audit / $($regDrift.Count) registry / $(if($logDrift){'1'}else{'0'}) event-log" 'DRIFT'
if ($auditDrift) { $auditDrift | Select-Object Item,Current,Desired | Format-Table -AutoSize | Out-String | Write-Host }
if ($regDrift)   { $regDrift   | Select-Object Item,Current,Desired | Format-Table -AutoSize | Out-String | Write-Host }
if ($logDrift)   { $logDrift   | Format-Table -AutoSize | Out-String | Write-Host }

if ($ShowOnly) {
    Write-Log "ShowOnly specified; exiting without changes." 'INFO'
    exit 0
}

if (-not $Force) {
    $answer = Read-Host "Apply the changes above? (y/N)"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Log "User declined. Exiting." 'INFO'
        exit 0
    }
}

$failed = 0

if (-not $KeepLocalGPOAudit) {
    if ($PSCmdlet.ShouldProcess('local GPO audit.csv', 'remove + backup')) {
        if (-not (Remove-LocalGPOAuditCsv)) { $failed++ }
    }
} else {
    Write-Log "KeepLocalGPOAudit specified; leaving audit.csv files in place." 'INFO'
}

foreach ($d in $auditDrift) {
    if ($PSCmdlet.ShouldProcess($d.Item, 'auditpol set')) {
        if (-not (Set-AuditSubcategory -Item $d.Ref)) { $failed++ }
    }
}
foreach ($d in $regDrift) {
    if ($PSCmdlet.ShouldProcess($d.Item, 'registry set')) {
        if (-not (Set-RegistryValueEnsured -Item $d.Ref)) { $failed++ }
    }
}
if ($logDrift -and $PSCmdlet.ShouldProcess('Security log', 'Limit-EventLog')) {
    if (-not (Set-SecurityLogBaseline)) { $failed++ }
}

if ($failed -gt 0) {
    Write-Log "Completed with $failed failure(s). Log: $LogFile" 'ERROR'
    exit 2
}

Write-Log "Remediation complete. Re-run with -ShowOnly to confirm." 'OK'
exit 0
