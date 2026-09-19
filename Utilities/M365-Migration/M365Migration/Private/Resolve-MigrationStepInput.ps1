function Resolve-MigrationStepInput {
    <#
    .SYNOPSIS
        Runs one named step-catalogue resolver over a scanned workspace.

    .DESCRIPTION
        The catalogue never stores a path. It stores the name of a rule for finding one -
        'Plan', 'Inventory:Source:Users', 'Export:Get-TeamsPhoneAssignments' - and this is
        where those names are turned into files (Docs/Workbench-Design.md, section 5.3).
        Keeping them here rather than in Resolve-MigrationStepArguments means a resolver can
        be asked a question on its own, which is what a form does when the operator opens the
        "which file?" dropdown beside a field.

        Every resolver answers with the same three things: the Value it chose, the Source that
        chose it (the resolver expression itself, so a UI can say why), and every Candidate it
        considered, newest first, so the answer is never the only one on offer. Value is always
        Candidates[0] when there are any, so "the resolver's pick" and "the top of the list"
        cannot disagree.

        The resolvers:

          Plan                      The workspace's identity plan - the pinned one if settings
                                    pin one, otherwise the newest. Candidates are every plan in
                                    the label folder, with the pinned one lifted to the front.
          ExistingPlan              The same document, for the planner's -ExistingPlanPath: a
                                    re-plan reads the plan it is about to replace.
          Inventory:<Prefix>:<Tab>  The newest <Prefix>_<Tab>_<ts>.csv - an inventory tab.
          Export:<Token>            Another step's export, found by the step's id or by one of
                                    its result tokens. Where that step also publishes a report
                                    of the same name (Get-TeamsPhoneAssignments writes both
                                    Source_Get-TeamsPhoneAssignments-Results_<ts>.csv and
                                    Source_TeamsPhoneAssignments_<ts>.csv) the report is
                                    preferred, because the report is the round trip: it carries
                                    the phone number, its type and the routing policy, where the
                                    results file only records what the export did. The results
                                    file stays on the candidate list.
          Settings:<Key>            A value stored in the settings file, addressed with the
                                    schema's dotted key. Blank strings and empty maps answer
                                    with nothing, so "not configured" never reaches a command
                                    line; a boolean answers with itself, including $false.

        A path is always absolute. A settings path stored relative - which is how the settings
        file stores anything inside the workspace - is resolved against the workspace folder.

        An unknown or malformed resolver name answers with a null Source. That is the signal
        the caller turns into a warning: a catalogue that asks for a rule this module does not
        have is a mistake worth reporting, not a silently empty field.

    .PARAMETER Resolver
        The resolver expression from the catalogue, for example 'Inventory:Source:Users'.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .PARAMETER Catalog
        The step instances, as Get-MigrationStep returns them. Only the Export: resolver needs
        them, to find the step that produced the file.

    .EXAMPLE
        Resolve-MigrationStepInput -Resolver 'Plan' -Workspace $workspace

        Returns the plan every consumer will run against, plus the other plans on disk.

    .EXAMPLE
        (Resolve-MigrationStepInput -Resolver 'Inventory:Source:Users' -Workspace $workspace).Candidates

        Lists every source user inventory in the workspace, newest first.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Resolver,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [AllowNull()]
        [object[]]$Catalog
    )

    $segments = @($Resolver -split ':')
    $kind = $segments[0]

    # The shape of the expression is part of the resolver's name: 'Inventory' on its own, or
    # 'Settings' with three parts, is a catalogue mistake and not an empty answer.
    $shapes = @{ 'Plan' = 1; 'ExistingPlan' = 1; 'Inventory' = 3; 'Export' = 2; 'Settings' = 2 }
    if (-not $shapes.ContainsKey($kind) -or $segments.Count -ne $shapes[$kind]) {
        return [pscustomobject]@{ Value = $null; Source = $null; Candidates = @() }
    }

    $value = $null
    $candidates = @()

    switch ($kind) {
        { $_ -in @('Plan', 'ExistingPlan') } {
            $plans = @()
            if ($Workspace.Label) {
                $plans = @($Workspace.Artefacts | Where-Object {
                        $_.Folder -eq $Workspace.Label -and $_.Name -eq 'IdentityPlan' -and $_.Suffix -eq ''
                    } | Sort-Object -Property Timestamp, Path -Descending)
            }
            $candidates = @($plans | ForEach-Object { $_.Path })

            if ($null -ne $Workspace.Plan) { $value = [string]$Workspace.Plan.Path }
            if ($value) {
                # A pinned plan leads the list even when a newer one exists: it is the document
                # every consumer is about to run against, so it has to read as the chosen one.
                $candidates = @($value) + @($candidates | Where-Object { $_ -ne $value })
            }
            break
        }

        'Inventory' {
            $found = @($Workspace.Artefacts | Where-Object {
                    $_.Prefix -eq $segments[1] -and $_.Name -eq $segments[2] -and
                    $_.Suffix -eq '' -and $_.Extension -eq 'csv'
                } | Sort-Object -Property Timestamp, Path -Descending)
            $candidates = @($found | ForEach-Object { $_.Path })
            if ($candidates.Count -gt 0) { $value = $candidates[0] }
            break
        }

        'Export' {
            $token = $segments[1]
            # An absent catalogue arrives as $null, and piping $null sends one $null item into
            # the filter, where reading .Id off it is a terminating error under strict mode.
            # A resolver is asked questions by forms as well as by the driver, so it answers
            # "nothing found" rather than throwing at whoever forgot the catalogue.
            $known = @($Catalog | Where-Object { $null -ne $_ })
            $producer = @($known | Where-Object {
                    $_.Id -eq $token -or @($_.ResultIds) -contains $token
                }) | Select-Object -First 1

            if ($producer) {
                $state = @($Workspace.Steps | Where-Object { $_.Id -eq $producer.Id })
                $files = if ($state.Count -gt 0) { @($state[0].Files) } else { @() }

                # 'Get-TeamsPhoneAssignments' names the report 'TeamsPhoneAssignments'; the verb
                # belongs to the step that wrote it, not to the artefact it wrote.
                $reportName = $token -replace '^\w+-', ''
                $reports = @()
                if (@($producer.Produces) -contains "Report:$reportName") {
                    $reports = @($files |
                            Where-Object { $_.Suffix -eq '' -and $_.Name -eq $reportName } |
                            Sort-Object -Property Timestamp, Path -Descending)
                }
                $results = @($files |
                        Where-Object { $_.Suffix -eq 'Results' } |
                        Sort-Object -Property Timestamp, Path -Descending)

                $candidates = @(@($reports) + @($results) | ForEach-Object { $_.Path })
                if ($candidates.Count -gt 0) { $value = $candidates[0] }
            }
            break
        }

        'Settings' {
            $stored = Get-MigrationStepSettingsValue -Workspace $Workspace -Key $segments[1]
            if ($null -ne $stored) {
                $value = $stored
                $candidates = @($stored)
            }
            break
        }
    }

    return [pscustomobject]@{
        Value      = $value
        Source     = $Resolver
        Candidates = @($candidates)
    }
}
