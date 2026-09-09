function ConvertTo-MigrationX500 {
    <#
    .SYNOPSIS
        Normalises legacy distinguished names into X500 proxy-address form.

    .DESCRIPTION
        A plan carries the source LegacyExchangeDN, sometimes an already-formed 'X500:'
        entry, and sometimes a ';' separated list of both. Stamping the source DN onto the
        destination object as an X500 address is what makes replies to old mail and cached
        Outlook entries resolve after the move, so getting the form right matters more
        than it looks.

        Every value is trimmed, its existing prefix (in any casing) replaced with the
        uppercase 'X500:' Exchange expects, and duplicates collapsed case-insensitively
        while the first spelling seen is the one kept - a legacy DN is compared
        case-insensitively but stored as written.

        ';' separated values are expanded, so a plan cell and a single DN are both valid
        input.

    .PARAMETER Value
        One or more legacy distinguished names or X500 entries, individually or as a ';'
        separated list. Blank entries are dropped.

    .PARAMETER NoPrefix
        Returns the bare distinguished names instead of 'X500:' entries, for callers that
        add the prefix themselves.

    .EXAMPLE
        ConvertTo-MigrationX500 -Value '/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=abc'

        Returns 'X500:/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=abc'.

    .EXAMPLE
        ConvertTo-MigrationX500 -Value @($row.SourceX500, $row.LegacyExchangeDN)

        Returns the deduplicated X500 set for a plan row, whichever column carried it.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Value,

        [switch]$NoPrefix
    )

    begin {
        $result = [System.Collections.Generic.List[string]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    process {
        foreach ($item in @($Value)) {
            foreach ($entry in @(Split-MigrationList -Value $item)) {
                $dn = ([string]$entry).Trim() -replace '^(?i)x500:', ''
                $dn = $dn.Trim()
                if ([string]::IsNullOrWhiteSpace($dn)) { continue }
                if (-not $seen.Add($dn)) { continue }
                $result.Add($(if ($NoPrefix) { $dn } else { "X500:$dn" }))
            }
        }
    }

    end {
        return [string[]]$result.ToArray()
    }
}
