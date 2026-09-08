function Connect-MigrationExchange {
    <#
    .SYNOPSIS
        Connects to Exchange Online, optionally against a delegated (GDAP) tenant.

    .DESCRIPTION
        Reuses a live Exchange Online session unless -Reconnect is given, because the
        connection is slow to establish and a migration run makes many of them. When the
        existing session targets a different delegated organisation it is replaced rather
        than reused - running a cutover against the wrong tenant is the failure mode this
        check exists to prevent.

        The connected tenant is logged so the results file and the log agree on which
        tenant was touched.

    .PARAMETER DelegatedOrganization
        The customer tenant domain for GDAP delegated access, for example
        'contoso.onmicrosoft.com'. Omit when signing in to your own tenant.

    .PARAMETER Reconnect
        Forces a fresh connection.

    .EXAMPLE
        Connect-MigrationExchange

        Connects to Exchange Online in the signed-in user's own tenant.

    .EXAMPLE
        Connect-MigrationExchange -DelegatedOrganization 'contoso.onmicrosoft.com'

        Connects through GDAP to a customer tenant.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        App-only certificate authentication cannot be combined with
        -DelegatedOrganization; use delegated sign-in for cross-tenant work.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DelegatedOrganization,

        [switch]$Reconnect
    )

    Initialize-MigrationModule -Name 'ExchangeOnlineManagement'

    $existing = $null
    try {
        $existing = @(Get-ConnectionInformation -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.State -eq 'Connected' }) | Select-Object -First 1
    }
    catch {
        $existing = $null
    }

    if ($existing) {
        $wrongTenant = $DelegatedOrganization -and $existing.Organization -and
            ($existing.Organization -ne $DelegatedOrganization)

        if ($Reconnect -or $wrongTenant) {
            $reason = if ($Reconnect) { '-Reconnect was requested' } else { "it targets $($existing.Organization)" }
            Write-MigrationLog -Message "Dropping the existing Exchange Online session because $reason." -Level WARNING
            try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch { $null = $_ }
        }
        else {
            Write-MigrationLog -Message "Reusing the existing Exchange Online session for $($existing.Organization)." -Level INFO
            return $existing
        }
    }

    $connectParameters = @{ ShowBanner = $false; ErrorAction = 'Stop' }
    if ($DelegatedOrganization) { $connectParameters['DelegatedOrganization'] = $DelegatedOrganization }

    try {
        Connect-ExchangeOnline @connectParameters
    }
    catch {
        throw "Could not connect to Exchange Online: $($_.Exception.Message)"
    }

    $information = @(Get-ConnectionInformation -ErrorAction SilentlyContinue |
        Where-Object { $_ -and $_.State -eq 'Connected' }) | Select-Object -First 1

    if (-not $information) {
        throw 'Connect-ExchangeOnline returned without establishing a session. Re-run and complete the sign-in prompt.'
    }

    Write-MigrationLog -Message "Connected to Exchange Online - organisation $($information.Organization) as $($information.UserPrincipalName)." -Level SUCCESS
    return $information
}
