# Uninstallation Script for Timus Connect
# ---------------------------------------
# This script performs the following actions:
# 1. Stops and deletes services related to Timus Connect.
# 2. Kills all processes named "timus" and other specified processes.
# 3. Runs the uninstaller for Timus Connect silently.
# 4. Deletes specific directories associated with Timus Connect.
# 5. Removes Timus Connect from startup items.
# 6. Removes specific registry keys related to Timus Connect.
# 
# NOTE: Please review this script thoroughly before running it. Ensure that the paths
# and services mentioned are correct for your specific setup.

# Define log function
function Log-Message {
    param (
        [string]$message
    )
    $logFile = "$env:USERPROFILE\\timus_uninstall.txt"
    Add-Content -Path $logFile -Value ("$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $message")
}

# Function to stop and delete a service
function Stop-And-Delete-Service {
    param (
        [string]$serviceName
    )
    try {
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
            Log-Message "Stopped service $serviceName"
        }
        sc.exe delete $serviceName
        Log-Message "Deleted service $serviceName"
    } catch {
        Log-Message "Failed to stop or delete service ${serviceName}: $($_)"
    }
}

# Function to kill processes by name
function Kill-Processes {
    param (
        [string[]]$processNames
    )
    foreach ($processName in $processNames) {
        try {
            Get-Process -Name $processName -ErrorAction Stop | Stop-Process -Force
            Log-Message "Killed all processes named $processName"
        } catch {
            Log-Message "Failed to kill processes named ${processName}: $($_)"
        }
    }
}

# Function to kill processes by executable name using taskkill
function TaskKill-Processes {
    param (
        [string[]]$processExecutables
    )
    foreach ($processExecutable in $processExecutables) {
        try {
            Start-Process -FilePath "taskkill.exe" -ArgumentList "/F /IM $processExecutable" -NoNewWindow -Wait
            Log-Message "Taskkill executed for $processExecutable"
        } catch {
            Log-Message "Failed to execute taskkill for ${processExecutable}: $($_)"
        }
    }
}

# Function to delete directories
function Delete-Directory {
    param (
        [string]$directoryPath
    )
    try {
        Remove-Item -Path $directoryPath -Recurse -Force -ErrorAction Stop
        Log-Message "Deleted directory $directoryPath"
    } catch {
        Log-Message "Failed to delete directory ${directoryPath}: $($_)"
    }
}

# Function to remove startup items
function Remove-StartupItem {
    param (
        [string]$itemName
    )
    try {
        # Remove from Startup folder
        $startupFolderPath = [System.Environment]::GetFolderPath('Startup')
        $startupItemPath = Join-Path -Path $startupFolderPath -ChildPath "$itemName.lnk"
        if (Test-Path $startupItemPath) {
            Remove-Item -Path $startupItemPath -Force
            Log-Message "Removed $itemName from Startup folder"
        }
    } catch {
        Log-Message "Failed to remove $itemName from Startup folder: $($_)"
    }
    
    try {
        # Remove from Registry (Current User)
        $regPath = "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
        if (Get-ItemProperty -Path $regPath -Name $itemName -ErrorAction Stop) {
            Remove-ItemProperty -Path $regPath -Name $itemName -ErrorAction Stop -Force
            Log-Message "Removed $itemName from HKCU registry"
        }
    } catch {
        Log-Message "Failed to remove $itemName from HKCU registry: $($_)"
    }

    try {
        # Remove from Registry (Local Machine)
        $regPathLM = "HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
        if (Get-ItemProperty -Path $regPathLM -Name $itemName -ErrorAction Stop) {
            Remove-ItemProperty -Path $regPathLM -Name $itemName -ErrorAction Stop -Force
            Log-Message "Removed $itemName from HKLM registry"
        }
    } catch {
        Log-Message "Failed to remove $itemName from HKLM registry: $($_)"
    }
}

# Function to remove registry keys
function Remove-RegistryKey {
    param (
        [string]$registryPath
    )
    try {
        if (Test-Path $registryPath) {
            Remove-Item -Path $registryPath -Recurse -Force -ErrorAction Stop
            Log-Message "Removed registry key $registryPath"
        }
    } catch {
        Log-Message "Failed to remove registry key ${registryPath}: $($_)"
    }
}

# Define paths using environment variables
$programFilesPath = [System.Environment]::GetFolderPath('ProgramFiles')
$programDataPath = [System.Environment]::GetFolderPath('CommonApplicationData')
$appDataLocalPath = [System.Environment]::GetFolderPath('LocalApplicationData')
$appDataRoamingPath = [System.Environment]::GetFolderPath('ApplicationData')

# Construct the path to the uninstaller
$uninstallPath = Join-Path -Path $programFilesPath -ChildPath "Timus Connect\\Uninstall Timus Connect"

# Stop and delete Timus Connect services
Stop-And-Delete-Service -serviceName "timus-connect-service"
Stop-And-Delete-Service -serviceName "timus-helper-service"

# Kill all processes named "timus"
Kill-Processes -processNames @("timus")

# Additional taskkill commands for specific executables
TaskKill-Processes -processExecutables @("timus-connect-service.exe", "timus-helper-service.exe", "timus-telemetry.exe", "timus-wireguard-tunnel-service.exe", "openvpn.exe")

# Run uninstaller silently
try {
    $process = Start-Process -FilePath $uninstallPath -ArgumentList "/S" -NoNewWindow -Wait -PassThru
    $process.WaitForExit()
    Log-Message "Ran uninstaller at $uninstallPath"
} catch {
    Log-Message "Failed to run uninstaller at ${uninstallPath}: $($_)"
}

# Delete directories associated with Timus Connect
Delete-Directory -directoryPath "$appDataLocalPath\\timus-updater"
Delete-Directory -directoryPath "$appDataRoamingPath\\Timus Connect"
Delete-Directory -directoryPath "$programFilesPath\\Timus Connect"
Delete-Directory -directoryPath "$programDataPath\\Timus Connect"

# Remove Timus Connect from startup items
Remove-StartupItem -itemName "Timus Connect"

# Remove specific registry keys related to Timus Connect
Remove-RegistryKey -registryPath "HKCU:\\SOFTWARE\\Classes\\timus-connect"
Remove-RegistryKey -registryPath "HKLM:\\SOFTWARE\\Timus"
Remove-RegistryKey -registryPath "HKCR:\\timus-connect"

# Log completion of the script
Log-Message "Uninstallation script completed"

# Exit the script
exit