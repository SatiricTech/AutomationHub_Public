function ConvertTo-MigrationSafeRow {
    <#
    .SYNOPSIS
        Runs every string property of a row through ConvertTo-MigrationSafeCell.

    .DESCRIPTION
        The row-level counterpart to ConvertTo-MigrationSafeCell: every CSV and workbook
        export in this toolkit writes a collection of pscustomobject rows, so this is the
        one call site that needs to touch each of them before Export-Csv or Export-Excel
        sees the data. Property order is preserved, because the order the caller built the
        row in is the column order the file is written in.

        A new pscustomobject is returned; the row passed in is not modified.

    .PARAMETER Row
        The row to sanitise. Any object exposing PSObject.Properties works, not just
        pscustomobject.

    .EXAMPLE
        $safeRows = $rows | ForEach-Object { ConvertTo-MigrationSafeRow -Row $_ }

        Sanitises every row in a collection before it is exported.

    .EXAMPLE
        ConvertTo-MigrationSafeRow -Row ([pscustomobject]@{ Identity = '=x'; Count = 1 })

        Returns a row whose Identity is "'=x" and whose Count is left alone.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Row
    )

    $safe = [ordered]@{}
    foreach ($property in $Row.PSObject.Properties) {
        $safe[$property.Name] = ConvertTo-MigrationSafeCell -Value $property.Value
    }

    return [pscustomobject]$safe
}
