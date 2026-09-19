function Get-MigrationScriptParameterHelp {
    <#
    .SYNOPSIS
        Reads a script's .PARAMETER descriptions as a name -> text map.

    .DESCRIPTION
        The generated step form shows one line of help beside each field, and the only place
        that sentence exists is the script's comment-based help. Get-Help parses it; nothing
        else does, which is why this reaches for the help engine rather than the AST.

        One wildcard call (-Parameter '*') is made first because it costs a single parse for
        the whole file rather than one per parameter, and any name the wildcard result does
        not carry is then asked for by name. Every call is wrapped: help is a nicety, and a
        script with a malformed or missing help block must still produce a usable form rather
        than failing the catalogue.

        The text is flattened to a single line - Get-Help returns it as MAML paragraph items,
        which carry the source file's own line wrapping - because a form field's help is one
        line of prose, not a reflowed paragraph.

    .PARAMETER Path
        Path to the .ps1 file whose help is read.

    .PARAMETER Name
        The parameter names to look up.

    .EXAMPLE
        Get-MigrationScriptParameterHelp -Path ./New-MigrationUsers.ps1 -Name 'PlanPath', 'Wave'

        Returns a hashtable of the two parameters' help sentences.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Name
    )

    $map = @{}

    function Get-MigrationHelpItemText {
        param([AllowNull()]$HelpItem)

        if ($null -eq $HelpItem) { return '' }

        # -Parameter returns MAML objects, so every property has to be probed rather than
        # assumed: a script whose help block omits a .PARAMETER entry still returns an object.
        $description = $HelpItem.PSObject.Properties['description']
        if ($null -eq $description -or $null -eq $description.Value) { return '' }

        $parts = foreach ($item in @($description.Value)) {
            $text = $item.PSObject.Properties['Text']
            if ($null -ne $text -and $null -ne $text.Value) { [string]$text.Value }
        }

        return (($parts -join ' ') -replace '\s+', ' ').Trim()
    }

    try {
        foreach ($item in @(Get-Help -Name $Path -Parameter '*' -ErrorAction Stop)) {
            $itemName = $item.PSObject.Properties['name']
            if ($null -eq $itemName -or [string]::IsNullOrWhiteSpace([string]$itemName.Value)) { continue }

            $text = Get-MigrationHelpItemText -HelpItem $item
            if (-not [string]::IsNullOrWhiteSpace($text)) { $map[[string]$itemName.Value] = $text }
        }
    }
    catch {
        Write-Debug "Wildcard help lookup failed for '$Path': $($_.Exception.Message)"
    }

    foreach ($parameterName in $Name) {
        if ($map.ContainsKey($parameterName)) { continue }

        try {
            $item = Get-Help -Name $Path -Parameter $parameterName -ErrorAction Stop
            $text = Get-MigrationHelpItemText -HelpItem $item
            if (-not [string]::IsNullOrWhiteSpace($text)) { $map[$parameterName] = $text }
        }
        catch {
            Write-Debug "No help for '$parameterName' in '$Path': $($_.Exception.Message)"
        }
    }

    return $map
}
