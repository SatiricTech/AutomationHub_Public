<#
.SYNOPSIS
   Network Adapter Management Script - Flexible Variable Creation for Network Adapters
   
.DESCRIPTION
   This script provides multiple methods to capture and store network adapter information
   in PowerShell variables for easy access and manipulation. It creates both numbered
   and named variables for network adapters, with special focus on adapters that are
   currently "Up" (online and working).
   
.HIGH-LEVEL USE CASES
   - Bulk DNS server configuration across multiple network adapters
   - Network adapter inventory and status monitoring
   - Automated network configuration scripts
   - Troubleshooting network connectivity issues
   - Setting adapter-specific network policies
   - Network adapter performance monitoring
   
.HOW IT WORKS
   The script creates multiple sets of variables:
   
   1. ALL ADAPTERS:
      - $adapter1, $adapter2, etc. - Contains all adapters regardless of status
      - $adapterVars hashtable - Access adapters by their original names
   
   2. UP/ONLINE ADAPTERS ONLY:
      - $upAdapter1, $upAdapter2, etc. - Numbered variables for active adapters
      - $WiFi, $Ethernet, etc. - Named variables (special chars removed)
      - $upAdapterVars hashtable - Access active adapters by their original names
   
   Each variable contains the COMPLETE adapter object, allowing access to all properties:
   - .ifIndex - Interface index for DNS/network configuration
   - .Name - Adapter name
   - .Status - Current status (Up/Down)
   - .MacAddress - Physical address
   - .LinkSpeed - Connection speed
   - .InterfaceDescription - Hardware description
   - .DriverDescription - Driver information
   - .DriverVersion - Driver version number
   - .InterfaceGuid - Unique identifier
   - .MediaType - Connection media type
   - And many more properties...
   
.EXAMPLES OF ACCESSING INDIVIDUAL PROPERTIES
   # Get interface index for DNS configuration
   $WiFi.ifIndex                    # Returns: 12 (example)
   $Ethernet.ifIndex                 # Returns: 7 (example)
   $upAdapter1.ifIndex              # Returns: 12 (example)
   
   # Get adapter name
   $Ethernet.Name                   # Returns: "Ethernet"
   $upAdapter2.Name                 # Returns: "Wi-Fi"
   
   # Get MAC address
   $WiFi.MacAddress                 # Returns: "AA-BB-CC-DD-EE-FF"
   $Ethernet.MacAddress             # Returns: "11-22-33-44-55-66"
   
   # Get link speed
   $Ethernet.LinkSpeed              # Returns: "1 Gbps"
   $WiFi.LinkSpeed                  # Returns: "300 Mbps"
   
   # Get status
   $adapter1.Status                 # Returns: "Up" or "Down"
   $upAdapter1.Status               # Returns: "Up" (always, since filtered)
   
   # Get driver information
   $Ethernet.DriverDescription      # Returns: "Intel(R) Ethernet Connection"
   $Ethernet.DriverVersion          # Returns: "12.18.9.7"
   
   # Get interface description (hardware)
   $WiFi.InterfaceDescription       # Returns: "Intel(R) Wi-Fi 6 AX200"
   
   # Get media type
   $Ethernet.MediaType              # Returns: "802.3"
   
   # From hashtable
   $upAdapterVars['Wi-Fi'].ifIndex  # Returns: 12 (example)
   $adapterVars['Ethernet'].Status  # Returns: "Up" or "Down"
   
.EXAMPLES OF USAGE IN SCRIPTS
   # Set DNS servers for an adapter
   Set-DnsClientServerAddress -InterfaceIndex $upAdapter1.ifIndex -ServerAddresses "8.8.8.8","8.8.4.4"
   
   # Check adapter status
   if ($Ethernet.Status -eq "Up") { 
       Write-Host "Ethernet is connected at $($Ethernet.LinkSpeed)"
   }
   
   # Loop through all active adapters
   $counter = 1
   while (Get-Variable -Name "upAdapter$counter" -ErrorAction SilentlyContinue) {
       $adapter = Get-Variable -Name "upAdapter$counter" -ValueOnly
       Write-Host "Processing: $($adapter.Name) with index $($adapter.ifIndex)"
       $counter++
   }
   
.NOTES
   Author: Network Administration Script
   Purpose: Flexible network adapter management
   Requirements: PowerShell 5.0 or higher, Run as Administrator for network changes
   
   Special Characters in Adapter Names:
   - Spaces, hyphens, and special characters are removed
   - "Wi-Fi" becomes $WiFi
   - "Ethernet 2" becomes $Ethernet2
   - "Bluetooth Network Connection" becomes $BluetoothNetworkConnection
   - Original names are preserved in hashtables for exact matching
#>

# ============================================================================
# MAIN SCRIPT - NETWORK ADAPTER VARIABLE CREATION
# ============================================================================

# METHOD 1: Manual assignment if you know the position
# All adapters (complete objects)
$adapters = Get-NetAdapter
$firstAdapter = $adapters[0]
$secondAdapter = $adapters[1]
$thirdAdapter = $adapters[2]

# Up/Online adapters only (complete objects)
$upAdapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
$firstUpAdapter = $upAdapters[0]
$secondUpAdapter = $upAdapters[1]
$thirdUpAdapter = $upAdapters[2]

# METHOD 2: Dynamic variable creation with complete objects
# All adapters
$counter = 1
foreach ($adapter in Get-NetAdapter) {
   New-Variable -Name "adapter$counter" -Value $adapter -Force
   $counter++
}

# Up/Online adapters only - numbered variables
$counter = 1
foreach ($adapter in (Get-NetAdapter | Where-Object {$_.Status -eq "Up"})) {
   New-Variable -Name "upAdapter$counter" -Value $adapter -Force
   $counter++
}

# Up/Online adapters only - NAMED variables (using interface name)
foreach ($adapter in (Get-NetAdapter | Where-Object {$_.Status -eq "Up"})) {
   # Clean the adapter name to make it a valid variable name
   # Remove spaces, hyphens, and other special characters
   $varName = $adapter.Name -replace '[^a-zA-Z0-9]', ''
   New-Variable -Name $varName -Value $adapter -Force
}

# METHOD 3: Using hashtables for named adapters (complete objects)
# All adapters
$adapterVars = @{}
foreach ($adapter in Get-NetAdapter) {
   $adapterVars[$adapter.Name] = $adapter
}

# Up/Online adapters only
$upAdapterVars = @{}
foreach ($adapter in (Get-NetAdapter | Where-Object {$_.Status -eq "Up"})) {
   $upAdapterVars[$adapter.Name] = $adapter
}

# ============================================================================
# EXAMPLES OF USAGE - ACCESSING INDIVIDUAL PROPERTIES
# ============================================================================

Write-Host "`n=== EXAMPLES OF ACCESSING INDIVIDUAL PROPERTIES ===" -ForegroundColor Cyan

# Choose example adapter - prefer Ethernet if it exists and is up, otherwise use first up adapter
$exampleAdapter = $null
$exampleVarName = $null

if (Get-Variable -Name "Ethernet" -ErrorAction SilentlyContinue) {
   $exampleAdapter = $Ethernet
   $exampleVarName = "Ethernet"
} elseif (Get-Variable -Name "upAdapter1" -ErrorAction SilentlyContinue) {
   $exampleAdapter = $upAdapter1
   $exampleVarName = "upAdapter1"
}

if ($exampleAdapter) {
   Write-Host "`nExample using `$$exampleVarName adapter:" -ForegroundColor Yellow
   Write-Host "  Adapter Name: $($exampleAdapter.Name)" -ForegroundColor Green
   Write-Host ""
   Write-Host "  Property Access Examples:" -ForegroundColor Cyan
   Write-Host "    `$$exampleVarName.ifIndex = $($exampleAdapter.ifIndex)"
   Write-Host "    `$$exampleVarName.Status = $($exampleAdapter.Status)"
   Write-Host "    `$$exampleVarName.MacAddress = $($exampleAdapter.MacAddress)"
   Write-Host "    `$$exampleVarName.LinkSpeed = $($exampleAdapter.LinkSpeed)"
   Write-Host "    `$$exampleVarName.InterfaceDescription = $($exampleAdapter.InterfaceDescription)"
   Write-Host "    `$$exampleVarName.MediaType = $($exampleAdapter.MediaType)"
   if ($exampleAdapter.DriverDescription) {
       Write-Host "    `$$exampleVarName.DriverDescription = $($exampleAdapter.DriverDescription)"
   }
   if ($exampleAdapter.DriverVersion) {
       Write-Host "    `$$exampleVarName.DriverVersion = $($exampleAdapter.DriverVersion)"
   }
} else {
   Write-Host "`nNo active network adapters found to demonstrate property access." -ForegroundColor Yellow
}

# Show all variables summary
Write-Host "`n=== ALL CREATED VARIABLES SUMMARY ===" -ForegroundColor White
Write-Host "`nNumbered up adapters (upAdapter1, upAdapter2, etc.):" -ForegroundColor Green
Get-Variable upAdapter* -ErrorAction SilentlyContinue | Format-Table Name, @{Name="Interface Name";Expression={$_.Value.Name}}, @{Name="ifIndex";Expression={$_.Value.ifIndex}}

Write-Host "`nNamed adapters (using interface names):" -ForegroundColor Green
foreach ($adapter in (Get-NetAdapter | Where-Object {$_.Status -eq "Up"})) {
   $varName = $adapter.Name -replace '[^a-zA-Z0-9]', ''
   if (Get-Variable -Name $varName -ErrorAction SilentlyContinue) {
       $var = Get-Variable -Name $varName -ValueOnly
       Write-Host "  `$$varName.ifIndex = $($var.ifIndex) (Name: $($var.Name))"
   }
}