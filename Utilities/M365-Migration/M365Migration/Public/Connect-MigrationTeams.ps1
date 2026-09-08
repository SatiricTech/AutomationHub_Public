function Connect-MigrationTeams {
    <#
    .SYNOPSIS
        Connects to Microsoft Teams PowerShell.

    .DESCRIPTION
        Reuses a live Teams session unless -Reconnect is given or the cached session
        belongs to a different tenant. Teams sign-in is the slowest of the three services
        the toolkit uses, so reuse matters; targeting the wrong tenant matters more, hence
        the tenant check.

    .PARAMETER TenantId
        The tenant to sign in to.

    .PARAMETER Reconnect
        Forces a fresh connection.

    .EXAMPLE
        Connect-MigrationTeams

        Connects using the signed-in user's default tenant.

    .EXAMPLE
        Connect-MigrationTeams -TenantId 'contoso.onmicrosoft.com' -Reconnect

        Signs out of any cached session and connects to the named tenant.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        Teams Phone operations need the Teams Administrator or Teams Communications
        Administrator role; Global Reader is not sufficient for the assignment cmdlets.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Teams is the product name; the singular form would name a different thing.')]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId,

        [switch]$Reconnect
    )

    Initialize-MigrationModule -Name 'MicrosoftTeams'

    $existing = $null
    try { $existing = Get-CsTenant -ErrorAction Stop } catch { $existing = $null }

    if ($existing) {
        $wrongTenant = $TenantId -and $existing.TenantId -and ($existing.TenantId -ne $TenantId)
        if ($Reconnect -or $wrongTenant) {
            $reason = if ($Reconnect) { '-Reconnect was requested' } else { "it targets tenant $($existing.TenantId)" }
            Write-MigrationLog -Message "Dropping the existing Teams session because $reason." -Level WARNING
            try { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue } catch { $null = $_ }
        }
        else {
            Write-MigrationLog -Message "Reusing the existing Teams session for tenant $($existing.TenantId)." -Level INFO
            return $existing
        }
    }

    $connectParameters = @{ ErrorAction = 'Stop' }
    if ($TenantId) { $connectParameters['TenantId'] = $TenantId }

    try {
        Connect-MicrosoftTeams @connectParameters | Out-Null
    }
    catch {
        throw "Could not connect to Microsoft Teams: $($_.Exception.Message)"
    }

    $tenant = $null
    try { $tenant = Get-CsTenant -ErrorAction Stop } catch { $tenant = $null }
    if (-not $tenant) {
        throw 'Connect-MicrosoftTeams returned without establishing a usable session. Re-run and complete the sign-in prompt.'
    }

    Write-MigrationLog -Message "Connected to Microsoft Teams - tenant $($tenant.TenantId) ($($tenant.DisplayName))." -Level SUCCESS
    return $tenant
}
