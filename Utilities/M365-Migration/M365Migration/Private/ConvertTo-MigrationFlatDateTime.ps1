function ConvertTo-MigrationFlatDateTime {
    <#
    .SYNOPSIS
        Normalises a timestamp to ISO 8601 UTC, 'yyyy-MM-ddTHH:mm:ssZ'.

    .DESCRIPTION
        Graph returns timestamps in several shapes - some with a trailing 'Z', some with an
        offset, some with neither - and Excel will happily reinterpret each of them
        differently when the CSV is opened. One flat UTC form means a report can be sorted
        as text and compared between runs.

        A value with no offset is read as UTC rather than local time, which is what Graph
        means by it. Anything that will not parse is passed through unchanged: an
        unrecognised timestamp is still evidence, and silently blanking it would lose it.

    .PARAMETER Value
        The timestamp, as a string, DateTime or DateTimeOffset. Null or blank returns $null.

    .EXAMPLE
        ConvertTo-MigrationFlatDateTime -Value '2026-09-08T14:30:00.1234567'

        Returns '2026-09-08T14:30:00Z'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }

    $parsed = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    return [string]$Value
}
