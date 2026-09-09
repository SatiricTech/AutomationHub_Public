function ConvertTo-MigrationByteCount {
    <#
    .SYNOPSIS
        Parses an Exchange ByteQuantifiedSize into an exact byte count.

    .DESCRIPTION
        Exchange sizes render as '1.5 GB (1,610,612,736 bytes)'. The parenthesised figure
        is the exact one and the only one worth keeping - the leading value is rounded and
        formatted for the caller's locale, so parsing it would give a different answer on
        a German-language session. When the string carries no byte count the object's own
        ToBytes() is tried before giving up, which covers the typed value Exchange returns
        over a live remoting session as opposed to the string a CSV round-trip leaves.

        Returns $null rather than 0 when nothing can be parsed: an unknown size and an
        empty mailbox are different facts and a report must not conflate them.

    .PARAMETER Size
        The size value from Exchange, as an object or a string. Also accepts a bare digit
        string, which is what a re-imported CSV column holds.

    .EXAMPLE
        ConvertTo-MigrationByteCount -Size '1.5 GB (1,610,612,736 bytes)'

        Returns 1610612736.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[System.Int64]])]
    param(
        [AllowNull()]
        $Size
    )

    if ($null -eq $Size) { return $null }

    $text = [string]$Size
    if ($text -match '\(([\d.,\s]+)\s*bytes\)') {
        $digits = $Matches[1] -replace '[^\d]', ''
        if ($digits) { return [int64]$digits }
    }

    if ($Size -isnot [string] -and $Size.PSObject.Methods['ToBytes']) {
        try { return [int64]$Size.ToBytes() } catch { return $null }
    }

    if ($text -match '^\d+$') { return [int64]$text }

    return $null
}
