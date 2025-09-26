# Computer Renaming Script
# Format: ID-(First letter of manufacturer)(Device type)-(Last part of serial)
# Example: ABC-HD-L52648M4
# ABC Client - HP Desktop - L52648M4 (partial serial)

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

# Determine manufacturer code
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

# Determine device type based on model and form factor
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

# Allow manual override of device type
Write-Host "Detected device type: $deviceType (D=Desktop, L=Laptop, A=All-in-One, T=Tablet)"
$override = Read-Host "Press Enter to accept, or enter different type (D/L/A/T)"
if (-not [string]::IsNullOrWhiteSpace($override)) {
    $deviceType = $override.ToUpper()
}

# Clean and prepare serial number (remove spaces, special characters)
$cleanSerial = $serialNumber -replace '[^A-Za-z0-9]', ''

# Build the base name without serial
$baseName = "$CompanyID-$manufacturerCode$deviceType-"
$baseLength = $baseName.Length

# Calculate how much space we have for serial (15 total - base length)
$maxSerialLength = 15 - $baseLength

if ($maxSerialLength -le 0) {
    Write-Error "Company ID '$CompanyID' is too long! Base name '$baseName' exceeds 15 characters."
    exit 1
}

# Get the last part of serial number that fits
$serialPart = if ($cleanSerial.Length -gt $maxSerialLength) {
    $cleanSerial.Substring($cleanSerial.Length - $maxSerialLength)
} else {
    $cleanSerial
}

# Build final computer name
$newComputerName = "$baseName$serialPart"

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