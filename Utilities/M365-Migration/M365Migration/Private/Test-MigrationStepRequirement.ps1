function Test-MigrationStepRequirement {
    <#
    .SYNOPSIS
        Says whether one entry of a step's Requires list is met in this workspace.

    .DESCRIPTION
        A Requires entry names either another step instance, which has to be Done, or an
        artefact kind from the Produces vocabulary, which only has to exist
        (Docs/Workbench-Design.md, section 5.2). That second case is what lets a plan carried
        in from another machine satisfy 'Plan' without the planner ever having run here, and
        it is why this is not simply a lookup of the step's state.

        A step id is looked for first, exactly as the scanner does when it picks the next step,
        so a catalogue that ever named a step after an artefact kind would still read as the
        step. An entry that is neither is not met - it cannot be - and the scanner has already
        reported it in the workspace's Warnings, so nothing is said again here.

    .PARAMETER Requirement
        The Requires entry: a step id, an artefact kind, or 'Report:<name>'.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .EXAMPLE
        Test-MigrationStepRequirement -Requirement 'Plan' -Workspace $workspace

        Returns $true when the workspace holds an identity plan, whoever produced it.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Requirement,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace
    )

    $state = @($Workspace.Steps | Where-Object { $_.Id -eq $Requirement })
    if ($state.Count -gt 0) { return ($state[0].State -eq 'Done') }

    # The Produces vocabulary, mapped onto what the scanner's parsed filenames actually look
    # like. These are the same rules Get-MigrationWorkspace uses to build its artefact-kind set
    # (section 6), restated here rather than shared because the scanner builds the set once for
    # a whole scan while this answers one question at a time.
    #
    #   Plan       the scanner already chose one - pinned, or newest - so its own answer stands.
    #   Log        any .log the naming contract parsed, in any prefix folder.
    #   Results    any '-Results_' file; a '-DryRun_' file is a rehearsal and is not evidence.
    #   Inventory  the Users tab, which is the one every inventory run writes and so the one
    #              that proves an inventory happened.
    #   Mapping    the mapping export has no artefact of its own - the mover's workbook is named
    #              by the mover's contract, not the toolkit's - so its results file stands in.
    #   Report:<n> a suffix-less artefact whose whole Name is <n>; 'DomainBlockers-Recheck' is
    #              one name, not a name plus a suffix.
    $artefacts = @($Workspace.Artefacts)
    switch ($Requirement) {
        'Plan' { return ($null -ne $Workspace.Plan) }
        'Log' { return (@($artefacts | Where-Object { $_.Extension -eq 'log' }).Count -gt 0) }
        'Results' { return (@($artefacts | Where-Object { $_.Suffix -eq 'Results' }).Count -gt 0) }
        'Inventory' {
            return (@($artefacts | Where-Object { $_.Suffix -eq '' -and $_.Name -eq 'Users' }).Count -gt 0)
        }
        'Mapping' {
            return (@($artefacts |
                        Where-Object { $_.Suffix -eq 'Results' -and $_.Name -eq 'Export-MappingFile' }).Count -gt 0)
        }
    }

    if ($Requirement -like 'Report:*') {
        $name = $Requirement.Substring('Report:'.Length)
        return (@($artefacts | Where-Object { $_.Suffix -eq '' -and $_.Name -eq $name }).Count -gt 0)
    }

    return $false
}
