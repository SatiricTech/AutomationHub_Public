function Split-MigrationTeamsLineUri {
    <#
    .SYNOPSIS
        Splits a Teams LineUri into its number and extension parts.

    .DESCRIPTION
        A LineUri such as 'tel:+15551234567;ext=123' carries two facts that the
        migration plan tracks separately, because a ported number keeps its E.164 form
        while the extension is often re-issued in the destination tenant.

    .PARAMETER LineUri
        The LineUri value. Blank input returns an object with both members null.

    .EXAMPLE
        Split-MigrationTeamsLineUri -LineUri 'tel:+15551234567;ext=123'

        Returns Number '+15551234567' and Extension '123'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LineUri
    )

    if ([string]::IsNullOrWhiteSpace($LineUri)) {
        return [pscustomobject]@{ Number = $null; Extension = $null }
    }

    $value = $LineUri.Trim() -replace '^(?i)tel:', ''
    $extension = $null
    if ($value -match '^(?<num>[^;]+);(?i)ext=(?<ext>.+)$') {
        $value = $Matches['num']
        $extension = $Matches['ext'].Trim()
    }

    return [pscustomobject]@{ Number = $value; Extension = $extension }
}
