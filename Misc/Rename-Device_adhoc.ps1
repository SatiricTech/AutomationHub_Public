# Computer Renaming Script
# Format: ID-(Hypervisor/Manufacturer)(Device type)-(Serial/Custom)
# Physical Examples: ABC-HD-L52648M4 (ABC Client - HP Desktop - L52648M4 partial serial)
# VM Examples: ABC-HS-DC01 (ABC Client - Hyper-V Server - DC01 custom name)
# VM Examples: ABC-VS-FS01 (ABC Client - VMware Server - FS01 custom name)
# VM Examples: ABC-BS-APP01 (ABC Client - VirtualBox Server - APP01 custom name)
# VM Detection: Automatically detects VMs and hypervisor platform

# Check if running as administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator!"
    exit 1
}

# Check if CompanyID is already set (for RMM deployment), otherwise prompt
if ([string]::IsNullOrWhiteSpace($CompanyID)) {
    do {
        $CompanyID = Read-Host "Enter Company ID (e.g., BRR)"
        if ([string]::IsNullOrWhiteSpace($CompanyID)) {
            Write-Warning "Company ID cannot be empty!"
        }
    } while ([string]::IsNullOrWhiteSpace($CompanyID))
    Write-Host "Using Company ID: $CompanyID" -ForegroundColor Green
} else {
    Write-Host "Using Company ID: $CompanyID (provided via variable)" -ForegroundColor Green
}

# Get system information
try {
    $computerInfo = Get-CimInstance -ClassName Win32_ComputerSystem
    $biosInfo = Get-CimInstance -ClassName Win32_BIOS
    $baseboardInfo = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction SilentlyContinue
    
    $manufacturer = $computerInfo.Manufacturer
    $model = $computerInfo.Model
    $serialNumber = $biosInfo.SerialNumber
    
    Write-Host "System Information:" -ForegroundColor Green
    Write-Host "Manufacturer: $manufacturer"
    Write-Host "Model: $model"
    Write-Host "Serial Number: $serialNumber"
    Write-Host ""
}
catch {
    Write-Error "Failed to retrieve system information: $_"
    exit 1
}

# Detect if this is a Virtual Machine
$isVirtualMachine = $false
$vmPlatform = ""

# Check for VM indicators
if ($manufacturer -match "Microsoft Corporation|VMware|VirtualBox|QEMU|Xen|Parallels|Oracle") {
    $isVirtualMachine = $true
    $vmPlatform = switch -Wildcard ($manufacturer) {
        "*Microsoft*" { "Hyper-V" }
        "*VMware*" { "VMware" }
        "*VirtualBox*" { "VirtualBox" }
        "*QEMU*" { "QEMU" }
        "*Xen*" { "Xen" }
        "*Parallels*" { "Parallels" }
        "*Oracle*" { "VirtualBox" }
        default { "Unknown VM" }
    }
}

# Additional VM detection methods
if (-not $isVirtualMachine) {
    # Check for VM-specific services
    $vmServices = Get-Service -Name "*vm*", "*vbox*", "*vmware*", "*hyper-v*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
    if ($vmServices) {
        $isVirtualMachine = $true
        $vmPlatform = "Service-based detection"
    }
    
    # Check for VM-specific registry entries
    try {
        $vmRegKeys = @(
            "HKLM:\SOFTWARE\VMware, Inc.\VMware Tools",
            "HKLM:\SOFTWARE\Oracle\VirtualBox Guest Additions",
            "HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters"
        )
        
        foreach ($regKey in $vmRegKeys) {
            if (Test-Path $regKey) {
                $isVirtualMachine = $true
                $vmPlatform = switch ($regKey) {
                    "*VMware*" { "VMware" }
                    "*VirtualBox*" { "VirtualBox" }
                    "*Microsoft*" { "Hyper-V" }
                }
                break
            }
        }
    }
    catch {
        # Registry check failed, continue
    }
}

if ($isVirtualMachine) {
    Write-Host "Virtual Machine Detected!" -ForegroundColor Cyan
    Write-Host "VM Platform: $vmPlatform" -ForegroundColor Cyan
    Write-Host ""
}

# Determine manufacturer code
if ($isVirtualMachine) {
    # Use hypervisor-specific codes for VMs
    $manufacturerCode = switch -Wildcard ($vmPlatform) {
        "*Hyper-V*" { "H" }  # H for Hyper-V
        "*VMware*" { "V" }  # V for VMware
        "*VirtualBox*" { "B" }  # B for VirtualBox
        "*QEMU*" { "Q" }  # Q for QEMU
        "*Xen*" { "X" }  # X for Xen
        "*Parallels*" { "P" }  # P for Parallels
        default { 
            Write-Warning "Unknown VM platform: $vmPlatform"
            $manualCode = Read-Host "Enter hypervisor code manually (H/V/B/Q/X/P/U)"
            $manualCode.ToUpper()
        }
    }
} else {
    $manufacturerCode = switch -Wildcard ($manufacturer) {
        "*Dell*" { "D" }
        "*HP*" { "H" }
        "*Hewlett*" { "H" }
        "*Lenovo*" { "L" }
        "*Microsoft*" { "M" }
        "*ASUS*" { "A" }
        "*Acer*" { "C" }
        default { 
            Write-Warning "Unknown manufacturer: $manufacturer"
            $manualCode = Read-Host "Enter manufacturer code manually (D/H/L/M/A/C/U)"
            $manualCode.ToUpper()
        }
    }
}

# Determine device type based on model and form factor
if ($isVirtualMachine) {
    # For VMs, determine if it's a server or desktop based on OS and roles
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $isServerOS = $osInfo.Caption -match "Server"
    
    # Check for server roles/features
    $hasServerRoles = $false
    try {
        $serverRoles = Get-WindowsFeature -ErrorAction SilentlyContinue | Where-Object { $_.FeatureType -eq 'Role' -and $_.InstallState -eq 'Installed' }
        if ($serverRoles) {
            $hasServerRoles = $true
        }
    }
    catch {
        # Windows Feature cmdlet not available, check services instead
        $serverServices = Get-Service -Name "*AD*", "*DNS*", "*DHCP*", "*IIS*", "*SQL*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
        if ($serverServices) {
            $hasServerRoles = $true
        }
    }
    
    if ($isServerOS -or $hasServerRoles) {
        $deviceType = "S"  # VM Server
    } else {
        $deviceType = "D"  # VM Desktop
    }
    
    Write-Host "VM Type Detection:" -ForegroundColor Cyan
    Write-Host "OS Type: $(if ($isServerOS) { 'Server' } else { 'Client' })"
    Write-Host "Has Server Roles: $(if ($hasServerRoles) { 'Yes' } else { 'No' })"
    Write-Host "VM Device Type: $(if ($deviceType -eq 'S') { 'VMS (VM Server)' } else { 'VMD (VM Desktop)' })"
    Write-Host ""
} else {
    # Physical machine detection logic
    $deviceType = "D"  # Default to Desktop

    # Check for laptop indicators
    if ($model -match "Laptop|Book|Pavilion.*Book|EliteBook|ProBook|ThinkPad|IdeaPad|Inspiron.*Book|Latitude|XPS.*Book|Surface.*Laptop") {
        $deviceType = "L"
    }
    # Check for All-in-One indicators  
    elseif ($model -match "All.*in.*One|AIO|OptiPlex.*AIO|EliteOne|IdeaCentre.*AIO|Inspiron.*AIO") {
        $deviceType = "A"
    }
    # Check for tablet indicators
    elseif ($model -match "Tablet|Surface.*Pro|Surface.*Go|ThinkPad.*Tablet") {
        $deviceType = "T"
    }
    # Check for server indicators
    elseif ($model -match "Server|PowerEdge|ProLiant|ThinkServer|System.*x|BladeCenter|Rack|Tower.*Server") {
        $deviceType = "S"
    }
}

# Allow manual override of device type
$deviceTypeDescription = switch ($deviceType) {
    "D" { if ($isVirtualMachine) { "Desktop VM ($vmPlatform)" } else { "Desktop" } }
    "L" { "Laptop" }
    "A" { "All-in-One" }
    "T" { "Tablet" }
    "S" { if ($isVirtualMachine) { "Server VM ($vmPlatform)" } else { "Server" } }
}

Write-Host "Detected device type: $deviceTypeDescription"
Write-Host "Manufacturer/Hypervisor code: $manufacturerCode"
$override = Read-Host "Press Enter to accept, or enter different type (D/L/A/T/S)"
if (-not [string]::IsNullOrWhiteSpace($override)) {
    $deviceType = $override.ToUpper()
}

# Build the base name without identifier
$baseName = "$CompanyID-$manufacturerCode$deviceType-"
$baseLength = $baseName.Length

# Calculate how much space we have for identifier (15 total - base length)
$maxSerialLength = 15 - $baseLength
if ($maxSerialLength -le 0) {
    Write-Error "Company ID '$CompanyID' is too long! Base name '$baseName' exceeds 15 characters."
    exit 1
}

# Determine the identifier part (serial for physical, custom for VMs)
if ($isVirtualMachine) {
    Write-Host "`nVM Custom Naming:" -ForegroundColor Cyan
    Write-Host "For VMs, you can use a custom identifier instead of serial number."
    Write-Host "Examples: DC01, FS01, APP01, WEB01, SQL01, etc."
    Write-Host ""
    
    do {
        $customIdentifier = Read-Host "Enter custom VM identifier (or press Enter to use serial)"
        if ([string]::IsNullOrWhiteSpace($customIdentifier)) {
            # Use serial number if no custom identifier provided
            $cleanSerial = $serialNumber -replace '[^A-Za-z0-9]', ''
            $identifierPart = if ($cleanSerial.Length -gt $maxSerialLength) {
                $cleanSerial.Substring($cleanSerial.Length - $maxSerialLength)
            } else {
                $cleanSerial
            }
            Write-Host "Using serial number: $identifierPart" -ForegroundColor Yellow
        } else {
            # Clean custom identifier (remove spaces, special characters, convert to uppercase)
            $identifierPart = $customIdentifier.ToUpper() -replace '[^A-Za-z0-9]', ''
            Write-Host "Using custom identifier: $identifierPart" -ForegroundColor Green
        }
    } while ([string]::IsNullOrWhiteSpace($identifierPart))
} else {
    # Physical machine - use serial number
    $cleanSerial = $serialNumber -replace '[^A-Za-z0-9]', ''
    $identifierPart = if ($cleanSerial.Length -gt $maxSerialLength) {
        $cleanSerial.Substring($cleanSerial.Length - $maxSerialLength)
    } else {
        $cleanSerial
    }
}

# Truncate identifier if too long
if ($identifierPart.Length -gt $maxSerialLength) {
    $identifierPart = $identifierPart.Substring(0, $maxSerialLength)
    Write-Warning "Identifier truncated to fit 15 character limit: $identifierPart"
}

# Build final computer name
$newComputerName = "$baseName$identifierPart"

# Display the proposed name
Write-Host ""
Write-Host "Proposed Computer Name: $newComputerName" -ForegroundColor Yellow
Write-Host "Length: $($newComputerName.Length) characters"
Write-Host ""

# Confirm before renaming
$confirm = Read-Host "Do you want to rename this computer? (Y/N)"
if ($confirm -match "^[Yy]") {
    try {
        # Rename the computer
        Rename-Computer -NewName $newComputerName -Force
        Write-Host "Computer successfully renamed to: $newComputerName" -ForegroundColor Green
        Write-Host ""
        Write-Host "A restart is required for the change to take effect." -ForegroundColor Yellow
        
        $restart = Read-Host "Do you want to restart now? (Y/N)"
        if ($restart -match "^[Yy]") {
            Restart-Computer -Force
        }
    }
    catch {
        Write-Error "Failed to rename computer: $_"
        exit 1
    }
} else {
    Write-Host "Operation cancelled." -ForegroundColor Red
}