function Split-MigrationList {
    <#
    .SYNOPSIS
        Splits a delimited plan cell into a trimmed array of values.

    .DESCRIPTION
        Multi-value columns in the identity plan - aliases, licences, X500 addresses -
        are stored as a single semicolon-delimited cell so the file stays editable in
        Excel. This is the one reader for that format: it trims each entry and discards
        empty ones, so trailing delimiters and stray spaces from hand-editing do not
        become empty aliases downstream.

        An empty cell yields an empty array, never a single empty string.

    .PARAMETER Value
        The delimited cell contents.

    .PARAMETER Separator
        The delimiter. Defaults to ';'.

    .EXAMPLE
        Split-MigrationList -Value 'smtp:j.smith@contoso.com; smtp:js@contoso.com;'

        Returns the two addresses with the trailing delimiter ignored.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [ValidateNotNullOrEmpty()]
        [string]$Separator = ';'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return [string[]]@() }

    $items = $Value.Split($Separator) |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    # PowerShell unrolls a single-element result on return, so callers that need to count
    # or index the result wrap the call in @() - as Resolve-MigrationSkuMap does.
    return [string[]]@($items)
}
