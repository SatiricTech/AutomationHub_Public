function ConvertTo-MigrationGigabyte {
    <#
    .SYNOPSIS
        Converts an Exchange size or raw byte count to GB, rounded to two decimals.

    .DESCRIPTION
        Mailbox and archive sizes are reported in GB because that is the unit a migration
        is planned in - throughput, licence tiers and cutover windows are all quoted that
        way. Two decimals keeps a 40 MB mailbox distinguishable from an empty one.

        Returns $null when the size cannot be parsed, so an unknown size stays visibly
        unknown in the report rather than becoming a plausible-looking 0.

    .PARAMETER Size
        A byte count, or an Exchange ByteQuantifiedSize value.

    .EXAMPLE
        ConvertTo-MigrationGigabyte -Size '1.5 GB (1,610,612,736 bytes)'

        Returns 1.5.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[System.Double]])]
    param(
        [AllowNull()]
        $Size
    )

    $bytes = ConvertTo-MigrationByteCount -Size $Size
    if ($null -eq $bytes) { return $null }

    return [math]::Round(($bytes / 1GB), 2)
}
