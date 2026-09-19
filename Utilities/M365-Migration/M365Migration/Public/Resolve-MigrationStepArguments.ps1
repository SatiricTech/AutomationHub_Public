function Resolve-MigrationStepArguments {
    <#
    .SYNOPSIS
        Works out the exact parameter list a step would run with, and where each value came from.

    .DESCRIPTION
        This is the seam between "the operator picked a step" and "a child process runs a
        script" (Docs/Workbench-Design.md, sections 5.3 and 7.1). It reads the step's
        catalogue entry, the workspace scan and whatever the operator typed, and returns the
        arguments as data: what would be passed, what it would be, and which of five sources
        decided it. Both front ends render that; the driver writer turns it into a splat.

        Nothing here connects to anything or writes anything. Resolving is safe to do on every
        keystroke, which is what makes a live "this is what will run" panel possible.

        The precedence ladder, highest first:

          Fixed     The instance is only that step because of these - -Stage Provisioned,
                    -Prefix Source, -AcknowledgeSourceTenant. They are not negotiable.
          Operator  What the operator typed, through -Override. A key that is not a parameter
                    of the script is dropped with a warning rather than passed on to fail in
                    the child, where the error would be a parameter-binding stack trace.
          Settings  The catalogue's Bind map, settings key -> parameter. A blank setting is
                    not a value and is left out, so an unset domain never arrives as
                    -SmtpDomain ''. A boolean is always a value: settings that say "do not
                    include collisions" are saying something.
          Resolved  The catalogue's Resolve map, parameter -> resolver. See
                    Resolve-MigrationStepInput for what each resolver looks for. Every
                    resolved argument keeps its Candidates, so a form can offer the files the
                    resolver passed over.
          Default   The script's own default, recorded so a form can show what will happen if
                    the field is left alone - and deliberately NOT passed. A default is the
                    script's business, and re-stating it in a driver would freeze today's value
                    into a file that outlives the script.

        Five parameters the workbench always owns are added last, under the source 'Common':
        -OutputPath is the workspace, -Prefix is the instance's fixed prefix or the label,
        -Verbosity comes from the settings defaults, -DryRun appears only for a rehearsal, and
        -Confirm:$false appears only for a script whose ConfirmImpact is High (the catalogue's
        Confirm flag), because an unattended child process cannot answer a prompt. -Wave is
        added the same way when the caller asks for one and the script takes it. -LogPath is
        never passed: every script derives it from -OutputPath, and naming it here would move
        the logs out from under the workspace.

        -TenantId and -DelegatedOrganization are covered by the catalogue's Bind map on every
        entry that has them; where an entry does not, the side's own settings block is used, so
        a script that takes -TenantId always gets one and can assert which tenant it reached.

        Parameter sets. A parameter the operator or the instance fixed narrows the sets under
        consideration to the ones that hold it, which is what makes -TestUser select the
        TestUser set even though the plan would also have resolved. The chosen set is then the
        first set the script declares whose mandatory parameters are all present; if none is
        satisfiable, the closest one is chosen and MissingMandatory says what it still needs.
        Arguments that do not belong to the chosen set are dropped, because a command line
        that mixes two sets cannot bind at all.

    .PARAMETER Step
        The step instance from Get-MigrationStep.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .PARAMETER Override
        Operator input, parameter name -> value. Matched case-insensitively against the
        script's parameters; an unknown name is dropped and reported in Warnings.

    .PARAMETER DryRun
        Resolve the arguments for a rehearsal, which adds -DryRun.

    .PARAMETER Wave
        The waves the run is limited to. Added as -Wave when the script takes it.

    .EXAMPLE
        Resolve-MigrationStepArguments -Step (Get-MigrationStep -Id 'New-Users') -Workspace $ws

        Returns the provisioning run's arguments: the plan it resolved, the destination tenant
        from settings, the workspace as -OutputPath and the label as -Prefix.

    .EXAMPLE
        $resolved = Resolve-MigrationStepArguments -Step $step -Workspace $ws -DryRun -Wave '1'
        $resolved.Arguments | Where-Object Source -ne 'Default' | Format-Table Name, Value, Source

        Shows exactly what a wave-1 rehearsal would pass, which is the panel both front ends
        draw before the operator commits.

    .EXAMPLE
        (Resolve-MigrationStepArguments -Step $step -Workspace $ws).MissingMandatory

        Lists what the operator still has to supply before the step can run at all.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The name is fixed by the workbench contract (Docs/Workbench-Design.md, section 7.1).')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Step,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [AllowNull()]
        [hashtable]$Override,

        [switch]$DryRun,

        [AllowEmptyCollection()]
        [string[]]$Wave
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $parameters = @($Step.Parameters)

    # PowerShell hashtables are case-insensitive, which is what lets an operator type
    # 'planpath' and still get the script's declared spelling on the command line.
    $byName = @{}
    foreach ($parameter in $parameters) { $byName[$parameter.Name] = $parameter }

    if ($null -eq $Workspace.Settings) {
        $warnings.Add('The workspace has no valid settings file, so nothing could be taken from settings.')
    }

    # --- what the instance fixes, and what the operator typed -------------------------------

    $fixedValues = [ordered]@{}
    foreach ($key in @($Step.Fixed.Keys)) {
        $name = [string]$key
        if (-not $byName.ContainsKey($name)) {
            $warnings.Add("The catalogue fixes -$name, which $($Step.Script).ps1 does not have.")
            continue
        }
        $fixedValues[$byName[$name].Name] = $Step.Fixed[$key]
    }

    $operatorValues = [ordered]@{}
    if ($Override) {
        foreach ($key in @($Override.Keys)) {
            $name = [string]$key
            if (-not $byName.ContainsKey($name)) {
                $warnings.Add("'$name' is not a parameter of $($Step.Script).ps1, so it was ignored.")
                continue
            }
            $operatorValues[$byName[$name].Name] = $Override[$key]
        }
    }

    # --- which parameter sets are still in play ---------------------------------------------

    $setNames = @($Step.ParameterSets.Names)
    $candidateSets = @($setNames)
    foreach ($name in (@($fixedValues.Keys) + @($operatorValues.Keys))) {
        $sets = @($byName[$name].ParameterSets)
        # A parameter in every set - or in a script with no named sets - narrows nothing.
        if ($sets.Count -eq 0 -or $sets.Count -eq $setNames.Count) { continue }

        $narrowed = @($candidateSets | Where-Object { $sets -contains $_ })
        if ($narrowed.Count -eq 0) {
            $warnings.Add("-$name cannot be combined with the other values supplied: they belong to " +
                'different parameter sets.')
            continue
        }
        $candidateSets = $narrowed
    }

    $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($parameter in $parameters) {
        $sets = @($parameter.ParameterSets)
        if ($sets.Count -eq 0 -or @($sets | Where-Object { $candidateSets -contains $_ }).Count -gt 0) {
            $null = $allowed.Add($parameter.Name)
        }
    }

    # --- the ladder --------------------------------------------------------------------------

    $values = @{}

    foreach ($name in @($fixedValues.Keys)) {
        if (-not $allowed.Contains($name)) { continue }
        $values[$name] = New-MigrationStepArgument -Name $name -Value $fixedValues[$name] -Source 'Fixed'
    }

    foreach ($name in @($operatorValues.Keys)) {
        if ($values.ContainsKey($name) -or -not $allowed.Contains($name)) { continue }
        $values[$name] = New-MigrationStepArgument -Name $name -Value $operatorValues[$name] -Source 'Operator'
    }

    foreach ($settingsKey in @($Step.Bind.Keys)) {
        $target = [string]$Step.Bind[$settingsKey]
        if (-not $byName.ContainsKey($target)) {
            $warnings.Add("The catalogue binds '$settingsKey' to -$target, which $($Step.Script).ps1 " +
                'does not have.')
            continue
        }
        $name = $byName[$target].Name
        if ($values.ContainsKey($name) -or -not $allowed.Contains($name)) { continue }

        $bound = Get-MigrationStepSettingsValue -Workspace $Workspace -Key $settingsKey
        if ($null -eq $bound) { continue }
        $values[$name] = New-MigrationStepArgument -Name $name -Value $bound -Source 'Settings'
    }

    $catalog = $null
    foreach ($target in @($Step.Resolve.Keys)) {
        $resolver = [string]$Step.Resolve[$target]
        if (-not $byName.ContainsKey($target)) {
            $warnings.Add("The catalogue resolves -$target, which $($Step.Script).ps1 does not have.")
            continue
        }
        $name = $byName[$target].Name
        if ($values.ContainsKey($name) -or -not $allowed.Contains($name)) { continue }

        # Only the Export: resolver needs the catalogue, and building it is not free, so it is
        # read once and only when a step actually asks for another step's output.
        if ($resolver -like 'Export:*' -and $null -eq $catalog) {
            $catalog = if ($Workspace.Scenario) { @(Get-MigrationStep -Scenario $Workspace.Scenario) }
            else { @(Get-MigrationStep) }
        }

        $resolved = Resolve-MigrationStepInput -Resolver $resolver -Workspace $Workspace -Catalog $catalog
        if ($null -eq $resolved.Source) {
            $warnings.Add("Resolver '$resolver' for -$name is not one this workbench knows.")
            continue
        }
        if ($null -eq $resolved.Value) { continue }

        $values[$name] = New-MigrationStepArgument -Name $name -Value $resolved.Value -Source 'Resolved' `
            -Candidates @($resolved.Candidates)
    }

    # --- the parameters the workbench owns ----------------------------------------------------

    if ($byName.ContainsKey('OutputPath') -and -not $values.ContainsKey('OutputPath')) {
        $values['OutputPath'] = New-MigrationStepArgument -Name 'OutputPath' -Value $Workspace.Path -Source 'Common'
    }

    if ($byName.ContainsKey('Prefix') -and -not $values.ContainsKey('Prefix')) {
        if ($Workspace.Label) {
            $values['Prefix'] = New-MigrationStepArgument -Name 'Prefix' -Value $Workspace.Label -Source 'Common'
        }
        else {
            $warnings.Add('The workspace has no label, so -Prefix could not be set. Set ' +
                "'Label' in M365Migration.settings.json.")
        }
    }

    if ($byName.ContainsKey('Verbosity') -and -not $values.ContainsKey('Verbosity')) {
        $verbosity = Get-MigrationStepSettingsValue -Workspace $Workspace -Key 'Defaults.Verbosity'
        if ($null -ne $verbosity) {
            $values['Verbosity'] = New-MigrationStepArgument -Name 'Verbosity' -Value $verbosity -Source 'Common'
        }
    }

    # A step that talks to a tenant must always name it, so the script's own assertion can
    # refuse a session that reached the other one.
    if ($Step.Side -in @('Source', 'Destination')) {
        foreach ($name in @('TenantId', 'DelegatedOrganization')) {
            if (-not $byName.ContainsKey($name) -or $values.ContainsKey($name)) { continue }
            if (-not $allowed.Contains($name)) { continue }
            $sideValue = Get-MigrationStepSettingsValue -Workspace $Workspace -Key "$($Step.Side).$name"
            if ($null -eq $sideValue) { continue }
            $values[$name] = New-MigrationStepArgument -Name $name -Value $sideValue -Source 'Common'
        }
    }

    if ($DryRun -and $byName.ContainsKey('DryRun')) {
        $values['DryRun'] = New-MigrationStepArgument -Name 'DryRun' -Value $true -Source 'Common'
    }

    if ($Step.Confirm -and $byName.ContainsKey('Confirm')) {
        $values['Confirm'] = New-MigrationStepArgument -Name 'Confirm' -Value $false -Source 'Common'
    }

    if ($PSBoundParameters.ContainsKey('Wave') -and @($Wave).Count -gt 0 -and
        $byName.ContainsKey('Wave') -and -not $values.ContainsKey('Wave') -and $allowed.Contains('Wave')) {
        $values['Wave'] = New-MigrationStepArgument -Name 'Wave' -Value @($Wave) -Source 'Common'
    }

    # --- the script's own defaults, recorded but never passed ----------------------------------

    foreach ($parameter in $parameters) {
        if ($parameter.Common -or $values.ContainsKey($parameter.Name)) { continue }
        if (-not $allowed.Contains($parameter.Name) -or $null -eq $parameter.Default) { continue }
        $values[$parameter.Name] = New-MigrationStepArgument -Name $parameter.Name `
            -Value $parameter.Default -Source 'Default'
    }

    # --- the parameter set, and what it still needs ---------------------------------------------

    $present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($values.Keys)) {
        if ($values[$name].Source -ne 'Default') { $null = $present.Add($name) }
    }

    $chosenSet = ''
    $missing = @()
    if ($setNames.Count -eq 0) {
        # No named sets: one implicit set, and every mandatory parameter belongs to it.
        $missing = @($parameters |
                Where-Object { $_.Mandatory -and -not $present.Contains($_.Name) } |
                ForEach-Object { $_.Name })
    }
    else {
        $closestSet = ''
        $closestMissing = $null
        foreach ($setName in $candidateSets) {
            $needed = @($parameters |
                    Where-Object { @($_.MandatoryIn) -contains $setName -and -not $present.Contains($_.Name) } |
                    ForEach-Object { $_.Name })
            if ($needed.Count -eq 0) {
                $chosenSet = $setName
                $closestMissing = $null
                break
            }
            if ($null -eq $closestMissing -or $needed.Count -lt $closestMissing.Count) {
                $closestSet = $setName
                $closestMissing = $needed
            }
        }
        if (-not $chosenSet -and $null -ne $closestMissing) {
            $chosenSet = $closestSet
            $missing = @($closestMissing)
        }
    }

    if ($chosenSet) {
        # Anything outside the chosen set would make the whole command line unbindable, so it
        # goes - including the plan a resolver found before the operator chose another mode.
        foreach ($name in @($values.Keys)) {
            $sets = @($byName[$name].ParameterSets)
            if ($sets.Count -gt 0 -and $sets -notcontains $chosenSet) { $values.Remove($name) }
        }
    }

    # Declaration order is the order a reader of the script expects, and it is stable, which
    # matters because this list is written into a driver file that is kept as a record.
    $arguments = [System.Collections.Generic.List[object]]::new()
    foreach ($parameter in $parameters) {
        if ($values.ContainsKey($parameter.Name)) { $arguments.Add($values[$parameter.Name]) }
    }

    return [pscustomobject]@{
        Arguments        = @($arguments)
        ParameterSet     = $chosenSet
        MissingMandatory = @($missing)
        Warnings         = @($warnings)
    }
}
