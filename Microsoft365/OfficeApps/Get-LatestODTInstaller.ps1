# Used for when https://officecdn.microsoft.com/pr/wsus/setup.exe is not working.
#
# Parse the download page for the dynamic link
$response = Invoke-WebRequest -Uri "https://www.microsoft.com/en-us/download/details.aspx?id=49117"
$downloadUrl = ($response.Links | Where-Object { $_.href -match "download\.microsoft\.com.*\.exe$|download\.microsoft\.com.*\.msi$" }).href

# Log the discovered download URL
Write-LogMessage "Microsoft Office Deployment Tool download URL: $downloadUrl" -Level "INFO"

# Ensure destination directory exists
$destinationPath = "C:\Temp\M365"
if (!(Test-Path $destinationPath)) {
    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
}

# Extract filename from URL for the download
$fileName = Split-Path $downloadUrl -Leaf
$fullPath = Join-Path $destinationPath $fileName

# Log download initiation
Write-LogMessage "Downloading Office Deployment Tool to: $fullPath" -Level "INFO"

# Download the file
try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $fullPath
    Write-LogMessage "Successfully downloaded Office Deployment Tool to $fullPath" -Level "INFO"
}
catch {
    Write-LogMessage "Failed to download Office Deployment Tool: $($_.Exception.Message)" -Level "ERROR"
}