#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!#
#  ╔═══╗ ╔═══╗ ╔═╗ ╔╗ ╔════╗ ╔══╗ ╔═╗ ╔╗ ╔═══╗ ╔╗     #
#  ║╔═╗║ ║╔══╝ ║║╚╗║║ ║╔╗╔╗║ ╚╣╠╝ ║║╚╗║║ ║╔══╝ ║║     #
#  ║╚══╗ ║╚══╗ ║╔╗╚╝║ ╚╝║║╚╝  ║║  ║╔╗╚╝║ ║╚══╗ ║║     #
#  ╚══╗║ ║╔══╝ ║║╚╗║║   ║║    ║║  ║║╚╗║║ ║╔══╝ ║║     #
#  ║╚═╝║ ║╚══╗ ║║ ║║║  ╔╝╚╗  ╔╣╠╗ ║║ ║║║ ║╚══╗ ║╚══╗  #
#  ╚═══╝ ╚═══╝ ╚╝ ╚═╝  ╚══╝  ╚══╝ ╚╝ ╚═╝ ╚═══╝ ╚═══╝  #
#>>>>>>>>>>>>>>>>>>>> [SYSTEM::ACTIVE] <<<<<<<<<<<<<<<<<<<<<<<<#
#######################CYBER DEFENSE ###########################
#####################╔═╗╔═╗╔═╗╔ ╗╦═╗╔═╗#########################
#####################╚═╗║╣ ║  ║ ║╠╦╝║╣ #########################
#####################╚═╝╚═╝╚═╝╚═╝╩╚═╚═╝#########################
#!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!#

#############################
# Author: Ramon DeWitt
# Last Updated: 2025-05-18
# Version: 2.1
# Description: This script is used to handle clean installs and cleanup uninstallations of SentinelOne agents. This has only been tested on supported version of CURRENT Windows.
# Editing the $Mode variable will allow you to choose between Install or Clean.
#############################


#############################
# SentinelOne Install & Cleanup Script
#############################

#############################
# ScreenConnect Tags
#############################

#!ps
#timeout=180000

param (
    [Parameter()]
    [ValidateSet("Install", "Clean")]
    [string]$Mode = "Clean",
    
    [Parameter()]
    [switch]$Force = $false
)

#############################
# Config Variables REQUIRED
#############################
$apiToken = "{API_TOKEN_HERE}"
$consoleUrl = "{https://CONSOLE_URL.net}"
$siteId = "{SITE_ID_HERE}"
$siteToken = "{SITE_TOKEN_HERE}"
#############################
# Config Variables REQUIRED
#############################



# Headers for API requests
$headers = @{
    "Authorization" = "ApiToken $apiToken"
    "Content-Type" = "application/json"
}

# Create temp directory for download
$tempDir = "C:\Temp\SentinelOne"
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# Installer path
$installerPath = "$tempDir\SentinelOneInstaller.exe"

# Function to write logs
function Write-Log {
    param([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $message"
    Add-Content -Path "$tempDir\S1_Script_Log.txt" -Value "[$timestamp] $message"
}

# Function to download the installer
function Download-Installer {
    Write-Log "Checking if installer needs to be downloaded"
    
    $needsDownload = $true
    
    if (Test-Path $installerPath) {
        if (-not $Force) {
            $fileInfo = Get-Item $installerPath
            # Only download if file is older than 30 days or smaller than 1MB (likely corrupted)
            if ($fileInfo.LastWriteTime -gt (Get-Date).AddDays(-30) -and $fileInfo.Length -gt 1MB) {
                Write-Log "Using existing installer (use -Force to force a new download)"
                $needsDownload = $false
            } else {
                Write-Log "Existing installer is old or potentially corrupted, will download a fresh copy"
            }
        } else {
            Write-Log "Force flag set, will download a fresh copy of the installer"
        }
    }
    
    if ($needsDownload) {
        try {
            # Get the latest Windows agent packages
            Write-Log "Fetching Windows agent packages"
            $apiEndpoint = "/web/api/v2.1/update/agent/packages"
            
            # Build query parameters based on the API documentation
            $queryParams = @(
                "siteIds=$siteId",
                "osTypes=windows",
                "limit=10",
                "sortBy=version",
                "sortOrder=desc"
            )
            
            $queryString = $queryParams -join "&"
            $fullUrl = "$consoleUrl$apiEndpoint`?$queryString"
            
            Write-Log "API URL: $fullUrl"
            $response = Invoke-RestMethod -Uri $fullUrl -Headers $headers -Method Get
            
            Write-Log "Found $($response.pagination.totalItems) packages"
            
            if ($response.data.Count -eq 0) {
                Write-Log "No matching agent packages found"
                return $false
            }
            
            # Find the latest GA package for Windows
            $package = $null
            foreach ($pkg in $response.data) {
                Write-Log "Found package: $($pkg.version), Status: $($pkg.status), OS: $($pkg.osType), Arch: $($pkg.osArch)"
                # Select the first package
                if (-not $package) {
                    $package = $pkg
                    Write-Log "Selected package: $($package.version) (ID: $($package.id))"
                }
            }
            
            if (-not $package) {
                Write-Log "No suitable package found"
                return $false
            }
            
            # Download the agent package using the correct endpoint format
            $packageId = $package.id
            $downloadEndpoint = "/web/api/v2.1/update/agent/download/$packageId"
            $downloadUrl = "$consoleUrl$downloadEndpoint"
            
            Write-Log "Downloading agent from: $downloadUrl"
            
            # Remove existing installer if present
            if (Test-Path $installerPath) {
                Remove-Item $installerPath -Force
            }
            
            # Download the file
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("Authorization", "ApiToken $apiToken")
            $webClient.DownloadFile($downloadUrl, $installerPath)
            
            # Verify download was successful
            if (-not (Test-Path $installerPath)) {
                Write-Log "Failed to download installer package"
                return $false
            }
            
            $fileInfo = Get-Item $installerPath
            Write-Log "Agent package downloaded successfully to: $installerPath (Size: $($fileInfo.Length) bytes)"
            
            return $true
        }
        catch {
            Write-Log "ERROR during download: $_"
            Write-Log "Stack Trace: $($_.ScriptStackTrace)"
            return $false
        }
    }
    
    return $true
}

# Function to perform installation
function Install-SentinelOne {
    try {
        # Parse version to determine installation method
        $fileInfo = Get-Item $installerPath
        $fileVersion = $fileInfo.VersionInfo.FileVersion
        
        if ([string]::IsNullOrEmpty($fileVersion)) {
            # Try to extract version from filename or use a default
            $versionString = "22.0.0.0"
            Write-Log "Could not determine version from file properties, assuming $versionString"
        } else {
            $versionString = $fileVersion
            Write-Log "Detected version: $versionString"
        }
        
        if ($versionString -match "^(\d+)\.") {
            $majorVersion = [int]$matches[1]
            Write-Log "Major version: $majorVersion"
        } else {
            $majorVersion = 22  # Default to newer version syntax
            Write-Log "Could not parse major version, defaulting to newer installation method"
        }
        
        # Install the agent with appropriate arguments based on version
        if ($majorVersion -ge 22) {
            # For version 22+ use new CLI syntax
            $installArgs = "-t $siteToken -q"
            Write-Log "Using version 22+ installation syntax: $installArgs"
        } else {
            # For older versions use the old syntax
            $installArgs = "/SITE_TOKEN=$siteToken /quiet"
            Write-Log "Using legacy installation syntax: $installArgs"
        }
        
        # Execute the installer
        Write-Log "Installing SentinelOne agent..."
        $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        
        $exitCode = $process.ExitCode
        Write-Log "Installation process completed with exit code: $exitCode"
        
        if ($exitCode -eq 0) {
            Write-Log "SentinelOne agent installed successfully"
            return $true
        } else {
            Write-Log "Installation may have encountered issues. Exit code: $exitCode"
            return $false
        }
    }
    catch {
        Write-Log "ERROR during installation: $_"
        Write-Log "Stack Trace: $($_.ScriptStackTrace)"
        return $false
    }
}

# Function to clean/repair SentinelOne
function Clean-SentinelOne {
    try {
        Write-Log "Running SentinelOne cleanup..."
        
        # The -c flag is for cleanup mode
        $cleanArgs = "-c -t $siteToken"
        Write-Log "Using cleanup syntax: $cleanArgs"
        
        # Execute the installer in cleanup mode
        $process = Start-Process -FilePath $installerPath -ArgumentList $cleanArgs -Wait -PassThru -NoNewWindow
        
        $exitCode = $process.ExitCode
        Write-Log "Cleanup process completed with exit code: $exitCode"
        
        if ($exitCode -eq 0) {
            Write-Log "SentinelOne cleanup completed successfully"
            return $true
        } else {
            Write-Log "Cleanup may have encountered issues. Exit code: $exitCode"
            return $false
        }
    }
    catch {
        Write-Log "ERROR during cleanup: $_"
        Write-Log "Stack Trace: $($_.ScriptStackTrace)"
        return $false
    }
}

# Main script execution
Write-Log "Starting SentinelOne script in $Mode mode"

# Always ensure we have the installer
$downloadSuccess = Download-Installer
if (-not $downloadSuccess) {
    Write-Log "Failed to ensure installer is available. Cannot proceed."
    exit 1
}

# Execute the requested mode
if ($Mode -eq "Install") {
    Write-Log "Running in Installation mode"
    $success = Install-SentinelOne
    
    if ($success) {
        Write-Log "SentinelOne installation completed successfully"
        exit 0
    } else {
        Write-Log "SentinelOne installation failed"
        exit 1
    }
} 
elseif ($Mode -eq "Clean") {
    Write-Log "Running in Cleanup mode"
    $success = Clean-SentinelOne
    
    if ($success) {
        Write-Log "SentinelOne cleanup completed successfully"
        exit 0
    } else {
        Write-Log "SentinelOne cleanup failed"
        exit 1
    }
}