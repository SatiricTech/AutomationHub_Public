# Check if running on a Domain Controller
$isDC = (Get-WmiObject -Class Win32_ComputerSystem).DomainRole -ge 4

if (-not $isDC) {
    Write-Host "Error: This script must be run on a Domain Controller. Exiting..." -ForegroundColor Red
    exit 1
}

Write-Host "Running on Domain Controller - proceeding with account creation..." -ForegroundColor Green

# Import Active Directory module
Import-Module ActiveDirectory

# Set account details
$Username = "{YourAdminUsername}"
$Password = ConvertTo-SecureString "$env:password" -AsPlainText -Force

# Create the user account
New-ADUser -Name $Username -SamAccountName $Username -Enabled $True -AccountPassword $Password -PasswordNeverExpires $True

# Add user to Domain Admins group
Add-ADGroupMember -Identity "Domain Admins" -Members $Username

# Verify the account creation and group membership
Get-ADUser $Username -Properties MemberOf | Select-Object Name,Enabled,@{N='Groups';E={$_.MemberOf}}