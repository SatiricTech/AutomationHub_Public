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
    one - it lands in Workbench/ under the default output root, which keeps loose log files out
    of the folder the migration folders themselves live in. A refusal that can be read off the
    arguments (no -Workspace, a folder that is not there, a step id the catalogue does not hold)
    is made before the log is opened at all, so it creates nothing anywhere.

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
    Overrides this script's own log file path. The folder that file is in becomes the run's
    output folder too, so a redirected log leaves nothing behind under the default output root.

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
    unexpected error, a child that reported no exit code at all, or a run whose tenant did not
    verify; 2 a refusal - no workspace, a workspace folder that is not there, settings that will
    not load, an unknown step id, a parameter set that is still short of a mandatory value, or a
    hard gate that was not acknowledged - or the step's own exit code 2; 130 the run was aborted.
    Any other code is the step's own, passed through unchanged.

    The one exception to "exits with the step's exit code": a run whose TenantVerified came back
    false exits 1 whatever the step returned. A scheduler has only the exit code, and a step that
    exited 0 against the wrong tenant must not read as a reason to run the next one. An aborted
    run still exits 130, because "I stopped this" is the fact the caller needs first.

    Every refusal and the tenant-mismatch line are written once to the process's standard
    error stream as a plain line, and once more to the run log. A scheduler or shell that
    redirects stderr captures them; a PowerShell caller that runs this script in-process with
    2>&1 does not, because that operator redirects PowerShell's error stream, not the
    process's - read the exit code and the log in that case.

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

# The window's own constants and the three variables its handlers read. They are declared here
# rather than in the GUI region for two reasons: that region holds function definitions and
# nothing else, so dot-sourcing the script never builds or touches anything; and Set-StrictMode
# -Version Latest makes reading an unassigned variable an error, so a handler that runs before
# Start-MigrationWorkbenchGui has filled them in has to find them already there.
#
# 2000 lines is a screenful of scrollback many times over and still cheap to append to. The
# whole of a run's output is in that run's stdout.txt, which is where anyone reading it
# afterwards should be looking.
$script:WorkbenchGuiPaneLimit = 2000

# The wave list's own entry for 'do not limit this run at all'. It is an item rather than an
# inferred rule because 'every wave ticked' and 'no wave ticked' produce the same command, and
# neither the WaveRequired gate nor the ledger could then tell the two screens apart.
$script:WorkbenchGuiAllWavesLabel = '(all waves)'

# What a [SecureString] parameter's row says instead of offering a box. The window collects no
# secret at all: a password box is one more place a client secret can be shoulder-read or land
# in a screenshot, and the child process reads it from this environment variable instead.
$script:WorkbenchGuiSecretRowText =
    'Set $env:{0} before Run — the window never takes a secret.' -f $script:WorkbenchSecretVariable

# The window's state bag, and the two scriptblocks Invoke-MigrationStep is handed as its
# -OutputWriter and -Pump. $null until a window exists.
$script:Gui = $null
$script:PaneWriter = $null
$script:UiPump = $null

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
        record of the session says why nothing happened - and to stderr exactly once, as a plain
        line, because a refusal printed twice (once as the log's [ERROR] line and again inside
        Write-Error's position block) is three quarters scaffolding.

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

    # A plain line on stderr rather than Write-Error. The sentence has already gone to the log
    # with an [ERROR] prefix, and Write-Error would print it a second time wrapped in a position
    # block naming a line of this script - four lines of scaffolding around one sentence, in the
    # one mode whose entire output a scheduler may be capturing and mailing to somebody.
    [Console]::Error.WriteLine($Message)
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

function ConvertTo-WorkbenchComparablePath {
    <#
    .SYNOPSIS
        Puts a workspace path in the form two paths are compared in.

    .DESCRIPTION
        One rule for "these two paths are the same workspace", in one place, because the answer
        is wanted in three: reading the recent list, adding to it, and building the picker's menu
        out of the recent list and the folders under the default root together. Three inlined
        comparisons is how a workspace ends up listed twice with a trailing slash between them.

        A trailing separator is dropped, because a folder is the same folder with or without one
        and Get-ChildItem never produces one while an operator typing a path often does. The case
        is left alone - the operator's own capitalisation is what the menu should show - and the
        comparison the callers make is case-insensitive instead: Windows and macOS both treat
        two spellings of one path as one folder by default, and offering both would be offering
        the same migration twice.

    .PARAMETER Path
        The path to canonicalise.

    .EXAMPLE
        ConvertTo-WorkbenchComparablePath -Path '/Migrations/Contoso/'

        Returns '/Migrations/Contoso'.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    # Both separators: Windows accepts a forward slash everywhere, so a path an operator pasted
    # from a script can end in either one.
    return $Path.Trim().TrimEnd([System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
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

        A file that is valid JSON but is not an array of paths is one of those ways. -NoEnumerate
        is what makes that knowable: without it a one-element array comes back unwrapped as a
        bare string, indistinguishable from a JSON document that was only ever a string, and the
        picker would offer its characters as workspaces.

        Paths come back canonicalised and de-duplicated without case, so a workspace recorded
        once with a trailing separator and once without is one entry in the menu rather than two.

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
        $parsed = ConvertFrom-Json -InputObject $raw -NoEnumerate -ErrorAction Stop
    }
    catch {
        Write-Verbose "The recent-workspace list could not be read: $($_.Exception.Message)"
        return @()
    }

    if ($parsed -isnot [System.Array]) {
        Write-Verbose 'The recent-workspace list is not a JSON array of paths; ignoring it.'
        return @()
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $parsed) {
        # Only strings: an array of numbers or objects is somebody else's file, and '@{a=1}' is
        # not a folder anyone meant to open.
        if ($entry -isnot [string]) { continue }
        $path = ConvertTo-WorkbenchComparablePath -Path $entry
        if (-not $path) { continue }
        if (-not $seen.Add($path)) { continue }
        $kept.Add($path)
    }

    return @($kept)
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

    # Compared the way the reader and the picker compare: canonical form, without case. A
    # workspace opened as 'C:\Migrations\Contoso' and again as 'c:/migrations/contoso/' is one
    # workspace, and listing it twice would put the same migration at two menu numbers.
    $canonical = ConvertTo-WorkbenchComparablePath -Path $Path
    if (-not $canonical) { return }

    $kept = [System.Collections.Generic.List[string]]::new()
    $kept.Add($canonical)
    foreach ($entry in @(Get-WorkbenchRecentWorkspace)) {
        if ($entry -ieq $canonical) { continue }
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
        # A path that is there but is a file is a different mistake from a path that is not
        # there, and 'does not exist' about a file the operator can see would send them looking
        # for the wrong thing.
        $problem = if (Test-Path -LiteralPath $full -PathType Leaf) {
            "'$full' is a file, not a folder. -Workspace takes the migration folder itself."
        }
        else {
            "The workspace folder '$full' does not exist. Create it first, or point -Workspace " +
            'at an existing migration folder.'
        }
        return [pscustomobject]@{ Path = $null; Problem = $problem }
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

    # List<string>.Contains is an ordinal, case-sensitive match, which would have offered a
    # remembered workspace and the folder under the root it actually is as two separate numbers.
    # One set, canonical and without case, for both sources.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $choices = [System.Collections.Generic.List[string]]::new()

    foreach ($path in @(Get-WorkbenchRecentWorkspace)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        if ($seen.Add($path)) { $choices.Add($path) }
    }
    if (Test-Path -LiteralPath $root -PathType Container) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object -Property Name)) {
            $path = ConvertTo-WorkbenchComparablePath -Path $folder.FullName
            if ($seen.Add($path)) { $choices.Add($path) }
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

function Get-WorkbenchStepProblem {
    <#
    .SYNOPSIS
        Says why a named step cannot be run, or returns '' when the catalogue knows it.

    .DESCRIPTION
        The unattended path refuses an unknown step id anyway, and so it should - but by then a
        run context exists, and a run context is a folder on disk. Every refusal this script can
        make from its arguments alone has to be makeable before Initialize-MigrationRun is
        called, or the price of telling an operator they mistyped a step name is a log folder
        left behind under the default output root (Docs/Workbench-Design.md, section 10).

        Get-MigrationStep throws on an unknown id and the sentence it throws already names the id
        and lists every step the catalogue holds, which is exactly the refusal to print. The
        catalogue is cached, so asking twice - here and again in the run itself - costs nothing.

    .PARAMETER StepId
        The step instance id the operator named, or empty when they named none.

    .EXAMPLE
        Get-WorkbenchStepProblem -StepId 'New-Users'

        Returns '': the catalogue knows that step.

    .EXAMPLE
        Get-WorkbenchStepProblem -StepId 'Nope'

        Returns the catalogue's own sentence, naming 'Nope' and listing the ids it does know.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$StepId
    )

    if ([string]::IsNullOrWhiteSpace($StepId)) { return '' }

    try {
        $null = Get-MigrationStep -Id $StepId
        return ''
    }
    catch {
        return [string]$_.Exception.Message
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
        settings that will not load (Test-MigrationWorkspaceRunnable, the refusal all three
        front ends share); a step id that is not in the catalogue; a parameter set still short
        of a mandatory value; a hard gate whose RequiredInput was not supplied through
        -Set @{ Acknowledge = ... }; and a step that needs a client secret with no secret in the
        environment to give it.

        Soft gates warn and the run goes ahead. That is the difference the severities exist to
        draw: a soft gate is advice an operator may have good reason to ignore, and recording
        each one as an override in the ledger is what lets the next reader see what was ignored.
        The warnings are emitted after the hard gates have been judged, so a run that is about
        to be refused does not first leave a scheduler's log describing what it waved through.

        A hard gate is matched by the engine's own rule (Test-MigrationTypedConfirmation) - a
        domain without case, because DNS has none, and anything else with case, because shouting
        REMOVE is the point - and a hard gate naming nothing to type is refused rather than
        treated as satisfied.

        One thing is decided after the run: a tenant mismatch. It is written to stderr and the
        log and it makes the exit code 1 whatever the step returned, because an unattended
        caller has nothing but that code, and a step that exited 0 against the wrong tenant
        would otherwise read as a reason to run the next one.

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
    # difference reaches the resolver, the driver and the ledger, where a run 'limited to' a
    # blank wave is a lie the WaveRequired gate then reads as satisfied.
    #
    # Assigned in two statements rather than one. 'if ($Wave) { @($Wave) } else { @() }' looks
    # like it says this, and does not: an if-statement used as an expression whose taken branch
    # is the empty array yields nothing at all, so $waves became $null and every @($waves) after
    # it was @($null) - one blank wave, not no waves.
    $waves = @()
    if ($Wave) { $waves = @($Wave) }

    $workspace = Get-MigrationWorkspace -Path $WorkspacePath

    # The same refusal the console board and the window make, out of the same engine function,
    # so all three agree on when a workspace may be run against at all. The scanner has already
    # run the settings through Resolve-MigrationSettings; reading its result rather than loading
    # the file a second time is what keeps the two from disagreeing.
    $runnable = Test-MigrationWorkspaceRunnable -Workspace $workspace
    if (-not $runnable.CanRun) {
        $detail = @(@($workspace.SettingsResult.Errors) | ForEach-Object { "  $_" }) -join [Environment]::NewLine
        Write-WorkbenchRefusal -Message (
            [string]$runnable.Reason + [Environment]::NewLine +
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

    # Hard gates are judged first, and the soft-gate warnings are held until after them. The
    # console asks in the other order because there the typed confirmation is the last act
    # before the run, which is where a deliberate act belongs; here nothing is asked, and
    # warning about what was waved through on a run that is about to be refused anyway just
    # leaves a scheduler's log describing a run that never happened.
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

        # The engine's rule, the same one the console form and the window's modal dialog apply.
        if (Test-MigrationTypedConfirmation -Typed $acknowledge -Required $required) { continue }

        Write-WorkbenchRefusal -Message (
            "$($gate.Message) An unattended run answers it with " +
            "-Set @{ Acknowledge = '$required' }. The run was not started.")
        return 2
    }

    # Soft gates are judged on a live run only, which is the console's rule too: a rehearsal
    # exists to be run before the prerequisites are met, so holding one to them would leave an
    # unattended caller with nothing safe to do - and recording an override for a rehearsal would
    # put a waiver in the ledger for a run that changed nothing.
    $gateOverrides = [System.Collections.Generic.List[string]]::new()
    if (-not $DryRun) {
        foreach ($gate in @($gates | Where-Object { $_.Severity -eq 'Soft' -and -not $_.Satisfied })) {
            Write-Warning "$($gate.Kind) gate not satisfied, continuing anyway: $($gate.Message)"
            # The extra parentheses matter: a method call splits its arguments on commas, so
            # without them the format operator would get only its first value.
            $gateOverrides.Add(('{0}:{1}' -f $gate.Kind, $gate.Message))
        }
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
    # Coloured by what the code means (Docs/Workbench-Design.md, section 7.3), the same mapping
    # the console board uses: 0 green, 1 red, and 2, 3 and 130 amber - a run that did some of
    # the work, left some behind, or was stopped is neither a success nor a failure.
    $exitColour = switch ([string]$result.ExitCode) {
        '0' { 'Green' }
        '1' { 'Red' }
        '2' { 'Yellow' }
        '3' { 'Yellow' }
        '130' { 'Yellow' }
        default { '' }
    }
    $exitLine = 'Exit {0}: {1}' -f $result.ExitCode, $result.Meaning
    if ($exitColour) { Write-Host $exitLine -ForegroundColor $exitColour } else { Write-Host $exitLine }

    foreach ($file in @($result.Files)) { Write-Host "  wrote $file" }
    Write-Host "  log  $($result.StdoutPath)"

    # Spec section 7.2: a tenant mismatch is flagged regardless of the exit code, and the two
    # interactive front ends shout it in red. An unattended caller has only the exit code and
    # whatever it captured from stderr, so it gets both - and the exit code becomes 1 whatever
    # the step returned, because a step that exited 0 against the wrong tenant is the worst
    # outcome this toolkit can produce and 0 is the one answer that tells a scheduler to carry
    # on to the next step.
    $mismatch = ((Get-MigrationProperty -InputObject $result -Name 'TenantVerified' -Default $null) -eq $false)
    if ($mismatch) {
        Write-WorkbenchRefusal -Message ('TENANT MISMATCH — ' + (Format-MigrationTenantVerdict -Result $result))
    }

    # 130 is the shell's own code for a process ended by an interrupt, and it is what a scheduler
    # reading this run needs to tell 'the operator stopped it' from 'the step failed'. It is
    # decided before the mismatch, because a run that was killed may simply never have reached
    # the sign-in that would have printed a tenant line, and 'I stopped this' is the fact the
    # caller needs first.
    if ($result.Aborted) { return 130 }

    if ($mismatch) { return 1 }

    # A child that reported no exit code at all is not a success: [int]$null is 0, and a
    # scheduler reading 0 would go on to the next step of the migration.
    if ($null -eq $result.ExitCode) { return 1 }

    $code = [int]$result.ExitCode
    # Complete-MigrationRun only accepts 0-255, and a child that returned something else has
    # already said all it is going to say; 1 is the honest summary of 'it did not succeed'.
    if ($code -lt 0 -or $code -gt 255) { return 1 }
    return $code
}

#endregion Helper Functions

#region GUI

# The window is built by Start-MigrationWorkbenchGui and by nothing else: everything in this
# region is a function definition, so dot-sourcing the script with -NoGui on macOS loads the
# helpers below and touches no WinForms type at all. The state bag and the two seams the runner
# is handed live in the Configuration region above, because Set-StrictMode -Version Latest makes
# reading an unassigned variable an error and the handlers here read them by name.

function ConvertTo-WorkbenchGuiControlKind {
    <#
    .SYNOPSIS
        Decides which control the step form draws for one script parameter.

    .DESCRIPTION
        The step form is generated from Get-MigrationStep's parameter objects, so the mapping
        from a parameter to a control is the whole of the form's layout logic - and it is a pure
        function of the parameter, which is what lets it be tested on a machine with no WinForms
        (Docs/Workbench-Design.md, section 9).

        A [SecureString] parameter is a kind of its own, and the one kind that is not a control:
        'Secret' is drawn as a line of text telling the operator to set the environment variable
        the child process reads. It is decided first, because a secret must never fall through to
        the text box at the bottom of this function - that is how a client secret ends up typed
        into a window, shoulder-read, screenshot, and (if the form ever sent it) written into a
        driver file.

        The order the remaining tests are applied in matters twice:

          * a folder parameter is recognised before a file one, because -OutputPath ends in
            'Path' and would otherwise be offered as a file the operator has to pick; and
          * a hashtable is recognised before either, because a map is a map whatever its name
            ends in, and a two-column editor is the only control that can hold one.

        A parameter with a ValidateSet is a pick-list - a checked list when it takes several
        values, a drop-down when it takes one - because a list the script itself declares is a
        list the operator should never have to type.

    .PARAMETER Parameter
        One parameter object from a step's Parameters collection.

    .EXAMPLE
        ConvertTo-WorkbenchGuiControlKind -Parameter $planPath

        Returns 'FilePicker' for -PlanPath: a text box and a '...' button.

    .EXAMPLE
        ConvertTo-WorkbenchGuiControlKind -Parameter $scope

        Returns 'CheckedListBox' for a [string[]] parameter with a ValidateSet.

    .EXAMPLE
        ConvertTo-WorkbenchGuiControlKind -Parameter $clientSecret

        Returns 'Secret' for a [SecureString] parameter: a line of text, never a box.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Parameter
    )

    $typeName = [string](Get-MigrationProperty -InputObject $Parameter -Name 'TypeName' -Default '')
    if ($typeName -in @('SecureString', 'System.Security.SecureString')) { return 'Secret' }

    $name = [string](Get-MigrationProperty -InputObject $Parameter -Name 'Name' -Default '')
    $isSwitch = [bool](Get-MigrationProperty -InputObject $Parameter -Name 'IsSwitch' -Default $false)
    $isBool = [bool](Get-MigrationProperty -InputObject $Parameter -Name 'IsBool' -Default $false)
    if ($isSwitch -or $isBool) { return 'CheckBox' }

    $valid = @(Get-MigrationProperty -InputObject $Parameter -Name 'ValidValues' -Default @())
    $isArray = [bool](Get-MigrationProperty -InputObject $Parameter -Name 'IsArray' -Default $false)
    if ($valid.Count -gt 0) {
        if ($isArray) { return 'CheckedListBox' }
        return 'ComboBox'
    }

    if ([bool](Get-MigrationProperty -InputObject $Parameter -Name 'IsHashtable' -Default $false)) {
        return 'MapEditor'
    }

    if ($name -match 'OutputPath$|Folder') { return 'FolderPicker' }
    if ($name -match '(Path|Csv|File)$') { return 'FilePicker' }

    return 'TextBox'
}

function Test-WorkbenchGuiFormParameter {
    <#
    .SYNOPSIS
        Decides whether the generated step form draws a row for one script parameter.

    .DESCRIPTION
        Two parameters never get a row, and for two different reasons
        (Docs/Workbench-Design.md, section 9).

        A Common parameter - -OutputPath, -Prefix, -LogPath, -Verbosity, -DryRun - is set by the
        workbench itself for every step, so a row for it would be a box whose value the resolver
        replaces.

        A parameter the workbench owns (Get-MigrationWorkbenchOwnedParameter - the engine's own
        list, so the form filter and the resolver cannot drift apart) is worse than redundant:
        the window would be showing a box whose value the resolver drops, or two controls for
        one value. That is exactly how a run comes to be recorded in the ledger as the wave the
        operator ticked while the driver runs the wave they typed.

        A pure function of the parameter, so the rule the form applies is the rule the test
        asserts - there is no window on the machine this is written on.

    .PARAMETER Parameter
        One parameter object from a step's Parameters collection.

    .EXAMPLE
        Test-WorkbenchGuiFormParameter -Parameter $wave

        Returns $false: the Waves checked list owns -Wave.

    .EXAMPLE
        Test-WorkbenchGuiFormParameter -Parameter $planPath

        Returns $true: -PlanPath is the operator's to fill in.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Parameter
    )

    if ([bool](Get-MigrationProperty -InputObject $Parameter -Name 'Common' -Default $false)) { return $false }

    $name = [string](Get-MigrationProperty -InputObject $Parameter -Name 'Name' -Default '')
    # -in on strings is case-insensitive, which is what a parameter name is compared by.
    return ($name -notin (Get-MigrationWorkbenchOwnedParameter))
}

function Get-WorkbenchGuiStepList {
    <#
    .SYNOPSIS
        Builds the Phases tree's model: the runbook's phases, each with its steps.

    .DESCRIPTION
        The tree's whole content as data, so the window has nothing to work out while it draws
        (Docs/Workbench-Design.md, sections 6 and 9). The steps are the ones
        Get-MigrationStep returns for the workspace's own scenario, in the runbook's order, and
        the glyph and the last-run line are the console's own renderers - the two front ends
        draw the same workspace from the same two functions, so they cannot disagree about what
        a step's state is or when it last ran.

        A workspace whose settings did not load has no scenario, and a tenant-to-tenant runbook
        is the right thing to show then: it is the superset, and showing nothing would leave the
        operator with a window that cannot explain itself.

        Returned as one object per phase rather than a flat list because the tree is a tree: the
        phase is the parent node, and grouping here rather than in the drawing code is what
        keeps this testable without a window.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .EXAMPLE
        (Get-WorkbenchGuiStepList -Workspace $ws).Steps.Id

        Lists every step id the tree will show - the same ids, in the same order, as
        Get-MigrationStep -Scenario $ws.Scenario.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace
    )

    $scenario = [string](Get-MigrationProperty -InputObject $Workspace -Name 'Scenario' -Default '')
    if (-not $scenario) { $scenario = 'TenantToTenant' }

    $stateById = @{}
    foreach ($state in @(Get-MigrationProperty -InputObject $Workspace -Name 'Steps' -Default @())) {
        $stateById[[string]$state.Id] = $state
    }
    $nextId = [string](Get-MigrationProperty -InputObject $Workspace -Name 'NextStepId' -Default '')

    $phases = [System.Collections.Generic.List[object]]::new()
    $current = $null

    foreach ($step in @(Get-MigrationStep -Scenario $scenario)) {
        $phase = [string]$step.Phase
        if ($null -eq $current -or [string]$current.Phase -ne $phase) {
            $current = [pscustomobject]@{
                Phase = $phase
                Steps = [System.Collections.Generic.List[object]]::new()
            }
            $phases.Add($current)
        }

        $state = $null
        if ($stateById.ContainsKey([string]$step.Id)) { $state = $stateById[[string]$step.Id] }

        $current.Steps.Add([pscustomobject]@{
                Id      = [string]$step.Id
                Title   = [string]$step.Title
                Glyph   = [string](Format-MigrationStepGlyph -State $state)
                LastRun = [string](Format-MigrationStepLastRun -State $state)
                IsNext  = ([string]$step.Id -eq $nextId)
                Side    = [string]$step.Side
                Impact  = [string]$step.Impact
                Step    = $step
            })
    }

    # Handed back as arrays: a caller reading '.Steps.Id' off the result is reading a property
    # of a collection, and a List<object> and an array do not behave the same way there.
    foreach ($entry in $phases) { $entry.Steps = @($entry.Steps) }

    return @($phases)
}

function Format-WorkbenchGuiBanner {
    <#
    .SYNOPSIS
        Builds the tenant banner for a step: the sentence and the colour it is painted in.

    .DESCRIPTION
        The banner exists to answer one question before a button is pressed - which tenant is
        this about - and to answer it in a colour, because a technician running a cutover reads
        the colour long before they read the words (Docs/Workbench-Design.md, section 9).

        Amber is the source tenant, which is the one where a mistake is irreversible; blue is
        the destination, where most of the writing happens; grey is an offline step, which signs
        in to nothing at all. The colour name is returned rather than a Drawing.Color so that
        this function - and its test - never touch WinForms.

        The tenant is named the way the console names it: the display name where the settings
        hold one, the *.onmicrosoft.com domain where they do not, and the GUID beside it. The
        GUID is shown in full here; the console shortens it only because a terminal line has to
        hold the rest of the board as well.

    .PARAMETER Step
        The selected step, or $null when nothing is selected yet.

    .PARAMETER Settings
        The workspace's settings document, or $null where it did not load.

    .EXAMPLE
        Format-WorkbenchGuiBanner -Step $step -Settings $ws.Settings

        Returns { Text = 'SOURCE  contoso.onmicrosoft.com  <guid>'; Colour = 'Amber' }.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        $Step,

        [AllowNull()]
        $Settings
    )

    if ($null -eq $Step) {
        return [pscustomobject]@{ Text = 'No step selected'; Colour = 'Grey' }
    }

    $side = [string](Get-MigrationProperty -InputObject $Step -Name 'Side' -Default '')
    if ($side -notin @('Source', 'Destination')) {
        return [pscustomobject]@{
            Text   = 'OFFLINE  this step signs in to nothing; it reads and writes files only'
            Colour = 'Grey'
        }
    }

    $section = Get-MigrationProperty -InputObject $Settings -Name $side -Default $null
    $name = [string](Get-MigrationProperty -InputObject $section -Name 'DisplayName' -Default '')
    if (-not $name) {
        $name = [string](Get-MigrationProperty -InputObject $section -Name 'OnMicrosoftDomain' -Default '')
    }
    $guid = [string](Get-MigrationProperty -InputObject $section -Name 'TenantId' -Default '')

    $parts = @(@($name, $guid) | Where-Object { $_ })
    $who = if ($parts.Count -gt 0) { $parts -join '  ' } else { '(tenant not set)' }

    $colour = if ($side -eq 'Source') { 'Amber' } else { 'Blue' }
    return [pscustomobject]@{ Text = ('{0}  {1}' -f $side.ToUpperInvariant(), $who); Colour = $colour }
}

function ConvertTo-WorkbenchGuiOverride {
    <#
    .SYNOPSIS
        Turns what a control holds back into the typed value the argument resolver expects.

    .DESCRIPTION
        Every control in the step form holds text, a tick or a set of ticks, and
        Resolve-MigrationStepArguments expects the script's own types: a boolean for a switch, a
        string array for a [string[]], an ordered map for a hashtable, a number for an [int].
        This is the one place that conversion happens, and it is a pure function of the
        parameter and the text so it can be tested with no window (Docs/Workbench-Design.md,
        section 9).

        A number that will not parse comes back as the text the operator typed, rather than as a
        silently substituted zero. That is the same choice the console's settings form makes,
        and for the same reason: a resolver or a script that names the bad value is far more use
        to the operator than a field that quietly corrected itself.

        Empty text is not an override at all - it returns $null, which the caller drops - so a
        field the operator cleared falls back to the settings or the resolver rather than
        forcing an empty string onto the command line. A switch is the exception: a cleared tick
        is $false, which is a value.

        Two parameters can never produce one, whatever they were handed. A [SecureString] has no
        control to read - its row is a line of text - and a secret must never reach an -Override
        hashtable, because that is what New-MigrationStepDriver writes into a file. And a
        parameter the workbench owns (Get-MigrationWorkbenchOwnedParameter) would arrive here
        only through a form that should not have drawn it; returning $null is the second lock on
        the bug where -Override @{ Wave = ... } silently outranks the wave the run was told to
        use. The engine drops such a key as well, which is the third.

        A map is read by the engine's own parser (ConvertFrom-MigrationMapText), the same one
        the console's settings form and its step form use, so 'old.com=new.com' means the same
        thing in all three.

    .PARAMETER Parameter
        The parameter object the control was generated from.

    .PARAMETER Text
        What the control holds: its text, 'True'/'False' for a tick, or one checked item per
        line for a checked list.

    .EXAMPLE
        ConvertTo-WorkbenchGuiOverride -Parameter $scope -Text "Users`nGroups"

        Returns @('Users', 'Groups') for a [string[]] parameter.

    .EXAMPLE
        ConvertTo-WorkbenchGuiOverride -Parameter $aliasMap -Text 'old.com=new.com'

        Returns an ordered hashtable of one rewrite.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Parameter,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $value = if ($null -eq $Text) { '' } else { $Text }

    # Both refusals are decided before anything is read, so no path through this function can
    # return a secret or a value for a parameter the window sets from a control of its own.
    if ((ConvertTo-WorkbenchGuiControlKind -Parameter $Parameter) -eq 'Secret') { return $null }
    if (-not (Test-WorkbenchGuiFormParameter -Parameter $Parameter)) { return $null }

    $isSwitch = [bool](Get-MigrationProperty -InputObject $Parameter -Name 'IsSwitch' -Default $false)
    $isBool = [bool](Get-MigrationProperty -InputObject $Parameter -Name 'IsBool' -Default $false)
    if ($isSwitch -or $isBool) {
        # -in on strings is case-insensitive, which is what makes 'True' from a CheckBox and a
        # hand-typed 'yes' the same answer.
        return [bool]($value.Trim() -in @('1', 'y', 'yes', 'true', '$true', 'on'))
    }

    if ([bool](Get-MigrationProperty -InputObject $Parameter -Name 'IsHashtable' -Default $false)) {
        return (ConvertFrom-MigrationMapText -Text $value)
    }

    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    if ([bool](Get-MigrationProperty -InputObject $Parameter -Name 'IsArray' -Default $false)) {
        # A checked list gives one item per line; a text box holding a list is comma-separated,
        # which is how the console's own editor takes one.
        return @(@($value -split "`r?`n|,") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    $typeName = [string](Get-MigrationProperty -InputObject $Parameter -Name 'TypeName' -Default '')
    if ($typeName -in @('Int32', 'Int64')) {
        $number = 0
        if ([int]::TryParse($value.Trim(), [ref]$number)) { return $number }
        return $value.Trim()
    }

    return $value.Trim()
}

function Write-WorkbenchGuiPane {
    <#
    .SYNOPSIS
        Appends one line to the log pane, scrolls to it, and keeps the window painting.

    .DESCRIPTION
        The pane is the window's whole account of a session, and it is written from two places:
        this front end, and the child process through the -OutputWriter seam
        Invoke-MigrationStep is handed. A run is polled on the UI thread, so the DoEvents here
        is the only thing keeping the window from greying out as 'Not Responding' for the length
        of a step.

        The pane is capped. A migration's full inventory run is tens of thousands of lines, and
        a TextBox holding all of them makes every later append slower than the one before it;
        the whole of a run's output is in the run folder's stdout.txt, which is where anyone
        reading it afterwards should be. On the cap the oldest half goes and a line says so, so
        nobody reads a trimmed pane as the start of the run.

    .PARAMETER Line
        The line to append.

    .EXAMPLE
        Write-WorkbenchGuiPane -Line 'Exit 0: Completed'

        Appends the line and scrolls the pane to it.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ($null -eq $script:Gui) { return }

    $box = $script:Gui.LogBox
    $box.AppendText(([string]$Line) + "`r`n")
    $script:Gui.PaneLines++

    if ($script:Gui.PaneLines -gt $script:WorkbenchGuiPaneLimit) {
        $keep = [int]($script:WorkbenchGuiPaneLimit / 2)
        $kept = @(@($box.Lines) | Select-Object -Last $keep)
        $box.Lines = [string[]](@("--- the oldest lines were trimmed; the run folder has all of them ---") + $kept)
        $script:Gui.PaneLines = $kept.Count + 1

        # TextBox.Lines joins its array with a newline and leaves none on the end, so the next
        # AppendText would run onto the last kept line and the pane would silently lose a line
        # break at every trim. One explicit terminator here is what keeps it line-per-line.
        if ($box.TextLength -gt 0) { $box.AppendText("`r`n") }
    }

    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-WorkbenchGuiStatus {
    <#
    .SYNOPSIS
        Puts one sentence in the status strip.

    .PARAMETER Text
        What the strip should say.

    .EXAMPLE
        Set-WorkbenchGuiStatus -Text 'Ready'

        Replaces whatever the strip was showing.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ($null -eq $script:Gui) { return }
    $script:Gui.StatusItem.Text = [string]$Text
}

function Update-WorkbenchGuiRunState {
    <#
    .SYNOPSIS
        Says in the strip, and in the pane, whether anything can be run against this workspace.

    .DESCRIPTION
        Called after every scan - opening a workspace, refreshing one, and the refresh a saved
        settings document triggers - so the one sentence that decides whether the buttons will do
        anything is written from one place and is never stale. That is what makes the refusal
        lift by itself the moment the Settings dialog saves a document that validates: the save
        rescans, the rescan calls this, and the strip goes back to Ready.

        The pane gets the line as well as the strip. The strip holds one sentence and is
        overwritten by the next thing that happens; the pane is the session's record, and an
        operator who came back to the window after lunch should be able to scroll up and find out
        why Run did nothing.

    .EXAMPLE
        Update-WorkbenchGuiRunState

        Writes 'Ready', or names the settings keys that have to be fixed before anything runs.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui) { return }

    $canRun = Test-MigrationWorkspaceRunnable -Workspace $script:Gui.Workspace
    if ($canRun.CanRun) {
        Set-WorkbenchGuiStatus -Text 'Ready'
        return
    }

    Set-WorkbenchGuiStatus -Text ([string]$canRun.Reason)
    if ($null -ne $script:Gui.Workspace) { Write-WorkbenchGuiPane -Line ('  ! ' + [string]$canRun.Reason) }
}

function Set-WorkbenchGuiBusy {
    <#
    .SYNOPSIS
        Locks or releases the window while an engine call is in flight.

    .DESCRIPTION
        Every handler in this region wraps its engine calls in this, because the calls are
        synchronous on the UI thread: a scan of a large workspace takes a second, a child step
        takes minutes, and the only thing keeping the window alive through either is the
        DoEvents in Write-WorkbenchGuiPane. Disabling the controls is what stops a technician
        queueing a second run on top of the first while that pump is running.

        Cancel is the one button that does the opposite: it is enabled only while a run is in
        flight, which is the only time there is anything to cancel.

    .PARAMETER Busy
        $true to lock the window, $false to release it.

    .PARAMETER Activity
        A few words naming what is happening, shown in the status strip.

    .EXAMPLE
        Set-WorkbenchGuiBusy -Busy $true -Activity 'running New-Users'

        Disables the controls and shows 'Working... running New-Users'.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [bool]$Busy,

        [AllowEmptyString()]
        [string]$Activity = ''
    )

    if ($null -eq $script:Gui) { return }

    foreach ($button in @($script:Gui.Buttons)) { $button.Enabled = -not $Busy }
    $script:Gui.Tabs.Enabled = -not $Busy
    $script:Gui.FormPanel.Enabled = -not $Busy
    $script:Gui.WaveList.Enabled = -not $Busy
    $script:Gui.WorkspaceBox.Enabled = -not $Busy
    $script:Gui.Menu.Enabled = -not $Busy

    # Cancel is never enabled from here. 'Busy' also covers a rescan, a settings save and the
    # gate dialogs a run puts up before it starts anything, and a Cancel button that lit up
    # during those would either promise something nothing can deliver or arm a cancellation
    # against a child that has not been started yet. The run action turns it on itself, at the
    # moment there is a process to cancel, and this turns it off again afterwards.
    $script:Gui.CancelButton.Enabled = $false

    if ($Busy) {
        Set-WorkbenchGuiStatus -Text ("Working... $Activity").Trim()
        $script:Gui.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    }
    else {
        $script:Gui.Form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    [System.Windows.Forms.Application]::DoEvents()
}

function Show-WorkbenchGuiMessage {
    <#
    .SYNOPSIS
        Shows a message box, so every dialog in the window looks the same.

    .PARAMETER Message
        The body text.

    .PARAMETER Title
        The caption.

    .PARAMETER Icon
        Information, Warning or Error.

    .EXAMPLE
        Show-WorkbenchGuiMessage -Message 'Pick a step first.' -Icon 'Warning'

        Shows the warning and returns when the operator dismisses it.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateNotNullOrEmpty()]
        [string]$Title = 'M365 Migration Workbench',

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Icon = 'Information'
    )

    [void][System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', $Icon)
}

function Update-WorkbenchGuiTree {
    <#
    .SYNOPSIS
        Redraws the Phases tree from the current workspace scan.

    .DESCRIPTION
        The tree is rebuilt rather than patched, because a run changes the glyph, the last-run
        line and which step is next all at once, and a tree patched in three places is a tree
        that eventually shows two 'next' markers. The model comes from Get-WorkbenchGuiStepList,
        so this function decides nothing: it only draws.

        The selection is restored by id afterwards, so a run does not throw the operator back to
        the top of the runbook.

    .EXAMPLE
        Update-WorkbenchGuiTree

        Redraws the tree from $script:Gui.Workspace.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui -or $null -eq $script:Gui.Workspace) { return }

    $selectedId = ''
    if ($null -ne $script:Gui.Step) { $selectedId = [string]$script:Gui.Step.Id }

    $tree = $script:Gui.Tree
    $script:Gui.Suppress = $true
    $tree.BeginUpdate()
    try {
        $tree.Nodes.Clear()
        foreach ($phase in @(Get-WorkbenchGuiStepList -Workspace $script:Gui.Workspace)) {
            $phaseNode = $tree.Nodes.Add([string]$phase.Phase)
            foreach ($entry in @($phase.Steps)) {
                $text = ('{0} {1}' -f $entry.Glyph, $entry.Title)
                if ($entry.LastRun) { $text = $text + '   ' + $entry.LastRun }
                if ($entry.IsNext) { $text = $text + '   <- next' }

                $node = $phaseNode.Nodes.Add($text)
                $node.Tag = [string]$entry.Id
                if ($entry.IsNext) {
                    $node.NodeFont = New-Object System.Drawing.Font($tree.Font, [System.Drawing.FontStyle]::Bold)
                }
                if ([string]$entry.Id -eq $selectedId) { $tree.SelectedNode = $node }
            }
            $phaseNode.Expand()
        }
    }
    finally {
        $tree.EndUpdate()
        $script:Gui.Suppress = $false
    }
}

function Set-WorkbenchGuiPreview {
    <#
    .SYNOPSIS
        Puts a generated driver in the command preview, and clears up the one it replaces.

    .DESCRIPTION
        The preview shows what New-MigrationStepDriver wrote: the line an operator could have
        typed, and the line that will actually start the child. The window never builds either
        of them - a command line assembled by a front end is a command line that can disagree
        with the file it claims to describe.

        A driver is a real file in the workspace, so the one being replaced is removed unless a
        run has already started in its folder; stdout.txt is the marker for that, because from
        the moment it exists the run folder belongs to Invoke-MigrationStep and is evidence.
        Without this the workspace fills with run folders for runs that never happened.

    .PARAMETER Driver
        The result of New-MigrationStepDriver, or $null to clear the preview.

    .EXAMPLE
        Set-WorkbenchGuiPreview -Driver $driver

        Shows that driver's two command lines and removes the previous unused one.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removes only an unused driver folder this window wrote; the operator asked for it.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        $Driver
    )

    if ($null -eq $script:Gui) { return }

    $previous = $script:Gui.Preview
    if ($null -ne $previous) {
        $folder = [string](Get-MigrationProperty -InputObject $previous -Name 'RunFolder' -Default '')
        if ($folder -and (Test-Path -LiteralPath $folder -PathType Container) -and
            -not (Test-Path -LiteralPath (Join-Path $folder 'stdout.txt') -PathType Leaf)) {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $script:Gui.Preview = $Driver

    if ($null -eq $Driver) {
        $script:Gui.PreviewBox.Text = ''
        return
    }

    $script:Gui.PreviewBox.Text = (@([string]$Driver.DisplayLine, [string]$Driver.CommandLine) -join "`r`n")
}

function Get-WorkbenchGuiWave {
    <#
    .SYNOPSIS
        Reads the waves the operator ticked, as the runner and the gates expect them.

    .DESCRIPTION
        An empty list means the whole plan, which is what '(all waves)' stands for in the list.
        The sentinel is an item rather than an inferred rule, because 'every wave is ticked' and
        'no wave is ticked' would otherwise produce the same command from two opposite-looking
        screens, and neither the WaveRequired gate nor the ledger could tell them apart.

    .EXAMPLE
        Get-WorkbenchGuiWave

        Returns @('1') when wave 1 alone is ticked, and @() when '(all waves)' is.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    if ($null -eq $script:Gui) { return @() }

    $checked = @(@($script:Gui.WaveList.CheckedItems) | ForEach-Object { [string]$_ })
    if ($checked -contains $script:WorkbenchGuiAllWavesLabel) { return @() }
    return @($checked | Where-Object { $_ })
}

function Get-WorkbenchGuiOverride {
    <#
    .SYNOPSIS
        Collects the values the operator changed, as -Override for the argument resolver.

    .DESCRIPTION
        Only the rows the operator actually touched are collected. Sending every control's
        current value would make the provenance of every argument 'Operator', which would hide
        exactly what the form is there to show: that a value came from the settings file, from a
        resolver, or from the instance's own fixed set. A row is marked when its control raises
        a change event, which is why the form's own population runs with $script:Gui.Suppress
        set.

        A row whose value converts to $null - a text box the operator cleared - is dropped
        rather than sent as an empty string, so clearing a field hands the parameter back to the
        settings and the resolvers rather than forcing a blank onto the command line.

    .EXAMPLE
        Get-WorkbenchGuiOverride

        Returns @{ PasswordLength = 20 } after the operator typed 20 in that box.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $overrides = @{}
    if ($null -eq $script:Gui) { return $overrides }

    foreach ($row in @($script:Gui.Rows)) {
        if (-not $row.Dirty) { continue }

        $control = $row.Control
        $text = switch ($row.Kind) {
            'CheckBox' { [string]$control.Checked }
            'CheckedListBox' { (@(@($control.CheckedItems) | ForEach-Object { [string]$_ }) -join "`n") }
            default { [string]$control.Text }
        }

        $value = ConvertTo-WorkbenchGuiOverride -Parameter $row.Parameter -Text $text
        if ($null -eq $value) { continue }
        $overrides[[string]$row.Name] = $value
    }

    return $overrides
}

function Show-WorkbenchGuiStepForm {
    <#
    .SYNOPSIS
        Draws the right-hand form for one step: its parameters, its waves and its banner.

    .DESCRIPTION
        The form is generated, never hand-written (Docs/Workbench-Design.md, section 9). One row
        per parameter the operator could fill in - Test-WorkbenchGuiFormParameter decides which
        those are, so the five options every script shares and the three a dedicated control owns
        never appear - with the control ConvertTo-WorkbenchGuiControlKind chose, the value
        Resolve-MigrationStepArguments already decided, and the rung of the precedence ladder
        that decided it beside the value.

        The values are resolved for a rehearsal, because a rehearsal is the safe reading of a
        step and because the buttons re-resolve for the mode they are: the form is a picture of
        what would run, and the run action never trusts it.

        On a workspace whose settings do not validate (Test-MigrationWorkspaceRunnable) nothing is
        resolved at all. The resolver would answer from a settings document that does not exist:
        no tenant to assert against, no label, and a picture of a run that must not be started
        anyway. The rows are drawn empty and the strip says which keys have to be fixed first.

        A [SecureString] parameter gets a line of text rather than a control. There is no box to
        type a client secret into anywhere in this window, by design.

        A row the instance fixes is drawn disabled. Those values are what make the instance that
        step rather than another one, they outrank an operator override in the resolver, and a
        control that accepted an edit the engine then ignored would be a lie the operator only
        discovers in the driver file.

        The population runs with $script:Gui.Suppress set, so filling a control does not mark
        its row as something the operator changed.

    .PARAMETER Step
        The step instance, or the bare script entry from the All tools tab.

    .EXAMPLE
        Show-WorkbenchGuiStepForm -Step (Get-MigrationStep -Id 'New-Users')

        Replaces the right-hand pane with that step's form.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates the local window only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Step
    )

    if ($null -eq $script:Gui) { return }
    if ($null -eq $script:Gui.Workspace) {
        Show-WorkbenchGuiMessage -Message 'Open a workspace first: a step form is a picture of one migration folder.' `
            -Icon 'Warning'
        return
    }

    $script:Gui.Step = $Step
    $script:Gui.Rows = [System.Collections.Generic.List[object]]::new()
    Set-WorkbenchGuiPreview -Driver $null

    $banner = Format-WorkbenchGuiBanner -Step $Step -Settings (
        Get-MigrationProperty -InputObject $script:Gui.Workspace -Name 'Settings' -Default $null)
    $script:Gui.BannerLabel.Text = [string]$banner.Text
    $script:Gui.BannerLabel.BackColor = switch ([string]$banner.Colour) {
        'Amber' { [System.Drawing.Color]::FromArgb(255, 224, 130) }
        'Blue' { [System.Drawing.Color]::FromArgb(179, 212, 252) }
        default { [System.Drawing.Color]::FromArgb(224, 224, 224) }
    }

    $script:Gui.TitleLabel.Text = ('{0} - {1}   ({2}, {3} tenant, impact {4})' -f
        $Step.Id, $Step.Title, [System.IO.Path]::GetFileName([string]$Step.ScriptPath),
        $Step.Side, $Step.Impact)

    # Resolved once, for a rehearsal: the form shows what a safe run would pass, and both
    # buttons resolve again for the mode they actually are. Nothing is resolved while the
    # settings are unusable - the run actions refuse then, and a form full of values resolved
    # from a document that did not load would be a picture of a run nobody can start.
    $canRun = Test-MigrationWorkspaceRunnable -Workspace $script:Gui.Workspace
    $resolved = $null
    if ($canRun.CanRun) {
        try {
            $resolved = Resolve-MigrationStepArguments -Step $Step -Workspace $script:Gui.Workspace `
                -Override @{} -Wave @() -DryRun
        }
        catch {
            Write-WorkbenchGuiPane -Line "  ! This step's arguments could not be resolved: $($_.Exception.Message)"
        }
    }

    $valueByName = @{}
    $sourceByName = @{}
    if ($null -ne $resolved) {
        foreach ($argument in @($resolved.Arguments)) {
            $valueByName[[string]$argument.Name] = $argument.Value
            $sourceByName[[string]$argument.Name] = [string]$argument.Source
        }
    }

    $panel = $script:Gui.FormPanel
    # Everything from here to the wave list runs suppressed, because filling a control raises the
    # same change event an operator does and every row would otherwise arrive marked as edited.
    # The reset is in the finally: a form that threw half-drawn must not leave the window deaf to
    # the operator's next edit.
    $script:Gui.Suppress = $true
    $panel.SuspendLayout()
    try {
        $panel.Controls.Clear()
        $panel.RowStyles.Clear()
        $panel.RowCount = 0

        $row = 0
        foreach ($parameter in @($Step.Parameters)) {
            if (-not (Test-WorkbenchGuiFormParameter -Parameter $parameter)) { continue }

            $name = [string]$parameter.Name
            $kind = ConvertTo-WorkbenchGuiControlKind -Parameter $parameter
            $source = if ($sourceByName.ContainsKey($name)) { $sourceByName[$name] } else { '' }
            $value = if ($valueByName.ContainsKey($name)) { $valueByName[$name] } else { $null }

            $entry = @{
                Name      = $name
                Parameter = $parameter
                Kind      = $kind
                Control   = $null
                Dirty     = $false
                Source    = $source
            }

            $label = New-Object System.Windows.Forms.Label
            $label.Text = $(if ([bool]$parameter.Mandatory) { "$name *" } else { $name })
            $label.AutoSize = $true
            $label.Anchor = 'Left'
            $label.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)

            $hostControl = New-WorkbenchGuiParameterControl -Row $entry -Value $value
            $entry.Control.Tag = $entry

            $provenance = New-Object System.Windows.Forms.Label
            $provenance.Text = $source
            $provenance.AutoSize = $true
            $provenance.Anchor = 'Left'
            $provenance.ForeColor = [System.Drawing.Color]::DimGray
            $provenance.Margin = New-Object System.Windows.Forms.Padding(6, 6, 3, 3)

            # A fixed value is what makes this instance this step; the resolver outranks any
            # override with it, so an editable control here would be a promise nothing keeps.
            # A Secret row is a sentence rather than a control, and it is disabled for the same
            # reason: there is nothing in it to edit and nothing in it to read back.
            if ($source -eq 'Fixed' -or $kind -eq 'Secret') { $hostControl.Enabled = $false }

            $helpText = [string](Get-MigrationProperty -InputObject $parameter -Name 'Help' -Default '')
            if ($helpText) { $script:Gui.ToolTip.SetToolTip($entry.Control, $helpText) }

            $panel.RowCount = $row + 1
            $null = $panel.RowStyles.Add(
                (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
            $panel.Controls.Add($label, 0, $row)
            $panel.Controls.Add($hostControl, 1, $row)
            $panel.Controls.Add($provenance, 2, $row)

            $script:Gui.Rows.Add($entry)
            $row++
        }

        if ($row -eq 0) {
            $empty = New-Object System.Windows.Forms.Label
            $empty.Text = 'This step takes nothing but the options the workbench sets itself.'
            $empty.AutoSize = $true
            $panel.RowCount = 1
            $panel.Controls.Add($empty, 0, 0)
        }

        # The waves of the plan this workspace holds. A writer starts with nothing ticked so the
        # WaveRequired gate is the one that raises it; a reader starts on the whole plan, which
        # is what reading a plan means and what the console never asks a reader about.
        $waveList = $script:Gui.WaveList
        $waveList.Items.Clear()
        $null = $waveList.Items.Add($script:WorkbenchGuiAllWavesLabel)
        $plan = Get-MigrationProperty -InputObject $script:Gui.Workspace -Name 'Plan' -Default $null
        if ($null -ne $plan) {
            foreach ($wave in @((Get-MigrationProperty -InputObject $plan -Name 'Waves' -Default @{}).Keys)) {
                $null = $waveList.Items.Add([string]$wave)
            }
        }
        $waveList.SetItemChecked(0, ([string]$Step.Impact -notin @('Write', 'Destructive')))
    }
    finally {
        $panel.ResumeLayout()
        $script:Gui.Suppress = $false
    }

    if (-not $canRun.CanRun) {
        # The strip is where the operator looks before pressing a button, so it - not a dialog
        # they would have to dismiss on every selection - is where the refusal belongs.
        Set-WorkbenchGuiStatus -Text ([string]$canRun.Reason)
        return
    }

    Set-WorkbenchGuiStatus -Text ('Ready - {0}' -f $Step.Id)
}

function New-WorkbenchGuiParameterControl {
    <#
    .SYNOPSIS
        Builds the control for one form row and returns what the layout should host.

    .DESCRIPTION
        Split out of Show-WorkbenchGuiStepForm because it is the only part of the form that
        differs per parameter, and because a picker is two controls - a box and a '...' button -
        that have to sit in one cell. The row hashtable is filled in with the control that holds
        the value, which is not always the control returned: for a picker, the returned panel is
        the host and the box inside it is the value.

    .PARAMETER Row
        The row hashtable; its Control member is set here.

    .PARAMETER Value
        The value the resolver decided, or $null.

    .EXAMPLE
        $hostControl = New-WorkbenchGuiParameterControl -Row $entry -Value $resolvedValue

        Returns the control to place in the form's second column.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds a control for the local window only; nothing on the system changes.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [hashtable]$Row,

        [AllowNull()]
        $Value
    )

    $parameter = $Row.Parameter
    $valid = @(Get-MigrationProperty -InputObject $parameter -Name 'ValidValues' -Default @())

    # One renderer for whatever the resolver decided, so a hashtable, an array and a switch all
    # arrive in the box as something the round trip back through ConvertTo-WorkbenchGuiOverride
    # understands.
    $asText = {
        param([AllowNull()]$Item)
        if ($null -eq $Item) { return '' }
        if ($Item -is [System.Collections.IDictionary]) {
            return ((@($Item.Keys) | ForEach-Object { '{0}={1}' -f $_, $Item[$_] }) -join "`r`n")
        }
        if ($Item -isnot [string] -and $Item -is [System.Collections.IEnumerable]) {
            return ((@($Item) | ForEach-Object { [string]$_ }) -join "`r`n")
        }
        return [string]$Item
    }

    switch ($Row.Kind) {
        'Secret' {
            # A Label, not a disabled TextBox and certainly not a PasswordChar box: there is no
            # control here to type into, to paste into, or to read a value back out of. The
            # secret reaches the child process through its environment block and nowhere else
            # (Docs/Workbench-Design.md, sections 7.3 and 9), and a window that collected one
            # would be one more place it could be shoulder-read or screenshot.
            $text = New-Object System.Windows.Forms.Label
            $text.Text = [string]$script:WorkbenchGuiSecretRowText
            $text.AutoSize = $true
            $text.Anchor = 'Left'
            $text.ForeColor = [System.Drawing.Color]::DimGray
            $text.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 3)
            $Row.Control = $text
            return $text
        }

        'CheckBox' {
            $box = New-Object System.Windows.Forms.CheckBox
            $box.AutoSize = $true
            $box.Checked = [bool]$Value
            $box.Add_CheckedChanged({ Invoke-WorkbenchGuiFormChangedAction -Control $args[0] })
            $Row.Control = $box
            return $box
        }

        'ComboBox' {
            $box = New-Object System.Windows.Forms.ComboBox
            $box.DropDownStyle = 'DropDownList'
            $box.Width = 280
            foreach ($choice in $valid) { $null = $box.Items.Add([string]$choice) }
            $text = & $asText $Value
            if ($text -and $box.Items.Contains($text)) { $box.SelectedItem = $text }
            $box.Add_SelectedIndexChanged({ Invoke-WorkbenchGuiFormChangedAction -Control $args[0] })
            $Row.Control = $box
            return $box
        }

        'CheckedListBox' {
            $box = New-Object System.Windows.Forms.CheckedListBox
            $box.CheckOnClick = $true
            $box.IntegralHeight = $false
            $box.Width = 280
            $box.Height = [Math]::Min(120, 20 + (18 * [Math]::Max(1, @($valid).Count)))
            $chosen = @(@($Value) | ForEach-Object { [string]$_ })
            foreach ($choice in $valid) {
                $index = $box.Items.Add([string]$choice)
                if ($chosen -contains [string]$choice) { $box.SetItemChecked($index, $true) }
            }
            $box.Add_ItemCheck({ Invoke-WorkbenchGuiFormChangedAction -Control $args[0] })
            $Row.Control = $box
            return $box
        }

        'MapEditor' {
            $box = New-Object System.Windows.Forms.TextBox
            $box.Multiline = $true
            $box.ScrollBars = 'Vertical'
            $box.Width = 280
            $box.Height = 60
            $box.Text = & $asText $Value
            $box.Add_TextChanged({ Invoke-WorkbenchGuiFormChangedAction -Control $args[0] })
            $Row.Control = $box
            return $box
        }

        default {
            $box = New-Object System.Windows.Forms.TextBox
            $box.Width = 280
            if ([bool](Get-MigrationProperty -InputObject $parameter -Name 'IsArray' -Default $false)) {
                $box.Multiline = $true
                $box.ScrollBars = 'Vertical'
                $box.Height = 48
            }
            $box.Text = & $asText $Value
            $box.Add_TextChanged({ Invoke-WorkbenchGuiFormChangedAction -Control $args[0] })
            $Row.Control = $box

            if ($Row.Kind -notin @('FilePicker', 'FolderPicker')) { return $box }

            $panel = New-Object System.Windows.Forms.FlowLayoutPanel
            $panel.AutoSize = $true
            $panel.FlowDirection = 'LeftToRight'
            $panel.WrapContents = $false
            $panel.Margin = New-Object System.Windows.Forms.Padding(0)

            $pick = New-Object System.Windows.Forms.Button
            $pick.Text = '...'
            $pick.Width = 32
            $pick.Tag = $Row
            $pick.Add_Click({ Invoke-WorkbenchGuiPickPathAction -Control $args[0] })

            $panel.Controls.Add($box)
            $panel.Controls.Add($pick)
            return $panel
        }
    }
}

function Show-WorkbenchGuiTypedConfirmation {
    <#
    .SYNOPSIS
        Asks the operator to type a hard gate's RequiredInput, and returns whether they did.

    .DESCRIPTION
        A hard gate exists to make somebody type something (Docs/Workbench-Design.md, section
        7.2), so the dialog's OK button stays disabled until the text box holds exactly what the
        gate asked for - judged by Test-MigrationTypedConfirmation, the same rule the console
        and the unattended path use. A keypress is never accepted in its place, and a gate
        naming nothing to type is refused here rather than shown as a dialog nobody could pass.

    .PARAMETER Message
        The gate's own sentence.

    .PARAMETER RequiredInput
        What has to be typed.

    .EXAMPLE
        Show-WorkbenchGuiTypedConfirmation -Message $gate.Message -RequiredInput 'newco.com'

        Returns $true only if the operator typed that domain and pressed OK.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RequiredInput
    )

    if ([string]::IsNullOrWhiteSpace($RequiredInput)) { return $false }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Type it out'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.StartPosition = 'CenterParent'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 190)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $text = New-Object System.Windows.Forms.Label
    $text.Text = $Message
    $text.SetBounds(12, 12, 496, 64)

    $ask = New-Object System.Windows.Forms.Label
    $ask.Text = "Type '$RequiredInput' exactly to continue:"
    $ask.SetBounds(12, 84, 496, 20)

    $answer = New-Object System.Windows.Forms.TextBox
    $answer.SetBounds(12, 108, 496, 24)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Continue'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.SetBounds(316, 146, 90, 30)
    $ok.Enabled = $false

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.SetBounds(416, 146, 90, 30)

    $dialog.Controls.AddRange(@($text, $ask, $answer, $ok, $cancel))
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    # The handler is a named function reading the state bag, like every other handler here, so
    # it does not depend on what happened to be in scope when the dialog was built.
    $script:Gui.Confirmation = @{ AnswerBox = $answer; OkButton = $ok; Required = $RequiredInput }
    $answer.Add_TextChanged({ Invoke-WorkbenchGuiConfirmationChangedAction })

    try {
        $result = $dialog.ShowDialog($script:Gui.Form)
        return (($result -eq [System.Windows.Forms.DialogResult]::OK) -and
            (Test-MigrationTypedConfirmation -Typed $answer.Text -Required $RequiredInput))
    }
    finally {
        $script:Gui.Confirmation = $null
        $dialog.Dispose()
    }
}

function Show-WorkbenchGuiResultSummary {
    <#
    .SYNOPSIS
        Reports one finished run: what the exit code meant, what it counted and what it wrote.

    .DESCRIPTION
        The same five things the console prints after a run (Docs/Workbench-Design.md, section
        8), in a dialog: the meaning of the exit code, the Planned/Succeeded/Failed/Skipped
        counts, the files produced, the run's own log, and whether the child reached the tenant
        it was given.

        A tenant mismatch gets its own red dialog whatever the exit code was. A step that exited
        0 against the wrong tenant is the worst outcome this toolkit can produce, and a line in
        a summary dialog is exactly the kind of thing an operator clicks past.

    .PARAMETER Result
        The result object from Invoke-MigrationStep.

    .PARAMETER Step
        The step that ran, named in the caption.

    .EXAMPLE
        Show-WorkbenchGuiResultSummary -Result $result -Step $step

        Shows the summary, and a TENANT MISMATCH dialog first where one is warranted.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Result,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Step
    )

    $verified = Get-MigrationProperty -InputObject $Result -Name 'TenantVerified' -Default $null
    if ($verified -eq $false) {
        # One sentence, built by the engine, so the window, the console and the unattended path
        # cannot describe the same outcome three different ways - and so that a run which
        # printed no tenant line at all is reported as the sign-in failure it is rather than
        # sending an operator after a GUID nobody saw.
        $verdict = Format-MigrationTenantVerdict -Result $Result
        $warning = ("TENANT MISMATCH`r`n`r`n$verdict Check the tenant GUIDs in Settings before " +
            'anything else, and read the run log before trusting what this step reports.')
        Write-WorkbenchGuiPane -Line '!! TENANT MISMATCH'
        Write-WorkbenchGuiPane -Line "   $verdict"
        Show-WorkbenchGuiMessage -Message $warning -Title 'Tenant mismatch' -Icon 'Error'
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Exit {0}: {1}' -f $Result.ExitCode, $Result.Meaning)

    $summary = Get-MigrationProperty -InputObject $Result -Name 'Summary' -Default $null
    $counts = [System.Collections.Generic.List[string]]::new()
    foreach ($countName in @('Planned', 'Succeeded', 'Failed', 'Skipped')) {
        $count = [int](Get-MigrationProperty -InputObject $summary -Name $countName -Default 0)
        if ($count -gt 0) { $counts.Add("$count $countName") }
    }
    if ($counts.Count -gt 0) { $lines.Add($counts -join ', ') }

    $lines.Add('')
    foreach ($file in @(Get-MigrationProperty -InputObject $Result -Name 'Files' -Default @())) {
        $lines.Add("wrote $file")
    }
    $lines.Add("log  $($Result.StdoutPath)")

    $lines.Add('')
    $lines.Add($(
            if ($verified -eq $false) { 'TENANT MISMATCH - see the dialog above.' }
            else { Format-MigrationTenantVerdict -Result $Result }))

    $icon = if ($verified -eq $false -or [int]$Result.ExitCode -eq 1) { 'Error' }
    elseif ([int]$Result.ExitCode -ne 0) { 'Warning' }
    else { 'Information' }

    Show-WorkbenchGuiMessage -Message ($lines -join "`r`n") -Title ('Run: {0}' -f $Step.Id) -Icon $icon
}

function Show-WorkbenchGuiSettingsDialog {
    <#
    .SYNOPSIS
        Opens the settings form: one row per schema key, validated by the engine before it saves.

    .DESCRIPTION
        The same document the console's form edits (Docs/Workbench-Design.md, sections 4 and 8),
        drawn as a dialog. Every key Get-MigrationSettingsSchema declares gets a row - a
        drop-down for a Choice, a tick for a Bool, a two-column box for the alias domain Map,
        and a text box for everything else - except SchemaVersion, which is the file format's
        own version and not a choice an operator has.

        A tenant row gets a Resolve button, because an operator knows their tenant by its domain
        and every connector in the toolkit compares GUIDs. Where the lookup fails - no network,
        a typo, a domain in no tenant - what was typed is kept and the validator gets to say
        what is wrong with it, which is far more use than a field that silently emptied itself.

        Nothing is written until the document validates. It is validated the way it will be
        read: written to a temporary file and loaded back through Resolve-MigrationSettings,
        which is the only way to get the errors back as objects with the key each one is about,
        so the dialog can put each message beside the field that caused it. Only then does
        Save-MigrationSettings write - atomically, keeping the previous version.

    .EXAMPLE
        Show-WorkbenchGuiSettingsDialog

        Opens the dialog on the open workspace and returns when it is closed.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The nested Set- helper writes one key into an in-memory document; nothing reaches disk here.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($null -eq $script:Gui -or $null -eq $script:Gui.Workspace) { return $false }

    $workspace = $script:Gui.Workspace
    $schema = @(Get-MigrationSettingsSchema | Where-Object { [string]$_.Key -ne 'SchemaVersion' })

    # The document is one level deep at most, so walking a dotted key is two cases and no more.
    function Get-WorkbenchGuiSettingsValue {
        param([AllowNull()]$Document, [string]$Key)
        $segments = $Key -split '\.', 2
        $value = Get-MigrationProperty -InputObject $Document -Name $segments[0] -Default $null
        if ($segments.Count -eq 1) { return $value }
        return (Get-MigrationProperty -InputObject $value -Name $segments[1] -Default $null)
    }

    function Set-WorkbenchGuiSettingsValue {
        param($Document, [string]$Key, [AllowNull()]$Value)
        $segments = $Key -split '\.', 2
        if ($segments.Count -eq 1) { $Document[$segments[0]] = $Value; return }
        if (-not $Document.Contains($segments[0])) { $Document[$segments[0]] = [ordered]@{} }
        $Document[$segments[0]][$segments[1]] = $Value
    }

    $dialog = New-Object System.Windows.Forms.Form

    # Everything the dialog is made of is built inside the try. Building a control can fail for
    # reasons that have nothing to do with this workspace - a font that is not installed, a
    # value the schema describes but this document holds in another shape - and this dialog is
    # the only way an operator fixes a settings file that will not validate. It must arrive as a
    # message, never as an error that closes the window behind it.
    try {
        $dialog.Text = "Settings - $($workspace.Path)"
        $dialog.StartPosition = 'CenterParent'
        $dialog.ClientSize = New-Object System.Drawing.Size(900, 640)
        $dialog.MinimumSize = New-Object System.Drawing.Size(760, 480)
        $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $dialog.AutoScaleMode = 'Dpi'

        $grid = New-Object System.Windows.Forms.TableLayoutPanel
        $grid.Dock = 'Fill'
        $grid.ColumnCount = 4
        $grid.AutoScroll = $true
        $grid.GrowStyle = 'AddRows'
        $null = $grid.ColumnStyles.Add(
            (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $null = $grid.ColumnStyles.Add(
            (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $null = $grid.ColumnStyles.Add(
            (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
        $null = $grid.ColumnStyles.Add(
            (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

        $rows = [System.Collections.Generic.List[object]]::new()
        $index = 0
        foreach ($entry in $schema) {
            $key = [string]$entry.Key
            $current = Get-WorkbenchGuiSettingsValue -Document $workspace.Settings -Key $key

            $label = New-Object System.Windows.Forms.Label
            $label.Text = $key
            $label.AutoSize = $true
            $label.Anchor = 'Left'
            $label.Margin = New-Object System.Windows.Forms.Padding(3, 7, 8, 3)

            $control = $null
            switch ([string]$entry.Type) {
                'Choice' {
                    $control = New-Object System.Windows.Forms.ComboBox
                    $control.DropDownStyle = 'DropDownList'
                    $control.Width = 320
                    foreach ($choice in @($entry.Choices)) { $null = $control.Items.Add([string]$choice) }
                    $chosen = [string]$current
                    if (-not $chosen) { $chosen = [string]$entry.Default }
                    if ($control.Items.Contains($chosen)) { $control.SelectedItem = $chosen }
                }
                'Bool' {
                    $control = New-Object System.Windows.Forms.CheckBox
                    $control.AutoSize = $true
                    $control.Checked = [bool]$current
                }
                'Map' {
                    $control = New-Object System.Windows.Forms.TextBox
                    $control.Multiline = $true
                    $control.ScrollBars = 'Vertical'
                    $control.Width = 320
                    $control.Height = 60
                    if ($current -is [System.Collections.IDictionary]) {
                        $control.Text = ((@($current.Keys) |
                                ForEach-Object { '{0}={1}' -f $_, $current[$_] }) -join "`r`n")
                    }
                }
                default {
                    $control = New-Object System.Windows.Forms.TextBox
                    $control.Width = 320
                    $control.Text = [string]$current
                }
            }

            $extra = New-Object System.Windows.Forms.Label
            $extra.Text = ''
            $extra.AutoSize = $true
            if ($key -like '*.TenantId') {
                $extra = New-Object System.Windows.Forms.Button
                $extra.Text = 'Resolve'
                $extra.Width = 80
                $extra.Tag = $control
                $extra.Add_Click({ Invoke-WorkbenchGuiResolveTenantAction -Control $args[0] })
            }

            $message = New-Object System.Windows.Forms.Label
            $message.Text = [string]$entry.Description
            $message.AutoSize = $true
            $message.MaximumSize = New-Object System.Drawing.Size(420, 0)
            $message.ForeColor = [System.Drawing.Color]::DimGray
            $message.Margin = New-Object System.Windows.Forms.Padding(8, 7, 3, 3)

            $grid.Controls.Add($label, 0, $index)
            $grid.Controls.Add($control, 1, $index)
            $grid.Controls.Add($extra, 2, $index)
            $grid.Controls.Add($message, 3, $index)

            $rows.Add(@{
                    Key          = $key
                    Type         = [string]$entry.Type
                    Control      = $control
                    MessageLabel = $message
                    Description  = [string]$entry.Description
                })
            $index++
        }

        $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
        $buttons.Dock = 'Bottom'
        $buttons.FlowDirection = 'RightToLeft'
        $buttons.AutoSize = $true
        $buttons.Padding = New-Object System.Windows.Forms.Padding(6)

        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.Width = 100
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

        $save = New-Object System.Windows.Forms.Button
        $save.Text = 'Save'
        $save.Width = 100
        $save.Add_Click({ Invoke-WorkbenchGuiSettingsSaveAction })

        $buttons.Controls.Add($cancel)
        $buttons.Controls.Add($save)

        $dialog.Controls.Add($grid)
        $dialog.Controls.Add($buttons)
        $dialog.CancelButton = $cancel

        # Save reads the rows and the dialog out of the state bag, so it is a named function like
        # every other handler rather than a closure over this function's locals.
        $script:Gui.SettingsForm = @{
            Dialog   = $dialog
            Rows     = @($rows)
            Writer   = ${function:Set-WorkbenchGuiSettingsValue}
            SavePath = [string]$workspace.SettingsPath
        }

        $result = $dialog.ShowDialog($script:Gui.Form)
        return ($result -eq [System.Windows.Forms.DialogResult]::OK)
    }
    catch {
        Show-WorkbenchGuiMessage -Message ("The settings dialog could not be built: " +
            "$($_.Exception.Message)`r`n`r`nThe file can still be edited by hand: " +
            [string]$workspace.SettingsPath) -Icon 'Error'
        return $false
    }
    finally {
        $script:Gui.SettingsForm = $null
        $dialog.Dispose()
    }
}

function Invoke-WorkbenchGuiSettingsSaveAction {
    <#
    .SYNOPSIS
        Validates the settings dialog's fields and writes the document when they pass.

    .DESCRIPTION
        Builds a fresh document from New-MigrationSettings and the dialog's controls, writes it
        to a temporary file, and reads it back through Resolve-MigrationSettings. That round
        trip is what turns a validation failure into errors carrying the key each one is about,
        which is what lets the dialog put a message beside the field rather than in one
        undifferentiated list. Only a document that comes back clean is written to the
        workspace, through Save-MigrationSettings.

        The temporary file is written outside the workspace and removed in a finally, so a
        failed validation leaves nothing behind anywhere.

    .EXAMPLE
        Invoke-WorkbenchGuiSettingsSaveAction

        The Save button's handler.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui -or $null -eq $script:Gui.SettingsForm) { return }

    $state = $script:Gui.SettingsForm
    $document = New-MigrationSettings

    foreach ($row in @($state.Rows)) {
        $control = $row.Control
        $value = switch ([string]$row.Type) {
            'Choice' { [string]$control.Text }
            'Bool' { [bool]$control.Checked }
            'Map' {
                $map = [ordered]@{}
                foreach ($line in @([string]$control.Text -split "`r?`n")) {
                    $pair = $line -split '=', 2
                    if ($pair.Count -ne 2) { continue }
                    $left = $pair[0].Trim()
                    if (-not $left) { continue }
                    $map[$left] = $pair[1].Trim()
                }
                $map
            }
            'Int' {
                $number = 0
                # Kept as typed when it will not parse, so the validator names the key and the
                # value rather than the dialog silently substituting a number.
                if ([int]::TryParse(([string]$control.Text).Trim(), [ref]$number)) { $number }
                else { ([string]$control.Text).Trim() }
            }
            default { ([string]$control.Text).Trim() }
        }

        & $state.Writer $document ([string]$row.Key) $value
        $row.MessageLabel.Text = [string]$row.Description
        $row.MessageLabel.ForeColor = [System.Drawing.Color]::DimGray
    }

    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) (
        'M365Migration-settings-{0}.json' -f [guid]::NewGuid().ToString('N'))
    $errors = @()
    try {
        Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop `
            -Value ($document | ConvertTo-Json -Depth 6)
        $errors = @((Resolve-MigrationSettings -Path $temporary).Errors)
    }
    catch {
        Show-WorkbenchGuiMessage -Message "The settings could not be checked: $($_.Exception.Message)" `
            -Title 'Settings' -Icon 'Error'
        return
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }

    if ($errors.Count -gt 0) {
        $unplaced = [System.Collections.Generic.List[string]]::new()
        foreach ($problem in $errors) {
            $key = [string](Get-MigrationProperty -InputObject $problem -Name 'Key' -Default '')
            $text = [string](Get-MigrationProperty -InputObject $problem -Name 'Message' -Default $problem)
            $row = @($state.Rows | Where-Object { [string]$_.Key -eq $key }) | Select-Object -First 1
            if ($key -and $null -ne $row) {
                $row.MessageLabel.Text = $text
                $row.MessageLabel.ForeColor = [System.Drawing.Color]::Firebrick
                continue
            }
            # An error naming no key is about the document rather than a field, and there is no
            # row to put it beside.
            $unplaced.Add($text)
        }

        $summary = 'These settings are not valid yet; the fields that need attention are marked in red.'
        if ($unplaced.Count -gt 0) { $summary = $summary + "`r`n`r`n" + ($unplaced -join "`r`n") }
        Show-WorkbenchGuiMessage -Message $summary -Title 'Settings' -Icon 'Warning'
        return
    }

    try {
        $null = Save-MigrationSettings -Path ([string]$state.SavePath) -Settings $document
    }
    catch {
        Show-WorkbenchGuiMessage -Message "The settings could not be saved: $($_.Exception.Message)" `
            -Title 'Settings' -Icon 'Error'
        return
    }

    Write-WorkbenchGuiPane -Line "Settings saved to $($state.SavePath)"
    $state.Dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $state.Dialog.Close()
}

function Invoke-WorkbenchGuiResolveTenantAction {
    <#
    .SYNOPSIS
        Turns a domain typed in a tenant field into the tenant's GUID.

    .PARAMETER Control
        The Resolve button; its Tag is the text box to read and rewrite.

    .EXAMPLE
        Invoke-WorkbenchGuiResolveTenantAction -Control $button

        Replaces 'contoso.com' with the tenant GUID that domain belongs to.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Control
    )

    $box = $Control.Tag
    $typed = ([string]$box.Text).Trim()
    if (-not $typed) {
        Show-WorkbenchGuiMessage -Message 'Type a domain or a GUID first.' -Title 'Settings' -Icon 'Warning'
        return
    }

    try {
        Set-WorkbenchGuiBusy -Busy $true -Activity 'resolving the tenant'
        $box.Text = [string](Resolve-MigrationTenantId -Tenant $typed)
    }
    catch {
        # What was typed is kept: the validator naming a bad value is more use to the operator
        # than a field that emptied itself while they were looking somewhere else.
        Show-WorkbenchGuiMessage -Message ($_.Exception.Message + "`r`n`r`nWhat you typed was kept.") `
            -Title 'Settings' -Icon 'Warning'
    }
    finally {
        Set-WorkbenchGuiBusy -Busy $false
        Set-WorkbenchGuiStatus -Text 'Ready'
    }
}

function Invoke-WorkbenchGuiConfirmationChangedAction {
    <#
    .SYNOPSIS
        Enables the typed-confirmation dialog's OK button only when the text is exactly right.

    .EXAMPLE
        Invoke-WorkbenchGuiConfirmationChangedAction

        The confirmation box's TextChanged handler.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui -or $null -eq $script:Gui.Confirmation) { return }

    $state = $script:Gui.Confirmation
    $state.OkButton.Enabled = Test-MigrationTypedConfirmation -Typed ([string]$state.AnswerBox.Text) `
        -Required ([string]$state.Required)
}

function Invoke-WorkbenchGuiFormChangedAction {
    <#
    .SYNOPSIS
        Marks a step-form row as edited by the operator and drops the stale command preview.

    .DESCRIPTION
        Only a row the operator actually changed becomes an -Override, which is what keeps the
        provenance column honest (see Get-WorkbenchGuiOverride). The form's own population sets
        $script:Gui.Suppress, so filling a control does not count as an edit.

    .PARAMETER Control
        The control that raised the event; its Tag is the row.

    .EXAMPLE
        Invoke-WorkbenchGuiFormChangedAction -Control $textBox

        Marks that row edited.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Control
    )

    if ($null -eq $script:Gui -or $script:Gui.Suppress) { return }

    $row = $Control.Tag
    if ($row -is [hashtable]) { $row.Dirty = $true }

    # The preview describes a command that is no longer the one this form would run.
    Set-WorkbenchGuiPreview -Driver $null
}

function Invoke-WorkbenchGuiPickPathAction {
    <#
    .SYNOPSIS
        Opens a file or folder picker for a path parameter and writes the choice into its box.

    .DESCRIPTION
        A common dialog is a shell call, and a shell call fails for reasons that have nothing to
        do with this window - a path the shell cannot expand, a namespace extension that throws.
        Every handler in this region has to survive that with a message rather than by taking the
        window down, and the dialog is disposed in a finally because it is an unmanaged handle
        whether it returned OK, Cancel or an exception.

    .PARAMETER Control
        The '...' button; its Tag is the row.

    .EXAMPLE
        Invoke-WorkbenchGuiPickPathAction -Control $button

        Opens the picker and fills the box beside it.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Control
    )

    if ($null -eq $script:Gui) { return }

    $row = $Control.Tag
    if ($row -isnot [hashtable]) { return }

    $start = [string]$script:Gui.WorkspacePath
    $chosen = ''
    $picker = $null

    try {
        if ([string]$row.Kind -eq 'FolderPicker') {
            $picker = New-Object System.Windows.Forms.FolderBrowserDialog
            $picker.Description = "Folder for -$($row.Name)"
            if ($start) { $picker.SelectedPath = $start }
            if ($picker.ShowDialog($script:Gui.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $chosen = $picker.SelectedPath
            }
        }
        else {
            $picker = New-Object System.Windows.Forms.OpenFileDialog
            $picker.Title = "File for -$($row.Name)"
            $picker.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
            # An array parameter takes several files, which is exactly what the picker offers.
            $picker.Multiselect = [bool](Get-MigrationProperty -InputObject $row.Parameter -Name 'IsArray' `
                    -Default $false)
            if ($start) { $picker.InitialDirectory = $start }
            if ($picker.ShowDialog($script:Gui.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $chosen = (@($picker.FileNames) -join "`r`n")
            }
        }
    }
    catch {
        Show-WorkbenchGuiMessage -Message ("That picker could not be opened: $($_.Exception.Message)" +
            "`r`n`r`nType the path into the box instead.") -Icon 'Warning'
        return
    }
    finally {
        if ($null -ne $picker) { $picker.Dispose() }
    }

    if (-not $chosen) { return }
    $row.Control.Text = $chosen
    $row.Dirty = $true
    Set-WorkbenchGuiPreview -Driver $null
}

function Invoke-WorkbenchGuiTreeSelectAction {
    <#
    .SYNOPSIS
        Shows the form for the step the operator picked in the Phases tree.

    .PARAMETER Node
        The selected tree node; its Tag is the step id, and a phase node has none.

    .EXAMPLE
        Invoke-WorkbenchGuiTreeSelectAction -Node $tree.SelectedNode

        Redraws the right-hand pane for that step.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        $Node
    )

    if ($null -eq $script:Gui -or $script:Gui.Suppress -or $null -eq $Node) { return }

    $id = [string]$Node.Tag
    if (-not $id) { return }

    try {
        Set-WorkbenchGuiBusy -Busy $true -Activity "opening $id"
        Show-WorkbenchGuiStepForm -Step (Get-MigrationStep -Id $id)
    }
    catch {
        Show-WorkbenchGuiMessage -Message "That step could not be opened: $($_.Exception.Message)" -Icon 'Error'
    }
    finally {
        Set-WorkbenchGuiBusy -Busy $false
    }
}

function Invoke-WorkbenchGuiToolSelectAction {
    <#
    .SYNOPSIS
        Shows the form for the script the operator picked in the All tools list.

    .DESCRIPTION
        The all-tools entry is the bare script: it fixes nothing, so every option the script has
        is offered free. That is the point of the second tab.

    .EXAMPLE
        Invoke-WorkbenchGuiToolSelectAction

        Opens the selected script's form.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui) { return }

    $selected = @($script:Gui.ToolList.SelectedItems)
    if ($selected.Count -eq 0) { return }
    $name = [string]$selected[0].Tag
    if (-not $name) { return }

    try {
        Set-WorkbenchGuiBusy -Busy $true -Activity "opening $name"
        Show-WorkbenchGuiStepForm -Step (Get-MigrationStep -Script $name)
    }
    catch {
        Show-WorkbenchGuiMessage -Message "That tool could not be opened: $($_.Exception.Message)" -Icon 'Error'
    }
    finally {
        Set-WorkbenchGuiBusy -Busy $false
    }
}

function Invoke-WorkbenchGuiOpenWorkspaceAction {
    <#
    .SYNOPSIS
        Opens a workspace: scans it, redraws the tree, and clears the step form.

    .DESCRIPTION
        One scan, one redraw. The scan is Get-MigrationWorkspace and nothing else, so the window
        shows exactly what the console would show for the same folder; a workspace whose
        settings will not load is still opened, with the problems written into the pane and the
        Settings dialog offered, because the operator has to be able to fix them from here - and
        fixing them through that dialog is the one thing this window can do that the console
        cannot.

        Opened, but not runnable: Update-WorkbenchGuiRunState puts the keys that have to be fixed
        in the status strip and in the pane, and every run action refuses until they are. The
        tree is still drawn, because a runbook an operator can read is how they work out which
        settings they are missing.

    .PARAMETER Path
        The workspace folder.

    .EXAMPLE
        Invoke-WorkbenchGuiOpenWorkspaceAction -Path 'C:\Migration-Automations\Contoso'

        Scans that folder and fills the window with it.

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

    if ($null -eq $script:Gui) { return }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Show-WorkbenchGuiMessage -Message "The workspace folder '$Path' does not exist." -Icon 'Warning'
        return
    }

    try {
        Set-WorkbenchGuiBusy -Busy $true -Activity 'scanning the workspace'

        # Reaped before the new workspace is scanned, not after. A driver written for Copy
        # command and never run is not evidence of anything, and leaving it behind would put a
        # run folder in the old workspace for a run that never happened - including when the
        # scan below is the thing that throws.
        Set-WorkbenchGuiPreview -Driver $null

        $script:Gui.WorkspacePath = $Path
        $script:Gui.WorkspaceBox.Text = $Path
        $script:Gui.Workspace = Get-MigrationWorkspace -Path $Path
        $script:Gui.Step = $null
        $script:Gui.FormPanel.Controls.Clear()
        $script:Gui.Rows = [System.Collections.Generic.List[object]]::new()
        $script:Gui.TitleLabel.Text = 'Pick a step on the left.'

        Add-WorkbenchRecentWorkspace -Path $Path
        Update-WorkbenchGuiTree

        Write-WorkbenchGuiPane -Line "--- workspace $Path ---"
        foreach ($warning in @(Get-MigrationProperty -InputObject $script:Gui.Workspace -Name 'Warnings' `
                    -Default @())) {
            Write-WorkbenchGuiPane -Line "  ! $warning"
        }

        $canRun = Test-MigrationWorkspaceRunnable -Workspace $script:Gui.Workspace
        if (-not $canRun.CanRun) {
            foreach ($problem in @($script:Gui.Workspace.SettingsResult.Errors)) {
                Write-WorkbenchGuiPane -Line "  ! $problem"
            }
            Show-WorkbenchGuiMessage -Message ([string]$canRun.Reason + "`r`n`r`n" +
                'Without a label the scanner cannot attribute a single file to a step, and without the ' +
                'tenant GUIDs no run can assert where it wrote.') -Title 'Settings' -Icon 'Warning'
        }

        if ($null -ne (Get-MigrationRunContext)) {
            Write-MigrationLog -Message "Workbench window opened on $Path" -Level INFO
        }
    }
    catch {
        Show-WorkbenchGuiMessage -Message "That workspace could not be opened: $($_.Exception.Message)" `
            -Icon 'Error'
    }
    finally {
        Set-WorkbenchGuiBusy -Busy $false
        Update-WorkbenchGuiRunState
    }
}

function Invoke-WorkbenchGuiBrowseAction {
    <#
    .SYNOPSIS
        Asks for a workspace folder and opens it.

    .DESCRIPTION
        Everything is inside the try, the picker included. Working out where to start it reads
        the default output root and touches the disk, and a handler that threw before it reached
        its own try would take the window down over a path lookup.

    .EXAMPLE
        Invoke-WorkbenchGuiBrowseAction

        The Browse button's handler.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui) { return }

    $picker = $null
    try {
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = 'Pick the migration folder'
        $start = [string]$script:Gui.WorkspacePath
        if (-not $start) { $start = Get-MigrationDefaultOutputRoot }
        if ($start -and (Test-Path -LiteralPath $start -PathType Container)) { $picker.SelectedPath = $start }

        if ($picker.ShowDialog($script:Gui.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        Invoke-WorkbenchGuiOpenWorkspaceAction -Path $picker.SelectedPath
    }
    catch {
        Show-WorkbenchGuiMessage -Message "The folder picker could not be opened: $($_.Exception.Message)" `
            -Icon 'Error'
    }
    finally {
        if ($null -ne $picker) { $picker.Dispose() }
    }
}

function Invoke-WorkbenchGuiRefreshAction {
    <#
    .SYNOPSIS
        Rescans the open workspace and redraws the tree.

    .EXAMPLE
        Invoke-WorkbenchGuiRefreshAction

        Picks up a file another window wrote into the workspace.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui -or -not $script:Gui.WorkspacePath) { return }

    try {
        Set-WorkbenchGuiBusy -Busy $true -Activity 'rescanning the workspace'
        $script:Gui.Workspace = Get-MigrationWorkspace -Path ([string]$script:Gui.WorkspacePath)
        Update-WorkbenchGuiTree
    }
    catch {
        Show-WorkbenchGuiMessage -Message "The workspace could not be rescanned: $($_.Exception.Message)" `
            -Icon 'Error'
    }
    finally {
        Set-WorkbenchGuiBusy -Busy $false
        # The rescan is also what a saved settings document triggers, so this is where a refusal
        # that has just been fixed stops being shown.
        Update-WorkbenchGuiRunState
    }
}

function Invoke-WorkbenchGuiSettingsAction {
    <#
    .SYNOPSIS
        Opens the settings dialog and rescans when it saved.

    .DESCRIPTION
        The dialog is the way out of a workspace whose settings do not validate, so a failure to
        build or show it has to arrive as a message rather than as an unhandled error: an
        operator whose only route to fixing the file is this menu item must not be left with a
        window that closed itself instead.

    .EXAMPLE
        Invoke-WorkbenchGuiSettingsAction

        The Settings menu item's handler.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui -or $null -eq $script:Gui.Workspace) {
        Show-WorkbenchGuiMessage -Message 'Open a workspace first.' -Icon 'Warning'
        return
    }

    try {
        if (Show-WorkbenchGuiSettingsDialog) {
            # Every state on the board is derived from the settings - the label decides which
            # files belong to which step - so a saved document means a stale board. The rescan
            # is also what lifts the run refusal when the document now validates.
            Invoke-WorkbenchGuiRefreshAction
        }
    }
    catch {
        Show-WorkbenchGuiMessage -Message ("The settings dialog could not be opened: " +
            "$($_.Exception.Message)`r`n`r`nThe file can still be edited by hand: " +
            [string](Get-MigrationProperty -InputObject $script:Gui.Workspace -Name 'SettingsPath' `
                    -Default '')) -Icon 'Error'
    }
}

function Invoke-WorkbenchGuiResultsAction {
    <#
    .SYNOPSIS
        Writes the console's Results & logs view into the log pane.

    .DESCRIPTION
        The same lines the console prints for that screen, rendered by the same function
        (Format-MigrationWorkbenchView), so the two front ends cannot come to describe one
        workspace's run history differently. The pane is the right place for it: it is already
        the window's scrollback, and a run folder path is something an operator copies out.

    .EXAMPLE
        Invoke-WorkbenchGuiResultsAction

        Dumps the last 20 runs, newest first, into the pane.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui -or $null -eq $script:Gui.Workspace) {
        Show-WorkbenchGuiMessage -Message 'Open a workspace first.' -Icon 'Warning'
        return
    }

    try {
        Set-WorkbenchGuiBusy -Busy $true -Activity 'reading the run ledger'
        $lines = @(Format-MigrationWorkbenchView -Workspace $script:Gui.Workspace -View 'Results' `
                -Version ([string]$script:Gui.Version))
        Write-WorkbenchGuiPane -Line '--- results & logs ---'
        foreach ($line in $lines) { Write-WorkbenchGuiPane -Line ([string]$line) }
        Write-WorkbenchGuiPane -Line '--- end of results & logs ---'
    }
    catch {
        Show-WorkbenchGuiMessage -Message "The run ledger could not be read: $($_.Exception.Message)" `
            -Icon 'Error'
    }
    finally {
        Set-WorkbenchGuiBusy -Busy $false
        Set-WorkbenchGuiStatus -Text 'Ready'
    }
}

function Invoke-WorkbenchGuiCopyAction {
    <#
    .SYNOPSIS
        Copies the command the selected step would run to the clipboard.

    .DESCRIPTION
        What is copied is a real driver's command line, never a line this window assembled: the
        command starts a file, and a front end that printed a command it had not written would
        eventually print one the file does not match.

        The preview's command is copied when there is one - after a run, that is the command
        that ran, because the run action leaves its own driver in the preview. With an empty
        preview a rehearsal's driver is written, because a rehearsal is the safe reading of a
        step; pressing Run writes the live one into the preview before it starts, and copying
        then gives the live command.

        A workspace whose settings do not validate is refused here as it is on the run buttons.
        Writing a driver would mean resolving arguments against a settings document that did not
        load, and a command line on the clipboard is a command line somebody pastes into a
        console - so the one thing worse than running it from here would be handing it over to
        be run somewhere else.

    .EXAMPLE
        Invoke-WorkbenchGuiCopyAction

        Puts 'pwsh -NoProfile -File "...driver.ps1"' on the clipboard.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui) { return }
    if ($null -eq $script:Gui.Step) {
        Show-WorkbenchGuiMessage -Message 'Pick a step first.' -Icon 'Warning'
        return
    }

    $canRun = Test-MigrationWorkspaceRunnable -Workspace $script:Gui.Workspace
    if (-not $canRun.CanRun) {
        Show-WorkbenchGuiMessage -Message ([string]$canRun.Reason) -Title 'Settings' -Icon 'Warning'
        return
    }

    try {
        Set-WorkbenchGuiBusy -Busy $true -Activity 'writing the driver'

        if ($null -eq $script:Gui.Preview) {
            $resolved = Resolve-MigrationStepArguments -Step $script:Gui.Step -Workspace $script:Gui.Workspace `
                -Override (Get-WorkbenchGuiOverride) -Wave (Get-WorkbenchGuiWave) -DryRun
            Set-WorkbenchGuiPreview -Driver (New-MigrationStepDriver -Step $script:Gui.Step `
                    -Arguments $resolved -Workspace $script:Gui.Workspace -Version ([string]$script:Gui.Version))
        }

        [System.Windows.Forms.Clipboard]::SetText([string]$script:Gui.Preview.CommandLine)
        Write-WorkbenchGuiPane -Line ([string]$script:Gui.Preview.DisplayLine)
        Write-WorkbenchGuiPane -Line ([string]$script:Gui.Preview.CommandLine)
        Set-WorkbenchGuiStatus -Text 'The command is on the clipboard.'
    }
    catch {
        Show-WorkbenchGuiMessage -Message "The command could not be prepared: $($_.Exception.Message)" `
            -Icon 'Error'
    }
    finally {
        Set-WorkbenchGuiBusy -Busy $false
    }
}

function Invoke-WorkbenchGuiOpenFolderAction {
    <#
    .SYNOPSIS
        Opens the last run's folder, or the workspace, in Explorer.

    .DESCRIPTION
        After a run the folder worth opening is that run's: the driver, stdout.txt and
        stderr.txt are in it, and they are what a technician sends on when a step needs
        explaining. Before the first run of a session there is nothing better than the workspace
        itself.

    .EXAMPLE
        Invoke-WorkbenchGuiOpenFolderAction

        Opens the folder in Explorer.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui) { return }

    $folder = [string]$script:Gui.LastRunFolder
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
        $folder = [string]$script:Gui.WorkspacePath
    }
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
        Show-WorkbenchGuiMessage -Message 'There is no folder to open yet.' -Icon 'Warning'
        return
    }

    try {
        Start-Process -FilePath $folder -ErrorAction Stop
    }
    catch {
        Show-WorkbenchGuiMessage -Message ("That folder could not be opened: $($_.Exception.Message)" +
            "`r`n`r`n$folder") -Icon 'Warning'
    }
}

function Invoke-WorkbenchGuiCancelAction {
    <#
    .SYNOPSIS
        Asks the running step to stop.

    .DESCRIPTION
        The flag is all this sets. Invoke-MigrationStep reads it through the -CancelIf seam on
        its next poll and kills the child's whole process tree from there, which is the only
        place that knows what was started and how to record that it was stopped.

    .EXAMPLE
        Invoke-WorkbenchGuiCancelAction

        The Cancel button's handler.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ($null -eq $script:Gui -or -not $script:Gui.Running) { return }

    $script:Gui.CancelRequested = $true
    $script:Gui.CancelButton.Enabled = $false
    Write-WorkbenchGuiPane -Line '--- cancelling; waiting for the child to stop ---'
    Set-WorkbenchGuiStatus -Text 'Cancelling...'
}

function Invoke-WorkbenchGuiDryRunAction {
    <#
    .SYNOPSIS
        Rehearses the selected step.

    .EXAMPLE
        Invoke-WorkbenchGuiDryRunAction

        The Dry run button's handler.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Invoke-WorkbenchGuiStepAction -Live $false
}

function Invoke-WorkbenchGuiRunAction {
    <#
    .SYNOPSIS
        Runs the selected step for real.

    .EXAMPLE
        Invoke-WorkbenchGuiRunAction

        The Run button's handler.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Invoke-WorkbenchGuiStepAction -Live $true
}

function Invoke-WorkbenchGuiStepAction {
    <#
    .SYNOPSIS
        Resolves, gates, drives and runs the selected step, then redraws the board.

    .DESCRIPTION
        The window's one run path, and the only handler with any length to it - because the
        order of these five things is the whole safety story (Docs/Workbench-Design.md, sections
        7 and 9). None of them is decided here: the arguments come from
        Resolve-MigrationStepArguments, the gates from Test-MigrationStepGate, the command from
        New-MigrationStepDriver and the run from Invoke-MigrationStep.

          1. The arguments are resolved for the mode of the button that was pressed. Resolving
             once when the form was drawn and reading a flag afterwards is how a driver ends up
             rehearsing while the ledger records a live run, and how a live run of a destructive
             step gets through on a rehearsal's much shorter gate list.
          2. A parameter set still short of a mandatory value is a refusal, not a run.
          3. The gates. A live run must clear them all: a soft gate is a Yes/No the operator
             answers and the override is recorded in the ledger, a hard one is typed out in
             full in its own dialog. A rehearsal clears only the hard ones - a rehearsal exists
             to be run before the prerequisites are met.
          4. The secret, where the step signs in with one and no certificate is configured. The
             window reads it from the environment variable the unattended path uses and passes
             it to the child's environment block alone; it never reaches the driver file, the
             settings or the pane. There is deliberately no box to type it into: a window that
             collected a client secret would be one more place it could be shoulder-read or
             screenshot.
          5. The run, with the pane as its writer, DoEvents as its pump and the Cancel button as
             its cancel. Afterwards the workspace is scanned again and the tree redrawn, because
             every glyph on it has just potentially changed.

        The re-entrancy guard is the first thing checked: DoEvents keeps the window alive during
        a run, which also means it keeps the buttons capable of raising events, and a second run
        started on top of the first would share this function's state with it. Then the settings:
        a workspace whose settings did not load is refused before the resolver is called at all,
        the same refusal the console and the unattended path make (Test-MigrationWorkspaceRunnable).

    .PARAMETER Live
        $true to run the step for real, $false to rehearse it.

    .EXAMPLE
        Invoke-WorkbenchGuiStepAction -Live $false

        Rehearses the step the form is showing.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [bool]$Live
    )

    if ($null -eq $script:Gui) { return }
    if ($script:Gui.Running) { return }
    if ($null -eq $script:Gui.Workspace) {
        Show-WorkbenchGuiMessage -Message 'Open a workspace first.' -Icon 'Warning'
        return
    }
    if ($null -eq $script:Gui.Step) {
        Show-WorkbenchGuiMessage -Message 'Pick a step first.' -Icon 'Warning'
        return
    }

    # Before the resolver, before the gates, before a driver exists. A run resolved against
    # settings that did not load is handed no -TenantId, so the expected tenant is never set and
    # TenantVerified comes back $null; the prefix and the output folder fall back to Common; and
    # one Yes on a soft gate would start a live writer nobody can say which tenant it reached.
    $canRun = Test-MigrationWorkspaceRunnable -Workspace $script:Gui.Workspace
    if (-not $canRun.CanRun) {
        Show-WorkbenchGuiMessage -Message ([string]$canRun.Reason) -Title 'Settings' -Icon 'Warning'
        return
    }

    $step = $script:Gui.Step
    $workspace = $script:Gui.Workspace
    $mode = if ($Live) { 'run' } else { 'rehearsal' }

    $script:Gui.Running = $true
    $script:Gui.CancelRequested = $false
    try {
        Set-WorkbenchGuiBusy -Busy $true -Activity ('{0}: {1}' -f $mode, $step.Id)
        Write-WorkbenchGuiPane -Line ('--- {0} {1} ({2}) ---' -f $mode, $step.Id, (Get-Date -Format 's'))

        # --- 1. the arguments, for the mode the button is ---------------------------------
        # Read once. The resolver, the gates and Invoke-MigrationStep below are all handed this
        # same variable, never a second call to Get-WorkbenchGuiWave: the ledger records the
        # waves the runner was given, and a list read twice is a ledger that can disagree with
        # the driver about which wave ran. The step form draws no -Wave control of its own
        # (Test-WorkbenchGuiFormParameter), so an -Override cannot outrank it either.
        $wave = @(Get-WorkbenchGuiWave)
        $resolved = Resolve-MigrationStepArguments -Step $step -Workspace $workspace `
            -Override (Get-WorkbenchGuiOverride) -Wave $wave -DryRun:(-not $Live)

        foreach ($warning in @($resolved.Warnings)) { Write-WorkbenchGuiPane -Line "  ! $warning" }

        # --- 2. what the chosen parameter set still needs ---------------------------------
        $missing = @($resolved.MissingMandatory)
        if ($missing.Count -gt 0) {
            Show-WorkbenchGuiMessage -Message ("This step is still short of what it needs: " +
                ($missing -join ', ') + '. Fill those in on the form, or in Settings.') -Icon 'Warning'
            return
        }

        # --- 3. the gates -----------------------------------------------------------------
        $gates = @(Test-MigrationStepGate -Step $step -Arguments $resolved -Workspace $workspace -Live:$Live)
        foreach ($gate in $gates) {
            Write-WorkbenchGuiPane -Line ('  [{0}] {1}: {2}' -f
                $(if ($gate.Satisfied) { 'ok' } else { '!!' }), $gate.Kind, $gate.Message)
        }

        $gateOverrides = [System.Collections.Generic.List[string]]::new()

        # Soft gates first, so the typed confirmation is the last thing between the operator and
        # the run - which is where a deliberate act belongs. A rehearsal is not held to them.
        if ($Live) {
            foreach ($gate in @($gates | Where-Object { $_.Severity -eq 'Soft' -and -not $_.Satisfied })) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    ("$($gate.Message)`r`n`r`nOverride the $($gate.Kind) gate and run anyway? " +
                        'The override is recorded in the run ledger.'),
                    "$($gate.Kind) gate", 'YesNo', 'Warning')
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                    Write-WorkbenchGuiPane -Line '  The run was not started.'
                    return
                }
                # The extra parentheses matter: a method call splits its arguments on commas, so
                # without them the format operator would get only its first value.
                $gateOverrides.Add(('{0}:{1}' -f $gate.Kind, $gate.Message))
            }
        }

        foreach ($gate in @($gates | Where-Object { $_.Severity -eq 'Hard' -and -not $_.Satisfied })) {
            $required = [string]$gate.RequiredInput
            if (-not $required) {
                Show-WorkbenchGuiMessage -Message ("The $($gate.Kind) gate expects a typed confirmation " +
                    'but names no input, so it cannot be answered. The run was not started.') -Icon 'Error'
                return
            }
            if (-not (Show-WorkbenchGuiTypedConfirmation -Message ([string]$gate.Message) `
                        -RequiredInput $required)) {
                Write-WorkbenchGuiPane -Line '  The run was not started.'
                return
            }
        }

        # --- 4. the secret ----------------------------------------------------------------
        $environment = $null
        $secretMapping = @()
        if (@(@($step.Parameters) | Where-Object { $_.Name -eq 'ClientSecret' }).Count -gt 0) {
            $viva = Get-MigrationProperty -InputObject $workspace.Settings -Name 'VivaLearning' -Default $null
            $thumbprint = [string](Get-MigrationProperty -InputObject $viva -Name 'CertificateThumbprint' `
                    -Default '')
            if (-not $thumbprint) {
                $secret = [string][System.Environment]::GetEnvironmentVariable($script:WorkbenchSecretVariable)
                if (-not $secret) {
                    Show-WorkbenchGuiMessage -Message ("This step signs in with a client secret and the " +
                        "workspace settings hold no VivaLearning.CertificateThumbprint. Set " +
                        "`$env:$($script:WorkbenchSecretVariable) before starting the workbench, or " +
                        'configure a certificate. The run was not started.') -Icon 'Warning'
                    return
                }
                $environment = @{ $script:WorkbenchSecretVariable = $secret }
                $secretMapping = @("ClientSecret=$($script:WorkbenchSecretVariable)")
            }
        }

        # --- 5. the driver, the run, the board --------------------------------------------
        $driver = New-MigrationStepDriver -Step $step -Arguments $resolved -Workspace $workspace `
            -Version ([string]$script:Gui.Version) -SecretEnvironmentVariable $secretMapping
        Set-WorkbenchGuiPreview -Driver $driver
        Write-WorkbenchGuiPane -Line ([string]$driver.DisplayLine)
        Write-WorkbenchGuiPane -Line ([string]$driver.CommandLine)

        # The driver that is about to run stays in the preview slot, so what is on screen - and
        # what Copy command copies - is the command that ran, which is what Copy's own
        # description promises. Its folder is safe there: Set-WorkbenchGuiPreview only removes
        # the driver it replaces when that folder holds no stdout.txt, and Invoke-MigrationStep
        # writes stdout.txt the moment it starts the child.
        $script:Gui.LastRunFolder = [string]$driver.RunFolder

        # The one place Cancel is armed: from here there is a child to cancel, and the finally's
        # Set-WorkbenchGuiBusy turns it off again whatever happens.
        $script:Gui.CancelButton.Enabled = $true

        $runParameters = @{
            Step          = $step
            Driver        = $driver
            Workspace     = $workspace
            OutputWriter  = $script:PaneWriter
            Pump          = $script:UiPump
            CancelIf      = { $script:Gui.CancelRequested }
            Wave          = $wave
            GateOverrides = @($gateOverrides)
        }
        # Both passed explicitly, even when false or null: a runner that behaved differently for
        # an unbound switch than for -DryRun:$false would be a difference nothing can see.
        $runParameters['DryRun'] = (-not $Live)
        $runParameters['Environment'] = $environment

        if ([string]$step.Side -in @('Source', 'Destination')) {
            $side = Get-MigrationProperty -InputObject $workspace.Settings -Name ([string]$step.Side) `
                -Default $null
            $expected = [string](Get-MigrationProperty -InputObject $side -Name 'TenantId' -Default '')
            if ($expected) { $runParameters['ExpectedTenantId'] = $expected }
        }

        $result = Invoke-MigrationStep @runParameters

        # The secret's last reference in this process; the child has its own copy.
        $environment = $null

        Write-WorkbenchGuiPane -Line ('Exit {0}: {1}' -f $result.ExitCode, $result.Meaning)
        if ($null -ne (Get-MigrationRunContext)) {
            Write-MigrationLog -Level INFO -Message (
                "Step $($step.Id) finished with exit code $($result.ExitCode) ($($result.Meaning))")
        }

        Show-WorkbenchGuiResultSummary -Result $result -Step $step

        $script:Gui.Workspace = Get-MigrationWorkspace -Path ([string]$script:Gui.WorkspacePath)
        Update-WorkbenchGuiTree
    }
    catch {
        Write-WorkbenchGuiPane -Line "  ! This step could not be run: $($_.Exception.Message)"
        Show-WorkbenchGuiMessage -Message "This step could not be run:`r`n`r`n$($_.Exception.Message)" `
            -Icon 'Error'
    }
    finally {
        # Busy is released first and Running cleared after it. Set-WorkbenchGuiBusy re-enables
        # the buttons and then pumps the message queue, so a click queued during the run is
        # dispatched inside that DoEvents - and it has to meet the re-entrancy guard still
        # closed, or the window starts a second run out of the first one's finally block.
        Set-WorkbenchGuiBusy -Busy $false
        $script:Gui.Running = $false
        $script:Gui.CancelRequested = $false
        Set-WorkbenchGuiStatus -Text 'Ready'
    }
}

function Start-MigrationWorkbenchGui {
    <#
    .SYNOPSIS
        Builds and runs the WinForms workbench window, and returns the session's exit code.

    .DESCRIPTION
        The WinForms front end of Docs/Workbench-Design.md, section 9. It is the console
        workbench with a mouse: the same scanner, the same catalogue, the same argument
        resolver, the same gates, the same driver writer and the same runner. The window holds
        no rules of its own - it never works out a state, a gate, an argument or a command line
        - so the two front ends cannot come to disagree about when a run is allowed or what it
        would pass.

        The order of the first four things it does is the whole of its portability story, and
        none of them can be swapped:

          1. The platform check. WinForms does not exist off Windows, and loading the assembly
             to discover that would end the session on the machines the console mode is the
             whole point of. So Test-WorkbenchWindows is asked before any type is touched, and
             the refusal is a console message and exit 2.
          2. The apartment check. WinForms requires STA; pwsh 7 starts MTA on Windows unless it
             is told otherwise, and in MTA the common file dialogs and the clipboard misbehave
             and a handler exception can take the window down with no message at all. Rather
             than refuse, the script relaunches itself with -STA and hands back the child's exit
             code, so a technician who typed 'pwsh Start-MigrationWorkbench.ps1' still gets a
             window.
          3. Add-Type, which is therefore only ever reached on Windows in an STA thread.
          4. The DPI mode, inside a try: SetHighDpiMode exists from .NET Core 3.0 and throws on
             an older host, where a slightly blurry window is a far better outcome than none.

        Everything after that is layout and handlers, and every handler is a named function
        reading $script:Gui. Handlers fire long after this function's parameters were bound, and
        a function that reads a state bag is much easier to reason about - and to fix on a
        client's server - than a scriptblock relying on what happened to be in scope.

        The pane writer and the DoEvents pump are installed as $script:PaneWriter and
        $script:UiPump and handed to Invoke-MigrationStep as -OutputWriter and -Pump. That is
        what keeps the window painting through a run the engine polls on this thread, and what
        keeps the engine itself free of any reference to WinForms.

    .PARAMETER WorkspacePath
        The workspace to open, or empty to start with no workspace and let the operator browse.

    .PARAMETER LaunchArgument
        The arguments to pass to the relaunched process when this session is not STA. Empty
        means the relaunch carries only the workspace.

    .EXAMPLE
        Start-MigrationWorkbenchGui -WorkspacePath 'C:\Migration-Automations\Contoso'

        Opens the window on that migration folder and returns when it is closed.

    .EXAMPLE
        exit (Start-MigrationWorkbenchGui -WorkspacePath $path)

        How the Main region calls it: the window's exit code is the script's.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).

        Exit codes: 0 the window opened and was closed; 2 a refusal - not Windows. An STA
        relaunch returns whatever the child returned.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a window; every state change inside it is confirmed by the operator at a button.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkspacePath,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$LaunchArgument = @()
    )

    #region Refusal and relaunch

    if (-not (Test-WorkbenchWindows)) {
        Write-WorkbenchRefusal -Message (
            'The WinForms workbench runs on Windows only. Use -Console for the console workbench, ' +
            'which does everything the window does on any platform.')
        return 2
    }

    $apartment = [System.Threading.ApartmentState]::Unknown
    try { $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState() }
    catch {
        # A host that will not report an apartment state is treated as MTA, which costs one
        # relaunch and buys a window that is certainly in the apartment WinForms needs.
        Write-Verbose "The apartment state could not be read: $($_.Exception.Message)"
    }

    if ($apartment -ne [System.Threading.ApartmentState]::STA) {
        $executable = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $arguments = [System.Collections.Generic.List[string]]::new()
        foreach ($argument in @('-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)) {
            $arguments.Add($argument)
        }
        $carried = @($LaunchArgument)
        if ($carried.Count -eq 0 -and $WorkspacePath) { $carried = @('-Workspace', $WorkspacePath) }
        foreach ($argument in $carried) { $arguments.Add([string]$argument) }

        # Start-Process joins ArgumentList with spaces and quotes nothing, so anything that can
        # hold a space is quoted here - a workspace under 'C:\Program Files' otherwise arrives
        # as two arguments and binds to neither parameter.
        $quoted = @($arguments | ForEach-Object {
                if ([string]$_ -match '\s') { '"{0}"' -f $_ } else { [string]$_ }
            })

        Write-MigrationLog -Message 'Relaunching in a single-threaded apartment, which WinForms requires.' `
            -Level INFO
        $child = Start-Process -FilePath $executable -ArgumentList $quoted -PassThru -Wait -ErrorAction Stop
        return [int]$child.ExitCode
    }

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    # From .NET Core 3.0; an older host throws, and a slightly blurry window beats no window.
    try { $null = [System.Windows.Forms.Application]::SetHighDpiMode('PerMonitorV2') }
    catch { Write-Verbose "SetHighDpiMode is not available on this host: $($_.Exception.Message)" }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    #endregion Refusal and relaunch

    #region Form layout

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "M365 Migration Workbench $($script:Version)"
    $form.ClientSize = New-Object System.Drawing.Size(1280, 860)
    $form.MinimumSize = New-Object System.Drawing.Size(1024, 720)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.AutoScaleMode = 'Dpi'

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'
    $root.ColumnCount = 1
    $root.RowCount = 5
    $null = $root.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    foreach ($style in @(
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)),
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)),
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 62)),
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)),
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 38)))) {
        $null = $root.RowStyles.Add($style)
    }

    # --- row 0: the workspace strip ---------------------------------------------------------
    $topStrip = New-Object System.Windows.Forms.TableLayoutPanel
    $topStrip.Dock = 'Fill'
    $topStrip.AutoSize = $true
    $topStrip.ColumnCount = 3
    $topStrip.RowCount = 1
    $null = $topStrip.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $topStrip.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $topStrip.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

    $workspaceLabel = New-Object System.Windows.Forms.Label
    $workspaceLabel.Text = 'Migration folder:'
    $workspaceLabel.AutoSize = $true
    $workspaceLabel.Anchor = 'Left'
    $workspaceLabel.Margin = New-Object System.Windows.Forms.Padding(3, 8, 6, 3)

    $workspaceBox = New-Object System.Windows.Forms.TextBox
    $workspaceBox.Dock = 'Fill'
    $workspaceBox.ReadOnly = $true

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse...'
    $browseButton.Width = 110

    $topStrip.Controls.Add($workspaceLabel, 0, 0)
    $topStrip.Controls.Add($workspaceBox, 1, 0)
    $topStrip.Controls.Add($browseButton, 2, 0)

    # --- row 1: the tenant banner -----------------------------------------------------------
    $bannerLabel = New-Object System.Windows.Forms.Label
    $bannerLabel.Dock = 'Fill'
    $bannerLabel.Height = 30
    $bannerLabel.TextAlign = 'MiddleLeft'
    $bannerLabel.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $bannerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $bannerLabel.BackColor = [System.Drawing.Color]::FromArgb(224, 224, 224)
    $bannerLabel.Text = 'No step selected'

    # --- row 2: the runbook on the left, the step form on the right -------------------------
    $split = New-Object System.Windows.Forms.TableLayoutPanel
    $split.Dock = 'Fill'
    $split.ColumnCount = 2
    $split.RowCount = 1
    $null = $split.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 40)))
    $null = $split.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 60)))

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'

    $phasePage = New-Object System.Windows.Forms.TabPage
    $phasePage.Text = 'Phases'
    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = 'Fill'
    $tree.HideSelection = $false
    $tree.Font = New-Object System.Drawing.Font('Consolas', 9)
    $phasePage.Controls.Add($tree)

    $toolPage = New-Object System.Windows.Forms.TabPage
    $toolPage.Text = 'All tools'
    $toolList = New-Object System.Windows.Forms.ListView
    $toolList.Dock = 'Fill'
    $toolList.View = 'Details'
    $toolList.FullRowSelect = $true
    $toolList.MultiSelect = $false
    $null = $toolList.Columns.Add('Script', 260)
    $null = $toolList.Columns.Add('What it does', 520)
    $toolPage.Controls.Add($toolList)

    $tabs.TabPages.Add($phasePage)
    $tabs.TabPages.Add($toolPage)

    $rightPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $rightPanel.Dock = 'Fill'
    $rightPanel.ColumnCount = 1
    $rightPanel.RowCount = 4
    $null = $rightPanel.ColumnStyles.Add(
        (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    foreach ($style in @(
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)),
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)),
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)),
            (New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))) {
        $null = $rightPanel.RowStyles.Add($style)
    }

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Dock = 'Fill'
    $titleLabel.AutoSize = $true
    $titleLabel.Text = 'Pick a step on the left.'
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    $formPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $formPanel.Dock = 'Fill'
    $formPanel.AutoScroll = $true
    $formPanel.ColumnCount = 3
    $formPanel.GrowStyle = 'AddRows'
    foreach ($style in @(
            (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)),
            (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)),
            (New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))) {
        $null = $formPanel.ColumnStyles.Add($style)
    }

    $waveGroup = New-Object System.Windows.Forms.GroupBox
    $waveGroup.Text = 'Waves'
    $waveGroup.Dock = 'Fill'
    $waveGroup.Height = 110
    $waveList = New-Object System.Windows.Forms.CheckedListBox
    $waveList.Dock = 'Fill'
    $waveList.CheckOnClick = $true
    $waveList.IntegralHeight = $false
    $waveGroup.Controls.Add($waveList)

    $previewBox = New-Object System.Windows.Forms.TextBox
    $previewBox.Dock = 'Fill'
    $previewBox.Height = 70
    $previewBox.Multiline = $true
    $previewBox.ReadOnly = $true
    $previewBox.WordWrap = $false
    $previewBox.ScrollBars = 'Both'
    $previewBox.Font = New-Object System.Drawing.Font('Consolas', 9)

    $rightPanel.Controls.Add($titleLabel, 0, 0)
    $rightPanel.Controls.Add($formPanel, 0, 1)
    $rightPanel.Controls.Add($waveGroup, 0, 2)
    $rightPanel.Controls.Add($previewBox, 0, 3)

    $split.Controls.Add($tabs, 0, 0)
    $split.Controls.Add($rightPanel, 1, 0)

    # --- row 3: the buttons ------------------------------------------------------------------
    $buttonRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonRow.Dock = 'Fill'
    $buttonRow.AutoSize = $true
    $buttonRow.FlowDirection = 'LeftToRight'
    $buttonRow.WrapContents = $false

    $dryRunButton = New-Object System.Windows.Forms.Button
    $dryRunButton.Text = 'Dry run'
    $dryRunButton.Width = 130
    $dryRunButton.Height = 32

    $runButton = New-Object System.Windows.Forms.Button
    $runButton.Text = 'Run'
    $runButton.Width = 130
    $runButton.Height = 32

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Width = 130
    $cancelButton.Height = 32
    $cancelButton.Enabled = $false

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = 'Copy command'
    $copyButton.Width = 150
    $copyButton.Height = 32

    $openFolderButton = New-Object System.Windows.Forms.Button
    $openFolderButton.Text = 'Open folder'
    $openFolderButton.Width = 130
    $openFolderButton.Height = 32

    foreach ($button in @($dryRunButton, $runButton, $cancelButton, $copyButton, $openFolderButton)) {
        $buttonRow.Controls.Add($button)
    }

    # --- row 4: the log pane -----------------------------------------------------------------
    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Dock = 'Fill'
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = 'Both'
    $logBox.WordWrap = $false
    $logBox.BackColor = [System.Drawing.Color]::White
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)

    $root.Controls.Add($topStrip, 0, 0)
    $root.Controls.Add($bannerLabel, 0, 1)
    $root.Controls.Add($split, 0, 2)
    $root.Controls.Add($buttonRow, 0, 3)
    $root.Controls.Add($logBox, 0, 4)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusItem.Text = 'Starting...'
    $null = $statusStrip.Items.Add($statusItem)

    $menu = New-Object System.Windows.Forms.MenuStrip
    $fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem('&File')
    $openItem = New-Object System.Windows.Forms.ToolStripMenuItem('&Open workspace...')
    $refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem('&Refresh')
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('E&xit')
    $null = $fileMenu.DropDownItems.Add($openItem)
    $null = $fileMenu.DropDownItems.Add($refreshItem)
    $null = $fileMenu.DropDownItems.Add($exitItem)
    $settingsMenu = New-Object System.Windows.Forms.ToolStripMenuItem('&Settings...')
    $resultsMenu = New-Object System.Windows.Forms.ToolStripMenuItem('Results && &logs')
    $null = $menu.Items.Add($fileMenu)
    $null = $menu.Items.Add($settingsMenu)
    $null = $menu.Items.Add($resultsMenu)

    # Docking is applied in reverse order of the Controls collection, so the menu and the status
    # strip have to be added after the panel that fills what is left of the window.
    $form.Controls.Add($root)
    $form.Controls.Add($statusStrip)
    $form.Controls.Add($menu)
    $form.MainMenuStrip = $menu

    $script:Gui = @{
        Form            = $form
        Menu            = $menu
        WorkspaceBox    = $workspaceBox
        BannerLabel     = $bannerLabel
        TitleLabel      = $titleLabel
        Tabs            = $tabs
        Tree            = $tree
        ToolList        = $toolList
        FormPanel       = $formPanel
        WaveList        = $waveList
        PreviewBox      = $previewBox
        LogBox          = $logBox
        StatusItem      = $statusItem
        CancelButton    = $cancelButton
        ToolTip         = (New-Object System.Windows.Forms.ToolTip)
        Buttons         = @($browseButton, $dryRunButton, $runButton, $copyButton, $openFolderButton)
        Rows            = [System.Collections.Generic.List[object]]::new()
        Workspace       = $null
        WorkspacePath   = ''
        Step            = $null
        Preview         = $null
        Running         = $false
        CancelRequested = $false
        Suppress        = $false
        PaneLines       = 0
        LastRunFolder   = ''
        Confirmation    = $null
        SettingsForm    = $null
        Version         = [string]$script:Version
    }

    # The two seams Invoke-MigrationStep is handed. They live here rather than inside the runner
    # because the engine must hold no reference to WinForms at all - that is what lets every
    # engine function be tested, and every offline step be run, on macOS.
    $script:PaneWriter = { param($Line) Write-WorkbenchGuiPane -Line $Line }
    $script:UiPump = { [System.Windows.Forms.Application]::DoEvents() }

    #endregion Form layout

    #region Event handlers

    $browseButton.Add_Click({ Invoke-WorkbenchGuiBrowseAction })
    $openItem.Add_Click({ Invoke-WorkbenchGuiBrowseAction })
    $refreshItem.Add_Click({ Invoke-WorkbenchGuiRefreshAction })
    $exitItem.Add_Click({ $script:Gui.Form.Close() })
    $settingsMenu.Add_Click({ Invoke-WorkbenchGuiSettingsAction })
    $resultsMenu.Add_Click({ Invoke-WorkbenchGuiResultsAction })

    $tree.Add_AfterSelect({ Invoke-WorkbenchGuiTreeSelectAction -Node $args[1].Node })
    $toolList.Add_SelectedIndexChanged({ Invoke-WorkbenchGuiToolSelectAction })

    $dryRunButton.Add_Click({ Invoke-WorkbenchGuiDryRunAction })
    $runButton.Add_Click({ Invoke-WorkbenchGuiRunAction })
    $cancelButton.Add_Click({ Invoke-WorkbenchGuiCancelAction })
    $copyButton.Add_Click({ Invoke-WorkbenchGuiCopyAction })
    $openFolderButton.Add_Click({ Invoke-WorkbenchGuiOpenFolderAction })

    $form.Add_FormClosing({ Invoke-WorkbenchGuiClosingAction -CancelEventArgs $args[1] })
    $form.Add_FormClosed({
            # A driver written for a preview and never run is not evidence of anything, and
            # leaving it behind would put a run folder in the workspace for a run that never
            # happened.
            Set-WorkbenchGuiPreview -Driver $null
            $script:PaneWriter = $null
            $script:UiPump = $null
        })

    #endregion Event handlers

    #region Initial population

    Write-WorkbenchGuiPane -Line "M365 Migration Workbench $($script:Version) - the window over the same engine."

    foreach ($name in @(@(Get-MigrationStep) | ForEach-Object { [string]$_.Script } | Sort-Object -Unique)) {
        $entry = Get-MigrationStep -Script $name
        $item = New-Object System.Windows.Forms.ListViewItem(
            [System.IO.Path]::GetFileName([string]$entry.ScriptPath))
        $null = $item.SubItems.Add(
            [string](Get-MigrationScriptSynopsisText -Path ([string]$entry.ScriptPath)))
        $item.Tag = $name
        $null = $toolList.Items.Add($item)
    }
    $toolList.SelectedItems.Clear()

    if ($WorkspacePath) {
        Invoke-WorkbenchGuiOpenWorkspaceAction -Path $WorkspacePath
    }
    else {
        Set-WorkbenchGuiStatus -Text 'Pick a migration folder: File > Open workspace, or Browse.'
        Write-WorkbenchGuiPane -Line 'No workspace yet. Press Browse to pick the migration folder.'
    }

    #endregion Initial population

    [void]$form.ShowDialog()
    $form.Dispose()
    $script:Gui = $null
    return 0
}

function Invoke-WorkbenchGuiClosingAction {
    <#
    .SYNOPSIS
        Refuses to close the window while a step is still running.

    .DESCRIPTION
        The run is polled on this thread, so closing the form under it would leave a child
        process nobody is watching and a ledger line nobody writes. Cancel is the way out of a
        run, and it is the button this points at.

    .PARAMETER CancelEventArgs
        The FormClosing event's arguments; its Cancel member is what stops the close.

    .EXAMPLE
        Invoke-WorkbenchGuiClosingAction -CancelEventArgs $e

        The form's FormClosing handler.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $CancelEventArgs
    )

    if ($null -eq $script:Gui -or -not $script:Gui.Running) { return }

    $CancelEventArgs.Cancel = $true
    Show-WorkbenchGuiMessage -Message ('A step is still running. Press Cancel to stop it, and close the ' +
        'window once it has.') -Icon 'Warning'
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

        # Every refusal that can be read off the arguments alone is made here, before there is a
        # run context - and therefore before any folder exists. Initialize-MigrationRun creates
        # its -OutputPath whether or not a line is ever written there, so a refusal raised after
        # it leaves a folder behind under the operator's default output root as the price of
        # telling them they mistyped a path or a step id. There is no log to write these to yet,
        # which is why they go to the error stream and to the host and nowhere else.
        $refusal = [string]$resolution.Problem
        if (-not $refusal -and $mode -eq 'NonInteractive') {
            $refusal = Get-WorkbenchStepProblem -StepId $Step
        }
        if ($refusal) {
            Write-WorkbenchRefusal -Message $refusal
            exit 2
        }

        # The workbench's own log belongs beside the ledger it is about to append to. With no
        # workspace known - a console session that has not picked one yet - the default output
        # root is the only place left that is certainly writable, and the log goes in a Workbench
        # subfolder of it rather than in the root: the root is where an operator's migration
        # folders live, and a front end that drops loose log files among them makes its own
        # folder list harder to read every time it writes one.
        #
        # A caller who named -LogPath gets that file's own folder as the output path. The log
        # path alone would not do it: Initialize-MigrationRun creates -OutputPath either way, so
        # redirecting the log without this would still leave a folder under the default root -
        # which is exactly what a test run, or a run against a workspace that is not there, must
        # not do.
        $logRoot = if ($LogPath) {
            [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath(
                    [System.IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $LogPath)))
        }
        else {
            Join-Path -ChildPath 'Workbench' -Path $(
                if ($workspacePath) { $workspacePath } else { Get-MigrationDefaultOutputRoot })
        }

        $null = Initialize-MigrationRun -ScriptName 'Start-MigrationWorkbench' -OutputPath $logRoot `
            -Prefix '' -LogPath $LogPath -Verbosity $Verbosity -BoundParameters $PSBoundParameters

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

                # What an STA relaunch has to carry. Rebuilt from what was bound rather than
                # read back off the command line, because a re-quoted command line is a second
                # parser and the one thing a relaunch must not do is start a different session
                # than the one the operator asked for. -Step never appears: a named step is
                # NonInteractive and never reaches this branch at all.
                $guiArguments = [System.Collections.Generic.List[string]]::new()
                if ($workspacePath) {
                    $guiArguments.Add('-Workspace')
                    $guiArguments.Add($workspacePath)
                }
                foreach ($name in @('Verbosity', 'LogPath')) {
                    if (-not $PSBoundParameters.ContainsKey($name)) { continue }
                    $guiArguments.Add("-$name")
                    $guiArguments.Add([string]$PSBoundParameters[$name])
                }

                $exitCode = Start-MigrationWorkbenchGui -WorkspacePath $workspacePath `
                    -LaunchArgument $guiArguments.ToArray()
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
