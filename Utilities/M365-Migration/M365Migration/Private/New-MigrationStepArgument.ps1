function New-MigrationStepArgument {
    <#
    .SYNOPSIS
        Builds one entry of a resolved step's argument list.

    .DESCRIPTION
        Resolve-MigrationStepArguments fills its list from six places, and every entry has to
        come out the same shape whichever place it came from, because a form binds to it and a
        driver writer reads it. That shape is built here so the six call sites cannot drift.

        The one piece of judgement in it is Warning. A parameter that names a file gets checked
        for the file actually being there, but only when the value came from settings or from a
        resolver - the two sources the operator did not look at. A path the operator typed is
        theirs, and flagging it would be arguing with someone who can see their own filesystem.
        The argument is never dropped over a missing file: a step may legitimately be told to
        write one, and refusing to show the value would hide what the run is about to do.

    .PARAMETER Name
        The parameter's declared name.

    .PARAMETER Value
        The value that would be passed.

    .PARAMETER Source
        Which rung of the precedence ladder decided it: Fixed, Operator, Settings, Resolved,
        Default or Common.

    .PARAMETER Candidates
        The other values the resolver considered, newest first, for a form's dropdown.

    .EXAMPLE
        New-MigrationStepArgument -Name 'PlanPath' -Value $path -Source 'Resolved' -Candidates $plans

        Returns the resolved plan argument with the other plans on offer beside it.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only; nothing is written to disk or to a tenant.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        $Value,

        [Parameter(Mandatory)]
        [ValidateSet('Fixed', 'Operator', 'Settings', 'Resolved', 'Default', 'Common')]
        [string]$Source,

        [AllowEmptyCollection()]
        [string[]]$Candidates = @()
    )

    $warning = $null
    if ($Source -in @('Settings', 'Resolved') -and $Value -is [string] -and
        ($Name -like '*Path' -or $Name -like '*Csv') -and
        -not (Test-Path -LiteralPath $Value)) {
        $warning = "'$Value' is not on disk."
    }

    return [pscustomobject]@{
        Name       = $Name
        Value      = $Value
        Source     = $Source
        Warning    = $warning
        Candidates = @($Candidates)
    }
}
