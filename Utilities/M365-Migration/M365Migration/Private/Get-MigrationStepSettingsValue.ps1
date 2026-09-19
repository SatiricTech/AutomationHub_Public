function Get-MigrationStepSettingsValue {
    <#
    .SYNOPSIS
        Reads the settings value a step should be given, by its dotted schema key.

    .DESCRIPTION
        Every settings read on the way to a command line comes through here: the catalogue's
        Bind map names a key directly, the Settings:<Key> resolver names one through the
        catalogue, and the gates read the release domain. They have to agree on what a value
        is, so the rules live here rather than at each call site.

        What counts as "not configured": a blank or whitespace string, an empty map, an empty
        list. Those answer with $null, so an unset domain or an unset SKU map never reaches a
        command line as -SmtpDomain ''. A boolean is always a value, $false included - a
        settings file that says "do not include collisions" is saying something, and the step
        has to be told.

        Blank-key fallbacks. One key in the schema is documented as "blank means the same as
        this other key", and because a blank value is skipped rather than passed, that would
        otherwise leave the parameter unset instead of defaulted. Domains.Release is the vanity
        domain released from the SOURCE tenant and Domains.Target is the one identities land on
        in the destination; they are the same string only when the domain moves with the users,
        so Release exists, is allowed to be blank, and falls back to Target here
        (Docs/Workbench-Design.md, section 4). The effective release domain is what the
        domain-release step is given and what its typed confirmation asks the operator to type,
        and both read it through this one rule.

        A key the schema types as Path is made absolute against the workspace when it is stored
        relative, which is how the settings file stores anything inside the workspace
        (Docs/Workbench-Design.md, section 3). The schema is the authority on which keys those
        are - a name ending in 'Path' is a hint, not a contract - so the typed key list is read
        from it and memoised for the session.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace; its Settings may be $null.

    .PARAMETER Key
        The dotted settings key, for example 'Destination.TenantId'.

    .EXAMPLE
        Get-MigrationStepSettingsValue -Workspace $workspace -Key 'Domains.Target'

        Returns the target domain, or $null when the settings file does not name one.

    .EXAMPLE
        Get-MigrationStepSettingsValue -Workspace $workspace -Key 'Domains.Release'

        Returns the domain to release from the source tenant, falling back to Domains.Target
        when the settings file leaves Release blank.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key
    )

    # Documented "blank means the same as" relationships, settings key -> the key that answers
    # in its place. Kept as a table so the next one is a line rather than another branch.
    $fallbacks = @{ 'Domains.Release' = 'Domains.Target' }

    $value = Get-MigrationSettingsLeaf -Workspace $Workspace -Key $Key
    if ($null -eq $value -and $fallbacks.ContainsKey($Key)) {
        $value = Get-MigrationSettingsLeaf -Workspace $Workspace -Key $fallbacks[$Key]
        $Key = $fallbacks[$Key]
    }
    if ($null -eq $value) { return $null }

    if ($value -is [string] -and -not [System.IO.Path]::IsPathRooted($value)) {
        if ($null -eq $script:MigrationSettingsPathKeys) {
            $script:MigrationSettingsPathKeys = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@(Get-MigrationSettingsSchema | Where-Object { $_.Type -eq 'Path' } |
                        ForEach-Object { $_.Key }),
                [System.StringComparer]::OrdinalIgnoreCase)
        }
        if ($script:MigrationSettingsPathKeys.Contains($Key)) {
            return (Join-Path $Workspace.Path $value)
        }
    }

    return $value
}
