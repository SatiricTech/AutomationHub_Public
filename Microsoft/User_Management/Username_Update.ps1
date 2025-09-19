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

#################################################################################
### This script will update the username of the user in the Microsoft 365 tenant.
### It updates their login username to first initial, last name @ $domainsuffix.
### It uses the Display Name to determine the first initial and last name.
#################################################################################

# Connect to Microsoft Graph (requires appropriate permissions)
Connect-MgGraph -Scopes "User.ReadWrite.All"

# Define the domain suffix
$domainSuffix = "[Domain Suffix here]"

# Get all M365 users
$users = Get-MgUser -All -Property "Id,DisplayName,UserPrincipalName,Mail"

Write-Host "Found $($users.Count) users to process..." -ForegroundColor Green

foreach ($user in $users) {
    # Skip the special user Max-F2
    if ($user.DisplayName -eq "Max-F2") {
        Write-Host "Skipping Max-F2 user as requested" -ForegroundColor Yellow
        continue
    }
    
    # Skip if DisplayName is null or empty
    if ([string]::IsNullOrWhiteSpace($user.DisplayName)) {
        Write-Host "Skipping user $($user.UserPrincipalName) - no display name" -ForegroundColor Yellow
        continue
    }
    
    $displayName = $user.DisplayName.Trim()
    $newUserPrincipalName = ""
    
    # Check if display name contains a space (first name last name format)
    if ($displayName.Contains(" ")) {
        $nameParts = $displayName -split '\s+', 2  # Split into max 2 parts
        
        if ($nameParts.Count -eq 2) {
            # First initial + Last name format
            $firstName = $nameParts[0].Trim()
            $lastName = $nameParts[1].Trim()
            
            if ($firstName.Length -gt 0 -and $lastName.Length -gt 0) {
                $newUserPrincipalName = "$($firstName.Substring(0,1))$($lastName)$domainSuffix"
            } else {
                # Fallback to display name if parsing fails
                $cleanDisplayName = $displayName -replace '[^\w\-\.]', ''
                $newUserPrincipalName = "$cleanDisplayName$domainSuffix"
            }
        } else {
            # Fallback to display name
            $cleanDisplayName = $displayName -replace '[^\w\-\.]', ''
            $newUserPrincipalName = "$cleanDisplayName$domainSuffix"
        }
    } else {
        # No space found, use display name as-is
        $cleanDisplayName = $displayName -replace '[^\w\-\.]', ''
        $newUserPrincipalName = "$cleanDisplayName$domainSuffix"
    }
    
    # Make sure the new UPN is not empty and is different from current
    if ([string]::IsNullOrWhiteSpace($newUserPrincipalName) -or $newUserPrincipalName -eq $user.UserPrincipalName) {
        Write-Host "Skipping $($user.DisplayName) - no change needed or invalid new UPN" -ForegroundColor Yellow
        continue
    }
    
    try {
        Write-Host "Updating $($user.DisplayName): $($user.UserPrincipalName) -> $newUserPrincipalName" -ForegroundColor Cyan
        
        # Update the user's UserPrincipalName
        Update-MgUser -UserId $user.Id -UserPrincipalName $newUserPrincipalName
        
        Write-Host "✓ Successfully updated $($user.DisplayName)" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Failed to update $($user.DisplayName): $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Add a small delay to avoid throttling
    Start-Sleep -Milliseconds 500
}

Write-Host "`nScript completed!" -ForegroundColor Green
Write-Host "Remember to disconnect when done: Disconnect-MgGraph" -ForegroundColor Yellow