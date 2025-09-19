# Computer Renaming Script
# Format: ID-(First letter of manufacturer)(Device type)-(Last part of serial)
# Example: BRR-HD-L52648M4

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
        Write-Warning "Unknown manufacturer: $manufacturer - defaulting to 'U' for Unknown"
        "U"
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

Write-Host "Detected device type: $deviceType (D=Desktop, L=Laptop, A=All-in-One, T=Tablet)" -ForegroundColor Green

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