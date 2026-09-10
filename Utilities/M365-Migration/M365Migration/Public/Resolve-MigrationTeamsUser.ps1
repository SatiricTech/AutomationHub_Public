function Resolve-MigrationTeamsUser {
    <#
    .SYNOPSIS
        Resolves a UPN or object ID to a Teams user object.

    .DESCRIPTION
        Get-CsOnlineUser throws when the identity is unknown, which would abort a
        per-row loop that is meant to record the miss and carry on. This wrapper turns
        that terminating error into $null so the caller can mark the row Failed with a
        useful Detail and continue with the rest of the wave.

    .PARAMETER Identity
        A user principal name or Entra ID object ID.

    .EXAMPLE
        Resolve-MigrationTeamsUser -Identity 'john.smith@contoso.com'

        Returns the Teams user object, or $null when the user does not exist.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        Requires an active MicrosoftTeams session; call Connect-MigrationTeams first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity
    )

    try {
        return Get-CsOnlineUser -Identity $Identity -ErrorAction Stop
    }
    catch {
        Write-MigrationLog -Message "Teams user '$Identity' could not be resolved: $($_.Exception.Message)" -Level DEBUG
        return $null
    }
}
