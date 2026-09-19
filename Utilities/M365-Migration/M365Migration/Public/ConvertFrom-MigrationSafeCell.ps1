function ConvertFrom-MigrationSafeCell {
    <#
    .SYNOPSIS
        Undoes ConvertTo-MigrationSafeCell's formula-defusing apostrophe.

    .DESCRIPTION
        The exact inverse of ConvertTo-MigrationSafeCell, applied wherever this toolkit
        reads one of its own CSVs back in. Every report and results file is written
        through the sanitiser, so a cell that started with =, +, -, @, a tab or a
        carriage return is on disk with a leading apostrophe. That apostrophe is a
        spreadsheet convention, not part of the data: Excel hides it, but Import-Csv
        hands it back, and a toolkit script that then writes the value to a destination
        tenant would provision an apostrophe the source tenant never had.

        That matters because several of these files are chain inputs, not just reports:
        the Users tab Get-MigrationInventory writes is what New-MigrationIdentityPlan
        reads, and the plan is what New-MigrationUsers POSTs to Graph.

        A leading apostrophe is removed only when the character after it is one of the
        sanitiser's own leaders (=, +, -, @, tab, carriage return). Any other apostrophe
        is data and is left alone, so the surname "'Brien" survives a read unchanged.

        Only a string is inspected; every other type passes through.

    .PARAMETER Value
        The cell value read back from a CSV, of any type.

    .EXAMPLE
        ConvertFrom-MigrationSafeCell -Value "'=SUM(A1)"

        Returns '=SUM(A1)' - the value as it was before the sanitiser defused it.

    .EXAMPLE
        ConvertFrom-MigrationSafeCell -Value "'Brien"

        Returns "'Brien" unchanged: the character after the apostrophe is a letter, so the
        apostrophe is part of the name rather than a spreadsheet escape.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).

        One value cannot be recovered, by construction: a source value that genuinely
        began with an apostrophe followed by a formula leader - "'=x" typed into the
        source tenant - is written to disk unchanged (the sanitiser leaves it alone,
        because an apostrophe is not a formula leader) and is read back here as '=x'.
        There is nothing in the file to tell that case apart from a defused '=x', and no
        escape hatch can be added without changing what a spreadsheet displays, which is
        the whole point of the sanitiser. The trade is deliberate: the unrecoverable case
        is a value no directory has ever been observed to hold, while phone numbers,
        hyphen placeholders and formula-looking aliases - the cases this inverse fixes -
        are everyday inventory data.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($Value -isnot [string]) { return $Value }
    if ($Value.Length -lt 2 -or $Value[0] -ne "'") { return $Value }

    # The same leader set ConvertTo-MigrationSafeCell prefixes, and only that set: an
    # apostrophe in front of anything else was never added by this toolkit.
    if ($Value.Substring(1, 1) -match '^[=+\-@\t\r]$') {
        return $Value.Substring(1)
    }

    return $Value
}
