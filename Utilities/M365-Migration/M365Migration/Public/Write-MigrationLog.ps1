function Write-MigrationLog {
    <#
    .SYNOPSIS
        Writes a timestamped, level-classified message to the console and the run log.

    .DESCRIPTION
        The single logging entry point for every script in the toolkit. The log file
        always receives every message; the -Verbosity chosen at Initialize-MigrationRun
        only filters the console, because the console is for the technician watching a
        cutover at 2am while the file is for the post-incident reconstruction.

        Console filtering:
          Low    - ERROR and SUCCESS
          Medium - ERROR, SUCCESS and WARNING
          High   - everything, including INFO and DEBUG

        Calling this before Initialize-MigrationRun is legal: messages go to the console
        at Medium verbosity and no file is written. That keeps early parameter
        validation loggable without forcing a run context into existence first.

    .PARAMETER Message
        The text to log.

    .PARAMETER Level
        INFO, WARNING, ERROR, DEBUG or SUCCESS. Defaults to INFO.

    .EXAMPLE
        Write-MigrationLog -Message 'Connected to Microsoft Graph' -Level SUCCESS

        Writes a green success line to the console and to the run log.

    .EXAMPLE
        Write-MigrationLog -Message "Row skipped: PlanStatus is 'Excluded'" -Level WARNING

        Records a per-row decision. At Low verbosity this reaches the file only.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'This is the toolkit logger; colour-coded console output is its purpose and no other module code calls Write-Host.')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$timestamp] [$Level] $Message"

    $verbosity = 'Medium'
    $logPath = $null
    if ($script:MigrationRun) {
        $verbosity = $script:MigrationRun.Verbosity
        $logPath = $script:MigrationRun.LogPath
    }

    $showOnConsole = switch ($verbosity) {
        'Low'    { $Level -in @('ERROR', 'SUCCESS') }
        'Medium' { $Level -in @('ERROR', 'SUCCESS', 'WARNING') }
        'High'   { $true }
        default  { $true }
    }

    if ($showOnConsole) {
        $colour = switch ($Level) {
            'ERROR'   { 'Red' }
            'WARNING' { 'Yellow' }
            'SUCCESS' { 'Green' }
            'DEBUG'   { 'DarkGray' }
            default   { 'Gray' }
        }
        Write-Host $line -ForegroundColor $colour
    }

    if ($logPath) {
        try {
            Add-Content -LiteralPath $logPath -Value $line -Encoding utf8 -ErrorAction Stop
        }
        catch {
            # A log write must never take the run down with it, but the operator has to
            # know the audit trail is incomplete - so warn once per failure, on console only.
            Write-Host "[$timestamp] [WARNING] Could not write to log file '$logPath': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
