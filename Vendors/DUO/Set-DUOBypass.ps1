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

<#
.SYNOPSIS
    Enhanced PowerShell script to backup hosts file and add a DUO Security API bypass redirect

.DESCRIPTION
    This script automatically extracts the DUO Security API domain from the log file
    and creates a localhost redirect in the Windows hosts file. It creates timestamped
    backups and maintains a restoration log for easy recovery.

    This is designed to bypass DUO when it's in a fail open configuration state. This will NOT work
    if DUO is in a fail closed configuration state.

.PARAMETER None
    This script does not accept parameters

.EXAMPLE
    .\DUO_Bypass.ps1
    Run the script as Administrator to automatically configure hosts file redirect and bypass DUO.

.NOTES
    - Must be run as Administrator
    - Creates backup of hosts file with timestamp
    - Logs restoration commands to C:\Windows\System32\drivers\etc\hosts_restore.log
    - Automatically flushes DNS cache after modification
    - Requires DUO Security active log file

.LINK
    https://docs.microsoft.com/en-us/powershell/
#>

$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$BackupFile = "$env:SystemRoot\System32\drivers\etc\hosts.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$DUOLogFile = "C:\ProgramData\DUO Security\dUO.log"

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Please run as Administrator" -ForegroundColor Red
    exit 1
}

# Check if DUO log file exists
if (-not (Test-Path $DUOLogFile)) {
    Write-Host "DUO log file not found: $DUOLogFile" -ForegroundColor Red
    Write-Host "Please ensure DUO Security is installed and has generated log entries." -ForegroundColor Yellow
    exit 1
}

# Extract domain from DUO log file
Write-Host "Searching for DUO API domain in log file..."
try {
    $LogContent = Get-Content $DUOLogFile -ErrorAction Stop
    $HostLine = $LogContent | Select-String "Host:" | Select-Object -Last 1
    
    if (-not $HostLine) {
        Write-Host "No 'Host:' entries found in the log file" -ForegroundColor Red
        Write-Host "Please ensure DUO Security has made API calls that are logged." -ForegroundColor Yellow
        exit 1
    }
    
    # Extract the domain from the Host: line
    # Looking for patterns like "Host: api-xxxxxxxx.dUOsecurity.com"
    if ($HostLine -match "Host:\s*([a-zA-Z0-9\-]+\.dUOsecurity\.com)") {
        $Domain = $matches[1]
        Write-Host "Found DUO API domain: $Domain" -ForegroundColor Green
    } else {
        Write-Host "Could not extract domain from Host line: $HostLine" -ForegroundColor Red
        Write-Host "Expected format: Host: api-xxxxxxxx.dUOsecurity.com" -ForegroundColor Yellow
        exit 1
    }
} catch {
    Write-Host "Failed to read log file: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Create backup
Write-Host "Creating backup of hosts file..."
try {
    Copy-Item $HostsFile $BackupFile
    Write-Host "Backup created: $BackupFile" -ForegroundColor Green
} catch {
    Write-Host "Failed to create backup: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Check if entry already exists
$HostsContent = Get-Content $HostsFile
if ($HostsContent | Select-String $Domain) {
    Write-Host "Entry for $Domain already exists in hosts file" -ForegroundColor Yellow
    Write-Host "Current entry:" -ForegroundColor Cyan
    $HostsContent | Select-String $Domain | ForEach-Object { Write-Host "  $($_.Line)" -ForegroundColor Cyan }
    exit 0
}

# Add the entry
Write-Host "Adding $Domain to hosts file..."
try {
    Add-Content -Path $HostsFile -Value "127.0.0.1    $Domain"
    Write-Host "Done! $Domain now redirects to localhost" -ForegroundColor Green
    Write-Host "To restore original hosts file, run: Copy-Item '$BackupFile' '$HostsFile' -Force" -ForegroundColor Cyan
    
    # Log the restoration command for reference
    $LogFile = "$env:SystemRoot\System32\drivers\etc\hosts_restore.log"
    $LogEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Backup: $BackupFile | Restore Command: Copy-Item '$BackupFile' '$HostsFile' -Force"
    Add-Content -Path $LogFile -Value $LogEntry
    Write-Host "Restoration command logged to: $LogFile" -ForegroundColor Gray
    
    # Flush DNS cache
    Write-Host "Flushing DNS cache..."
    ipconfig /flushdns | Out-Null
    Write-Host "DNS cache flushed" -ForegroundColor Green
    
    # Display current hosts file content
    Write-Host "`nCurrent hosts file content:" -ForegroundColor Yellow
    Write-Host "=" * 50 -ForegroundColor Yellow
    Get-Content $HostsFile | ForEach-Object { Write-Host $_ }
    Write-Host "=" * 50 -ForegroundColor Yellow
} catch {
    Write-Host "Failed to modify hosts file: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}