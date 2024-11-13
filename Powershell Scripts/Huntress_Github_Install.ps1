# Inputs
$AccountKey = "{ACCT KEY FROM HUTNRESS HERE}"
$DirectoryPath = "C:\Temp\Huntress"
$OrganizationKey = "cmg"
if (-not (Test-Path -Path $directoryPath -PathType Container)) {
    New-Item -Path $directoryPath -ItemType Directory
    Write-Host "Directory '$directoryPath' created."
} else {
    Write-Host "Directory '$directoryPath' already exists."
}
cd C:\Temp\Huntress
Invoke-WebRequest -Uri {LINK TO YOUR HUNTRESS POWERSHELL INSTALL FILE IN GITHUB HERE} -Outfile .\HuntressDeploymentv2.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\HuntressDeploymentv2.ps1 -acctkey $AccountKey -orgkey $OrganizationKey
Start-Sleep -Seconds 15
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Restricted
