function Test-MigrationPlanRowActionable {
    <#
    .SYNOPSIS
        Decides whether a plan row may be acted on, and says why not when it may not.

    .DESCRIPTION
        Three things stop a row dead before any tenant call is attempted, and they are
        collected here so the ordering is explicit and can be proved offline rather than
        being re-implemented in each writer's per-row loop:

          PlanStatus  the planning phase has not signed the row off. Writers act on
                      Planned, ManualOverride and UpnSmtpDiverge; Collision only with
                      -IncludeCollisions; everything else is skipped with the status named
                      in the reason, so the results file explains itself.
          ObjectType  the object is not one this script handles - a group where the caller
                      only does mailboxes, say. Only checked when -SupportedObjectType is
                      given.
          IsSynced    the object is directory-synced. This is a Failed rather than a
                      Skipped, because UserPrincipalName and proxyAddresses must be changed
                      on-premises and allowed to sync: both Entra ID and Exchange Online
                      reject the write, and a migration that quietly leaves users behind is
                      worse than one that stops and says so.

        Returns Actionable, Reason and Status. Status is '' for an actionable row and
        otherwise the value the caller should put in the result row - 'Skipped' or
        'Failed' - so the two decisions stay in one place.

        Pure function - no tenant calls.

    .PARAMETER Row
        A plan row from Import-MigrationPlan. PlanStatus, ObjectType and IsSynced are read
        tolerantly, so a row missing any of them is handled rather than throwing.

    .PARAMETER IncludeCollisions
        Also act on rows whose PlanStatus is Collision.

    .PARAMETER ActionableStatus
        Overrides the default set of statuses a writer will act on.

    .PARAMETER SupportedObjectType
        The ObjectType values this caller handles. Omit to accept any object type.

    .PARAMETER IsSynced
        The object's onPremisesSyncEnabled value as read from the tenant, when the caller
        has looked it up. Overrides the row's own IsSynced column.

    .PARAMETER AllowSynced
        Acts on directory-synced objects anyway. For read-only callers and for the few
        attributes that are not mastered on-premises.

    .EXAMPLE
        $gate = Test-MigrationPlanRowActionable -Row $row
        if (-not $gate.Actionable) { continue }

        The standard opening of a writer's per-row loop.

    .EXAMPLE
        Test-MigrationPlanRowActionable -Row $row -SupportedObjectType 'User', 'Shared' -IncludeCollisions

        Accepts collision rows, and rejects groups and contacts with a reason naming the type.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Row,

        [switch]$IncludeCollisions,

        [ValidateNotNullOrEmpty()]
        [string[]]$ActionableStatus = @('Planned', 'ManualOverride', 'UpnSmtpDiverge'),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$SupportedObjectType = @(),

        [bool]$IsSynced,

        [switch]$AllowSynced
    )

    $blocked = {
        param([string]$Status, [string]$Reason)
        [pscustomobject]@{ Actionable = $false; Status = $Status; Reason = $Reason }
    }

    $statuses = [System.Collections.Generic.List[string]]::new()
    foreach ($status in @($ActionableStatus)) {
        if (-not [string]::IsNullOrWhiteSpace($status)) { $statuses.Add($status) }
    }
    if ($IncludeCollisions -and $statuses -notcontains 'Collision') { $statuses.Add('Collision') }

    $planStatus = [string](Get-MigrationCsvValue -Row $Row -Name 'PlanStatus' -Default '')
    if ($statuses -notcontains $planStatus) {
        $shown = if ($planStatus) { $planStatus } else { '(empty)' }
        return & $blocked 'Skipped' ("PlanStatus is '$shown' - this script only acts on " +
            "$($statuses -join ', ').")
    }

    $objectType = [string](Get-MigrationCsvValue -Row $Row -Name 'ObjectType' -Default '')
    $supported = @($SupportedObjectType | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($supported.Count -gt 0 -and $supported -notcontains $objectType) {
        $shown = if ($objectType) { $objectType } else { '(empty)' }
        return & $blocked 'Skipped' ("ObjectType '$shown' is not handled by this script - it acts on " +
            "$($supported -join ', ').")
    }

    if (-not $AllowSynced) {
        $synced = if ($PSBoundParameters.ContainsKey('IsSynced')) {
            $IsSynced
        }
        else {
            # The plan stores booleans as the strings 'True'/'False'; anything else, including
            # an empty cell, means 'not known to be synced'.
            [string](Get-MigrationCsvValue -Row $Row -Name 'IsSynced' -Default 'False') -ieq 'True'
        }

        if ($synced) {
            return & $blocked 'Failed' ('Object is directory-synced (onPremisesSyncEnabled). ' +
                'UserPrincipalName and proxyAddresses must be changed on-premises and allowed to ' +
                'sync - Entra ID and Exchange Online both reject the write.')
        }
    }

    [pscustomobject]@{ Actionable = $true; Status = ''; Reason = '' }
}
