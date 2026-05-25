# Microsoft 365 Apps Installation Script
# Created for MSP/MSSP business model
# Installs Microsoft 365 Business Standard (not shared computer licensing)

# Set error action preference
$ErrorActionPreference = "Stop"

# Function to write log messages
function Write-LogMessage {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(if($Level -eq "ERROR"){"Red"}elseif($Level -eq "WARNING"){"Yellow"}else{"Green"})
}

# Function to create directory if it doesn't exist
function New-DirectoryIfNotExists {
    param(
        [string]$Path
    )
    
    try {
        if (-not (Test-Path -Path $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-LogMessage "Created directory: $Path"
        } else {
            Write-LogMessage "Directory already exists: $Path"
        }
    }
    catch {
        Write-LogMessage "Failed to create directory $Path`: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

# Function to download file from URL
function Get-FileFromUrl {
    param(
        [string]$Url,
        [string]$DestinationPath
    )
    
    try {
        Write-LogMessage "Downloading file from: $Url"
        Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing
        Write-LogMessage "Successfully downloaded file to: $DestinationPath"
    }
    catch {
        Write-LogMessage "Failed to download file from $Url`: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

# Function to extract Office Deployment Tool
function Extract-OfficeDeploymentTool {
    param(
        [string]$DownloadedFile,
        [string]$ExtractPath
    )
    
    try {
        Write-LogMessage "Extracting Office Deployment Tool from: $DownloadedFile"
        
        # Create extraction directory
        if (-not (Test-Path -Path $ExtractPath)) {
            New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null
        }
        
        # Extract the ODT executable
        $extractProcess = Start-Process -FilePath $DownloadedFile -ArgumentList "/extract:$ExtractPath", "/quiet" -Wait -PassThru
        
        if ($extractProcess.ExitCode -eq 0) {
            Write-LogMessage "Successfully extracted Office Deployment Tool to: $ExtractPath"
            return $true
        } else {
            Write-LogMessage "Failed to extract Office Deployment Tool. Exit code: $($extractProcess.ExitCode)" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-LogMessage "Error extracting Office Deployment Tool: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Function to run Office Deployment Tool
function Invoke-OfficeDeploymentTool {
    param(
        [string]$SetupExePath,
        [string]$ConfigurationXmlPath,
        [string]$Operation = "configure"
    )
    
    try {
        Write-LogMessage "Running Office Deployment Tool ($Operation) with configuration: $ConfigurationXmlPath"
        
        # Run the ODT setup.exe with the configuration XML
        $processArgs = @(
            "/$Operation"
            $ConfigurationXmlPath
        )
        
        Write-LogMessage "Executing: $SetupExePath $($processArgs -join ' ')"
        
        $process = Start-Process -FilePath $SetupExePath -ArgumentList $processArgs -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0) {
            Write-LogMessage "Office Deployment Tool ($Operation) completed successfully"
            return $true
        } else {
            Write-LogMessage "Office Deployment Tool ($Operation) failed with exit code: $($process.ExitCode)" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-LogMessage "Error running Office Deployment Tool ($Operation): $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Main script execution
try {
    Write-LogMessage "Starting Microsoft 365 Apps installation process (Business Standard)"
    
    # Create system root temp directory structure
    $tempDir = Join-Path -Path $env:SystemRoot -ChildPath "\Temp\Sentinel\ToolKit\M365"
    New-DirectoryIfNotExists -Path $tempDir
    
    # Step 1: Download and prepare installation XML
    Write-LogMessage "Step 1: Downloading Microsoft 365 Apps installation configuration"
    
    # Download the XML installation file
    $xmlUrl = "https://raw.githubusercontent.com/Sentinel-Cyber/ScriptHub-Public/main/Microsoft365/Local%20Office%20Apps/365Apps4Business_Standard_NotShared.xml"
    $odtDir = Join-Path -Path $tempDir -ChildPath "ODT"
    New-DirectoryIfNotExists -Path $odtDir
    $xmlPath = Join-Path -Path $odtDir -ChildPath "365Apps4Business_Standard_NotShared.xml"
    
    Get-FileFromUrl -Url $xmlUrl -DestinationPath $xmlPath
    
    # Verify the XML file was downloaded
    if (Test-Path -Path $xmlPath) {
        Write-LogMessage "XML installation file downloaded successfully"
        Write-LogMessage "Installation XML ready: $xmlPath"
    } else {
        throw "XML installation file was not downloaded successfully"
    }
    
    # Step 2: Install Microsoft 365 Apps
    Write-LogMessage "Step 2: Installing Microsoft 365 Apps Business Standard"
    
    # Download Office Deployment Tool
    Write-LogMessage "Downloading Microsoft Office Deployment Tool"
    
    # Parse the download page for the dynamic link
    $response = Invoke-WebRequest -Uri "https://www.microsoft.com/en-us/download/details.aspx?id=49117"
    $downloadUrl = ($response.Links | Where-Object { $_.href -match "download\.microsoft\.com.*\.exe$|download\.microsoft\.com.*\.msi$" }).href
    
    # Log the discovered download URL
    Write-LogMessage "Microsoft Office Deployment Tool download URL: $downloadUrl"
    
    # Extract filename from URL for the download
    $fileName = Split-Path $downloadUrl -Leaf
    $odtDownloadPath = Join-Path -Path $tempDir -ChildPath $fileName
    
    # Download the ODT file
    Get-FileFromUrl -Url $downloadUrl -DestinationPath $odtDownloadPath
    
    # Extract Office Deployment Tool
    $odtExtractPath = Join-Path -Path $tempDir -ChildPath "ODT"
    if (Extract-OfficeDeploymentTool -DownloadedFile $odtDownloadPath -ExtractPath $odtExtractPath) {
        Write-LogMessage "Office Deployment Tool extracted successfully"
        
        # Find the setup.exe file in the extracted directory
        $setupExePath = Get-ChildItem -Path $odtExtractPath -Name "setup.exe" -Recurse | Select-Object -First 1
        if ($setupExePath) {
            $fullSetupPath = Join-Path -Path $odtExtractPath -ChildPath $setupExePath
            Write-LogMessage "Found Office Deployment Tool setup.exe at: $fullSetupPath"
            
            # Step 2a: Download Office installation files using the XML
            Write-LogMessage "Step 2a: Downloading Office installation files using XML configuration"
            if (Invoke-OfficeDeploymentTool -SetupExePath $fullSetupPath -ConfigurationXmlPath $xmlPath -Operation "download") {
                Write-LogMessage "Office installation download completed successfully"
                
                # Step 2b: Configure (install) Office using the XML
                Write-LogMessage "Step 2b: Installing Office applications using XML configuration"
                if (Invoke-OfficeDeploymentTool -SetupExePath $fullSetupPath -ConfigurationXmlPath $xmlPath -Operation "configure") {
                    Write-LogMessage "Office installation configuration completed successfully"
                } else {
                    Write-LogMessage "Office installation configuration failed" -Level "ERROR"
                }
            } else {
                Write-LogMessage "Office installation download failed" -Level "ERROR"
            }
            
        } else {
            Write-LogMessage "setup.exe not found in extracted Office Deployment Tool" -Level "ERROR"
        }
    } else {
        Write-LogMessage "Failed to extract Office Deployment Tool" -Level "ERROR"
    }
    
}
catch {
    Write-LogMessage "Script execution failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}