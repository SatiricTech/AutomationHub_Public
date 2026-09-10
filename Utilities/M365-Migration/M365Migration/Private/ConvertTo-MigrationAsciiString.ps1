function ConvertTo-MigrationAsciiString {
    <#
    .SYNOPSIS
        Transliterates a Unicode string to its closest ASCII form.

    .DESCRIPTION
        Address local parts must be ASCII. Two passes are needed because not every
        Latin letter decomposes: 'e-acute' splits into 'e' plus a combining accent under
        NFD, but 'o-slash', 'eszett' and the ligatures carry no combining mark at all
        and have to be mapped by hand first. Ordinal (-creplace) matching keeps the
        upper- and lower-case forms distinct.

    .PARAMETER Value
        The text to transliterate. Null or empty returns an empty string.

    .EXAMPLE
        ConvertTo-MigrationAsciiString -Value 'Muller-Ostergaard'

        Returns the ASCII form of a name carrying diacritics.

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

    if ([string]::IsNullOrEmpty($Value)) { return '' }

    $mapped = $Value `
        -creplace "ß", 'ss' `
        -creplace "æ", 'ae' -creplace "Æ", 'AE' `
        -creplace "œ", 'oe' -creplace "Œ", 'OE' `
        -creplace "ø", 'o'  -creplace "Ø", 'O' `
        -creplace "đ", 'd'  -creplace "Đ", 'D' `
        -creplace "ð", 'd'  -creplace "Ð", 'D' `
        -creplace "þ", 'th' -creplace "Þ", 'TH' `
        -creplace "ł", 'l'  -creplace "Ł", 'L' `
        -creplace "ı", 'i'  -creplace "İ", 'I'

    $decomposed = $mapped.Normalize([System.Text.NormalizationForm]::FormD)
    $builder = [System.Text.StringBuilder]::new($decomposed.Length)

    foreach ($character in $decomposed.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }

    return $builder.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}
