### NinjaRMM Uninstaller with Uninstall Prevention Handling ###
### #!PS
### #maxlength=50000
### #Timeout=90000

#Get current user context
$CurrentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
#Check user that is running the script is a member of Administrator Group
if (!($CurrentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator))) {
    #UAC Prompt will occur for the user to input Administrator credentials and relaunch the powershell session
    Write-Output 'This script must be ran with administrative privileges'
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; Exit
}

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
$Now = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath = "$LogDirectory\NinjaRemoval_$Now.txt"
Start-Transcript -Path $LogPath -Force
$ErrorActionPreference = 'SilentlyContinue'

Write-Output "===== NinjaRMM Uninstall Process Started ====="
Write-Output "Log file: $LogPath"

function Uninstall-NinjaMSI {
    $Arguments = @(
        "/x$($UninstallString)"
        '/quiet'
        '/L*V'
        "$LogDirectory\NinjaRMMAgent_uninstall.log"
        "WRAPPED_ARGUMENTS=`"--mode unattended`""
    )

    # Check if Ninja service is running before attempting to disable uninstall prevention
    $NinjaService = Get-Service -Name "NinjaRMMAgent" -ErrorAction SilentlyContinue
    if ($NinjaService -and $NinjaService.Status -eq 'Running') {
        Write-Output "NinjaRMMAgent service is running. Disabling uninstall prevention..."
        Start-Process "$NinjaInstallLocation\NinjaRMMAgent.exe" -ArgumentList "-disableUninstallPrevention NOUI" -ErrorAction SilentlyContinue
        Start-Sleep 10
    } else {
        Write-Output "Warning: NinjaRMMAgent service is not running. Uninstall prevention may not be handled properly."
    }

    Write-Output "Running MSI uninstaller..."
    Start-Process "msiexec.exe" -ArgumentList $Arguments -Wait -NoNewWindow
    Write-Output 'Finished running uninstaller. Continuing to clean up...'
    Start-Sleep 30
}

$NinjaRegPath = 'HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC\NinjaRMMAgent'
$NinjaDataDirectory = "$($env:ProgramData)\NinjaRMMAgent"
$UninstallRegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'

Write-Output 'Beginning NinjaRMM Agent removal...'

if (!([System.Environment]::Is64BitOperatingSystem)) {
    $NinjaRegPath = 'HKLM:\SOFTWARE\NinjaRMM LLC\NinjaRMMAgent'
    $UninstallRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
}

# Attempt to find Ninja installation location
$NinjaInstallLocation = $null
try {
    $NinjaInstallLocation = (Get-ItemPropertyValue $NinjaRegPath -Name Location -ErrorAction Stop).Replace('/', '\')
    Write-Output "Found Ninja installation location from registry: $NinjaInstallLocation"
} catch {
    Write-Output "Unable to find Ninja location in registry. Attempting service path method..."
}

if (!(Test-Path "$($NinjaInstallLocation)\NinjaRMMAgent.exe")) {
    $NinjaServicePath = ((Get-Service | Where-Object { $_.Name -eq 'NinjaRMMAgent' }).BinaryPathName).Trim('"')
    if (!(Test-Path $NinjaServicePath)) {
        Write-Output 'Unable to locate Ninja installation path. Continuing with cleanup...'
    } else {
        $NinjaInstallLocation = $NinjaServicePath | Split-Path
        Write-Output "Found Ninja installation location from service: $NinjaInstallLocation"
    }
}

$UninstallString = (Get-ItemProperty $UninstallRegPath | Where-Object { ($_.DisplayName -eq 'NinjaRMMAgent') -and ($_.UninstallString -match 'msiexec') }).UninstallString

if (!($UninstallString)) {
    Write-Output 'Unable to determine uninstall string. Continuing with cleanup...' 
} else {
    $UninstallString = $UninstallString.Split('X')[1]
    Write-Output "Found uninstall string: $UninstallString"
    Uninstall-NinjaMSI
}

# Stop Ninja processes
$Processes = @("NinjaRMMAgent", "NinjaRMMAgentPatcher", "njbar", "NinjaRMMProxyProcess64")
Write-Output "Stopping Ninja processes..."
foreach ($Process in $Processes) {
    $RunningProcess = Get-Process $Process -ErrorAction SilentlyContinue
    if ($RunningProcess) {
        Write-Output "Stopping process: $Process"
        $RunningProcess | Stop-Process -Force 
    }
}

# Remove Ninja services
$NinjaServices = @('NinjaRMMAgent', 'nmsmanager', 'lockhart')
Write-Output "Removing Ninja services..."
foreach ($NS in $NinjaServices) {
    if (($NS -eq 'lockhart') -and !(Test-Path "$NinjaInstallLocation\lockhart\bin\lockhart.exe")) {
        continue
    }
    if (Get-Service $NS -ErrorAction SilentlyContinue) {
        Write-Output "Removing service: $NS"
        & sc.exe DELETE $NS
        Start-Sleep 2
        if (Get-Service $NS -ErrorAction SilentlyContinue) {
            Write-Output "Failed to remove service: $($NS). Continuing with removal attempt..."
        }
    }
}

# Remove installation directory
if (Test-Path $NinjaInstallLocation) {
    Write-Output "Removing installation directory: $NinjaInstallLocation"
    Remove-Item $NinjaInstallLocation -Recurse -Force
    if (Test-Path $NinjaInstallLocation) {
        Write-Output 'Failed to remove Ninja Installation Directory:'
        Write-Output "$NinjaInstallLocation"
        Write-Output 'Continuing with removal attempt...'
    } 
}

# Remove data directory
if (Test-Path $NinjaDataDirectory) {
    Write-Output "Removing data directory: $NinjaDataDirectory"
    Remove-Item $NinjaDataDirectory -Recurse -Force
    if (Test-Path $NinjaDataDirectory) {
        Write-Output 'Failed to remove Ninja Data Directory:'
        Write-Output "$NinjaDataDirectory"
        Write-Output 'Continuing with removal attempt...'
    }
}

# Clean up registry keys
Write-Output "Cleaning up registry keys..."
$MSIWrapperReg = 'HKLM:\SOFTWARE\WOW6432Node\EXEMSI.COM\MSI Wrapper\Installed'
$ProductInstallerReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
$HKCRInstallerReg = 'Registry::\HKEY_CLASSES_ROOT\Installer\Products'

$RegKeysToRemove = [System.Collections.Generic.List[object]]::New()

(Get-ItemProperty $UninstallRegPath | Where-Object { $_.DisplayName -eq 'NinjaRMMAgent' }).PSPath | ForEach-Object { $RegKeysToRemove.Add($_) }
(Get-ItemProperty $ProductInstallerReg | Where-Object { $_.ProductName -eq 'NinjaRMMAgent' }).PSPath | ForEach-Object { $RegKeysToRemove.Add($_) }
(Get-ChildItem $MSIWrapperReg -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NinjaRMMAgent' }).PSPath | ForEach-Object { $RegKeysToRemove.Add($_) }
Get-ChildItem $HKCRInstallerReg -ErrorAction SilentlyContinue | ForEach-Object { if ((Get-ItemPropertyValue $_.PSPath -Name 'ProductName' -ErrorAction SilentlyContinue) -eq 'NinjaRMMAgent') { $RegKeysToRemove.Add($_.PSPath) } }

$ProductInstallerKeys = Get-ChildItem $ProductInstallerReg -ErrorAction SilentlyContinue | Select-Object *
foreach ($Key in $ProductInstallerKeys) {
    $KeyName = $($Key.Name).Replace('HKEY_LOCAL_MACHINE', 'HKLM:') + "\InstallProperties"
    if (Get-ItemProperty $KeyName -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'NinjaRMMAgent' }) {
        $RegKeysToRemove.Add($Key.PSPath)
    }
}

Write-Output 'Removing registry items if found...'
foreach ($RegKey in $RegKeysToRemove) {
    if (!([string]::IsNullOrEmpty($RegKey))) {
        Write-Output "Removing: $($RegKey)"
        Remove-Item $RegKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path $NinjaRegPath) {
    Write-Output "Removing: $($NinjaRegPath)"
    Get-Item ($NinjaRegPath | Split-Path) | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Verify registry removal
foreach ($RegKey in $RegKeysToRemove) {
    if (!([string]::IsNullOrEmpty($RegKey))) {
        if (Test-Path $RegKey) {
            Write-Output 'Failed to remove the following registry key:'
            Write-Output "$($RegKey)"
        }
    }   
}

if (Test-Path $NinjaRegPath) {
    Write-Output "Failed to remove: $NinjaRegPath"
}

# Check for rogue reg entries from older installations
$Child = Get-ChildItem 'HKLM:\Software\Classes\Installer\Products' -ErrorAction SilentlyContinue
$MissingPNs = [System.Collections.Generic.List[object]]::New()

foreach ($C in $Child) {
    if ($C.Name -match '99E80CA9B0328e74791254777B1F42AE') {
        continue
    }
    try {
        Get-ItemPropertyValue $C.PSPath -Name 'ProductName' -ErrorAction Stop | Out-Null
    } catch {
        $MissingPNs.Add($($C.Name))
    } 
}

if ($MissingPNs) {
    Write-Output 'Some registry keys are missing the Product Name.'
    Write-Output 'This could be an indicator of a corrupt Ninja install key.'
    Write-Output 'If you are still unable to install the Ninja Agent after running this script...'
    Write-Output 'Please make a backup of the following keys before removing them from the registry:'
    Write-Output ($MissingPNs | Out-String)
}

##Begin Ninja Remote Removal##
Write-Output "Beginning Ninja Remote removal..."
$NR = 'ncstreamer'

if (Get-Process $NR -ErrorAction SilentlyContinue) {
    Write-Output 'Stopping Ninja Remote process...'
    try {
        Get-Process $NR | Stop-Process -Force
    } catch {
        Write-Output 'Unable to stop the Ninja Remote process...'
        Write-Output "$($_.Exception)"
        Write-Output 'Continuing to Ninja Remote service...'
    }
}

if (Get-Service $NR -ErrorAction SilentlyContinue) {
    try {
        Stop-Service $NR -Force
    } catch {
        Write-Output 'Unable to stop the Ninja Remote service...'
        Write-Output "$($_.Exception)"
        Write-Output 'Attempting to remove service...'
    }

    & sc.exe DELETE $NR
    Start-Sleep 5
    if (Get-Service $NR -ErrorAction SilentlyContinue) {
        Write-Output 'Failed to remove Ninja Remote service. Continuing with remaining removal steps...'
    }
}

$NRDriver = 'nrvirtualdisplay.inf'
$DriverCheck = pnputil /enum-drivers | Where-Object { $_ -match "$NRDriver" }
if ($DriverCheck) {
    Write-Output 'Ninja Remote Virtual Driver found. Removing...'
    $DriverBreakdown = pnputil /enum-drivers | Where-Object { $_ -ne 'Microsoft PnP Utility' }

    $DriversArray = [System.Collections.Generic.List[object]]::New()
    $CurrentDriver = @{}
    
    foreach ($Line in $DriverBreakdown) {
        if ($Line -ne "") {
            $ObjectName = $Line.Split(':').Trim()[0]
            $ObjectValue = $Line.Split(':').Trim()[1]
            $CurrentDriver[$ObjectName] = $ObjectValue
        } else {
            if ($CurrentDriver.Count -gt 0) {
                $DriversArray.Add([PSCustomObject]$CurrentDriver)
                $CurrentDriver = @{}
            }
        }
    }

    $DriverToRemove = ($DriversArray | Where-Object {$_.'Provider Name' -eq 'NinjaOne'}).'Published Name'
    pnputil /delete-driver "$DriverToRemove" /force
}

$NRDirectory = "$($env:ProgramFiles)\NinjaRemote"
if (Test-Path $NRDirectory) {
    Write-Output "Removing directory: $NRDirectory"
    Remove-Item $NRDirectory -Recurse -Force
    if (Test-Path $NRDirectory) {
        Write-Output 'Failed to completely remove Ninja Remote directory at:'
        Write-Output "$NRDirectory"
        Write-Output 'Continuing to registry removal...'
    }
}

$NRHKUReg = 'Registry::\HKEY_USERS\S-1-5-18\Software\NinjaRMM LLC'
if (Test-Path $NRHKUReg) {
    Remove-Item $NRHKUReg -Recurse -Force
}

function Remove-NRRegistryItems {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SID
    )
    $NRRunReg = "Registry::\HKEY_USERS\$SID\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    $NRRegLocation = "Registry::\HKEY_USERS\$SID\Software\NinjaRMM LLC"
    if (Test-Path $NRRunReg) {
        $RunRegValues = Get-ItemProperty -Path $NRRunReg
        $PropertyNames = $RunRegValues.PSObject.Properties | Where-Object { $_.Name -match "NinjaRMM|NinjaOne" } 
        foreach ($PName in $PropertyNames) {    
            Write-Output "Removing item..."
            Write-Output "$($PName.Name): $($PName.Value)"
            Remove-ItemProperty $NRRunReg -Name $PName.Name -Force
        }
    }
    if (Test-Path $NRRegLocation) {
        Write-Output "Removing $NRRegLocation..."
        Remove-Item $NRRegLocation -Recurse -Force
    }
    Write-Output 'Registry removal completed.'
}

$AllProfiles = Get-CimInstance Win32_UserProfile | Select-Object LocalPath, SID, Loaded, Special | 
Where-Object { $_.SID -like "S-1-5-21-*" }
$Mounted = $AllProfiles | Where-Object { $_.Loaded -eq $true }
$Unmounted = $AllProfiles | Where-Object { $_.Loaded -eq $false }

$Mounted | ForEach-Object {
    Write-Output "Removing registry items for $($_.LocalPath)"
    Remove-NRRegistryItems -SID "$($_.SID)"
}

$Unmounted | ForEach-Object {
    $Hive = "$($_.LocalPath)\NTUSER.DAT"
    if (Test-Path $Hive) {      
        Write-Output "Loading hive and removing Ninja Remote registry items for $($_.LocalPath)..."

        REG LOAD HKU\$($_.SID) $Hive 2>&1>$null

        Remove-NRRegistryItems -SID "$($_.SID)"
        
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
          
        REG UNLOAD HKU\$($_.SID) 2>&1>$null
    } 
}

$NRPrinter = Get-Printer | Where-Object { $_.Name -eq 'NinjaRemote' }

if ($NRPrinter) {
    Write-Output 'Removing Ninja Remote printer...'
    Remove-Printer -InputObject $NRPrinter
}

$NRPrintDriverPath = "$env:SystemDrive\Users\Public\Documents\NrSpool\NrPdfPrint"
if (Test-Path $NRPrintDriverPath) {
    Write-Output 'Removing Ninja Remote printer driver...'
    Remove-Item $NRPrintDriverPath -Force
}

Write-Output 'Removal of Ninja Remote complete.'
##End Ninja Remote Removal##

Write-Output '===== NinjaRMM Uninstall Process Completed ====='
Write-Output "Removal script completed. Please review if any errors displayed."
Write-Output "Full log available at: $LogPath"
Stop-Transcript