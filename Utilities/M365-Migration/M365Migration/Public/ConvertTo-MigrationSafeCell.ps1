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

    .PARAMETER Value
        The cell value to check, of any type.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value '=HYPERLINK("http://evil")'

        Returns "'=HYPERLINK(""http://evil"")" - safe to write to CSV or a workbook cell.

    .EXAMPLE
        ConvertTo-MigrationSafeCell -Value 'John Smith'

        Returns 'John Smith' unchanged; it does not start with a formula-triggering character.

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

    # Formula-triggering leaders recognised by Excel/Calc/Sheets, plus the two whitespace
    # characters some readers also treat as a formula lead-in.
    if ($Value -match '^[=+\-@\t\r]') {
        return "'$Value"
    }

    return $Value
}
