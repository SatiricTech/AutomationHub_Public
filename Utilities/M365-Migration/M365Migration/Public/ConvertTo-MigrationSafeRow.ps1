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

        -ExcludeProperty exists for one narrow case: a value this toolkit generated rather
        than read from a tenant, where the exact characters matter. A generated credential
        is the example - New-MigrationRandomPassword draws from a pool containing '-', '=',
        '+' and '@', so roughly one password in seventeen starts with a character the
        sanitiser would quote-prefix. That prefix would put a password in the results file
        that the account does not actually have, which is worse than the injection risk it
        defends against: the value never came from a tenant, so it cannot carry one.

    .PARAMETER Row
        The row to sanitise. Any object exposing PSObject.Properties works, not just
        pscustomobject.

    .PARAMETER ExcludeProperty
        Names of properties to copy through untouched. Use only for values this toolkit
        generated itself; anything that came from a tenant must stay sanitised. Matching is
        case-insensitive, and a name that the row does not carry is simply ignored.

    .EXAMPLE
        $safeRows = $rows | ForEach-Object { ConvertTo-MigrationSafeRow -Row $_ }

        Sanitises every row in a collection before it is exported.

    .EXAMPLE
        ConvertTo-MigrationSafeRow -Row ([pscustomobject]@{ Identity = '=x'; Count = 1 })

        Returns a row whose Identity is "'=x" and whose Count is left alone.

    .EXAMPLE
        ConvertTo-MigrationSafeRow -Row $row -ExcludeProperty 'GeneratedPassword'

        Sanitises every column except the minted credential, which is written exactly as it
        was generated so it still matches the account.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Row,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$ExcludeProperty
    )

    $exempt = @($ExcludeProperty | Where-Object { $_ })

    $safe = [ordered]@{}
    foreach ($property in $Row.PSObject.Properties) {
        $safe[$property.Name] = if ($exempt -contains $property.Name) {
            $property.Value
        }
        else {
            ConvertTo-MigrationSafeCell -Value $property.Value
        }
    }

    return [pscustomobject]$safe
}
