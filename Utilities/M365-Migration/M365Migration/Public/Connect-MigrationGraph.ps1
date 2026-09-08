function Connect-MigrationGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with the requested scopes and verifies they were granted.

    .DESCRIPTION
        A cached Graph session is the most common cause of a migration script failing
        every row with 403. The session is reused only when it targets the right tenant
        and already holds every requested scope; otherwise it is dropped so the sign-in
        prompt asks for consent afresh.

        After connecting, the granted scopes are checked against the requested list and a
        shortfall throws, naming the missing scopes. Failing here costs one error message;
        failing later costs an Authorization_RequestDenied on every row of the wave and a
        results file that has to be reconciled by hand.

    .PARAMETER Scopes
        The delegated permissions the calling script needs.

    .PARAMETER TenantId
        The tenant to sign in to. Recommended when the technician has access to several.

    .PARAMETER Reconnect
        Forces a fresh sign-in even when the cached session would qualify.

    .EXAMPLE
        Connect-MigrationGraph -Scopes 'User.ReadWrite.All', 'Directory.ReadWrite.All'

        Connects and confirms both scopes were granted.

    .EXAMPLE
        Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId 'contoso.onmicrosoft.com' -Reconnect

        Signs out of any cached session and connects to the named tenant.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        Read-only scopes are enough for the discovery and planning phases; only the
        cutover writers need the ReadWrite variants.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Scopes,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId,

        [switch]$Reconnect
    )

    Initialize-MigrationModule -Name 'Microsoft.Graph.Authentication'

    $existing = $null
    try { $existing = Get-MgContext } catch { $existing = $null }

    if ($existing) {
        $granted = @($existing.Scopes)
        $missing = @($Scopes | Where-Object { $granted -notcontains $_ })
        $wrongTenant = $TenantId -and $existing.TenantId -and ($existing.TenantId -ne $TenantId)

        if ($Reconnect -or $missing.Count -gt 0 -or $wrongTenant) {
            $reason = if ($Reconnect) { '-Reconnect was requested' }
            elseif ($wrongTenant) { "it targets tenant $($existing.TenantId)" }
            else { 'it lacks scope(s): ' + ($missing -join ', ') }
            Write-MigrationLog -Message "Dropping the cached Graph session because $reason." -Level WARNING
            try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
        }
        else {
            Write-MigrationLog -Message "Reusing the existing Graph session for tenant $($existing.TenantId) as $($existing.Account)." -Level INFO
            return $existing
        }
    }

    $connectParameters = @{ Scopes = $Scopes; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $connectParameters['TenantId'] = $TenantId }

    try {
        Connect-MgGraph @connectParameters
    }
    catch {
        throw "Could not connect to Microsoft Graph: $($_.Exception.Message)"
    }

    $context = Get-MgContext
    if (-not $context) {
        throw 'Connect-MgGraph returned without establishing a session. Re-run and complete the sign-in prompt.'
    }

    $grantedScopes = @($context.Scopes)
    $notGranted = @($Scopes | Where-Object { $grantedScopes -notcontains $_ })
    if ($notGranted.Count -gt 0) {
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
        throw ('The Graph session was not granted the following required scope(s): ' + ($notGranted -join ', ') +
            '. A Global Administrator must approve them at the consent prompt - re-run and accept the request. ' +
            'Until consent is granted every call using them fails with 403 Authorization_RequestDenied.')
    }

    Write-MigrationLog -Message "Connected to Microsoft Graph - tenant $($context.TenantId) as $($context.Account)." -Level SUCCESS
    return $context
}
