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
        The tenant the caller expects to be connected to - a GUID (typically the one
        already returned by Connect-MigrationGraph in the same run) or a domain, which
        is resolved to its GUID via Resolve-MigrationTenantId before any comparison. A
        cached session whose TenantID does not match is dropped and reconnected, and a
        freshly established session is checked again after Connect-ExchangeOnline
        returns: a mismatch there disconnects and throws, because a cutover run cannot
        be allowed to silently proceed against the wrong tenant.

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

    # Resolved once so a domain is only looked up a single time and both the cached-
    # session check below and the post-connect check further down compare against the
    # same GUID.
    $expectedTenantId = if ($TenantId) { Resolve-MigrationTenantId -Tenant $TenantId } else { '' }

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
        $wrongTenantId = $expectedTenantId -and $existingTenantId -and ($existingTenantId -ne $expectedTenantId)
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

    # Nothing above told Connect-ExchangeOnline which tenant to use: on the interactive
    # path it has no -TenantId to honour, and the account chooser can land the session in
    # any tenant the technician holds an account in - including the one the cached session
    # was just dropped for. So the freshly established session is checked as well, which is
    # the only place the expected tenant can be enforced at all. The comparison itself lives
    # in Assert-MigrationTenant, so every connector and script shares one implementation of
    # "does this session match the tenant I was told to expect".
    if ($expectedTenantId) {
        try {
            $null = Assert-MigrationTenant -ExpectedTenantId $expectedTenantId -ExchangeConnection $information `
                -Purpose 'Exchange Online sign-in'
        }
        catch {
            try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch { $null = $_ }
            throw ("$($_.Exception.Message) The wrong account was probably picked in the account chooser; " +
                'sign in again with an account in the expected tenant.')
        }
    }

    $organizationText = if ($connectedOrganization) { $connectedOrganization } else { $connectedTenantId }
    Write-MigrationLog -Message "Connected to Exchange Online - organisation $organizationText as $connectedUpn." -Level SUCCESS
    return $information
}
