# Simple script to detect and uninstall ScreenConnect/ConnectWise Control
# Preserves instances with specified fingerprints
# Run as administrator

# ================================================
# If You're not using NinjaOne, you can comment out 
#     all of the Ninja related code around line 200.
# ================================================

Write-Host "Checking for ScreenConnect/ConnectWise Control..."

# ===== CONFIGURATION SECTION =====
# Company name for logging directory (change "Sentinel" to your MSP name)
$companyName = "{MSP NAME}"

# Protected fingerprints (add multiple fingerprints separated by commas)
$protectedFingerprints = @("{Your ScreenConnect ID(s)}}")
# Example with multiple fingerprints:
# $protectedFingerprints = @("12347f10be771234", "12349b2d72be1234", "another-fingerprint")

# ===== END CONFIGURATION SECTION =====

# Define logging variables
$currentDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$removedInstances = @()
$logEntries = @()

# Setup local logging directory and file using company name
$logDirectory = Join-Path $env:SystemRoot "Temp\$companyName\Logging"
$logFileName = "ScreenConnect_Removal_$(Get-Date -Format 'yyyy-MM-dd').log"
$logFilePath = Join-Path $logDirectory $logFileName

# Create logging directory if it doesn't exist
if (-not (Test-Path $logDirectory)) {
    try {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        Write-Host "Created logging directory: $logDirectory" -ForegroundColor Green
    } catch {
        Write-Host "Warning: Failed to create logging directory: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Continuing without local file logging..." -ForegroundColor Yellow
        $logFilePath = $null
    }
}

# Function to write to local log file
function Write-LocalLog {
    param([string]$Message)
    if ($logFilePath) {
        try {
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message" | Out-File -FilePath $logFilePath -Append -Encoding UTF8
        } catch {
            Write-Host "Warning: Failed to write to local log file: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# Log script start
Write-LocalLog "=== ScreenConnect Removal Script Started ==="
Write-LocalLog "Company: $companyName"
Write-LocalLog "Protected Fingerprints: $($protectedFingerprints -join ', ')"

# Function to check if an application should be preserved
function Should-PreserveApp {
    param($appName, $installLocation)
    
    # Check against all protected fingerprints
    foreach ($fingerprint in $protectedFingerprints) {
        # First check: Look for fingerprint directly in the application name (most common case)
        if ($appName -and $appName.Contains($fingerprint)) {
            Write-Host "PROTECTED: Found fingerprint $fingerprint in application name: $appName" -ForegroundColor Green
            return $true
        }
        
        # Second check: Look in installation location path
        if ($installLocation -and $installLocation.Contains($fingerprint)) {
            Write-Host "PROTECTED: Found fingerprint $fingerprint in installation path for $appName" -ForegroundColor Green
            return $true
        }
        
        # Third check: Look in config files (if installation location exists)
        if ($installLocation -and (Test-Path $installLocation)) {
            # Look for config files that might contain the fingerprint
            $configPaths = @(
                "$installLocation\App_Data\Config.xml",
                "$installLocation\Config.xml",
                "$installLocation\App.config"
            )
            
            foreach ($configPath in $configPaths) {
                if (Test-Path $configPath) {
                    try {
                        $configContent = Get-Content $configPath -Raw -ErrorAction SilentlyContinue
                        if ($configContent -and $configContent.Contains($fingerprint)) {
                            Write-Host "PROTECTED: Found fingerprint $fingerprint in config file $configPath for $appName" -ForegroundColor Green
                            return $true
                        }
                    } catch {
                        # Continue if we can't read the file
                    }
                }
            }
            
            # Check all files in the installation directory for the fingerprint
            try {
                $files = Get-ChildItem $installLocation -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.xml', '.config', '.json', '.txt') }
                foreach ($file in $files) {
                    try {
                        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                        if ($content -and $content.Contains($fingerprint)) {
                            Write-Host "PROTECTED: Found fingerprint $fingerprint in $($file.FullName) for $appName" -ForegroundColor Green
                            return $true
                        }
                    } catch {
                        # Continue if we can't read the file
                    }
                }
            } catch {
                # Continue if we can't access the directory
            }
        }
    }
    
    return $false
}

# Get installed applications
$apps = Get-WmiObject -Class Win32_Product | Where-Object {
    $_.Name -like "*ScreenConnect*" -or 
    $_.Name -like "*ConnectWise*"
}

# Log and uninstall found applications (except protected ones)
if ($apps) {
    foreach ($app in $apps) {
        Write-Host "FOUND: $($app.Name) - Version: $($app.Version)" -ForegroundColor Yellow
        Write-Host "Install Location: $($app.InstallLocation)" -ForegroundColor Gray
        
        # Check if this app should be preserved
        if (Should-PreserveApp -appName $app.Name -installLocation $app.InstallLocation) {
            Write-Host "SKIPPING: $($app.Name) - Contains protected fingerprint" -ForegroundColor Green
            Write-LocalLog "PRESERVED: $($app.Name) - Version: $($app.Version) - Contains protected fingerprint"
            continue
        }
        
        # Uninstall the application
        Write-Host "Uninstalling $($app.Name)..." -ForegroundColor Cyan
        Write-LocalLog "REMOVING: $($app.Name) - Version: $($app.Version) - Install Location: $($app.InstallLocation)"
        $app.Uninstall() | Out-Null
        Write-Host "Uninstall command executed for $($app.Name)" -ForegroundColor Red
        Write-LocalLog "REMOVED: $($app.Name) - Uninstall command completed"
        
        # Log the removed instance
        $removedInstances += "$($app.Name) (Version: $($app.Version))"
        $logEntries += "[$currentDate] Removed: $($app.Name) - Version: $($app.Version) - Install Location: $($app.InstallLocation)"
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
            Write-Host "Install Location: $($app.InstallLocation)" -ForegroundColor Gray
            
            # Check if this app should be preserved
            if (Should-PreserveApp -appName $app.DisplayName -installLocation $app.InstallLocation) {
                Write-Host "SKIPPING: $($app.DisplayName) - Contains protected fingerprint" -ForegroundColor Green
                Write-LocalLog "PRESERVED: $($app.DisplayName) - Contains protected fingerprint"
                continue
            }
            
            # Basic uninstall using msiexec
            if ($app.UninstallString -like "*msiexec*") {
                $code = $app.UninstallString -replace ".*{(.*)}.*", '$1'
                Write-Host "Uninstalling with product code: $code" -ForegroundColor Cyan
                Write-LocalLog "REMOVING: $($app.DisplayName) - Product Code: $code - Install Location: $($app.InstallLocation)"
                Start-Process "msiexec.exe" -ArgumentList "/x {$code} /qn" -Wait
                Write-Host "Uninstall command executed for $($app.DisplayName)" -ForegroundColor Red
                Write-LocalLog "REMOVED: $($app.DisplayName) - MSI uninstall completed"
                
                # Log the removed instance
                $removedInstances += "$($app.DisplayName)"
                $logEntries += "[$currentDate] Removed: $($app.DisplayName) - Install Location: $($app.InstallLocation) - Uninstall String: $($app.UninstallString)"
            } else {
                Write-Host "Manual uninstallation may be required." -ForegroundColor Red
                Write-Host "Uninstall string: $($app.UninstallString)"
                Write-LocalLog "MANUAL REQUIRED: $($app.DisplayName) - Non-MSI uninstall string: $($app.UninstallString)"
            }
        }
    } else {
        Write-Host "No applications found in registry either." -ForegroundColor Green
    }
}

Write-Host "Process complete. Protected instances with fingerprints ($($protectedFingerprints -join ', ')) were preserved." -ForegroundColor Green
Write-LocalLog "=== ScreenConnect Removal Script Completed ==="

# Update NinjaOne custom field with removal log
if ($removedInstances.Count -gt 0) {
    Write-LocalLog "Summary: $($removedInstances.Count) instance(s) removed in this run"
    
    try {
        # Get existing log from custom field
        $existingLog = ""
        try {
            $existingLog = Ninja-Property-Get "screenconnectInstanceRemoved"
            if ($existingLog -eq $null) { $existingLog = "" }
        } catch {
            $existingLog = ""
        }
        
        # Create summary for this run
        $summary = "[$currentDate] ScreenConnect Removal Summary: $($removedInstances.Count) instance(s) removed"
        $detailedLog = $logEntries -join "`n"
        
        # Combine with existing log (keep existing entries at top, new ones at bottom)
        $newLogContent = if ($existingLog -ne "") {
            "$existingLog`n`n$summary`n$detailedLog"
        } else {
            "$summary`n$detailedLog"
        }
        
        # Set the custom field with the updated log
        Ninja-Property-Set "screenconnectInstanceRemoved" $newLogContent
        Write-Host "Successfully logged removal details to NinjaOne custom field 'screenconnectInstanceRemoved'" -ForegroundColor Green
        Write-LocalLog "Successfully updated NinjaOne custom field 'screenconnectInstanceRemoved'"
        
        # Display summary
        Write-Host "`nREMOVAL SUMMARY:" -ForegroundColor Yellow
        foreach ($instance in $removedInstances) {
            Write-Host "  - $instance" -ForegroundColor Red
        }
        
    } catch {
        Write-Host "Warning: Failed to update NinjaOne custom field 'screenconnectInstanceRemoved': $($_.Exception.Message)" -ForegroundColor Yellow
        Write-LocalLog "ERROR: Failed to update NinjaOne custom field: $($_.Exception.Message)"
        Write-Host "Manual log entry needed:" -ForegroundColor Yellow
        Write-Host $summary -ForegroundColor Yellow
        foreach ($entry in $logEntries) {
            Write-Host $entry -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "No instances were removed during this run." -ForegroundColor Green
    Write-LocalLog "No instances removed in this run"
    
    # Still log that the script ran
    try {
        $existingLog = ""
        try {
            $existingLog = Ninja-Property-Get "screenconnectInstanceRemoved"
            if ($existingLog -eq $null) { $existingLog = "" }
        } catch {
            $existingLog = ""
        }
        
        $noRemovalEntry = "[$currentDate] ScreenConnect scan completed - No instances removed (Protected fingerprints: $($protectedFingerprints -join ', '))"
        $newLogContent = if ($existingLog -ne "") {
            "$existingLog`n$noRemovalEntry"
        } else {
            $noRemovalEntry
        }
        
        Ninja-Property-Set "screenconnectInstanceRemoved" $newLogContent
        Write-Host "Logged scan completion to NinjaOne custom field 'screenconnectInstanceRemoved'" -ForegroundColor Green
        Write-LocalLog "Updated NinjaOne custom field with scan completion status"
    } catch {
        Write-Host "Warning: Failed to update NinjaOne custom field: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-LocalLog "ERROR: Failed to update NinjaOne custom field: $($_.Exception.Message)"
    }
}

# Log final status
if ($logFilePath) {
    Write-LocalLog "Local log file saved to: $logFilePath"
    Write-Host "Local log file saved to: $logFilePath" -ForegroundColor Cyan
}