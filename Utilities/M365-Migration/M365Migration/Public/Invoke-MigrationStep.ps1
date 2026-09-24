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
        reader of the workspace needs to know. That line's DryRun and Wave come from the driver
        object, which took them from the arguments it emitted - the ledger describes the run
        that happened rather than the run a front end thought it was asking for. A caller that
        passes -DryRun or -Wave is asserting agreement, and a disagreement is refused before the
        child starts.

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
        The waves this run was limited to. Checked against the driver's own -Wave and refused
        before the child starts if the two disagree; the ledger records the driver's.

    .PARAMETER DryRun
        Asserts that this is a rehearsal. The driver decides - it is the file that carries
        -DryRun - and a caller that says otherwise is refused before the child starts, because
        a ledger line recording a live run as a rehearsal is what the DryRunFirst gate reads
        the next time somebody asks whether the step was practised.

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

        Start-Process redirection holds the run's stdout.txt and stderr.txt open for the life of
        the session: two file handles per run that are not released when the child exits
        (observed on macOS, and inherent to redirecting to files rather than to captured
        streams). A workbench session that runs the whole 17-step runbook several times over
        therefore accumulates handles until it closes - well inside any per-process limit, but
        worth knowing before the run folder is deleted or moved while the workbench is open.
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

    # The ledger records the mode and the waves the driver will actually run with, not the ones
    # the caller believes it asked for. A front end that resolved for a rehearsal and then told
    # the runner 'live' - or the other way round - would leave one line in the only account of
    # the run that outlives the workspace's files, and it would be the wrong one.
    $driverDryRun = [bool](Get-MigrationProperty -InputObject $Driver -Name 'DryRun' -Default $false)
    $driverWave = @(Get-MigrationProperty -InputObject $Driver -Name 'Wave' -Default @())

    # A disagreement is a bug in the caller, and it is fatal before the child starts rather than
    # a warning afterwards: by the time the run has happened the damage - a live writer recorded
    # as a rehearsal, wave 3 recorded as wave 1 - is already in the tenant.
    if ($PSBoundParameters.ContainsKey('DryRun') -and ([bool]$DryRun -ne $driverDryRun)) {
        throw ("The driver runs this step as $(if ($driverDryRun) { 'a rehearsal' } else { 'a live run' }) " +
            "and the caller asked for it to be recorded as $(if ($DryRun) { 'a rehearsal' } else { 'a live run' }). " +
            'Resolve the arguments for the mode you are running.')
    }
    if ($PSBoundParameters.ContainsKey('Wave')) {
        $callerKey = Get-MigrationWaveKey -Wave @($Wave)
        if ($callerKey -ne (Get-MigrationWaveKey -Wave $driverWave)) {
            throw ("The driver runs this step for wave(s) '$($driverWave -join ', ')' and the caller asked " +
                "for '$(@($Wave | Where-Object { $_ }) -join ', ')' to be recorded. Resolve the arguments " +
                'for the waves you are running.')
        }
    }

    $runFolder = [string]$Driver.RunFolder
    $stdoutPath = Join-Path $runFolder 'stdout.txt'
    $stderrPath = Join-Path $runFolder 'stderr.txt'

    $writer = if ($PSBoundParameters.ContainsKey('OutputWriter')) { $OutputWriter }
    else { { param($Line) Write-Host $Line } }

    # The pwsh the driver was written for, which is the one the workbench is running in: a
    # workbench started from 7.4 must not hand its step to whatever 'pwsh' is on PATH. It is a
    # field on the driver object rather than something parsed back out of the display command
    # line, which is quoted for reading and cannot be split on reliably.
    $executable = [string](Get-MigrationProperty -InputObject $Driver -Name 'PwshPath' -Default '')
    if (-not $executable) { $executable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }

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

    # Which front-end scriptblocks have already thrown. A hashtable rather than three variables
    # because the drain below mutates it from inside a nested scope.
    $broken = @{ OutputWriter = $false; Pump = $false; CancelIf = $false }

    # Takes its offsets as references so the loop and the final read share one position in each
    # file; everything else it needs is read from the enclosing scope.
    $drain = {
        param([ref]$OutOffset, [ref]$ErrOffset, [switch]$Final)
        foreach ($line in @(Read-MigrationFileTail -Path $stdoutPath -Offset $OutOffset -Flush:$Final)) {
            # Collected whatever the writer does with it: the tenant scan below reads these.
            $stdoutLines.Add($line)
            Invoke-MigrationStepSeam -Name 'OutputWriter' -Seam $writer -Argument @($line) -State $broken | Out-Null
        }
        foreach ($line in @(Read-MigrationFileTail -Path $stderrPath -Offset $ErrOffset -Flush:$Final)) {
            Invoke-MigrationStepSeam -Name 'OutputWriter' -Seam $writer -Argument @("  ! $line") `
                -State $broken | Out-Null
        }
    }

    $stdoutOffset = [long]0
    $stderrOffset = [long]0
    $aborted = $false
    $started = Get-Date
    $result = $null

    $process = Start-Process @startParameters
    try {
        while (-not $process.HasExited) {
            [System.Threading.Thread]::Sleep($PollMilliseconds)
            & $drain ([ref]$stdoutOffset) ([ref]$stderrOffset)

            if ($PSBoundParameters.ContainsKey('Pump')) {
                Invoke-MigrationStepSeam -Name 'Pump' -Seam $Pump -State $broken | Out-Null
            }

            if ($PSBoundParameters.ContainsKey('CancelIf') -and
                [bool](Invoke-MigrationStepSeam -Name 'CancelIf' -Seam $CancelIf -State $broken)) {

                # The child can finish while the loop is asleep, and then there is nothing to
                # cancel: recording that as an abort would tell the next reader of the
                # workspace that a step which completed never ran.
                if ($process.HasExited) { break }

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
        # Everything from here runs even if the loop threw, because the two things that must
        # never be skipped are killing a child nobody is watching any more and recording that
        # the run happened at all.
        if (-not $process.HasExited) {
            try { $process.Kill($true) }
            catch { Write-Warning "The run could not be killed cleanly: $($_.Exception.Message)" }
            [void]$process.WaitForExit(5000)
        }

        # The child can exit between two polls, and its last line can arrive without a newline.
        & $drain ([ref]$stdoutOffset) ([ref]$stderrOffset) -Final

        $ended = Get-Date

        $exitCode = $null
        try { $exitCode = [int]$process.ExitCode }
        catch { $exitCode = $null }
        # A killed process on some platforms reports no exit code at all; 130 is the shell's
        # own word for "interrupted", which is what happened.
        if ($null -eq $exitCode -and $aborted) { $exitCode = 130 }

        $meaning = 'See the log'
        if ($null -ne $exitCode) {
            $codes = Get-MigrationProperty -InputObject $Step -Name 'ExitCodes' -Default @{}
            $named = Get-MigrationProperty -InputObject $codes -Name ([string]$exitCode) -Default ''
            if ($named) { $meaning = [string]$named }
        }
        if ($aborted) { $meaning = 'Aborted by the operator' }

        # The connection lines Connect-MigrationGraph, -Exchange and -Teams print, whether the
        # session was opened now or reused from an earlier step in the same process. GUIDs are
        # lowercased on the way in: the same tenant written two ways is one tenant.
        $tenantPatterns = @(
            'Connected to (?:Microsoft Graph|Exchange Online|Microsoft Teams).*?tenant ([0-9a-f-]{36})',
            'Reusing the (?:existing|cached) .*?session for tenant ([0-9a-f-]{36})'
        )
        $connected = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $stdoutLines) {
            foreach ($pattern in $tenantPatterns) {
                if ($line -notmatch $pattern) { continue }
                $guid = ([string]$Matches[1]).ToLowerInvariant()
                if (-not $connected.Contains($guid)) { $connected.Add($guid) }
            }
        }

        $tenantVerified = $null
        if ($ExpectedTenantId) {
            $expected = $ExpectedTenantId.Trim().ToLowerInvariant()
            $wrong = @($connected | Where-Object { $_ -ne $expected })
            $tenantVerified = ($connected.Count -gt 0) -and ($wrong.Count -eq 0)
        }

        # Offline steps take the workspace label too, so every step has one output folder.
        $fixed = Get-MigrationProperty -InputObject $Step -Name 'Fixed' -Default @{}
        $prefix = [string](Get-MigrationProperty -InputObject $fixed -Name 'Prefix' -Default '')
        if (-not $prefix) {
            $prefix = [string](Get-MigrationProperty -InputObject $Workspace -Name 'Label' -Default '')
        }
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
        # machines, and an absolute path from somebody else's laptop tells the next reader
        # nothing.
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
            DryRun         = $driverDryRun
            Wave           = @($driverWave)
            ExitCode       = $exitCode
            Meaning        = $meaning
            Aborted        = $aborted
            TenantVerified = $tenantVerified
            GateOverrides  = @($GateOverrides | Where-Object { $_ })
            Driver         = (& $relative $driverPath)
            Files          = @(@($produced.Files) | ForEach-Object { & $relative $_ })
            Summary        = $summary
        }

        # A ledger that cannot be written is worth a warning, never the run's exception: the
        # caller still gets the result, and LedgerEntry still says what would have been recorded.
        try {
            Add-MigrationRunLedgerEntry -Path (Join-Path $workspacePath 'Workbench' 'Runs.jsonl') `
                -Entry $entry | Out-Null
        }
        catch {
            Write-Warning "The run could not be recorded in the ledger: $($_.Exception.Message)"
        }

        $result = [pscustomobject]@{
            RunId              = [string]$Driver.RunId
            StepId             = [string]$Step.Id
            ExitCode           = $exitCode
            Meaning            = $meaning
            Aborted            = $aborted
            Started            = $started
            Ended              = $ended
            StdoutPath         = $stdoutPath
            StderrPath         = $stderrPath
            ExpectedTenantId   = [string]$ExpectedTenantId
            ConnectedTenantIds = $connected.ToArray()
            TenantVerified     = $tenantVerified
            Files              = @($produced.Files)
            Summary            = $produced.Summary
            LedgerEntry        = [pscustomobject]$entry
        }
    }

    return $result
}
