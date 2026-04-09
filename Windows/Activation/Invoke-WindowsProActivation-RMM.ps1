# Step 2: Activate Windows 11 Pro with Your Product Key
# Run this script as Administrator AFTER rebooting from Step 1

# ========================================
# Create a Variable in the Ninja Script called "Product Key" it will auto-shorten to productKey
# ========================================
$productKey = "$env:productKey"
# ========================================

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Windows 11 Pro Activation - Step 2" -ForegroundColor Cyan
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
Write-Host ""

if ($currentEdition -notlike "*Pro*") {
    Write-Host "WARNING: Windows edition is not Pro yet." -ForegroundColor Yellow
    Write-Host "Please make sure Step 1 completed successfully and you rebooted." -ForegroundColor Yellow
    Write-Host ""
}

# Get activation status
$licenseStatus = (Get-CimInstance -ClassName SoftwareLicensingProduct | Where-Object {$_.PartialProductKey -and $_.Name -like "*Windows*"}).LicenseStatus

Write-Host "Current License Status:" -ForegroundColor White
switch ($licenseStatus) {
    0 { Write-Host "  Unlicensed" -ForegroundColor Red }
    1 { Write-Host "  Licensed (Activated)" -ForegroundColor Green }
    2 { Write-Host "  Out-of-Box Grace Period" -ForegroundColor Yellow }
    3 { Write-Host "  Out-of-Tolerance Grace Period" -ForegroundColor Yellow }
    4 { Write-Host "  Non-Genuine Grace Period" -ForegroundColor Yellow }
    5 { Write-Host "  Notification" -ForegroundColor Yellow }
    6 { Write-Host "  Extended Grace" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "Using Product Key: $productKey" -ForegroundColor White
Write-Host ""

# Validate format (basic check)
if ($productKey -eq "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" -or $productKey -notmatch "^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$") {
    Write-Host "ERROR: Product key not configured or format is invalid." -ForegroundColor Red
    Write-Host "Expected format: XXXXX-XXXXX-XXXXX-XXXXX-XXXXX" -ForegroundColor Red
    Write-Host "Please edit the script and set the correct product key at the top." -ForegroundColor Yellow
    Write-Host ""
    pause
    exit
}

Write-Host "Installing product key..." -ForegroundColor Green

try {
    # Install the product key
    $result = cscript //nologo C:\Windows\System32\slmgr.vbs /ipk $productKey 2>&1
    Write-Host $result -ForegroundColor White
    
    Start-Sleep -Seconds 2
    
    Write-Host ""
    Write-Host "Activating Windows..." -ForegroundColor Green
    
    # Activate Windows
    $activateResult = cscript //nologo C:\Windows\System32\slmgr.vbs /ato 2>&1
    Write-Host $activateResult -ForegroundColor White
    
    Start-Sleep -Seconds 2
    
    Write-Host ""
    Write-Host "Checking activation status..." -ForegroundColor Green
    Start-Sleep -Seconds 3
    
    # Check final activation status
    $finalStatus = (Get-CimInstance -ClassName SoftwareLicensingProduct | Where-Object {$_.PartialProductKey -and $_.Name -like "*Windows*"}).LicenseStatus
    
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    
    if ($finalStatus -eq 1) {
        Write-Host "SUCCESS! Windows 11 Pro is now activated!" -ForegroundColor Green
    } else {
        Write-Host "Activation may not be complete." -ForegroundColor Yellow
        Write-Host "Please check your activation status in Settings > System > Activation" -ForegroundColor Yellow
    }
    
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "You can verify activation in:" -ForegroundColor White
    Write-Host "  Settings > System > Activation" -ForegroundColor White
    Write-Host ""
    
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to activate Windows" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "- Verify your product key is correct" -ForegroundColor White
    Write-Host "- Ensure you have an internet connection" -ForegroundColor White
    Write-Host "- Check Settings > System > Activation for more details" -ForegroundColor White
    Write-Host ""
}

pause