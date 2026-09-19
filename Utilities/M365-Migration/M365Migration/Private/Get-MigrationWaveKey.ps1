function Get-MigrationWaveKey {
    <#
    .SYNOPSIS
        Reduces a list of waves to one string that two runs can be compared on.

    .DESCRIPTION
        "Was this step rehearsed for the waves we are about to run live?" is a set question,
        not a list question: -Wave 2,1 and -Wave 1,2 select the same rows, and a wave named
        twice selects them once. Comparing the arrays directly would answer no to both, so
        both sides are reduced to the same normal form here - trimmed, blanks dropped, sorted,
        de-duplicated, joined - and compared as strings.

        An empty list is the whole plan, and its key is the empty string, so "no wave" matches
        "no wave" without the caller special-casing it.

    .PARAMETER Wave
        The waves, as a resolved -Wave argument or a ledger entry's Wave field holds them.

    .EXAMPLE
        Get-MigrationWaveKey -Wave @('2', '1')

        Returns '1|2', the same key -Wave 1,2 produces.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Wave
    )

    $normalised = @(@($Wave) |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ } |
            Sort-Object -Unique)

    return ($normalised -join '|')
}
