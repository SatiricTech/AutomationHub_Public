function New-MigrationPlanRow {
    <#
    .SYNOPSIS
        Returns an empty identity-plan row with every column in canonical order.

    .DESCRIPTION
        Building plan rows from a literal hashtable is how column drift starts: one
        script spells a column differently, Export-Csv writes a different header set, and
        the next phase cannot read the file. This is the only supported way to create a
        row, so every producer emits the same shape.

        All columns are empty strings rather than $null so that Export-Csv writes an
        empty cell rather than the string 'null' and so that a strict-mode read of any
        column succeeds.

    .EXAMPLE
        $row = New-MigrationPlanRow
        $row.SourceUserPrincipalName = 'john.smith@contoso.com'
        $row.PlanStatus = 'Planned'

        Creates and populates a plan row.

    .EXAMPLE
        $rows = 1..3 | ForEach-Object { New-MigrationPlanRow }

        Creates several blank rows for a hand-built plan.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only; nothing is written to disk or to a tenant.')]
    [OutputType([pscustomobject])]
    param()

    $row = [ordered]@{}
    foreach ($column in $script:MigrationPlanColumns) { $row[$column] = '' }
    return [pscustomobject]$row
}
