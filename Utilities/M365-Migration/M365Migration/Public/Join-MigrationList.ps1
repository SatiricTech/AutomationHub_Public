function Join-MigrationList {
    <#
    .SYNOPSIS
        Joins values into the plan's delimited cell format.

    .DESCRIPTION
        The inverse of Split-MigrationList. Null and empty entries are dropped and each
        value is trimmed, so a round trip through Split and Join is stable - which
        matters because Save-MigrationPlan rewrites the plan in place on every pass and
        a drifting delimiter would show up as a spurious diff.

    .PARAMETER Values
        The values to join.

    .PARAMETER Separator
        The delimiter. Defaults to ';'.

    .EXAMPLE
        Join-MigrationList -Values @('SPE_E3', 'MCOEV')

        Returns 'SPE_E3;MCOEV'.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Values,

        [ValidateNotNullOrEmpty()]
        [string]$Separator = ';'
    )

    if ($null -eq $Values -or $Values.Count -eq 0) { return '' }

    $clean = $Values |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }

    return (@($clean) -join $Separator)
}
