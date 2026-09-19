function ConvertFrom-MigrationMapText {
    <#
    .SYNOPSIS
        Reads typed 'old=new' pairs into the ordered map a hashtable parameter expects.

    .DESCRIPTION
        Three places take a map from an operator: the console settings form's `Map` rows, the
        console step form's `E` action on a `[hashtable]` parameter, and the window's two-column
        editor (Docs/Workbench-Design.md, sections 8 and 9). Each of them used to parse the text
        itself, and the one that did not - the console's `E` - handed the typed string straight
        to the resolver, where the child then failed to bind a String to a Hashtable.

        Both separators are accepted, because both are what an operator has in front of them: a
        single-line box holds `old.com=new.com;other.com=new.com`, and a multi-line editor holds
        one pair per line. A pair with no `=` is skipped rather than guessed at, and so is one
        whose left side is blank - a map key that is the empty string binds, and then silently
        matches nothing.

        Ordered, because the map goes into a driver file that is kept as the record of the run,
        and a record whose lines move between two readings of the same input is a poor record.

        Exported rather than private because the window lives in Start-MigrationWorkbench.ps1,
        outside the module, and the front ends may only call exported functions.

    .PARAMETER Text
        What the operator typed. Pairs separated by ';' or by line breaks, each 'left=right'.
        Empty text is an empty map, which is a real answer: it clears the map.

    .EXAMPLE
        ConvertFrom-MigrationMapText -Text 'old.com=new.com;legacy.com=new.com'

        Returns an ordered map of two rewrites.

    .EXAMPLE
        ConvertFrom-MigrationMapText -Text "old.com=new.com`nlegacy.com=new.com"

        Returns the same map from the window's two-column editor, one pair per line.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $map = [ordered]@{}
    $value = if ($null -eq $Text) { '' } else { $Text }

    foreach ($pair in @($value -split ";|\r?\n")) {
        $parts = $pair -split '=', 2
        if ($parts.Count -ne 2) { continue }
        $left = $parts[0].Trim()
        if (-not $left) { continue }
        $map[$left] = $parts[1].Trim()
    }

    return $map
}
