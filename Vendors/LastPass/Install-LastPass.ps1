#### NOT PRODUCTION READY!!!!!!!!!!!!!!!!!!!!!!!!!!!!

#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Checks for and downloads LastPass desktop application and browser extensions for Windows 11.

.DESCRIPTION
    This script checks if LastPass is installed on the system and in supported browsers (Edge, Chrome, Firefox).
    If not found, it downloads and installs the LastPass Universal MSI installer with silent deployment.
    The MSI installer includes the desktop app and browser extensions for detected browsers.

.PARAMETER EnableLogging
    Enable verbose logging during MSI installation for troubleshooting.

.NOTES
    File Name      : Install-LastPass.ps1
    Author         : Ramon
    Prerequisite   : PowerShell 5.1 or higher, Administrator privileges
    Version        : 2.0
    
.EXAMPLE
    .\Install-LastPass.ps1
    
    Runs the script interactively with prompts for installation options.

.LINK
    https://support.lastpass.com/help/install-lastpass-software-using-the-admin-console-lp010069
#>

# Set error action preference
$ErrorActionPreference = "Stop"

# Color functions for output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check if LastPass desktop app is installed
function Test-LastPassInstalled {
    Write-ColorOutput "`n[*] Checking for LastPass desktop application..." "Cyan"
    
    $lastPassPaths = @(
        "${env:ProgramFiles}\LastPass\LastPass.exe",
        "${env:ProgramFiles(x86)}\LastPass\LastPass.exe",
        "${env:LOCALAPPDATA}\LastPass\LastPass.exe"
    )
    
    foreach ($path in $lastPassPaths) {
        if (Test-Path $path) {
            Write-ColorOutput "[+] LastPass desktop app found at: $path" "Green"
            return $true
        }
    }
    
    Write-ColorOutput "[-] LastPass desktop app not found" "Yellow"
    return $false
}

# Function to check if a browser is installed
function Test-BrowserInstalled {
    param(
        [string]$BrowserName
    )
    
    $browserPaths = @{
        "Chrome" = @(
            "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
        )
        "Edge" = @(
            "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        )
        "Firefox" = @(
            "${env:ProgramFiles}\Mozilla Firefox\firefox.exe",
            "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
        )
    }
    
    foreach ($path in $browserPaths[$BrowserName]) {
        if (Test-Path $path) {
            return $true
        }
    }
    
    return $false
}

# Function to check browser extensions
function Test-BrowserExtension {
    param(
        [string]$BrowserName,
        [string]$ExtensionPath
    )
    
    Write-ColorOutput "`n[*] Checking for LastPass extension in $BrowserName..." "Cyan"
    
    # First check if browser is installed
    if (-not (Test-BrowserInstalled -BrowserName $BrowserName)) {
        Write-ColorOutput "[-] $BrowserName is not installed on this system" "DarkGray"
        return $false
    }
    
    if (Test-Path $ExtensionPath) {
        $extensionDirs = Get-ChildItem -Path $ExtensionPath -Directory -ErrorAction SilentlyContinue
        $lastPassExtension = $extensionDirs | Where-Object { 
            $_.Name -match "hdokiejnpimakedhajhdlcegeplioahd|debgaelkhoipmbjnhpoblmbacnmmgbeg|lpicinaepkfalogpnoijgnalddmmpelj"
        }
        
        if ($lastPassExtension) {
            Write-ColorOutput "[+] LastPass extension found in $BrowserName" "Green"
            return $true
        }
    }
    
    Write-ColorOutput "[-] LastPass extension not found in $BrowserName" "Yellow"
    return $false
}

# Function to check all browsers
function Test-AllBrowsers {
    Write-ColorOutput "`n========================================" "Magenta"
    Write-ColorOutput "Checking Browser Extensions" "Magenta"
    Write-ColorOutput "========================================" "Magenta"
    
    # Check Chrome
    $chromePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions"
    Test-BrowserExtension -BrowserName "Chrome" -ExtensionPath $chromePath
    
    # Check Edge
    $edgePath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions"
    Test-BrowserExtension -BrowserName "Edge" -ExtensionPath $edgePath
    
    # Check Firefox (more complex, checking profiles)
    Write-ColorOutput "`n[*] Checking for LastPass extension in Firefox..." "Cyan"
    
    if (-not (Test-BrowserInstalled -BrowserName "Firefox")) {
        Write-ColorOutput "[-] Firefox is not installed on this system" "DarkGray"
    } else {
        $firefoxProfilePath = "$env:APPDATA\Mozilla\Firefox\Profiles"
        if (Test-Path $firefoxProfilePath) {
            $profiles = Get-ChildItem -Path $firefoxProfilePath -Directory -ErrorAction SilentlyContinue
            $found = $false
            
            foreach ($profile in $profiles) {
                $extensionsPath = Join-Path $profile.FullName "extensions"
                if (Test-Path $extensionsPath) {
                    $lastPassXpi = Get-ChildItem -Path $extensionsPath -Filter "*lastpass*" -ErrorAction SilentlyContinue
                    if ($lastPassXpi) {
                        Write-ColorOutput "[+] LastPass extension found in Firefox" "Green"
                        $found = $true
                        break
                    }
                }
            }
            
            if (-not $found) {
                Write-ColorOutput "[-] LastPass extension not found in Firefox" "Yellow"
            }
        } else {
            Write-ColorOutput "[-] Firefox profile not found" "Yellow"
        }
    }
}

# Function to download and install LastPass using MSI
function Install-LastPassUniversal {
    param(
        [switch]$IncludeAllBrowsers,
        [switch]$EnableLogging
    )
    
    Write-ColorOutput "`n[*] Downloading LastPass Universal MSI installer..." "Cyan"
    
    $downloadUrl = "https://download.cloud.lastpass.com/windows_installer/LastPassInstaller.msi"
    $installerPath = Join-Path $env:TEMP "LastPassInstaller.msi"
    $logPath = Join-Path $env:TEMP "LastPassInstall.log"
    
    <#
    Available MSI Features (ADDLOCAL parameter):
    - ChromeExtension: Chrome browser extension
    - EdgeExtension: Microsoft Edge browser extension  
    - FirefoxExtension: Firefox browser extension (Note: Firefox disabled sideloading)
    - ExplorerExtension: Internet Explorer extension
    - GenericShortcuts: Start menu shortcuts
    - DesktopShortcut: Desktop shortcut
    
    Additional MSI Properties:
    - DISABLEPRINT=1: Disable print functionality in LastPass
    - DISABLEEXPORT=1: Disable export functionality
    - NODISABLEIEPWMGR=0: Disable IE password manager (default: 1 = don't disable)
    - NODISABLECHROMEPWMGR=0: Disable Chrome password manager (default: 1 = don't disable)
    - ALLUSERS=1: Install for all users (requires admin)
    
    Example advanced deployment:
    msiexec /i LastPassInstaller.msi /quiet /norestart ALLUSERS=1 
           ADDLOCAL=ChromeExtension,EdgeExtension,GenericShortcuts,DesktopShortcut 
           DISABLEPRINT=1 DISABLEEXPORT=1 /l*v install.log
    #>
    
    try {
        # Download the MSI installer
        Write-ColorOutput "[*] Downloading from: $downloadUrl" "White"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
        
        Write-ColorOutput "[+] Download complete! ($([math]::Round((Get-Item $installerPath).Length / 1MB, 2)) MB)" "Green"
        Write-ColorOutput "[*] Starting installation..." "Cyan"
        
        # Build msiexec arguments for silent install
        $msiArgs = @(
            "/i"
            "`"$installerPath`""
            "/quiet"
            "/norestart"
            "ALLUSERS=1"
        )
        
        # Determine which browser extensions to install
        $features = @()
        
        if (Test-BrowserInstalled -BrowserName "Chrome") {
            $features += "ChromeExtension"
            Write-ColorOutput "[*] Chrome detected - will install extension" "Cyan"
        }
        
        if (Test-BrowserInstalled -BrowserName "Edge") {
            $features += "EdgeExtension"
            Write-ColorOutput "[*] Edge detected - will install extension" "Cyan"
        }
        
        if (Test-BrowserInstalled -BrowserName "Firefox") {
            $features += "FirefoxExtension"
            Write-ColorOutput "[*] Firefox detected - will install extension" "Cyan"
        }
        
        # Always include desktop shortcuts and app
        $features += "GenericShortcuts"
        $features += "DesktopShortcut"
        
        # Add ADDLOCAL parameter with features
        if ($features.Count -gt 0) {
            $msiArgs += "ADDLOCAL=$($features -join ',')"
        }
        
        # Optional: Disable browser password managers to avoid conflicts
        # Uncomment these if you want to disable built-in password managers
        # $msiArgs += "NODISABLEIEPWMGR=0"
        # $msiArgs += "NODISABLECHROMEPWMGR=0"
        
        # Enable logging if requested
        if ($EnableLogging) {
            $msiArgs += "/l*v"
            $msiArgs += "`"$logPath`""
            Write-ColorOutput "[*] Logging enabled: $logPath" "Cyan"
        }
        
        # Display the command being run
        Write-ColorOutput "[*] Running: msiexec $($msiArgs -join ' ')" "DarkGray"
        
        # Run the MSI installer
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
        
        # Check exit code
        if ($process.ExitCode -eq 0) {
            Write-ColorOutput "[+] LastPass installed successfully!" "Green"
            Write-ColorOutput "[+] Desktop app and detected browser extensions have been installed" "Green"
            $success = $true
        } elseif ($process.ExitCode -eq 3010) {
            Write-ColorOutput "[+] LastPass installed successfully!" "Green"
            Write-ColorOutput "[!] A reboot is required to complete the installation" "Yellow"
            $success = $true
        } else {
            Write-ColorOutput "[!] Installer exited with code: $($process.ExitCode)" "Yellow"
            
            if ($EnableLogging -and (Test-Path $logPath)) {
                Write-ColorOutput "[*] Check installation log for details: $logPath" "Yellow"
            } else {
                Write-ColorOutput "[*] Run script with -EnableLogging to get detailed error information" "Yellow"
            }
            
            # Common exit codes
            switch ($process.ExitCode) {
                1602 { Write-ColorOutput "[!] User cancelled installation" "Red" }
                1603 { Write-ColorOutput "[!] Fatal error during installation" "Red" }
                1619 { Write-ColorOutput "[!] Installation package could not be opened" "Red" }
                1625 { Write-ColorOutput "[!] Installation forbidden by system policy" "Red" }
                1638 { Write-ColorOutput "[!] Another version is already installed" "Yellow" }
                default { Write-ColorOutput "[!] Unknown error occurred" "Red" }
            }
            
            $success = $false
        }
        
        # Clean up installer (keep log if logging was enabled)
        Start-Sleep -Seconds 2
        if (Test-Path $installerPath) {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
        
        if (-not $EnableLogging -and (Test-Path $logPath)) {
            Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
        }
        
        return $success
    }
    catch {
        Write-ColorOutput "[!] Error downloading or installing LastPass: $($_.Exception.Message)" "Red"
        
        # Clean up on error
        if (Test-Path $installerPath) {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }
        if (-not $EnableLogging -and (Test-Path $logPath)) {
            Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
        }
        
        return $false
    }
}

# Function to provide browser extension installation instructions
function Show-ExtensionInstructions {
    param(
        [bool]$UniversalInstallerUsed = $false
    )
    
    Write-ColorOutput "`n========================================" "Magenta"
    Write-ColorOutput "Browser Extension Information" "Magenta"
    Write-ColorOutput "========================================" "Magenta"
    
    if ($UniversalInstallerUsed) {
        Write-ColorOutput "`n[*] The MSI installer should have installed browser extensions automatically." "Green"
        Write-ColorOutput "[*] If extensions don't appear, restart your browsers or install manually below." "White"
        Write-ColorOutput "`n[!] Note: Firefox disabled extension sideloading - you must install from Firefox Add-ons manually." "Yellow"
    } else {
        Write-ColorOutput "`n[!] Browser extensions can be installed manually from the browser stores." "Yellow"
    }
    
    Write-ColorOutput "`n--- Manual Installation Links ---" "Cyan"
    
    Write-ColorOutput "`nChrome Web Store:" "Cyan"
    Write-ColorOutput "https://chrome.google.com/webstore/detail/lastpass-free-password-ma/hdokiejnpimakedhajhdlcegeplioahd" "White"
    
    Write-ColorOutput "`nMicrosoft Edge Add-ons:" "Cyan"
    Write-ColorOutput "https://microsoftedge.microsoft.com/addons/detail/lastpass-password-mana/bbcinlkgjjkejfdpemiealijmmooekmp" "White"
    
    Write-ColorOutput "`nFirefox Add-ons (REQUIRED for Firefox users):" "Cyan"
    Write-ColorOutput "https://addons.mozilla.org/en-US/firefox/addon/lastpass-password-manager/" "White"
    
    Write-ColorOutput "`n[*] Or search for 'LastPass' in your browser's extension store." "White"
}

# Function to open browser extension stores
function Open-ExtensionStores {
    param(
        [switch]$OpenNow
    )
    
    if ($OpenNow) {
        Write-ColorOutput "`n[*] Opening browser extension stores..." "Cyan"
        
        # Chrome
        if (Test-BrowserInstalled -BrowserName "Chrome") {
            $chromePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
            if (-not (Test-Path $chromePath)) {
                $chromePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
            }
            if (-not (Test-Path $chromePath)) {
                $chromePath = "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
            }
            Start-Process $chromePath "https://chrome.google.com/webstore/detail/lastpass-free-password-ma/hdokiejnpimakedhajhdlcegeplioahd"
            Write-ColorOutput "[+] Opened Chrome Web Store" "Green"
        }
        
        # Edge
        if (Test-BrowserInstalled -BrowserName "Edge") {
            Start-Process "msedge" "https://microsoftedge.microsoft.com/addons/detail/lastpass-password-mana/bbcinlkgjjkejfdpemiealijmmooekmp"
            Write-ColorOutput "[+] Opened Edge Add-ons Store" "Green"
        }
        
        # Firefox
        if (Test-BrowserInstalled -BrowserName "Firefox") {
            $firefoxPath = "${env:ProgramFiles}\Mozilla Firefox\firefox.exe"
            if (-not (Test-Path $firefoxPath)) {
                $firefoxPath = "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
            }
            Start-Process $firefoxPath "https://addons.mozilla.org/en-US/firefox/addon/lastpass-password-manager/"
            Write-ColorOutput "[+] Opened Firefox Add-ons Store" "Green"
        }
        
        if (-not (Test-BrowserInstalled -BrowserName "Chrome") -and 
            -not (Test-BrowserInstalled -BrowserName "Edge") -and 
            -not (Test-BrowserInstalled -BrowserName "Firefox")) {
            Write-ColorOutput "[-] No supported browsers found installed" "Yellow"
        }
    }
}

# Main execution
function Main {
    Write-ColorOutput "========================================" "Magenta"
    Write-ColorOutput "LastPass Installation Script" "Magenta"
    Write-ColorOutput "Windows 11 - Desktop & Browser Extensions" "Magenta"
    Write-ColorOutput "========================================" "Magenta"
    
    # Check current installation status
    $desktopInstalled = Test-LastPassInstalled
    Test-AllBrowsers
    
    $installed = $false
    
    # Prompt for installation
    if (-not $desktopInstalled) {
        Write-ColorOutput "`n========================================" "Magenta"
        Write-ColorOutput "Installation Options" "Magenta"
        Write-ColorOutput "========================================" "Magenta"
        Write-ColorOutput "`nThe LastPass Universal MSI Installer will install:" "White"
        Write-ColorOutput "  • LastPass Desktop Application" "White"
        Write-ColorOutput "  • Browser extensions for detected browsers (Edge, Chrome, Firefox)" "White"
        Write-ColorOutput "  • Desktop shortcuts" "White"
        Write-ColorOutput "`n[?] Would you like to install LastPass? (Y/N)" "Yellow"
        $response = Read-Host
        
        if ($response -eq "Y" -or $response -eq "y") {
            Write-ColorOutput "`n[?] Enable installation logging for troubleshooting? (Y/N)" "Yellow"
            $logResponse = Read-Host
            $enableLog = ($logResponse -eq "Y" -or $logResponse -eq "y")
            
            $installed = Install-LastPassUniversal -EnableLogging:$enableLog
            
            if ($installed) {
                Write-ColorOutput "`n[+] LastPass has been installed!" "Green"
                Write-ColorOutput "[*] You may need to restart your browsers for extensions to appear" "Cyan"
                
                # Re-check installation
                Start-Sleep -Seconds 2
                Write-ColorOutput "`n[*] Verifying installation..." "Cyan"
                Test-LastPassInstalled | Out-Null
            }
        } else {
            Write-ColorOutput "[*] Skipping installation." "White"
        }
    }
    
    # Show extension instructions
    if ($installed) {
        Show-ExtensionInstructions -UniversalInstallerUsed $true
    } else {
        Show-ExtensionInstructions -UniversalInstallerUsed $false
    }
    
    # Offer to open browser stores
    Write-ColorOutput "`n[?] Would you like to open the browser extension stores now? (Y/N)" "Yellow"
    $openStores = Read-Host
    
    if ($openStores -eq "Y" -or $openStores -eq "y") {
        Open-ExtensionStores -OpenNow
    }
    
    Write-ColorOutput "`n========================================" "Magenta"
    Write-ColorOutput "[✓] Script completed!" "Green"
    Write-ColorOutput "========================================" "Magenta"
    Write-ColorOutput "`nNote: After installing browser extensions, you'll need to log in with your LastPass credentials." "White"
}

# Run the script
Main