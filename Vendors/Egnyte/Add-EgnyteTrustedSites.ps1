# ============================================
# CONFIGURATION VARIABLES
# ============================================
$mspName = "MSP Name Here"
$mspRoot = "C:\Windows\Temp\$mspName"

# Registry path for Trusted Sites (Zone 2)
$regPathTemplate = "Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"

# Directory setup
$loggingPath = Join-Path $mspRoot "Logging"
$logFile = Join-Path $loggingPath "TrustedSites_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Ensure logging directory exists
if (-not (Test-Path $loggingPath)) {
    New-Item -Path $loggingPath -ItemType Directory -Force | Out-Null
}

# Function to write to log and console
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to log file
    Add-Content -Path $logFile -Value $logMessage
    
    # Write to console with colors
    switch ($Level) {
        "INFO" { Write-Host $Message -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "WARNING" { Write-Host $Message -ForegroundColor Yellow }
        "ERROR" { Write-Host $Message -ForegroundColor Red }
    }
}

# Function to load a user hive if not already loaded
function Load-UserHive {
    param(
        [string]$UserProfilePath,
        [string]$SID
    )
    
    $ntUserDatPath = Join-Path $UserProfilePath "NTUSER.DAT"
    
    if (Test-Path $ntUserDatPath) {
        # Check if hive is already loaded
        $testPath = "Registry::HKEY_USERS\$SID"
        if (-not (Test-Path $testPath)) {
            try {
                reg load "HKU\$SID" $ntUserDatPath 2>&1 | Out-Null
                Start-Sleep -Milliseconds 500  # Give it a moment to load
                Write-Log "Loaded registry hive for SID: $SID" "SUCCESS"
                return $true
            }
            catch {
                Write-Log "Failed to load registry hive for SID: $SID - Error: $_" "ERROR"
                return $false
            }
        }
        else {
            Write-Log "Registry hive already loaded for SID: $SID" "INFO"
            return $false  # Return false because we didn't load it (it was already loaded)
        }
    }
    else {
        Write-Log "NTUSER.DAT not found at: $ntUserDatPath" "WARNING"
        return $false
    }
}

# Function to unload a user hive
function Unload-UserHive {
    param(
        [string]$SID
    )
    
    try {
        [gc]::Collect()
        Start-Sleep -Milliseconds 500
        reg unload "HKU\$SID" 2>&1 | Out-Null
        Write-Log "Unloaded registry hive for SID: $SID" "SUCCESS"
    }
    catch {
        Write-Log "Failed to unload registry hive for SID: $SID - Error: $_" "WARNING"
    }
}

# Function to add a wildcard subdomain site to Trusted Sites
function Add-HttpsWildcardTrustedSite {
    param(
        [string]$Domain,
        [string]$UserRegPath
    )
    
    try {
        $domainPath = Join-Path $UserRegPath $Domain
        $wildcardPath = Join-Path $domainPath "*"
        
        # Create the domain key if it doesn't exist
        if (-not (Test-Path $domainPath)) {
            New-Item -Path $domainPath -Force | Out-Null
        }
        
        # Create the wildcard subkey under the domain
        if (-not (Test-Path $wildcardPath)) {
            New-Item -Path $wildcardPath -Force | Out-Null
        }
        
        # Set the https property in the wildcard subkey (2 = Trusted Sites zone)
        Set-ItemProperty -Path $wildcardPath -Name "https" -Value 2 -Type DWord
        return $true
    }
    catch {
        Write-Log "Failed to add https://*.$Domain to $UserRegPath - Error: $_" "ERROR"
        return $false
    }
}

# Function to add a file:// protocol site
function Add-FileTrustedSite {
    param(
        [string]$Domain,
        [string]$UserRegPath
    )
    
    try {
        $domainPath = Join-Path $UserRegPath $Domain
        
        # Create the domain key if it doesn't exist
        if (-not (Test-Path $domainPath)) {
            New-Item -Path $domainPath -Force | Out-Null
        }
        
        # Set the file protocol value (2 = Trusted Sites zone)
        Set-ItemProperty -Path $domainPath -Name "file" -Value 2 -Type DWord
        return $true
    }
    catch {
        Write-Log "Failed to add file://$Domain to $UserRegPath - Error: $_" "ERROR"
        return $false
    }
}

# Function to process a single user's registry
function Process-UserRegistry {
    param(
        [string]$UserRegRoot,
        [string]$UserIdentifier
    )
    
    Write-Log "Processing registry for: $UserIdentifier" "INFO"
    
    $regPath = Join-Path $UserRegRoot $regPathTemplate
    
    # Check and add file://egnytedrive
    $egnyteDrivePath = Join-Path $regPath "egnytedrive"
    if (-not (Test-Path $egnyteDrivePath) -or -not (Get-ItemProperty -Path $egnyteDrivePath -Name "file" -ErrorAction SilentlyContinue)) {
        if (Add-FileTrustedSite -Domain "egnytedrive" -UserRegPath $regPath) {
            Write-Log "Added file://egnytedrive for $UserIdentifier" "SUCCESS"
        }
    } else {
        Write-Log "file://egnytedrive already exists for $UserIdentifier" "INFO"
    }
    
    # Check and add https://*.egnyte.com
    $egnyteComPath = Join-Path $regPath "egnyte.com"
    $egnyteWildcardPath = Join-Path $egnyteComPath "*"
    if (-not (Test-Path $egnyteWildcardPath) -or -not (Get-ItemProperty -Path $egnyteWildcardPath -Name "https" -ErrorAction SilentlyContinue)) {
        if (Add-HttpsWildcardTrustedSite -Domain "egnyte.com" -UserRegPath $regPath) {
            Write-Log "Added https://*.egnyte.com for $UserIdentifier" "SUCCESS"
        }
    } else {
        Write-Log "https://*.egnyte.com already exists for $UserIdentifier" "INFO"
    }
}

# Start script
Write-Log "======================================" "INFO"
Write-Log "Trusted Sites Configuration Script (All Users)" "INFO"
Write-Log "======================================" "INFO"
Write-Log "Log file: $logFile" "INFO"

# Get all user profiles
$userProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" | 
    Where-Object { $_.PSChildName -match '^S-1-5-21-[\d\-]+$' } |
    Select-Object @{Name="SID";Expression={$_.PSChildName}}, @{Name="ProfilePath";Expression={$_.ProfileImagePath}}

Write-Log "Found $($userProfiles.Count) user profile(s) to process" "INFO"

foreach ($profile in $userProfiles) {
    $sid = $profile.SID
    $profilePath = $profile.ProfilePath
    
    Write-Log "--------------------------------------" "INFO"
    Write-Log "Processing user profile: $profilePath" "INFO"
    Write-Log "SID: $sid" "INFO"
    
    # Check if the hive is already loaded (user is logged in)
    $hiveAlreadyLoaded = Test-Path "Registry::HKEY_USERS\$sid"
    
    if ($hiveAlreadyLoaded) {
        Write-Log "User registry hive already loaded (user may be logged in)" "INFO"
        Process-UserRegistry -UserRegRoot "Registry::HKEY_USERS\$sid" -UserIdentifier $sid
    }
    else {
        # Need to load the hive
        $loaded = Load-UserHive -UserProfilePath $profilePath -SID $sid
        
        if (Test-Path "Registry::HKEY_USERS\$sid") {
            Process-UserRegistry -UserRegRoot "Registry::HKEY_USERS\$sid" -UserIdentifier $sid
            
            # Only unload if we loaded it (not if it was already loaded)
            if ($loaded) {
                Unload-UserHive -SID $sid
            }
        }
        else {
            Write-Log "Could not access registry hive for SID: $sid" "ERROR"
        }
    }
}

# Also process the current user if running in user context
if ($env:USERNAME -and $env:USERNAME -ne "SYSTEM") {
    Write-Log "--------------------------------------" "INFO"
    Write-Log "Processing current user context: $env:USERNAME" "INFO"
    Process-UserRegistry -UserRegRoot "Registry::HKEY_CURRENT_USER" -UserIdentifier "CURRENT_USER ($env:USERNAME)"
}

Write-Log "======================================" "INFO"
Write-Log "Trusted Sites configuration complete for all users!" "SUCCESS"
Write-Log "======================================" "INFO"