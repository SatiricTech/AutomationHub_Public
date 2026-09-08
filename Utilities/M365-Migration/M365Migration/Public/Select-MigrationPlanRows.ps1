function Select-MigrationPlanRows {
    <#
    .SYNOPSIS
        Filters identity-plan rows by wave, object type and plan status.

    .DESCRIPTION
        The shared filter used by Import-MigrationPlan and by any script that needs to
        re-slice rows it already holds - provisioning users first and then their managers,
        for example, without re-reading the file.

        Rows whose PlanStatus is 'Excluded' are dropped by default, because the exclusion
        rules exist precisely so that break-glass and service accounts never reach a
        writer by accident. -IncludeExcluded brings them back for reporting, and an
        explicit -PlanStatus filter naming 'Excluded' is honoured on its own terms.

        All filters are case-insensitive and combine with AND.

    .PARAMETER Rows
        The plan rows to filter.

    .PARAMETER Wave
        One or more wave identifiers to keep.

    .PARAMETER ObjectType
        One or more object types to keep, for example 'User' or 'Shared'.

    .PARAMETER PlanStatus
        One or more plan statuses to keep.

    .PARAMETER IncludeExcluded
        Keeps rows with PlanStatus 'Excluded'.

    .EXAMPLE
        Select-MigrationPlanRows -Rows $plan -Wave '1' -ObjectType 'User'

        Returns the wave-one users, minus anything excluded.

    .EXAMPLE
        Select-MigrationPlanRows -Rows $plan -PlanStatus 'Planned', 'ManualOverride'

        Returns only the rows a writer is allowed to act on.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The function filters a set of rows and the plural name is fixed by the toolkit build contract.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [AllowNull()][AllowEmptyCollection()][string[]]$Wave,
        [AllowNull()][AllowEmptyCollection()][string[]]$ObjectType,
        [AllowNull()][AllowEmptyCollection()][string[]]$PlanStatus,

        [switch]$IncludeExcluded
    )

    $filtered = @($Rows)

    if ($Wave -and @($Wave).Count -gt 0) {
        $wanted = @($Wave | ForEach-Object { ([string]$_).Trim() })
        $filtered = @($filtered | Where-Object { $wanted -contains (Get-MigrationCsvValue -Row $_ -Name 'Wave' -Default '') })
    }

    if ($ObjectType -and @($ObjectType).Count -gt 0) {
        $wanted = @($ObjectType | ForEach-Object { ([string]$_).Trim() })
        $filtered = @($filtered | Where-Object { $wanted -contains (Get-MigrationCsvValue -Row $_ -Name 'ObjectType' -Default '') })
    }

    if ($PlanStatus -and @($PlanStatus).Count -gt 0) {
        $wanted = @($PlanStatus | ForEach-Object { ([string]$_).Trim() })
        $filtered = @($filtered | Where-Object { $wanted -contains (Get-MigrationCsvValue -Row $_ -Name 'PlanStatus' -Default '') })
    }
    elseif (-not $IncludeExcluded) {
        $filtered = @($filtered | Where-Object { (Get-MigrationCsvValue -Row $_ -Name 'PlanStatus' -Default '') -ne 'Excluded' })
    }

    return $filtered
}
