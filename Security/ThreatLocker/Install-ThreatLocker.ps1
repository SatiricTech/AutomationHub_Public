##################################################################################################
#### INFORMATIONAL
#### This script requires you provide your threatlocker Unique Identifier in the License variable.
#### As written it assumes you have this UID in a Organization custom field called "tllicense"
##################################################################################################

[Net.ServicePointManager]::SecurityProtocol = "Tls12"

## Variables
$organizationName = $env:NINJA_ORGANIZATION_NAME
$License = Ninja-Property-Get tllicense

## Check if C:\Temp directory exists and create if not
if (!(Test-Path "C:\Temp")) {
    mkdir "C:\Temp";
}

## Check the OS architecture and download the correct installer
try {
    if ([Environment]::Is64BitOperatingSystem) {
        $downloadURL = "https://api.threatlocker.com/updates/installers/threatlockerstubx64.exe";
    }
    else {
        $downloadURL = "https://api.threatlocker.com/updates/installers/threatlockerstubx86.exe";
    }

    $localInstaller = "C:\Temp\ThreatLockerStub.exe";

    Invoke-WebRequest -Uri $downloadURL -OutFile $localInstaller;
    
}
catch {
    Write-Output "Failed to get download the installer";
    Exit 1;
}

## Attempt install
try {
    & C:\Temp\ThreatLockerStub.exe Instance="F" key="$License" Company=$organizationName;
}
catch {
    Write-Output "Installation Failed";
    Exit 1
}

## Verify install
$service = Get-Service -Name ThreatLockerService -ErrorAction SilentlyContinue;

if ($service.Name -eq "ThreatLockerService" -and $service.Status -eq "Running") {
    Write-Output "Installation successful";
    Exit 0;
}
else {
    ## Check the OS type
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    
    if ($osInfo.ProductType -ne 1) {
        Write-Output "Installation Failed";
        Exit 1
    }
}