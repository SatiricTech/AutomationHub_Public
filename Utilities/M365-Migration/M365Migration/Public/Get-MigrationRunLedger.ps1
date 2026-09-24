function Get-MigrationRunLedger {
    <#
    .SYNOPSIS
        Reads a workspace's run ledger, newest run first.

    .DESCRIPTION
        Workbench/Runs.jsonl holds one line per run (Docs/Workbench-Design.md, section 7.4).
        This is the "Results & logs" view's source, and it orders by Started descending because
        that is the question an operator asks of it - what happened last, and did it work.

        A line that is not valid JSON becomes a warning and is skipped. An operator who opened
        the ledger in an editor, or a run killed mid-append, must cost one line rather than the
        whole history: the ledger is also what the scanner and the DryRunFirst gate read, and
        losing all of it would quietly turn a migration in progress into one that looks like it
        never started.

        Runs are stamped to the second, which is also what names their folders, so two runs
        cannot share a moment in practice; where they do, the order they were appended in
        decides, which is the order they actually happened.

    .PARAMETER Workspace
        The workspace scan from Get-MigrationWorkspace, or any object carrying its Path.

    .EXAMPLE
        Get-MigrationRunLedger -Workspace $ws | Select-Object Started, StepId, ExitCode, Meaning

        Lists the workspace's runs newest first, as the results view shows them.

    .EXAMPLE
        (Get-MigrationRunLedger -Workspace $ws | Where-Object StepId -eq 'New-Users')[0].TenantVerified

        Answers whether the last provisioning run reached the tenant it was meant to.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace
    )

    $workspacePath = [string]$Workspace.Path
    if (-not $workspacePath) { throw 'The workspace has no Path; there is no ledger to read.' }

    $result = Get-MigrationRunLedgerEntry -Path (Join-Path $workspacePath 'Workbench' 'Runs.jsonl')
    foreach ($warning in @($result.Warnings)) { Write-Warning $warning }

    return @(@($result.Entries) | Sort-Object -Property Started, LineNumber -Descending)
}
