function Get-MigrationScriptParameterDefault {
    <#
    .SYNOPSIS
        Reads a script's parameter default values out of its param block.

    .DESCRIPTION
        Get-Command does not expose default values: a default lives in the param block's
        expression tree, not in the parameter metadata, so the only way to learn that
        -UpnFormat defaults to 'First.Last' is to read the ParamBlockAst.

        SafeGetValue() evaluates the literal expressions a default is normally written as -
        a string, a number, $true/$false/$null, an array literal, a hashtable literal - and
        refuses anything that would have to run code. A default that has to run code (a
        Join-Path call, say) is reported as its source text instead, which is still the right
        thing to show an operator beside the field even though no value can be precomputed.

    .PARAMETER Command
        The ExternalScriptInfo for the script, as returned by Get-Command on its path.

    .EXAMPLE
        Get-MigrationScriptParameterDefault -Command (Get-Command ./New-MigrationUsers.ps1)

        Returns @{ ForceChangePassword = $true; PasswordLength = 16; Verbosity = 'Medium' }.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Management.Automation.CommandInfo]$Command
    )

    $defaults = @{}
    $paramBlock = $Command.ScriptBlock.Ast.ParamBlock
    if ($null -eq $paramBlock) { return $defaults }

    foreach ($parameter in $paramBlock.Parameters) {
        if ($null -eq $parameter.DefaultValue) { continue }

        $name = $parameter.Name.VariablePath.UserPath
        try {
            $defaults[$name] = $parameter.DefaultValue.SafeGetValue()
        }
        catch {
            $defaults[$name] = $parameter.DefaultValue.Extent.Text
        }
    }

    return $defaults
}
