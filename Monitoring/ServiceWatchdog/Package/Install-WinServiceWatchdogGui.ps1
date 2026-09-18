#Requires -Version 5.1

<#
.SYNOPSIS
    WinForms front end that installs, tests and removes the ServiceWatchdog on a Windows server
    without the technician editing any JSON.

.DESCRIPTION
    Windows-only, runs elevated in Windows PowerShell 5.1 with -STA (WinForms needs a single
    threaded apartment). Launched by Run-ServiceWatchdog.cmd, which self-elevates first.

    This script owns no monitoring logic. It is a front end for the ServiceWatchdog endpoint
    scripts: it collects a site name and a set
    of services, writes the public ServiceWatchdog.json schema, and then drives
    Register-WinServiceWatchdogTask.ps1, Invoke-WinServiceWatchdog.ps1 and
    Unregister-WinServiceWatchdogTask.ps1 in child powershell.exe processes, streaming their
    output into a read-only log pane. All tests, remediation and alerting stay in those
    scripts, so this front end never drifts from their contract.

    The endpoint scripts are found in $PSScriptRoot\Endpoint first, which is where
    New-ServiceWatchdogClientPackage.ps1 puts a pinned copy for a technician hand-off, and
    failing that in $PSScriptRoot\..\Endpoint, which is where they live in this repository
    so the GUI can be run straight from a clone. Neither having the registrar is a refusal.

    Window contents, top to bottom: site name (pre-filled with the computer name, or the
    installed config's SiteName), a filterable checked list of every service on the machine
    (running first, then alphabetical by display name, already-watched services pre-checked),
    the four action buttons, the log viewer row, the log pane, and a status line.

    Buttons:
      Install          Writes C:\ProgramData\ServiceWatchdog\ServiceWatchdog.json from
                       ServiceWatchdog.settings.json Defaults + site name + ticked services, then runs the
                       registrar with -RunNow -Force. Because the config is written first,
                       the registrar's "edit the config and re-run" exit 2 never happens. On an
                       installed server this is an update: the previous selection is loaded at
                       startup and simply rewritten. No test email is sent: delivery is a
                       separate decision, made with Send test alert once the task exists, so an
                       install is never held up by an Azure-side problem and a technician can
                       re-test delivery without re-registering anything.
      Send test alert  Runs the installed worker with -TestAlert and points the technician at
                       the inbox for the [TEST] email.
      Check status     Scheduled task state, last run time, mapped last result, a
                       -ValidateConfig pass, and the tail of today's worker log.
      View logs        Writes one of five things into the log pane: today's worker log in full,
                       the last 50 lines of the newest worker log, the last 50 Application log
                       events from the ServiceWatchdog source, the tail of the newest registrar
                       or uninstaller log, or this launch's own GUI log. A single dump is capped
                       at 2000 lines with a note naming the file to open for the rest.
      Uninstall        Confirms, then runs the unregistrar. The install folder, config and logs
                       are deliberately left in place so a re-install needs no new key.

    Refusals (message box, exit 2): not elevated, not Windows, not in a single threaded apartment,
    ServiceWatchdog.settings.json missing or still containing the literal REPLACE token, settings whose
    MaxRunSeconds and Webhook.TimeoutSeconds cannot fit the scheduled task's execution time limit,
    or Endpoint\Register-WinServiceWatchdogTask.ps1 absent. The function key is never written to
    the pane, the GUI log file or the screen: every line of child output is scrubbed of the key
    before it is displayed or logged.

    Child scripts are polled rather than waited on, so the registrar's progress appears in the
    pane while it works and the window keeps repainting through a run that takes minutes. The
    install folder is created with the Administrators group as its owner and a SYSTEM plus
    Administrators DACL before the config is written, because the config holds the function key
    and because the registrar refuses an install folder owned by anyone else.

    Structure note: every pure helper (settings load and validation, config merge, service
    sorting, exit-code mapping, status formatting) is defined before the UI, and the UI is built
    only inside Start-WatchdogGui, which the bottom of the script calls only when the file is
    run rather than dot-sourced. That is what lets the Pester suite exercise the helpers on a
    machine with no WinForms.

.PARAMETER SettingsPath
    Path to ServiceWatchdog.settings.json. Defaults to the copy beside this script. The file is not in git;
    it arrives with the folder handed to the technician.

.PARAMETER PackageRoot
    Folder holding Endpoint\ and ServiceWatchdog.settings.json. Defaults to the folder this script runs from.

.PARAMETER NoGui
    Load the helper functions and exit without building any UI. Used by the Pester suite and by
    anyone who wants to dot-source the helpers; nothing is installed or changed.

.PARAMETER Verbosity
    Console output level for the script's own messages. Low shows errors and success, Medium
    adds warnings, High shows everything. The GUI log file always receives every message, and
    the log pane is unaffected.

.PARAMETER DryRun
    Validates the settings, builds the config in memory and logs every child script command
    line with a [DRYRUN] prefix, but writes no config and launches no child process. The GUI
    still opens so the technician can see what would run.

.PARAMETER LogPath
    Override for the GUI's own log file. Defaults to
    %ProgramData%\ServiceWatchdog\Logs\Install-WinServiceWatchdogGui-<yyyyMMdd-HHmmss>.log.

.EXAMPLE
    .\Install-WinServiceWatchdogGui.ps1

    Normal use, though technicians should double-click Run-ServiceWatchdog.cmd instead so the
    UAC prompt and -STA are handled for them.

.EXAMPLE
    .\Install-WinServiceWatchdogGui.ps1 -DryRun -Verbosity High

    Opens the GUI in rehearsal mode: the config is built and every child command line is logged,
    but nothing is written and no child script runs.

.EXAMPLE
    . .\Install-WinServiceWatchdogGui.ps1 -NoGui

    Dot-sources the helper functions without loading WinForms, as the Pester suite does.

.NOTES
    Version:    1.1.1
    Created:    2026-09-17
    Platform:   Windows Server 2016 or later, Windows PowerShell 5.1, elevated, -STA.
    Exit codes: 0 the GUI ran and was closed normally; 1 unexpected error; 2 a refusal condition
                (not elevated, not Windows, not STA, settings missing, unedited or over the task's
                execution time limit, Endpoint\ incomplete).
                Child script exit codes are mapped and reported, never propagated.
    Logging:    %ProgramData%\ServiceWatchdog\Logs, alongside the endpoint scripts' own logs.

    Checklist deviations from the powershell-authoring skill (Enterprise tier):
      - 3.1: targets Windows PowerShell 5.1, not 7.4. Windows Server ships only 5.1 and the
        endpoint scripts are launched with powershell.exe for the same reason.
      - 5.2: no SecretManagement vault. The function key lives in ServiceWatchdog.settings.json,
        which is git-ignored and travels with the package built by
        New-ServiceWatchdogClientPackage.ps1; it is copied into the config file that the
        registrar ACLs down to SYSTEM and Administrators. Matching the endpoint design.
      - 6.6: the integration test is the operator acceptance run in README.md; WinForms code
        cannot be unit tested on macOS, so only the pure helpers are covered by Pester.

    Developed with AI assistance (Claude); reviewed before use.
#>

[CmdletBinding()]
param (
    [string]$SettingsPath,

    [string]$PackageRoot,

    [switch]$NoGui,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium',

    [switch]$DryRun,

    [string]$LogPath
)

#region Configuration & Constants

$ErrorActionPreference = 'Stop'

# The on-device contract of the endpoint scripts. Changing any of these means those scripts
# changed too; re-read their headers before editing.
# $env:ProgramData is empty off Windows, where Join-Path would then throw; the temp fallback keeps
# the helpers dot-sourceable for the Pester suite on macOS without affecting the real paths.
$script:WatchdogGuiProgramData = $env:ProgramData
if ([string]::IsNullOrWhiteSpace($script:WatchdogGuiProgramData)) {
    $script:WatchdogGuiProgramData = [System.IO.Path]::GetTempPath()
}
$script:WatchdogGuiInstallPath   = Join-Path $script:WatchdogGuiProgramData 'ServiceWatchdog'
$script:WatchdogGuiConfigPath    = Join-Path $script:WatchdogGuiInstallPath 'ServiceWatchdog.json'
$script:WatchdogGuiWorkerPath    = Join-Path $script:WatchdogGuiInstallPath 'Invoke-WinServiceWatchdog.ps1'
$script:WatchdogGuiWorkerLogRoot = Join-Path $script:WatchdogGuiInstallPath 'Logs'
# The GUI's own log lives beside the worker's, in the same project log root. The file names differ
# (Install-WinServiceWatchdogGui-<stamp>.log against ServiceWatchdog-<date>.log), so nothing clashes
# and a technician collecting one folder collects the whole story of an install.
$script:WatchdogGuiOwnLogRoot    = $script:WatchdogGuiWorkerLogRoot
$script:WatchdogGuiTaskName      = 'ServiceWatchdog'
$script:WatchdogGuiEventSource   = 'ServiceWatchdog'

$script:WatchdogGuiSchemaVersion = 1

# The registrar's -ExecutionTimeLimitSeconds default. The GUI never overrides it, so the settings
# must not describe a run that cannot finish inside it (see Get-WatchdogGuiWorstCaseRunSeconds).
$script:WatchdogGuiExecutionTimeLimitSeconds = 420

# Well-known SIDs, matching the registrar's own locale-safe constants. The GUI creates and locks
# the install folder before it writes the key into it; the registrar then re-applies the same ACL.
$script:WatchdogGuiSystemSid         = 'S-1-5-18'
$script:WatchdogGuiAdministratorsSid = 'S-1-5-32-544'

# Fallbacks used only when ServiceWatchdog.settings.json omits a Defaults value. They match the public
# ServiceWatchdog.example.json so an incomplete settings file still produces a valid config.
$script:WatchdogGuiConfigDefaults = @{
    ''         = @{
        MaxStartAttempts        = 5
        RetryDelaySeconds       = 30
        PostStartVerifySeconds  = 10
        StartPendingWaitSeconds = 60
        MaxRunSeconds           = 240
    }
    'Alerting' = @{
        ReminderMinutes             = 240
        NotifyOnRemediation         = $false
        RemediationCooldownMinutes  = 60
        HeartbeatHours              = 24
    }
    'Logging'  = @{
        LogRoot             = ''
        LogRetentionDays    = 30
        EventLogHealthyRuns = $false
    }
}

# Set by Initialize-WatchdogGuiLog; helpers tolerate it being empty so they can be dot-sourced.
$script:LogFilePath = $LogPath
$script:LogVerbosity = $Verbosity
$script:DryRunMode = $DryRun.IsPresent

# Set once the settings are loaded, so every line bound for the pane or the log can be scrubbed.
$script:SecretValues = @()

# Replaced by the GUI with a scriptblock that appends to the log pane.
$script:PaneWriter = $null

# Replaced by the GUI with a scriptblock that pumps the WinForms message queue. Called while a
# child process is running so the window keeps repainting even during a silent minute.
$script:UiPump = $null

#endregion

#region Helper Functions

function Remove-WatchdogGuiSecretText {
    <#
    .SYNOPSIS
        Replaces every known secret value in a string with ********.
    .DESCRIPTION
        Defence in depth for the "never show the key" rule. The public worker already masks the
        function key in its own output, but this GUI relays child stdout verbatim, so every line
        is scrubbed before it reaches the pane or the log file. A secret shorter than eight
        characters is ignored: it would be too generic and would mangle unrelated output.
    .PARAMETER Text
        The text to scrub. $null and empty strings are returned unchanged.
    .PARAMETER Secret
        Secret values to redact. Defaults to the values collected when the settings loaded.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object or updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [string[]]$Secret
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    $secrets = $Secret
    if ($null -eq $secrets) {
        $secrets = $script:SecretValues
    }
    $result = $Text
    foreach ($value in @($secrets)) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value.Length -ge 8) {
            $result = $result.Replace($value, '********')
        }
    }
    return $result
}

function Initialize-WatchdogGuiLog {
    <#
    .SYNOPSIS
        Resolves the GUI's log file path and creates its folder.
    .DESCRIPTION
        The default sits in the same Logs folder the endpoint scripts use, which is inside the
        install folder. That folder must not be created with a bare New-Item: the registrar
        refuses an install folder owned by the administrator who happened to create it (exit 2),
        so when it is still absent it is created through New-WatchdogGuiProtectedFolder, exactly
        as the config write does.
    .PARAMETER Path
        Explicit log file path. When empty, the project convention path is used:
        %ProgramData%\ServiceWatchdog\Logs\Install-WinServiceWatchdogGui-<yyyyMMdd-HHmmss>.log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    $resolved = $Path
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $resolved = Join-Path $script:WatchdogGuiOwnLogRoot "Install-WinServiceWatchdogGui-$stamp.log"
    }
    $folder = Split-Path -Path $resolved -Parent
    if ($folder -and -not (Test-Path -LiteralPath $folder)) {
        if ((Test-WatchdogGuiWindows) -and
            -not (Test-Path -LiteralPath $script:WatchdogGuiInstallPath -PathType Container)) {
            New-WatchdogGuiProtectedFolder -Path $script:WatchdogGuiInstallPath -Confirm:$false | Out-Null
        }
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
    $script:LogFilePath = $resolved
    return $resolved
}

function Write-WatchdogGuiLog {
    <#
    .SYNOPSIS
        Writes one scrubbed, timestamped line to the GUI log file, the log pane and the console.
    .DESCRIPTION
        The log file always receives every line. The console honours -Verbosity through
        Write-Verbose/Write-Warning (never Write-Host, so the hidden console of a WinForms run
        stays quiet). The pane receives the line whenever the GUI has installed a pane writer.
    .PARAMETER Message
        The message. Scrubbed of known secrets before it goes anywhere.
    .PARAMETER Level
        INFO, WARNING, ERROR, DEBUG or SUCCESS.
    .PARAMETER NoPane
        Keep the line out of the log pane (used for noise the technician does not need).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')]
        [string]$Level = 'INFO',

        [switch]$NoPane
    )

    $clean = Remove-WatchdogGuiSecretText -Text $Message
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $clean

    if ($script:LogFilePath) {
        try {
            Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8
        }
        catch {
            # A failed log write must never take the GUI down with it.
            Write-Warning "Could not write to the log file: $_"
        }
    }

    switch ($Level) {
        'ERROR' { Write-Verbose $line -Verbose:$true }
        'WARNING' {
            if ($script:LogVerbosity -in @('Medium', 'High')) { Write-Warning $clean }
        }
        'SUCCESS' { Write-Verbose $line -Verbose:$true }
        default {
            if ($script:LogVerbosity -eq 'High') { Write-Verbose $line -Verbose:$true }
        }
    }

    if (-not $NoPane -and $script:PaneWriter) {
        & $script:PaneWriter $line
    }
}

function ConvertTo-WatchdogGuiHashtable {
    <#
    .SYNOPSIS
        Converts ConvertFrom-Json output into nested hashtables.
    .DESCRIPTION
        Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, and PSCustomObject property
        lookups differ enough from hashtable lookups to be worth normalising once.
    .PARAMETER InputObject
        The object to convert.
    #>
    [CmdletBinding()]
    [OutputType([object], [hashtable])]
    param (
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-WatchdogGuiHashtable -InputObject $property.Value
        }
        return $table
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) {
            $table[[string]$key] = ConvertTo-WatchdogGuiHashtable -InputObject $InputObject[$key]
        }
        return $table
    }
    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += , (ConvertTo-WatchdogGuiHashtable -InputObject $item)
        }
        return $items
    }
    return $InputObject
}

function Get-WatchdogGuiWorstCaseRunSeconds {
    <#
    .SYNOPSIS
        Computes the worst-case worker run time the registrar checks its execution limit against.
    .DESCRIPTION
        Mirrors step 3 of Register-WinServiceWatchdogTask.ps1 exactly:
        MaxRunSeconds + 2 * (2 * Webhook.TimeoutSeconds + 5) + 15. The GUI never passes
        -ExecutionTimeLimitSeconds, so the registrar's 420 second default has to cover whatever
        the settings file asks for; anything larger is refused by the registrar with exit 2 after
        the config has already been written, which is a confusing place for a technician to land.
        Computing it here lets the refusal happen at startup with a message that names the knob.
    .PARAMETER Settings
        The settings as nested hashtables. Missing values fall back to the public defaults, which
        is what the generated config would carry.
    .OUTPUTS
        System.Int32 - the worst-case run time in seconds.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun is the settings file itself (ServiceWatchdog.settings.json), which is plural by name.')]
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [AllowNull()]
        [object]$Settings
    )

    $defaults = $null
    $webhook = $null
    if ($Settings -is [System.Collections.IDictionary]) {
        $defaults = $Settings['Defaults']
        $webhook = $Settings['Webhook']
    }

    $maxRunSeconds = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section '' -Key 'MaxRunSeconds')
    $timeoutSeconds = 30
    if ($webhook -is [System.Collections.IDictionary] -and $webhook.Contains('TimeoutSeconds') -and
        $null -ne $webhook['TimeoutSeconds']) {
        $timeoutSeconds = [int]$webhook['TimeoutSeconds']
    }

    return ($maxRunSeconds + 2 * (2 * $timeoutSeconds + 5) + 15)
}

function Test-WatchdogGuiSettings {
    <#
    .SYNOPSIS
        Validates a loaded ServiceWatchdog.settings.json structure.
    .DESCRIPTION
        Rejects anything that would produce a config the public worker refuses: wrong schema
        version, a missing or non-https webhook URL, a missing or empty function key, and any
        value still carrying the literal upper-case REPLACE token. The REPLACE check is
        case-sensitive on purpose, matching the public worker: a real client name such as
        'Replacement Parts Co' must not be rejected.

        It also rejects a Defaults block whose MaxRunSeconds and Webhook.TimeoutSeconds would
        exceed the registrar's execution time limit, because that failure would otherwise surface
        as a bare exit 2 from a child process after the config had already been written.
    .PARAMETER Settings
        The settings as nested hashtables (see ConvertTo-WatchdogGuiHashtable).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun is the settings file itself (ServiceWatchdog.settings.json), which is plural by name.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Settings
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if ($Settings -isnot [System.Collections.IDictionary]) {
        $errors.Add('ServiceWatchdog.settings.json must contain a JSON object.')
        return [pscustomobject]@{ IsValid = $false; Errors = @($errors.ToArray()) }
    }

    if (-not $Settings.ContainsKey('SchemaVersion') -or [string]$Settings['SchemaVersion'] -ne '1') {
        $errors.Add('SchemaVersion must be 1.')
    }

    $webhook = $Settings['Webhook']
    if ($webhook -isnot [System.Collections.IDictionary]) {
        $errors.Add('Webhook section is missing.')
    }
    else {
        $url = [string]$webhook['Url']
        if ($url -cmatch 'REPLACE') {
            $errors.Add('Webhook.Url still contains REPLACE; the settings file has not been filled in.')
        }
        elseif ($url -notmatch '^(?i)https://[^\s/]+') {
            $errors.Add('Webhook.Url must be an https:// URL.')
        }

        $key = [string]$webhook['FunctionKey']
        if ($key -cmatch 'REPLACE') {
            $errors.Add('Webhook.FunctionKey still contains REPLACE; copy ServiceWatchdog.settings.example.json to ' +
                'ServiceWatchdog.settings.json and fill in the FunctionKey.')
        }
        elseif ([string]::IsNullOrWhiteSpace($key)) {
            $errors.Add('Webhook.FunctionKey must not be empty.')
        }
    }

    # Any other REPLACE anywhere in the file is a half-filled settings file too.
    foreach ($name in @('ClientName')) {
        if ([string]$Settings[$name] -cmatch 'REPLACE') {
            $errors.Add("$name still contains REPLACE; the settings file has not been filled in.")
        }
    }

    # The registrar refuses to register a task whose execution limit cannot cover the worst-case
    # run derived from the config. Catch it here instead: at this point nothing has been written.
    try {
        $worstCase = Get-WatchdogGuiWorstCaseRunSeconds -Settings $Settings
        if ($worstCase -gt $script:WatchdogGuiExecutionTimeLimitSeconds) {
            $maxRun = [int](Get-WatchdogGuiDefaultValue -Defaults $Settings['Defaults'] -Section '' -Key 'MaxRunSeconds')
            $timeout = 30
            if ($webhook -is [System.Collections.IDictionary] -and $webhook.Contains('TimeoutSeconds') -and
                $null -ne $webhook['TimeoutSeconds']) {
                $timeout = [int]$webhook['TimeoutSeconds']
            }
            $allowedMaxRun = $script:WatchdogGuiExecutionTimeLimitSeconds - (2 * (2 * $timeout + 5) + 15)
            $errors.Add(("Defaults.MaxRunSeconds $maxRun with Webhook.TimeoutSeconds $timeout needs " +
                    "$worstCase seconds in the worst case, more than the scheduled task's " +
                    "$($script:WatchdogGuiExecutionTimeLimitSeconds) second execution limit. Lower " +
                    "Defaults.MaxRunSeconds to $allowedMaxRun or less (or lower Webhook.TimeoutSeconds) " +
                    'in ServiceWatchdog.settings.json.'))
        }
    }
    catch {
        $errors.Add("Defaults.MaxRunSeconds and Webhook.TimeoutSeconds must be whole numbers: $_")
    }

    return [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = @($errors.ToArray())
    }
}

function Resolve-WatchdogGuiSettings {
    <#
    .SYNOPSIS
        Reads and validates ServiceWatchdog.settings.json, returning a result object rather than throwing.
    .DESCRIPTION
        The single entry point the GUI uses for its startup refusal check, so a missing file,
        malformed JSON and unedited placeholders all arrive in the same shape.
    .PARAMETER Path
        Path to ServiceWatchdog.settings.json.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun is the settings file itself (ServiceWatchdog.settings.json), which is plural by name.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    $failure = {
        param ($message)
        [pscustomobject]@{ IsValid = $false; Errors = @($message); Settings = $null }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return & $failure 'No settings path was supplied.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return & $failure ("ServiceWatchdog.settings.json was not found at '$Path'. Copy ServiceWatchdog.settings.example.json to " +
            'ServiceWatchdog.settings.json and fill in the FunctionKey.')
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $parsed = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    }
    catch {
        return & $failure "ServiceWatchdog.settings.json at '$Path' is not valid JSON: $_"
    }

    $settings = ConvertTo-WatchdogGuiHashtable -InputObject $parsed
    $result = Test-WatchdogGuiSettings -Settings $settings

    return [pscustomobject]@{
        IsValid  = $result.IsValid
        Errors   = @($result.Errors)
        Settings = $settings
    }
}

function Get-WatchdogGuiDefaultValue {
    <#
    .SYNOPSIS
        Reads one value from the settings Defaults block, falling back to the public defaults.
    .PARAMETER Defaults
        The Defaults hashtable from ServiceWatchdog.settings.json. May be $null.
    .PARAMETER Section
        '' for a top-level config value, otherwise 'Alerting' or 'Logging'.
    .PARAMETER Key
        The value name.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param (
        [AllowNull()]
        [object]$Defaults,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $container = $Defaults
    if ($Section -and $Defaults -is [System.Collections.IDictionary]) {
        $container = $Defaults[$Section]
    }
    if ($container -is [System.Collections.IDictionary] -and $container.Contains($Key) -and
        $null -ne $container[$Key]) {
        return $container[$Key]
    }
    return $script:WatchdogGuiConfigDefaults[$Section][$Key]
}

function New-WatchdogGuiConfig {
    <#
    .SYNOPSIS
        Builds the public ServiceWatchdog.json content from the settings, a site name and a
        service selection.
    .DESCRIPTION
        The output is an ordered dictionary whose shape is identical to the public
        ServiceWatchdog.example.json, so ConvertTo-Json produces a file the worker's
        -ValidateConfig accepts with no unknown-key warnings. Everything the GUI does not ask
        for comes from the settings Defaults block, which is why those knobs can be retuned for
        the client without touching this script.

        Service names are trimmed and de-duplicated case-insensitively in the order ticked,
        because the worker rejects a Services array containing duplicates.
    .PARAMETER Settings
        The validated settings (nested hashtables).
    .PARAMETER SiteName
        Site name for the alert emails, 1 to 64 characters.
    .PARAMETER Service
        Short service names (Get-Service Name), not display names.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object or updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Settings,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SiteName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Service
    )

    $defaults = $Settings['Defaults']
    $webhook = $Settings['Webhook']
    if ($webhook -isnot [System.Collections.IDictionary]) {
        throw 'The settings file has no Webhook section; the config cannot be built.'
    }

    $services = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Service) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $trimmed = $name.Trim()
        if ($seen.Add($trimmed)) { $services.Add($trimmed) }
    }
    if ($services.Count -lt 1) {
        throw 'At least one service must be selected.'
    }

    $timeout = 30
    if ($webhook.Contains('TimeoutSeconds') -and $null -ne $webhook['TimeoutSeconds']) {
        $timeout = [int]$webhook['TimeoutSeconds']
    }

    $config = [ordered]@{
        SchemaVersion           = $script:WatchdogGuiSchemaVersion
        SiteName                = $SiteName.Trim()
        Services                = @($services.ToArray())
        MaxStartAttempts        = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section '' -Key 'MaxStartAttempts')
        RetryDelaySeconds       = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section '' -Key 'RetryDelaySeconds')
        PostStartVerifySeconds  = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section '' `
                -Key 'PostStartVerifySeconds')
        StartPendingWaitSeconds = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section '' `
                -Key 'StartPendingWaitSeconds')
        MaxRunSeconds           = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section '' -Key 'MaxRunSeconds')
        Webhook                 = [ordered]@{
            Url            = [string]$webhook['Url']
            FunctionKey    = [string]$webhook['FunctionKey']
            TimeoutSeconds = $timeout
        }
        Alerting                = [ordered]@{
            ReminderMinutes            = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section 'Alerting' `
                    -Key 'ReminderMinutes')
            NotifyOnRemediation        = [bool](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section 'Alerting' `
                    -Key 'NotifyOnRemediation')
            RemediationCooldownMinutes = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section 'Alerting' `
                    -Key 'RemediationCooldownMinutes')
            HeartbeatHours             = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section 'Alerting' `
                    -Key 'HeartbeatHours')
        }
        Logging                 = [ordered]@{
            LogRoot             = [string](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section 'Logging' `
                    -Key 'LogRoot')
            LogRetentionDays    = [int](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section 'Logging' `
                    -Key 'LogRetentionDays')
            EventLogHealthyRuns = [bool](Get-WatchdogGuiDefaultValue -Defaults $defaults -Section 'Logging' `
                    -Key 'EventLogHealthyRuns')
        }
    }

    return $config
}

function Get-WatchdogGuiSortedServiceList {
    <#
    .SYNOPSIS
        Orders services for the checked list: running first, then alphabetical by display name.
    .DESCRIPTION
        Running services come first because those are what an operator almost always wants to
        watch; within each group the order is alphabetical by display name, case-insensitively,
        so the list is stable between runs. A service with no display name falls back to its
        short name so it still sorts somewhere sensible instead of to the top.
    .PARAMETER Service
        Objects with Name, DisplayName and Status (Get-Service output, or anything shaped alike).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Service
    )

    $running = { if ([string]$_.Status -eq 'Running') { 0 } else { 1 } }
    $label = {
        if ([string]::IsNullOrWhiteSpace([string]$_.DisplayName)) { [string]$_.Name }
        else { [string]$_.DisplayName }
    }
    return @($Service | Sort-Object -Property @{ Expression = $running }, @{ Expression = $label })
}

function Format-WatchdogGuiServiceLabel {
    <#
    .SYNOPSIS
        Renders one checked-list row as 'Display Name (ShortName) [Status]'.
    .PARAMETER Service
        An object with Name, DisplayName and Status.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [object]$Service
    )

    $display = [string]$Service.DisplayName
    if ([string]::IsNullOrWhiteSpace($display)) { $display = [string]$Service.Name }
    return '{0} ({1}) [{2}]' -f $display, [string]$Service.Name, [string]$Service.Status
}

function Get-WatchdogGuiExitCodeMeaning {
    <#
    .SYNOPSIS
        Maps a child script's exit code to the meaning documented in that script's header.
    .DESCRIPTION
        The three public scripts share 0/1/2 but diverge on 10 and 50, so the meaning depends on
        which one ran. Anything unrecognised is reported as an error rather than silently
        treated as success.
    .PARAMETER ExitCode
        The process exit code.
    .PARAMETER Script
        Register, Unregister or Worker.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter(Mandatory)]
        [ValidateSet('Register', 'Unregister', 'Worker')]
        [string]$Script
    )

    $meaning = $null
    $severity = 'Error'

    switch ($Script) {
        'Register' {
            switch ($ExitCode) {
                0 { $meaning = 'Scheduled task registered and the first run completed.'; $severity = 'Success' }
                1 { $meaning = 'Unexpected error in the registrar; see the log pane.' }
                2 {
                    $meaning = 'Refused: the config is invalid, sits outside the install folder, the install ' +
                    'folder already exists and is owned by another account, the worker is already present ' +
                    'without -Force, or the execution time limit is too small. The log pane above has the ' +
                    'registrar line that says which.'
                }
                10 {
                    $meaning = 'The task is registered, but the test alert was not delivered. Check the function ' +
                    'key and the Azure side.'
                    $severity = 'Warning'
                }
                50 {
                    $meaning = 'The task is registered, but one or more service recovery steps failed.'
                    $severity = 'Warning'
                }
            }
        }
        'Unregister' {
            switch ($ExitCode) {
                0 { $meaning = 'Scheduled task removed, or it was already absent.'; $severity = 'Success' }
                1 { $meaning = 'Unexpected error in the unregistrar; see the log pane.' }
                2 { $meaning = 'Refused: invalid parameters.' }
            }
        }
        'Worker' {
            switch ($ExitCode) {
                0 { $meaning = 'Healthy, or every stopped service was restarted.'; $severity = 'Success' }
                1 { $meaning = 'Unexpected error in the worker; see the log pane.' }
                2 { $meaning = 'Configuration or parameters invalid.' }
                10 {
                    $meaning = 'Notification or heartbeat delivery pending: the webhook did not accept the event.'
                    $severity = 'Warning'
                }
                50 {
                    $meaning = 'One or more services are Failed, Missing or Disabled after retries.'
                    $severity = 'Warning'
                }
            }
        }
    }

    if ($null -eq $meaning) {
        $meaning = "Unrecognised exit code $ExitCode from the $Script script."
    }

    return [pscustomobject]@{
        ExitCode  = $ExitCode
        Script    = $Script
        IsSuccess = ($ExitCode -eq 0)
        Severity  = $severity
        Meaning   = $meaning
    }
}

function Format-WatchdogGuiTaskResult {
    <#
    .SYNOPSIS
        Describes a scheduled task's LastTaskResult, whether it is a worker exit code or one of
        Task Scheduler's own status codes.
    .DESCRIPTION
        A freshly registered task reports 267011 ("has not yet run") and a running one 267009, and
        neither is a worker exit code. Feeding those straight into Get-WatchdogGuiExitCodeMeaning produced
        "Unrecognised exit code 267011", which reads like a fault on a server where nothing is
        wrong. The three codes a technician actually meets are named here; everything else is a
        worker exit code and is mapped as one, so the exit-code map itself stays a faithful copy of
        the public scripts' .NOTES lists.
    .PARAMETER LastTaskResult
        The task's LastTaskResult. Task Scheduler reports it as an unsigned 32-bit value, and an
        abnormal run (the action was killed, or powershell.exe itself crashed) leaves an
        HRESULT-style code above 0x7FFFFFFF there, so the parameter is not [int]: casting
        4294770688 (0xFFFD0000) to Int32 threw, and because the status line is refreshed at
        startup the GUI exited 1 before its window opened.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [uint32]$LastTaskResult
    )

    switch ($LastTaskResult) {
        267011 { return '267011 - the task has not run yet.' }
        267009 { return '267009 - the task is running now.' }
        267014 { return '267014 - the last run was stopped before it finished.' }
        { $_ -gt [int]::MaxValue } {
            return ('0x{0:X8} - the last run ended abnormally (not a worker exit code); ' +
                'press Install to re-register the task, then Check status again.') -f $LastTaskResult
        }
        default {
            $mapped = Get-WatchdogGuiExitCodeMeaning -ExitCode ([int]$LastTaskResult) -Script 'Worker'
            return ('{0} - {1}' -f $mapped.ExitCode, $mapped.Meaning)
        }
    }
}

function Format-WatchdogGuiTaskStatus {
    <#
    .SYNOPSIS
        Turns scheduled task state into the status lines shown by Check status.
    .DESCRIPTION
        The first line returned is the one-line summary the status bar shows; the rest is detail
        for the log pane. The task's LastTaskResult is a worker exit code, so it is mapped
        through Get-WatchdogGuiExitCodeMeaning rather than printed as a bare number.
    .PARAMETER TaskState
        The task's State (Ready, Running, Disabled...). $null when the task does not exist.
    .PARAMETER TaskInfo
        Get-ScheduledTaskInfo output, or anything with LastRunTime, LastTaskResult and
        NextRunTime. $null when the task does not exist.
    .PARAMETER ConfigPresent
        Whether the config file exists on disk.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [AllowNull()]
        [object]$TaskState,

        [AllowNull()]
        [object]$TaskInfo,

        [switch]$ConfigPresent
    )

    $lines = New-Object System.Collections.Generic.List[string]

    if ($null -eq $TaskState -and $null -eq $TaskInfo) {
        $suffix = 'config not present'
        if ($ConfigPresent) { $suffix = 'config present' }
        $lines.Add("Not installed: scheduled task '$script:WatchdogGuiTaskName' does not exist ($suffix).")
        return , @($lines.ToArray())
    }

    $state = '(unknown)'
    if ($null -ne $TaskState) { $state = [string]$TaskState }

    $lastRun = 'never'
    $nextRun = 'not scheduled'
    $resultText = 'no result yet'
    if ($null -ne $TaskInfo) {
        if ($TaskInfo.LastRunTime) { $lastRun = ([datetime]$TaskInfo.LastRunTime).ToString('yyyy-MM-dd HH:mm:ss') }
        if ($TaskInfo.NextRunTime) { $nextRun = ([datetime]$TaskInfo.NextRunTime).ToString('yyyy-MM-dd HH:mm:ss') }
        if ($null -ne $TaskInfo.LastTaskResult) {
            $resultText = Format-WatchdogGuiTaskResult -LastTaskResult ([uint32]$TaskInfo.LastTaskResult)
        }
    }

    $lines.Add("Installed: task '$script:WatchdogGuiTaskName' is $state, last run $lastRun, last result $resultText.")
    $lines.Add("Next run:     $nextRun")
    $lines.Add("Install path: $script:WatchdogGuiInstallPath")
    $lines.Add("Config:       $script:WatchdogGuiConfigPath")
    $lines.Add("Worker logs:  $script:WatchdogGuiWorkerLogRoot")
    $lines.Add("Event log:    Application, source $script:WatchdogGuiEventSource")
    return , @($lines.ToArray())
}

function Test-WatchdogGuiElevation {
    <#
    .SYNOPSIS
        Returns $true when the current process is elevated on Windows.
    .DESCRIPTION
        The GUI checks this itself instead of using #Requires -RunAsAdministrator so it can show
        a message box rather than a console error the technician will never see.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Test-WatchdogGuiSingleThreadedApartment {
    <#
    .SYNOPSIS
        Returns $true when the current thread is in a single threaded apartment.
    .DESCRIPTION
        WinForms requires STA. Run-ServiceWatchdog.cmd passes -STA, but somebody running the .ps1
        by hand from a PowerShell 5.1 console gets MTA, where the common file dialogs and the
        clipboard misbehave and a handler exception can take the window down with no message. Off
        Windows (where the Pester suite dot-sources this) there is no apartment state to read, so
        the check reports $true rather than blocking a run that never builds a window anyway.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    try {
        $state = [System.Threading.Thread]::CurrentThread.GetApartmentState()
        if ($state -eq [System.Threading.ApartmentState]::Unknown) { return $true }
        return ($state -eq [System.Threading.ApartmentState]::STA)
    }
    catch {
        return $true
    }
}

function Test-WatchdogGuiWindows {
    <#
    .SYNOPSIS
        Returns $true on Windows, on both Windows PowerShell 5.1 and PowerShell 7.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    # Windows PowerShell 5.1 (the Desktop edition) exists only on Windows and has no $IsWindows.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return $true
    }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-WatchdogGuiPackagePath {
    <#
    .SYNOPSIS
        Resolves the package folder and the paths inside it that the GUI drives.
    .DESCRIPTION
        The endpoint scripts are looked for in <Root>\Endpoint first, which is where a built
        client package keeps its pinned copy, and then in <Root>\..\Endpoint, which is where they
        live in the repository so the GUI can be run straight from a clone. The fallback is taken
        only when the first folder has no Register-WinServiceWatchdogTask.ps1 and the second one
        does, so a package that ships its own Endpoint\ always wins and a run with neither still
        reports the primary path in its refusal message.
    .PARAMETER Root
        The package folder. Defaults to $PSScriptRoot.
    .PARAMETER SettingsFile
        Override for ServiceWatchdog.settings.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Root,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$SettingsFile
    )

    $resolvedRoot = $Root
    if ([string]::IsNullOrWhiteSpace($resolvedRoot)) { $resolvedRoot = $PSScriptRoot }
    $registrarName = 'Register-WinServiceWatchdogTask.ps1'
    $endpoint = Join-Path $resolvedRoot 'Endpoint'
    if (-not (Test-Path -LiteralPath (Join-Path $endpoint $registrarName) -PathType Leaf)) {
        $parent = Split-Path -Path $resolvedRoot -Parent
        if ($parent) {
            $sibling = Join-Path $parent 'Endpoint'
            if (Test-Path -LiteralPath (Join-Path $sibling $registrarName) -PathType Leaf) {
                $endpoint = $sibling
            }
        }
    }
    $settings = $SettingsFile
    if ([string]::IsNullOrWhiteSpace($settings)) {
        $settings = Join-Path $resolvedRoot 'ServiceWatchdog.settings.json'
    }

    return [pscustomobject]@{
        Root         = $resolvedRoot
        EndpointPath = $endpoint
        SettingsPath = $settings
        ExamplePath  = Join-Path $resolvedRoot 'ServiceWatchdog.settings.example.json'
        Register     = Join-Path $endpoint $registrarName
        Unregister   = Join-Path $endpoint 'Unregister-WinServiceWatchdogTask.ps1'
        Worker       = Join-Path $endpoint 'Invoke-WinServiceWatchdog.ps1'
    }
}

function Format-WatchdogGuiCommandLine {
    <#
    .SYNOPSIS
        Renders a powershell.exe command line for the log pane, quoting paths with spaces.
    .PARAMETER ScriptPath
        The child script.
    .PARAMETER ArgumentList
        Its arguments.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [AllowNull()]
        [string[]]$ArgumentList
    )

    $quote = {
        param ($value)
        if ($value -match '\s') { '"{0}"' -f $value } else { $value }
    }
    $parts = @('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NonInteractive', '-File',
        (& $quote $ScriptPath))
    foreach ($argument in @($ArgumentList)) {
        $parts += (& $quote $argument)
    }
    return ($parts -join ' ')
}

function Read-WatchdogGuiFileTail {
    <#
    .SYNOPSIS
        Reads whatever has been appended to a file since a byte offset, without locking it.
    .DESCRIPTION
        The child process still has its redirect files open for writing, so they are opened with
        FileShare ReadWrite,Delete and read from the given offset. Only whole lines are returned:
        a trailing fragment is left for the next call so a half-written line never reaches the
        pane, and the returned offset stays on a line boundary.
    .PARAMETER Path
        The file to read.
    .PARAMETER Offset
        Byte offset to resume from. 0 on the first call.
    .OUTPUTS
        PSCustomObject with Text (the complete lines read, possibly empty) and Offset (where the
        next call should resume).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [ValidateRange(0, [long]::MaxValue)]
        [long]$Offset = 0
    )

    $result = [pscustomobject]@{ Text = ''; Offset = $Offset }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $result
    }

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        if ($stream.Length -le $Offset) {
            return $result
        }
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $count = [int]($stream.Length - $Offset)
        $buffer = New-Object byte[] $count
        $read = $stream.Read($buffer, 0, $count)
        if ($read -le 0) {
            return $result
        }

        # Stop at the last newline so a partially written line is re-read next time instead of
        # being shown split across two pane lines.
        $lastBreak = -1
        for ($index = $read - 1; $index -ge 0; $index--) {
            if ($buffer[$index] -eq 10) { $lastBreak = $index; break }
        }
        if ($lastBreak -lt 0) {
            return $result
        }
        $result.Text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $lastBreak + 1)
        $result.Offset = $Offset + $lastBreak + 1
        return $result
    }
    catch {
        # A transient sharing or encoding problem must not abort the run the child is doing.
        return $result
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Invoke-WatchdogGuiChildScript {
    <#
    .SYNOPSIS
        Runs one pinned public script in a child Windows PowerShell process, streaming its output
        into the log pane, and returns its exit code.
    .DESCRIPTION
        Synchronous from the caller's point of view: the registrar can take a minute or two, and a
        job would add a second failure surface for no benefit the technician can see. The caller
        disables the buttons and shows "Working..." for the duration.

        The process is started without -Wait and polled instead, because -Wait blocks the UI
        thread outright: the window would stop repainting and Windows would grey it out as "Not
        Responding" for the whole registrar run, with the progress the registrar prints arriving
        only after it finished. Each poll appends whatever the child has written since the last
        one (stdout then stderr, through the same scrubbed relay as everything else) and pumps the
        WinForms message queue, so the pane fills as the work happens.

        stdout and stderr go to temp files rather than to captured streams because that is the
        only method that also catches what the child writes through Write-Host. The exit code is
        read from the process object, never from $?, which would only describe Start-Process.

        Honours -DryRun: the command line is logged with a [DRYRUN] prefix and nothing runs.
    .PARAMETER ScriptPath
        Full path to the child script.
    .PARAMETER ArgumentList
        Arguments appended after -File <ScriptPath>.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath,

        [AllowNull()]
        [string[]]$ArgumentList
    )

    $commandLine = Format-WatchdogGuiCommandLine -ScriptPath $ScriptPath -ArgumentList $ArgumentList
    Write-WatchdogGuiLog "Running: $commandLine"

    if ($script:DryRunMode) {
        Write-WatchdogGuiLog "[DRYRUN] Child process not started: $commandLine" -Level 'WARNING'
        return [pscustomobject]@{ ExitCode = 0; Output = '[DRYRUN] not executed'; DryRun = $true }
    }

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Script not found: $ScriptPath"
    }

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NonInteractive', '-File', ('"{0}"' -f $ScriptPath))
    foreach ($argument in @($ArgumentList)) {
        if ($argument -match '\s') { $quoted += ('"{0}"' -f $argument) } else { $quoted += $argument }
    }

    $offsets = @{ $stdout = [long]0; $stderr = [long]0 }
    $collected = New-Object System.Text.StringBuilder

    # Appends everything written since the last call, and keeps the window alive while doing it.
    $drain = {
        foreach ($file in @($stdout, $stderr)) {
            $chunk = Read-WatchdogGuiFileTail -Path $file -Offset $offsets[$file]
            $offsets[$file] = $chunk.Offset
            if (-not [string]::IsNullOrEmpty($chunk.Text)) {
                [void]$collected.Append($chunk.Text)
                Write-WatchdogGuiOutputBlock -Text (Remove-WatchdogGuiSecretText -Text $chunk.Text)
            }
        }
        if ($script:UiPump) { & $script:UiPump }
    }

    try {
        $process = Start-Process -FilePath $exe -ArgumentList $quoted -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        while (-not $process.HasExited) {
            & $drain
            Start-Sleep -Milliseconds 250
        }
        # The child can exit between the last poll and HasExited turning true, so drain once more.
        $process.WaitForExit()
        & $drain

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output   = (Remove-WatchdogGuiSecretText -Text $collected.ToString())
            Streamed = $true
            DryRun   = $false
        }
    }
    finally {
        foreach ($file in @($stdout, $stderr)) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-WatchdogGuiProtectedFolder {
    <#
    .SYNOPSIS
        Creates the install folder with the same owner and DACL the registrar would apply.
    .DESCRIPTION
        Two problems are solved here, both of them consequences of the GUI writing the config
        before the registrar runs.

        First, ownership. The registrar refuses an install folder that already exists and is owned
        by anything other than SYSTEM, Administrators or TrustedInstaller (exit 2), because an
        owner keeps WRITE_DAC over a folder whose contents Task Scheduler runs as SYSTEM. A folder
        created by an elevated administrator is owned by that administrator's own account on a
        default Windows Server, so simply calling New-Item here would make the registrar refuse
        the very folder this GUI just created - and tell the technician to delete it and re-run,
        which the GUI would then do again. The owner is therefore set to the Administrators group,
        exactly as the registrar's icacls /setowner does.

        Second, the function key. Between this write and the registrar's ACL step the config sits
        in a folder that inherits ProgramData's permissive DACL, where any interactive user can
        read it. The restrictive DACL is applied to the new folder before anything is written into
        it, so the key is never readable by Users at any point.

        An existing folder is left completely alone: the registrar validates its owner and
        re-applies the ACL, and silently reassigning ownership of a folder someone else set up is
        not this script's decision to make.
    .PARAMETER Path
        The folder to create.
    .OUTPUTS
        System.Boolean - $true when this call created the folder, $false when it already existed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create the install folder restricted to SYSTEM and Administrators')) {
        return $false
    }

    Write-WatchdogGuiLog "Creating $Path, restricted to SYSTEM and Administrators."
    New-Item -Path $Path -ItemType Directory -Force | Out-Null

    # If this fails the registrar will refuse the folder on ownership, so a clear throw here beats
    # a bare exit 2 from a child process: the technician can act on this sentence.
    try {
        $administrators = New-Object System.Security.Principal.SecurityIdentifier($script:WatchdogGuiAdministratorsSid)
        $system = New-Object System.Security.Principal.SecurityIdentifier($script:WatchdogGuiSystemSid)
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetOwner($administrators)
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($system, $administrators)) {
            $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        Set-Acl -LiteralPath $Path -AclObject $security
    }
    catch {
        throw ("Could not secure the install folder '$Path' ($_). Delete that folder and run this tool " +
            'again from an elevated session.')
    }
    return $true
}

function Write-WatchdogGuiConfig {
    <#
    .SYNOPSIS
        Writes ServiceWatchdog.json into the install folder, creating the folder if needed.
    .DESCRIPTION
        Written before the registrar runs so the registrar never takes its "config not yet
        edited, exit 2" first-run path. Because the file holds the function key, the folder is
        created through New-WatchdogGuiProtectedFolder rather than New-Item. UTF-8 without a BOM, because
        the config is also read by the worker under SYSTEM and a BOM buys nothing. Honours -DryRun.
    .PARAMETER Config
        The ordered dictionary from New-WatchdogGuiConfig.
    .PARAMETER Path
        Target file. Defaults to C:\ProgramData\ServiceWatchdog\ServiceWatchdog.json.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Config,

        [string]$Path = $script:WatchdogGuiConfigPath
    )

    $folder = Split-Path -Path $Path -Parent
    $json = $Config | ConvertTo-Json -Depth 6

    if ($script:DryRunMode) {
        Write-WatchdogGuiLog "[DRYRUN] Would write the config to $Path" -Level 'WARNING'
        return $Path
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write ServiceWatchdog.json')) {
        return $Path
    }

    New-WatchdogGuiProtectedFolder -Path $folder -Confirm:$false | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
    Write-WatchdogGuiLog "Config written to $Path ($($Config['Services'].Count) service(s))." -Level 'SUCCESS'
    return $Path
}

function Get-WatchdogGuiInstalledConfig {
    <#
    .SYNOPSIS
        Reads the installed ServiceWatchdog.json, if there is one, so a re-run pre-fills the GUI.
    .DESCRIPTION
        Returns $null when the file is absent or unreadable: a re-run must still work when the
        previous config was hand-edited into something invalid.
    .PARAMETER Path
        Config path. Defaults to the on-device path.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param (
        [string]$Path = $script:WatchdogGuiConfigPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return ConvertTo-WatchdogGuiHashtable -InputObject (ConvertFrom-Json -InputObject $raw -ErrorAction Stop)
    }
    catch {
        Write-WatchdogGuiLog "Existing config at $Path could not be read ($_); starting from defaults." -Level 'WARNING'
        return $null
    }
}

function Get-WatchdogGuiLogChoice {
    <#
    .SYNOPSIS
        Returns the View logs choices, in the order they appear in the drop-down.
    .DESCRIPTION
        One table so the drop-down, the handler and the Pester suite cannot disagree about what
        the choices are: the GUI adds Label to the ComboBox and passes the selected item's Kind
        back into Resolve-WatchdogGuiLogFile, and nothing else parses the label text.
    .OUTPUTS
        PSCustomObject[] with Kind and Label.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param ()

    return @(
        [pscustomobject]@{ Kind = 'WorkerToday'; Label = "Today's worker log" }
        [pscustomobject]@{ Kind = 'WorkerTail'; Label = 'Last 50 worker log lines' }
        [pscustomobject]@{ Kind = 'Events'; Label = 'Last 50 events (Application log)' }
        [pscustomobject]@{ Kind = 'RegistrarLogs'; Label = 'Registrar / uninstaller logs' }
        [pscustomobject]@{ Kind = 'GuiLog'; Label = "This session's GUI log" }
    )
}

function Get-WatchdogGuiNewestLogFile {
    <#
    .SYNOPSIS
        Returns the full path of the most recently written log matching any of the given patterns.
    .DESCRIPTION
        Used for the "newest of a family" choices. A missing folder, an unreadable folder and a
        folder with no match are all the same answer ($null), because every caller reports the
        same "nothing to show yet" sentence for them and a log viewer must never throw.
    .PARAMETER LogRoot
        The Logs folder to search. Not recursive: the endpoint scripts keep one flat folder.
    .PARAMETER Pattern
        One or more wildcard file name patterns, for example ServiceWatchdog-*.log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($LogRoot) -or -not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        return $null
    }
    try {
        $files = @()
        foreach ($item in $Pattern) {
            $files += @(Get-ChildItem -LiteralPath $LogRoot -Filter $item -File -ErrorAction SilentlyContinue)
        }
        # -Filter 'x-*.log' also matches x-1.log.bak on Windows, so the extension is re-checked.
        $newest = @($files |
                Where-Object { $_.Extension -eq '.log' } |
                Sort-Object -Property LastWriteTime -Descending |
                Select-Object -First 1)
        if (@($newest).Count -lt 1) {
            return $null
        }
        return [string]$newest[0].FullName
    }
    catch {
        return $null
    }
}

function Resolve-WatchdogGuiLogFile {
    <#
    .SYNOPSIS
        Resolves a View logs choice to the file it should read.
    .DESCRIPTION
        The daily worker log name (ServiceWatchdog-<yyyyMMdd>.log) and the registrar and
        uninstaller names (Register-WinServiceWatchdogTask-<yyyyMMdd-HHmmss>.log and its
        Unregister- counterpart) are the ones those scripts build themselves; this is the only
        place in the GUI that knows them, so a rename in the endpoint scripts is a one-line fix
        here. The Events choice has no file and returns a $null path.
    .PARAMETER Kind
        A Kind from Get-WatchdogGuiLogChoice.
    .PARAMETER LogRoot
        The Logs folder. Ignored for GuiLog, which is this launch's own log file.
    .PARAMETER Date
        The day whose worker log is wanted. Defaults to today.
    .OUTPUTS
        PSCustomObject with Kind, Path (possibly $null) and Exists.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('WorkerToday', 'WorkerTail', 'Events', 'RegistrarLogs', 'GuiLog')]
        [string]$Kind,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$LogRoot,

        [datetime]$Date = (Get-Date)
    )

    $path = $null
    switch ($Kind) {
        'WorkerToday' {
            if (-not [string]::IsNullOrWhiteSpace($LogRoot)) {
                $path = Join-Path $LogRoot ('ServiceWatchdog-{0}.log' -f $Date.ToString('yyyyMMdd'))
            }
        }
        'WorkerTail' {
            $path = Get-WatchdogGuiNewestLogFile -LogRoot $LogRoot -Pattern @('ServiceWatchdog-*.log')
        }
        'RegistrarLogs' {
            $path = Get-WatchdogGuiNewestLogFile -LogRoot $LogRoot -Pattern @('Register-*.log', 'Unregister-*.log')
        }
        'GuiLog' {
            $path = $script:LogFilePath
        }
        'Events' {
            $path = $null
        }
    }

    $exists = $false
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $exists = [bool](Test-Path -LiteralPath $path -PathType Leaf)
    }
    return [pscustomobject]@{
        Kind   = $Kind
        Path   = $path
        Exists = $exists
    }
}

function Get-WatchdogGuiMissingLogMessage {
    <#
    .SYNOPSIS
        The sentence shown when a View logs choice has nothing to show.
    .DESCRIPTION
        An absent log is normal, not a fault: the worker writes today's file only on its first
        run after midnight, and the registrar log only exists once an install has been attempted.
        Each choice therefore gets a sentence that says why it is empty rather than a bare "file
        not found" a technician would escalate.
    .PARAMETER Kind
        A Kind from Get-WatchdogGuiLogChoice.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('WorkerToday', 'WorkerTail', 'Events', 'RegistrarLogs', 'GuiLog')]
        [string]$Kind
    )

    switch ($Kind) {
        'WorkerToday' {
            return 'No log for today yet: the worker has not run since midnight.'
        }
        'WorkerTail' {
            return 'No worker log found: the watchdog has not run on this server yet.'
        }
        'RegistrarLogs' {
            return 'No registrar or uninstaller log found yet: nothing has been installed or removed on this server.'
        }
        'GuiLog' {
            return "This launch's GUI log file has not been created yet."
        }
        default {
            return ("No events found in the Application log for source $script:WatchdogGuiEventSource yet: the " +
                'event source is created by the registrar.')
        }
    }
}

function Get-WatchdogGuiLogTail {
    <#
    .SYNOPSIS
        Returns the last N lines of a log file, or an empty array when there is nothing to read.
    .DESCRIPTION
        Get-Content -Tail is tried first because it does not read the whole file. It can fail on a
        log the worker still has open, so the fallback re-reads the file with FileShare
        ReadWrite,Delete, the same share mode Read-WatchdogGuiFileTail uses for child output. A
        missing, locked or unreadable file returns an empty array: a log viewer must never throw
        or take the window down.
    .PARAMETER Path
        The log file. $null, empty and absent all return an empty array.
    .PARAMETER Lines
        How many trailing lines to return.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,

        [ValidateRange(1, 100000)]
        [int]$Lines = 50
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    try {
        return @(Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop)
    }
    catch {
        try {
            $text = ''
            $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try {
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $text = $reader.ReadToEnd()
                $reader.Dispose()
            }
            finally {
                $stream.Dispose()
            }
            $all = @(($text -split "`r?`n") | Where-Object { -not [string]::IsNullOrEmpty($_) })
            if (@($all).Count -le $Lines) {
                return @($all)
            }
            return @($all[(@($all).Count - $Lines)..(@($all).Count - 1)])
        }
        catch {
            return @()
        }
    }
}

function Limit-WatchdogGuiDumpLine {
    <#
    .SYNOPSIS
        Caps one log dump so a huge file cannot fill the log pane, keeping the newest lines.
    .DESCRIPTION
        The pane is an unbounded WinForms TextBox: appending a 200,000 line log would take
        minutes and leave the window unusable. The newest lines are the ones a technician wants,
        so the head is dropped and a note naming the file replaces it.
    .PARAMETER Line
        The lines to cap. $null and empty are returned as an empty array.
    .PARAMETER MaxLines
        The cap. 2000 by default.
    .PARAMETER Path
        The file the lines came from, named in the truncation note when supplied.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Line,

        [ValidateRange(1, 100000)]
        [int]$MaxLines = 2000,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    $all = @($Line)
    if (@($all).Count -le $MaxLines) {
        return @($all)
    }

    $note = "... truncated to the last $MaxLines lines; open the file for the rest."
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $note = "... truncated to the last $MaxLines lines; open $Path for the rest."
    }
    $kept = @($all[(@($all).Count - $MaxLines)..(@($all).Count - 1)])
    return @(@($note) + $kept)
}

function Format-WatchdogGuiEvent {
    <#
    .SYNOPSIS
        Renders one Application log event as a single pane line.
    .DESCRIPTION
        'time  Id n  Level  first line of the message'. Only the first non-blank line of the
        message is kept: the worker writes multi-line event bodies and five of those would push
        the previous events out of sight, which defeats the point of a 50 event list.
    .PARAMETER EventRecord
        A Get-WinEvent record, or anything with TimeCreated, Id, LevelDisplayName and Message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [object]$EventRecord
    )

    $time = '(no time)'
    if ($EventRecord.TimeCreated) {
        $time = ([datetime]$EventRecord.TimeCreated).ToString('yyyy-MM-dd HH:mm:ss')
    }

    $level = [string]$EventRecord.LevelDisplayName
    if ([string]::IsNullOrWhiteSpace($level)) { $level = 'Unknown' }

    $first = ''
    $message = [string]$EventRecord.Message
    if (-not [string]::IsNullOrWhiteSpace($message)) {
        $candidate = @(($message -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
            Select-Object -First 1
        if ($null -ne $candidate) { $first = ([string]$candidate).Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($first)) { $first = '(no message text)' }

    return '{0}  Id {1}  {2}  {3}' -f $time, [string]$EventRecord.Id, $level, $first
}

function Get-WatchdogGuiEventLine {
    <#
    .SYNOPSIS
        Reads the last N ServiceWatchdog events from the Application log as formatted lines.
    .DESCRIPTION
        Get-WinEvent throws rather than returning nothing when a filter matches no events, and it
        throws again when the provider has never been registered, which is the normal state of a
        server the watchdog has not been installed on yet. Both are reported as the "nothing yet"
        sentence instead of an error, so pressing View logs before an install is not alarming.
    .PARAMETER MaxEvents
        How many of the newest events to read.
    .PARAMETER ProviderName
        The event source. Defaults to the project's own source.
    .PARAMETER LogName
        The event log. Defaults to Application, where the worker writes.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param (
        [ValidateRange(1, 1000)]
        [int]$MaxEvents = 50,

        [ValidateNotNullOrEmpty()]
        [string]$ProviderName = $script:WatchdogGuiEventSource,

        [ValidateNotNullOrEmpty()]
        [string]$LogName = 'Application'
    )

    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $LogName; ProviderName = $ProviderName } `
                -MaxEvents $MaxEvents -ErrorAction Stop)
    }
    catch {
        $detail = [string]$_
        if ($detail -match 'No events were found' -or $detail -match 'could not be found') {
            return @(Get-WatchdogGuiMissingLogMessage -Kind 'Events')
        }
        return @("Could not read the $LogName log for source $ProviderName ($detail).")
    }

    if (@($events).Count -lt 1) {
        return @(Get-WatchdogGuiMissingLogMessage -Kind 'Events')
    }
    return @($events | ForEach-Object { Format-WatchdogGuiEvent -EventRecord $_ })
}

#endregion


#region GUI

# All GUI state lives in one script-scoped bag so the event handlers below are ordinary
# functions rather than closures. Handlers fire long after Start-WatchdogGui's parameters were
# bound, and a function that reads $script:Gui is far easier to reason about (and to fix at 2am
# on a client server) than a scriptblock relying on captured scope.
$script:Gui = $null

function Get-WatchdogGuiShortNameFromLabel {
    <#
    .SYNOPSIS
        Extracts the short service name from a checked-list label.
    .DESCRIPTION
        Labels are 'Display Name (ShortName) [Status]' and the short name is what the config
        keys on, so this is the one place the label format is parsed. A label that does not match
        (which should never happen) is returned unchanged rather than silently dropped.
    .PARAMETER Label
        The list item text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Label
    )

    if ($Label -match '\(([^()]+)\)\s\[[^\]]*\]$') {
        return $Matches[1]
    }
    return $Label
}

function Write-WatchdogGuiPane {
    <#
    .SYNOPSIS
        Appends one already-scrubbed line to the log pane and keeps it scrolled to the bottom.
    .PARAMETER Line
        The line to append.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line
    )

    if (-not $script:Gui -or -not $script:Gui.LogBox) { return }
    $script:Gui.LogBox.AppendText($Line + "`r`n")
    $script:Gui.LogBox.SelectionStart = $script:Gui.LogBox.TextLength
    $script:Gui.LogBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Write-WatchdogGuiOutputBlock {
    <#
    .SYNOPSIS
        Relays a child script's captured output into the pane, one indented line at a time.
    .PARAMETER Text
        The captured output. Already scrubbed by Invoke-WatchdogGuiChildScript; scrubbed again by
        Write-WatchdogGuiLog, because two cheap passes beat one missed key.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-WatchdogGuiLog ('  | ' + $line.TrimEnd())
        }
    }
}

function Set-WatchdogGuiBusy {
    <#
    .SYNOPSIS
        Disables the controls and shows a "Working..." status while a child script runs.
    .DESCRIPTION
        The child scripts run synchronously (the registrar can take a minute or two), so the only
        thing keeping the window responsive is the DoEvents in Write-WatchdogGuiPane. Disabling the
        buttons is what stops a technician from queueing a second registrar run on top of the
        first.
    .PARAMETER Busy
        $true to lock the UI, $false to release it.
    .PARAMETER Activity
        Short description shown after "Working...".
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object or updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [bool]$Busy,

        [AllowEmptyString()]
        [string]$Activity = ''
    )

    if (-not $script:Gui) { return }
    foreach ($button in $script:Gui.Buttons) { $button.Enabled = -not $Busy }
    $script:Gui.ServiceList.Enabled = -not $Busy
    $script:Gui.SiteBox.Enabled = -not $Busy
    $script:Gui.FilterBox.Enabled = -not $Busy
    if ($script:Gui.LogChoiceBox) { $script:Gui.LogChoiceBox.Enabled = -not $Busy }
    if ($Busy) {
        $script:Gui.StatusItem.Text = "Working... $Activity"
        $script:Gui.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    }
    else {
        $script:Gui.Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-WatchdogGuiCheckedCount {
    <#
    .SYNOPSIS
        Refreshes the "n ticked" counter beside the filter box.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object or updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    if (-not $script:Gui) { return }
    $script:Gui.CountLabel.Text = '{0} ticked' -f $script:Gui.CheckedNames.Count
}

function Update-WatchdogGuiServiceList {
    <#
    .SYNOPSIS
        Rebuilds the checked list for the current filter, preserving the ticks.
    .DESCRIPTION
        The set of ticked short names is the authority, not the list items, so filtering the list
        can never lose a selection the technician made under a different filter.
    .PARAMETER Filter
        Substring matched against both the short name and the display name. Empty shows all.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object or updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Filter
    )

    if (-not $script:Gui) { return }
    $list = $script:Gui.ServiceList
    $script:Gui.Suppress = $true
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($service in $script:Gui.AllServices) {
            if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                $matched = ([string]$service.Name) -like "*$Filter*" -or
                    ([string]$service.DisplayName) -like "*$Filter*"
                if (-not $matched) { continue }
            }
            $index = $list.Items.Add((Format-WatchdogGuiServiceLabel -Service $service))
            if ($script:Gui.CheckedNames.Contains([string]$service.Name)) {
                $list.SetItemChecked($index, $true)
            }
        }
    }
    finally {
        $list.EndUpdate()
        $script:Gui.Suppress = $false
    }
    Update-WatchdogGuiCheckedCount
}

function Update-WatchdogGuiStatusLine {
    <#
    .SYNOPSIS
        Queries the scheduled task and updates the status bar, optionally logging the detail.
    .PARAMETER Detailed
        Also write every status line to the log pane (what Check status does).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object or updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [switch]$Detailed
    )

    if (-not $script:Gui) { return }
    $taskState = $null
    $taskInfo = $null
    try {
        $task = Get-ScheduledTask -TaskName $script:WatchdogGuiTaskName -ErrorAction SilentlyContinue
        if ($task) {
            $taskState = $task.State
            $taskInfo = Get-ScheduledTaskInfo -TaskName $script:WatchdogGuiTaskName -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-WatchdogGuiLog "Could not query the scheduled task '$script:WatchdogGuiTaskName': $_" -Level 'WARNING'
    }
    $configPresent = [bool](Test-Path -LiteralPath $script:WatchdogGuiConfigPath -PathType Leaf)
    # This runs while the window is being built, so a formatting problem must degrade to a
    # warning in the status bar rather than propagate and close the GUI before it opens.
    try {
        $lines = Format-WatchdogGuiTaskStatus -TaskState $taskState -TaskInfo $taskInfo -ConfigPresent:$configPresent
    }
    catch {
        Write-WatchdogGuiLog "Could not format the task status: $_" -Level 'WARNING'
        $lines = @("Status unavailable: $_ (Check status will retry; the log pane has the detail).")
    }
    $script:Gui.StatusItem.Text = $lines[0]
    if ($Detailed) {
        foreach ($line in $lines) { Write-WatchdogGuiLog $line }
    }
}

function Show-WatchdogGuiMessage {
    <#
    .SYNOPSIS
        Shows a message box. Wrapped so every dialog in the GUI looks the same.
    .PARAMETER Message
        Body text. Scrubbed, because child script text can reach a dialog too.
    .PARAMETER Title
        Caption.
    .PARAMETER Icon
        Information, Warning or Error.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [string]$Title = 'ServiceWatchdog',

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Icon = 'Information'
    )

    [void][System.Windows.Forms.MessageBox]::Show((Remove-WatchdogGuiSecretText -Text $Message), $Title, 'OK', $Icon)
}

function Get-WatchdogGuiLogLevelForResult {
    <#
    .SYNOPSIS
        Maps an exit-code result object's severity onto a Write-WatchdogGuiLog level.
    .PARAMETER Result
        Output of Get-WatchdogGuiExitCodeMeaning.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [object]$Result
    )

    if ($Result.IsSuccess) { return 'SUCCESS' }
    if ($Result.Severity -eq 'Warning') { return 'WARNING' }
    return 'ERROR'
}

function Invoke-WatchdogGuiInstallAction {
    <#
    .SYNOPSIS
        Install: writes the config, then runs the registrar with -RunNow -Force.
    .DESCRIPTION
        Writing the config first is deliberate: the registrar's documented first-run behaviour is
        to copy the example config and exit 2 asking the operator to edit it, and that path must
        never be reached here. On a server that already has the watchdog this is an update, which
        is why -Force is passed: the worker is already present in the install folder and the
        registrar refuses to overwrite it otherwise.

        -TestAlert is deliberately not passed. Installing and proving email delivery are separate
        decisions: an Azure-side problem used to turn a perfectly good install into the registrar's
        exit 10, and a technician who wanted a second test email had to re-run the whole
        registration. The success dialog therefore points at Send test alert, which exercises the
        installed worker on its own.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    try {
        $siteName = $script:Gui.SiteBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($siteName)) {
            Show-WatchdogGuiMessage -Message 'Enter a site name first.' -Icon 'Warning'
            return
        }
        if ($siteName -cmatch 'REPLACE') {
            Show-WatchdogGuiMessage -Message 'The site name still contains REPLACE. Enter the real site name.' `
                -Icon 'Warning'
            return
        }
        if ($script:Gui.CheckedNames.Count -lt 1) {
            Show-WatchdogGuiMessage -Message 'Tick at least one service to watch.' -Icon 'Warning'
            return
        }

        Set-WatchdogGuiBusy -Busy $true -Activity 'writing the config and registering the task'
        Write-WatchdogGuiLog "--- Install: site '$siteName', $($script:Gui.CheckedNames.Count) service(s) ---"

        $config = New-WatchdogGuiConfig -Settings $script:Gui.Settings -SiteName $siteName `
            -Service @($script:Gui.CheckedNames)
        Write-WatchdogGuiLog ('Services: ' + (@($config['Services']) -join ', '))
        Write-WatchdogGuiConfig -Config $config -Path $script:WatchdogGuiConfigPath -Confirm:$false | Out-Null

        # -ConfigPath and -SourcePath are always explicit: the registrar defaults SourcePath to
        # its own folder and ConfigPath to <InstallPath>\ServiceWatchdog.json, and relying on
        # either would break the moment this package is run from a mapped drive or a subfolder.
        $arguments = @(
            '-ConfigPath', $script:WatchdogGuiConfigPath,
            '-SourcePath', $script:Gui.Paths.EndpointPath,
            '-InstallPath', $script:WatchdogGuiInstallPath,
            '-TaskName', $script:WatchdogGuiTaskName,
            '-RunNow', '-Force', '-Verbosity', 'High'
        )
        $result = Invoke-WatchdogGuiChildScript -ScriptPath $script:Gui.Paths.Register -ArgumentList $arguments
        if (-not $result.Streamed) { Write-WatchdogGuiOutputBlock -Text $result.Output }
        $mapped = Get-WatchdogGuiExitCodeMeaning -ExitCode $result.ExitCode -Script 'Register'
        Write-WatchdogGuiLog "Registrar exit $($mapped.ExitCode): $($mapped.Meaning)" `
            -Level (Get-WatchdogGuiLogLevelForResult -Result $mapped)

        $message = $mapped.Meaning
        $icon = 'Warning'
        if ($mapped.IsSuccess) {
            $message = $mapped.Meaning + "`r`n`r`nNo test email was sent. Press Send test alert to prove " +
            'delivery, then check the inbox for the [TEST] email.'
            $icon = 'Information'
        }
        Show-WatchdogGuiMessage -Message $message -Title 'Install' -Icon $icon
    }
    catch {
        Write-WatchdogGuiLog "Install failed: $_" -Level 'ERROR'
        Show-WatchdogGuiMessage -Message "Install failed:`r`n$_" -Title 'Install' -Icon 'Error'
    }
    finally {
        Set-WatchdogGuiBusy -Busy $false
        Update-WatchdogGuiStatusLine
    }
}

function Invoke-WatchdogGuiTestAlertAction {
    <#
    .SYNOPSIS
        Send test alert: runs the installed worker with -TestAlert.
    .DESCRIPTION
        Deliberately runs the copy in the install folder, not the pinned source copy, so what is
        tested is what the scheduled task actually executes.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    try {
        if (-not (Test-Path -LiteralPath $script:WatchdogGuiWorkerPath -PathType Leaf)) {
            Show-WatchdogGuiMessage -Message ("The worker is not installed yet at $script:WatchdogGuiWorkerPath. " +
                'Run Install first.') -Icon 'Warning'
            return
        }
        Set-WatchdogGuiBusy -Busy $true -Activity 'sending a test alert'
        Write-WatchdogGuiLog '--- Send test alert ---'
        $result = Invoke-WatchdogGuiChildScript -ScriptPath $script:WatchdogGuiWorkerPath -ArgumentList @(
            '-ConfigPath', $script:WatchdogGuiConfigPath, '-TestAlert', '-Verbosity', 'High')
        if (-not $result.Streamed) { Write-WatchdogGuiOutputBlock -Text $result.Output }
        $mapped = Get-WatchdogGuiExitCodeMeaning -ExitCode $result.ExitCode -Script 'Worker'
        Write-WatchdogGuiLog "Worker exit $($mapped.ExitCode): $($mapped.Meaning)" `
            -Level (Get-WatchdogGuiLogLevelForResult -Result $mapped)

        $message = $mapped.Meaning
        $icon = 'Warning'
        if ($mapped.IsSuccess) {
            $message = 'Test alert accepted by the webhook. Check the inbox for the [TEST] email.'
            $icon = 'Information'
        }
        Show-WatchdogGuiMessage -Message $message -Title 'Send test alert' -Icon $icon
    }
    catch {
        Write-WatchdogGuiLog "Send test alert failed: $_" -Level 'ERROR'
        Show-WatchdogGuiMessage -Message "Send test alert failed:`r`n$_" -Title 'Send test alert' -Icon 'Error'
    }
    finally {
        Set-WatchdogGuiBusy -Busy $false
    }
}

function Invoke-WatchdogGuiStatusAction {
    <#
    .SYNOPSIS
        Check status: task state and last result, a -ValidateConfig pass, and the worker log tail.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    try {
        Set-WatchdogGuiBusy -Busy $true -Activity 'collecting status'
        Write-WatchdogGuiLog '--- Check status ---'
        Update-WatchdogGuiStatusLine -Detailed

        if (Test-Path -LiteralPath $script:WatchdogGuiWorkerPath -PathType Leaf) {
            $result = Invoke-WatchdogGuiChildScript -ScriptPath $script:WatchdogGuiWorkerPath -ArgumentList @(
                '-ConfigPath', $script:WatchdogGuiConfigPath, '-ValidateConfig', '-Verbosity', 'High')
            if (-not $result.Streamed) { Write-WatchdogGuiOutputBlock -Text $result.Output }
            if ($result.ExitCode -eq 0) {
                Write-WatchdogGuiLog 'Config validation passed (worker exit 0).' -Level 'SUCCESS'
            }
            else {
                # A bad config means the watchdog is silently not protecting anything, so this one
                # gets a dialog: a red line in the pane is too easy to scroll past.
                $mapped = Get-WatchdogGuiExitCodeMeaning -ExitCode $result.ExitCode -Script 'Worker'
                Write-WatchdogGuiLog "Config validation failed, worker exit $($mapped.ExitCode): $($mapped.Meaning)" `
                    -Level 'ERROR'
                Show-WatchdogGuiMessage -Message ("The installed config at $script:WatchdogGuiConfigPath did not validate " +
                    "(worker exit $($result.ExitCode)).`r`n`r`n$($mapped.Meaning)`r`n`r`nThe log pane has the " +
                    'worker lines that say which value is wrong. Fix the site name or the service list here ' +
                    'and use Install to rewrite the config.') -Title 'Check status' -Icon 'Error'
            }
        }
        else {
            Write-WatchdogGuiLog "No installed worker at $script:WatchdogGuiWorkerPath; nothing to validate." -Level 'WARNING'
            Show-WatchdogGuiMessage -Message ('The watchdog is not installed on this server yet: there is no worker at ' +
                "$script:WatchdogGuiWorkerPath.`r`n`r`nTick the services to watch and use Install.") `
                -Title 'Check status' -Icon 'Warning'
        }

        # Same resolver and reader the View logs drop-down uses, so the daily log name lives in
        # exactly one place.
        $today = Resolve-WatchdogGuiLogFile -Kind 'WorkerToday' -LogRoot $script:WatchdogGuiWorkerLogRoot
        if ($today.Exists) {
            Write-WatchdogGuiLog "Last 20 lines of $($today.Path)"
            foreach ($line in @(Get-WatchdogGuiLogTail -Path $today.Path -Lines 20)) {
                Write-WatchdogGuiLog ('  | ' + $line)
            }
            Write-WatchdogGuiLog 'View logs has the whole file, the event list and the registrar log.'
        }
        else {
            Write-WatchdogGuiLog ("$(Get-WatchdogGuiMissingLogMessage -Kind 'WorkerToday') Expected " +
                "$($today.Path).") -Level 'WARNING'
        }
    }
    catch {
        Write-WatchdogGuiLog "Check status failed: $_" -Level 'ERROR'
        Show-WatchdogGuiMessage -Message "Check status failed:`r`n$_" -Title 'Check status' -Icon 'Error'
    }
    finally {
        Set-WatchdogGuiBusy -Busy $false
    }
}

function Invoke-WatchdogGuiViewLogAction {
    <#
    .SYNOPSIS
        View logs: writes the selected log, event list or file tail into the log pane.
    .DESCRIPTION
        Everything a technician needs after an install is in %ProgramData%\ServiceWatchdog\Logs or
        the Application log, and on a locked-down server opening either from Explorer is a detour
        this window can save. The pane is the only output: no file is opened, nothing is copied,
        and the chosen dump is bracketed by a header and a footer line so two viewings in a row
        cannot be read as one.

        The whole dump goes through Write-WatchdogGuiLog like every other line, so it is scrubbed
        of the function key and lands in the GUI's own log file as well as the pane.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    try {
        if (-not $script:Gui) { return }
        $choices = @(Get-WatchdogGuiLogChoice)
        $index = [int]$script:Gui.LogChoiceBox.SelectedIndex
        if ($index -lt 0 -or $index -ge @($choices).Count) { $index = 0 }
        $choice = $choices[$index]

        Set-WatchdogGuiBusy -Busy $true -Activity 'reading logs'
        Write-WatchdogGuiLog ('--- View logs: {0} ---' -f $choice.Label)

        $lines = @()
        if ($choice.Kind -eq 'Events') {
            $lines = @(Get-WatchdogGuiEventLine -MaxEvents 50)
        }
        else {
            $resolved = Resolve-WatchdogGuiLogFile -Kind $choice.Kind -LogRoot $script:WatchdogGuiWorkerLogRoot
            if (-not $resolved.Exists) {
                $lines = @(Get-WatchdogGuiMissingLogMessage -Kind $choice.Kind)
                if ($resolved.Path) { $lines += "Expected $($resolved.Path)." }
            }
            else {
                Write-WatchdogGuiLog "File: $($resolved.Path)"
                # Today's worker log is shown in full (capped); every other choice is a 50 line tail.
                $wanted = 50
                if ($choice.Kind -eq 'WorkerToday') { $wanted = 100000 }
                $lines = @(Limit-WatchdogGuiDumpLine -Line @(Get-WatchdogGuiLogTail -Path $resolved.Path `
                            -Lines $wanted) -Path $resolved.Path)
                if (@($lines).Count -lt 1) { $lines = @('The file is empty.') }
            }
        }

        foreach ($line in $lines) { Write-WatchdogGuiLog ('  | ' + [string]$line) }
        Write-WatchdogGuiLog ('--- end of {0} ---' -f $choice.Label)
    }
    catch {
        Write-WatchdogGuiLog "View logs failed: $_" -Level 'ERROR'
        Show-WatchdogGuiMessage -Message "View logs failed:`r`n$_" -Title 'View logs' -Icon 'Error'
    }
    finally {
        Set-WatchdogGuiBusy -Busy $false
    }
}

function Invoke-WatchdogGuiUninstallAction {
    <#
    .SYNOPSIS
        Uninstall: confirms, then runs the unregistrar to remove the scheduled task.
    .DESCRIPTION
        -RemoveFiles and -RemoveEventSource are intentionally not passed. Leaving the install
        folder means a re-install needs no new function key, and the worker log and event history
        survive for whoever is investigating why the watchdog was removed.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param ()

    try {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Remove the '$script:WatchdogGuiTaskName' scheduled task from this server?`r`n`r`n" +
                'The install folder, config and logs are left in place, so a re-install needs no new key.'),
            'Uninstall', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        Set-WatchdogGuiBusy -Busy $true -Activity 'removing the scheduled task'
        Write-WatchdogGuiLog '--- Uninstall ---'
        $result = Invoke-WatchdogGuiChildScript -ScriptPath $script:Gui.Paths.Unregister -ArgumentList @(
            '-TaskName', $script:WatchdogGuiTaskName, '-InstallPath', $script:WatchdogGuiInstallPath, '-Verbosity', 'High')
        if (-not $result.Streamed) { Write-WatchdogGuiOutputBlock -Text $result.Output }
        $mapped = Get-WatchdogGuiExitCodeMeaning -ExitCode $result.ExitCode -Script 'Unregister'
        Write-WatchdogGuiLog "Unregistrar exit $($mapped.ExitCode): $($mapped.Meaning)" `
            -Level (Get-WatchdogGuiLogLevelForResult -Result $mapped)
        $icon = 'Information'
        if (-not $mapped.IsSuccess) { $icon = 'Error' }
        Show-WatchdogGuiMessage -Message $mapped.Meaning -Title 'Uninstall' -Icon $icon
    }
    catch {
        Write-WatchdogGuiLog "Uninstall failed: $_" -Level 'ERROR'
        Show-WatchdogGuiMessage -Message "Uninstall failed:`r`n$_" -Title 'Uninstall' -Icon 'Error'
    }
    finally {
        Set-WatchdogGuiBusy -Busy $false
        Update-WatchdogGuiStatusLine
    }
}

function Start-WatchdogGui {
    <#
    .SYNOPSIS
        Builds and runs the ServiceWatchdog window. The only function that creates WinForms
        controls.
    .DESCRIPTION
        Checks the refusal conditions first (Windows, elevated, Endpoint\ present, settings usable
        and filled in) so nothing is built for a run that cannot succeed, then populates the
        service list and pre-fills from an existing install before showing the form modally.
    .PARAMETER PackageRoot
        The package folder holding Endpoint\ and ServiceWatchdog.settings.json.
    .PARAMETER SettingsFile
        Override for ServiceWatchdog.settings.json.
    .OUTPUTS
        System.Int32 - the process exit code: 0 the window opened and was closed, 2 a refusal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an object or updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PackageRoot,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$SettingsFile
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $paths = Get-WatchdogGuiPackagePath -Root $PackageRoot -SettingsFile $SettingsFile

    #region Refusals

    # Each of these is a stop, not a warning: continuing would either fail deeper inside a child
    # script with a message the technician cannot act on, or install a watchdog that cannot alert.
    $refusal = $null
    if (-not (Test-WatchdogGuiWindows)) {
        $refusal = 'ServiceWatchdog can only be installed on Windows.'
    }
    elseif (-not (Test-WatchdogGuiElevation)) {
        $refusal = 'This tool must run elevated. Close this window, double-click ' +
        'Run-ServiceWatchdog.cmd and accept the UAC prompt.'
    }
    elseif (-not (Test-WatchdogGuiSingleThreadedApartment)) {
        $refusal = 'This tool must run in a single threaded apartment, which WinForms requires. Close this ' +
        'window and double-click Run-ServiceWatchdog.cmd, which passes -STA for you.'
    }
    elseif (-not (Test-Path -LiteralPath $paths.Register -PathType Leaf)) {
        $refusal = "Register-WinServiceWatchdogTask.ps1 was not found in '$($paths.EndpointPath)', and " +
        "there is no Endpoint folder beside '$($paths.Root)' either. Copy the whole ServiceWatchdog " +
        'folder to the server, Endpoint\ included.'
    }

    $settings = $null
    if (-not $refusal) {
        $settingsResult = Resolve-WatchdogGuiSettings -Path $paths.SettingsPath
        if ($settingsResult.IsValid) {
            $settings = $settingsResult.Settings
        }
        else {
            $refusal = "The settings file is not usable:`r`n`r`n" + (@($settingsResult.Errors) -join "`r`n")
        }
    }

    if ($refusal) {
        Write-WatchdogGuiLog $refusal -Level 'ERROR'
        [void][System.Windows.Forms.MessageBox]::Show($refusal, 'ServiceWatchdog - cannot start', 'OK', 'Error')
        return 2
    }

    # Registered before any child output can reach the pane, so the key can never be displayed.
    $script:SecretValues = @([string]$settings['Webhook']['FunctionKey'])

    #endregion

    #region Form layout

    $clientName = [string]$settings['ClientName']
    if ([string]::IsNullOrWhiteSpace($clientName)) { $clientName = 'ServiceWatchdog' }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "ServiceWatchdog $([char]0x2013) $clientName"
    $form.Size = New-Object System.Drawing.Size(940, 780)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 660)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $siteLabel = New-Object System.Windows.Forms.Label
    $siteLabel.Text = 'Site name (appears in the alert emails):'
    $siteLabel.Location = New-Object System.Drawing.Point(12, 12)
    $siteLabel.AutoSize = $true

    $siteBox = New-Object System.Windows.Forms.TextBox
    $siteBox.Location = New-Object System.Drawing.Point(12, 32)
    $siteBox.Size = New-Object System.Drawing.Size(360, 24)
    $siteBox.MaxLength = 64

    $filterLabel = New-Object System.Windows.Forms.Label
    $filterLabel.Text = 'Filter services (name or display name):'
    $filterLabel.Location = New-Object System.Drawing.Point(396, 12)
    $filterLabel.AutoSize = $true

    $filterBox = New-Object System.Windows.Forms.TextBox
    $filterBox.Location = New-Object System.Drawing.Point(396, 32)
    $filterBox.Size = New-Object System.Drawing.Size(300, 24)

    $countLabel = New-Object System.Windows.Forms.Label
    $countLabel.Location = New-Object System.Drawing.Point(710, 35)
    $countLabel.AutoSize = $true
    $countLabel.Text = '0 ticked'

    $serviceList = New-Object System.Windows.Forms.CheckedListBox
    $serviceList.Location = New-Object System.Drawing.Point(12, 64)
    $serviceList.Size = New-Object System.Drawing.Size(900, 300)
    $serviceList.Anchor = 'Top,Left,Right'
    $serviceList.CheckOnClick = $true
    $serviceList.IntegralHeight = $false

    $buttonTop = 376
    $installButton = New-Object System.Windows.Forms.Button
    $installButton.Text = 'Install'
    $installButton.Location = New-Object System.Drawing.Point(12, $buttonTop)
    $installButton.Size = New-Object System.Drawing.Size(150, 32)
    $installButton.Anchor = 'Top,Left'

    $testButton = New-Object System.Windows.Forms.Button
    $testButton.Text = 'Send test alert'
    $testButton.Location = New-Object System.Drawing.Point(172, $buttonTop)
    $testButton.Size = New-Object System.Drawing.Size(150, 32)
    $testButton.Anchor = 'Top,Left'

    $statusButton = New-Object System.Windows.Forms.Button
    $statusButton.Text = 'Check status'
    $statusButton.Location = New-Object System.Drawing.Point(332, $buttonTop)
    $statusButton.Size = New-Object System.Drawing.Size(150, 32)
    $statusButton.Anchor = 'Top,Left'

    $uninstallButton = New-Object System.Windows.Forms.Button
    $uninstallButton.Text = 'Uninstall'
    $uninstallButton.Location = New-Object System.Drawing.Point(492, $buttonTop)
    $uninstallButton.Size = New-Object System.Drawing.Size(150, 32)
    $uninstallButton.Anchor = 'Top,Left'

    # Second row: the log viewer. Its own row rather than a fifth action button, because reading a
    # log is a different kind of act from installing or removing one and should not sit a
    # mis-click away from Uninstall.
    $viewTop = $buttonTop + 40
    $viewLabel = New-Object System.Windows.Forms.Label
    $viewLabel.Text = 'Logs:'
    $viewLabel.Location = New-Object System.Drawing.Point(12, ($viewTop + 6))
    $viewLabel.AutoSize = $true

    $logChoiceBox = New-Object System.Windows.Forms.ComboBox
    $logChoiceBox.Location = New-Object System.Drawing.Point(56, $viewTop)
    $logChoiceBox.Size = New-Object System.Drawing.Size(266, 24)
    $logChoiceBox.DropDownStyle = 'DropDownList'
    $logChoiceBox.Anchor = 'Top,Left'
    foreach ($choice in @(Get-WatchdogGuiLogChoice)) {
        [void]$logChoiceBox.Items.Add($choice.Label)
    }
    $logChoiceBox.SelectedIndex = 0

    $viewButton = New-Object System.Windows.Forms.Button
    $viewButton.Text = 'View logs'
    $viewButton.Location = New-Object System.Drawing.Point(332, $viewTop)
    $viewButton.Size = New-Object System.Drawing.Size(150, 28)
    $viewButton.Anchor = 'Top,Left'

    $logLabel = New-Object System.Windows.Forms.Label
    $logLabel.Text = 'Log (mirrors the underlying scripts; the function key is never shown):'
    $logLabel.Location = New-Object System.Drawing.Point(12, 452)
    $logLabel.AutoSize = $true

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(12, 472)
    $logBox.Size = New-Object System.Drawing.Size(900, 234)
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = 'Both'
    $logBox.WordWrap = $false
    $logBox.BackColor = [System.Drawing.Color]::White
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $logBox.Anchor = 'Top,Left,Right,Bottom'

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusItem.Text = 'Starting...'
    [void]$statusStrip.Items.Add($statusItem)

    $form.Controls.AddRange(@($siteLabel, $siteBox, $filterLabel, $filterBox, $countLabel, $serviceList,
            $installButton, $testButton, $statusButton, $uninstallButton, $viewLabel, $logChoiceBox, $viewButton,
            $logLabel, $logBox, $statusStrip))

    $script:Gui = @{
        Form         = $form
        SiteBox      = $siteBox
        FilterBox    = $filterBox
        CountLabel   = $countLabel
        ServiceList  = $serviceList
        LogChoiceBox = $logChoiceBox
        LogBox       = $logBox
        StatusItem   = $statusItem
        Buttons      = @($installButton, $testButton, $statusButton, $uninstallButton, $viewButton)
        AllServices  = @()
        CheckedNames = (New-Object System.Collections.Generic.HashSet[string] `
                ([System.StringComparer]::OrdinalIgnoreCase))
        Suppress     = $false
        Paths        = $paths
        Settings     = $settings
    }
    $script:PaneWriter = { param ($line) Write-WatchdogGuiPane -Line $line }
    # Lets Invoke-WatchdogGuiChildScript keep the window repainting during a long registrar run without the
    # helper region having to reference WinForms (which is what keeps it dot-sourceable off Windows).
    $script:UiPump = { [System.Windows.Forms.Application]::DoEvents() }

    #endregion

    #region Event handlers

    $filterBox.Add_TextChanged({ Update-WatchdogGuiServiceList -Filter $script:Gui.FilterBox.Text.Trim() })

    $serviceList.Add_ItemCheck({
            param ($listSender, $checkEvent)
            if ($script:Gui.Suppress) { return }
            $name = Get-WatchdogGuiShortNameFromLabel -Label ([string]$listSender.Items[$checkEvent.Index])
            if ($checkEvent.NewValue -eq [System.Windows.Forms.CheckState]::Checked) {
                [void]$script:Gui.CheckedNames.Add($name)
            }
            else {
                [void]$script:Gui.CheckedNames.Remove($name)
            }
            Update-WatchdogGuiCheckedCount
        })

    $installButton.Add_Click({ Invoke-WatchdogGuiInstallAction })
    $testButton.Add_Click({ Invoke-WatchdogGuiTestAlertAction })
    $statusButton.Add_Click({ Invoke-WatchdogGuiStatusAction })
    $viewButton.Add_Click({ Invoke-WatchdogGuiViewLogAction })
    $uninstallButton.Add_Click({ Invoke-WatchdogGuiUninstallAction })
    $form.Add_FormClosed({
            $script:PaneWriter = $null
            $script:UiPump = $null
        })

    #endregion

    #region Initial population

    Write-WatchdogGuiLog "GUI started. Package folder: $($paths.Root)"
    Write-WatchdogGuiLog "Settings loaded from $($paths.SettingsPath); the function key is never displayed."
    if ($script:DryRunMode) {
        Write-WatchdogGuiLog '[DRYRUN] Rehearsal mode: no config is written and no child script runs.' -Level 'WARNING'
    }

    # Deliberately not -ErrorAction Stop. On a real server Get-Service emits a non-terminating
    # error for every service whose configuration the caller cannot read, and with the script-wide
    # $ErrorActionPreference = 'Stop' a single one of those would abort the whole enumeration and
    # leave the technician looking at an empty list. Skipped services are counted and reported
    # instead, and an empty list is a dialog rather than a line in the pane nobody reads.
    try {
        $serviceErrors = @()
        $raw = @(Get-Service -ErrorAction SilentlyContinue -ErrorVariable +serviceErrors |
                Select-Object -Property Name, DisplayName, Status)
        $script:Gui.AllServices = Get-WatchdogGuiSortedServiceList -Service $raw
        Write-WatchdogGuiLog "Found $($script:Gui.AllServices.Count) services on $env:COMPUTERNAME."
        if (@($serviceErrors).Count -gt 0) {
            Write-WatchdogGuiLog ("$(@($serviceErrors).Count) service(s) could not be read (access denied or a broken " +
                'registration) and are not listed.') -Level 'WARNING'
        }
    }
    catch {
        Write-WatchdogGuiLog "Could not enumerate services: $_" -Level 'ERROR'
        $script:Gui.AllServices = @()
    }

    if (@($script:Gui.AllServices).Count -lt 1) {
        Show-WatchdogGuiMessage -Message ('No services could be read from this server, so there is nothing to tick. ' +
            "Check that this window is elevated and that the Service Control Manager is healthy, then " +
            'close and run Run-ServiceWatchdog.cmd again.') -Icon 'Error'
    }

    $existing = Get-WatchdogGuiInstalledConfig -Path $script:WatchdogGuiConfigPath
    if ($existing) {
        $siteBox.Text = [string]$existing['SiteName']
        foreach ($name in @($existing['Services'])) {
            if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
                [void]$script:Gui.CheckedNames.Add([string]$name)
            }
        }
        Write-WatchdogGuiLog ("Existing install found: site '$($siteBox.Text)', $($script:Gui.CheckedNames.Count) " +
            'service(s) already watched. Install rewrites the config with the current selection.')
    }
    else {
        $siteBox.Text = $env:COMPUTERNAME
        Write-WatchdogGuiLog 'No installed config found; site name pre-filled with the computer name.'
    }

    Update-WatchdogGuiServiceList -Filter ''
    Update-WatchdogGuiStatusLine

    #endregion

    [void]$form.ShowDialog()
    $form.Dispose()
    $script:Gui = $null
    return 0
}

#endregion

#region Main

# Guard: dot-sourcing (InvocationName '.') or -NoGui loads the helpers and stops, which is how the
# Pester suite tests them on a machine that has no WinForms.
if (-not $NoGui -and $MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        Initialize-WatchdogGuiLog -Path $LogPath | Out-Null
        Write-WatchdogGuiLog "=== Install-WinServiceWatchdogGui 1.1.1 starting on $env:COMPUTERNAME ===" -NoPane
        Write-WatchdogGuiLog ("Parameters: PackageRoot='$PackageRoot' SettingsPath='$SettingsPath' " +
            "Verbosity=$Verbosity DryRun=$($DryRun.IsPresent)") -NoPane
        $exitCode = Start-WatchdogGui -PackageRoot $PackageRoot -SettingsFile $SettingsPath
    }
    catch {
        Write-WatchdogGuiLog "Unexpected error: $_" -Level 'ERROR'
        Write-WatchdogGuiLog "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR' -NoPane
        $exitCode = 1
    }
    finally {
        Write-WatchdogGuiLog "=== Install-WinServiceWatchdogGui finished with exit code $exitCode ===" -NoPane
    }
    exit $exitCode
}

#endregion
