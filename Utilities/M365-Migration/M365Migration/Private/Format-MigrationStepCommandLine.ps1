function Format-MigrationStepCommandLine {
    <#
    .SYNOPSIS
        Renders a resolved argument list the way an operator would have typed it.

    .DESCRIPTION
        The command preview both front ends show before a run (Docs/Workbench-Design.md,
        sections 8 and 9) is this line. It is deliberately not the driver: the driver is a
        splat, which is correct and unreadable, while this is the shape of the command the
        operator already knows from the README - Set-MigrationIdentity.ps1 -PlanPath '...'
        -Wave 1 -DryRun.

        Readability is what it optimises for, so a value is only quoted where quoting tells the
        reader something: a path, a display name, anything with a space or a quote in it. A
        plain token - a prefix, a wave, a verbosity level - is left bare, because '1' reads as
        a quoted string where 1 reads as a wave.

        Switches are shown bare when present (-DryRun) and as -Name:$false when explicitly off,
        which is how a switch is actually written; a [bool] parameter keeps its value beside it
        (-ForceChangePassword $false), because that is how a [bool] must be written and the two
        are not interchangeable at the command line. Arrays are comma-joined and a dictionary
        is rendered as the hashtable literal it is: the operator needs to see which domains an
        alias map holds, not that one exists.

    .PARAMETER Step
        The step instance, read for its script name and its parameter metadata (which of the
        arguments are switches).

    .PARAMETER Argument
        The arguments that will actually be passed, in the order the driver writes them.

    .EXAMPLE
        Format-MigrationStepCommandLine -Step $step -Argument $emitted

        Returns "New-MigrationUsers.ps1 -PlanPath '/plans/p.csv' -Wave 1 -DryRun".

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Step,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Argument
    )

    # A token that needs no quotes to be read back as itself: a wave, a prefix, a verbosity
    # level, a GUID. Anything else - a path, a display name, an empty string - gets them.
    $bareToken = '^[A-Za-z0-9._-]+$'

    $switchNames = @(@(Get-MigrationProperty -InputObject $Step -Name 'Parameters' -Default @()) |
            Where-Object { $_.IsSwitch } | ForEach-Object { [string]$_.Name })

    $renderScalar = {
        param($Value)
        if ($Value -is [string] -and $Value -match $bareToken) { return [string]$Value }
        return ConvertTo-MigrationPowerShellLiteral -Value $Value
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add([System.IO.Path]::GetFileName([string]$Step.ScriptPath))

    foreach ($item in @($Argument)) {
        $name = [string]$item.Name
        $value = $item.Value

        if ($switchNames -contains $name) {
            $present = if ($value -is [System.Management.Automation.SwitchParameter]) { $value.IsPresent }
            else { [bool]$value }
            $parts.Add($(if ($present) { "-$name" } else { "-${name}:`$false" }))
            continue
        }

        if ($value -is [System.Collections.IDictionary] -or
            ($value -isnot [string] -and $value -isnot [System.Collections.IEnumerable])) {
            $parts.Add("-$name " + (& $renderScalar $value))
            continue
        }

        if ($value -is [string]) {
            $parts.Add("-$name " + (& $renderScalar $value))
            continue
        }

        $items = @(@($value) | ForEach-Object { & $renderScalar $_ })
        $parts.Add("-$name " + ($items -join ','))
    }

    return ($parts -join ' ')
}
