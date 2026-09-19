function Invoke-MigrationStep {
    <#
    .SYNOPSIS
        Runs a generated driver in a child pwsh, streams its output, and records the run.

    .DESCRIPTION
        One step, one child process (Docs/Workbench-Design.md, section 7.3). The toolkit's
        scripts call exit at top level, re-import the module and hold process-global Graph,
        Exchange and Teams sessions, so they cannot be dot-sourced into the workbench: they get
        their own process, started from the same pwsh the workbench is running in.

        Output is polled, not awaited. Start-Process writes stdout and stderr to files in the
        run folder and this function reads whatever is new every -PollMilliseconds, hands each
        complete line to -OutputWriter and then calls -Pump. That shape exists for the WinForms
        front end: -Wait would block the UI thread and Windows would grey the window out as
        "Not Responding" for the whole run, while the events on Process (OutputDataReceived)
        need a runspace pumping them and have been unreliable under WinForms. Redirect files
        also catch what a script writes through Write-Host, which captured streams do not -
        and the toolkit logger writes through Write-Host by design.

        Nothing here knows what a form is. -OutputWriter, -Pump and -CancelIf are the three
        seams the two front ends fill in: the console passes a writer that is Write-Host and no
        pump at all; WinForms passes one that appends to the log pane, a pump that is
        DoEvents, and a cancel that reads its own button.

        Tenant verification is post-run and evidence-based. The connection lines the toolkit's
        Connect-* functions print carry the tenant GUID they actually reached, so they are read
        back out of stdout and compared with -ExpectedTenantId. No line at all when a tenant was
        expected is a failure, not a pass: a step that was supposed to sign in and printed
        nothing has proved nothing about where it wrote.

        Secrets never reach the driver file. -Environment sets variables on the child process
        only - they exist for the life of that process and are not visible to the parent, to
        another step, or to anyone reading the workspace afterwards. That is how Viva Learning's
        client secret is passed.

        Every run appends one line to Workbench/Runs.jsonl, whatever the exit code and even
        when it was aborted, because "this was tried and killed" is exactly what the next
        reader of the workspace needs to know.

    .PARAMETER Step
        The step instance from Get-MigrationStep.

    .PARAMETER Driver
        The result of New-MigrationStepDriver: the run id, folder, driver path and command line.

    .PARAMETER Workspace
        The workspace scan from Get-MigrationWorkspace. The child's working directory.

    .PARAMETER ExpectedTenantId
        The tenant the step's side should reach. Omit it and TenantVerified comes back $null.

    .PARAMETER OutputWriter
        Called with one line of child output at a time. Defaults to Write-Host. Lines from
        stderr arrive prefixed with '  ! '.

    .PARAMETER Pump
        Called once per poll, after the output. The WinForms message pump goes here.

    .PARAMETER Environment
        Environment variables for the child process only.

    .PARAMETER PollMilliseconds
        How often to read new output and check for cancellation. 250 ms by default.

    .PARAMETER CancelIf
        Called once per poll; when it returns true the process tree is killed and the run is
        recorded as aborted.

    .PARAMETER GateOverrides
        The soft gates the operator chose to override, recorded in the ledger.

    .PARAMETER Wave
        The waves this run was limited to, recorded in the ledger.

    .PARAMETER DryRun
        Records the run as a rehearsal. The driver already carries -DryRun; this is what makes
        the ledger say so, which is what the DryRunFirst gate reads later.

    .EXAMPLE
        Invoke-MigrationStep -Step $step -Driver $driver -Workspace $ws -ExpectedTenantId $guid

        Runs the step, printing its output as it happens, and returns the run result.

    .EXAMPLE
        $lines = [System.Collections.Generic.List[string]]::new()
        Invoke-MigrationStep -Step $step -Driver $driver -Workspace $ws -OutputWriter {
            param($Line) $lines.Add($Line) }

        Collects the output instead of printing it - the shape both front ends use.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The default writer is the console front end: child output is the run, not a return value.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Step,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Driver,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [AllowEmptyString()]
        [string]$ExpectedTenantId,

        [ValidateNotNull()]
        [scriptblock]$OutputWriter,

        [ValidateNotNull()]
        [scriptblock]$Pump,

        [AllowNull()]
        [hashtable]$Environment,

        [ValidateRange(10, 60000)]
        [int]$PollMilliseconds = 250,

        [ValidateNotNull()]
        [scriptblock]$CancelIf,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$GateOverrides,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Wave,

        [switch]$DryRun
    )

    $workspacePath = [string]$Workspace.Path
    if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) {
        throw "The workspace folder '$workspacePath' does not exist; nothing can be run against it."
    }

    $driverPath = [string]$Driver.DriverPath
    if (-not (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
        throw "The driver '$driverPath' is not on disk; generate it with New-MigrationStepDriver first."
    }

    $runFolder = [string]$Driver.RunFolder
    $stdoutPath = Join-Path $runFolder 'stdout.txt'
    $stderrPath = Join-Path $runFolder 'stderr.txt'

    $writer = if ($PSBoundParameters.ContainsKey('OutputWriter')) { $OutputWriter }
    else { { param($Line) Write-Host $Line } }

    # The pwsh the driver was written for, which is the one the workbench is running in: a
    # workbench started from 7.4 must not hand its step to whatever 'pwsh' is on PATH.
    $executable = [string]$Driver.CommandLine
    $split = $executable.IndexOf(' -NoProfile')
    $executable = if ($split -gt 0) { $executable.Substring(0, $split) }
    else { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }

    # Start-Process joins ArgumentList with spaces and quotes nothing, so the one argument that
    # can hold a space is quoted here.
    $argumentList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        ('"{0}"' -f $driverPath))

    $startParameters = @{
        FilePath               = $executable
        ArgumentList           = $argumentList
        PassThru               = $true
        NoNewWindow            = $true
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError  = $stderrPath
        WorkingDirectory       = $workspacePath
        ErrorAction            = 'Stop'
    }
    if ($Environment -and $Environment.Count -gt 0) { $startParameters['Environment'] = $Environment }

    $stdoutLines = [System.Collections.Generic.List[string]]::new()

    # Takes its offsets as references so the loop and the final read share one position in each
    # file; everything else it needs is read from the enclosing scope.
    $drain = {
        param([ref]$OutOffset, [ref]$ErrOffset, [switch]$Final)
        foreach ($line in @(Read-MigrationFileTail -Path $stdoutPath -Offset $OutOffset -Flush:$Final)) {
            $stdoutLines.Add($line)
            & $writer $line
        }
        foreach ($line in @(Read-MigrationFileTail -Path $stderrPath -Offset $ErrOffset -Flush:$Final)) {
            & $writer "  ! $line"
        }
    }

    $stdoutOffset = [long]0
    $stderrOffset = [long]0
    $aborted = $false
    $started = Get-Date

    $process = Start-Process @startParameters
    try {
        while (-not $process.HasExited) {
            [System.Threading.Thread]::Sleep($PollMilliseconds)
            & $drain ([ref]$stdoutOffset) ([ref]$stderrOffset)
            if ($PSBoundParameters.ContainsKey('Pump')) { & $Pump }

            if ($PSBoundParameters.ContainsKey('CancelIf') -and [bool](& $CancelIf)) {
                $aborted = $true
                # The whole tree: a step that has started EXO or Teams has children of its own.
                try { $process.Kill($true) }
                catch { Write-Warning "The run could not be killed cleanly: $($_.Exception.Message)" }
                break
            }
        }

        # A killed process is waited for with a bound: a front end must never hang on a child
        # that refuses to die, and five seconds is far longer than a kill takes to land.
        if ($aborted) { [void]$process.WaitForExit(5000) } else { $process.WaitForExit() }
    }
    finally {
        # The child can exit between two polls, and its last line can arrive without a newline.
        & $drain ([ref]$stdoutOffset) ([ref]$stderrOffset) -Final
    }

    $ended = Get-Date

    $exitCode = $null
    try { $exitCode = [int]$process.ExitCode }
    catch { $exitCode = $null }
    # A killed process on some platforms reports no exit code at all; 130 is the shell's own
    # word for "interrupted", which is what happened.
    if ($null -eq $exitCode -and $aborted) { $exitCode = 130 }

    $meaning = 'See the log'
    if ($null -ne $exitCode) {
        $codes = Get-MigrationProperty -InputObject $Step -Name 'ExitCodes' -Default @{}
        $named = Get-MigrationProperty -InputObject $codes -Name ([string]$exitCode) -Default ''
        if ($named) { $meaning = [string]$named }
    }
    if ($aborted) { $meaning = 'Aborted by the operator' }

    # The connection lines Connect-MigrationGraph, -Exchange and -Teams print, whether the
    # session was opened now or reused from an earlier step in the same process.
    $tenantPatterns = @(
        'Connected to (?:Microsoft Graph|Exchange Online|Microsoft Teams).*?tenant ([0-9a-f-]{36})',
        'Reusing the (?:existing|cached) .*?session for tenant ([0-9a-f-]{36})'
    )
    $connected = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $stdoutLines) {
        foreach ($pattern in $tenantPatterns) {
            if ($line -match $pattern -and -not $connected.Contains($Matches[1])) { $connected.Add($Matches[1]) }
        }
    }

    $tenantVerified = $null
    if ($ExpectedTenantId) {
        $expected = $ExpectedTenantId.Trim().ToLowerInvariant()
        $wrong = @($connected | Where-Object { $_.ToLowerInvariant() -ne $expected })
        $tenantVerified = ($connected.Count -gt 0) -and ($wrong.Count -eq 0)
    }

    # Offline steps take the workspace label too, so every step has exactly one output folder.
    $fixed = Get-MigrationProperty -InputObject $Step -Name 'Fixed' -Default @{}
    $prefix = [string](Get-MigrationProperty -InputObject $fixed -Name 'Prefix' -Default '')
    if (-not $prefix) { $prefix = [string](Get-MigrationProperty -InputObject $Workspace -Name 'Label' -Default '') }
    if (-not $prefix) { $prefix = Split-Path -Path $workspacePath -Leaf }
    $produced = Get-MigrationRunArtefact -Folder (Join-Path $workspacePath $prefix) -Since $started

    $summary = $null
    if ($produced.Summary) {
        $summary = [ordered]@{
            Succeeded = $produced.Summary.Succeeded
            Failed    = $produced.Summary.Failed
            Skipped   = $produced.Summary.Skipped
            Planned   = $produced.Summary.Planned
        }
    }

    # Paths are recorded relative to the workspace: the folder is synced and copied between
    # machines, and an absolute path from somebody else's laptop tells the next reader nothing.
    $relative = {
        param([string]$FullPath)
        return ([System.IO.Path]::GetRelativePath($workspacePath, $FullPath) -replace '\\', '/')
    }

    $entry = [ordered]@{
        Started        = $started.ToString('s')
        Ended          = $ended.ToString('s')
        StepId         = [string]$Step.Id
        Script         = [string]$Step.Script
        Side           = [string]$Step.Side
        TenantId       = [string]$ExpectedTenantId
        DryRun         = [bool]$DryRun
        Wave           = @($Wave | Where-Object { $_ })
        ExitCode       = $exitCode
        Meaning        = $meaning
        Aborted        = $aborted
        TenantVerified = $tenantVerified
        GateOverrides  = @($GateOverrides | Where-Object { $_ })
        Driver         = (& $relative $driverPath)
        Files          = @(@($produced.Files) | ForEach-Object { & $relative $_ })
        Summary        = $summary
    }

    Add-MigrationRunLedgerEntry -Path (Join-Path $workspacePath 'Workbench' 'Runs.jsonl') -Entry $entry | Out-Null

    return [pscustomobject]@{
        RunId              = [string]$Driver.RunId
        StepId             = [string]$Step.Id
        ExitCode           = $exitCode
        Meaning            = $meaning
        Aborted            = $aborted
        Started            = $started
        Ended              = $ended
        StdoutPath         = $stdoutPath
        StderrPath         = $stderrPath
        ConnectedTenantIds = $connected.ToArray()
        TenantVerified     = $tenantVerified
        Files              = @($produced.Files)
        Summary            = $produced.Summary
        LedgerEntry        = [pscustomobject]$entry
    }
}
