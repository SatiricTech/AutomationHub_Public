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

# Live Browser History Extraction PowerShell Script (Auto-Close Browsers)
# Extract browser history with automatic browser closure for complete access
# Version 1.6 - Enhanced with audit directories and auto-run capability

param(
    [Alias("o")]
    [string]$OutputFile = "",
    
    [Alias("s")]
    [string]$SearchTerm = "",
    
    [Alias("c")]
    [switch]$Chrome,
    
    [Alias("f")]
    [switch]$Firefox,
    
    [Alias("e")]
    [switch]$Edge,
    
    [Alias("u")]
    [string]$UserProfile = "",
    
    [switch]$AllUsers,
    
    [switch]$NoCloseBrowsers,
    
    [switch]$AutoRun,
    
    [switch]$Help
)

function Show-Usage {
    Write-Host @"
Live Browser History Extraction v1.6 (PowerShell - Auto-Close Browsers)

Usage: .\LiveBrowserHistory.ps1 [options]

Options:
-OutputFile, -o <output_file>
    Where to store this script's output
    Default: C:\Windows\Temp\BrowserHistoryAudit_YYYY-MM-DD_HHMM\browser_history.csv
-SearchTerm, -s <term>
    Only pay attention to URLs that contain this string
-Chrome, -c
    Handle Google Chrome browsing history only
-Firefox, -f
    Handle Mozilla Firefox browsing history only
-Edge, -e
    Handle Microsoft Edge browsing history only
-UserProfile, -u <username>
    Target specific user profile (default: current user)
-AllUsers
    Process all user profiles (requires admin rights)
-NoCloseBrowsers
    Don't automatically close browsers before extraction
-AutoRun
    Run without prompting to close browsers (assumes Yes to all prompts)
-Help
    Show this help message

If no browser switches are specified, all browsers will be processed.
Note: This version automatically closes browsers to ensure complete database access.
"@
}

function Get-HostnameFromUrl {
    param([string]$Url)
    
    try {
        $uri = [System.Uri]$Url
        return $uri.Host
    }
    catch {
        return $null
    }
}

function Test-SearchFilter {
    param([string]$Url, [string]$SearchTerm)
    
    if ([string]::IsNullOrEmpty($SearchTerm)) {
        return $true
    }
    return $Url -like "*$SearchTerm*"
}

function Initialize-OutputDirectory {
    param([string]$CustomOutputFile = "")
    
    # Create timestamped folder name
    $timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
    $auditFolderName = "BrowserHistoryAudit_$timestamp"
    
    # Use Windows system temp directory (C:\Windows\Temp)
    $systemTempPath = "C:\Windows\Temp"
    
    # Verify system temp path exists, create if it doesn't
    if (-not (Test-Path $systemTempPath)) {
        try {
            New-Item -Path $systemTempPath -ItemType Directory -Force | Out-Null
            Write-Host "Created system temp directory: $systemTempPath" -ForegroundColor Yellow
        }
        catch {
            Write-Warning "Could not create system temp directory. Falling back to user temp."
            $systemTempPath = [System.IO.Path]::GetTempPath()
        }
    }
    
    $auditPath = Join-Path $systemTempPath $auditFolderName
    
    # Create the audit directory
    try {
        if (-not (Test-Path $auditPath)) {
            New-Item -Path $auditPath -ItemType Directory -Force | Out-Null
            Write-Host "Created audit directory: $auditPath" -ForegroundColor Green
        }
        
        # Determine output file path
        if ([string]::IsNullOrEmpty($CustomOutputFile)) {
            $outputFile = Join-Path $auditPath "browser_history.csv"
        }
        else {
            # If custom output file provided, use it but ensure it's in our audit directory
            $fileName = [System.IO.Path]::GetFileName($CustomOutputFile)
            $outputFile = Join-Path $auditPath $fileName
        }
        
        return @{
            AuditPath = $auditPath
            OutputFile = $outputFile
            Timestamp = $timestamp
        }
    }
    catch {
        Write-Error "Failed to create audit directory: $($_.Exception.Message)"
        Write-Host "This may require administrator privileges to write to C:\Windows\Temp" -ForegroundColor Yellow
        Write-Host "Try running as administrator or use -OutputFile to specify a different location" -ForegroundColor Yellow
        exit 1
    }
}

function Export-AuditSummary {
    param(
        [string]$AuditPath,
        [string]$Timestamp,
        [array]$UserProfiles,
        [array]$ClosedBrowsers,
        [string]$OutputFile
    )
    
    $summaryFile = Join-Path $AuditPath "audit_summary.txt"
    
    $summary = @"
Browser History Audit Summary
============================
Audit Date/Time: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Audit ID: $Timestamp
Computer: $env:COMPUTERNAME
Current User: $env:USERNAME
PowerShell Version: $($PSVersionTable.PSVersion)

Audit Configuration:
- User Profiles Processed: $($UserProfiles.Count)
- Users: $($UserProfiles.Username -join ', ')
- Browsers Closed: $($ClosedBrowsers -join ', ')
- Output File: $OutputFile

Results:
"@

    if (Test-Path $OutputFile) {
        try {
            $results = Import-Csv $OutputFile
            $summary += @"

- Total History Entries: $($results.Count)
- Browsers Found: $($results | Group-Object Browser | ForEach-Object { "$($_.Name): $($_.Count)" } | Join-String -Separator ', ')
- Date Range: $(if ($results.Count -gt 0) { "Various (timestamps not available in binary extraction)" } else { "No data" })
- Top Domains: $(if ($results.Count -gt 0) { ($results | Group-Object Domain | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { $_.Name } | Where-Object { $_ } | Join-String -Separator ', ') } else { "None" })

"@
        }
        catch {
            $summary += "`n- Error reading results file: $($_.Exception.Message)`n"
        }
    }
    else {
        $summary += "`n- No results file generated`n"
    }

    $summary += @"

Audit Notes:
- This audit used binary extraction methods
- Timestamps may not be available for all entries
- Browser databases were accessed after closing browsers for complete extraction
- For forensic-quality results with timestamps, use dedicated forensic tools

Files Generated:
- browser_history.csv: Main results file with extracted URLs
- audit_summary.txt: This summary file

"@

    try {
        $summary | Out-File -FilePath $summaryFile -Encoding UTF8
        Write-Host "Audit summary saved to: $summaryFile" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to create audit summary: $($_.Exception.Message)"
    }
}

function Close-Browsers {
    param(
        [bool]$SkipClose = $false,
        [bool]$AutoRun = $false
    )
    
    if ($SkipClose) {
        Write-Host "Skipping browser closure (NoCloseBrowsers flag set)" -ForegroundColor Yellow
        return @()
    }
    
    Write-Host "Checking for running browsers..." -ForegroundColor Cyan
    
    $browsersToClose = @(
        @{Name="Chrome"; Process="chrome"; DisplayName="Google Chrome"},
        @{Name="Firefox"; Process="firefox"; DisplayName="Mozilla Firefox"},
        @{Name="Edge"; Process="msedge"; DisplayName="Microsoft Edge"},
        @{Name="IE"; Process="iexplore"; DisplayName="Internet Explorer"}
    )
    
    $closedBrowsersInfo = @()
    $runningBrowsers = @()
    
    foreach ($browser in $browsersToClose) {
        $processes = Get-Process -Name $browser.Process -ErrorAction SilentlyContinue
        if ($processes) {
            $runningBrowsers += $browser.DisplayName
            Write-Host "Found running $($browser.DisplayName) processes: $($processes.Count)" -ForegroundColor Yellow
            
            # Collect detailed info about running processes for restoration
            foreach ($process in $processes) {
                try {
                    $commandLine = ""
                    # Try to get command line arguments (requires WMI)
                    $wmiProcess = Get-WmiObject Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue
                    if ($wmiProcess) {
                        $commandLine = $wmiProcess.CommandLine
                    }
                    
                    $browserInfo = @{
                        DisplayName = $browser.DisplayName
                        ProcessName = $browser.Process
                        CommandLine = $commandLine
                        ProcessId = $process.Id
                    }
                    
                    $closedBrowsersInfo += $browserInfo
                }
                catch {
                    # Fallback: just store basic info
                    $closedBrowsersInfo += @{
                        DisplayName = $browser.DisplayName
                        ProcessName = $browser.Process
                        CommandLine = ""
                        ProcessId = $process.Id
                    }
                }
            }
        }
    }
    
    if ($runningBrowsers.Count -eq 0) {
        Write-Host "No browsers are currently running." -ForegroundColor Green
        return @()
    }
    
    Write-Host "`nRunning browsers detected: $($runningBrowsers -join ', ')" -ForegroundColor Yellow
    Write-Host "These browsers will be closed to ensure complete database access." -ForegroundColor Yellow
    
    if ($AutoRun) {
        Write-Host "AutoRun mode enabled - automatically closing browsers..." -ForegroundColor Cyan
        $proceed = $true
    }
    else {
        $response = Read-Host "Continue and close browsers? (Y/N) [Y]"
        $proceed = (-not $response) -or ($response.ToUpper() -eq 'Y')
    }
    
    if (-not $proceed) {
        Write-Host "Browser closure cancelled. Extraction may be incomplete." -ForegroundColor Yellow
        return @()
    }
    
    Write-Host "`nClosing browsers..." -ForegroundColor Cyan
    
    foreach ($browser in $browsersToClose) {
        $processes = Get-Process -Name $browser.Process -ErrorAction SilentlyContinue
        if ($processes) {
            try {
                Write-Host "Closing $($browser.DisplayName)..."
                
                # Try graceful closure first
                $processes | ForEach-Object {
                    $_.CloseMainWindow() | Out-Null
                }
                
                # Wait a moment for graceful closure
                Start-Sleep -Seconds 3
                
                # Force close any remaining processes
                $remainingProcesses = Get-Process -Name $browser.Process -ErrorAction SilentlyContinue
                if ($remainingProcesses) {
                    Write-Host "Force closing remaining $($browser.DisplayName) processes..."
                    $remainingProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                
                Write-Host "$($browser.DisplayName) closed successfully." -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to close $($browser.DisplayName): $($_.Exception.Message)"
            }
        }
    }
    
    if ($closedBrowsersInfo.Count -gt 0) {
        Write-Host "`nClosed browsers: $($runningBrowsers -join ', ')" -ForegroundColor Green
        Write-Host "Waiting 2 seconds for file handles to release..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
    }
    
    return $closedBrowsersInfo
}

function Restart-Browsers {
    param(
        [array]$BrowsersToRestart,
        [bool]$AutoRun = $false
    )
    
    if ($BrowsersToRestart.Count -eq 0) {
        return
    }
    
    if ($AutoRun) {
        Write-Host "`nAutoRun mode - skipping browser restart prompt." -ForegroundColor Cyan
        return
    }
    
    Write-Host "`nWould you like to restart the closed browsers? (Y/N) [N]" -ForegroundColor Cyan
    $response = Read-Host
    
    if ($response.ToUpper() -eq 'Y') {
        Write-Host "Restarting browsers with original profiles..." -ForegroundColor Cyan
        
        $browserPaths = @{
            "Google Chrome" = @(
                "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
            )
            "Mozilla Firefox" = @(
                "${env:ProgramFiles}\Mozilla Firefox\firefox.exe",
                "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
            )
            "Microsoft Edge" = @(
                "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
            )
        }
        
        # Group browsers by type to avoid duplicate launches
        $browsersToLaunch = @{}
        
        foreach ($browserInfo in $BrowsersToRestart) {
            $browserName = $browserInfo.DisplayName
            $commandLine = $browserInfo.CommandLine
            
            if (-not $browsersToLaunch.ContainsKey($browserName)) {
                $browsersToLaunch[$browserName] = @()
            }
            
            # Extract profile information from command line
            $profileInfo = @{
                CommandLine = $commandLine
                Arguments = ""
            }
            
            # Parse command line for profile-specific arguments
            if ($commandLine) {
                # For Chrome/Edge: look for --profile-directory or --user-data-dir
                if ($browserName -match "Chrome|Edge") {
                    if ($commandLine -match '--profile-directory[=\s]+"?([^"]+)"?') {
                        $profileInfo.Arguments = "--profile-directory=`"$($matches[1])`""
                        Write-Host "  Found profile: $($matches[1]) for $browserName" -ForegroundColor Yellow
                    }
                    elseif ($commandLine -match '--user-data-dir[=\s]+"?([^"]+)"?') {
                        $profileInfo.Arguments = "--user-data-dir=`"$($matches[1])`""
                        Write-Host "  Found user data dir: $($matches[1]) for $browserName" -ForegroundColor Yellow
                    }
                }
                # For Firefox: look for -P or --profile
                elseif ($browserName -match "Firefox") {
                    if ($commandLine -match '-P\s+"?([^"]+)"?') {
                        $profileInfo.Arguments = "-P `"$($matches[1])`""
                        Write-Host "  Found profile: $($matches[1]) for $browserName" -ForegroundColor Yellow
                    }
                    elseif ($commandLine -match '--profile[=\s]+"?([^"]+)"?') {
                        $profileInfo.Arguments = "--profile `"$($matches[1])`""
                        Write-Host "  Found profile dir: $($matches[1]) for $browserName" -ForegroundColor Yellow
                    }
                }
            }
            
            $browsersToLaunch[$browserName] += $profileInfo
        }
        
        # Launch each browser type with its profiles
        foreach ($browserName in $browsersToLaunch.Keys) {
            if ($browserPaths.ContainsKey($browserName)) {
                $executablePath = $null
                
                # Find the browser executable
                foreach ($path in $browserPaths[$browserName]) {
                    if (Test-Path $path) {
                        $executablePath = $path
                        break
                    }
                }
                
                if ($executablePath) {
                    $profiles = $browsersToLaunch[$browserName]
                    $uniqueProfiles = $profiles | Sort-Object Arguments -Unique
                    
                    if ($uniqueProfiles.Count -eq 1 -and [string]::IsNullOrEmpty($uniqueProfiles[0].Arguments)) {
                        # No specific profiles, just launch normally
                        try {
                            Start-Process $executablePath -ErrorAction Stop
                            Write-Host "$browserName restarted successfully." -ForegroundColor Green
                        }
                        catch {
                            Write-Warning "Failed to restart $browserName from $executablePath"
                        }
                    }
                    else {
                        # Launch with specific profiles
                        foreach ($profileInfo in $uniqueProfiles) {
                            if (-not [string]::IsNullOrEmpty($profileInfo.Arguments)) {
                                try {
                                    Start-Process $executablePath -ArgumentList $profileInfo.Arguments -ErrorAction Stop
                                    Write-Host "$browserName restarted with profile arguments: $($profileInfo.Arguments)" -ForegroundColor Green
                                }
                                catch {
                                    Write-Warning "Failed to restart $browserName with profile: $($profileInfo.Arguments)"
                                }
                            }
                            else {
                                # Fallback to default launch
                                try {
                                    Start-Process $executablePath -ErrorAction Stop
                                    Write-Host "$browserName restarted (default profile)." -ForegroundColor Green
                                }
                                catch {
                                    Write-Warning "Failed to restart $browserName"
                                }
                            }
                        }
                    }
                }
                else {
                    Write-Warning "Could not find executable for $browserName"
                }
            }
        }
    }
}

function Get-UserProfiles {
    param([string]$SpecificUser, [bool]$AllUsers)
    
    $profiles = @()
    
    if ($AllUsers) {
        $userFolders = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notmatch '^(Public|Default|All Users)$' }
        foreach ($folder in $userFolders) {
            $profiles += @{
                Username = $folder.Name
                Path = $folder.FullName
            }
        }
    }
    elseif (-not [string]::IsNullOrEmpty($SpecificUser)) {
        $userPath = "C:\Users\$SpecificUser"
        if (Test-Path $userPath) {
            $profiles += @{
                Username = $SpecificUser
                Path = $userPath
            }
        }
        else {
            Write-Warning "User profile not found: $SpecificUser"
        }
    }
    else {
        $profiles += @{
            Username = $env:USERNAME
            Path = $env:USERPROFILE
        }
    }
    
    return $profiles
}

function Test-DatabaseAccess {
    param([string]$DatabasePath)
    
    try {
        # Try to open the file for reading
        $file = [System.IO.File]::OpenRead($DatabasePath)
        $file.Close()
        return $true
    }
    catch {
        return $false
    }
}

function Read-BinaryFile {
    param(
        [string]$FilePath,
        [int]$MaxBytes = 50MB
    )
    
    try {
        $fileInfo = Get-Item $FilePath
        $bytesToRead = [Math]::Min($fileInfo.Length, $MaxBytes)
        
        $bytes = New-Object byte[] $bytesToRead
        $stream = [System.IO.File]::OpenRead($FilePath)
        $stream.Read($bytes, 0, $bytesToRead) | Out-Null
        $stream.Close()
        
        return $bytes
    }
    catch {
        Write-Warning "Could not read file: $FilePath - $($_.Exception.Message)"
        return $null
    }
}

function Find-URLsInBinary {
    param(
        [byte[]]$Bytes,
        [string]$SearchTerm = ""
    )
    
    $urls = @()
    
    if (-not $Bytes) { return $urls }
    
    # Convert bytes to string and look for URL patterns
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes)
    
    # Common URL patterns
    $urlPatterns = @(
        'https?://[^\s<>"{}|\\^`\[\]\x00-\x1F]+',
        'www\.[^\s<>"{}|\\^`\[\]\x00-\x1F]+\.[a-zA-Z]{2,}'
    )
    
    foreach ($pattern in $urlPatterns) {
        $matches = [regex]::Matches($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($match in $matches) {
            $url = $match.Value.Trim()
            # Filter out obviously invalid URLs
            if ($url.Length -gt 10 -and $url.Length -lt 2000 -and $url -notmatch '[\x00-\x08\x0B\x0C\x0E-\x1F]') {
                if (Test-SearchFilter $url $SearchTerm) {
                    $urls += $url
                }
            }
        }
    }
    
    return $urls | Sort-Object -Unique
}

function Get-ChromeHistoryBinary {
    param([array]$UserProfiles, [string]$SearchTerm, [string]$OutputFile)
    
    Write-Host "Processing Chrome history (enhanced binary method)..." -ForegroundColor Cyan
    $allEntries = @()
    $accessibleDatabases = 0
    $totalDatabases = 0
    
    foreach ($profile in $UserProfiles) {
        $chromePaths = @()
        
        $chromeBase = "$($profile.Path)\AppData\Local\Google\Chrome\User Data"
        if (Test-Path $chromeBase) {
            $defaultHistory = "$chromeBase\Default\History"
            if (Test-Path $defaultHistory) {
                $chromePaths += $defaultHistory
            }
            
            $namedProfiles = Get-ChildItem "$chromeBase\Profile*" -Directory -ErrorAction SilentlyContinue
            foreach ($namedProfile in $namedProfiles) {
                $historyPath = "$($namedProfile.FullName)\History"
                if (Test-Path $historyPath) {
                    $chromePaths += $historyPath
                }
            }
        }
        
        foreach ($dbPath in $chromePaths) {
            $totalDatabases++
            Write-Host "  Checking: $dbPath"
            
            # Test database access first
            if (-not (Test-DatabaseAccess $dbPath)) {
                Write-Warning "  Cannot access Chrome database (browser may still be running)"
                continue
            }
            
            $accessibleDatabases++
            
            try {
                $bytes = Read-BinaryFile -FilePath $dbPath -MaxBytes 50MB
                if ($bytes) {
                    $urls = Find-URLsInBinary -Bytes $bytes -SearchTerm $SearchTerm
                    Write-Host "  Found $($urls.Count) URLs in this database" -ForegroundColor Green
                    foreach ($url in $urls) {
                        $hostname = Get-HostnameFromUrl $url
                        $allEntries += [PSCustomObject]@{
                            Timestamp = "Unknown"
                            Domain = $hostname
                            Title = $null
                            URL = $url
                            Browser = "Chrome"
                            User = $profile.Username
                        }
                    }
                }
            }
            catch {
                Write-Warning "  Failed to process Chrome database: $($_.Exception.Message)"
            }
        }
    }
    
    if ($allEntries.Count -gt 0) {
        $allEntries | Export-Csv -Path $OutputFile -Append -NoTypeInformation -Encoding UTF8
    }
    Write-Host "Chrome: Found $($allEntries.Count) entries from $accessibleDatabases/$totalDatabases accessible databases" -ForegroundColor Green
}

function Get-FirefoxHistoryBinary {
    param([array]$UserProfiles, [string]$SearchTerm, [string]$OutputFile)
    
    Write-Host "Processing Firefox history (enhanced binary method)..." -ForegroundColor Cyan
    $allEntries = @()
    $accessibleDatabases = 0
    $totalDatabases = 0
    
    foreach ($profile in $UserProfiles) {
        $firefoxBase = "$($profile.Path)\AppData\Roaming\Mozilla\Firefox\Profiles"
        if (-not (Test-Path $firefoxBase)) { continue }
        
        $firefoxProfiles = Get-ChildItem "$firefoxBase\*\places.sqlite" -ErrorAction SilentlyContinue
        
        foreach ($dbPath in $firefoxProfiles) {
            $totalDatabases++
            Write-Host "  Checking: $dbPath"
            
            # Test database access first
            if (-not (Test-DatabaseAccess $dbPath)) {
                Write-Warning "  Cannot access Firefox database (browser may still be running)"
                continue
            }
            
            $accessibleDatabases++
            
            try {
                $bytes = Read-BinaryFile -FilePath $dbPath -MaxBytes 50MB
                if ($bytes) {
                    $urls = Find-URLsInBinary -Bytes $bytes -SearchTerm $SearchTerm
                    Write-Host "  Found $($urls.Count) URLs in this database" -ForegroundColor Green
                    foreach ($url in $urls) {
                        $hostname = Get-HostnameFromUrl $url
                        $allEntries += [PSCustomObject]@{
                            Timestamp = "Unknown"
                            Domain = $hostname
                            Title = $null
                            URL = $url
                            Browser = "Firefox"
                            User = $profile.Username
                        }
                    }
                }
            }
            catch {
                Write-Warning "  Failed to process Firefox database: $($_.Exception.Message)"
            }
        }
    }
    
    if ($allEntries.Count -gt 0) {
        $allEntries | Export-Csv -Path $OutputFile -Append -NoTypeInformation -Encoding UTF8
    }
    Write-Host "Firefox: Found $($allEntries.Count) entries from $accessibleDatabases/$totalDatabases accessible databases" -ForegroundColor Green
}

function Get-EdgeHistoryBinary {
    param([array]$UserProfiles, [string]$SearchTerm, [string]$OutputFile)
    
    Write-Host "Processing Microsoft Edge history (enhanced binary method)..." -ForegroundColor Cyan
    $allEntries = @()
    $accessibleDatabases = 0
    $totalDatabases = 0
    
    foreach ($profile in $UserProfiles) {
        $edgeBase = "$($profile.Path)\AppData\Local\Microsoft\Edge\User Data"
        if (-not (Test-Path $edgeBase)) { continue }
        
        $edgePaths = @()
        
        $defaultHistory = "$edgeBase\Default\History"
        if (Test-Path $defaultHistory) {
            $edgePaths += $defaultHistory
        }
        
        $namedProfiles = Get-ChildItem "$edgeBase\Profile*" -Directory -ErrorAction SilentlyContinue
        foreach ($namedProfile in $namedProfiles) {
            $historyPath = "$($namedProfile.FullName)\History"
            if (Test-Path $historyPath) {
                $edgePaths += $historyPath
            }
        }
        
        foreach ($dbPath in $edgePaths) {
            $totalDatabases++
            Write-Host "  Checking: $dbPath"
            
            # Test database access first
            if (-not (Test-DatabaseAccess $dbPath)) {
                Write-Warning "  Cannot access Edge database (browser may still be running)"
                continue
            }
            
            $accessibleDatabases++
            
            try {
                $bytes = Read-BinaryFile -FilePath $dbPath -MaxBytes 50MB
                if ($bytes) {
                    $urls = Find-URLsInBinary -Bytes $bytes -SearchTerm $SearchTerm
                    Write-Host "  Found $($urls.Count) URLs in this database" -ForegroundColor Green
                    foreach ($url in $urls) {
                        $hostname = Get-HostnameFromUrl $url
                        $allEntries += [PSCustomObject]@{
                            Timestamp = "Unknown"
                            Domain = $hostname
                            Title = $null
                            URL = $url
                            Browser = "Edge"
                            User = $profile.Username
                        }
                    }
                }
            }
            catch {
                Write-Warning "  Failed to process Edge database: $($_.Exception.Message)"
            }
        }
    }
    
    if ($allEntries.Count -gt 0) {
        $allEntries | Export-Csv -Path $OutputFile -Append -NoTypeInformation -Encoding UTF8
    }
    Write-Host "Edge: Found $($allEntries.Count) entries from $accessibleDatabases/$totalDatabases accessible databases" -ForegroundColor Green
}

function Get-IEEdgeHistoryFromRegistry {
    param([array]$UserProfiles, [string]$SearchTerm, [string]$OutputFile)
    
    Write-Host "Processing IE/Edge history from registry..." -ForegroundColor Cyan
    $allEntries = @()
    
    foreach ($profile in $UserProfiles) {
        try {
            # For current user, use HKCU directly
            if ($profile.Username -eq $env:USERNAME) {
                $regPath = "HKCU:\Software\Microsoft\Internet Explorer\TypedURLs"
            }
            else {
                # For other users, we'd need to load their registry hive
                # This requires admin privileges and is more complex
                Write-Host "  Skipping registry for user $($profile.Username) (requires admin and registry loading)"
                continue
            }
            
            if (Test-Path $regPath) {
                $typedUrls = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                if ($typedUrls) {
                    $urlCount = 0
                    $typedUrls.PSObject.Properties | Where-Object { $_.Name -match '^url\d+$' } | ForEach-Object {
                        $url = $_.Value
                        if (Test-SearchFilter $url $SearchTerm) {
                            $hostname = Get-HostnameFromUrl $url
                            $allEntries += [PSCustomObject]@{
                                Timestamp = "Unknown"
                                Domain = $hostname
                                Title = $null
                                URL = $url
                                Browser = "IE/Edge"
                                User = $profile.Username
                            }
                            $urlCount++
                        }
                    }
                    Write-Host "  Found $urlCount URLs in registry for $($profile.Username)" -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Warning "  Failed to process IE/Edge registry for user $($profile.Username): $($_.Exception.Message)"
        }
    }
    
    if ($allEntries.Count -gt 0) {
        $allEntries | Export-Csv -Path $OutputFile -Append -NoTypeInformation -Encoding UTF8
    }
    Write-Host "IE/Edge Registry: Found $($allEntries.Count) entries" -ForegroundColor Green
}

# Main execution
if ($Help) {
    Show-Usage
    exit 0
}

Write-Host "Browser History Extraction v1.6 - Auto-Close Browsers for Complete Access" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($AutoRun) {
    Write-Host "AutoRun mode enabled - running without user prompts" -ForegroundColor Yellow
}

# Initialize output directory and file paths
$auditInfo = Initialize-OutputDirectory $OutputFile
$OutputFile = $auditInfo.OutputFile
$auditPath = $auditInfo.AuditPath
$timestamp = $auditInfo.Timestamp

Write-Host "Audit ID: $timestamp" -ForegroundColor Cyan
Write-Host "Audit Directory: $auditPath" -ForegroundColor Cyan

# Store which browsers are running so we can offer to restart them
$runningBrowsers = @()
$browsersToCheck = @("chrome", "firefox", "msedge", "iexplore")
foreach ($browserProcess in $browsersToCheck) {
    $processes = Get-Process -Name $browserProcess -ErrorAction SilentlyContinue
    if ($processes) {
        switch ($browserProcess) {
            "chrome" { $runningBrowsers += "Google Chrome" }
            "firefox" { $runningBrowsers += "Mozilla Firefox" }
            "msedge" { $runningBrowsers += "Microsoft Edge" }
            "iexplore" { $runningBrowsers += "Internet Explorer" }
        }
    }
}

# Close browsers unless user specifically requests not to (returns detailed browser info)
$closedBrowsersInfo = Close-Browsers -SkipClose $NoCloseBrowsers -AutoRun $AutoRun

Write-Host "Note: This method extracts URLs from browser databases using enhanced binary parsing." -ForegroundColor Yellow
Write-Host "With browsers closed, we can access complete databases for better extraction." -ForegroundColor Yellow

# Get user profiles to process
$userProfiles = Get-UserProfiles $UserProfile $AllUsers

if ($userProfiles.Count -eq 0) {
    Write-Error "No user profiles found to process."
    exit 1
}

Write-Host "`nProcessing $($userProfiles.Count) user profile(s)..." -ForegroundColor Cyan

# Clear output file if it exists
if (Test-Path $OutputFile) {
    Remove-Item $OutputFile -Force
}

# Process browsers based on switches
$processAll = -not ($Chrome -or $Firefox -or $Edge)

if ($Firefox -or $processAll) {
    Get-FirefoxHistoryBinary $userProfiles $SearchTerm $OutputFile
}

if ($Chrome -or $processAll) {
    Get-ChromeHistoryBinary $userProfiles $SearchTerm $OutputFile
}

if ($Edge -or $processAll) {
    Get-EdgeHistoryBinary $userProfiles $SearchTerm $OutputFile
}

# Always try to get IE/Edge from registry
Get-IEEdgeHistoryFromRegistry $userProfiles $SearchTerm $OutputFile

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "Browser history extraction complete!" -ForegroundColor Green
Write-Host "Audit Directory: $auditPath" -ForegroundColor Green
Write-Host "Results File: $OutputFile" -ForegroundColor Green

# Generate audit summary
$closedBrowserNames = $closedBrowsersInfo | ForEach-Object { $_.DisplayName } | Sort-Object -Unique
Export-AuditSummary -AuditPath $auditPath -Timestamp $timestamp -UserProfiles $userProfiles -ClosedBrowsers $closedBrowserNames -OutputFile $OutputFile

# Offer to restart browsers that were closed
if ($closedBrowsersInfo.Count -gt 0) {
    Restart-Browsers -BrowsersToRestart $closedBrowsersInfo -AutoRun $AutoRun
}

# Summary and preview
if (Test-Path $OutputFile) {
    try {
        $results = Import-Csv $OutputFile
        Write-Host "`nSummary:" -ForegroundColor Cyan
        Write-Host "Total entries found: $($results.Count)"
        
        # Browser breakdown
        $browserCounts = $results | Group-Object Browser | Sort-Object Count -Descending
        foreach ($browser in $browserCounts) {
            Write-Host "  $($browser.Name): $($browser.Count) entries"
        }
        
        # Domain breakdown (top 10)
        Write-Host "`nTop 10 domains:" -ForegroundColor Cyan
        $results | Group-Object Domain | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
            if ($_.Name) {
                Write-Host "  $($_.Name): $($_.Count) visits"
            }
        }
        
        # Show first few entries as preview
        Write-Host "`nPreview of results:" -ForegroundColor Cyan
        $results | Select-Object -First 5 | Format-Table -AutoSize -Wrap
    }
    catch {
        Write-Warning "Could not generate summary: $($_.Exception.Message)"
    }
}
else {
    Write-Warning "No output file was created. Check for errors above."
}

Write-Host "`nNote: This method may not capture all history entries or timestamps." -ForegroundColor Yellow
Write-Host "For complete extraction with timestamps, use a dedicated forensic tool." -ForegroundColor Yellow
Write-Host "`nAudit files saved to: $auditPath" -ForegroundColor Cyan

if (-not $AutoRun) {
    Write-Host "Open audit directory? (Y/N) [N]" -ForegroundColor Cyan -NoNewline
    $openResponse = Read-Host " "
    if ($openResponse.ToUpper() -eq 'Y') {
        try {
            Start-Process explorer.exe $auditPath
        }
        catch {
            Write-Warning "Could not open directory: $($_.Exception.Message)"
        }
    }
}
else {
    Write-Host "AutoRun mode - skipping directory open prompt." -ForegroundColor Yellow
}