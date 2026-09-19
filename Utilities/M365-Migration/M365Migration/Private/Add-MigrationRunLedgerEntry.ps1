function Add-MigrationRunLedgerEntry {
    <#
    .SYNOPSIS
        Appends one run to Workbench/Runs.jsonl and returns the line it wrote.

    .DESCRIPTION
        The ledger is the workbench's memory (Docs/Workbench-Design.md, section 7.4): the
        folder scanner reads it to decide what state a step is in, the DryRunFirst gate reads
        it to decide whether a rehearsal happened, and the results view lists it. It is JSON
        Lines - one compact object per line - precisely because it is appended to by a process
        that may be killed: a half-written line costs its own line and nothing else, which is
        the contract Get-MigrationRunLedgerEntry reads under.

        UTF-8 without a byte-order mark, and '\n' rather than the platform newline: the file is
        read back by ConvertFrom-Json line by line, and a BOM would ride along on the first
        line and make exactly that one line unparseable.

    .PARAMETER Path
        The ledger file. Its folder is created if the workspace has never run a step.

    .PARAMETER Entry
        The run record, ordered as section 7.4 lists it.

    .EXAMPLE
        Add-MigrationRunLedgerEntry -Path $ledger -Entry $entry

        Appends the run and returns the JSON that was written.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Collections.IDictionary]$Entry
    )

    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
        New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    }

    # Depth 5 clears the deepest thing a run record holds - the four counts under Summary -
    # with room to spare, and -Compress keeps one run to one line.
    $json = $Entry | ConvertTo-Json -Compress -Depth 5
    [System.IO.File]::AppendAllText($Path, ($json + "`n"), [System.Text.UTF8Encoding]::new($false))

    return $json
}
