function Get-MigrationCsvValue {
    <#
    .SYNOPSIS
        Reads a property from a CSV row, tolerating missing or blank values.

    .DESCRIPTION
        The module runs under Set-StrictMode -Version Latest, where reading a property
        that does not exist is a terminating error. Operator-maintained CSVs regularly
        omit optional columns, so every read of a CSV row goes through here: an absent
        property, a null and a whitespace-only cell all collapse to the same default.

        Values are trimmed, because a trailing space in a UPN column produces a Graph
        lookup failure that is almost impossible to spot by eye.

    .PARAMETER Row
        The row object, typically from Import-MigrationCsv.

    .PARAMETER Name
        The property name to read.

    .PARAMETER Default
        What to return when the property is missing or blank. Defaults to $null.

    .EXAMPLE
        Get-MigrationCsvValue -Row $row -Name 'MiddleName'

        Returns the middle name, or $null when the column is absent or empty.

    .EXAMPLE
        Get-MigrationCsvValue -Row $row -Name 'Wave' -Default '1'

        Returns the wave, defaulting to the first wave when unspecified.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Row,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        $Default = $null
    )

    if ($null -eq $Row) { return $Default }
    if (-not $Row.PSObject.Properties[$Name]) { return $Default }

    $value = $Row.PSObject.Properties[$Name].Value
    if ($null -eq $value) { return $Default }

    $text = ([string]$value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    return $text
}
