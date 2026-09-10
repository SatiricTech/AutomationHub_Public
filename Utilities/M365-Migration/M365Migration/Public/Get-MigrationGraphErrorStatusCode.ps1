function Get-MigrationGraphErrorStatusCode {
    <#
    .SYNOPSIS
        Extracts the HTTP status code from a failed Graph request.

    .DESCRIPTION
        Invoke-MgGraphRequest does not surface the response object consistently across
        authentication types, so three sources are consulted in order: the exception's
        Response property, the Graph error body's code string, and finally the raw
        exception text. Returns 0 when no status can be determined, which callers must
        treat as "not retryable".

    .PARAMETER ErrorRecord
        The ErrorRecord captured in the catch block.

    .EXAMPLE
        try { Invoke-MgGraphRequest -Method GET -Uri $uri }
        catch { $status = Get-MigrationGraphErrorStatusCode -ErrorRecord $_ }

        Maps a Graph failure to its HTTP status code.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        $ErrorRecord
    )

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        $status = $response.Value.PSObject.Properties['StatusCode']
        if ($status -and $status.Value) { return [int]$status.Value }
    }

    # ErrorDetails is null on many SDK failures, and strict mode makes a blind property
    # read on it fatal - so it is checked before being dereferenced.
    $detail = ''
    if ($ErrorRecord.ErrorDetails) { $detail = [string]$ErrorRecord.ErrorDetails.Message }
    if ($detail) {
        # A non-JSON body (or none at all) simply falls through to the message text.
        $code = [string]$(try { (ConvertFrom-Json $detail -ErrorAction Stop).error.code } catch { $null })
        switch -Regex ($code) {
            '^(notFound|ResourceNotFound|Request_ResourceNotFound)$' { return 404 }
            '^tooManyRequests$'                                      { return 429 }
            '^(serviceUnavailable|serviceNotAvailable)$'             { return 503 }
            '^(forbidden|accessDenied|Authorization_RequestDenied)$' { return 403 }
            '^badRequest$'                                           { return 400 }
            '^(unauthorized|InvalidAuthenticationToken)$'            { return 401 }
        }
    }

    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match 'HTTP/[\d.]+\s+(\d{3})' -or $message -match '\b([45]\d{2})\s*\(' -or
        $message -match '\b(40[0-9]|429|50[0-9])\b') {
        return [int]$Matches[1]
    }

    # SDK cmdlets (Get-MgUser -UserId on a missing object, for example) report a miss as
    # '[Request_ResourceNotFound] : Resource ... does not exist ...' with ErrorDetails null
    # and no numeric status anywhere in the text, so only the code name is left to match.
    if ($message -match '(?i)\bRequest_ResourceNotFound\b' -or $message -match '(?i)\bResourceNotFound\b') {
        return 404
    }

    return 0
}
