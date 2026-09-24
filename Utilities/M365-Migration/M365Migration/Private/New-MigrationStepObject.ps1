function New-MigrationStepObject {
    <#
    .SYNOPSIS
        Builds one step object from a catalogue entry, an instance and the script's parameters.

    .DESCRIPTION
        Both shapes Get-MigrationStep returns are built here so they cannot drift: the phase
        view's step instance, and the all-tools view's bare script entry. They differ in
        exactly one thing - the bare entry carries no Fixed values, because the all-tools view
        offers every option free - and that difference is expressed by passing -Instance $null
        rather than by a second builder.

        Every array and map is copied out of the catalogue rather than handed through, because
        the imported catalogue is cached for the session and a caller that edited a step in
        place would otherwise change every step built after it.

    .PARAMETER Entry
        The script's catalogue entry.

    .PARAMETER Instance
        The instance definition, or $null for the bare script entry.

    .PARAMETER Id
        The step's id: the instance's own id, or the script basename for a bare entry.

    .PARAMETER Script
        The script's basename.

    .PARAMETER ScriptPath
        Full path to the script.

    .PARAMETER Introspection
        The script's { Parameters; ParameterSets } from Get-MigrationScriptParameter.

    .EXAMPLE
        New-MigrationStepObject -Entry $entry -Instance $instance -Id 'Readiness-Pre' `
            -Script 'Test-MigrationReadiness' -ScriptPath $path -Introspection $introspection

        Returns the pre-provisioning readiness step with -Stage fixed to 'Pre'.

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
        [ValidateNotNull()]
        [hashtable]$Entry,

        [AllowNull()]
        [hashtable]$Instance,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Script,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Introspection
    )

    $isInstance = ($null -ne $Instance)

    $instanceFixed = $null
    $instanceBind = $null
    $instanceResolve = $null
    if ($isInstance) {
        $instanceFixed = Get-MigrationCatalogValue -Entry $Instance -Instance $null -Key 'Fixed' -Default @{}
        $instanceBind = Get-MigrationCatalogValue -Entry $Instance -Instance $null -Key 'Bind' -Default @{}
        $instanceResolve = Get-MigrationCatalogValue -Entry $Instance -Instance $null -Key 'Resolve' -Default @{}
    }

    # The all-tools view deliberately fixes nothing: it is the script with every option free.
    $fixed = @{}
    if ($isInstance) {
        $entryFixed = Get-MigrationCatalogValue -Entry $Entry -Instance $null -Key 'Fixed' -Default @{}
        $fixed = Merge-MigrationStepMap -Base $entryFixed -Override $instanceFixed
    }

    # A script that names its results by mode declares both tokens on its entry and the token
    # this view writes as ResultId. Both are published: the folder scanner has to recognise a
    # file either mode wrote, while the driver only ever writes this view's own token. Where
    # only one of the two keys is declared, the other is derived from it, so every step comes
    # back with a ResultIds list that contains its ResultId.
    $resultId = Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'ResultId' -Default $null
    $resultIds = @(Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'ResultIds' -Default @())
    if ($resultIds.Count -eq 0 -and $resultId) { $resultIds = @($resultId) }
    if (-not $resultId -and $resultIds.Count -gt 0) { $resultId = $resultIds[0] }
    if ($resultId -and $resultIds -notcontains $resultId) { $resultIds = @($resultIds) + @($resultId) }

    $entryBind = Get-MigrationCatalogValue -Entry $Entry -Instance $null -Key 'Bind' -Default @{}
    $entryResolve = Get-MigrationCatalogValue -Entry $Entry -Instance $null -Key 'Resolve' -Default @{}
    $exitCodes = Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'ExitCodes' `
        -Default @{ 0 = 'Completed'; 1 = 'Failed'; 2 = 'Some rows failed' }

    return [pscustomobject]@{
        Id            = $Id
        Script        = $Script
        ScriptPath    = $ScriptPath
        Title         = [string](Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Title' -Default '')
        Phase         = [string](Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Phase' -Default '')
        Order         = [double](Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Order' -Default 0)
        Side          = [string](Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Side' -Default '')
        Scenario      = @(Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Scenario' `
                -Default @('TenantToTenant', 'InPlaceRedesign'))
        Connects      = @(Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Connects' -Default @())
        Impact        = [string](Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Impact' `
                -Default 'Read')
        ResultId      = $resultId
        ResultIds     = @($resultIds)
        Confirm       = [bool](Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Confirm' `
                -Default $false)
        Fixed         = $fixed
        Bind          = Merge-MigrationStepMap -Base $entryBind -Override $instanceBind -ByValue
        Resolve       = Merge-MigrationStepMap -Base $entryResolve -Override $instanceResolve
        Requires      = @(Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Requires' -Default @())
        Produces      = @(Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Produces' -Default @())
        ExitCodes     = Merge-MigrationStepMap -Base $exitCodes -Override @{}
        Notes         = [string](Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Notes' -Default '')
        Ignore        = @(Get-MigrationCatalogValue -Entry $Entry -Instance $Instance -Key 'Ignore' -Default @())
        Parameters    = @($Introspection.Parameters)
        ParameterSets = $Introspection.ParameterSets
        IsInstance    = $isInstance
        Instances     = @()
    }
}
