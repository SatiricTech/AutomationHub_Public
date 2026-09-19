function Assert-MigrationTenant {
    <#
    .SYNOPSIS
        Confirms every connected service is signed in to the expected tenant.

    .DESCRIPTION
        The single tenant check every connecting script calls once it has whichever of
        Graph, Exchange Online and Teams it needs for the run. Each connection that was
        supplied is compared against -ExpectedTenantId; a mismatch throws immediately,
        because acting on the wrong customer's tenant is the failure mode this function
        exists to prevent, and a run has to stop before it touches anything.

        -ExpectedTenantId may be a GUID or a domain; a domain is resolved to its GUID
        with Resolve-MigrationTenantId before any comparison, exactly as
        Connect-MigrationExchange resolves -TenantId.

        Passing an empty -ExpectedTenantId is legal - a script that was not told which
        tenant to expect cannot demand one - but it is not silent: a WARNING is written
        for every connection that was supplied, naming the tenant and account it is
        signed in to, so the run log states plainly which tenant is about to be acted on
        even though nothing forced it to be the right one.

        Connection objects are read defensively through Get-MigrationProperty, because a
        mocked object in a test, or a thin response from a partially-scoped connection,
        may not carry every property, and the module runs under
        Set-StrictMode -Version Latest.

    .PARAMETER ExpectedTenantId
        The tenant ID (GUID or domain) the run expects every connection to be signed in
        to. An empty string means no tenant was specified.

    .PARAMETER GraphContext
        The object returned by Connect-MigrationGraph. Its TenantId and Account
        properties are read; omit when the run has no Graph connection to check.

    .PARAMETER ExchangeConnection
        The object returned by Connect-MigrationExchange. Its TenantId and
        UserPrincipalName properties are read; omit when the run has no Exchange Online
        connection to check.

    .PARAMETER TeamsTenant
        The object returned by Connect-MigrationTeams. Its TenantId property is read;
        omit when the run has no Teams connection to check.

    .PARAMETER Purpose
        A short label identifying the run, used to prefix a mismatch's error message so
        an operator watching several concurrent runs can tell which one failed. Defaults
        to 'This run'.

    .EXAMPLE
        Assert-MigrationTenant -ExpectedTenantId $graphContext.TenantId -GraphContext $graphContext `
            -ExchangeConnection $exchangeConnection

        Confirms the Graph and Exchange Online connections agree with the expected
        tenant, throwing if either does not.

    .EXAMPLE
        Assert-MigrationTenant -ExpectedTenantId '' -GraphContext $graphContext -Purpose 'Contoso cutover'

        Records which tenant the run is about to act on without enforcing anything,
        because the caller has no expected tenant to compare against.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ExpectedTenantId,

        [AllowNull()]
        $GraphContext,

        [AllowNull()]
        $ExchangeConnection,

        [AllowNull()]
        $TeamsTenant,

        [ValidateNotNullOrEmpty()]
        [string]$Purpose = 'This run'
    )

    # A label, rather than a property name, per connection: it is what a mismatch
    # message names and what an empty-expected warning is written once for.
    $services = [ordered]@{
        Graph    = [pscustomobject]@{ Label = 'Microsoft Graph'; Connection = $GraphContext; UpnProperty = 'Account' }
        Exchange = [pscustomobject]@{
            Label = 'Exchange Online'; Connection = $ExchangeConnection; UpnProperty = 'UserPrincipalName' }
        Teams    = [pscustomobject]@{ Label = 'Microsoft Teams'; Connection = $TeamsTenant; UpnProperty = '' }
    }

    $connected = @{}
    foreach ($key in $services.Keys) {
        $service = $services[$key]
        $connected[$key] = if ($service.Connection) {
            Get-MigrationProperty -InputObject $service.Connection -Name 'TenantId' -Default ''
        }
        else { '' }
    }

    if (-not $ExpectedTenantId) {
        foreach ($key in $services.Keys) {
            $service = $services[$key]
            if (-not $service.Connection) { continue }

            $tenantId = $connected[$key]
            $upn = if ($service.UpnProperty) {
                Get-MigrationProperty -InputObject $service.Connection -Name $service.UpnProperty -Default ''
            }
            else { '' }
            $upnSuffix = if ($upn) { " ($upn)" } else { '' }

            Write-MigrationLog -Message ("No -TenantId was given; this run acts on tenant $tenantId$upnSuffix. " +
                'Pass -TenantId to guard against a cached session.') -Level WARNING
        }

        return [pscustomobject]@{
            Matches          = $false
            ExpectedTenantId = ''
            Connected        = $connected
            Reason           = 'No tenant was specified'
        }
    }

    $expectedTenantId = Resolve-MigrationTenantId -Tenant $ExpectedTenantId

    foreach ($key in $services.Keys) {
        $tenantId = $connected[$key]
        if ($tenantId -and ($tenantId -ne $expectedTenantId)) {
            $label = $services[$key].Label
            throw ("${Purpose}: $label is connected to tenant $tenantId but $expectedTenantId was requested. " +
                'Sign in with an account in the expected tenant and re-run.')
        }
    }

    return [pscustomobject]@{
        Matches          = $true
        ExpectedTenantId = $expectedTenantId
        Connected        = $connected
        Reason           = ''
    }
}
