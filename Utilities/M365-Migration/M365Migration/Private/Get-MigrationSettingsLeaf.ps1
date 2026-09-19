function Get-MigrationSettingsLeaf {
    <#
    .SYNOPSIS
        Walks a dotted settings key and answers null for anything that is not configured.

    .DESCRIPTION
        The raw half of Get-MigrationStepSettingsValue: the key walk and the "is this a value?"
        test, with no fallbacks and no path handling. Separated so the fallback rule can ask
        the same question of a second key without recursing into its own fallbacks.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace; its Settings may be $null.

    .PARAMETER Key
        The dotted settings key.

    .EXAMPLE
        Get-MigrationSettingsLeaf -Workspace $workspace -Key 'Domains.Smtp'

        Returns the SMTP domain, or $null when the settings file leaves it blank.

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
