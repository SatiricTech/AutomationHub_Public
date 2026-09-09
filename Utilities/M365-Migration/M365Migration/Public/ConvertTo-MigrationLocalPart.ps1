function ConvertTo-MigrationLocalPart {
    <#
    .SYNOPSIS
        Builds an address local part from name components using a token template.

    .DESCRIPTION
        The naming engine behind New-MigrationIdentityPlan. A template is either a named
        preset or a token string; tokens are replaced with sanitised name components and
        literal characters pass through.

        Tokens: {first} {last} {middle} {f} {m} {l} {source} {display}
        Truncation: {last:5} keeps the first five characters of that token.

        Presets: First.Last, FLast, F.Last, FirstLast, First, First.L, FirstL,
        First.M.Last, FMLast, Last.First, Keep.

        Each token is transliterated to ASCII, lowercased, stripped of apostrophes and
        spaces, and reduced to [a-z0-9-]. After assembly, runs of '.' and '-' collapse
        and any leading or trailing separator is trimmed.

        The design rule that matters: the engine never guesses. If a token the template
        needs is empty after sanitising - no surname on the source object, a name written
        only in Han characters - IsComplete is false and MissingTokens names the gaps, so
        the caller marks the row NeedsReview and a human decides. {middle} and {m} are the
        one exception: they are optional by nature and simply disappear along with their
        adjacent separator.

        A token the engine does not know - '{nick}' - is a typo, not a literal, and is
        refused with an error naming it rather than written into the address.

        {source} is passed through rather than sanitised, because it is already a valid
        local part. That is what makes the 'Keep' preset lossless and lets guest '#EXT#'
        addresses survive untouched.

    .PARAMETER Template
        A preset name or a token template string.

    .PARAMETER FirstName
        Given name, feeding {first} and {f}.

    .PARAMETER MiddleName
        Middle name, feeding {middle} and {m}. Optional in every sense.

    .PARAMETER LastName
        Surname, feeding {last} and {l}.

    .PARAMETER SourceLocalPart
        The existing local part, feeding {source}.

    .PARAMETER DisplayName
        Display name, feeding {display}.

    .EXAMPLE
        ConvertTo-MigrationLocalPart -Template 'First.Last' -FirstName 'José' -LastName 'Müller-Østergaard'

        Returns LocalPart 'jose.muller-ostergaard' with IsComplete true.

    .EXAMPLE
        ConvertTo-MigrationLocalPart -Template '{first}.{m}.{last}' -FirstName 'John' -LastName 'Smith'

        Returns 'john.smith' - the empty middle token takes its separator with it.

    .EXAMPLE
        ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName 'John'

        Returns IsComplete false and MissingTokens 'last' rather than inventing a name.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Template,

        [AllowNull()][AllowEmptyString()][string]$FirstName,
        [AllowNull()][AllowEmptyString()][string]$MiddleName,
        [AllowNull()][AllowEmptyString()][string]$LastName,
        [AllowNull()][AllowEmptyString()][string]$SourceLocalPart,
        [AllowNull()][AllowEmptyString()][string]$DisplayName
    )

    $presets = @{
        'First.Last'   = '{first}.{last}'
        'FLast'        = '{f}{last}'
        'F.Last'       = '{f}.{last}'
        'FirstLast'    = '{first}{last}'
        'First'        = '{first}'
        'First.L'      = '{first}.{l}'
        'FirstL'       = '{first}{l}'
        'First.M.Last' = '{first}.{m}.{last}'
        'FMLast'       = '{f}{m}{last}'
        'Last.First'   = '{last}.{first}'
        'Keep'         = '{source}'
    }

    $pattern = $Template
    if ($pattern -notmatch '\{') {
        if ($presets.ContainsKey($pattern)) {
            $pattern = $presets[$pattern]
        }
        else {
            throw ("'$Template' is neither a token template nor a known preset. Known presets: " +
                (($presets.Keys | Sort-Object) -join ', ') + '.')
        }
    }

    $tokenPattern = '\{(?<name>first|last|middle|display|source|f|m|l)(?::(?<len>\d+))?\}'

    # A token nobody recognises would otherwise pass through as literal '{nick}' text and only
    # surface as an unusable address several steps later, so a typo is refused here by name.
    $residue = [regex]::Replace($pattern, $tokenPattern, '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($residue -match '[{}]') {
        $offending = @([regex]::Matches($residue, '\{[^{}]*\}?|\}') | ForEach-Object { $_.Value } | Select-Object -Unique)
        throw ("The template '$Template' contains unknown token(s) " + ($offending -join ', ') +
            '. Known tokens: {first} {last} {middle} {f} {m} {l} {source} {display}, each with an ' +
            'optional truncation such as {last:5}.')
    }

    $first = ConvertTo-MigrationTokenText -Value $FirstName
    $middle = ConvertTo-MigrationTokenText -Value $MiddleName
    $last = ConvertTo-MigrationTokenText -Value $LastName
    $display = ConvertTo-MigrationTokenText -Value $DisplayName

    # The source local part is already a legal address component, so it is preserved
    # rather than sanitised. Casing is normalised except for the '#EXT#' marker, which
    # Entra ID stores upper-case on guest accounts.
    $source = ''
    if (-not [string]::IsNullOrWhiteSpace($SourceLocalPart)) {
        $source = $SourceLocalPart.Trim().ToLowerInvariant() -replace '#ext#', '#EXT#'
    }

    $values = @{
        'first'   = $first
        'last'    = $last
        'middle'  = $middle
        'f'       = if ($first) { $first.Substring(0, 1) } else { '' }
        'm'       = if ($middle) { $middle.Substring(0, 1) } else { '' }
        'l'       = if ($last) { $last.Substring(0, 1) } else { '' }
        'source'  = $source
        'display' = $display
    }

    # {middle} and {m} are optional; every other token is required by the template that names it.
    $optionalTokens = @('middle', 'm')

    $missing = [System.Collections.Generic.List[string]]::new()
    $builder = [System.Text.StringBuilder]::new()
    $cursor = 0

    foreach ($match in [regex]::Matches($pattern, $tokenPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$builder.Append($pattern.Substring($cursor, $match.Index - $cursor))
        $cursor = $match.Index + $match.Length

        $name = $match.Groups['name'].Value.ToLowerInvariant()
        $value = [string]$values[$name]

        if ([string]::IsNullOrEmpty($value)) {
            if ($optionalTokens -notcontains $name -and -not $missing.Contains($name)) {
                $missing.Add($name)
            }
            continue
        }

        if ($match.Groups['len'].Success) {
            $length = [int]$match.Groups['len'].Value
            if ($length -lt $value.Length) { $value = $value.Substring(0, $length) }
        }

        [void]$builder.Append($value)
    }

    [void]$builder.Append($pattern.Substring($cursor))

    # Collapse the separator runs left behind by empty tokens, then trim the ends.
    $localPart = $builder.ToString() -replace '([.-])[.-]+', '$1'
    $localPart = $localPart -replace '^[.-]+', '' -replace '[.-]+$', ''

    return [pscustomobject]@{
        LocalPart     = $localPart
        IsComplete    = ($missing.Count -eq 0)
        MissingTokens = [string[]]$missing.ToArray()
    }
}
