<#
Timus Connect Windows Installation Script - 7/17/2025
#>

# Config
$TimusAppName = 'Timus Connect'
$TimusDownloadUrl = "https://repo.timuscloud.com/connect/Timus-Connect.exe"
$TimusDownloadDir = "$env:ProgramData\TimusInstall"
$TimusInstallerPath = "$TimusDownloadDir\Timus-Connect.exe"

# Check install status from registry
function Get-TimusInstalledApplication {
$regPaths = @(
'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach ($path in $regPaths) {
Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
$props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
if ($props.DisplayName -like "*$TimusAppName*") {
return $props
}
}
}
return $null
}

# Prepare download directory
if (Test-Path $TimusDownloadDir) {
Write-Output "Cleaning existing Timus download directory..."
try {
Remove-Item -Path $TimusDownloadDir -Recurse -Force -ErrorAction Stop
} catch {
Write-Output "Folder delete failed. Retrying after delay..."
Start-Sleep -Seconds 2
Remove-Item -Path $TimusDownloadDir -Recurse -Force -ErrorAction SilentlyContinue
}
}
Write-Output "Creating Timus download directory..."
New-Item -ItemType Directory -Path $TimusDownloadDir -Force | Out-Null

# Download installer
$TimusDownloaded = $false
try {
Invoke-WebRequest -Uri $TimusDownloadUrl -OutFile $TimusInstallerPath -ErrorAction Stop
Write-Output "Timus installer downloaded via Invoke-WebRequest."
$TimusDownloaded = $true
} catch {
Write-Output "Invoke-WebRequest failed. Trying WebClient..."
try {
(New-Object System.Net.WebClient).DownloadFile($TimusDownloadUrl, $TimusInstallerPath)
Write-Output "Timus installer downloaded via WebClient."
$TimusDownloaded = $true
} catch {
Write-Output "WebClient failed. Trying BITS..."
try {
Start-BitsTransfer -Source $TimusDownloadUrl -Destination $TimusInstallerPath
Write-Output "Timus installer downloaded via BITS."
$TimusDownloaded = $true
} catch {
Write-Host "All download methods failed. Exiting."
Exit 1
}
}
}

# Extract version from downloaded EXE
if (-Not (Test-Path $TimusInstallerPath)) {
Write-Host "Downloaded installer not found. Exiting."
Exit 1
}
$TimusTargetVersion = (Get-Item $TimusInstallerPath).VersionInfo.FileVersion
Write-Host "Latest Timus version from EXE: $TimusTargetVersion"

# Check installed version
$TimusInstalledApp = Get-TimusInstalledApplication
if ($TimusInstalledApp) {
$TimusCurrentVersion = $TimusInstalledApp.DisplayVersion
Write-Host "Installed version: $TimusCurrentVersion"
if ($TimusCurrentVersion -eq $TimusTargetVersion) {
Write-Host "Timus Connect is up to date. Exiting."
Exit 0
} else {
Write-Host "Outdated version detected ($TimusCurrentVersion). Proceeding with update."
}
} else {
Write-Host "Timus Connect not found. Proceeding with fresh install."
}

# Silent install
try {
Start-Process -Wait -FilePath $TimusInstallerPath -ArgumentList "/S" -Verb RunAs -ErrorAction Stop
Write-Host "Timus installation completed."
} catch {
Write-Host "Timus installation failed. Exiting."
Exit 1
}

# Post-install validation
$TimusInstalledApp = Get-TimusInstalledApplication
if ($TimusInstalledApp -and $TimusInstalledApp.DisplayVersion -eq $TimusTargetVersion) {
Write-Host "Timus Connect installed successfully at version $TimusTargetVersion."
} else {
Write-Host "Timus installation failed or incorrect version."
Exit 1
}

# Cleanup
Write-Output "Removing Timus installer directory..."
Remove-Item -Path $TimusDownloadDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Output "Timus install script completed."
Exit 0