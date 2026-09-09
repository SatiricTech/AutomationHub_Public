function ConvertTo-MigrationTokenText {
    <#
    .SYNOPSIS
        Sanitises one name component for use inside an address local part.

    .DESCRIPTION
        Applies the toolkit's per-token rule set: transliterate to ASCII, lowercase,
        drop apostrophes and whitespace so "O'Brien" and "van der Berg" join up, keep
        hyphens so double-barrelled surnames survive, and discard everything else.
        A name written only in a non-Latin script therefore reduces to an empty string,
        which is exactly the signal the caller needs in order to flag it for review
        instead of inventing an address.

    .PARAMETER Value
        The raw name component.

    .EXAMPLE
        ConvertTo-MigrationTokenText -Value "O'Brien"

        Returns 'obrien'.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $ascii = ConvertTo-MigrationAsciiString -Value $Value.Trim()
    $lowered = $ascii.ToLowerInvariant()

    # Apostrophes and spaces vanish outright; the catch-all below then removes any
    # remaining punctuation or non-Latin character.
    $lowered = $lowered -replace "['\u2019\s]", ''
    $cleaned = $lowered -replace '[^a-z0-9-]', ''

    # A component left holding nothing but separators - a surname recorded as '-' - carries no
    # name at all. Returning it would quietly shorten the address to 'john@' instead of telling
    # the caller the surname is missing, so it is treated as empty.
    if ($cleaned -notmatch '[a-z0-9]') { return '' }

    return $cleaned
}
