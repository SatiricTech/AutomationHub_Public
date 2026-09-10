function Get-MigrationGraphRetryAfterSecond {
    <#
    .SYNOPSIS
        Reads the retry delay Graph asked for, in seconds.

    .DESCRIPTION
        Throttled Graph responses carry a Retry-After header, and honouring it is the
        difference between backing off once and being throttled progressively harder.
        The header is not always where the SDK puts it, and the employee-learning API
        expresses its hint in the error body in MINUTES instead, so both forms are read
        here. Returns 0 when no hint is available, leaving the caller to fall back to
        exponential backoff.

    .PARAMETER ErrorRecord
        The ErrorRecord from a failed Graph request.

    .EXAMPLE
        $wait = Get-MigrationGraphRetryAfterSecond -ErrorRecord $_

        Returns the server-requested delay, or 0 when the response carried none.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        $ErrorRecord
    )

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        $headers = $response.Value.PSObject.Properties['Headers']
        if ($headers -and $headers.Value) {
            $raw = $null
            $collection = $headers.Value
            try {
                if ($collection -is [System.Collections.IDictionary]) {
                    foreach ($key in $collection.Keys) {
                        if ([string]$key -ieq 'Retry-After') { $raw = $collection[$key]; break }
                    }
                }
                elseif ($collection.PSObject.Methods['GetValues']) {
                    $raw = @($collection.GetValues('Retry-After'))[0]
                }
                elseif ($collection.PSObject.Properties['RetryAfter']) {
                    $raw = $collection.RetryAfter
                }
            }
            catch {
                $raw = $null
            }

            if ($raw) {
                $seconds = 0
                if ([int]::TryParse(([string]@($raw)[0]).Trim(), [ref]$seconds) -and $seconds -gt 0) {
                    return $seconds
                }
            }
        }
    }

    # ErrorDetails is null on many SDK failures, and strict mode makes a blind property
    # read on it fatal - so it is checked before being dereferenced.
    $detail = ''
    if ($ErrorRecord.ErrorDetails) { $detail = [string]$ErrorRecord.ErrorDetails.Message }
    if ($detail -match 'Retry after (\d+) minute') { return ([int]$Matches[1] * 60) }

    return 0
}
