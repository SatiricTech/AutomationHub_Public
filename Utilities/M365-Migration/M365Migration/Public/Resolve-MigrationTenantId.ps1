function Resolve-MigrationTenantId {
    <#
    .SYNOPSIS
        Resolves a tenant domain or GUID to its Entra ID tenant GUID.

    .DESCRIPTION
        Several toolkit scripts accept a tenant as either a domain
        (contoso.onmicrosoft.com) or a GUID, and Graph calls need the GUID form. A GUID
        input is normalised and returned without any network call. A domain is resolved
        through the tenant's OIDC discovery document, whose 'issuer' field embeds the
        tenant GUID as the first path segment.

        The discovery endpoint (login.microsoftonline.com/<tenant>/v2.0/.well-known/
        openid-configuration) is public and unauthenticated - reading it performs no
        sign-in and requires no credential.

    .PARAMETER Tenant
        A tenant domain (contoso.onmicrosoft.com) or a GUID, with or without braces.

    .EXAMPLE
        Resolve-MigrationTenantId -Tenant 'contoso.onmicrosoft.com'

        Returns the tenant's GUID by reading its OIDC discovery document.

    .EXAMPLE
        Resolve-MigrationTenantId -Tenant '{a1b2c3d4-0000-0000-0000-000000000001}'

        Returns 'a1b2c3d4-0000-0000-0000-000000000001' without calling the network.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Tenant
    )

    $parsedGuid = [guid]::Empty
    if ([guid]::TryParse($Tenant.Trim('{', '}'), [ref]$parsedGuid)) {
        return $parsedGuid.ToString().ToLowerInvariant()
    }

    $domain = $Tenant.Trim()
    $uri = "https://login.microsoftonline.com/$domain/v2.0/.well-known/openid-configuration"
    try {
        $discovery = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15 -ErrorAction Stop
        # The issuer is 'https://login.microsoftonline.com/<guid>/v2.0' - the GUID is its first path segment.
        if ($discovery.issuer -notmatch '^https://login\.microsoftonline\.com/([0-9a-fA-F-]{36})/') {
            throw "the discovery document's issuer '$($discovery.issuer)' did not contain a tenant GUID"
        }
        return ([guid]$Matches[1]).ToString().ToLowerInvariant()
    }
    catch {
        throw "Tenant '$Tenant' could not be resolved to a tenant ID: $($_.Exception.Message)"
    }
}
