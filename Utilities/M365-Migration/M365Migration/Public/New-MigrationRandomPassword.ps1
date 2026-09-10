function New-MigrationRandomPassword {
    <#
    .SYNOPSIS
        Generates a random password from a cryptographic source.

    .DESCRIPTION
        Used where a passphrase is unsuitable - service principals, or tenants whose
        policy bans dictionary words. Characters are drawn with
        RandomNumberGenerator.GetInt32 rather than Get-Random because Get-Random is
        seeded from a non-cryptographic PRNG. One character from each required class is
        placed first and the whole string is then shuffled, guaranteeing complexity
        without the retry loop that a naive generator needs.

    .PARAMETER Length
        Password length. Entra ID's own maximum is 256; the floor of 12 matches the
        toolkit's minimum policy.

    .EXAMPLE
        New-MigrationRandomPassword -Length 20

        Returns a 20-character password containing all four character classes.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
        Generated values are written only to the results CSV, never to the run log.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Generates an in-memory value; changes no system state.')]
    [OutputType([string])]
    param(
        [ValidateRange(12, 128)]
        [int]$Length = 16
    )

    $classes = @(
        'abcdefghijkmnpqrstuvwxyz',
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        '23456789',
        '!@#$%^*-_=+?'
    )

    $characters = [System.Collections.Generic.List[char]]::new()
    foreach ($class in $classes) {
        $characters.Add($class[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
    }

    $pool = -join $classes
    while ($characters.Count -lt $Length) {
        $characters.Add($pool[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($pool.Length)])
    }

    # Fisher-Yates, so the guaranteed class characters do not always land at the front.
    for ($i = $characters.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $swap = $characters[$i]
        $characters[$i] = $characters[$j]
        $characters[$j] = $swap
    }

    return (-join $characters)
}
