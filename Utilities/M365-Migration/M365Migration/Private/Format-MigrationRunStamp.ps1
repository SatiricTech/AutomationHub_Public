function Format-MigrationRunStamp {
    <#
    .SYNOPSIS
        Formats a moment the way every workbench view shows one.

    .DESCRIPTION
        One format, '18 Sep 10:31', used by the phase view and the results view alike, so two
        readings of the same run cannot look like two runs. Invariant culture, because a
        migration's screenshots and its notes travel between machines with different locales
        and 'Sep' has to stay 'Sep'. Anything that is not a date at all - a ledger line that
        lost its Started field - renders as an empty string rather than as today.

    .PARAMETER Value
        The moment, or anything else.

    .EXAMPLE
        Format-MigrationRunStamp -Value ([datetime]'2026-09-18T10:31:00')

        Returns '18 Sep 10:31'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Value
    )

    if ($Value -is [datetime]) {
        return $Value.ToString('dd MMM HH:mm', [cultureinfo]::InvariantCulture)
    }

    $parsed = [datetime]::MinValue
    if ($Value -is [string] -and [datetime]::TryParse($Value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed.ToString('dd MMM HH:mm', [cultureinfo]::InvariantCulture)
    }

    return ''
}
