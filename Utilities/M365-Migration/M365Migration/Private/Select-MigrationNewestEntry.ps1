function Select-MigrationNewestEntry {
    <#
    .SYNOPSIS
        Returns the most recent of a set of run-ledger entries.

    .DESCRIPTION
        "The newest run of this step" decides a step's exit code, its TenantVerified flag and
        which instance owns a shared results file, so it has to be one answer and always the
        same answer. Entries sort by Started, and by their position in the ledger when two
        runs share a second - the ledger is append-only, so a later line is a later run. An
        entry whose Started did not parse sorts oldest rather than being dropped: it is still
        evidence that something ran.

    .PARAMETER Entry
        The entries to choose between, as Get-MigrationRunLedgerEntry returns them.

    .EXAMPLE
        Select-MigrationNewestEntry -Entry $ledger.Entries

        Returns the last run recorded in the ledger.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entry
    )

    return @($Entry | Sort-Object -Property @{
            Expression = { if ($null -ne $_.Started) { $_.Started } else { [datetime]::MinValue } }
            Descending = $true
        }, @{ Expression = 'LineNumber'; Descending = $true }) | Select-Object -First 1
}
