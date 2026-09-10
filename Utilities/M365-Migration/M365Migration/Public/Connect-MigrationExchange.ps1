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

    .PARAMETER TenantId
        The tenant ID (GUID) the caller expects to be connected to - typically the GUID
        already returned by Connect-MigrationGraph in the same run. A cached session
        whose TenantID does not match is dropped and reconnected. Exchange Online does
        not expose the connected tenant's domain outside CBA/managed-identity
        connections, so this check only works with the GUID form; pass a domain here and
        it is ignored.

    .PARAMETER Reconnect
        Forces a fresh connection.

    .EXAMPLE
        Connect-MigrationExchange

        Connects to Exchange Online in the signed-in user's own tenant.

    .EXAMPLE
        Connect-MigrationExchange -DelegatedOrganization 'contoso.onmicrosoft.com'

        Connects through GDAP to a customer tenant.

    .EXAMPLE
        Connect-MigrationExchange -TenantId $graphContext.TenantId

        Connects (or reuses a cached session) and guards against a leftover Exchange
        Online session pointed at a different tenant than the one Graph is signed in to.

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

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TenantId,

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
        # Organization is populated only for CBA/managed-identity connections; a normal
        # interactive sign-in - delegated (GDAP) or the primary dedicated-GA path - leaves
        # it blank, so DelegatedOrganization (populated from the -DelegatedOrganization
        # Connect-ExchangeOnline was given) and TenantID are what a cached session can
        # actually be checked against. Get-MigrationProperty is used throughout because a
        # mocked or thin Get-ConnectionInformation object may not carry every property, and
        # the module runs under Set-StrictMode -Version Latest.
        $existingDelegatedOrganization = Get-MigrationProperty -InputObject $existing -Name 'DelegatedOrganization' -Default ''
        $existingTenantId = Get-MigrationProperty -InputObject $existing -Name 'TenantId' -Default ''
        $existingUpn = Get-MigrationProperty -InputObject $existing -Name 'UserPrincipalName' -Default ''

        $wrongOrganization = $DelegatedOrganization -and $existingDelegatedOrganization -and
            ($existingDelegatedOrganization -ne $DelegatedOrganization)
        $wrongTenantId = $TenantId -and $existingTenantId -and ($existingTenantId -ne $TenantId)
        $wrongTenant = $wrongOrganization -or $wrongTenantId

        if ($Reconnect -or $wrongTenant) {
            $reason = if ($Reconnect) { '-Reconnect was requested' }
            elseif ($wrongOrganization) { "it targets $existingDelegatedOrganization" }
            else { "it targets tenant $existingTenantId" }
            Write-MigrationLog -Message "Dropping the existing Exchange Online session because $reason." -Level WARNING
            try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch { $null = $_ }
        }
        else {
            Write-MigrationLog -Message ("Reusing the existing Exchange Online session for tenant " +
                "$existingTenantId as $existingUpn.") -Level SUCCESS
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

    $connectedOrganization = Get-MigrationProperty -InputObject $information -Name 'DelegatedOrganization' -Default ''
    if (-not $connectedOrganization) { $connectedOrganization = Get-MigrationProperty -InputObject $information -Name 'Organization' -Default '' }
    $connectedUpn = Get-MigrationProperty -InputObject $information -Name 'UserPrincipalName' -Default ''
    $connectedTenantId = Get-MigrationProperty -InputObject $information -Name 'TenantId' -Default ''
    $organizationText = if ($connectedOrganization) { $connectedOrganization } else { $connectedTenantId }
    Write-MigrationLog -Message "Connected to Exchange Online - organisation $organizationText as $connectedUpn." -Level SUCCESS
    return $information
}
