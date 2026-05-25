#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Comprehensive Server Role Detection Script
    
.DESCRIPTION
    This script detects and displays ALL Windows Server roles and features including:
    - All Windows Server roles (AD DS, DNS, DHCP, Hyper-V, IIS, RDS, etc.)
    - All Windows Server features
    - FSMO Roles (if applicable)
    - Service-based role detection
    - Comprehensive server information
    
.PARAMETER ComputerName
    Optional parameter to specify a remote computer name. If not provided, uses local computer.
    
.PARAMETER ShowFeatures
    Switch to also display installed Windows Features (default: true)
    
.EXAMPLE
    .\Detect_ServerRoles.ps1
    
.EXAMPLE
    .\Detect_ServerRoles.ps1 -ComputerName "SERVER01"
    
.EXAMPLE
    .\Detect_ServerRoles.ps1 -ComputerName "SERVER01" -ShowFeatures:$false
#>

param(
    [string]$ComputerName = $env:COMPUTERNAME,
    [switch]$ShowFeatures = $true
)

# Function to test if a service is running
function Test-ServiceRunning {
    param([string]$ServiceName, [string]$TargetComputer = $ComputerName)
    
    try {
        $service = Get-Service -Name $ServiceName -ComputerName $TargetComputer -ErrorAction Stop
        return $service.Status -eq 'Running'
    }
    catch {
        return $false
    }
}

# Function to get all Windows Server roles and features
function Get-WindowsServerRolesAndFeatures {
    param([string]$TargetComputer = $ComputerName)
    
    try {
        if ($TargetComputer -eq $env:COMPUTERNAME) {
            $features = Get-WindowsFeature -ErrorAction Stop
        } else {
            $features = Get-WindowsFeature -ComputerName $TargetComputer -ErrorAction Stop
        }
        
        # Separate roles and features
        $roles = $features | Where-Object { $_.FeatureType -eq 'Role' -and $_.InstallState -eq 'Installed' }
        $installedFeatures = $features | Where-Object { $_.FeatureType -eq 'Feature' -and $_.InstallState -eq 'Installed' }
        
        return @{
            Roles = $roles
            Features = $installedFeatures
            AllInstalled = $features | Where-Object { $_.InstallState -eq 'Installed' }
        }
    }
    catch {
        Write-Warning "Unable to retrieve Windows Features: $($_.Exception.Message)"
        return $null
    }
}

# Function to get FSMO roles for current server
function Get-FSMORoles {
    try {
        # Check if this server is a domain controller
        $isDC = Test-WindowsRole -RoleName "AD-Domain-Services"
        if (-not $isDC) {
            return "Not a Domain Controller"
        }
        
        # Get current domain
        $currentDomain = Get-ADDomain -ErrorAction Stop
        $currentForest = Get-ADForest -ErrorAction Stop
        
        $fsmoRoles = @()
        
        # Check Domain FSMO roles
        if ($currentDomain.PDCEmulator -eq $ComputerName) {
            $fsmoRoles += "PDC Emulator"
        }
        if ($currentDomain.RIDMaster -eq $ComputerName) {
            $fsmoRoles += "RID Master"
        }
        if ($currentDomain.InfrastructureMaster -eq $ComputerName) {
            $fsmoRoles += "Infrastructure Master"
        }
        
        # Check Forest FSMO roles
        if ($currentForest.SchemaMaster -eq $ComputerName) {
            $fsmoRoles += "Schema Master"
        }
        if ($currentForest.DomainNamingMaster -eq $ComputerName) {
            $fsmoRoles += "Domain Naming Master"
        }
        
        if ($fsmoRoles.Count -eq 0) {
            return "No FSMO Roles"
        } else {
            return ($fsmoRoles -join ", ")
        }
    }
    catch {
        return "Unable to determine FSMO roles: $($_.Exception.Message)"
    }
}

# Function to get DNS zones if DNS server is installed
function Get-DNSZones {
    try {
        $zones = Get-DnsServerZone -ErrorAction Stop
        return $zones.Count
    }
    catch {
        return "Unable to enumerate zones"
    }
}

# Function to get DHCP scopes if DHCP server is installed
function Get-DHCPScopes {
    try {
        $scopes = Get-DhcpServerv4Scope -ErrorAction Stop
        return $scopes.Count
    }
    catch {
        return "Unable to enumerate scopes"
    }
}

# Function to get Hyper-V VMs if Hyper-V is installed
function Get-HyperVVMs {
    try {
        $vms = Get-VM -ErrorAction Stop
        return $vms.Count
    }
    catch {
        return "Unable to enumerate VMs"
    }
}

# Main execution
Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "    COMPREHENSIVE SERVER ROLE DETECTION REPORT" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "Target Computer: $ComputerName" -ForegroundColor Yellow
Write-Host "Report Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Yellow
Write-Host ""

# Get all Windows Server roles and features
Write-Host "Scanning Windows Server roles and features..." -ForegroundColor Green
$serverInfo = Get-WindowsServerRolesAndFeatures

if ($serverInfo) {
    Write-Host "Found $($serverInfo.Roles.Count) installed roles and $($serverInfo.Features.Count) installed features" -ForegroundColor Yellow
} else {
    Write-Host "Unable to retrieve Windows Server roles and features information" -ForegroundColor Red
    exit 1
}

# Initialize results array for roles
$roleResults = @()

# Process each installed role
foreach ($role in $serverInfo.Roles) {
    $roleDetails = "Role installed"
    
    # Add specific details for certain roles
    switch ($role.Name) {
        "AD-Domain-Services" {
            $roleDetails = "Active Directory Domain Services installed"
            # Check FSMO roles if this is a DC
            try {
                $fsmoRoles = Get-FSMORoles
                if ($fsmoRoles -and $fsmoRoles -ne "Not a Domain Controller" -and $fsmoRoles -ne "No FSMO Roles") {
                    $roleDetails += " - FSMO Roles: $fsmoRoles"
                }
            }
            catch {
                $roleDetails += " - Unable to determine FSMO roles"
            }
        }
        "DNS" {
            try {
                $zoneCount = Get-DNSZones
                $roleDetails = "DNS Server installed - $zoneCount zones configured"
            }
            catch {
                $roleDetails = "DNS Server installed - Unable to enumerate zones"
            }
        }
        "DHCP" {
            try {
                $scopeCount = Get-DHCPScopes
                $roleDetails = "DHCP Server installed - $scopeCount scopes configured"
            }
            catch {
                $roleDetails = "DHCP Server installed - Unable to enumerate scopes"
            }
        }
        "Hyper-V" {
            try {
                $vmCount = Get-HyperVVMs
                $roleDetails = "Hyper-V Server installed - $vmCount VMs configured"
            }
            catch {
                $roleDetails = "Hyper-V Server installed - Unable to enumerate VMs"
            }
        }
        "IIS-WebServerRole" {
            $roleDetails = "IIS Web Server installed"
        }
        "RDS-RD-Server" {
            $roleDetails = "Remote Desktop Services installed"
        }
        "Print-Services" {
            $roleDetails = "Print Services installed"
        }
        "FS-FileServer" {
            $roleDetails = "File Server installed"
        }
        "Web-Server" {
            $roleDetails = "Web Server (IIS) installed"
        }
        "ADCS-Cert-Authority" {
            $roleDetails = "Active Directory Certificate Services installed"
        }
        "ADFS-Federation" {
            $roleDetails = "Active Directory Federation Services installed"
        }
        "ADLDS-DS" {
            $roleDetails = "Active Directory Lightweight Directory Services installed"
        }
        "ADRMS" {
            $roleDetails = "Active Directory Rights Management Services installed"
        }
        "NPAS" {
            $roleDetails = "Network Policy and Access Services installed"
        }
        "TS-Gateway" {
            $roleDetails = "Terminal Services Gateway installed"
        }
        "TS-Licensing" {
            $roleDetails = "Terminal Services Licensing installed"
        }
        "WDS" {
            $roleDetails = "Windows Deployment Services installed"
        }
        "Windows-Server-Backup" {
            $roleDetails = "Windows Server Backup installed"
        }
        "WSUS" {
            $roleDetails = "Windows Server Update Services installed"
        }
    }
    
    $roleResults += [PSCustomObject]@{
        Role = $role.DisplayName
        Name = $role.Name
        Status = "Installed"
        Details = $roleDetails
    }
}

# Check for additional service-based roles that might not be detected by Windows Features
Write-Host "`nChecking additional service-based roles..." -ForegroundColor Green

# SQL Server Detection
$sqlServices = Get-Service -Name "*SQL*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
if ($sqlServices) {
    $sqlDetails = "SQL Server services detected: $($sqlServices.Name -join ', ')"
    $roleResults += [PSCustomObject]@{
        Role = "SQL Server"
        Name = "SQL-Server"
        Status = "Detected"
        Details = $sqlDetails
    }
}

# Exchange Server Detection
$exchangeServices = Get-Service -Name "*Exchange*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
if ($exchangeServices) {
    $exchangeDetails = "Exchange Server services detected: $($exchangeServices.Name -join ', ')"
    $roleResults += [PSCustomObject]@{
        Role = "Exchange Server"
        Name = "Exchange-Server"
        Status = "Detected"
        Details = $exchangeDetails
    }
}

# SharePoint Detection
$sharepointServices = Get-Service -Name "*SharePoint*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
if ($sharepointServices) {
    $sharepointDetails = "SharePoint services detected: $($sharepointServices.Name -join ', ')"
    $roleResults += [PSCustomObject]@{
        Role = "SharePoint Server"
        Name = "SharePoint-Server"
        Status = "Detected"
        Details = $sharepointDetails
    }
}

# System Center Detection
$scServices = Get-Service -Name "*SystemCenter*", "*SCOM*", "*SCCM*", "*SCVMM*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
if ($scServices) {
    $scDetails = "System Center services detected: $($scServices.Name -join ', ')"
    $roleResults += [PSCustomObject]@{
        Role = "System Center"
        Name = "System-Center"
        Status = "Detected"
        Details = $scDetails
    }
}

# Display results
Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "    INSTALLED SERVER ROLES SUMMARY" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan

if ($roleResults.Count -gt 0) {
    Write-Host "Found $($roleResults.Count) installed/detected roles:" -ForegroundColor Yellow
    $roleResults | Format-Table -Property Role, Status, Details -AutoSize -Wrap
} else {
    Write-Host "No Windows Server roles detected" -ForegroundColor Yellow
}

# Additional Server Information
Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "    ADDITIONAL SERVER INFORMATION" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan

# Get OS Information
$osInfo = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName
$computerInfo = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $ComputerName

Write-Host "Operating System: $($osInfo.Caption) $($osInfo.Version)" -ForegroundColor White
Write-Host "Architecture: $($osInfo.OSArchitecture)" -ForegroundColor White
Write-Host "Computer Name: $($computerInfo.Name)" -ForegroundColor White
Write-Host "Domain: $($computerInfo.Domain)" -ForegroundColor White
Write-Host "Manufacturer: $($computerInfo.Manufacturer)" -ForegroundColor White
Write-Host "Model: $($computerInfo.Model)" -ForegroundColor White
Write-Host "Total Physical Memory: $([math]::Round($computerInfo.TotalPhysicalMemory / 1GB, 2)) GB" -ForegroundColor White
Write-Host "Number of Processors: $($computerInfo.NumberOfProcessors)" -ForegroundColor White
Write-Host "Number of Logical Processors: $($computerInfo.NumberOfLogicalProcessors)" -ForegroundColor White

# Display installed Windows Features if requested
if ($ShowFeatures -and $serverInfo.Features.Count -gt 0) {
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "    INSTALLED WINDOWS FEATURES" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Cyan
    
    Write-Host "Total Installed Features: $($serverInfo.Features.Count)" -ForegroundColor Yellow
    Write-Host "`nInstalled Features:" -ForegroundColor Green
    $serverInfo.Features | Select-Object DisplayName, Name | Format-Table -AutoSize -Wrap
}

# Display all installed roles and features summary
Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "    COMPLETE INSTALLATION SUMMARY" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan

Write-Host "Total Installed Roles: $($serverInfo.Roles.Count)" -ForegroundColor Yellow
Write-Host "Total Installed Features: $($serverInfo.Features.Count)" -ForegroundColor Yellow
Write-Host "Total Installed Items: $($serverInfo.AllInstalled.Count)" -ForegroundColor Yellow

Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "    REPORT COMPLETE" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
