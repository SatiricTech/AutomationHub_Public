function Get-MigrationDictionaryValue {
    <#
    .SYNOPSIS
        Reads one key from a dictionary, collapsing a null value to the default.

    .DESCRIPTION
        Exists only to keep Get-MigrationProperty's two key-matching passes from repeating
        the same four lines. Separated so a change to what counts as 'absent' is made once.

    .PARAMETER Dictionary
        The dictionary to read.

    .PARAMETER Key
        The key, already matched against the caller's requested name.

    .PARAMETER Default
        Returned when the stored value is null.

    .EXAMPLE
        Get-MigrationDictionaryValue -Dictionary $response -Key 'value' -Default @()

        Returns the stored array, or an empty array when the key holds $null.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Collections.IDictionary]$Dictionary,

        [Parameter(Mandatory)]
        [AllowNull()]
        $Key,

        [AllowNull()]
        $Default = $null
    )

    $value = $Dictionary[$Key]
    if ($null -eq $value) { return $Default }
    return $value
}
