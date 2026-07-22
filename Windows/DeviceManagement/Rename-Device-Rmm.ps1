# Computer Renaming Script
# Format: ID-(Hypervisor/Manufacturer)(Device type)-(Serial/Custom)
# Physical Examples: ABC-HD-L52648M4 (ABC Client - HP Desktop - L52648M4 partial serial)
# VM Examples: ABC-HS-DC01 (ABC Client - Hyper-V Server - DC01 custom name)
# VM Examples: ABC-VS-FS01 (ABC Client - VMware Server - FS01 custom name)
# VM Detection: Automatically detects VMs and hypervisor platform

# Check if running as administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script must be run as Administrator!"
    exit 1
}

# Validate CompanyID variable is provided
if ([string]::IsNullOrWhiteSpace($CompanyID)) {
    Write-Error "CompanyID variable is not set or is empty!"
    exit 1
}

Write-Host "Using Company ID: $CompanyID" -ForegroundColor Green

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

# Manufacturer-based VM indicator
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

# Service-based VM detection
if (-not $isVirtualMachine) {
    $vmServices = Get-Service -Name "*vm*", "*vbox*", "*vmware*", "*hyper-v*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
    if ($vmServices) {
        $isVirtualMachine = $true
        $vmPlatform = "Service-based detection"
    }
}

# Registry-based VM detection
if (-not $isVirtualMachine) {
    try {
        $vmRegKeys = @(
            "HKLM:\\SOFTWARE\\VMware, Inc.\\VMware Tools",
            "HKLM:\\SOFTWARE\\Oracle\\VirtualBox Guest Additions",
            "HKLM:\\SOFTWARE\\Microsoft\\Virtual Machine\\Guest\\Parameters"
        )
        foreach ($regKey in $vmRegKeys) {
            if (Test-Path $regKey) {
                $isVirtualMachine = $true
                $vmPlatform = switch ($regKey) {
                    { $_ -like "*VMware*" } { "VMware"; break }
                    { $_ -like "*VirtualBox*" } { "VirtualBox"; break }
                    { $_ -like "*Microsoft*" } { "Hyper-V"; break }
                }
            }
        }
    }
    catch { }
}

# Determine manufacturer/hypervisor code
if ($isVirtualMachine) {
    $manufacturerCode = switch -Wildcard ($vmPlatform) {
        "*Hyper-V*" { "H" }
        "*VMware*" { "V" }
        "*VirtualBox*" { "B" }
        "*QEMU*" { "Q" }
        "*Xen*" { "X" }
        "*Parallels*" { "P" }
        default { "U" }
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
        default { "U" }
    }
}

# Determine device type (no prompts in RMM)
if ($isVirtualMachine) {
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $isServerOS = $osInfo.Caption -match "Server"
    $hasServerRoles = $false
    try {
        $serverRoles = Get-WindowsFeature -ErrorAction SilentlyContinue | Where-Object { $_.FeatureType -eq 'Role' -and $_.InstallState -eq 'Installed' }
        if ($serverRoles) { $hasServerRoles = $true }
    }
    catch {
        $serverServices = Get-Service -Name "*AD*", "*DNS*", "*DHCP*", "*IIS*", "*SQL*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
        if ($serverServices) { $hasServerRoles = $true }
    }
    $deviceType = if ($isServerOS -or $hasServerRoles) { "S" } else { "D" }
} else {
    $deviceType = "D"  # Default to Desktop
    if ($model -match "Laptop|Book|Pavilion.*Book|EliteBook|ProBook|ThinkPad|IdeaPad|Inspiron.*Book|Latitude|XPS.*Book|Surface.*Laptop") {
        $deviceType = "L"
    }
    elseif ($model -match "All.*in.*One|AIO|OptiPlex.*AIO|EliteOne|IdeaCentre.*AIO|Inspiron.*AIO") {
        $deviceType = "A"
    }
    elseif ($model -match "Tablet|Surface.*Pro|Surface.*Go|ThinkPad.*Tablet") {
        $deviceType = "T"
    }
    elseif ($model -match "Server|PowerEdge|ProLiant|ThinkServer|System.*x|BladeCenter|Rack|Tower.*Server") {
        $deviceType = "S"
    }
}

Write-Host "Detected: $(if ($isVirtualMachine) { "VM ($vmPlatform)" } else { "Physical" }) - Type: $deviceType" -ForegroundColor Green

# Build the base name without identifier
$baseName = "$CompanyID-$manufacturerCode$deviceType-"
$baseLength = $baseName.Length

# Calculate how much space we have for identifier (15 total - base length)
$maxSerialLength = 15 - $baseLength

if ($maxSerialLength -le 0) {
    Write-Error "Company ID '$CompanyID' is too long! Base name '$baseName' exceeds 15 characters."
    exit 1
}

# Determine identifier
# If $CustomIdentifier is provided (e.g., DC01/FS01), use it; otherwise fallback to serial
if (-not [string]::IsNullOrWhiteSpace($CustomIdentifier)) {
    $identifierPart = ($CustomIdentifier.ToUpper() -replace '[^A-Za-z0-9]', '')
} else {
    $cleanSerial = $serialNumber -replace '[^A-Za-z0-9]', ''
    $identifierPart = if ($cleanSerial.Length -gt $maxSerialLength) {
        $cleanSerial.Substring($cleanSerial.Length - $maxSerialLength)
    } else {
        $cleanSerial
    }
}

# Truncate identifier if needed
if ($identifierPart.Length -gt $maxSerialLength) {
    $identifierPart = $identifierPart.Substring(0, $maxSerialLength)
}

# Build final computer name
$newComputerName = "$baseName$identifierPart"

# Display the proposed name
Write-Host ""
Write-Host "Proposed Computer Name: $newComputerName" -ForegroundColor Yellow
Write-Host "Length: $($newComputerName.Length) characters"
Write-Host ""

# Rename the computer automatically (no confirmation needed for RMM deployment)
try {
    Rename-Computer -NewName $newComputerName -Force
    Write-Host "Computer successfully renamed to: $newComputerName" -ForegroundColor Green
    Write-Host "A restart is required for the change to take effect." -ForegroundColor Yellow
    
    # Exit with success code for RMM
    exit 0
}
catch {
    Write-Error "Failed to rename computer: $_"
    exit 1
}