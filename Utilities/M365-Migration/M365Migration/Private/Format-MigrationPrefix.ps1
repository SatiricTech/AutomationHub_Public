function Format-MigrationPrefix {
    <#
    .SYNOPSIS
        Normalises a run prefix into a filename-safe token.

    .DESCRIPTION
        The prefix names the client or run and is used both as a subfolder and as a
        filename lead-in, so anything that a filesystem would reject is replaced with
        a hyphen. An empty prefix is legal and returns an empty string, which callers
        read as "no prefix".

    .PARAMETER Value
        The raw prefix supplied by the operator.

    .EXAMPLE
        Format-MigrationPrefix -Value 'Contoso Wave 1'

        Returns 'Contoso-Wave-1'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $clean = $Value.Trim() -replace '[^\w\.\-]+', '-'
    return ($clean -replace '-{2,}', '-').Trim('-')
}
