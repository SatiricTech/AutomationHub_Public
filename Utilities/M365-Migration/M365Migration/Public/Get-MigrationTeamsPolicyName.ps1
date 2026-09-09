function Get-MigrationTeamsPolicyName {
    <#
    .SYNOPSIS
        Normalises a Teams policy assignment to a plain policy name.

    .DESCRIPTION
        Get-CsOnlineUser returns policy properties inconsistently: sometimes a bare
        string, sometimes an object exposing a Name property, sometimes null for the
        global (tenant default) policy. Reports and CSV round-trips need one shape, so
        everything collapses to a string here and null stays null.

    .PARAMETER Policy
        The raw policy value read from a Teams user object.

    .EXAMPLE
        Get-MigrationTeamsPolicyName -Policy $user.OnlineVoiceRoutingPolicy

        Returns the policy name, or $null when the user is on the global policy.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Policy
    )

    if ($null -eq $Policy) { return $null }
    if ($Policy.PSObject.Properties['Name']) { return [string]$Policy.Name }

    $text = [string]$Policy
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}
