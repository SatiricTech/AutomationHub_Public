# Inputs
$AccountKey = "9a94f5b4259d390e8f6b82d3f943b350"
$DirectoryPath = "C:\Temp\Huntress"
$OrganizationKey = "cmg"
if (-not (Test-Path -Path $directoryPath -PathType Container)) {
    New-Item -Path $directoryPath -ItemType Directory
    Write-Host "Directory '$directoryPath' created."
} else {
    Write-Host "Directory '$directoryPath' already exists."
}
cd C:\Temp\Huntress
Invoke-WebRequest -Uri https://github.com/CalicoTechnologies/huntress-deployment-scripts/raw/main/Powershell/InstallHuntress.powershellv2.ps1 -Outfile .\HuntressDeploymentv2.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\HuntressDeploymentv2.ps1 -acctkey $AccountKey -orgkey $OrganizationKey
Start-Sleep -Seconds 15
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Restricted