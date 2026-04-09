#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a Microsoft Entra ID Enterprise Application for Timus Networks integration with SSO and Sync capabilities.

.DESCRIPTION
    This script creates an enterprise application in Microsoft Entra ID with the following capabilities:
    - Creates application with specified redirect URI
    - Assigns required API permissions for user and group management
    - Removes default User.Read permission
    - Generates a client secret valid for 730 days (24 months)
    - Outputs all necessary credentials as copyable artifacts

.PARAMETER AppName
    Display name for the enterprise application (default: "Timus Networks SSO Sync")

.PARAMETER RedirectUri
    Redirect URI for the application (default: "https://app.timusnetworks.com/auth/callback")

.PARAMETER TenantId
    Optional tenant ID. If not provided, will use the connected tenant.

.EXAMPLE
    .\Timus_Build_Entra-SSOandSync_App.ps1
    
.EXAMPLE
    .\Timus_Build_Entra-SSOandSync_App.ps1 -AppName "My Timus App" -RedirectUri "https://mycompany.timusnetworks.com/auth"

.NOTES
    Author: AutomationHub
    Requires: Microsoft.Graph PowerShell module
    Requires: Global Administrator or Application Administrator role
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AppName = "Timus Networks SSO Sync",
    
    [Parameter(Mandatory = $false)]
    [string]$RedirectUri = "https://app.timusnetworks.com/auth/callback",
    
    [Parameter(Mandatory = $false)]
    [string]$TenantId
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check if Microsoft.Graph module is installed
function Test-MicrosoftGraphModule {
    try {
        $module = Get-Module -Name Microsoft.Graph -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        if ($module) {
            Write-ColorOutput "✓ Microsoft.Graph module found (Version: $($module.Version))" "Green"
            return $true
        } else {
            Write-ColorOutput "✗ Microsoft.Graph module not found" "Red"
            return $false
        }
    } catch {
        Write-ColorOutput "✗ Error checking Microsoft.Graph module: $($_.Exception.Message)" "Red"
        return $false
    }
}

# Function to install Microsoft.Graph module
function Install-MicrosoftGraphModule {
    try {
        Write-ColorOutput "Installing Microsoft.Graph module..." "Yellow"
        Write-ColorOutput "This may take a few minutes..." "Cyan"
        
        # Set execution policy if needed
        $currentPolicy = Get-ExecutionPolicy
        if ($currentPolicy -eq "Restricted") {
            Write-ColorOutput "Setting execution policy to allow module installation..." "Yellow"
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        }
        
        Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        Write-ColorOutput "✓ Microsoft.Graph module installed successfully" "Green"
    } catch {
        Write-ColorOutput "✗ Failed to install Microsoft.Graph module: $($_.Exception.Message)" "Red"
        Write-ColorOutput "Common solutions:" "Yellow"
        Write-ColorOutput "1. Run PowerShell as Administrator" "Yellow"
        Write-ColorOutput "2. Check internet connectivity" "Yellow"
        Write-ColorOutput "3. Try: Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser" "Yellow"
        throw
    }
}

# Function to connect to Microsoft Graph
function Connect-MicrosoftGraph {
    try {
        Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"
        
        # Define required scopes
        $scopes = @(
            "Application.ReadWrite.All",
            "Directory.ReadWrite.All",
            "User.Read.All",
            "Group.Read.All"
        )
        
        if ($TenantId) {
            Connect-MgGraph -Scopes $scopes -TenantId $TenantId
        } else {
            Connect-MgGraph -Scopes $scopes
        }
        
        Write-ColorOutput "✓ Successfully connected to Microsoft Graph" "Green"
    } catch {
        Write-ColorOutput "✗ Failed to connect to Microsoft Graph: $($_.Exception.Message)" "Red"
        throw
    }
}

# Function to create the enterprise application
function New-TimusEnterpriseApp {
    param(
        [string]$DisplayName,
        [string]$ReplyUrl
    )
    
    try {
        Write-ColorOutput "Creating enterprise application: $DisplayName" "Yellow"
        
        # Define required resource access (API permissions) - following Waldek's approach
        $requiredResourceAccess = @{
            "resourceAccess" = @(
                @{
                    id = "df021288-bdef-4463-88db-98f22de89214"  # User.Read.All
                    type = "Role"
                },
                @{
                    id = "5b567255-7703-4780-807c-7be8301ae99b"  # Group.Read.All (corrected)
                    type = "Role"
                },
                @{
                    id = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"  # Directory.Read.All
                    type = "Role"
                },
                @{
                    id = "741f803b-c850-494e-b5df-cde7c675a1ca"  # User.ReadWrite.All
                    type = "Role"
                },
                @{
                    id = "62a82d76-70ea-41e2-9197-370581804d09"  # Group.ReadWrite.All
                    type = "Role"
                }
            )
            "resourceAppId" = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
        }
        
        # Create application with web configuration and API permissions
        $appParams = @{
            DisplayName = $DisplayName
            Web = @{
                RedirectUris = @($ReplyUrl)
                ImplicitGrantSettings = @{
                    EnableIdTokenIssuance = $true
                    EnableAccessTokenIssuance = $false
                }
            }
            SignInAudience = "AzureADMultipleOrgs"
            RequiredResourceAccess = @($requiredResourceAccess)
        }
        
        $app = New-MgApplication @appParams
        Write-ColorOutput "✓ Application created successfully (App ID: $($app.AppId))" "Green"
        
        return $app
    } catch {
        Write-ColorOutput "✗ Failed to create application: $($_.Exception.Message)" "Red"
        throw
    }
}

# Function to create service principal
function New-TimusServicePrincipal {
    param(
        [string]$AppId
    )
    
    try {
        Write-ColorOutput "Creating service principal..." "Yellow"
        
        $servicePrincipal = New-MgServicePrincipal -AppId $AppId
        Write-ColorOutput "✓ Service principal created successfully" "Green"
        
        return $servicePrincipal
    } catch {
        Write-ColorOutput "✗ Failed to create service principal: $($_.Exception.Message)" "Red"
        throw
    }
}

# Function to grant admin consent using the Azure Portal API approach
function Grant-TimusAdminConsent {
    param(
        [string]$ApplicationId,
        [string]$ServicePrincipalId
    )
    
    try {
        Write-ColorOutput "Granting admin consent using Azure Portal API approach..." "Yellow"
        
        # Get the application to check what permissions are configured
        $app = Get-MgApplication -ApplicationId $ApplicationId
        
        # Build the consent payload exactly like Azure Portal does
        $consentPayload = @{
            clientAppId = $ApplicationId
            onBehalfOfAll = $true
            checkOnly = $false
            tags = @()
            constrainToRra = $true
            dynamicPermissions = @()
        }
        
        # Add Microsoft Graph permissions
        $graphPermissions = @{
            appIdentifier = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
            appRoles = @()
            scopes = @()
        }
        
        # Add application permissions (app roles) to the consent payload
        if ($app.RequiredResourceAccess) {
            foreach ($resourceAccess in $app.RequiredResourceAccess) {
                if ($resourceAccess.ResourceAppId -eq "00000003-0000-0000-c000-000000000000") {
                    foreach ($access in $resourceAccess.ResourceAccess) {
                        if ($access.Type -eq "Role") {
                            # Get the permission name from the app role ID
                            $graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
                            $appRole = $graphSp.AppRoles | Where-Object { $_.Id -eq $access.Id }
                            if ($appRole) {
                                $graphPermissions.appRoles += $appRole.Value
                                Write-ColorOutput "  ✓ Adding app role: $($appRole.Value)" "Green"
                            }
                        }
                    }
                }
            }
        }
        
        # Add the Microsoft Graph permissions to the payload
        if ($graphPermissions.appRoles.Count -gt 0) {
            $consentPayload.dynamicPermissions += $graphPermissions
        }
        
        # Make the API call to grant consent
        Write-ColorOutput "Sending consent request to Microsoft Graph..." "Yellow"
        
        try {
            # Use Invoke-MgGraphRequest to call the beta endpoint directly
            $response = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/directory/consentToApp" -Body ($consentPayload | ConvertTo-Json -Depth 10) -ContentType "application/json"
            
            Write-ColorOutput "✓ Admin consent granted successfully via Azure Portal API" "Green"
            
            # Return the permission names that were granted
            $grantedPermissions = @()
            foreach ($appRole in $graphPermissions.appRoles) {
                $grantedPermissions += $appRole
            }
            
            return $grantedPermissions
            
        } catch {
            Write-ColorOutput "✗ Azure Portal API consent failed: $($_.Exception.Message)" "Red"
            Write-ColorOutput "Falling back to individual permission assignment..." "Yellow"
            
            # Fallback to individual permission assignment
            return Grant-TimusIndividualConsent -ServicePrincipalId $ServicePrincipalId
        }
        
    } catch {
        Write-ColorOutput "✗ Failed to grant admin consent: $($_.Exception.Message)" "Red"
        Write-ColorOutput "Note: You may need Global Administrator or Application Administrator role" "Yellow"
        return @()
    }
}

# Working function based on Dmitriy Ivanov's proven solution
function Grant-TimusWorkingConsent {
    param(
        [string]$ApplicationId,
        [string]$ServicePrincipalId
    )
    
    try {
        Write-ColorOutput "Granting admin consent using proven OAuth2PermissionGrant approach..." "Yellow"
        
        # Get the application to check what permissions are configured
        $app = Get-MgApplication -ApplicationId $ApplicationId
        $sp = Get-MgServicePrincipal -ApplicationId $ApplicationId
        
        Write-ColorOutput "Processing $($app.RequiredResourceAccess.Count) resource access entries..." "Cyan"
        
        $assignedPermissions = @()
        
        foreach ($resourceAccess in $app.RequiredResourceAccess) {
            try {
                # Get the resource service principal (e.g., Microsoft Graph)
                $resourceSp = Get-MgServicePrincipal -Filter "AppId eq '$($resourceAccess.ResourceAppId)'"
                
                if (-not $resourceSp) {
                    Write-ColorOutput "  ⚠ Resource service principal not found for AppId: $($resourceAccess.ResourceAppId)" "Yellow"
                    continue
                }
                
                Write-ColorOutput "  Processing resource: $($resourceSp.DisplayName)" "Cyan"
                
                # Build scope mapping for app roles (application permissions)
                $scopesIdToValue = @{}
                $resourceSp.AppRoles | ForEach-Object { $scopesIdToValue[$_.Id] = $_.Value }
                
                # Get required scopes from the app's resource access
                $requiredScopes = @()
                foreach ($access in $resourceAccess.ResourceAccess) {
                    if ($scopesIdToValue.ContainsKey($access.Id)) {
                        $requiredScopes += $scopesIdToValue[$access.Id]
                        Write-ColorOutput "    Required scope: $($scopesIdToValue[$access.Id])" "Green"
                    }
                }
                
                if ($requiredScopes.Count -eq 0) {
                    Write-ColorOutput "    No application permissions found for this resource" "Yellow"
                    continue
                }
                
                # Check if grant already exists
                $existingGrant = Get-MgOauth2PermissionGrant -Filter "ClientId eq '$($sp.Id)' and ResourceId eq '$($resourceSp.Id)'"
                
                $newGrantRequired = $true
                if ($existingGrant) {
                    $grantedScopes = $existingGrant.Scope.Split(" ")
                    $requiredScopesSet = [System.Collections.Generic.HashSet[string]]$requiredScopes
                    $grantedScopesSet = [System.Collections.Generic.HashSet[string]]$grantedScopes
                    
                    if ($requiredScopesSet.IsSubsetOf($grantedScopesSet)) {
                        Write-ColorOutput "    ✓ Grant already exists with all required permissions" "Green"
                        $newGrantRequired = $false
                    } else {
                        Write-ColorOutput "    Revoking existing grant to update permissions..." "Yellow"
                        Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $existingGrant.Id
                    }
                }
                
                if ($newGrantRequired) {
                    $scopesToGrant = $requiredScopes -join " "
                    Write-ColorOutput "    Issuing new grant with scopes: $scopesToGrant" "Yellow"
                    
                    # Create the OAuth2 permission grant (this is what actually grants admin consent!)
                    New-MgOauth2PermissionGrant -ClientId $sp.Id -ConsentType "AllPrincipals" -ResourceId $resourceSp.Id -Scope $scopesToGrant | Out-Null
                    Write-ColorOutput "    ✓ Successfully granted admin consent" "Green"
                }
                
                $assignedPermissions += $requiredScopes
                
            } catch {
                Write-ColorOutput "  ✗ Failed to process resource $($resourceAccess.ResourceAppId): $($_.Exception.Message)" "Red"
            }
        }
        
        # Test if permissions actually work
        Write-ColorOutput "Testing permission usage..." "Yellow"
        try {
            $testUsers = Get-MgUser -Top 1 -ErrorAction Stop
            Write-ColorOutput "  ✓ Permission test successful - can read users" "Green"
        } catch {
            Write-ColorOutput "  ⚠ Permission test failed: $($_.Exception.Message)" "Yellow"
        }
        
        Write-ColorOutput "✓ Admin consent process completed successfully" "Green"
        return $assignedPermissions
        
    } catch {
        Write-ColorOutput "✗ Admin consent failed: $($_.Exception.Message)" "Red"
        return @()
    }
}

# Function to remove default permissions
function Remove-DefaultPermissions {
    param(
        [string]$ServicePrincipalId
    )
    
    try {
        Write-ColorOutput "Removing default permissions..." "Yellow"
        
        # Get current app role assignments
        $currentAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ServicePrincipalId
        
        # Remove User.Read permission if it exists
        $userReadAssignment = $currentAssignments | Where-Object { 
            $_.AppRoleId -eq "e1fe6dd8-ba31-4d61-89e7-88639da4683d" -or  # User.Read
            $_.AppRoleId -eq "311a71cc-e48d-4a7d-9d6b-2d8c8a3c4c5d"     # Alternative User.Read ID
        }
        
        if ($userReadAssignment) {
            Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ServicePrincipalId -AppRoleAssignmentId $userReadAssignment.Id
            Write-ColorOutput "  ✓ Removed default User.Read permission" "Green"
        } else {
            Write-ColorOutput "  ℹ No default User.Read permission found to remove" "Cyan"
        }
        
        Write-ColorOutput "✓ Default permission cleanup completed" "Green"
    } catch {
        Write-ColorOutput "✗ Failed to remove default permissions: $($_.Exception.Message)" "Red"
        # Don't throw here as this is not critical
    }
}

# Function to create client secret
function New-TimusClientSecret {
    param(
        [string]$ApplicationId
    )
    
    try {
        Write-ColorOutput "Creating client secret (valid for 730 days)..." "Yellow"
        
        # Calculate expiration date (730 days from now)
        $startDate = Get-Date
        $endDate = $startDate.AddDays(730)
        
        # Create password credential
        $passwordCredential = @{
            displayName = "Timus Integration Secret"
            startDateTime = $startDate
            endDateTime = $endDate
        }
        
        $clientSecret = Add-MgApplicationPassword -ApplicationId $ApplicationId -PasswordCredential $passwordCredential
        
        Write-ColorOutput "✓ Client secret created successfully" "Green"
        Write-ColorOutput "  Secret expires: $($endDate.ToString('yyyy-MM-dd HH:mm:ss'))" "Cyan"
        
        return $clientSecret
    } catch {
        Write-ColorOutput "✗ Failed to create client secret: $($_.Exception.Message)" "Red"
        throw
    }
}

# Function to output credentials
function Show-Credentials {
    param(
        [object]$App,
        [object]$ClientSecret,
        [string]$TenantId,
        [array]$AssignedPermissions = @()
    )
    
    Write-ColorOutput "`n" "Magenta"
    Write-ColorOutput ("="*80) "Magenta"
    Write-ColorOutput "                    TIMUS NETWORKS INTEGRATION CREDENTIALS" "Magenta"
    Write-ColorOutput ("="*80) "Magenta"
    Write-ColorOutput ""
    
    # Tenant ID
    Write-ColorOutput "TENANT ID:" "Yellow"
    Write-Host $TenantId -ForegroundColor White -BackgroundColor Black
    Write-Host ""
    
    # Application ID
    Write-ColorOutput "APPLICATION ID:" "Yellow"
    Write-Host $App.AppId -ForegroundColor White -BackgroundColor Black
    Write-Host ""
    
    # Client Secret Value
    Write-ColorOutput "CLIENT SECRET VALUE:" "Yellow"
    Write-Host $ClientSecret.SecretText -ForegroundColor White -BackgroundColor Black
    Write-Host ""
    
    # Client Secret ID
    Write-ColorOutput "CLIENT SECRET ID:" "Yellow"
    Write-Host $ClientSecret.KeyId -ForegroundColor White -BackgroundColor Black
    Write-Host ""
    
    # Redirect URI
    Write-ColorOutput "REDIRECT URI:" "Yellow"
    Write-Host $RedirectUri -ForegroundColor White -BackgroundColor Black
    Write-Host ""
    
    # Assigned Permissions
    if ($AssignedPermissions.Count -gt 0) {
        Write-ColorOutput "ASSIGNED PERMISSIONS:" "Yellow"
        foreach ($permission in $AssignedPermissions) {
            Write-Host "  • $permission" -ForegroundColor White -BackgroundColor Black
        }
        Write-Host ""
    } else {
        Write-ColorOutput "ASSIGNED PERMISSIONS:" "Yellow"
        Write-Host "  No permissions were assigned" -ForegroundColor Red -BackgroundColor Black
        Write-Host ""
    }
    
    Write-ColorOutput ("="*80) "Magenta"
    Write-ColorOutput "IMPORTANT: Save these credentials securely. The secret value cannot be retrieved again!" "Red"
    Write-ColorOutput ("="*80) "Magenta"
    Write-Host ""
    
    # Copy to clipboard functionality
    try {
        $permissionsText = if ($AssignedPermissions.Count -gt 0) { $AssignedPermissions -join ", " } else { "None assigned" }
        
        $credentialsText = @"
Tenant ID: $TenantId
Application ID: $($App.AppId)
Client Secret Value: $($ClientSecret.SecretText)
Client Secret ID: $($ClientSecret.KeyId)
Redirect URI: $RedirectUri
Assigned Permissions: $permissionsText
"@
        
        $credentialsText | Set-Clipboard
        Write-ColorOutput "✓ Credentials copied to clipboard for easy pasting" "Green"
    } catch {
        Write-ColorOutput "⚠ Could not copy to clipboard automatically" "Yellow"
    }
    
    # Add manual consent instructions if needed
    if ($AssignedPermissions.Count -lt 5) {
        Write-ColorOutput ""
        Write-ColorOutput "⚠ MANUAL ADMIN CONSENT REQUIRED" "Red"
        Write-ColorOutput "Some permissions may require manual admin consent:" "Yellow"
        Write-ColorOutput "1. Go to Azure Portal > Enterprise Applications" "Yellow"
        Write-ColorOutput "2. Find your app: $($App.DisplayName)" "Yellow"
        Write-ColorOutput "3. Go to Permissions > Grant admin consent" "Yellow"
        Write-ColorOutput "4. Click 'Grant admin consent for [Your Organization]'" "Yellow"
        Write-ColorOutput ""
    }
}

# Main execution
try {
    Write-ColorOutput "Starting Timus Networks Entra ID Enterprise Application Creation" "Cyan"
    Write-ColorOutput "Application Name: $AppName" "Cyan"
    Write-ColorOutput "Redirect URI: $RedirectUri" "Cyan"
    Write-ColorOutput ""
    
    # Check and install Microsoft.Graph module if needed
    if (-not (Test-MicrosoftGraphModule)) {
        Install-MicrosoftGraphModule
    }
    
    # Check if Microsoft Graph commands are available (skip explicit import due to known issues)
    try {
        Write-ColorOutput "Checking Microsoft Graph command availability..." "Yellow"
        $null = Get-Command Connect-MgGraph -ErrorAction Stop
        $null = Get-Command New-MgApplication -ErrorAction Stop
        $null = Get-Command New-MgServicePrincipal -ErrorAction Stop
        Write-ColorOutput "✓ Microsoft Graph commands are available" "Green"
    } catch {
        Write-ColorOutput "✗ Microsoft Graph commands not available" "Red"
        Write-ColorOutput "Please restart PowerShell and try again, or run:" "Yellow"
        Write-ColorOutput "Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber" "Yellow"
        throw
    }
    
    # Connect to Microsoft Graph
    Connect-MicrosoftGraph
    
    # Get tenant information
    $tenant = Get-MgOrganization
    $currentTenantId = $tenant.Id
    
    Write-ColorOutput "Connected to tenant: $($tenant.DisplayName)" "Cyan"
    Write-ColorOutput ""
    
    # Create enterprise application
    $app = New-TimusEnterpriseApp -DisplayName $AppName -ReplyUrl $RedirectUri
    
    # Create service principal
    $servicePrincipal = New-TimusServicePrincipal -AppId $app.AppId
    
    # Grant admin consent using the proven working approach
    $assignedPermissions = Grant-TimusWorkingConsent -ApplicationId $app.Id -ServicePrincipalId $servicePrincipal.Id
    
    # Remove default permissions
    Remove-DefaultPermissions -ServicePrincipalId $servicePrincipal.Id
    
    # Create client secret
    $clientSecret = New-TimusClientSecret -ApplicationId $app.Id
    
    # Display credentials
    Show-Credentials -App $app -ClientSecret $clientSecret -TenantId $currentTenantId -AssignedPermissions $assignedPermissions
    
    Write-ColorOutput "`n✓ Timus Networks Entra ID Enterprise Application created successfully!" "Green"
    Write-ColorOutput "You can now use these credentials to configure Timus Networks integration." "Green"
    
} catch {
    Write-ColorOutput "`n✗ Script execution failed: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Stack trace: $($_.ScriptStackTrace)" "Red"
    exit 1
} finally {
    # Disconnect from Microsoft Graph
    try {
        Disconnect-MgGraph | Out-Null
        Write-ColorOutput "`nDisconnected from Microsoft Graph" "Cyan"
    } catch {
        # Ignore disconnect errors
    }
}
