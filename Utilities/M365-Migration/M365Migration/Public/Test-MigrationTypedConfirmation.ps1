function Test-MigrationTypedConfirmation {
    <#
    .SYNOPSIS
        Decides whether what the operator typed clears a hard gate.

    .DESCRIPTION
        One rule, in the engine, applied by the console form, the window's modal dialog and the
        unattended path's -Set @{ Acknowledge = ... } alike (Docs/Workbench-Design.md, section
        7.2). It lived in three places before, which is three chances for the strongest gate in
        the toolkit to mean something different depending on which front end an operator happened
        to open.

        A domain is matched without case, because DNS has none and an operator who typed
        'NewCo.com' typed the domain. Anything else - the word REMOVE - is matched with case,
        because shouting it is the point. A value containing a dot is taken to be the domain,
        which is what tells the two kinds apart without the gate having to declare which it is.

        A gate that names nothing to type is refused rather than treated as satisfied: 'nothing
        expected' must never become 'anything is accepted', which would turn a typed confirmation
        into no gate at all.

    .PARAMETER Typed
        What the operator typed, or what -Set @{ Acknowledge = ... } carried. Surrounding
        whitespace is ignored.

    .PARAMETER Required
        The gate's RequiredInput.

    .EXAMPLE
        Test-MigrationTypedConfirmation -Typed 'NEWCO.COM' -Required 'newco.com'

        Returns $true: a domain has no case.

    .EXAMPLE
        Test-MigrationTypedConfirmation -Typed 'remove' -Required 'REMOVE'

        Returns $false: the keyword is matched with case.

    .EXAMPLE
        Test-MigrationTypedConfirmation -Typed 'anything' -Required ''

        Returns $false: a gate naming nothing to type cannot be cleared by typing.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Typed,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Required
    )

    if ([string]::IsNullOrWhiteSpace($Required)) { return $false }

    $answer = if ($null -eq $Typed) { '' } else { $Typed.Trim() }
    if ($Required -like '*.*') { return ($answer -ieq $Required) }
    return ($answer -ceq $Required)
}
