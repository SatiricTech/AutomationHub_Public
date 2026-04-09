# Step 1: Upgrade Windows 11 Home to Pro (Automated)
# Run this script as Administrator

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Windows 11 Home to Pro Upgrade - Step 1" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator!" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    pause
    exit
}

# Check current Windows edition
$currentEdition = (Get-WindowsEdition -Online).Edition
Write-Host "Current Edition: $currentEdition" -ForegroundColor Yellow

if ($currentEdition -notlike "*Home*" -and $currentEdition -notlike "*Core*") {
    Write-Host "This system is not running Windows Home or Core edition." -ForegroundColor Red
    Write-Host "Current edition: $currentEdition" -ForegroundColor Red
    pause
    exit
}

Write-Host ""
Write-Host "Starting automated upgrade to Windows 11 Pro..." -ForegroundColor Green
Write-Host ""

# Generic Windows 11 Pro upgrade key
$upgradeKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"

try {
    # Start the License Manager service
    Write-Host "[1/4] Starting License Manager service..." -ForegroundColor Cyan
    sc.exe config LicenseManager start= auto | Out-Null
    net start LicenseManager | Out-Null
    Start-Sleep -Seconds 2
    Write-Host "      License Manager started" -ForegroundColor Green
    
    # Start Windows Update service
    Write-Host "[2/4] Starting Windows Update service..." -ForegroundColor Cyan
    sc.exe config wuauserv start= auto | Out-Null
    net start wuauserv | Out-Null
    Start-Sleep -Seconds 2
    Write-Host "      Windows Update started" -ForegroundColor Green
    
    # Execute the upgrade using changepk.exe
    Write-Host "[3/4] Initiating Windows 11 Pro upgrade..." -ForegroundColor Cyan
    Write-Host "      This will take several minutes. Please wait..." -ForegroundColor Yellow
    Write-Host ""
    
    Start-Process "changepk.exe" -ArgumentList "/ProductKey $upgradeKey" -Wait
    
    Start-Sleep -Seconds 3
    
    # Verify the upgrade
    Write-Host ""
    Write-Host "[4/4] Verifying upgrade..." -ForegroundColor Cyan
    $newEdition = (Get-WindowsEdition -Online).Edition
    Write-Host "      New Edition: $newEdition" -ForegroundColor White
    
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    
    if ($newEdition -like "*Pro*") {
        Write-Host "SUCCESS! Windows 11 Pro upgrade complete!" -ForegroundColor Green
    } else {
        Write-Host "Upgrade initiated. Edition will change after reboot." -ForegroundColor Yellow
    }
    
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "After reboot:" -ForegroundColor White
    Write-Host "  1. Log back into Windows" -ForegroundColor White
    Write-Host "  2. Verify you're on Windows 11 Pro (Settings > System > About)" -ForegroundColor White
    Write-Host "  3. Run Step 2 script to activate with your Pro key" -ForegroundColor White
    Write-Host ""
    
    # Wait 5 seconds before rebooting
    Write-Host "System will reboot in 5 seconds..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5
    
    Write-Host "REBOOTING NOW..." -ForegroundColor Red
    
    # Reboot the computer
    Restart-Computer -Force
    
} catch {
    Write-Host ""
    Write-Host "ERROR: An error occurred during the upgrade process" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Manual upgrade steps:" -ForegroundColor Yellow
    Write-Host "  1. Open Command Prompt as Administrator" -ForegroundColor White
    Write-Host "  2. Run: sc config LicenseManager start= auto && net start LicenseManager" -ForegroundColor White
    Write-Host "  3. Run: sc config wuauserv start= auto && net start wuauserv" -ForegroundColor White
    Write-Host "  4. Run: changepk.exe /ProductKey $upgradeKey" -ForegroundColor White
    Write-Host "  5. Wait for the upgrade to complete and reboot" -ForegroundColor White
    Write-Host ""
    pause
}