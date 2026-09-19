function Get-MigrationCatalogValue {
    <#
    .SYNOPSIS
        Reads one step-catalogue key, letting an instance override its script's entry.

    .DESCRIPTION
        Every value in StepCatalog.psd1 can be stated once on the script's entry and overridden
        on one of its instances - the readiness entry says Phase 'Prepare' and its post-cutover
        instance says 'Cutover'. That three-way lookup (instance, then entry, then a default)
        appears once per catalogue key in New-MigrationStepObject, which is twenty-odd times,
        so it lives here rather than being spelled out each time.

        ContainsKey is used rather than a property read because an absent key and a key whose
        value is $null or $false mean different things: an instance that sets Confirm = $false
        must override an entry that sets it to $true, which a null test could not tell from
        "the instance says nothing".

    .PARAMETER Entry
        The script's catalogue entry.

    .PARAMETER Instance
        The instance's definition, or $null when reading the bare script entry.

    .PARAMETER Key
        The catalogue key to read.

    .PARAMETER Default
        Returned when neither the instance nor the entry carries the key.

    .EXAMPLE
        Get-MigrationCatalogValue -Entry $entry -Instance $instance -Key 'Phase' -Default 'Discover'

        Returns the instance's Phase, else the script's, else 'Discover'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Entry,

        [AllowNull()]
        [hashtable]$Instance,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [AllowNull()]
        $Default = $null
    )

    if ($null -ne $Instance -and $Instance.ContainsKey($Key)) { return $Instance[$Key] }
    if ($Entry.ContainsKey($Key)) { return $Entry[$Key] }
    return $Default
}
