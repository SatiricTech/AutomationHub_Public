function Invoke-MigrationGraphRequest {
    <#
    .SYNOPSIS
        Calls Microsoft Graph with throttling-aware retry and automatic paging.

    .DESCRIPTION
        The single Graph call path for the toolkit. Two behaviours make it worth the
        wrapper:

        Retry. A migration enumerates thousands of objects and will be throttled. On 429,
        503 or 504 the request is retried after the delay Graph asked for in its
        Retry-After header; when no hint is supplied it backs off exponentially (2, 4, 8
        seconds and so on) capped at 60. Any other failure is thrown immediately, because
        retrying a 403 just delays the error the operator needs to see.

        Paging. Graph returns collections a page at a time. With -All the '@odata.nextLink'
        chain is followed to exhaustion and the pages are concatenated, so callers never
        silently process the first 100 of 4,000 users.

        A collection response returns its 'value' array; a single-object response returns
        the object.

    .PARAMETER Method
        GET, POST, PUT, PATCH or DELETE.

    .PARAMETER Uri
        The Graph URI, absolute or relative (for example '/v1.0/users').

    .PARAMETER Body
        The request body. Converted to JSON automatically.

    .PARAMETER Headers
        Extra request headers, merged into every call the wrapper makes - including each
        page of a -All walk, because Graph applies the header per request rather than per
        query. Two headers earn their keep here: 'ConsistencyLevel: eventual' (required
        by advanced $filter/$count queries) and 'Prefer: include-unknown-enum-members'
        (without which newer enum values are dropped from the response rather than
        returned as-is).

    .PARAMETER All
        Follows the paging links and returns every page.

    .PARAMETER MaxRetry
        How many attempts to make before giving up. Defaults to 5.

    .EXAMPLE
        $users = Invoke-MigrationGraphRequest -Method GET -Uri '/v1.0/users?$select=id,userPrincipalName' -All

        Returns every user, following the paging links.

    .EXAMPLE
        Invoke-MigrationGraphRequest -Method PATCH -Uri "/v1.0/users/$id" -Body @{ usageLocation = 'US' }

        Updates a single user.

    .EXAMPLE
        Invoke-MigrationGraphRequest -Method GET -All `
            -Uri '/v1.0/users?$count=true&$filter=endsWith(mail,''@contoso.com'')' `
            -Headers @{ ConsistencyLevel = 'eventual' }

        Runs an advanced query, which Graph rejects without the ConsistencyLevel header.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        Requires an active Graph session; call Connect-MigrationGraph first.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Method, Body, Headers and MaxRetry are consumed inside the $invokeOnce scriptblock, which the analyzer does not follow. The scriptblock exists so the retry loop can be re-entered for each page.')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [AllowNull()]
        $Body,

        [AllowNull()]
        [hashtable]$Headers,

        [switch]$All,

        [ValidateRange(1, 20)]
        [int]$MaxRetry = 5
    )

    $invokeOnce = {
        param([string]$RequestUri)

        $attempt = 0
        while ($true) {
            $attempt++
            try {
                $parameters = @{ Method = $Method; Uri = $RequestUri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
                if ($null -ne $Headers -and $Headers.Count -gt 0) {
                    # Cloned per attempt so a retry cannot inherit anything Invoke-MgGraphRequest
                    # may have added to the hashtable the caller handed us.
                    $parameters['Headers'] = @{} + $Headers
                }
                if ($null -ne $Body) {
                    $parameters['Body'] = ($Body | ConvertTo-Json -Depth 10)
                    $parameters['ContentType'] = 'application/json'
                }
                return Invoke-MgGraphRequest @parameters
            }
            catch {
                $status = Get-MigrationGraphErrorStatusCode -ErrorRecord $_
                if ($status -notin @(429, 503, 504) -or $attempt -ge $MaxRetry) { throw }

                $delay = Get-MigrationGraphRetryAfterSecond -ErrorRecord $_
                if ($delay -le 0) {
                    $delay = [int][Math]::Min([Math]::Pow(2, $attempt), 60)
                }
                Write-MigrationLog -Message "Graph returned $status - waiting $delay second(s) before retry $attempt of $MaxRetry." -Level WARNING
                Start-Sleep -Seconds $delay
            }
        }
    }

    $response = & $invokeOnce $Uri

    $hasValue = $null -ne $response -and $response.PSObject.Properties['value']
    if (-not $hasValue) { return $response }

    $items = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $response.value) { $items.AddRange(@($response.value)) }

    if ($All) {
        $next = $null
        if ($response.PSObject.Properties['@odata.nextLink']) { $next = [string]$response.'@odata.nextLink' }

        while (-not [string]::IsNullOrWhiteSpace($next)) {
            $page = & $invokeOnce $next
            if ($null -ne $page -and $page.PSObject.Properties['value'] -and $null -ne $page.value) {
                $items.AddRange(@($page.value))
            }
            $next = $null
            if ($null -ne $page -and $page.PSObject.Properties['@odata.nextLink']) {
                $next = [string]$page.'@odata.nextLink'
            }
        }
    }

    return $items.ToArray()
}
