# Function to find NinjaRMM uninstall string
function Get-NinjaUninstallString {
    $uninstallString = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" | 
        Where-Object { $_.DisplayName -like "*Ninja*" } |
        Select-Object -ExpandProperty UninstallString

    if ($uninstallString) {
        # Extract MSI product code from uninstall string
        if ($uninstallString -match "{[0-9A-F-]+}") {
            return $matches[0]
        }
    }
    return $null
}

# Main script
try {
    Write-Host "Searching for NinjaRMM uninstall string..."
    $productCode = Get-NinjaUninstallString

    if ($productCode) {
        Write-Host "Found NinjaRMM installation. Proceeding with uninstall..."
        
        # Create uninstall command
        $arguments = "/X$productCode /qn /norestart /l*v C:\Windows\Temp\ninjauninstall.log"
        
        # Execute uninstall
        Write-Host "Running uninstaller..."
        Start-Process "msiexec.exe" -ArgumentList $arguments -Wait -NoNewWindow
        
        # Verify uninstallation
        $verifyUninstall = Get-NinjaUninstallString
        if ($verifyUninstall -eq $null) {
            Write-Host "NinjaRMM has been successfully uninstalled."
        } else {
            Write-Host "Warning: Uninstall may not have completed successfully."
        }
    } else {
        Write-Host "NinjaRMM installation not found in registry."
    }
} catch {
    Write-Host "An error occurred: $_"
}