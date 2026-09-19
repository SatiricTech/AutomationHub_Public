function Get-MigrationStep {
    <#
    .SYNOPSIS
        Returns the workbench's step catalogue: one object per step instance, or per script.

    .DESCRIPTION
        The workbench presents the toolkit twice - as guided runbook phases, and as a flat
        toolbox - and both views render from these objects. Each is a script plus the overlay
        that says what the script cannot say about itself (M365Migration/StepCatalog.psd1,
        see Docs/Workbench-Design.md section 5) plus the script's own parameters, read live
        through Get-MigrationScriptParameter.

        One script can back several steps. The inventory runs three times with a different
        -Prefix, readiness runs at three stages, domain release runs as a report and then as a
        remediation. Those are the instances: each one fixes the parameters that make it that
        step, and inherits everything else from its script's entry. A script with no instances
        declared is one instance whose id is its name with 'Migration' removed, so
        New-MigrationUsers is the step 'New-Users'.

        Without -Id or -Script every instance comes back, ordered by the runbook. -Id returns
        one instance and ignores -Scenario, because asking for a step by name is explicit.
        -Script returns the bare script entry for the all-tools view: the same shape with no
        Fixed values, since that view offers every option free, and with its instances hanging
        off the Instances property.

        The catalogue is read from <ToolkitPath>/M365Migration/StepCatalog.psd1 and cached for
        the session by path and LastWriteTimeUtc.

    .PARAMETER Id
        Return just this step instance, for example 'Readiness-Pre' or 'New-Users'.

    .PARAMETER Script
        Return the bare entry for this script basename, for example 'Test-MigrationReadiness'.

    .PARAMETER Scenario
        Keep only the steps that apply to this migration scenario: TenantToTenant or
        InPlaceRedesign. Ignored when -Id names a step.

    .PARAMETER ToolkitPath
        The folder holding the 17 scripts and the M365Migration module. Defaults to the
        module's own parent folder.

    .EXAMPLE
        Get-MigrationStep | Sort-Object Order | Format-Table Order, Id, Phase, Side, Impact

        Lists the whole runbook in order, as the phase view shows it.

    .EXAMPLE
        Get-MigrationStep -Scenario 'InPlaceRedesign' | Select-Object Id, Title

        Lists only the steps an in-place UPN redesign needs; the tenant-to-tenant ones are gone.

    .EXAMPLE
        (Get-MigrationStep -Id 'Readiness-Provisioned').Fixed

        Shows the parameters that instance always passes - here -Stage Provisioned.

    .EXAMPLE
        Get-MigrationStep -Script 'New-MigrationUsers' | Select-Object -ExpandProperty Parameters

        Returns every parameter of the provisioning script for the all-tools form.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Id')]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(Mandatory, ParameterSetName = 'Script')]
        [ValidateNotNullOrEmpty()]
        [string]$Script,

        [ValidateNotNullOrEmpty()]
        [string]$Scenario,

        [ValidateNotNullOrEmpty()]
        [string]$ToolkitPath
    )

    if (-not $PSBoundParameters.ContainsKey('ToolkitPath')) {
        # This file lives in <toolkit>/M365Migration/Public, so the toolkit is two levels up.
        $ToolkitPath = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    }

    $catalog = Import-MigrationStepCatalog -Path (Join-Path $ToolkitPath 'M365Migration' 'StepCatalog.psd1')

    $scriptNames = @($catalog.Keys | Sort-Object)
    if ($PSCmdlet.ParameterSetName -eq 'Script') {
        if ($scriptNames -notcontains $Script) {
            throw ("'$Script' is not in the step catalogue. Known scripts: " + ($scriptNames -join ', '))
        }
        $scriptNames = @($Script)
    }

    $bareEntries = [System.Collections.Generic.List[object]]::new()
    $instances = [System.Collections.Generic.List[object]]::new()

    foreach ($name in $scriptNames) {
        $entry = $catalog[$name]
        $scriptPath = Join-Path $ToolkitPath "$name.ps1"
        $introspection = Get-MigrationScriptParameter -ScriptPath $scriptPath

        # The default id is the script's name with the 'Migration' noun prefix removed:
        # New-MigrationUsers -> New-Users. Anchored to the verb so it can only ever strip the
        # one after the leading verb, never a 'Migration' that appears later in a noun.
        $defaultId = $name -replace '^(\w+)-Migration', '$1-'

        $definitions = @(Get-MigrationCatalogValue -Entry $entry -Instance $null -Key 'Instances' -Default @())
        if ($definitions.Count -eq 0) {
            # No instances declared: the script is one step, named after itself.
            $definitions = @(@{ Id = $defaultId })
        }

        $scriptInstances = [System.Collections.Generic.List[object]]::new()
        foreach ($definition in $definitions) {
            $instanceId = [string](Get-MigrationCatalogValue -Entry $definition -Instance $null -Key 'Id' `
                    -Default $defaultId)
            $scriptInstances.Add((New-MigrationStepObject -Entry $entry -Instance $definition -Id $instanceId `
                        -Script $name -ScriptPath $scriptPath -Introspection $introspection))
        }

        $bare = New-MigrationStepObject -Entry $entry -Instance $null -Id $name -Script $name `
            -ScriptPath $scriptPath -Introspection $introspection
        $bare.Instances = @($scriptInstances)

        $bareEntries.Add($bare)
        foreach ($instance in $scriptInstances) { $instances.Add($instance) }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Id') {
        $match = @($instances | Where-Object { $_.Id -eq $Id })
        if ($match.Count -eq 0) {
            $known = @($instances.Id | Sort-Object) -join ', '
            throw "Step '$Id' is not in the step catalogue. Known steps: $known"
        }
        return $match[0]
    }

    if ($PSCmdlet.ParameterSetName -eq 'Script') {
        $bare = $bareEntries[0]
        if ($PSBoundParameters.ContainsKey('Scenario')) {
            $bare.Instances = @($bare.Instances | Where-Object { $_.Scenario -contains $Scenario })
        }
        return $bare
    }

    $selected = $instances
    if ($PSBoundParameters.ContainsKey('Scenario')) {
        $selected = @($instances | Where-Object { $_.Scenario -contains $Scenario })
    }

    return @($selected | Sort-Object -Property Order, Id)
}
