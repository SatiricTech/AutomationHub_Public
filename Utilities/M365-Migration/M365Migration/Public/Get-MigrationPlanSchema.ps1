function Get-MigrationPlanSchema {
    <#
    .SYNOPSIS
        Returns the identity plan's column layout and status vocabulary.

    .DESCRIPTION
        Save-MigrationPlan and Import-MigrationPlan already read Private/PlanSchema.ps1's
        $script: variables directly, since they live inside the module. Everything else -
        a script building a plan-shaped CSV, a report, or a test asserting on the contract -
        had no supported way to read the same values without reaching into module internals.

        This is a read-only view: the arrays on the returned object are copies of the
        module's own, so a caller mutating the result cannot corrupt the schema every
        other function in the module relies on.

    .EXAMPLE
        (Get-MigrationPlanSchema).Columns

        Returns the 48 canonical plan columns, in the order Save-MigrationPlan writes them.

    .EXAMPLE
        if ('ManualOverride' -in (Get-MigrationPlanSchema).PlanStatuses) { 'known status' }

        Validates a status value against the plan's vocabulary.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    return [pscustomobject]@{
        Columns          = @($script:MigrationPlanColumns)
        WritebackColumns = @($script:MigrationPlanWritebackColumns)
        ObjectTypes      = @($script:MigrationObjectTypes)
        PlanStatuses     = @($script:MigrationPlanStatuses)
    }
}
