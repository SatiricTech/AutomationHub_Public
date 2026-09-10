function Get-MigrationProperty {
    <#
    .SYNOPSIS
        Reads a property or key that may not exist, returning a default instead of throwing.

    .DESCRIPTION
        Graph omits properties that were not $select-ed, Exchange Online returns different
        property bags depending on which property sets were requested, and the module runs
        under Set-StrictMode -Version Latest, where a plain $object.Missing is a terminating
        error. Every read of a tenant object goes through here so a thin response cannot
        abort a run that was meant to record the gap and carry on.

        Three shapes are handled with one call: a PSCustomObject or any .NET object (read
        through its PSObject property bag, so ETS and note properties work), a hashtable,
        and any other IDictionary - Graph's own -OutputType Hashtable responses among them.
        Dictionary keys are matched case-insensitively when the dictionary itself is
        case-sensitive, because Graph capitalises JSON keys differently between versions.

        Values come back raw. An array stays an array, a boolean stays a boolean and a
        nested object stays an object - the caller decides what to stringify. That is the
        difference between this and Get-MigrationCsvValue, which is for operator CSVs and
        deliberately trims to string. Ordinary PowerShell output semantics apply on the way
        out, so wrap the call in @(...) when a collection is expected, exactly as every
        other list-returning function in this module is used.

        Only $null collapses to the default. An empty string, an empty array and $false are
        all real values that a caller may need to tell apart from 'absent'.

    .PARAMETER InputObject
        The object, hashtable or dictionary to read from. $null returns the default.

    .PARAMETER Name
        The property name or dictionary key.

    .PARAMETER Default
        Returned when the property is absent or null. Defaults to $null.

    .EXAMPLE
        Get-MigrationProperty -InputObject $graphUser -Name 'onPremisesSyncEnabled' -Default $false

        Returns $false rather than throwing when Graph did not return the property.

    .EXAMPLE
        Get-MigrationProperty -InputObject $mailbox -Name 'EmailAddresses' -Default @()

        Returns the address array intact, ready to pipe into Split-MigrationProxyAddress.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [AllowNull()]
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        # Keys are walked rather than indexed: the indexer returns $null for a missing key
        # on a Hashtable but throws on a generic Dictionary, and Contains() is an explicit
        # interface implementation PowerShell will not bind to. An exact-case pass runs
        # first so a dictionary holding both 'id' and 'Id' returns the one that was asked
        # for; the second pass is what makes Graph's shifting JSON capitalisation harmless.
        $keys = @($InputObject.Keys)

        foreach ($key in $keys) {
            if ($Name -ceq [string]$key) {
                return (Get-MigrationDictionaryValue -Dictionary $InputObject -Key $key -Default $Default)
            }
        }

        foreach ($key in $keys) {
            if ($Name -ieq [string]$key) {
                return (Get-MigrationDictionaryValue -Dictionary $InputObject -Key $key -Default $Default)
            }
        }

        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property) { return $Default }

    # A property that exists but cannot be read (a Graph SDK model backed by a failed
    # deserialisation, say) is treated as absent rather than allowed to kill the run.
    try { $value = $property.Value }
    catch { return $Default }

    if ($null -eq $value) { return $Default }
    return $value
}
