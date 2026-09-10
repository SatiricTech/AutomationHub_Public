function ConvertTo-MigrationODataString {
    <#
    .SYNOPSIS
        Escapes a value for safe use inside an OData string literal.

    .DESCRIPTION
        OData terminates a string literal at the first single quote, so a value read
        from a CSV can otherwise break out of a $filter and change its meaning - the
        OData equivalent of SQL injection. Doubling the quote is the escape the protocol
        defines. Every filter in the toolkit passes its values through here.

        The returned value does NOT include the surrounding quotes; the caller supplies
        those, so the escaping and the quoting stay visible together at the call site.

    .PARAMETER Value
        The raw value, typically a UPN or display name from operator-supplied input.

    .EXAMPLE
        $safe = ConvertTo-MigrationODataString -Value "O'Brien"
        Get-MgUser -Filter "displayName eq '$safe'"

        Produces the filter "displayName eq 'O''Brien'".

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($null -eq $Value) { return '' }
    return $Value.Replace("'", "''")
}
