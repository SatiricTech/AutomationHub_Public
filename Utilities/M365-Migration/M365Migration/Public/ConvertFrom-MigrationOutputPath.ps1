function ConvertFrom-MigrationOutputPath {
    <#
    .SYNOPSIS
        Parses a migration output filename back into its prefix, name, suffix,
        timestamp and extension.

    .DESCRIPTION
        The inverse of Get-MigrationOutputPath, for anything that needs to read a
        migration output folder back apart - a cleanup pass, an inventory scanner, a
        report that lists what a run produced.

        Only the filename is inspected; any directory component in -Path is ignored. A
        '.bak' file (Save-MigrationPlan's backup convention) and any name that does not
        match the '<Prefix>_<Name>_<timestamp>.<ext>' shape (with the prefix segment
        optional) return $null rather than throwing, because a caller scanning a folder
        expects to skip files that are not part of the contract, not to stop on them.

        Name and Prefix never contain an underscore - it is the contract's separator -
        but a hyphen is common in Name (as in 'Set-Identity' or 'Migration-Inventory').
        To recover Suffix, the last hyphen in the parsed name is treated as a split point
        only when the segment after it is exactly 'Results' or 'DryRun' - the two mode
        suffixes Export-MigrationResult writes. Every other hyphenated name, including
        one produced by a caller passing its own -Suffix to Export-MigrationReport (for
        example 'DomainBlockers-Recheck'), is returned whole in Name with an empty
        Suffix. That is a deliberate, narrower rule than "split on the last hyphen" -
        it is the only way to tell a mode suffix apart from a name that simply contains
        a hyphen.

    .PARAMETER Path
        The file path (or bare filename) to parse.

    .EXAMPLE
        ConvertFrom-MigrationOutputPath -Path 'Contoso_Set-Identity-Results_20260918-101500.csv'

        Returns an object with Prefix 'Contoso', Name 'Set-Identity', Suffix 'Results'.

    .EXAMPLE
        ConvertFrom-MigrationOutputPath -Path 'Contoso_Migration-Inventory_20260917-091200.xlsx'

        Returns Name 'Migration-Inventory' and an empty Suffix: 'Inventory' is not a mode
        suffix, so the hyphenated name is kept whole.

    .EXAMPLE
        ConvertFrom-MigrationOutputPath -Path 'Contoso_IdentityPlan_20260918-101500.csv.bak'

        Returns $null - Save-MigrationPlan backups are not part of the filename contract.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # Mode suffixes Export-MigrationResult writes; the only segments the parser treats
    # as a splittable Suffix rather than part of a hyphenated Name.
    $modeSuffixes = @('Results', 'DryRun')

    $leaf = [System.IO.Path]::GetFileName($Path)
    if ($leaf -match '\.bak$') { return $null }

    $pattern = '^(?:(?<prefix>[^_]+)_)?(?<name>[^_]+)_(?<ts>\d{8}-\d{6})\.(?<ext>[A-Za-z0-9]+)$'
    if ($leaf -notmatch $pattern) { return $null }

    $prefix = if ($Matches.ContainsKey('prefix')) { $Matches['prefix'] } else { '' }
    $rawName = $Matches['name']
    $extension = $Matches['ext']
    $timestamp = [datetime]::ParseExact($Matches['ts'], 'yyyyMMdd-HHmmss', $null)

    $name = $rawName
    $suffix = ''
    $hyphenIndex = $rawName.LastIndexOf('-')
    if ($hyphenIndex -ge 0) {
        $candidate = $rawName.Substring($hyphenIndex + 1)
        if ($modeSuffixes -ccontains $candidate) {
            $suffix = $candidate
            $name = $rawName.Substring(0, $hyphenIndex)
        }
    }

    return [pscustomobject]@{
        Path      = $Path
        FileName  = $leaf
        Prefix    = $prefix
        Name      = $name
        Suffix    = $suffix
        Timestamp = $timestamp
        Extension = $extension
    }
}
