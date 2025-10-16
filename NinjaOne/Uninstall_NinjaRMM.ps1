### NinjaRMM Uninstaller with Uninstall Prevention Handling ###
### #!PS
### #maxlength=50000
### #Timeout=90000

# Set MSP Name (placeholder for public repo)
$MSPName = "YourMSPName"

# Define log directory
$LogDirectory = "C:\Windows\Temp\$MSPName\Logs"

# Create log directory if it doesn't exist
if (-not (Test-Path -Path $LogDirectory)) {
    try {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        Write-Host "Created log directory: $LogDirectory"
    } catch {
        Write-Host "Error creating log directory: $_"
        # Fallback to Windows\Temp if directory creation fails
        $LogDirectory = "C:\Windows\Temp"
    }
}

# Define log file path
$LogFile = Join-Path -Path $LogDirectory -ChildPath "NinjaUninstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Function to write to both console and log file
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $Message
    Add-Content -Path $LogFile -Value $logMessage
}

# Function to check if NinjaRMMAgent service is running
function Test-NinjaServiceRunning {
    try {
        $service = Get-Service -Name "NinjaRMMAgent" -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

# Function to find Ninja installation directory
function Get-NinjaInstallPath {
    $possiblePaths = Get-ChildItem "C:\Program Files (x86)" -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -like "*Ninja*" }
    
    if ($possiblePaths) {
        return $possiblePaths[0].FullName
    }
    return $null
}

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

# Function to disable uninstall prevention
function Disable-NinjaUninstallPrevention {
    param([string]$InstallPath)
    
    $agentExe = Join-Path -Path $InstallPath -ChildPath "NinjaRMMAgent.exe"
    
    if (Test-Path $agentExe) {
        try {
            Write-Log "Disabling uninstall prevention..."
            $process = Start-Process -FilePath $agentExe -ArgumentList "-disableUninstallPrevention" -Wait -PassThru -NoNewWindow
            if ($process.ExitCode -eq 0) {
                Write-Log "Uninstall prevention disabled successfully."
                return $true
            } else {
                Write-Log "Warning: Disable uninstall prevention returned exit code $($process.ExitCode)"
                return $false
            }
        } catch {
            Write-Log "Error disabling uninstall prevention: $_"
            return $false
        }
    } else {
        Write-Log "NinjaRMMAgent.exe not found at: $agentExe"
        return $false
    }
}

# Function to uninstall using native uninstaller
function Uninstall-NinjaWithNativeUninstaller {
    param([string]$InstallPath)
    
    $uninstallerPath = Join-Path -Path $InstallPath -ChildPath "uninstall.exe"
    
    if (Test-Path $uninstallerPath) {
        try {
            Write-Log "Running native Ninja uninstaller..."
            $process = Start-Process -FilePath $uninstallerPath -ArgumentList "--mode unattended" -Wait -PassThru -NoNewWindow
            Write-Log "Uninstaller completed with exit code: $($process.ExitCode)"
            return $true
        } catch {
            Write-Log "Error running native uninstaller: $_"
            return $false
        }
    } else {
        Write-Log "Native uninstaller not found at: $uninstallerPath"
        return $false
    }
}

# Main script
try {
    Write-Log "===== NinjaRMM Uninstall Process Started ====="
    
    # Check if Ninja service is running
    Write-Log "Checking if NinjaRMMAgent service is running..."
    $serviceRunning = Test-NinjaServiceRunning
    
    if ($serviceRunning) {
        Write-Log "NinjaRMMAgent service is running."
    } else {
        Write-Log "Warning: NinjaRMMAgent service is not running. Uninstall prevention may not be handled properly."
    }
    
    # Find Ninja installation path
    Write-Log "Searching for Ninja installation directory..."
    $installPath = Get-NinjaInstallPath
    
    if ($installPath) {
        Write-Log "Found Ninja installation at: $installPath"
        
        # If service is running, attempt to disable uninstall prevention
        if ($serviceRunning) {
            Disable-NinjaUninstallPrevention -InstallPath $installPath
        }
        
        # Attempt uninstall using native uninstaller
        $uninstallSuccess = Uninstall-NinjaWithNativeUninstaller -InstallPath $installPath
        
        if (-not $uninstallSuccess) {
            Write-Log "Native uninstaller failed or not found. Attempting MSI uninstall..."
            
            # Fallback to MSI uninstall
            $productCode = Get-NinjaUninstallString
            
            if ($productCode) {
                Write-Log "Found MSI product code: $productCode"
                $msiLogFile = Join-Path -Path $LogDirectory -ChildPath "NinjaMSIUninstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                $arguments = "/X$productCode /qn /norestart /l*v `"$msiLogFile`""
                
                Write-Log "Running MSI uninstaller..."
                Start-Process "msiexec.exe" -ArgumentList $arguments -Wait -NoNewWindow
                Write-Log "MSI uninstaller completed. Check log at: $msiLogFile"
            } else {
                Write-Log "Error: Could not find MSI product code for fallback uninstall."
            }
        }
        
        # Clean up remaining folders
        Write-Log "Cleaning up remaining Ninja folders..."
        
        # Remove all Ninja folders in Program Files (x86)
        $ninjaFolders = Get-ChildItem "C:\Program Files (x86)" -Directory -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*Ninja*" }
        
        foreach ($folder in $ninjaFolders) {
            try {
                Write-Log "Removing folder: $($folder.FullName)"
                Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction Stop
                Write-Log "Successfully removed: $($folder.FullName)"
            } catch {
                Write-Log "Warning: Could not remove $($folder.FullName): $_"
            }
        }
        
        # Remove ProgramData folder
        $programDataPath = "C:\ProgramData\NinjaRMMAgent"
        if (Test-Path $programDataPath) {
            try {
                Write-Log "Removing ProgramData folder: $programDataPath"
                Remove-Item -Path $programDataPath -Recurse -Force -ErrorAction Stop
                Write-Log "Successfully removed: $programDataPath"
            } catch {
                Write-Log "Warning: Could not remove $programDataPath : $_"
            }
        }
        
        # Final verification
        $verifyUninstall = Get-NinjaUninstallString
        if ($verifyUninstall -eq $null) {
            Write-Log "SUCCESS: NinjaRMM has been successfully uninstalled."
        } else {
            Write-Log "WARNING: Uninstall may not have completed successfully. Registry entry still exists."
        }
        
    } else {
        Write-Log "NinjaRMM installation not found."
    }
    
    Write-Log "===== NinjaRMM Uninstall Process Completed ====="
    Write-Log "Full log available at: $LogFile"
    
} catch {
    Write-Log "CRITICAL ERROR: An unexpected error occurred: $_"
    Write-Log $_.ScriptStackTrace
}