function Initialize-MigrationRun {
    <#
    .SYNOPSIS
        Creates the output folder, opens the run log and returns the run context.

    .DESCRIPTION
        The first call in every toolkit script. It resolves the output root
        (%LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations
        elsewhere), appends the prefix subfolder when one is given, creates the folder,
        opens a timestamped log file and records the invocation parameters.

        The context is also stored inside the module so that Write-MigrationLog and
        Invoke-MigrationAction need no arguments beyond their message or action - which
        is what keeps the per-row loops in the phase scripts readable.

        Parameter values are masked before logging when the parameter name suggests a
        secret. Nothing that could be a credential ever reaches the log file.

    .PARAMETER ScriptName
        The calling script's name; used in the log filename and the start banner.

    .PARAMETER OutputPath
        Overrides the default output root.

    .PARAMETER Prefix
        Names the client or run. When supplied, output lands in <root>\<Prefix>\ and
        filenames start with '<Prefix>_'.

    .PARAMETER LogPath
        Overrides the derived log file path entirely.

    .PARAMETER DryRun
        Records that this is a dry run, so Invoke-MigrationAction suppresses mutations.

    .PARAMETER Verbosity
        Console verbosity: Low, Medium (default) or High. The log file is unaffected.

    .PARAMETER BoundParameters
        The caller's $PSBoundParameters, recorded in the log with secrets masked.

    .EXAMPLE
        $run = Initialize-MigrationRun -ScriptName 'New-MigrationUsers' -Prefix 'Contoso' -BoundParameters $PSBoundParameters

        Opens Contoso_New-MigrationUsers_20260908-141500.log under the Contoso folder.

    .EXAMPLE
        $run = Initialize-MigrationRun -ScriptName 'Set-MigrationIdentity' -DryRun -Verbosity High

        Starts a dry run with full console output.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$OutputPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Prefix,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogPath,

        [switch]$DryRun,

        [ValidateSet('Low', 'Medium', 'High')]
        [string]$Verbosity = 'Medium',

        [hashtable]$BoundParameters
    )

    $cleanPrefix = Format-MigrationPrefix -Value $Prefix

    $root = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Get-MigrationDefaultOutputRoot } else { $OutputPath }
    $directory = if ($cleanPrefix) { Join-Path -Path $root -ChildPath $cleanPrefix } else { $root }

    if (-not (Test-Path -LiteralPath $directory)) {
        if ($PSCmdlet.ShouldProcess($directory, 'Create output directory')) {
            try {
                $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
            }
            catch {
                throw "Could not create the output directory '$directory': $($_.Exception.Message)"
            }
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $resolvedLogPath = $LogPath
    if ([string]::IsNullOrWhiteSpace($resolvedLogPath)) {
        $logName = if ($cleanPrefix) { "${cleanPrefix}_${ScriptName}_$timestamp.log" } else { "${ScriptName}_$timestamp.log" }
        $resolvedLogPath = Join-Path -Path $directory -ChildPath $logName
    }

    $script:MigrationRun = @{
        OutputDirectory = $directory
        Prefix          = $cleanPrefix
        LogPath         = $resolvedLogPath
        ScriptName      = $ScriptName
        StartedAt       = Get-Date
        DryRun          = [bool]$DryRun
        Verbosity       = $Verbosity
    }

    # A fresh run gets a fresh set of plan backups; Save-MigrationPlan writes the .bak
    # once per run rather than once per call.
    $script:MigrationPlanBackups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    Write-MigrationLog -Message "Started $ScriptName" -Level SUCCESS
    Write-MigrationLog -Message "Output directory: $directory" -Level INFO
    Write-MigrationLog -Message "Log file: $resolvedLogPath" -Level INFO
    if ($DryRun) {
        Write-MigrationLog -Message 'DryRun is enabled - no changes will be made.' -Level WARNING
    }

    if ($BoundParameters -and $BoundParameters.Count -gt 0) {
        # Anything whose name reads like a secret is masked. The pattern is deliberately
        # broad: a false positive costs a masked log line, a false negative leaks a credential.
        $secretPattern = 'password|passphrase|secret|credential|token|apikey|api-key|certificate|thumbprint|key$'
        foreach ($name in ($BoundParameters.Keys | Sort-Object)) {
            $value = if ($name -match $secretPattern) {
                '***masked***'
            }
            else {
                $raw = $BoundParameters[$name]
                if ($raw -is [System.Management.Automation.SwitchParameter]) { [string]$raw.IsPresent }
                elseif ($raw -is [System.Collections.IEnumerable] -and $raw -isnot [string]) { (@($raw) -join '; ') }
                else { [string]$raw }
            }
            Write-MigrationLog -Message "  Parameter $name = $value" -Level INFO
        }
    }

    return $script:MigrationRun
}
