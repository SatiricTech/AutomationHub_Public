function Get-MigrationSkuFriendlyName {
    <#
    .SYNOPSIS
        Translates a licence SKU part number into a human-readable product name.

    .DESCRIPTION
        Looks the part number up in the module's SKU name table. An unmapped part
        number is returned unchanged so that a gap in the table degrades to a slightly
        cryptic report rather than a blank licence column.

    .PARAMETER SkuPartNumber
        The Graph skuPartNumber value, for example 'SPE_E3'.

    .EXAMPLE
        Get-MigrationSkuFriendlyName -SkuPartNumber 'SPE_E3'

        Returns 'Microsoft 365 E3'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SkuPartNumber
    )

    if ([string]::IsNullOrWhiteSpace($SkuPartNumber)) { return '' }
    if ($script:SkuFriendlyNames.ContainsKey($SkuPartNumber)) {
        return $script:SkuFriendlyNames[$SkuPartNumber]
    }
    return $SkuPartNumber
}
