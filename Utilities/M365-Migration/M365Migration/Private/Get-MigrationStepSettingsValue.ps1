function Get-MigrationStepSettingsValue {
    <#
    .SYNOPSIS
        Reads one settings key by its dotted schema name, collapsing "not configured" to null.

    .DESCRIPTION
        Both halves of argument resolution read settings: Bind names a key directly, and the
        Settings:<Key> resolver names one through the catalogue. They must agree on three
        things, so the rule lives here rather than at each call site.

        What counts as "not configured": a blank or whitespace string, an empty map, an empty
        list. Those answer with $null, so an unset domain or an unset SKU map never reaches a
        command line as -SmtpDomain ''. A boolean is always a value, $false included - a
        settings file that says "do not include collisions" is saying something, and the step
        has to be told.

        A key the schema types as a Path is made absolute against the workspace when it is
        stored relative, which is how the settings file stores anything inside the workspace
        (Docs/Workbench-Design.md, section 3).

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace; its Settings may be $null.

    .PARAMETER Key
        The dotted settings key, for example 'Destination.TenantId'.

    .EXAMPLE
        Get-MigrationStepSettingsValue -Workspace $workspace -Key 'Domains.Target'

        Returns the target domain, or $null when the settings file does not name one.

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

    $settings = $Workspace.Settings
    if ($null -eq $settings) { return $null }

    $value = $settings
    foreach ($segment in @($Key -split '\.')) {
        $value = Get-MigrationProperty -InputObject $value -Name $segment -Default $null
        if ($null -eq $value) { return $null }
    }

    if ($value -is [bool]) { return $value }
    if ($value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }

        # The schema is the authority on which keys hold paths, but reading it for every
        # tenant id and domain would be wasteful, so only a relative value spelled like a
        # path is worth the lookup.
        if ($Key -like '*Path' -and -not [System.IO.Path]::IsPathRooted($value)) {
            $pathKeys = @(Get-MigrationSettingsSchema | Where-Object { $_.Type -eq 'Path' } |
                    ForEach-Object { $_.Key })
            if ($pathKeys -contains $Key) { return (Join-Path $Workspace.Path $value) }
        }
        return $value
    }
    if ($value -is [System.Collections.IDictionary]) {
        if ($value.Count -eq 0) { return $null }
        return $value
    }
    if ($value -is [System.Collections.IEnumerable]) {
        if (@($value).Count -eq 0) { return $null }
        return $value
    }

    return $value
}
