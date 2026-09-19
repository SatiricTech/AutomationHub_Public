function Resolve-MigrationTeamsUser {
    <#
    .SYNOPSIS
        Resolves a UPN or object ID to a Teams user object.

    .DESCRIPTION
        Get-CsOnlineUser throws when the identity is unknown, which would abort a
        per-row loop that is meant to record the miss and carry on. This wrapper turns
        that terminating error into $null so the caller can mark the row Failed with a
        useful Detail and continue with the rest of the wave.

        Only a genuine miss becomes $null. An expired token, a throttled request or any
        other service failure is rethrown, because reporting those as 'user not found'
        would tell the operator to go and create accounts that already exist.

    .PARAMETER Identity
        A user principal name or Entra ID object ID.

    .EXAMPLE
        Resolve-MigrationTeamsUser -Identity 'john.smith@contoso.com'

        Returns the Teams user object, or $null when the user does not exist.

    .EXAMPLE
        try { Resolve-MigrationTeamsUser -Identity 'john.smith@contoso.com' }
        catch { Write-MigrationLog -Message $_.Exception.Message -Level ERROR }

        Shows the caller-side shape: $null means missing, an exception means the lookup
        itself failed and the row's real cause is in the message.

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
        $message = $_.Exception.Message

        # Only the wordings Teams actually uses for an unknown identity mean "missing".
        # -match is case-insensitive, so a service that shouts NOT FOUND still matches.
        # 'unable to find' is defensive: the Teams cmdlets have used it as well.
        if ($message -match 'not found|could not be found|does not exist|Cannot find|unable to find') {
            Write-MigrationLog -Message "Teams user '$Identity' could not be resolved: $message" -Level DEBUG
            return $null
        }

        throw "Could not resolve Teams user '$Identity': $message"
    }
}
