function New-MigrationSettings {
    <#
    .SYNOPSIS
        Builds a settings document with every schema default filled in.

    .DESCRIPTION
        Returns the settings document (Docs/Workbench-Design.md, section 4) as an [ordered]
        hashtable, in schema order, with every key set to its Get-MigrationSettingsSchema
        default. This is the "new workspace" starting point: the workbench applies -Label
        and -Scenario, writes the result with Save-MigrationSettings, and the operator fills
        in the rest through the settings form.

        The label is normalised through Format-MigrationPrefix - the same normalisation
        Initialize-MigrationRun applies to a run prefix - so a settings document this
        function builds already passes Resolve-MigrationSettings' Label check.

    .PARAMETER Label
        Names the migration. Normalised with Format-MigrationPrefix. When omitted, the
        schema default (an empty string) is used, which Resolve-MigrationSettings and
        Save-MigrationSettings both reject until the operator sets a real label.

    .PARAMETER Scenario
        'TenantToTenant' (default) or 'InPlaceRedesign'.

    .EXAMPLE
        New-MigrationSettings -Label 'Contoso'

        Returns the default document with Label set to 'Contoso' and Scenario left at
        'TenantToTenant'.

    .EXAMPLE
        New-MigrationSettings -Label 'Contoso Redesign' -Scenario InPlaceRedesign

        Returns the default document for an in-place redesign; the label is normalised to
        'Contoso-Redesign'.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The name is fixed by the settings file contract (Docs/Workbench-Design.md).')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory document; changes no system state until Save-MigrationSettings writes.')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Label,

        [ValidateSet('TenantToTenant', 'InPlaceRedesign')]
        [string]$Scenario
    )

    $settings = [ordered]@{}
    foreach ($entry in Get-MigrationSettingsSchema) {
        $segments = $entry.Key -split '\.', 2
        if ($segments.Count -eq 1) {
            $settings[$segments[0]] = $entry.Default
        }
        else {
            $top = $segments[0]
            if (-not $settings.Contains($top)) { $settings[$top] = [ordered]@{} }
            $settings[$top][$segments[1]] = $entry.Default
        }
    }

    if ($PSBoundParameters.ContainsKey('Label')) {
        $settings['Label'] = Format-MigrationPrefix -Value $Label
    }
    if ($PSBoundParameters.ContainsKey('Scenario')) {
        $settings['Scenario'] = $Scenario
    }

    return $settings
}
