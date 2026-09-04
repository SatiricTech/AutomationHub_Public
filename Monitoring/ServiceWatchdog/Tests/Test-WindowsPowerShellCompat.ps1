#Requires -Version 7.4
using namespace System.Management.Automation.Language

<#
.SYNOPSIS
    Scans PowerShell scripts for constructs that Windows PowerShell 5.1 cannot run.

.DESCRIPTION
    Development-time static analysis tool for the ServiceWatchdog project. Parses one file,
    or every .ps1/.psm1 file under a folder, with the PowerShell language parser
    ([System.Management.Automation.Language.Parser]::ParseFile) and walks the resulting AST
    for constructs that require PowerShell 6/7 and therefore cannot run on Windows
    PowerShell 5.1, which is what Windows Server ships and what the ServiceWatchdog worker
    and its Task Scheduler registration scripts must target (DESIGN.md section 4.1):

      - Ternary operator                              $a ? 1 : 2
      - Null-coalescing operator / assignment          $a ?? $b   / $a ??= $b
      - Null-conditional member/index access           $a?.Prop   / $a?[0]
        Both the correct syntax (requires bracing the variable name: ${a}?.Prop) and the
        common unbraced typo ($a?.Prop, which PowerShell instead parses as a variable
        literally named "a?") are flagged, because the unbraced form is what a developer
        who does not know about the bracing requirement will actually type, and it is
        exactly as broken on Windows PowerShell 5.1 as the intended construct would be.
      - Pipeline chain operators                       cmd1 && cmd2 / cmd1 || cmd2
      - ForEach-Object -Parallel
      - Invoke-RestMethod / Invoke-WebRequest -SslProtocol, -MaximumRetryCount,
        -RetryIntervalSec, or -SkipHttpErrorCheck
      - Join-Path with more than two positional arguments (the -AdditionalChildPath
        parameter set, added in PowerShell 6)
      - #Requires -Version greater than 5.1
      - The .StartType property on a service object (Get-Service does not expose it until
        PowerShell 6; 5.1 callers must use Get-CimInstance Win32_Service or the registry)

    This is a read-only analysis tool. It never modifies the files it scans and performs no
    other mutation, so -DryRun has no effect on its behavior beyond a log entry; it is
    accepted for interface consistency with the rest of the ServiceWatchdog script family.

    CALLER CONTRACT
    Two invocation styles are supported and behave differently on purpose:
      - Without -PassThru: findings are printed one per line as "path:line: message" and
        the script calls `exit` (1 if any finding exists, 0 if the file(s) scanned are
        5.1-safe, 2 if -Path could not be resolved to a file or folder). Because `exit`
        terminates the current process, use this mode only when the checker is the last
        thing running in that process - typically `pwsh -File Test-WindowsPowerShellCompat.ps1
        -Path <target>` as a standalone build/CI step.
      - With -PassThru: finding objects (one [pscustomobject] per finding, with Path, Line,
        Rule, and Message properties) are returned to the pipeline and the script does NOT
        call `exit` - an unresolvable -Path throws instead. This is the safe mode for
        another script or Pester test to call in-process with the call operator
        (`& Test-WindowsPowerShellCompat.ps1 -Path <target> -PassThru`) without risking its
        own session being torn down by an `exit` inside the callee.

.PARAMETER Path
    A single script file, or a folder to scan recursively for *.ps1 and *.psm1 files.

.PARAMETER PassThru
    Return finding objects instead of printing "path:line: message" lines, and never call
    `exit` - see CALLER CONTRACT above.

.PARAMETER Verbosity
    Console output level for the tool's own Write-Log operational messages (not the
    findings themselves, which are always printed regardless of verbosity when -PassThru is
    not specified). Valid values: Low, Medium, High. Low shows only errors and the final
    success/failure summary; Medium adds warnings; High shows every file scanned.

.PARAMETER DryRun
    Accepted for interface consistency with the rest of the ServiceWatchdog script family.
    This tool performs no mutations, so scan results and the exit code are identical with
    or without -DryRun; only a log entry differs.

.PARAMETER LogPath
    Path to the log file. Defaults to
    $env:ProgramData\ServiceWatchdog\Logs\Test-WindowsPowerShellCompat-<timestamp>.log
    (or the platform temp directory when $env:ProgramData is not set, e.g. when this
    cross-platform dev tool is run on macOS/Linux).

.EXAMPLE
    .\Test-WindowsPowerShellCompat.ps1 -Path ..\Endpoint\Invoke-WinServiceWatchdog.ps1

    Scans a single file. Prints one "path:line: message" line per finding and exits 1 if
    any exist, 0 otherwise.

.EXAMPLE
    .\Test-WindowsPowerShellCompat.ps1 -Path ..\Endpoint -Verbosity High

    Recursively scans every .ps1/.psm1 file under a folder, with per-file progress logged
    to the console.

.EXAMPLE
    $findings = & .\Test-WindowsPowerShellCompat.ps1 -Path ..\Endpoint -PassThru -DryRun

    In-process usage from another script or test: returns finding objects instead of
    exiting. -DryRun is accepted here too but changes nothing, since the tool never mutates.

.NOTES
    Version : 1.0.0
    Created : 2026-09-04

    Checklist deviations from the powershell-authoring skill (Enterprise tier):
      - 4.6 (log root under $env:ProgramData\$MSPName\Logs): this tool uses
        $env:ProgramData\ServiceWatchdog\Logs instead, matching the product-named log root
        used by every other ServiceWatchdog script (DESIGN.md sections 3 and 4.9) rather
        than introducing the generic $MSPName placeholder into a project that is otherwise
        entirely MSP-name-agnostic.
      - -DryRun / Invoke-Action: this is a read-only static-analysis tool with no mutating
        actions to wrap, so Invoke-Action is not implemented. -DryRun is still accepted (see
        .PARAMETER DryRun) so the parameter surface matches the rest of the project.
      - Write-Log console sink: the templates.md Write-Log writes its console line with
        Write-Host, which lands on the process's stdout. This tool's stdout is a parseable
        interface (one "path:line: message" line per finding - see CALLER CONTRACT), so
        Write-Log here writes its console line to stderr ([Console]::Error.WriteLine)
        instead, keeping every non-finding line off stdout. Level, verbosity gating, and the
        file log (which always receives every message) are unchanged.

    Developed with AI assistance (Claude); reviewed before publication.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [switch]$PassThru,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Low',

    [string]$LogPath
)

#region Configuration & Constants

$ErrorActionPreference = 'Stop'
$script:Verbosity = $Verbosity
$scriptStartTime = Get-Date

# Product-named log root (see .NOTES checklist deviation 4.6) with a cross-platform
# fallback, because this dev tool also runs on macOS/Linux where $env:ProgramData is unset.
if (-not $LogPath) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
    $logRootBase = if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }
    $logRoot = Join-Path $logRootBase 'ServiceWatchdog' 'Logs'
    $LogPath = Join-Path $logRoot "$scriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}
$script:LogPath = $LogPath

try {
    $logDir = Split-Path -Path $script:LogPath -Parent
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
}
catch {
    Write-Warning "Could not create log directory for '$($script:LogPath)': $_. Continuing without file logging."
    $script:LogPath = $null
}

# Web request cmdlet parameters that exist only on PowerShell 6+ (DESIGN.md section 4.1).
$script:CompatWebCmdletParameters = @(
    'SslProtocol',
    'MaximumRetryCount',
    'RetryIntervalSec',
    'SkipHttpErrorCheck'
)

# Shared suffixes so every finding message stays short enough to read on one console line.
$script:Ps7Suffix = 'requires PowerShell 7+; not available in Windows PowerShell 5.1.'
$script:Ps6Suffix = 'requires PowerShell 6+; not available in Windows PowerShell 5.1.'

#endregion

#region Helper Functions

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logMessage = "[$timestamp] [$Level] $Message"

    $writeToConsole = switch ($script:Verbosity) {
        'Low' { $Level -in 'ERROR', 'SUCCESS' }
        'Medium' { $Level -in 'ERROR', 'WARNING', 'SUCCESS' }
        'High' { $true }
        default { $true }
    }

    if ($writeToConsole) {
        # Written to stderr, not stdout: stdout is reserved for the tool's actual product
        # (the "path:line: message" finding lines), so a caller parsing or capturing stdout
        # never sees operational log noise mixed in with it.
        [Console]::Error.WriteLine($logMessage)
    }

    if ($script:LogPath) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value $logMessage
        }
        catch {
            Write-Warning "Failed to write to log file '$($script:LogPath)': $_"
        }
    }
}

function New-CompatFinding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions',
        '',
        Justification = 'Builds an in-memory object only; no system state changes, so ShouldProcess does not apply.'
    )]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [int]$Line,

        [Parameter(Mandatory)]
        [string]$Rule,

        [Parameter(Mandatory)]
        [string]$Message
    )

    [pscustomobject]@{
        PSTypeName = 'ServiceWatchdog.CompatFinding'
        Path       = $FilePath
        Line       = $Line
        Rule       = $Rule
        Message    = $Message
    }
}

#endregion

#region Main Functions

function Get-CompatTargetFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        return @((Resolve-Path -LiteralPath $TargetPath).ProviderPath)
    }
    elseif (Test-Path -LiteralPath $TargetPath -PathType Container) {
        return @(
            Get-ChildItem -LiteralPath $TargetPath -Recurse -File -Include '*.ps1', '*.psm1' |
                Select-Object -ExpandProperty FullName
        )
    }
    else {
        throw "Path not found: $TargetPath"
    }
}

function Test-CompatNullConditionalTarget {
    # True when $Node's target expression is either the real null-conditional syntax
    # (${a}?.Prop / ${a}?[0], Node.NullConditional -eq $true) or the common unbraced typo
    # ($a?.Prop), which PowerShell instead tokenizes as a variable literally named "a?" -
    # see the .DESCRIPTION note on why both are flagged.
    param (
        [Parameter(Mandatory)]
        [Ast]$Node
    )

    if ($Node.NullConditional) {
        return $true
    }

    $target = $Node.Expression
    return ($target -is [VariableExpressionAst]) -and $target.VariablePath.UserPath.EndsWith('?')
}

function Get-CompatFinding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $findings = [System.Collections.Generic.List[object]]::new()

    $tokens = $null
    $parseErrors = $null
    $ast = [Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($parseError in $parseErrors) {
            $findings.Add((New-CompatFinding -FilePath $FilePath -Line $parseError.Extent.StartLineNumber `
                        -Rule 'ParseError' -Message "Parse error: $($parseError.Message)"))
        }
        return $findings
    }

    # Ternary operator: $a ? 1 : 2
    foreach ($node in $ast.FindAll({ param($n) $n -is [TernaryExpressionAst] }, $true)) {
        $message = "Ternary operator '?:' $script:Ps7Suffix"
        $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                    -Rule 'TernaryOperator' -Message $message))
    }

    # Pipeline chain operators: cmd1 && cmd2 / cmd1 || cmd2
    foreach ($node in $ast.FindAll({ param($n) $n -is [PipelineChainAst] }, $true)) {
        $message = "Pipeline chain operator ('&&' / '||') $script:Ps7Suffix"
        $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                    -Rule 'PipelineChainOperator' -Message $message))
    }

    # Null-coalescing operator: $a ?? $b (parsed as a BinaryExpressionAst).
    foreach ($node in $ast.FindAll({ param($n) $n -is [BinaryExpressionAst] }, $true)) {
        if ($node.Operator -eq [TokenKind]::QuestionQuestion) {
            $message = "Null-coalescing operator '??' $script:Ps7Suffix"
            $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                        -Rule 'NullCoalescingOperator' -Message $message))
        }
    }

    # Null-coalescing assignment operator: $a ??= $b. The PowerShell parser represents this
    # as an AssignmentStatementAst (not a BinaryExpressionAst) whose Operator is
    # QuestionQuestionEquals.
    foreach ($node in $ast.FindAll({ param($n) $n -is [AssignmentStatementAst] }, $true)) {
        if ($node.Operator -eq [TokenKind]::QuestionQuestionEquals) {
            $message = "Null-coalescing assignment operator '??=' $script:Ps7Suffix"
            $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                        -Rule 'NullCoalescingOperator' -Message $message))
        }
    }

    # Null-conditional member access: $a?.Prop / ${a}?.Prop (also covers method calls via
    # InvokeMemberExpressionAst, which derives from MemberExpressionAst).
    foreach ($node in $ast.FindAll({ param($n) $n -is [MemberExpressionAst] }, $true)) {
        if (Test-CompatNullConditionalTarget -Node $node) {
            $message = "Null-conditional member access ('?.') requires PowerShell 7.1+; " +
                'not available in Windows PowerShell 5.1.'
            $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                        -Rule 'NullConditionalMember' -Message $message))
        }

        if ($node.Member -is [StringConstantExpressionAst] -and $node.Member.Value -ieq 'StartType') {
            $message = "The 'StartType' property is not on Get-Service in Windows PowerShell 5.1; " +
                'use Get-CimInstance Win32_Service or the registry instead.'
            $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                        -Rule 'ServiceStartTypeProperty' -Message $message))
        }
    }

    # Null-conditional index access: $a?[0] / ${a}?[0]
    foreach ($node in $ast.FindAll({ param($n) $n -is [IndexExpressionAst] }, $true)) {
        if (Test-CompatNullConditionalTarget -Node $node) {
            $message = "Null-conditional index access ('?[]') requires PowerShell 7.1+; " +
                'not available in Windows PowerShell 5.1.'
            $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                        -Rule 'NullConditionalIndex' -Message $message))
        }
    }

    # Command-level checks: ForEach-Object -Parallel, Invoke-RestMethod/-WebRequest 6+-only
    # parameters, and Join-Path with more than two positional arguments.
    foreach ($node in $ast.FindAll({ param($n) $n -is [CommandAst] }, $true)) {
        $commandName = $node.GetCommandName()
        if (-not $commandName) {
            continue
        }

        $namedParameters = $node.CommandElements | Where-Object { $_ -is [CommandParameterAst] }

        if ($commandName -ieq 'ForEach-Object') {
            if ($namedParameters | Where-Object { $_.ParameterName -ieq 'Parallel' }) {
                $message = "'ForEach-Object -Parallel' $script:Ps7Suffix"
                $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                            -Rule 'ForEachObjectParallel' -Message $message))
            }
        }
        elseif ($commandName -iin @('Invoke-RestMethod', 'Invoke-WebRequest')) {
            foreach ($paramNode in $namedParameters) {
                if ($script:CompatWebCmdletParameters -icontains $paramNode.ParameterName) {
                    $message = "'-$($paramNode.ParameterName)' on $commandName $script:Ps6Suffix"
                    $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                                -Rule "WebCmdlet$($paramNode.ParameterName)" -Message $message))
                }
            }
        }
        elseif ($commandName -ieq 'Join-Path') {
            $positionalArguments = $node.CommandElements |
                Select-Object -Skip 1 |
                Where-Object { $_ -isnot [CommandParameterAst] }
            if (@($positionalArguments).Count -gt 2) {
                $message = "Join-Path with more than two positional arguments (-AdditionalChildPath) $script:Ps6Suffix"
                $findings.Add((New-CompatFinding -FilePath $FilePath -Line $node.Extent.StartLineNumber `
                            -Rule 'JoinPathAdditionalChildPath' -Message $message))
            }
        }
    }

    # #Requires -Version greater than 5.1
    $requiredVersion = $ast.ScriptRequirements.RequiredPSVersion
    if ($requiredVersion -and $requiredVersion -gt [version]'5.1') {
        $requiresLine = 1
        try {
            $fileLines = Get-Content -LiteralPath $FilePath
            for ($i = 0; $i -lt $fileLines.Count; $i++) {
                if ($fileLines[$i] -match '^\s*#[Rr]equires\s+-[Vv]ersion') {
                    $requiresLine = $i + 1
                    break
                }
            }
        }
        catch {
            Write-Log "Could not re-read '$FilePath' to locate the #Requires line number: $_" -Level 'WARNING'
        }

        $message = "'#Requires -Version $requiredVersion' declares a PowerShell $requiredVersion+ " +
            'requirement; Windows PowerShell 5.1 refuses to run a script whose #Requires ' +
            'version it does not meet.'
        $findings.Add((New-CompatFinding -FilePath $FilePath -Line $requiresLine `
                    -Rule 'RequiresVersion' -Message $message))
    }

    return $findings
}

function Invoke-WindowsPowerShellCompatScan {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    $targetFiles = Get-CompatTargetFile -TargetPath $TargetPath
    Write-Log "Resolved $($targetFiles.Count) file(s) to scan under '$TargetPath'." -Level 'INFO'

    $allFindings = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $targetFiles) {
        Write-Log "Scanning $file" -Level 'DEBUG'
        foreach ($finding in (Get-CompatFinding -FilePath $file)) {
            $allFindings.Add($finding)
        }
    }

    return $allFindings
}

#endregion

#region Script Body

try {
    $startMessage = "Script started. Path=$Path, Verbosity=$Verbosity, " +
        "DryRun=$($DryRun.IsPresent), PassThru=$($PassThru.IsPresent)"
    Write-Log $startMessage -Level 'INFO'
    if ($DryRun) {
        $dryRunMessage = '[DRYRUN] This tool is read-only; the scan below runs normally ' +
            'because there is nothing to skip.'
        Write-Log $dryRunMessage -Level 'INFO'
    }

    $findings = Invoke-WindowsPowerShellCompatScan -TargetPath $Path

    if ($PassThru) {
        Write-Log "Scan complete: $($findings.Count) finding(s). Returning finding objects via -PassThru." -Level 'INFO'
        $findings
    }
    else {
        foreach ($finding in $findings) {
            "$($finding.Path):$($finding.Line): $($finding.Message)"
        }

        if ($findings.Count -gt 0) {
            Write-Log "Scan complete: $($findings.Count) finding(s)." -Level 'WARNING'
            exit 1
        }
        else {
            Write-Log 'Scan complete: no Windows PowerShell 5.1 compatibility findings.' -Level 'SUCCESS'
            exit 0
        }
    }
}
catch {
    Write-Log "Script failed: $_" -Level 'ERROR'
    if ($PassThru) {
        throw
    }
    exit 2
}
finally {
    $duration = (Get-Date) - $scriptStartTime
    Write-Log "Total duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Level 'INFO'
}

#endregion
