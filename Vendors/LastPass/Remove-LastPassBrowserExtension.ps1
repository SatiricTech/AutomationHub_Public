# PowerShell script to remove LastPass Password Manager extension
# Simple version for NinjaRMM deployment

# Set execution policy for this session
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# Wait a moment for any file locks to clear
Start-Sleep -Seconds 2

# LastPass extension ID
$lastpassID = "hdokiejnpimakedhajhdlcegeplioahd"

# Create log file
$logPath = "C:\ProgramData\LastPassRemoval.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"[$timestamp] Starting LastPass removal script" | Out-File -FilePath $logPath

# Log function to avoid special character issues
function LogMessage {
    param([string]$message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $message" | Out-File -FilePath $logPath -Append
}

LogMessage "Script running with Administrator privileges: $([bool](([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match 'S-1-5-32-544'))"

# Function to remove extension from a browser profile
function RemoveExtension {
    param(
        [string]$browserName,
        [string]$profilePath
    )
    
    try {
        # Check if the profile path exists
        if (-not (Test-Path $profilePath)) {
            LogMessage "$browserName profile path not found: $profilePath"
            return
        }
        
        # Check for the extension directory
        $extensionPath = Join-Path -Path $profilePath -ChildPath "Extensions\$lastpassID"
        if (Test-Path $extensionPath) {
            LogMessage "Found LastPass in $browserName at $extensionPath"
            Remove-Item -Path $extensionPath -Recurse -Force -ErrorAction Stop
            LogMessage "Successfully removed LastPass extension directory from $browserName"
        } else {
            LogMessage "LastPass extension directory not found in $browserName at $extensionPath"
        }
        
        # Clean up preferences file by renaming it (browser will create a new one)
        $prefsFile = Join-Path -Path $profilePath -ChildPath "Preferences"
        if (Test-Path $prefsFile) {
            $backupFile = Join-Path -Path $profilePath -ChildPath "Preferences.bak"
            
            # Create backup
            Copy-Item -Path $prefsFile -Destination $backupFile -Force -ErrorAction Stop
            LogMessage "Created backup of $browserName preferences file"
            
            # Look for LastPass in the file
            $content = Get-Content -Path $prefsFile -Raw -ErrorAction Stop
            if ($content -match $lastpassID) {
                LogMessage "Found LastPass reference in $browserName preferences file"
                
                # Instead of trying to edit JSON, rename the file
                # The browser will create a new one without the extension
                Remove-Item -Path $prefsFile -Force -ErrorAction Stop
                LogMessage "Removed the preferences file. Browser will create a new one."
            } else {
                LogMessage "No LastPass references found in $browserName preferences file"
            }
        } else {
            LogMessage "$browserName preferences file not found"
        }
    } catch {
        $errorText = $_.Exception.Message
        LogMessage "ERROR while processing $browserName profile: $errorText"
    }
}

# Process all user profiles
try {
    $userFolders = Get-ChildItem -Path "C:\Users" -Directory
    LogMessage "Found $($userFolders.Count) user profiles"
    
    foreach ($userFolder in $userFolders) {
        $userName = $userFolder.Name
        LogMessage "Processing user: $userName"
        
        # Chrome default profile
        $chromePath = "C:\Users\$userName\AppData\Local\Google\Chrome\User Data\Default"
        RemoveExtension -browserName "Chrome default" -profilePath $chromePath
        
        # Edge default profile
        $edgePath = "C:\Users\$userName\AppData\Local\Microsoft\Edge\User Data\Default"
        RemoveExtension -browserName "Edge default" -profilePath $edgePath
        
        # Process Chrome profiles
        $chromeUserData = "C:\Users\$userName\AppData\Local\Google\Chrome\User Data"
        if (Test-Path $chromeUserData) {
            try {
                $profiles = Get-ChildItem -Path $chromeUserData -Directory | Where-Object { $_.Name -match "^Profile \d+$" }
                foreach ($profile in $profiles) {
                    $profilePath = $profile.FullName
                    RemoveExtension -browserName "Chrome $($profile.Name)" -profilePath $profilePath
                }
            } catch {
                $errorText = $_.Exception.Message
                LogMessage "ERROR enumerating Chrome profiles: $errorText"
            }
        }
        
        # Process Edge profiles
        $edgeUserData = "C:\Users\$userName\AppData\Local\Microsoft\Edge\User Data"
        if (Test-Path $edgeUserData) {
            try {
                $profiles = Get-ChildItem -Path $edgeUserData -Directory | Where-Object { $_.Name -match "^Profile \d+$" }
                foreach ($profile in $profiles) {
                    $profilePath = $profile.FullName
                    RemoveExtension -browserName "Edge $($profile.Name)" -profilePath $profilePath
                }
            } catch {
                $errorText = $_.Exception.Message
                LogMessage "ERROR enumerating Edge profiles: $errorText"
            }
        }
    }
    
    # Check for admin-installed extensions
    $adminPaths = @(
        "C:\Program Files (x86)\Google\Chrome\Application\Extensions\$lastpassID.json",
        "C:\Program Files (x86)\Microsoft\Edge\Application\Extensions\$lastpassID.json"
    )
    
    foreach ($adminPath in $adminPaths) {
        if (Test-Path $adminPath) {
            try {
                LogMessage "Found admin-installed LastPass at $adminPath"
                Remove-Item -Path $adminPath -Force -ErrorAction Stop
                LogMessage "Successfully removed admin-installed LastPass"
            } catch {
                $errorText = $_.Exception.Message
                LogMessage "ERROR removing admin-installed extension: $errorText"
            }
        }
    }
    
    # Check registry for policies
    $regKeys = @(
        "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist",
        "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionSettings",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge\ExtensionSettings"
    )
    
    foreach ($regKey in $regKeys) {
        if (Test-Path $regKey) {
            LogMessage "Checking registry key: $regKey"
            try {
                $properties = Get-ItemProperty -Path $regKey -ErrorAction Stop
                foreach ($property in $properties.PSObject.Properties) {
                    # Skip special PowerShell properties
                    if ($property.Name -like "PS*") { continue }
                    
                    $value = $property.Value
                    if ($value -is [String] -and $value -match $lastpassID) {
                        LogMessage "Found LastPass in registry value: $($property.Name)"
                        Remove-ItemProperty -Path $regKey -Name $property.Name -Force -ErrorAction Stop
                        LogMessage "Successfully removed registry value"
                    }
                }
            } catch {
                $errorText = $_.Exception.Message
                LogMessage "ERROR processing registry key: $errorText"
            }
        }
    }

    LogMessage "LastPass removal completed successfully"
    Write-Output "LastPass removal completed successfully. See log at $logPath"
    exit 0
    
} catch {
    $errorText = $_.Exception.Message
    LogMessage "CRITICAL ERROR: $errorText"
    Write-Output "Error removing LastPass extension. See log at $logPath"
    exit 1
}