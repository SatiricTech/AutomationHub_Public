# Get disk information for all drives
Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.Size -gt 0 } | ForEach-Object {
    $drive = $_.DeviceID
    $totalSizeGB = [math]::Round($_.Size / 1GB, 2)
    $freeSpaceGB = [math]::Round($_.FreeSpace / 1GB, 2)
    $freeSpacePercent = [math]::Round(($_.FreeSpace / $_.Size) * 100, 2)
    
    [PSCustomObject]@{
        Drive = $drive
        'Total Size (GB)' = $totalSizeGB
        'Free Space (GB)' = $freeSpaceGB
        'Free Space (%)' = $freeSpacePercent
    }
} | Format-Table -AutoSize

# Alternative version using Get-Volume (Windows 8/Server 2012 and newer)
# Uncomment the section below if you prefer this method:

<#
Write-Host "`nAlternative method using Get-Volume:" -ForegroundColor Green
Get-Volume | Where-Object { $_.Size -gt 0 -and $_.DriveLetter } | ForEach-Object {
    $totalSizeGB = [math]::Round($_.Size / 1GB, 2)
    $freeSpaceGB = [math]::Round($_.SizeRemaining / 1GB, 2)
    $freeSpacePercent = [math]::Round(($_.SizeRemaining / $_.Size) * 100, 2)
    
    [PSCustomObject]@{
        Drive = "$($_.DriveLetter):"
        'Total Size (GB)' = $totalSizeGB
        'Free Space (GB)' = $freeSpaceGB
        'Free Space (%)' = $freeSpacePercent
        'File System' = $_.FileSystem
    }
} | Format-Table -AutoSize
#>