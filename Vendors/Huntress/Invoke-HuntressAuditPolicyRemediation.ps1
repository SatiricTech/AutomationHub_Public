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
# Description: Detect & Remediate for Huntress SIEM Windows audit baseline.
#              Built for unattended RMM/automation deployment.
#
#              Parameters:
#                -Mode Detect      : report drift only, no changes
#                -Mode Remediate   : detect + apply changes (default)
#                -NoHuntressEDR    : set Process Creation to Success (default
#                                    is No Auditing, since EDR covers it)
#
#              Exit codes:
#                0 = compliant (no drift, no action taken)
#                1 = drift detected (Detect) OR drift remediated (Remediate)
#                2 = failure during remediation
#
#              Reference:
#              https://support.huntress.io/hc/en-us/articles/49363914702867-Enforcing-Windows-Logging-Audit-Policies
#############################

#############################
# Huntress Audit Policy - Detect & Remediate (RMM)
#############################

#!ps
#timeout=180000

param(
    [ValidateSet('Detect','Remediate')]
    [string]$Mode = 'Remediate',

    [switch]$NoHuntressEDR
)

#############################
# Config
#############################
$OrgFolder = 'SentinelCyber'
$LogDir    = "C:\ProgramData\$OrgFolder\Logs"
$LogFile   = Join-Path $LogDir 'Invoke-HuntressAuditPolicyRemediation.log'
$SecurityLogMaxKB = 512000

#############################
# Huntress Advanced Audit Policy baseline (subcategory -> Success/Failure)
#############################
$ProcessCreationSetting = if ($NoHuntressEDR) { @{ Success = 'enable';  Failure = 'disable' } } `
                                         else { @{ Success = 'disable'; Failure = 'disable' } }

$AuditBaseline = @(
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
    @{ Name = 'Account Lockout';                    Success = 'disable'; Failure = 'enable'  }
    @{ Name = 'Filtering Platform Connection';      Success = 'disable'; Failure = 'enable'  }
    @{ Name = 'Process Creation';                   Success = $ProcessCreationSetting.Success; Failure = $ProcessCreationSetting.Failure }

    # No Auditing
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
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa';
       Name = 'SCENoApplyLegacyAuditPolicy'; Type = 'DWord'; Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa';
       Name = 'AuditBaseObjects'; Type = 'DWord'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit';
       Name = 'ProcessCreationIncludeCmdLine_Enabled'; Type = 'DWord'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging';
       Name = 'EnableScriptBlockLogging'; Type = 'DWord'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging';
       Name = 'EnableModuleLogging'; Type = 'DWord'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames';
       Name = '*'; Type = 'String'; Value = '*' }
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
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','DRIFT','FIX')] [string]$Level = 'INFO')
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

function Get-AuditDrift {
    $drift = @()
    foreach ($item in $AuditBaseline) {
        $current = Get-AuditSubcategoryState -Subcategory $item.Name
        if (-not $current) { continue }
        $wantSuccess = ($item.Success -eq 'enable')
        $wantFailure = ($item.Failure -eq 'enable')
        if ($current.SuccessEnabled -ne $wantSuccess -or $current.FailureEnabled -ne $wantFailure) {
            $drift += [pscustomobject]@{
                Item = $item.Name; Current = $current.Raw
                Desired = "S=$($item.Success) F=$($item.Failure)"; Ref = $item
            }
        }
    }
    return $drift
}

function Get-RegistryDrift {
    $drift = @()
    foreach ($item in $RegistryBaseline) {
        $current = $null
        if (Test-Path -LiteralPath $item.Path) {
            $current = (Get-ItemProperty -LiteralPath $item.Path -Name $item.Name -ErrorAction SilentlyContinue).$($item.Name)
        }
        if ($null -eq $current -or $current -ne $item.Value) {
            $drift += [pscustomobject]@{
                Item = "$($item.Path)\$($item.Name)"
                Current = if ($null -eq $current) { '<missing>' } else { $current }
                Desired = $item.Value; Ref = $item
            }
        }
    }
    return $drift
}

function Get-SecurityLogDrift {
    try {
        $log = Get-WinEvent -ListLog Security -ErrorAction Stop
        $maxKB = [int]($log.MaximumSizeInBytes / 1KB)
        if ($maxKB -lt $SecurityLogMaxKB -or $log.LogMode -ne 'Circular') {
            return [pscustomobject]@{
                Item = 'Security log (size/mode)'
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
        Write-Log "audit fixed '$($Item.Name)' -> S=$($Item.Success) F=$($Item.Failure)" 'FIX'
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
        Write-Log "reg fixed '$($Item.Path)\$($Item.Name)' = $($Item.Value)" 'FIX'
        return $true
    } catch {
        Write-Log "reg FAIL '$($Item.Path)\$($Item.Name)' :: $_" 'ERROR'
        return $false
    }
}

function Set-SecurityLogBaseline {
    try {
        Limit-EventLog -LogName Security -MaximumSize ($SecurityLogMaxKB * 1KB) -OverflowAction OverwriteAsNeeded -ErrorAction Stop
        Write-Log "Security log fixed -> $SecurityLogMaxKB KB / OverwriteAsNeeded" 'FIX'
        return $true
    } catch {
        Write-Log "Security log FAIL :: $_" 'ERROR'
        return $false
    }
}

#############################
# Main
#############################
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

Write-Log "=== Huntress Audit Policy ($Mode) on $env:COMPUTERNAME (EDR-mode: $(-not $NoHuntressEDR)) ===" 'INFO'

if (-not (Test-IsAdmin)) {
    Write-Log "Must run elevated. Aborting." 'ERROR'
    exit 2
}

$auditDrift = Get-AuditDrift
$regDrift   = Get-RegistryDrift
$logDrift   = Get-SecurityLogDrift
$totalDrift = $auditDrift.Count + $regDrift.Count + $(if ($logDrift) { 1 } else { 0 })

if ($totalDrift -eq 0) {
    Write-Log "Compliant. No drift detected." 'OK'
    exit 0
}

Write-Log "Drift: $($auditDrift.Count) audit / $($regDrift.Count) registry / $(if($logDrift){'1'}else{'0'}) event-log" 'DRIFT'
foreach ($d in $auditDrift) { Write-Log "  audit '$($d.Item)' has '$($d.Current)' want '$($d.Desired)'" 'DRIFT' }
foreach ($d in $regDrift)   { Write-Log "  reg '$($d.Item)' has '$($d.Current)' want '$($d.Desired)'" 'DRIFT' }
if ($logDrift)              { Write-Log "  $($logDrift.Item) has '$($logDrift.Current)' want '$($logDrift.Desired)'" 'DRIFT' }

if ($Mode -eq 'Detect') {
    Write-Log "Detect mode: exiting without remediation." 'INFO'
    exit 1
}

$failed = 0
$fixed  = 0
foreach ($d in $auditDrift) {
    if (Set-AuditSubcategory -Item $d.Ref) { $fixed++ } else { $failed++ }
}
foreach ($d in $regDrift) {
    if (Set-RegistryValueEnsured -Item $d.Ref) { $fixed++ } else { $failed++ }
}
if ($logDrift) {
    if (Set-SecurityLogBaseline) { $fixed++ } else { $failed++ }
}

if ($failed -gt 0) {
    Write-Log "Remediation finished: $fixed fixed, $failed failed. Log: $LogFile" 'ERROR'
    exit 2
}

Write-Log "Remediation finished: $fixed item(s) corrected." 'OK'
exit 1
