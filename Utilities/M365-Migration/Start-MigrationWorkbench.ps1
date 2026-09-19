#Requires -Version 7.4

<#
.SYNOPSIS
    The one front door on the M365 migration toolkit: console workbench, WinForms workbench, or a
    single step run non-interactively.

.DESCRIPTION
    Docs/Workbench-Design.md, section 10. This script owns no migration logic at all. It picks a
    mode, finds the workspace, opens the run log, and hands the work to the engine functions in
    M365Migration: Show-MigrationWorkbench for the console, Start-MigrationWorkbenchGui for the
    window, and Get-MigrationStep / Resolve-MigrationStepArguments / Test-MigrationStepGate /
    New-MigrationStepDriver / Invoke-MigrationStep for a non-interactive run. Nothing here
    bypasses a toolkit script; the workbench only builds the command an operator could have typed.

    Three ways in, decided by Select-WorkbenchMode and nothing else:

      * -Step names a step        -> NonInteractive. -Workspace is required, the run exits with
                                     the step's exit code, and no question is ever asked.
      * Windows, no -Console      -> Gui. The WinForms window.
      * anything else             -> Console. The default off Windows, and what -Console forces
                                     on Windows.

    The platform is decided before any WinForms assembly is touched, because WinForms does not
    exist off Windows and loading it to find that out would abort the session on macOS and Linux.

    The workbench's own log lands in <workspace>/Workbench/ beside the run ledger, so a
    technician reading a workspace afterwards finds the front end's account of the session next
    to the runs it started. With no workspace known yet - a console session that has not picked
    one, or a refusal before the pick - it lands in the default output root instead.

    A non-interactive run answers a hard gate through -Set @{ Acknowledge = '<what it asks for>' }
    and nothing else: there is no console to type into, and a gate that cannot be typed at must
    not become a gate that is skipped. Soft gates warn and the run proceeds, and each one is
    recorded in the ledger as an override so the next reader knows what was waved through.

.PARAMETER Workspace
    The migration folder: everything the migration reads and writes lives under it, and it is
    what every step receives as -OutputPath. Required with -Step. Omit it in console mode and the
    workbench offers the recent list, the folders under the default output root, and a path.

.PARAMETER Console
    Force the console workbench on Windows, where the WinForms window is otherwise the default.
    Off Windows the console is the only mode and this switch changes nothing.

.PARAMETER Step
    Run this one step and exit with its exit code, asking nothing. The id is a step instance id
    such as 'New-Users' or 'DomainReferences-Remediate'; Get-MigrationStep lists them all.

.PARAMETER Wave
    One or more wave labels to limit the run to. Omit for the whole plan.

.PARAMETER DryRun
    Rehearse the step: the child script reads everything, calculates everything and changes
    nothing. The run is recorded in the ledger as a rehearsal, which is what the DryRunFirst gate
    reads later.

.PARAMETER Set
    Parameter overrides for a non-interactive run, as a hashtable of the child script's own
    parameter names. The one key that is not a script parameter is 'Acknowledge': it carries the
    typed confirmation a hard gate demands, and it is removed before the rest reach the script.

.PARAMETER Verbosity
    Console detail for this script's own messages: Low, Medium (default) or High. The log file
    always receives every line, and a child step's verbosity comes from the workspace settings.

.PARAMETER LogPath
    Overrides this script's own log file path.

.PARAMETER NoGui
    Load the helper functions and stop: no mode is chosen, no UI is built and nothing is run.
    Used by the Pester suite, and by anyone who wants to dot-source the helpers.

.EXAMPLE
    ./Start-MigrationWorkbench.ps1

    Opens the workbench - the window on Windows, the console board everywhere else - and offers
    the recent workspaces and the folders under the default output root.

.EXAMPLE
    ./Start-MigrationWorkbench.ps1 -Console -Workspace ~/Migration-Automations/Contoso

    Opens the console board on that workspace, on any platform.

.EXAMPLE
    ./Start-MigrationWorkbench.ps1 -Workspace ~/Migration-Automations/Contoso -Step New-Users -DryRun

    Rehearses the provisioning step and exits with its exit code. Nothing is asked and nothing is
    changed.

.EXAMPLE
    ./Start-MigrationWorkbench.ps1 -Workspace ~/Migration-Automations/Contoso `
        -Step DomainReferences-Remediate -Set @{ Acknowledge = 'newco.com' }

    Answers the step's typed-confirmation gate the only way an unattended run can, and runs it
    live against the source tenant.

.NOTES
    Author: AutomationHub
    Version:         1.0.0   the workbench's own version ($script:Version), stamped into the
                             banner and into the header of every driver file it writes.
    Toolkit Version: 1.2.0   the release these 17 scripts and the M365Migration module ship in.
    Written with assistance from Claude (Anthropic).

    Exit codes: 0 the session ran and was closed normally, or the step succeeded; 1 an
    unexpected error; 2 a refusal - no workspace, a workspace folder that is not there, settings
    that will not load, an unknown step id, a parameter set that is still short of a mandatory
    value, or a hard gate that was not acknowledged - or the step's own exit code 2; 130 the run
    was aborted. Any other code is the step's own, passed through unchanged.

    No secret ever reaches the driver file or the settings file. A step that takes a
    -ClientSecret and has no certificate thumbprint configured reads the secret from
    $env:M365MIGRATION_CLIENT_SECRET and passes it to the child process's environment block only.

    Cross-platform: the console workbench and every offline planning step run on macOS, Linux
    and Windows. Only the WinForms window is Windows-only, and it is never loaded elsewhere.
#>

[CmdletBinding()]
param (
    [string]$Workspace,

    [switch]$Console,

    [string]$Step,

    [string[]]$Wave,

    [switch]$DryRun,

    [hashtable]$Set,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium',

    [string]$LogPath,

    [switch]$NoGui
)

#region Configuration & Constants

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# One constant, passed to the console front end and stamped into every driver file, so the
# artefact of a run says which workbench wrote it.
$script:Version = '1.0.0'

# The recent-workspace list: a JSON array of paths, newest first. It is a convenience for the
# picker and nothing depends on it, which is why every failure to read it is an empty list rather
# than an error. Script-scoped so the Pester suite can point it somewhere harmless.
$script:WorkbenchRecentPath = if ($IsWindows -and $env:APPDATA) {
    Join-Path -Path $env:APPDATA -ChildPath 'M365Migration' -AdditionalChildPath 'recent.json'
}
else {
    $profileRoot = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profileRoot)) { $profileRoot = $HOME }
    Join-Path -Path $profileRoot -ChildPath '.config' -AdditionalChildPath 'M365Migration', 'recent.json'
}

# Long enough to hold the migrations a technician has in flight, short enough to stay a menu.
$script:WorkbenchRecentLimit = 10

# The environment variable a non-interactive run reads a Viva Learning client secret from, and
# the child-process variable it is handed over in. The two are the same name on purpose: one
# name to document, and nothing to translate.
$script:WorkbenchSecretVariable = 'M365MIGRATION_CLIENT_SECRET'

#endregion Configuration & Constants

#region Helper Functions

function Test-WorkbenchWindows {
    <#
    .SYNOPSIS
        Reports whether this session is running on Windows.

    .DESCRIPTION
        Asked before anything WinForms-related is loaded. $IsWindows does not exist in Windows
        PowerShell 5.1, where the edition is the answer instead - so both are consulted, and the
        function is safe to call on any host the toolkit could be started from.

        Its own function rather than an inline test because the mode choice is a truth table
        worth testing on a machine that is not Windows, which is where this toolkit is written.

    .EXAMPLE
        if (Test-WorkbenchWindows) { 'the window is available' }

        Returns $true on Windows and $false on macOS and Linux.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool](Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction SilentlyContinue)
}

function Write-WorkbenchRefusal {
    <#
    .SYNOPSIS
        Writes a refusal to the error stream and to the run log, without stopping the script.

    .DESCRIPTION
        Every refusal in this script ends in an exit code the caller acts on, so it must reach
        stderr and carry on rather than terminate: $ErrorActionPreference is 'Stop' here, and a
        bare Write-Error would throw past the exit-code handling that is the whole point of a
        non-interactive run.

        The same sentence goes to the run log when a run context exists, so the workspace's own
        record of the session says why nothing happened.

    .PARAMETER Message
        The sentence the operator reads.

    .EXAMPLE
        Write-WorkbenchRefusal -Message '-Workspace is required with -Step.'

        Writes the refusal to stderr and to the log, and returns.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    if ($null -ne (Get-MigrationRunContext)) { Write-MigrationLog -Message $Message -Level ERROR }
    Write-Error -Message $Message -ErrorAction Continue
}

function Select-WorkbenchMode {
    <#
    .SYNOPSIS
        Decides which of the three ways in this invocation is.

    .DESCRIPTION
        The whole of the mode rule, in one place and with no side effect, so it can be tested as
        the truth table it is (Docs/Workbench-Design.md, section 1).

        A named step wins over everything: an operator who asked for one step by name asked for
        one step, and opening a window or a board over the top of that would be a different
        command than the one they typed. Otherwise the window is the default on Windows, the
        console is the default everywhere else, and -Console forces the console on Windows.

    .PARAMETER Console
        The operator passed -Console.

    .PARAMETER Step
        The step id the operator named, or empty for an interactive session.

    .PARAMETER OnWindows
        Whether this is Windows - normally Test-WorkbenchWindows. Passed in rather than read so
        the truth table can be tested from any platform. It is not called 'IsWindows': PowerShell
        7 refuses to bind a parameter over the read-only automatic variable of that name.

    .EXAMPLE
        Select-WorkbenchMode -Console:$Console -Step $Step -OnWindows (Test-WorkbenchWindows)

        Returns 'NonInteractive', 'Gui' or 'Console'.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$Console,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Step,

        [bool]$OnWindows
    )

    if (-not [string]::IsNullOrWhiteSpace($Step)) { return 'NonInteractive' }
    if ($OnWindows -and -not $Console) { return 'Gui' }
    return 'Console'
}

function Get-WorkbenchRecentWorkspace {
    <#
    .SYNOPSIS
        Reads the recently opened workspace paths, newest first.

    .DESCRIPTION
        The list is a convenience for the workspace picker, so every way it can fail - no file,
        an empty file, a file some other tool wrote, a file half-written when the machine went
        down - is an empty list rather than an error. Losing the list costs the operator one
        typed path; refusing to open the workbench over it would cost them the session.

    .EXAMPLE
        Get-WorkbenchRecentWorkspace | Select-Object -First 3

        The three workspaces last opened.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    if (-not (Test-Path -LiteralPath $script:WorkbenchRecentPath -PathType Leaf)) { return @() }

    try {
        $raw = Get-Content -LiteralPath $script:WorkbenchRecentPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $entries = @($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        Write-Verbose "The recent-workspace list could not be read: $($_.Exception.Message)"
        return @()
    }

    return @($entries | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Add-WorkbenchRecentWorkspace {
    <#
    .SYNOPSIS
        Records a workspace at the top of the recent list.

    .DESCRIPTION
        The path moves to the front rather than being repeated, and the list is trimmed to its
        limit, so the menu stays the last few workspaces in the order they were last opened.

        Writing the list is best-effort for the same reason reading it is: a read-only profile
        folder or a roaming profile mid-sync must not cost the operator the session they were
        about to start.

    .PARAMETER Path
        The workspace folder to record.

    .EXAMPLE
        Add-WorkbenchRecentWorkspace -Path ~/Migration-Automations/Contoso

        Puts that workspace at the top of the picker's list.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $kept = [System.Collections.Generic.List[string]]::new()
    $kept.Add($Path)
    foreach ($entry in @(Get-WorkbenchRecentWorkspace)) {
        if ($entry -eq $Path) { continue }
        if ($kept.Count -ge $script:WorkbenchRecentLimit) { break }
        $kept.Add($entry)
    }

    try {
        $folder = Split-Path -Path $script:WorkbenchRecentPath -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
            $null = New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop
        }
        # -Depth 1 keeps a flat array flat; ConvertTo-Json would otherwise emit a single string
        # unwrapped when the list holds exactly one path, which is not the shape the reader wants.
        Set-Content -LiteralPath $script:WorkbenchRecentPath -Encoding utf8 -ErrorAction Stop `
            -Value (ConvertTo-Json -InputObject @($kept) -Depth 1)
    }
    catch {
        Write-Verbose "The recent-workspace list could not be written: $($_.Exception.Message)"
    }
}

function Resolve-WorkbenchWorkspacePath {
    <#
    .SYNOPSIS
        Turns the -Workspace argument into an absolute folder, or explains why it cannot.

    .DESCRIPTION
        Returns { Path; Problem }. Path is the absolute workspace folder, or $null; Problem is
        the sentence the operator reads, or '' where there is nothing wrong.

        Three outcomes, and the mode decides which of the last two applies to an absent
        -Workspace: a named folder that exists resolves; a named folder that does not is a
        refusal, because a non-interactive run that quietly created it would write a migration's
        worth of output into a typo; no folder at all is a refusal for a non-interactive run and
        an empty answer for an interactive one, where the picker asks.

        It refuses rather than exits, so the caller stays the only place that decides an exit
        code - which is what makes this testable without a subprocess.

    .PARAMETER Workspace
        The -Workspace argument, which may be empty.

    .PARAMETER Mode
        The mode Select-WorkbenchMode chose.

    .EXAMPLE
        Resolve-WorkbenchWorkspacePath -Workspace $Workspace -Mode 'NonInteractive'

        Returns the absolute path, or a Problem naming the folder that is not there.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Workspace,

        [Parameter(Mandatory)]
        [ValidateSet('Console', 'Gui', 'NonInteractive')]
        [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        $problem = if ($Mode -eq 'NonInteractive') {
            '-Workspace is required with -Step: a step runs against one migration folder, and an ' +
            'unattended run has nobody to ask which.'
        }
        else { '' }
        return [pscustomobject]@{ Path = $null; Problem = $problem }
    }

    # Resolve-Path would throw on a path that is not there, and the sentence it throws does not
    # say what the operator should do about it.
    $full = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $Workspace))

    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return [pscustomobject]@{
            Path    = $null
            Problem = "The workspace folder '$full' does not exist. Create it first, or point " +
            '-Workspace at an existing migration folder.'
        }
    }

    return [pscustomobject]@{ Path = $full; Problem = '' }
}

function Select-WorkbenchWorkspace {
    <#
    .SYNOPSIS
        Asks the operator which migration folder to open.

    .DESCRIPTION
        The console front end takes a path, not a picker, so the picker lives here: this is the
        entry script, and asking which folder to work in is the one question that has to be
        answered before there is a workbench at all.

        The menu is the recently opened workspaces first - the ones a technician mid-migration
        wants - then every folder under the default output root, then N for a new workspace under
        that root, P for a path typed in full, and Q to leave.

        Every question goes through Read-MigrationPrompt, the toolkit's one prompt seam, rather
        than through Read-Host. That is what keeps the whole toolkit answerable by a single
        Set-MigrationPromptHandler - which is how the Pester suite drives this picker with
        scripted answers on a machine with no console.

        Returns the chosen folder, or $null where the operator quit.

    .EXAMPLE
        $path = Select-WorkbenchWorkspace

        Prints the menu and returns the folder the operator chose.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'This is a console menu; its output is the prompt, not a return value.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The operator has just been asked; a second confirmation would be the same question.')]
    [OutputType([string])]
    param()

    $root = Get-MigrationDefaultOutputRoot

    $choices = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @(Get-WorkbenchRecentWorkspace)) {
        if ((Test-Path -LiteralPath $path -PathType Container) -and -not $choices.Contains($path)) {
            $choices.Add($path)
        }
    }
    if (Test-Path -LiteralPath $root -PathType Container) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object -Property Name)) {
            if (-not $choices.Contains($folder.FullName)) { $choices.Add($folder.FullName) }
        }
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Which migration folder?'
        for ($index = 0; $index -lt $choices.Count; $index++) {
            Write-Host ('  {0,2}. {1}' -f ($index + 1), $choices[$index])
        }
        if ($choices.Count -eq 0) { Write-Host "      (nothing under $root yet)" }
        Write-Host ('   N. New workspace under {0}' -f $root)
        Write-Host '   P. A path I will type'
        Write-Host '   Q. Quit'

        $answer = ([string](Read-MigrationPrompt -Kind 'Text' -Message 'Workspace')).Trim()
        if (-not $answer) { continue }
        $key = $answer.ToUpperInvariant()

        if ($key -eq 'Q') { return $null }

        if ($key -eq 'P') {
            $typed = ([string](Read-MigrationPrompt -Kind 'Text' -Message 'Path')).Trim()
            if (-not $typed) { continue }
            $resolved = Resolve-WorkbenchWorkspacePath -Workspace $typed -Mode 'Console'
            if ($resolved.Path) { return $resolved.Path }
            Write-Host "  $($resolved.Problem)" -ForegroundColor Yellow
            continue
        }

        if ($key -eq 'N') {
            $label = ([string](Read-MigrationPrompt -Kind 'Text' `
                        -Message 'Name for the new workspace')).Trim()
            if (-not $label) { continue }
            # A label is a folder name, not a path: a separator here would put the migration
            # somewhere the operator did not mean to look for it afterwards.
            if ($label.IndexOfAny(([System.IO.Path]::GetInvalidFileNameChars())) -ge 0) {
                Write-Host "  '$label' is not usable as a folder name." -ForegroundColor Yellow
                continue
            }
            $created = Join-Path -Path $root -ChildPath $label
            try {
                $null = New-Item -Path $created -ItemType Directory -Force -ErrorAction Stop
            }
            catch {
                Write-Host "  '$created' could not be created: $($_.Exception.Message)" -ForegroundColor Yellow
                continue
            }
            return $created
        }

        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $choices.Count) {
            Write-Host "  '$answer' is not one of the numbers, or N, P or Q." -ForegroundColor Yellow
            continue
        }

        return $choices[$number - 1]
    }
}

function Invoke-WorkbenchNonInteractive {
    <#
    .SYNOPSIS
        Runs one step against one workspace with nothing asked, and returns its exit code.

    .DESCRIPTION
        The unattended path of Docs/Workbench-Design.md, sections 7 and 10. It is the console
        step form with every question replaced by a rule, and it holds no logic the interactive
        path does not: the same settings loader, the same argument resolver, the same gates, the
        same driver writer and the same runner.

        In order, and every one of them a refusal that exits 2 rather than a run that guesses:
        settings that will not load; a step id that is not in the catalogue; a parameter set
        still short of a mandatory value; a hard gate whose RequiredInput was not supplied
        through -Set @{ Acknowledge = ... }; and a step that needs a client secret with no
        secret in the environment to give it.

        Soft gates warn and the run goes ahead. That is the difference the severities exist to
        draw: a soft gate is advice an operator may have good reason to ignore, and recording
        each one as an override in the ledger is what lets the next reader see what was ignored.

        A hard gate is matched the way the interactive form matches it - a domain without case,
        because DNS has none, and anything else with case, because shouting REMOVE is the point -
        and a hard gate naming nothing to type is refused rather than treated as satisfied.

    .PARAMETER WorkspacePath
        The absolute workspace folder, already checked to exist.

    .PARAMETER StepId
        The step instance id to run.

    .PARAMETER Wave
        Wave labels to limit the run to, or empty for the whole plan.

    .PARAMETER DryRun
        Rehearse rather than change anything, and record the run in the ledger as a rehearsal.

    .PARAMETER Set
        Parameter overrides for the child script, plus the workbench's own 'Acknowledge' key,
        which is taken out before the rest are used as -Override.

    .PARAMETER Version
        The workbench version stamped into the generated driver.

    .EXAMPLE
        Invoke-WorkbenchNonInteractive -WorkspacePath $path -StepId 'New-Users' -DryRun -Version '1.0.0'

        Rehearses the provisioning step and returns its exit code.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The child step''s output is the run itself, not a return value.')]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkspacePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$StepId,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Wave,

        [switch]$DryRun,

        [AllowNull()]
        [hashtable]$Set,

        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    # @($null) is an array holding one $null, which is not the same as no waves at all - and the
    # difference reaches the ledger, where a run 'limited to' a blank wave is a lie.
    $waves = if ($Wave) { @($Wave) } else { @() }

    $workspace = Get-MigrationWorkspace -Path $WorkspacePath

    # The scanner has already run the settings through Resolve-MigrationSettings; reading its
    # result rather than loading the file a second time is what keeps the two from disagreeing.
    if (-not $workspace.SettingsResult.IsValid) {
        $detail = @(@($workspace.SettingsResult.Errors) | ForEach-Object { "  $_" }) -join [Environment]::NewLine
        Write-WorkbenchRefusal -Message (
            "The settings in '$($workspace.SettingsPath)' cannot be used:" +
            [Environment]::NewLine + $detail)
        return 2
    }

    try {
        # Get-MigrationStep throws on an unknown id, and the sentence it throws already names the
        # id and lists every step the catalogue holds - which is exactly the refusal to print.
        $step = Get-MigrationStep -Id $StepId
    }
    catch {
        Write-WorkbenchRefusal -Message $_.Exception.Message
        return 2
    }

    # 'Acknowledge' is the workbench's own key, not a parameter of any of the 17 scripts. Leaving
    # it in -Override would put it in the driver file, where it cannot bind.
    $acknowledge = ''
    $overrides = @{}
    if ($Set) {
        foreach ($key in @($Set.Keys)) {
            if ($key -eq 'Acknowledge') { $acknowledge = [string]$Set[$key]; continue }
            $overrides[$key] = $Set[$key]
        }
    }

    $resolved = Resolve-MigrationStepArguments -Step $step -Workspace $workspace -Override $overrides `
        -Wave $waves -DryRun:$DryRun

    foreach ($warning in @($resolved.Warnings)) { Write-Warning ([string]$warning) }

    $missing = @($resolved.MissingMandatory)
    if ($missing.Count -gt 0) {
        Write-WorkbenchRefusal -Message (
            "Step '$StepId' is still short of what it needs: $($missing -join ', '). " +
            'Supply them with -Set @{ <Name> = <value> }, or fill them in the workspace settings.')
        return 2
    }

    $gates = @(Test-MigrationStepGate -Step $step -Arguments $resolved -Workspace $workspace -Live:(-not $DryRun))

    $gateOverrides = [System.Collections.Generic.List[string]]::new()
    foreach ($gate in @($gates | Where-Object { $_.Severity -eq 'Soft' -and -not $_.Satisfied })) {
        Write-Warning "$($gate.Kind) gate not satisfied, continuing anyway: $($gate.Message)"
        # The extra parentheses matter: a method call splits its arguments on commas, so without
        # them the format operator would get only its first value.
        $gateOverrides.Add(('{0}:{1}' -f $gate.Kind, $gate.Message))
    }

    foreach ($gate in @($gates | Where-Object { $_.Severity -eq 'Hard' -and -not $_.Satisfied })) {
        $required = [string]$gate.RequiredInput

        # A hard gate exists to make someone type something. One that names nothing to type
        # cannot be cleared by typing, and treating 'nothing expected' as 'anything is accepted'
        # would turn the strongest gate in the toolkit into no gate at all.
        if (-not $required) {
            Write-WorkbenchRefusal -Message (
                "The $($gate.Kind) gate expects a typed confirmation but names no input, so it " +
                'cannot be answered. The run was not started.')
            return 2
        }

        $accepted = if ($required -like '*.*') { $acknowledge -ieq $required } else { $acknowledge -ceq $required }
        if ($accepted) { continue }

        Write-WorkbenchRefusal -Message (
            "$($gate.Message) An unattended run answers it with " +
            "-Set @{ Acknowledge = '$required' }. The run was not started.")
        return 2
    }

    # A secret never reaches the driver file or the settings file: it is set on the child
    # process's environment block, which lives exactly as long as that process.
    $environment = $null
    $secretMapping = @()
    if (@(@($step.Parameters) | Where-Object { $_.Name -eq 'ClientSecret' }).Count -gt 0) {
        $viva = Get-MigrationProperty -InputObject $workspace.Settings -Name 'VivaLearning' -Default $null
        $thumbprint = [string](Get-MigrationProperty -InputObject $viva -Name 'CertificateThumbprint' -Default '')
        if (-not $thumbprint) {
            $secret = [string][System.Environment]::GetEnvironmentVariable($script:WorkbenchSecretVariable)
            if (-not $secret) {
                Write-WorkbenchRefusal -Message (
                    "Step '$StepId' signs in with a client secret and the workspace settings hold no " +
                    "VivaLearning.CertificateThumbprint. Set `$env:$($script:WorkbenchSecretVariable) " +
                    'before the run, or configure a certificate. The run was not started.')
                return 2
            }
            $environment = @{ $script:WorkbenchSecretVariable = $secret }
            $secretMapping = @("ClientSecret=$($script:WorkbenchSecretVariable)")
        }
    }

    $driver = New-MigrationStepDriver -Step $step -Arguments $resolved -Workspace $workspace `
        -Version $Version -SecretEnvironmentVariable $secretMapping

    Write-Host $driver.DisplayLine
    Write-Host $driver.CommandLine
    Write-Host ''

    $runParameters = @{
        Step          = $step
        Driver        = $driver
        Workspace     = $workspace
        OutputWriter  = { param($Line) Write-Host $Line }
        Wave          = $waves
        GateOverrides = @($gateOverrides)
    }
    # Both passed explicitly, even when false or null: a runner that behaved differently for an
    # unbound switch than for -DryRun:$false would be a difference nothing can see.
    $runParameters['DryRun'] = [bool]$DryRun
    $runParameters['Environment'] = $environment

    if ([string]$step.Side -in @('Source', 'Destination')) {
        $side = Get-MigrationProperty -InputObject $workspace.Settings -Name ([string]$step.Side) -Default $null
        $expected = [string](Get-MigrationProperty -InputObject $side -Name 'TenantId' -Default '')
        if ($expected) { $runParameters['ExpectedTenantId'] = $expected }
    }

    $result = Invoke-MigrationStep @runParameters

    # The secret's last reference in this process; the child has its own copy and this one has no
    # further use.
    $environment = $null

    Write-Host ''
    Write-Host ('Exit {0}: {1}' -f $result.ExitCode, $result.Meaning)
    foreach ($file in @($result.Files)) { Write-Host "  wrote $file" }
    Write-Host "  log  $($result.StdoutPath)"

    # 130 is the shell's own code for a process ended by an interrupt, and it is what a scheduler
    # reading this run needs to tell 'the operator stopped it' from 'the step failed'.
    if ($result.Aborted) { return 130 }

    $code = [int]$result.ExitCode
    # Complete-MigrationRun only accepts 0-255, and a child that returned something else has
    # already said all it is going to say; 1 is the honest summary of 'it did not succeed'.
    if ($code -lt 0 -or $code -gt 255) { return 1 }
    return $code
}

#endregion Helper Functions

#region GUI

# Task 13 adds Start-MigrationWorkbenchGui here.

function Start-MigrationWorkbenchGui {
    <#
    .SYNOPSIS
        Placeholder for the WinForms workbench, which this build does not carry.

    .DESCRIPTION
        The mode dispatch names this function, so it exists; the window itself arrives with the
        GUI region. It throws rather than silently falling back to the console, because an
        operator on Windows who got a console board without asking for one would reasonably
        conclude the window is broken rather than absent.

    .PARAMETER WorkspacePath
        The workspace the window would open on, or $null for its own picker.

    .EXAMPLE
        Start-MigrationWorkbenchGui -WorkspacePath $path

        Throws in this build. Use -Console.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'The parameter is the contract the GUI region will fill; the stub only refuses.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a window and changes nothing; this build only throws.')]
    [OutputType([void])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkspacePath
    )

    throw 'The WinForms workbench is not available in this build; use -Console.'
}

#endregion GUI

#region Main

# Guard: dot-sourcing (InvocationName '.') or -NoGui loads the helpers and stops, which is how the
# Pester suite tests them on a machine that has no WinForms and no console to drive.
if (-not $NoGui -and $MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        # The platform is decided here, before anything WinForms-related could be touched: the
        # assembly does not exist off Windows, and loading it to find that out would end the
        # session on the platforms the console mode is the whole point of.
        $mode = Select-WorkbenchMode -Console:$Console -Step $Step -OnWindows (Test-WorkbenchWindows)

        $resolution = Resolve-WorkbenchWorkspacePath -Workspace $Workspace -Mode $mode
        $workspacePath = $resolution.Path

        # The workbench's own log belongs beside the ledger it is about to append to. With no
        # workspace known - a refusal, or a console session that has not picked one yet - the
        # default output root is the only place left that is certainly writable.
        $logRoot = if ($workspacePath) { Join-Path -Path $workspacePath -ChildPath 'Workbench' }
        else { Get-MigrationDefaultOutputRoot }

        $null = Initialize-MigrationRun -ScriptName 'Start-MigrationWorkbench' -OutputPath $logRoot `
            -Prefix '' -LogPath $LogPath -Verbosity $Verbosity -BoundParameters $PSBoundParameters

        if ($resolution.Problem) {
            Write-WorkbenchRefusal -Message $resolution.Problem
            exit (Complete-MigrationRun -ExitCode 2)
        }

        Write-MigrationLog -Message "Workbench mode: $mode" -Level INFO

        switch ($mode) {
            'NonInteractive' {
                $exitCode = Invoke-WorkbenchNonInteractive -WorkspacePath $workspacePath -StepId $Step `
                    -Wave $Wave -DryRun:$DryRun -Set $Set -Version $script:Version
            }
            'Console' {
                if (-not $workspacePath) { $workspacePath = Select-WorkbenchWorkspace }
                if ($workspacePath) {
                    Add-WorkbenchRecentWorkspace -Path $workspacePath
                    $null = Show-MigrationWorkbench -Path $workspacePath -Version $script:Version
                }
                # A session the operator closed is a session that worked, whatever it did or did
                # not run: the exit code of an interactive front end is about the front end.
                $exitCode = 0
            }
            'Gui' {
                if ($workspacePath) { Add-WorkbenchRecentWorkspace -Path $workspacePath }
                Start-MigrationWorkbenchGui -WorkspacePath $workspacePath
                $exitCode = 0
            }
        }
    }
    catch {
        Write-WorkbenchRefusal -Message "Unexpected error: $($_.Exception.Message)"
        Write-MigrationLog -Message "Stack trace: $($_.ScriptStackTrace)" -Level DEBUG
        $exitCode = 1
    }

    exit (Complete-MigrationRun -ExitCode $exitCode)
}

#endregion Main
