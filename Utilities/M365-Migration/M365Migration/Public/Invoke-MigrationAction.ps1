function Invoke-MigrationAction {
    <#
    .SYNOPSIS
        Runs a mutating action, or logs what it would have done under -DryRun.

    .DESCRIPTION
        Every mutation in the toolkit goes through this wrapper. That is what makes the
        DryRun promise credible: there is exactly one place where a write can happen,
        and it is guarded by one flag read from the run context.

        In DryRun the action is not invoked and $null is returned, after logging
        '[DRYRUN] Would: <Description>'. Otherwise the description is logged, the action
        runs, and any failure is logged and re-thrown so the caller's per-row catch can
        mark the row Failed.

        This is intentionally separate from -WhatIf: scripts honour ShouldProcess at the
        row level for the interactive safety net, while DryRun is the batch-wide mode
        that still produces a full results CSV.

    .PARAMETER Description
        Human-readable description of the mutation, logged verbatim.

    .PARAMETER Action
        The scriptblock performing the mutation.

    .PARAMETER PassThru
        Returns whatever the action emitted. Without it the action's output is discarded,
        which keeps stray cmdlet output out of the caller's pipeline.

    .EXAMPLE
        Invoke-MigrationAction -Description "Set UPN for $upn" -Action { Update-MgUser -UserId $id -UserPrincipalName $target }

        Applies the change, or logs the intent when the run is a dry run.

    .EXAMPLE
        $mailbox = Invoke-MigrationAction -Description "Create shared mailbox $alias" -Action { New-Mailbox -Shared -Name $alias } -PassThru

        Captures the created object for later steps.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Description,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [scriptblock]$Action,

        [switch]$PassThru
    )

    $isDryRun = $false
    if ($script:MigrationRun) { $isDryRun = [bool]$script:MigrationRun.DryRun }

    if ($isDryRun) {
        Write-MigrationLog -Message "[DRYRUN] Would: $Description" -Level WARNING
        return $null
    }

    Write-MigrationLog -Message $Description -Level INFO
    try {
        $result = & $Action
    }
    catch {
        Write-MigrationLog -Message "Failed: $Description - $($_.Exception.Message)" -Level ERROR
        throw
    }

    if ($PassThru) { return $result }
}
