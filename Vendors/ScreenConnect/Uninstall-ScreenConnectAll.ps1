# Simple script to detect and uninstall ScreenConnect/ConnectWise Control
# Run as administrator

Write-Host "Checking for ScreenConnect/ConnectWise Control..."

# Get installed applications
$apps = Get-WmiObject -Class Win32_Product | Where-Object {
    $_.Name -like "*ScreenConnect*" -or 
    $_.Name -like "*ConnectWise*"
}

# Log and uninstall found applications
if ($apps) {
    foreach ($app in $apps) {
        Write-Host "FOUND: $($app.Name) - Version: $($app.Version)" -ForegroundColor Yellow
        
        # Uninstall the application
        Write-Host "Uninstalling $($app.Name)..." -ForegroundColor Cyan
        $app.Uninstall() | Out-Null
        Write-Host "Uninstall command executed for $($app.Name)" -ForegroundColor Green
    }
} else {
    Write-Host "No ScreenConnect/ConnectWise Control applications found via WMI." -ForegroundColor Green
    
    # Alternative check using registry
    Write-Host "Checking registry for applications..."
    $regApps = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | 
        Where-Object { $_.DisplayName -like "*ScreenConnect*" -or $_.DisplayName -like "*ConnectWise*" }
    
    if ($regApps) {
        foreach ($app in $regApps) {
            Write-Host "FOUND: $($app.DisplayName)" -ForegroundColor Yellow
            
            # Basic uninstall using msiexec
            if ($app.UninstallString -like "*msiexec*") {
                $code = $app.UninstallString -replace ".*{(.*)}.*", '$1'
                Write-Host "Uninstalling with product code: $code" -ForegroundColor Cyan
                Start-Process "msiexec.exe" -ArgumentList "/x {$code} /qn" -Wait
            } else {
                Write-Host "Manual uninstallation may be required." -ForegroundColor Red
                Write-Host "Uninstall string: $($app.UninstallString)"
            }
        }
    } else {
        Write-Host "No applications found in registry either." -ForegroundColor Green
    }
}

Write-Host "Process complete." -ForegroundColor Green