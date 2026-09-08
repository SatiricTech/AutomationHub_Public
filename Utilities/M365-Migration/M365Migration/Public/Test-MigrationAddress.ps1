function Test-MigrationAddress {
    <#
    .SYNOPSIS
        Validates a UPN, SMTP address or mail nickname against Microsoft 365 limits.

    .DESCRIPTION
        Catches the addresses that Entra ID or Exchange Online would reject, before a
        migration plan is handed to a provisioning script. Every rejection carries a
        Reason so the plan's PlanDetail column tells the operator what to fix.

        Upn          local 1-64, domain 1-48, total <= 113, local characters
                     [a-z0-9'._-], exactly one '@', no leading, trailing or consecutive
                     dots in the local part, and a dot in the domain.
        Smtp         local <= 64, total <= 254, RFC-safe local characters.
        MailNickname 1-64, [a-z0-9._-], no dot at either end, no '@'.

        Guest UPNs in the 'user_fabrikam.com#EXT#@contoso.onmicrosoft.com' form are
        valid and are checked against a relaxed character set, because Entra ID mints
        that shape itself and no template may rewrite it.

    .PARAMETER Address
        The address or nickname to validate.

    .PARAMETER Kind
        Upn, Smtp or MailNickname.

    .EXAMPLE
        Test-MigrationAddress -Address 'john.smith@contoso.com' -Kind Upn

        Returns IsValid true with an empty Reason.

    .EXAMPLE
        Test-MigrationAddress -Address 'john..smith@contoso.com' -Kind Upn

        Returns IsValid false and a Reason naming the consecutive dots.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address,

        [Parameter(Mandatory)]
        [ValidateSet('Upn', 'Smtp', 'MailNickname')]
        [string]$Kind
    )

    $fail = { param([string]$Reason) return @{ IsValid = $false; Reason = $Reason } }

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return (& $fail 'Address is empty.')
    }

    $value = $Address.Trim()
    $lowered = $value.ToLowerInvariant()

    if ($Kind -eq 'MailNickname') {
        if ($lowered.Length -gt 64) {
            return (& $fail "Mail nickname is $($lowered.Length) characters; the maximum is 64.")
        }
        if ($lowered -notmatch '^[a-z0-9._-]+$') {
            return (& $fail 'Mail nickname may contain only letters, digits, dot, underscore and hyphen.')
        }
        if ($lowered.StartsWith('.') -or $lowered.EndsWith('.')) {
            return (& $fail 'Mail nickname may not start or end with a dot.')
        }
        return @{ IsValid = $true; Reason = '' }
    }

    $atCount = @($lowered.ToCharArray() | Where-Object { $_ -eq '@' }).Count
    if ($atCount -ne 1) {
        return (& $fail "Address must contain exactly one '@' (found $atCount).")
    }

    $parts = $lowered -split '@', 2
    $local = $parts[0]
    $domain = $parts[1]

    if ($local.Length -lt 1) { return (& $fail 'The local part is empty.') }
    if ($domain.Length -lt 1) { return (& $fail 'The domain is empty.') }
    if ($local.Length -gt 64) {
        return (& $fail "The local part is $($local.Length) characters; the maximum is 64.")
    }

    $totalLimit = if ($Kind -eq 'Upn') { 113 } else { 254 }
    if ($lowered.Length -gt $totalLimit) {
        return (& $fail "Address is $($lowered.Length) characters; the maximum for $Kind is $totalLimit.")
    }

    if ($Kind -eq 'Upn' -and $domain.Length -gt 48) {
        return (& $fail "The domain is $($domain.Length) characters; the maximum for a UPN is 48.")
    }

    # Entra ID generates the guest form itself, so it is accepted verbatim; only the
    # portion before the marker is character-checked.
    $isExternal = $local.EndsWith('#ext#')
    $localToCheck = if ($isExternal) { $local.Substring(0, $local.Length - 5) } else { $local }

    if ([string]::IsNullOrEmpty($localToCheck)) {
        return (& $fail 'The local part is empty.')
    }

    $localPattern = if ($isExternal) {
        "^[a-z0-9'._-]+$"
    }
    elseif ($Kind -eq 'Upn') {
        "^[a-z0-9'._-]+$"
    }
    else {
        "^[a-z0-9!#\$%&'*+/=?^_`\`{|}~.-]+$"
    }

    if ($localToCheck -notmatch $localPattern) {
        return (& $fail "The local part '$local' contains characters that are not allowed in a $Kind address.")
    }

    if ($localToCheck.StartsWith('.') -or $localToCheck.EndsWith('.')) {
        return (& $fail 'The local part may not start or end with a dot.')
    }
    if ($localToCheck -match '\.\.') {
        return (& $fail 'The local part may not contain consecutive dots.')
    }

    if ($domain -notmatch '\.') {
        return (& $fail "The domain '$domain' must contain a dot.")
    }
    if ($domain -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') {
        return (& $fail "The domain '$domain' is not a valid DNS name.")
    }

    return @{ IsValid = $true; Reason = '' }
}
