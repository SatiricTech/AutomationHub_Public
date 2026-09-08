function Format-MigrationE164 {
    <#
    .SYNOPSIS
        Normalises a phone number to E.164, preserving any extension.

    .DESCRIPTION
        Source inventories and operator spreadsheets present numbers in every shape a
        human can type. Teams accepts only E.164, so 'tel:' prefixes, spaces, dashes,
        dots and brackets are stripped and a leading '+' is added. Anything that is not
        digits after cleaning returns $null rather than a guess - a malformed number
        must fail the row, not be silently assigned to the wrong person.

    .PARAMETER Value
        The raw phone number.

    .EXAMPLE
        Format-MigrationE164 -Value 'tel:(555) 123-4567;ext=88'

        Returns '+5551234567;ext=88'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $number = $Value.Trim() -replace '^(?i)tel:', ''
    $extension = $null
    if ($number -match '^(?<num>[^;]+);(?i)ext=(?<ext>.+)$') {
        $number = $Matches['num']
        $extension = $Matches['ext'].Trim()
    }

    $number = $number -replace '[\s\-\.\(\)]', ''
    if ($number -match '^\+?\d+$') {
        if (-not $number.StartsWith('+')) { $number = "+$number" }
    }
    else {
        return $null
    }

    if ($extension) { return "$number;ext=$extension" }
    return $number
}
