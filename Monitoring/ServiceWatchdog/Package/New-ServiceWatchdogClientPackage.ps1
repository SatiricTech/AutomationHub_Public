#Requires -Version 5.1

<#
.SYNOPSIS
    Builds a filled-in, drop-and-deploy ServiceWatchdog package for one client or tenant.

.DESCRIPTION
    Runs on an operator workstation (PowerShell 7 on Windows, macOS or Linux, or Windows
    PowerShell 5.1) and assembles the folder a technician copies onto a server:

        <OutputPath>\ServiceWatchdog\
            Run-ServiceWatchdog.cmd                 double-click entry point
            Install-WinServiceWatchdogGui.ps1       the WinForms front end
            ServiceWatchdog.settings.json           filled in from the parameters below
            PACKAGE-VERSION.txt                     what this package was built from
            Endpoint\                               pinned copy of the endpoint scripts
                Invoke-WinServiceWatchdog.ps1
                Register-WinServiceWatchdogTask.ps1
                Unregister-WinServiceWatchdogTask.ps1
                ServiceWatchdog.example.json
                VERSION.txt                         what the pinned copy was taken from

    Nothing on the built package needs GitHub access, a PowerShell gallery module or a
    hand-edited JSON file: the technician copies the folder, double-clicks the launcher,
    ticks services and presses Install & test.

    Both version stamps carry the repository's git short SHA when git is available and the
    build runs inside a working tree, so a package found on a server two years later can be
    traced back to the commit it was cut from. When git cannot answer (an exported archive,
    no git on PATH) the stamp records the build date instead and says so.

    The finished folder holds a live function key in ServiceWatchdog.settings.json. That is
    the whole point of the package, and it is also why the builder refuses to write into a
    git working tree unless -Force is passed: building into a clone is the easiest way to
    commit a secret by accident. The hand-over summary names the files and the key's length,
    never the key.

.PARAMETER ClientName
    The client or tenant name shown in the GUI's window title. 1 to 64 characters, and it
    may not contain the literal REPLACE, which the GUI rejects as an unedited placeholder.

.PARAMETER FunctionUrl
    The alert endpoint. Either the full URL, which must be https and end with
    /api/servicewatchdog/alert, or just the Function App host name (with or without an
    https:// prefix), in which case the path is appended for you.

.PARAMETER FunctionKey
    The function key as a SecureString, which is the way to pass it: pipe it in from
    Read-Host -AsSecureString or a SecretManagement vault and it never appears in the shell
    history, the console or a transcript. It is converted to plain text only at the moment
    the settings file is written, because that file is what the worker reads.

.PARAMETER FunctionKeyPlainText
    The function key as ordinary text, for a scripted build where a SecureString is
    impractical (a CI job reading a pipeline variable, for instance). The trade-off is
    real: the value lands in the shell history, in any transcript, and in the process
    arguments other users on the box can read. Prefer -FunctionKey everywhere else.

.PARAMETER OutputPath
    Folder to build into. A ServiceWatchdog subfolder is created inside it; that subfolder
    is what gets copied to the server. Created if it does not exist.

.PARAMETER DefaultsPath
    Optional JSON file whose contents replace the Defaults block of the settings file, for a
    client that needs different retry, alerting or logging behaviour. The file may be either
    the Defaults object itself or a whole settings file with a Defaults property. Values it
    omits fall back to the shipped defaults, and the result is checked against the scheduled
    task's execution time limit before anything is written.

.PARAMETER Force
    Overwrite an existing <OutputPath>\ServiceWatchdog folder, and allow the build to write
    into a git working tree. Both refusals exist to stop a function key reaching source
    control, so pass this only when the output really is outside anything you commit.

.PARAMETER Verbosity
    Console output level for the builder's own messages. Low shows errors and the summary,
    Medium adds warnings, High shows every step.

.PARAMETER DryRun
    Validate everything, resolve every path and report what would be written, but create no
    folder and write no file. The summary is printed as usual so the plan can be reviewed.

.EXAMPLE
    $key = Read-Host -Prompt 'Function key' -AsSecureString
    ./New-ServiceWatchdogClientPackage.ps1 -ClientName 'Example Org' `
        -FunctionUrl 'https://func-svcwatchdog-a1b2c3.azurewebsites.net/api/servicewatchdog/alert' `
        -FunctionKey $key -OutputPath ~/Handover

    The normal build: the key is prompted for, never typed on the command line, and the
    package appears at ~/Handover/ServiceWatchdog.

.EXAMPLE
    ./New-ServiceWatchdogClientPackage.ps1 -ClientName 'Example Org' `
        -FunctionUrl 'func-svcwatchdog-a1b2c3.azurewebsites.net' `
        -FunctionKey $key -OutputPath /tmp/build -DryRun -Verbosity High

    A rehearsal from a bare host name: the URL is completed, every file is listed, nothing is
    written.

.EXAMPLE
    ./New-ServiceWatchdogClientPackage.ps1 -ClientName 'Example Org' `
        -FunctionUrl 'https://func-x.azurewebsites.net/api/servicewatchdog/alert' `
        -FunctionKeyPlainText $env:WATCHDOG_KEY -OutputPath ./out `
        -DefaultsPath ./tuned-defaults.json -Force

    An unattended build with retuned defaults, overwriting a previous package. -Force is also
    what allows the output folder to sit inside a git working tree; keep it git-ignored.

.NOTES
    Version:    1.0.0
    Created:    2026-09-17
    Platform:   PowerShell 7 on Windows, macOS or Linux, or Windows PowerShell 5.1. The
                package it builds runs only on Windows; the builder itself touches nothing
                Windows-specific.
    Exit codes: 0 the package was built (or would be, under -DryRun); 1 unexpected error;
                2 a refusal (bad URL, empty key, missing source file, unusable Defaults,
                existing output folder or a git working tree without -Force).

    Checklist deviations from the powershell-authoring skill (Enterprise tier):
      - 3.1: targets Windows PowerShell 5.1 as well as 7.4, so an operator on a Windows
        server with no pwsh can still cut a package. Nothing here needs 7.x syntax.
      - 4.6: no log file. The builder's only artefact is the package, and a log written
        beside a folder that holds a function key is one more file to forget about; every
        message goes to the console instead.
      - 5.2: no SecretManagement vault of its own. -FunctionKey accepts a SecureString, which
        is what a vault hands you, and the key is written only into the settings file the
        worker reads.

    Developed with AI assistance (Claude); reviewed before publication.
#>

[CmdletBinding(DefaultParameterSetName = 'SecureKey', SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 64)]
    [string]$ClientName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionUrl,

    [Parameter(Mandatory, ParameterSetName = 'SecureKey')]
    [ValidateNotNull()]
    [System.Security.SecureString]$FunctionKey,

    [Parameter(Mandatory, ParameterSetName = 'PlainKey')]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionKeyPlainText,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [string]$DefaultsPath,

    [switch]$Force,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium',

    [switch]$DryRun
)

#region Configuration & Constants

$ErrorActionPreference = 'Stop'

$script:PackageFolderName = 'ServiceWatchdog'
$script:SettingsFileName = 'ServiceWatchdog.settings.json'
$script:ExampleFileName = 'ServiceWatchdog.settings.example.json'
$script:LauncherFileName = 'Run-ServiceWatchdog.cmd'
$script:GuiFileName = 'Install-WinServiceWatchdogGui.ps1'
$script:AlertPath = '/api/servicewatchdog/alert'

# The files copied verbatim out of ..\Endpoint. Every one is required: the GUI drives the three
# scripts, and the example config is what the registrar seeds a hand-built install from.
$script:EndpointFileName = @(
    'Invoke-WinServiceWatchdog.ps1'
    'Register-WinServiceWatchdogTask.ps1'
    'Unregister-WinServiceWatchdogTask.ps1'
    'ServiceWatchdog.example.json'
)

# The registrar's -ExecutionTimeLimitSeconds default, which the GUI never overrides. A Defaults
# block that cannot finish inside it is refused here rather than at the server.
$script:ExecutionTimeLimitSeconds = 420

$script:LogVerbosity = $Verbosity
$script:DryRunMode = $DryRun.IsPresent

#endregion

#region Helper Functions

function Write-Log {
    <#
    .SYNOPSIS
        Writes one timestamped line to the console at the requested level.
    .DESCRIPTION
        Console only, by design (see .NOTES): the builder writes a folder holding a function
        key, and a log file beside it would be one more copy of that context to lose track of.
        Write-Verbose and Write-Warning are used rather than Write-Host so the output can be
        captured or suppressed by the caller.
    .PARAMETER Message
        The message.
    .PARAMETER Level
        INFO, WARNING, ERROR, DEBUG or SUCCESS.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Write-Log is this project''s logging convention and is defined the same way by the endpoint scripts. The cmdlet the rule protects ships only with the Windows PowerShell 5.1 AppBackgroundTask module, which nothing here loads.')]
    [CmdletBinding()]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Verbose $line -Verbose:$true }
        'SUCCESS' { Write-Verbose $line -Verbose:$true }
        'WARNING' {
            if ($script:LogVerbosity -in @('Medium', 'High')) { Write-Warning $Message }
        }
        default {
            if ($script:LogVerbosity -eq 'High') { Write-Verbose $line -Verbose:$true }
        }
    }
}

function ConvertTo-PackageHashtable {
    <#
    .SYNOPSIS
        Converts ConvertFrom-Json output into nested hashtables.
    .DESCRIPTION
        Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, and the merge below is far
        easier to reason about over hashtables than over PSCustomObjects.
    .PARAMETER InputObject
        The object to convert.
    #>
    [CmdletBinding()]
    [OutputType([object], [hashtable])]
    param (
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-PackageHashtable -InputObject $property.Value
        }
        return $table
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) {
            $table[[string]$key] = ConvertTo-PackageHashtable -InputObject $InputObject[$key]
        }
        return $table
    }
    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $InputObject) { $items += , (ConvertTo-PackageHashtable -InputObject $item) }
        return $items
    }
    return $InputObject
}

function Resolve-PackageAlertUrl {
    <#
    .SYNOPSIS
        Normalises the -FunctionUrl value into the full https alert URL, or throws.
    .DESCRIPTION
        Three inputs are accepted, because all three are what an operator has to hand: the
        full URL printed by the Azure install script, the same URL without its path, and the
        bare Function App host name. Anything else is a refusal rather than a guess - a
        mistyped path would produce a package that installs cleanly and then never alerts,
        which is the one failure mode worth being strict about.

        A query string is rejected too: the function key belongs in the settings file's
        FunctionKey field, which the worker sends as the x-functions-key header, not in a
        ?code= parameter that would end up in every proxy log on the way out.
    .PARAMETER Url
        The -FunctionUrl value.
    .OUTPUTS
        System.String - the full https alert URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Url
    )

    $value = $Url.Trim().TrimEnd('/')
    if ($value -match '^(?i)http://') {
        throw "FunctionUrl must be https, not http: '$Url'."
    }
    if (-not ($value -match '^(?i)https://')) {
        # A bare host name. Anything with a slash in it is a path fragment, not a host.
        if ($value -match '[/\s?]') {
            throw ("FunctionUrl '$Url' is neither an https:// URL nor a bare host name. Pass " +
                "either https://<host>$script:AlertPath or just <host>.")
        }
        $value = 'https://' + $value
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "FunctionUrl '$Url' is not a valid URL."
    }
    if ($uri.Scheme -ne 'https') {
        throw "FunctionUrl must be https, not $($uri.Scheme): '$Url'."
    }
    if ($uri.Query) {
        throw ("FunctionUrl must not carry a query string: the function key goes in -FunctionKey, " +
            'which the worker sends as the x-functions-key header.')
    }

    $path = $uri.AbsolutePath.TrimEnd('/')
    if ([string]::IsNullOrEmpty($path) -or $path -eq '/') {
        return ('https://{0}{1}' -f $uri.Authority, $script:AlertPath)
    }
    if ($path -ne $script:AlertPath) {
        throw ("FunctionUrl path is '$path'; it must be '$script:AlertPath'. Pass the alert URL the " +
            'Azure install script printed, or just the Function App host name.')
    }
    return ('https://{0}{1}' -f $uri.Authority, $script:AlertPath)
}

function Get-PackageKeyPlainText {
    <#
    .SYNOPSIS
        Returns the function key as plain text from whichever parameter supplied it.
    .DESCRIPTION
        NetworkCredential is used for the SecureString case because it is the one conversion
        that behaves identically on Windows PowerShell 5.1 and on .NET Core, Windows, macOS and
        Linux alike. The value is returned, never logged.
    .PARAMETER SecureKey
        The -FunctionKey value, or $null.
    .PARAMETER PlainKey
        The -FunctionKeyPlainText value, or an empty string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [AllowNull()]
        [System.Security.SecureString]$SecureKey,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$PlainKey
    )

    $value = $PlainKey
    if ($null -ne $SecureKey) {
        $value = (New-Object System.Net.NetworkCredential('', $SecureKey)).Password
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'The function key is empty.'
    }
    if ($value -cmatch 'REPLACE') {
        throw 'The function key still contains REPLACE; pass the real key from the Azure deployment.'
    }
    return $value
}

function Get-PackageWorstCaseRunSeconds {
    <#
    .SYNOPSIS
        Computes the worst-case worker run time for a Defaults block and a webhook timeout.
    .DESCRIPTION
        Mirrors step 3 of Register-WinServiceWatchdogTask.ps1 and the GUI's own guard:
        MaxRunSeconds + 2 * (2 * TimeoutSeconds + 5) + 15. Checking it here means a bad
        -DefaultsPath is caught on the workstation rather than by a child process on a client
        server after the config has already been written.
    .PARAMETER Defaults
        The resolved Defaults hashtable.
    .PARAMETER TimeoutSeconds
        Webhook.TimeoutSeconds.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun is the settings file''s Defaults block, which is plural by name.')]
    [CmdletBinding()]
    [OutputType([int])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Defaults,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $maxRun = [int]$Defaults['MaxRunSeconds']
    return ($maxRun + 2 * (2 * $TimeoutSeconds + 5) + 15)
}

function Merge-PackageDefaults {
    <#
    .SYNOPSIS
        Merges an override file over the shipped Defaults block.
    .DESCRIPTION
        The override may be the Defaults object itself or a whole settings file with a Defaults
        property, because both are things an operator will reasonably hand to -DefaultsPath. The
        merge is one level deep into Alerting and Logging, which is exactly as deep as the
        schema goes, and an unknown key is a refusal rather than a silent no-op: a typo in a
        tuning file should not leave the shipped value quietly in place.
    .PARAMETER Base
        The shipped Defaults block.
    .PARAMETER Override
        The parsed override, or $null.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun is the settings file''s Defaults block, which is plural by name.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Base,

        [AllowNull()]
        [object]$Override
    )

    $merged = @{}
    foreach ($key in $Base.Keys) {
        if ($Base[$key] -is [System.Collections.IDictionary]) {
            $nested = @{}
            foreach ($inner in $Base[$key].Keys) { $nested[$inner] = $Base[$key][$inner] }
            $merged[$key] = $nested
        }
        else {
            $merged[$key] = $Base[$key]
        }
    }
    if ($null -eq $Override) { return $merged }
    if ($Override -isnot [System.Collections.IDictionary]) {
        throw 'The DefaultsPath file must contain a JSON object.'
    }

    $source = $Override
    if ($Override.Contains('Defaults') -and $Override['Defaults'] -is [System.Collections.IDictionary]) {
        $source = $Override['Defaults']
    }

    foreach ($key in $source.Keys) {
        if (-not $merged.Contains($key)) {
            throw ("The DefaultsPath file has an unknown key '$key'. Valid keys: " +
                ((@($Base.Keys) | Sort-Object) -join ', ') + '.')
        }
        if ($merged[$key] -is [System.Collections.IDictionary]) {
            if ($source[$key] -isnot [System.Collections.IDictionary]) {
                throw "The DefaultsPath file's '$key' must be a JSON object."
            }
            foreach ($inner in $source[$key].Keys) {
                if (-not $merged[$key].Contains($inner)) {
                    throw ("The DefaultsPath file has an unknown key '$key.$inner'. Valid keys: " +
                        ((@($merged[$key].Keys) | Sort-Object) -join ', ') + '.')
                }
                $merged[$key][$inner] = $source[$key][$inner]
            }
        }
        else {
            $merged[$key] = $source[$key]
        }
    }
    return $merged
}

function New-PackageSettingsContent {
    <#
    .SYNOPSIS
        Builds the ServiceWatchdog.settings.json content the GUI reads.
    .DESCRIPTION
        An ordered dictionary, so the file a technician may end up opening reads in the same
        order as the example, and so Test-WatchdogGuiSettings in the GUI sees exactly the shape
        it validates.
    .PARAMETER ClientName
        The client name for the window title.
    .PARAMETER AlertUrl
        The resolved https alert URL.
    .PARAMETER KeyPlainText
        The function key.
    .PARAMETER TimeoutSeconds
        Webhook.TimeoutSeconds.
    .PARAMETER Defaults
        The merged Defaults block.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object only; nothing on the system changes, so -WhatIf would mislead.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$AlertUrl,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$KeyPlainText,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Defaults
    )

    $alerting = [ordered]@{}
    foreach ($key in @('ReminderMinutes', 'NotifyOnRemediation', 'RemediationCooldownMinutes',
            'HeartbeatHours')) {
        $alerting[$key] = $Defaults['Alerting'][$key]
    }
    $logging = [ordered]@{}
    foreach ($key in @('LogRoot', 'LogRetentionDays', 'EventLogHealthyRuns')) {
        $logging[$key] = $Defaults['Logging'][$key]
    }

    $defaultsBlock = [ordered]@{
        MaxStartAttempts        = [int]$Defaults['MaxStartAttempts']
        RetryDelaySeconds       = [int]$Defaults['RetryDelaySeconds']
        PostStartVerifySeconds  = [int]$Defaults['PostStartVerifySeconds']
        StartPendingWaitSeconds = [int]$Defaults['StartPendingWaitSeconds']
        MaxRunSeconds           = [int]$Defaults['MaxRunSeconds']
        Alerting                = $alerting
        Logging                 = $logging
    }

    return [ordered]@{
        SchemaVersion = 1
        ClientName    = $ClientName.Trim()
        Webhook       = [ordered]@{
            Url            = $AlertUrl
            FunctionKey    = $KeyPlainText
            TimeoutSeconds = $TimeoutSeconds
        }
        Defaults      = $defaultsBlock
    }
}

function Get-PackageSourceVersion {
    <#
    .SYNOPSIS
        Describes what this package was built from: a git short SHA, or the build date.
    .DESCRIPTION
        git is asked directly rather than through a module so the builder has no dependencies,
        and every failure path (git absent, not a working tree, a detached or empty repository)
        falls through to the date stamp. A package with no SHA is still traceable to a day; a
        package that failed to build because git was missing would be useless.
    .PARAMETER Path
        A folder inside the repository.
    .OUTPUTS
        PSCustomObject with Sha (possibly empty), Source ('git' or 'date') and Text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $sha = ''
    try {
        if (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue) {
            $output = & git -C $Path rev-parse --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($output)) {
                $sha = ([string]$output).Trim()
            }
        }
    }
    catch {
        $sha = ''
    }

    if ($sha) {
        return [pscustomobject]@{
            Sha    = $sha
            Source = 'git'
            Text   = $sha
        }
    }
    return [pscustomobject]@{
        Sha    = ''
        Source = 'date'
        Text   = ('no-git-' + (Get-Date -Format 'yyyyMMdd'))
    }
}

function Test-PackageInsideGitTree {
    <#
    .SYNOPSIS
        Returns $true when a path lies inside a git working tree.
    .DESCRIPTION
        Walked by hand rather than shelled out to git, so the check works with no git on PATH
        and on a folder that does not exist yet (the nearest existing ancestor is what matters).
        A .git file is treated the same as a .git folder: that is what a worktree or a submodule
        looks like, and a secret committed from one is just as public.
    .PARAMETER Path
        The path to test.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $current = $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) { return $true }
        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

function Write-PackageTextFile {
    <#
    .SYNOPSIS
        Writes a text file as UTF-8 without a BOM, honouring -DryRun.
    .DESCRIPTION
        No BOM because these files are read by Windows PowerShell 5.1, by the worker under
        SYSTEM and by whoever opens them in Notepad, and a BOM helps none of them.
    .PARAMETER Path
        The file to write.
    .PARAMETER Content
        The text.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    if ($script:DryRunMode) {
        Write-Log "[DRYRUN] Would write $Path" -Level 'WARNING'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write file')) { return }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
    Write-Log "Wrote $Path"
}

function Copy-PackageFile {
    <#
    .SYNOPSIS
        Copies one source file into the package, honouring -DryRun.
    .PARAMETER Path
        The source file.
    .PARAMETER Destination
        The destination file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Source file not found: $Path"
    }
    if ($script:DryRunMode) {
        Write-Log "[DRYRUN] Would copy $Path to $Destination" -Level 'WARNING'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Destination, 'Copy file')) { return }
    Copy-Item -LiteralPath $Path -Destination $Destination -Force
    Write-Log "Copied $(Split-Path -Path $Path -Leaf) to $Destination"
}

function New-PackageFolder {
    <#
    .SYNOPSIS
        Creates a folder unless -DryRun is in force.
    .PARAMETER Path
        The folder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Container) { return }
    if ($script:DryRunMode) {
        Write-Log "[DRYRUN] Would create $Path" -Level 'WARNING'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create folder')) { return }
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
}

#endregion

#region Main

$exitCode = 1
try {
    Write-Log "=== New-ServiceWatchdogClientPackage 1.0.0 starting ===" -Level 'INFO'
    if ($script:DryRunMode) {
        Write-Log '[DRYRUN] Nothing will be created or written.' -Level 'WARNING'
    }

    #region Validate the inputs

    if ($ClientName -cmatch 'REPLACE') {
        throw 'ClientName still contains REPLACE; pass the real client name.'
    }

    $alertUrl = Resolve-PackageAlertUrl -Url $FunctionUrl
    Write-Log "Alert URL: $alertUrl"

    $keyPlainText = Get-PackageKeyPlainText -SecureKey $FunctionKey -PlainKey $FunctionKeyPlainText
    if ($PSCmdlet.ParameterSetName -eq 'PlainKey') {
        Write-Log ('The key was passed as plain text, so it is in this shell history and any ' +
            'transcript. Prefer -FunctionKey with a SecureString.') -Level 'WARNING'
    }

    $sourceRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($sourceRoot)) { $sourceRoot = (Get-Location).Path }
    $endpointSource = Join-Path (Split-Path -Path $sourceRoot -Parent) 'Endpoint'
    $examplePath = Join-Path $sourceRoot $script:ExampleFileName

    foreach ($required in @((Join-Path $sourceRoot $script:GuiFileName),
            (Join-Path $sourceRoot $script:LauncherFileName), $examplePath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw ("Source file not found: $required. Run this script from the repository's " +
                'Monitoring/ServiceWatchdog/Package folder.')
        }
    }
    foreach ($name in $script:EndpointFileName) {
        $candidate = Join-Path $endpointSource $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Endpoint source file not found: $candidate"
        }
    }

    # The shipped example is the single source of truth for both the Defaults block and the
    # webhook timeout, so a change there needs no matching edit here.
    $exampleSettings = ConvertTo-PackageHashtable -InputObject (
        ConvertFrom-Json -InputObject (Get-Content -LiteralPath $examplePath -Raw))
    $timeoutSeconds = [int]$exampleSettings['Webhook']['TimeoutSeconds']

    $override = $null
    if (-not [string]::IsNullOrWhiteSpace($DefaultsPath)) {
        if (-not (Test-Path -LiteralPath $DefaultsPath -PathType Leaf)) {
            throw "DefaultsPath file not found: $DefaultsPath"
        }
        try {
            $override = ConvertTo-PackageHashtable -InputObject (
                ConvertFrom-Json -InputObject (Get-Content -LiteralPath $DefaultsPath -Raw))
        }
        catch {
            throw "DefaultsPath file '$DefaultsPath' is not valid JSON: $_"
        }
        Write-Log "Defaults overridden from $DefaultsPath"
    }
    $defaults = Merge-PackageDefaults -Base $exampleSettings['Defaults'] -Override $override

    $worstCase = Get-PackageWorstCaseRunSeconds -Defaults $defaults -TimeoutSeconds $timeoutSeconds
    if ($worstCase -gt $script:ExecutionTimeLimitSeconds) {
        $allowed = $script:ExecutionTimeLimitSeconds - (2 * (2 * $timeoutSeconds + 5) + 15)
        throw ("Defaults.MaxRunSeconds $($defaults['MaxRunSeconds']) with a $timeoutSeconds second " +
            "webhook timeout needs $worstCase seconds in the worst case, more than the scheduled " +
            "task's $($script:ExecutionTimeLimitSeconds) second execution limit. Lower MaxRunSeconds " +
            "to $allowed or less.")
    }
    Write-Log "Worst-case worker run: $worstCase s (task limit $($script:ExecutionTimeLimitSeconds) s)"

    #endregion

    #region Resolve and guard the output folder

    # Resolved against the current location so the git-tree test and the summary both talk about
    # a real absolute path, whether or not the folder exists yet.
    $outputRoot = $OutputPath
    if (-not [System.IO.Path]::IsPathRooted($outputRoot)) {
        $outputRoot = Join-Path (Get-Location).Path $outputRoot
    }
    $outputRoot = [System.IO.Path]::GetFullPath($outputRoot)
    $packageRoot = Join-Path $outputRoot $script:PackageFolderName
    $endpointTarget = Join-Path $packageRoot 'Endpoint'

    if (Test-PackageInsideGitTree -Path $outputRoot) {
        if (-not $Force) {
            throw ("'$outputRoot' is inside a git working tree, and the package contains a live " +
                'function key. Build somewhere outside the repository, or pass -Force if the ' +
                'output folder is git-ignored and you accept the risk.')
        }
        Write-Log ("'$outputRoot' is inside a git working tree and the package contains a live " +
            'function key. Make sure it is git-ignored and never committed.') -Level 'WARNING'
    }

    if ((Test-Path -LiteralPath $packageRoot) -and -not $Force) {
        throw "'$packageRoot' already exists. Pass -Force to overwrite it, or choose another -OutputPath."
    }

    #endregion

    #region Build

    New-PackageFolder -Path $packageRoot -Confirm:$false
    New-PackageFolder -Path $endpointTarget -Confirm:$false

    Copy-PackageFile -Path (Join-Path $sourceRoot $script:LauncherFileName) `
        -Destination (Join-Path $packageRoot $script:LauncherFileName) -Confirm:$false
    Copy-PackageFile -Path (Join-Path $sourceRoot $script:GuiFileName) `
        -Destination (Join-Path $packageRoot $script:GuiFileName) -Confirm:$false
    Copy-PackageFile -Path $examplePath -Destination (Join-Path $packageRoot $script:ExampleFileName) `
        -Confirm:$false
    foreach ($name in $script:EndpointFileName) {
        Copy-PackageFile -Path (Join-Path $endpointSource $name) `
            -Destination (Join-Path $endpointTarget $name) -Confirm:$false
    }

    $settings = New-PackageSettingsContent -ClientName $ClientName -AlertUrl $alertUrl `
        -KeyPlainText $keyPlainText -TimeoutSeconds $timeoutSeconds -Defaults $defaults
    Write-PackageTextFile -Path (Join-Path $packageRoot $script:SettingsFileName) `
        -Content (($settings | ConvertTo-Json -Depth 6) + [System.Environment]::NewLine) -Confirm:$false

    $version = Get-PackageSourceVersion -Path $sourceRoot
    $builtAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    $newLine = [System.Environment]::NewLine
    $note = ''
    if ($version.Source -ne 'git') {
        $note = $newLine +
        'No git short SHA was available at build time (no git on PATH, or not a working tree).'
    }
    $endpointStamp = (@(
            'ServiceWatchdog endpoint scripts',
            "Source commit: $($version.Text)",
            "Copied:        $builtAt",
            'Copied verbatim from Monitoring/ServiceWatchdog/Endpoint. Do not edit here; refresh',
            'the pinned copy by rebuilding the package.'
        ) -join $newLine) + $note + $newLine
    $packageStamp = (@(
            'ServiceWatchdog drop-and-deploy package',
            "Source commit: $($version.Text)",
            "Built:         $builtAt",
            'Built by:      New-ServiceWatchdogClientPackage.ps1 1.0.0'
        ) -join $newLine) + $note + $newLine
    Write-PackageTextFile -Path (Join-Path $endpointTarget 'VERSION.txt') -Content $endpointStamp `
        -Confirm:$false
    Write-PackageTextFile -Path (Join-Path $packageRoot 'PACKAGE-VERSION.txt') -Content $packageStamp `
        -Confirm:$false

    #endregion

    #region Hand-over summary

    # Printed with Write-Information so it survives -Verbosity Low: this is the output the
    # operator actually needs. The key itself is never named, only its length.
    $summary = @(
        '',
        'ServiceWatchdog package built.',
        '',
        "  Client:    $ClientName",
        "  Alert URL: $alertUrl",
        "  Key:       supplied, $($keyPlainText.Length) characters, in $script:SettingsFileName only",
        "  Source:    $($version.Text)",
        "  Package:   $packageRoot",
        '',
        '  Contents:',
        "    $script:LauncherFileName",
        "    $script:GuiFileName",
        "    $script:SettingsFileName          <- holds the function key",
        "    $script:ExampleFileName",
        '    PACKAGE-VERSION.txt',
        '    Endpoint\ (4 scripts + VERSION.txt)',
        '',
        '  Hand it over:',
        '    1. Zip the ServiceWatchdog folder and send it over a channel you would send a',
        '       password over. It contains a live function key.',
        '    2. The technician copies the folder to the server (C:\Temp is fine), double-clicks',
        "       $script:LauncherFileName and accepts the UAC prompt.",
        '    3. They check the site name, tick the services to watch, and press Install & test.',
        '    4. They confirm the [TEST] email arrived.',
        ''
    )
    if ($script:DryRunMode) {
        $summary[1] = 'ServiceWatchdog package NOT built: -DryRun was in force. The plan was:'
    }
    foreach ($line in $summary) { Write-Information $line -InformationAction Continue }

    #endregion

    $exitCode = 0
}
catch {
    Write-Log "Package build failed: $_" -Level 'ERROR'
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level 'DEBUG'
    # A refusal the operator can act on, rather than an unexpected fault, is exit 2. Everything
    # thrown above is validation or a guard; a genuine fault arrives as a .NET exception type.
    $exitCode = 2
    if ($_.Exception -isnot [System.Management.Automation.RuntimeException]) { $exitCode = 1 }
}
finally {
    $keyPlainText = $null
    Write-Log "=== New-ServiceWatchdogClientPackage finished with exit code $exitCode ===" -Level 'INFO'
}

exit $exitCode

#endregion
