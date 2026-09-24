function Merge-MigrationStepMap {
    <#
    .SYNOPSIS
        Copies a step-catalogue map, letting an instance's entries win.

    .DESCRIPTION
        The Fixed, Resolve and Bind maps are stated on a script's catalogue entry and refined
        on its instances. Copying rather than mutating matters twice over: the imported
        catalogue is cached for the session, so a caller that edited a step's Fixed map in
        place would change every later step built from the same entry; and the three maps
        merge by different rules, which is easier to get right in one place than at each call.

        Fixed and Resolve are keyed by parameter name, so a later entry for the same parameter
        simply replaces the earlier one. Bind is keyed the other way round - settings key ->
        parameter name - so replacing by key would leave both bindings standing when an
        instance rebinds a parameter to a different settings key. The inventory's
        destination-side instances do exactly that: they bind Destination.TenantId to -TenantId
        where the script's entry binds Source.TenantId. -ByValue drops any base entry that
        targets a parameter the override also targets, so one parameter never ends up with two
        sources.

    .PARAMETER Base
        The script entry's map. $null is treated as empty.

    .PARAMETER Override
        The instance's map. $null is treated as empty.

    .PARAMETER ByValue
        Match the maps on their values (the target parameter) rather than their keys.

    .EXAMPLE
        Merge-MigrationStepMap -Base $entry.Bind -Override $instance.Bind -ByValue

        Returns the script's bindings with the instance's applied, one source per parameter.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [hashtable]$Base,

        [AllowNull()]
        [hashtable]$Override,

        [switch]$ByValue
    )

    $merged = @{}
    if ($null -ne $Base) {
        foreach ($key in @($Base.Keys)) { $merged[$key] = $Base[$key] }
    }

    if ($null -eq $Override -or $Override.Count -eq 0) { return $merged }

    if ($ByValue) {
        $targets = @($Override.Values)
        # @($merged.Keys) snapshots the keys, so the collection is not modified while enumerated.
        foreach ($key in @($merged.Keys)) {
            if ($targets -contains $merged[$key]) { $merged.Remove($key) }
        }
    }

    foreach ($key in @($Override.Keys)) { $merged[$key] = $Override[$key] }
    return $merged
}
