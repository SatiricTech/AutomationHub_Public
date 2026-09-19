function Get-MigrationRunArtefact {
    <#
    .SYNOPSIS
        Lists what a run left in the step's folder, and summarises its newest results file.

    .DESCRIPTION
        After a child process exits, the workbench has to answer "what did that produce?" - for
        the run panel, for the ledger, and for the folder scanner that reads the ledger later
        (Docs/Workbench-Design.md, sections 6 and 7.3).

        Every step writes into one folder: the prefix its instance fixes (Source, Destination,
        Post) or, for everything else, the workspace label. A file belongs to this run when the
        timestamp in its name is at or after the moment the run started - names, never
        mtimes, because a sync client (OneDrive, Egnyte) rewrites mtimes and would otherwise
        hand this run a file from last week. The one exception is the log, which a script opens
        at the start and appends to throughout: a '.log' touched since the run began is this
        run's log whatever its name says.

        Started is compared truncated to the second, because that is all the filename carries:
        a run that began at 10:20:00.7 writes 10:20:00, and must not then disown its own file.

        The summary is the newest results file's status counts - and only the Status column is
        ever read (Get-MigrationResultSummary), so a provisioning run's generated passwords are
        never touched by the workbench.

    .PARAMETER Folder
        The step's output folder.

    .PARAMETER Since
        When the run started.

    .EXAMPLE
        Get-MigrationRunArtefact -Folder (Join-Path $ws 'Contoso') -Since $started

        Returns { Files; Summary } for whatever the run just wrote.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Folder,

        [Parameter(Mandatory)]
        [datetime]$Since
    )

    $empty = [pscustomobject]@{ Files = @(); Summary = $null }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $empty }

    $threshold = [datetime]::new($Since.Year, $Since.Month, $Since.Day, $Since.Hour, $Since.Minute, $Since.Second)

    $produced = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue)) {
        $parsed = ConvertFrom-MigrationOutputPath -Path $file.Name
        $isRunFile = ($null -ne $parsed) -and ($parsed.Timestamp -ge $threshold)
        $isLiveLog = ($file.Extension -eq '.log') -and ($file.LastWriteTime -ge $threshold)
        if (-not $isRunFile -and -not $isLiveLog) { continue }

        $produced.Add([pscustomobject]@{ Path = $file.FullName; Parsed = $parsed })
    }

    if ($produced.Count -eq 0) { return $empty }

    $results = @($produced |
            Where-Object { $null -ne $_.Parsed -and $_.Parsed.Suffix -in @('Results', 'DryRun') -and
                $_.Parsed.Extension -eq 'csv' } |
            Sort-Object -Property { $_.Parsed.Timestamp } -Descending)

    $summary = $null
    if ($results.Count -gt 0) {
        try { $summary = Get-MigrationResultSummary -Path $results[0].Path }
        catch {
            # A results file that cannot be read costs the summary, not the run: the file is
            # on disk and named in Files either way, which is what the operator needs to see.
            Write-Warning ("The results file '$([System.IO.Path]::GetFileName($results[0].Path))' " +
                "could not be summarised: $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        Files   = @($produced | ForEach-Object { $_.Path } | Sort-Object)
        Summary = $summary
    }
}
