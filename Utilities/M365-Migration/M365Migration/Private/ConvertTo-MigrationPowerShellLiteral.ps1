function ConvertTo-MigrationPowerShellLiteral {
    <#
    .SYNOPSIS
        Renders a value as the PowerShell source literal that reconstructs it.

    .DESCRIPTION
        The generated driver (Docs/Workbench-Design.md, section 7.3) is a file, not a command
        line, and that is the whole point: 'pwsh -File' flattens every argument to a string, so
        -Wave @('1','2') arrives as '1 2' and -ForceChangePassword $false arrives as the string
        'False', which binds to $true. A splat written into a file binds properly - but only if
        the values were written as literals that mean what the resolver meant.

        So every rendering rule here is a binding rule:

          string      single-quoted, embedded quotes doubled. Single quotes, not double, so a
                      $ in a path or a password-shaped value can never be expanded.
          bool/switch $true / $false, never the string 'True'.
          number      bare and in the invariant culture, so a European operator's comma
                      separator cannot turn 2.5 into a syntax error.
          array       @('a', 'b'), and @('a') for one element: dropping the @() would make a
                      one-wave run bind a string where the script declared [string[]].
          dictionary  @{ 'k' = 'v'; ... }, keys sorted unless the caller ordered them, because
                      a driver that differs only in hash order is a diff nobody can read.
          $null       '$null' - the driver writer drops the argument instead of passing it, but
                      that is its decision to make, not this function's.

        Anything else - a GUID, a datetime, an enum - is rendered as its string form in a
        single-quoted literal: every toolkit parameter that takes one declares [string] or
        parses the string itself, so the quoted form is what binds.

    .PARAMETER Value
        The value to render.

    .EXAMPLE
        ConvertTo-MigrationPowerShellLiteral -Value @('1', '2')

        Returns "@('1', '2')".

    .EXAMPLE
        ConvertTo-MigrationPowerShellLiteral -Value "C:\it's here\p.csv"

        Returns "'C:\it''s here\p.csv'" - the embedded quote doubled, not escaped.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        $Value
    )

    if ($null -eq $Value) { return '$null' }

    if ($Value -is [System.Management.Automation.SwitchParameter]) {
        return $(if ($Value.IsPresent) { '$true' } else { '$false' })
    }

    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [short] -or $Value -is [byte] -or
        $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    }

    if ($Value -is [string]) { return "'" + ($Value -replace "'", "''") + "'" }

    if ($Value -is [System.Collections.IDictionary]) {
        # An operator-ordered dictionary keeps its order; a plain hashtable has none worth
        # keeping, so its keys are sorted to make two runs with the same values produce the
        # same file byte for byte.
        $keys = @($Value.Keys)
        if ($Value -isnot [System.Collections.Specialized.OrderedDictionary]) {
            $keys = @($keys | Sort-Object -Property { [string]$_ })
        }
        if ($keys.Count -eq 0) { return '@{}' }

        $pairs = foreach ($key in $keys) {
            '{0} = {1}' -f (ConvertTo-MigrationPowerShellLiteral -Value ([string]$key)),
            (ConvertTo-MigrationPowerShellLiteral -Value $Value[$key])
        }
        return '@{ ' + (@($pairs) -join '; ') + ' }'
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(@($Value) | ForEach-Object { ConvertTo-MigrationPowerShellLiteral -Value $_ })
        if ($items.Count -eq 0) { return '@()' }
        return '@(' + ($items -join ', ') + ')'
    }

    return "'" + ([string]$Value -replace "'", "''") + "'"
}
