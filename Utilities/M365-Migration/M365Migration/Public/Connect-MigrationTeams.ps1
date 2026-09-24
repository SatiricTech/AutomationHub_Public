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
        The tenant to sign in to - a GUID or a domain, which is resolved to its GUID via
        Resolve-MigrationTenantId before anything is compared or passed on, exactly as
        Connect-MigrationExchange resolves its own -TenantId. Get-CsTenant reports a GUID,
        so comparing a domain to it raw would judge a correct cached session "wrong tenant"
        and force the slowest sign-in of the three on every script of a run. A freshly
        established session is checked against it too, and a mismatch disconnects and
        throws: a Teams Phone cutover cannot be allowed to run against the wrong tenant.

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

    Initialize-MigrationModule -Name 'MicrosoftTeams' -MinimumVersion '5.7.0'

    # Resolved once so a domain is only looked up a single time, and so the cached-session
    # check, the -TenantId handed to Connect-MicrosoftTeams and the post-connect check all
    # compare against the same GUID - the only form Get-CsTenant ever reports.
    $expectedTenantId = if ($TenantId) { Resolve-MigrationTenantId -Tenant $TenantId } else { '' }

    $existing = $null
    try { $existing = Get-CsTenant -ErrorAction Stop } catch { $existing = $null }

    if ($existing) {
        $wrongTenant = $expectedTenantId -and $existing.TenantId -and ($existing.TenantId -ne $expectedTenantId)
        if ($Reconnect -or $wrongTenant) {
            $reason = if ($Reconnect) { '-Reconnect was requested' } else { "it targets tenant $($existing.TenantId)" }
            Write-MigrationLog -Message "Dropping the existing Teams session because $reason." -Level WARNING
            try { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue } catch { $null = $_ }
        }
        else {
            Write-MigrationLog -Message "Reusing the existing Teams session for tenant $($existing.TenantId) ($($existing.DisplayName))." -Level SUCCESS
            return $existing
        }
    }

    $connectParameters = @{ ErrorAction = 'Stop' }
    if ($expectedTenantId) { $connectParameters['TenantId'] = $expectedTenantId }

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

    # The account chooser can put a fresh sign-in in any tenant the technician holds an
    # account in, whatever -TenantId asked for, so the established session is checked too.
    # The comparison itself lives in Assert-MigrationTenant, so every connector and script
    # shares one implementation of "does this session match the tenant I was told to expect".
    if ($expectedTenantId) {
        try {
            $null = Assert-MigrationTenant -ExpectedTenantId $expectedTenantId -TeamsTenant $tenant `
                -Purpose 'Microsoft Teams sign-in'
        }
        catch {
            try { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue } catch { $null = $_ }
            throw ("$($_.Exception.Message) The wrong account was probably picked in the account chooser; " +
                'sign in again with an account in the expected tenant.')
        }
    }

    Write-MigrationLog -Message "Connected to Microsoft Teams - tenant $($tenant.TenantId) ($($tenant.DisplayName))." -Level SUCCESS
    return $tenant
}
