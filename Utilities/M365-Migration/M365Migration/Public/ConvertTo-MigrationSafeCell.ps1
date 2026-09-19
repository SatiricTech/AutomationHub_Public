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

        A string that is a pure signed number - optional leading + or -, digits, an optional
        decimal part, and an optional trailing ';ext=<digits>' extension, nothing else - is
        left alone even though it starts with + or -. A spreadsheet reads a bare number as a
        number, never as a formula or a DDE payload, and this toolkit round-trips E.164
        phone numbers in both plain (Format-MigrationE164: '+<digits>', no spaces or
        separators) and extension-qualified (Split-MigrationTeamsLineUri:
        '+<digits>;ext=<digits>') form out of one script's CSV and into another's
        -PhoneNumber parameter: quoting them here would corrupt that round trip for no
        security benefit. Anything with so much as a space, a non-digit extension, or any
        other character after the sign - '+1 555 123', '+1555;ext=abc',
        "-1+cmd|' /C calc'!A0" - is not a bare number and is still prefixed.

    .PARAMETER Value
        The cell value to check, of any type.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value '=HYPERLINK("http://evil")'

        Returns "'=HYPERLINK(""http://evil"")" - safe to write to CSV or a workbook cell.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value 'John Smith'

        Returns 'John Smith' unchanged; it does not start with a formula-triggering character.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value '+15551234567'

        Returns '+15551234567' unchanged - a pure signed number, including an E.164 phone
        number, is never a formula.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value '+15551110000;ext=524'

        Returns '+15551110000;ext=524' unchanged - the extension-qualified line URI shape
        Split-MigrationTeamsLineUri produces is exempt too.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($Value -isnot [string]) { return $Value }

    # A bare signed number - an E.164 phone number among them, with or without a
    # ';ext=<digits>' extension - can never be read as a formula or a DDE payload, so it is
    # exempt from the leader check below even though it may start with + or -.
    if ($Value -match '^[+-]?\d+(\.\d+)?(;ext=\d+)?$') { return $Value }

    # Formula-triggering leaders recognised by Excel/Calc/Sheets, plus the two whitespace
    # characters some readers also treat as a formula lead-in.
    if ($Value -match '^[=+\-@\t\r]') {
        return "'$Value"
    }

    return $Value
}
