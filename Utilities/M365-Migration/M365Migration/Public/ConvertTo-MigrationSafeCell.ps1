function ConvertTo-MigrationSafeCell {
    <#
    .SYNOPSIS
        Neutralises a value that a spreadsheet application would read as a formula.

    .DESCRIPTION
        Excel, LibreOffice Calc and Google Sheets treat a cell whose text starts with
        =, +, - or @ as a formula to evaluate, not as data - the classic CSV injection
        vector. A tab or carriage return leading a cell can do the same in some readers.
        A migration source can hand this toolkit an Identity, display name or address
        that happens to start with one of those characters (an SMTP alias '=old@old.com'
        entered by a previous migration tool, say), and every exported CSV and workbook
        row passes through here before it is written so that opening the file never runs
        anything.

        Prepending a single leading apostrophe is the same defusing Excel itself performs
        when a user types a formula-looking value into a cell formatted as text: the
        apostrophe is dropped from what is displayed, and the rest of the value is shown
        and read back verbatim, so nothing is lost from the data.

        Only a string is inspected. Numbers, booleans, dates and $null already have no
        formula reading in a spreadsheet and pass through unchanged.

        A string that is phone-shaped - an optional leading + or -, then nothing but digits,
        spaces, parentheses, dots and hyphens, with an optional trailing ';ext=<digits>'
        extension - is left alone even though it may start with + or -. None of those
        characters can turn the cell into a formula or a DDE payload, and this shape is
        exactly what a directory stores in MobilePhone, BusinessPhone and FaxNumber:
        '+15551234567' (Format-MigrationE164), '+15551110000;ext=524'
        (Split-MigrationTeamsLineUri) and the formatted forms a tenant actually holds,
        '+1 (425) 555-0100' among them. Those values are chain inputs, not just report
        cells - Get-MigrationInventory's Users tab becomes New-MigrationIdentityPlan's plan,
        which New-MigrationUsers POSTs to Graph - so a quote prefix would be provisioned
        into the destination tenant. A bare '-', the placeholder a source tenant writes for
        "no value", matches the same shape and is exempt for the same reason.

        Anything with a letter or another symbol after the sign - '+1555;ext=abc',
        "-1+cmd|' /C calc'!A0", '=1+1' - is not phone-shaped and is still prefixed.

    .PARAMETER Value
        The cell value to check, of any type.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value '=HYPERLINK("http://evil")'

        Returns "'=HYPERLINK(""http://evil"")" - safe to write to CSV or a workbook cell.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value 'John Smith'

        Returns 'John Smith' unchanged; it does not start with a formula-triggering character.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value '+1 (425) 555-0100'

        Returns '+1 (425) 555-0100' unchanged - a phone-shaped value, E.164 or formatted,
        is never a formula, and it has to reach the destination tenant verbatim.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value '+15551110000;ext=524'

        Returns '+15551110000;ext=524' unchanged - the extension-qualified line URI shape
        Split-MigrationTeamsLineUri produces is exempt too.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        ConvertFrom-MigrationSafeCell is the inverse, applied wherever the toolkit reads
        one of its own CSVs back in.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($Value -isnot [string]) { return $Value }

    # A phone-shaped value - digits, spaces, parentheses, dots and hyphens, with an optional
    # ';ext=<digits>' extension - can never be read as a formula or a DDE payload, so it is
    # exempt from the leader check below even though it may start with + or -. The bare '-'
    # placeholder matches this shape as well, which is intended: it is data, not a formula.
    if ($Value -match '^[+-]?[\d\s().\-]*(;ext=\d+)?$') { return $Value }

    # Formula-triggering leaders recognised by Excel/Calc/Sheets, plus the two whitespace
    # characters some readers also treat as a formula lead-in.
    if ($Value -match '^[=+\-@\t\r]') {
        return "'$Value"
    }

    return $Value
}
