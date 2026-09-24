#Requires -Version 5.1

<#
.SYNOPSIS
    Inventories the browser extensions installed on a Windows device and writes the result to
    NinjaOne device custom fields.

.DESCRIPTION
    Walks every local user profile on the device and reads the extension data that each browser
    keeps on disk. No web store or other external service is called. The extension name, version,
    permissions and install source all come from the browser's own files, which is enough to
    identify an extension and to spot the ones that did not come from a store.

    Browsers covered:
      - Chromium family: Chrome, Edge, Brave, Vivaldi, Chromium, Opera, Opera GX.
        Data comes from the profile's "Secure Preferences" and "Preferences" files
        (extensions.settings), with a fallback to Extensions\<id>\<version>\manifest.json and the
        _locales folder for names stored as __MSG_...__ tokens.
      - Firefox: Profiles\<profile>\extensions.json.

    What is written (three device custom fields, names are parameters):
      1. Inventory (multi-line text): one line per unique browser + extension ID, pipe separated:
             browser|extensionId|name|version|source|state|users|flags
         This field is for NinjaOne device search and custom field conditions. When a compromised
         extension is announced, search this field for the ID.
      2. Table (WYSIWYG): an HTML table of the same data for technicians to read.
      3. Flag count (integer): the number of unique extensions that carry a "blocked",
         "sideloaded" or "unsigned" flag. Put a policy condition on this field to alert.

    Flags:
      blocked     ID is on the block list (-BlockedExtensionId or the blockedExtensionIds script
                  variable).
      sideloaded  Not installed from a store and not installed by policy: unpacked, external
                  registry/preference installs, command line, or a .crx installed by hand.
      unsigned    Firefox extension with no valid signature.
      disabled    Present but disabled by the user or the browser.
      risk        Holds one or more of the permissions in the risky list (see configuration).
                  Listed for information; it does not add to the flag count.

    Extensions that ship with the browser (component extensions, and Chromium entries marked
    was_installed_by_default) are left out unless -IncludeDefaultExtensions is set. This keeps the
    inventory to what a person or an administrator installed.

    Windows-only. Built to run as SYSTEM from a NinjaOne scheduled script or policy. When the
    NinjaOne CLI is not present (for example, a manual run on a test machine), the script logs the
    values it would write and, when -ReportPath is set, writes a JSON report instead.

    Exit codes:
        0  = success
        1  = unexpected failure
        50 = partial success (at least one profile or browser data file could not be read)

.PARAMETER InventoryFieldName
    Name of the multi-line text custom field that receives the pipe-separated inventory.
    Default: browserExtensionInventory. The field has a 10,000 character limit; the script
    truncates and adds a trailer line when the inventory is longer.

.PARAMETER TableFieldName
    Name of the WYSIWYG custom field that receives the HTML table. Default: browserExtensionTable.

.PARAMETER FlagCountFieldName
    Name of the integer custom field that receives the flagged extension count.
    Default: browserExtensionFlagCount.

.PARAMETER BlockedExtensionId
    One or more extension IDs to mark as "blocked". Chromium IDs are 32 lowercase letters a-p.
    Firefox IDs are the add-on ID from extensions.json (a GUID in braces or an email-style ID).
    When this parameter is empty the script reads the blockedExtensionIds environment variable,
    which is how a NinjaOne script variable arrives. Separate IDs with commas, semicolons or
    new lines.

.PARAMETER IncludeDefaultExtensions
    Include component extensions and extensions the browser installed by default.

.PARAMETER ReportPath
    Optional path for a JSON report of every extension record found. Useful for a manual run
    on a test device and for a run outside NinjaOne.

.PARAMETER Verbosity
    Controls console output level. Valid values: Low, Medium, High.
    Low shows only errors and success. Medium adds warnings. High shows everything.
    The log file always receives everything.

.PARAMETER DryRun
    Collects and formats everything but does not write to NinjaOne. The values that would be
    written are logged at DEBUG level and, when -ReportPath is set, saved to the report.

.PARAMETER LogPath
    Path to the log file. Defaults to $env:ProgramData\$MSPName\Logs\<scriptname>-<timestamp>.log.

.EXAMPLE
    .\Set-NinjaBrowserExtensionInventory.ps1
    # Standard unattended run from NinjaOne. Writes the three custom fields.

.EXAMPLE
    .\Set-NinjaBrowserExtensionInventory.ps1 -DryRun -Verbosity High -ReportPath C:\Temp\ext.json
    # Manual run on a test device. Shows every extension found and writes a JSON report. No
    # custom field is changed.

.EXAMPLE
    .\Set-NinjaBrowserExtensionInventory.ps1 -BlockedExtensionId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    # Mark two IDs as blocked. Each match raises the flag count.

.NOTES
    Author:     Ramon DeWitt
    Version:    1.0.0
    Created:    2026-09-23
    AI Assist:  Claude Code
    Requires:   Windows PowerShell 5.1+ (NinjaOne runs scripts with powershell.exe), elevated
                (SYSTEM or local admin) to read every user profile. Targets 5.1 instead of 7.4
                because the NinjaOne agent runs PowerShell scripts in Windows PowerShell.

    NinjaOne setup: see README.md next to this script for the custom field definitions, the
    script variable and the policy condition.
#>

[CmdletBinding()]
param (
    [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
    [string]$InventoryFieldName = 'browserExtensionInventory',

    [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
    [string]$TableFieldName = 'browserExtensionTable',

    [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
    [string]$FlagCountFieldName = 'browserExtensionFlagCount',

    [string[]]$BlockedExtensionId,

    [switch]$IncludeDefaultExtensions,

    [string]$ReportPath,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Low',

    [switch]$DryRun,

    [string]$LogPath
)

#region Configuration & Constants

$MSPName = 'YourMSPName'   # <-- Replace with your MSP name (e.g. 'SentinelCyber')

$ErrorActionPreference = 'Stop'
$script:Verbosity = $Verbosity
$script:DryRun    = [bool]$DryRun
$scriptStartTime  = Get-Date

# NinjaOne custom field limits (characters). The script leaves a margin below each one.
$script:InventoryFieldLimit = 10000
$script:TableFieldLimit     = 199999

# Chromium-based browsers. Path is relative to the user profile folder. "User Data" roots hold
# one folder per browser profile (Default, Profile 1, ...). Opera keeps a single profile in the
# root itself, so SingleProfile tells the scanner not to look for sub-folders.
$script:ChromiumBrowsers = @(
    @{ Name = 'Chrome';   Path = 'AppData\Local\Google\Chrome\User Data';          SingleProfile = $false }
    @{ Name = 'Edge';     Path = 'AppData\Local\Microsoft\Edge\User Data';         SingleProfile = $false }
    @{ Name = 'Brave';    Path = 'AppData\Local\BraveSoftware\Brave-Browser\User Data'; SingleProfile = $false }
    @{ Name = 'Vivaldi';  Path = 'AppData\Local\Vivaldi\User Data';                SingleProfile = $false }
    @{ Name = 'Chromium'; Path = 'AppData\Local\Chromium\User Data';               SingleProfile = $false }
    @{ Name = 'Opera';    Path = 'AppData\Roaming\Opera Software\Opera Stable';    SingleProfile = $true }
    @{ Name = 'OperaGX';  Path = 'AppData\Roaming\Opera Software\Opera GX Stable'; SingleProfile = $true }
)

$script:FirefoxProfilesPath = 'AppData\Roaming\Mozilla\Firefox\Profiles'

# Chromium profile folders that never hold user extensions.
$script:ChromiumSkipProfiles = @('System Profile', 'Guest Profile')

# Chromium ManifestLocation enum. Only the codes that matter for the source label are named.
$script:ChromiumLocation = @{
    1  = 'internal'            # user install (web store or a .crx by hand)
    2  = 'external-pref'       # sideloaded by another program via preferences JSON
    3  = 'external-registry'   # sideloaded by another program via the registry
    4  = 'unpacked'            # developer mode, loaded from a folder
    5  = 'component'           # ships with the browser
    6  = 'external-pref'       # external preferences, downloaded
    7  = 'policy'              # ExtensionInstallForcelist, downloaded
    8  = 'command-line'        # --load-extension
    9  = 'policy'              # ExtensionInstallForcelist
    10 = 'component'           # external component, ships with the browser
}

# Extension IDs the browser installs on its own that are not marked was_installed_by_default in
# every build. Left out unless -IncludeDefaultExtensions is set.
$script:DefaultExtensionIds = @(
    'nmmhkkegccagdldgiimedpiccmgmieda'   # Chrome Web Store Payments
    'ghbmnnjooekpmoecnnnilnnbdlolhkhi'   # Google Docs Offline
    'jmjflgjpcpepeafmmgdpfkogkghcpiha'   # Edge relevant text changes
)

# Update URLs that identify a store install. Chromium sets from_webstore for Chrome Web Store
# installs; Edge Add-ons installs are identified by the update URL instead.
$script:StoreUpdateUrlPatterns = @(
    'clients2.google.com/service/update2/crx'
    'edge.microsoft.com/extensionwebstorebase'
)

# Permissions worth a second look. Host patterns that match every site count as risky on their
# own; the API permissions listed give an extension reach into traffic, sessions or the OS.
$script:RiskyHostPatterns = @('<all_urls>', '*://*/*', 'http://*/*', 'https://*/*', 'file:///*')
$script:RiskyApiPermissions = @(
    'webRequest', 'webRequestBlocking', 'declarativeNetRequest', 'cookies', 'debugger',
    'nativeMessaging', 'proxy', 'history', 'tabs', 'clipboardRead', 'downloads', 'management',
    'scripting', 'webNavigation', 'privacy', 'browsingData'
)

# Derive log path from central location if not explicitly provided.
# PS 5.1 Join-Path only accepts two segments, hence the nested call.
if (-not $LogPath) {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
    if (-not $scriptName) { $scriptName = 'Set-NinjaBrowserExtensionInventory' }
    $logRoot    = Join-Path (Join-Path $env:ProgramData $MSPName) 'Logs'
    $LogPath    = Join-Path $logRoot "$scriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}
$script:LogPath = $LogPath

#endregion

#region Helper Functions

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logMessage = "[$timestamp] [$Level] $Message"

    $writeToConsole = switch ($script:Verbosity) {
        'Low'    { $Level -in 'ERROR', 'SUCCESS' }
        'Medium' { $Level -in 'ERROR', 'WARNING', 'SUCCESS' }
        default  { $true }
    }

    if ($writeToConsole) {
        $color = switch ($Level) {
            'ERROR'   { 'Red' }
            'WARNING' { 'Yellow' }
            'SUCCESS' { 'Green' }
            'DEBUG'   { 'Cyan' }
            default   { 'White' }
        }
        Write-Host $logMessage -ForegroundColor $color
    }

    if ($script:LogPath) {
        try {
            Add-Content -Path $script:LogPath -Value $logMessage -ErrorAction Stop
        }
        catch {
            # A log write failure must never stop the inventory. Drop the file log and continue.
            $script:LogPath = $null
            Write-Host "[$timestamp] [WARNING] Log file is not writable, console only from here: $_" `
                -ForegroundColor Yellow
        }
    }
}

function Invoke-Action {
    param (
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if ($script:DryRun) {
        Write-Log "[DRYRUN] Would execute: $Description" -Level 'INFO'
    }
    else {
        Write-Log "Executing: $Description" -Level 'INFO'
        try {
            & $Action
        }
        catch {
            Write-Log "Failed: $Description - $_" -Level 'ERROR'
            throw
        }
    }
}

function Initialize-LogDirectory {
    if (-not $script:LogPath) { return }
    $logDir = Split-Path -Path $script:LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
}

function ConvertFrom-JsonFile {
    <#
    .SYNOPSIS
        Reads a JSON file into nested dictionaries.
    .DESCRIPTION
        Windows PowerShell 5.1 ConvertFrom-Json builds case-insensitive objects and fails on
        browser preference files that hold keys differing only by case. JavaScriptSerializer
        returns case-sensitive Dictionary<string,object> instances instead. PowerShell 7 gets the
        same shape from ConvertFrom-Json -AsHashtable. The file is opened with shared read/write
        access because the browser may be writing it at the same time.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Dispose()
    }
    finally {
        $stream.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return ConvertFrom-Json -InputObject $text -AsHashtable -Depth 64
    }

    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 100
    return $serializer.DeserializeObject($text)
}

function Get-JsonValue {
    <#
    .SYNOPSIS
        Walks a key path through nested dictionaries and returns $null when any step is missing.
    #>
    param (
        $Object,

        [Parameter(Mandatory)]
        [string[]]$KeyPath
    )

    $current = $Object
    foreach ($key in $KeyPath) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            # ContainsKey exists on both Hashtable and Dictionary<string,object>; Contains does not
            # surface on the generic dictionary from PowerShell.
            if (-not $current.ContainsKey($key)) { return $null }
            $current = $current[$key]
        }
        else {
            return $null
        }
    }
    return $current
}

function ConvertTo-StringArray {
    <#
    .SYNOPSIS
        Normalises a JSON value (string, array, or null) into a flat string array.
    #>
    param ($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { if ($null -ne $_) { [string]$_ } })
    }
    return @([string]$Value)
}

function Get-UserProfilePath {
    <#
    .SYNOPSIS
        Returns the local user profiles on this device from the ProfileList registry key.
    .DESCRIPTION
        Only domain and local user SIDs (S-1-5-21-...) are returned. Service and system profiles
        never hold a browser profile. Folder enumeration of C:\Users is not used because it picks
        up leftover folders with no matching account.
    #>
    $profileListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $profiles = @()

    foreach ($sidKey in (Get-ChildItem -Path $profileListKey -ErrorAction Stop)) {
        if ($sidKey.PSChildName -notlike 'S-1-5-21-*') { continue }
        $imagePath = (Get-ItemProperty -Path $sidKey.PSPath -Name 'ProfileImagePath' `
            -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $imagePath) { continue }
        $imagePath = [System.Environment]::ExpandEnvironmentVariables($imagePath)
        if (-not (Test-Path -Path $imagePath -PathType Container)) { continue }

        $profiles += [pscustomobject]@{
            UserName = Split-Path -Path $imagePath -Leaf
            Path     = $imagePath
            Sid      = $sidKey.PSChildName
        }
    }

    return $profiles
}

function Get-BlockedExtensionIdList {
    <#
    .SYNOPSIS
        Builds the block list from the parameter or the NinjaOne script variable.
    #>
    param (
        [string[]]$ParameterValue,
        [string]$EnvironmentValue
    )

    $raw = @()
    if ($ParameterValue) { $raw += $ParameterValue }
    elseif ($EnvironmentValue) { $raw += $EnvironmentValue }

    $ids = @()
    foreach ($item in $raw) {
        foreach ($piece in ($item -split '[,;\r\n]')) {
            $trimmed = $piece.Trim()
            if ($trimmed) { $ids += $trimmed.ToLowerInvariant() }
        }
    }
    return @($ids | Select-Object -Unique)
}

#endregion

#region Main Functions

function Resolve-ChromiumLocalizedName {
    <#
    .SYNOPSIS
        Resolves a __MSG_key__ manifest name from the extension's _locales messages.json.
    .DESCRIPTION
        Chromium stores the display name of a localised extension as a token. The real name lives
        in _locales\<locale>\messages.json under the key inside the token. Keys are matched
        case-insensitively because Chromium does the same. Returns $null when nothing resolves.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$ExtensionPath,

        [string]$DefaultLocale
    )

    if ($Token -notmatch '^__MSG_(.+)__$') { return $null }
    $messageKey = $Matches[1]

    $localesRoot = Join-Path $ExtensionPath '_locales'
    if (-not (Test-Path -Path $localesRoot -PathType Container)) { return $null }

    $candidates = @()
    if ($DefaultLocale) { $candidates += $DefaultLocale }
    $candidates += 'en', 'en_US', 'en_GB'
    $candidates += (Get-ChildItem -Path $localesRoot -Directory -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name)
    $candidates = @($candidates | Select-Object -Unique)

    foreach ($locale in $candidates) {
        $messagesPath = Join-Path (Join-Path $localesRoot $locale) 'messages.json'
        if (-not (Test-Path -Path $messagesPath -PathType Leaf)) { continue }
        try {
            $messages = ConvertFrom-JsonFile -Path $messagesPath
        }
        catch {
            Write-Log "Could not parse $messagesPath : $_" -Level 'DEBUG'
            continue
        }
        if ($messages -isnot [System.Collections.IDictionary]) { continue }

        foreach ($key in $messages.Keys) {
            if ([string]::Equals($key, $messageKey, [System.StringComparison]::OrdinalIgnoreCase)) {
                $message = Get-JsonValue -Object $messages[$key] -KeyPath 'message'
                if ($message) { return [string]$message }
            }
        }
    }
    return $null
}

function Get-ChromiumExtensionPath {
    <#
    .SYNOPSIS
        Returns the on-disk folder for a Chromium extension entry, or $null.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$ProfilePath,

        [Parameter(Mandatory)]
        [string]$ExtensionId,

        $Entry
    )

    $relativeOrAbsolute = Get-JsonValue -Object $Entry -KeyPath 'path'
    if ($relativeOrAbsolute) {
        $candidate = [string]$relativeOrAbsolute
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path (Join-Path $ProfilePath 'Extensions') $candidate
        }
        if (Test-Path -Path $candidate -PathType Container) { return $candidate }
    }

    # No usable path in the preferences: take the newest version folder under Extensions\<id>.
    $idRoot = Join-Path (Join-Path $ProfilePath 'Extensions') $ExtensionId
    if (Test-Path -Path $idRoot -PathType Container) {
        $newest = Get-ChildItem -Path $idRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($newest) { return $newest.FullName }
    }
    return $null
}

function ConvertFrom-ChromiumInstallTime {
    <#
    .SYNOPSIS
        Converts a Chromium install_time (microseconds since 1601-01-01 UTC) to a DateTime.
    #>
    param ($Value)

    if (-not $Value) { return $null }
    $microseconds = 0L
    if (-not [int64]::TryParse([string]$Value, [ref]$microseconds)) { return $null }
    if ($microseconds -le 0) { return $null }
    try {
        return [DateTime]::FromFileTimeUtc($microseconds * 10)
    }
    catch {
        return $null
    }
}

function Get-ChromiumExtensionSource {
    <#
    .SYNOPSIS
        Maps a Chromium preferences entry to a source label and a sideloaded verdict.
    #>
    param (
        $Entry,
        $Manifest
    )

    $locationCode = Get-JsonValue -Object $Entry -KeyPath 'location'
    $location = 'unknown'
    if ($null -ne $locationCode -and $script:ChromiumLocation.ContainsKey([int]$locationCode)) {
        $location = $script:ChromiumLocation[[int]$locationCode]
    }

    $fromWebstore = [bool](Get-JsonValue -Object $Entry -KeyPath 'from_webstore')
    $updateUrl    = [string](Get-JsonValue -Object $Manifest -KeyPath 'update_url')
    $storeUpdate  = $false
    foreach ($pattern in $script:StoreUpdateUrlPatterns) {
        if ($updateUrl -and $updateUrl.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $storeUpdate = $true
        }
    }

    $source = $location
    $sideloaded = $false
    switch ($location) {
        'internal' {
            if ($fromWebstore -or $storeUpdate) { $source = 'store' }
            else { $source = 'sideloaded'; $sideloaded = $true }
        }
        'external-pref'     { $sideloaded = $true }
        'external-registry' { $sideloaded = $true }
        'unpacked'          { $sideloaded = $true }
        'command-line'      { $sideloaded = $true }
        default             { }
    }

    return [pscustomobject]@{
        Source     = $source
        Sideloaded = $sideloaded
        IsDefault  = ($location -eq 'component') -or
                     [bool](Get-JsonValue -Object $Entry -KeyPath 'was_installed_by_default')
    }
}

function Get-ChromiumProfileExtension {
    <#
    .SYNOPSIS
        Reads every extension in one Chromium profile folder.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Browser,

        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$ProfilePath,

        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    # Secure Preferences holds the extension list on Windows; Preferences can hold entries too.
    # Secure Preferences wins when both hold the same ID.
    $settings = @{}
    foreach ($fileName in @('Preferences', 'Secure Preferences')) {
        $filePath = Join-Path $ProfilePath $fileName
        if (-not (Test-Path -Path $filePath -PathType Leaf)) { continue }
        try {
            $prefs = ConvertFrom-JsonFile -Path $filePath
        }
        catch {
            Write-Log "Could not read $filePath : $_" -Level 'WARNING'
            $script:ReadFailures++
            continue
        }
        $entries = Get-JsonValue -Object $prefs -KeyPath 'extensions', 'settings'
        if ($entries -is [System.Collections.IDictionary]) {
            foreach ($id in $entries.Keys) { $settings[$id] = $entries[$id] }
        }
    }

    $records = @()
    foreach ($id in $settings.Keys) {
        $entry = $settings[$id]
        if ($entry -isnot [System.Collections.IDictionary]) { continue }

        $manifest = Get-JsonValue -Object $entry -KeyPath 'manifest'
        $extensionPath = Get-ChromiumExtensionPath -ProfilePath $ProfilePath -ExtensionId $id -Entry $entry

        # Entries without a manifest in the preferences are pending installs or leftovers. Try the
        # manifest on disk before giving up on them.
        if ($manifest -isnot [System.Collections.IDictionary] -and $extensionPath) {
            $manifestPath = Join-Path $extensionPath 'manifest.json'
            if (Test-Path -Path $manifestPath -PathType Leaf) {
                try { $manifest = ConvertFrom-JsonFile -Path $manifestPath }
                catch { Write-Log "Could not read $manifestPath : $_" -Level 'DEBUG' }
            }
        }
        if ($manifest -isnot [System.Collections.IDictionary]) {
            Write-Log "$Browser/$UserName/$ProfileName $id has no manifest, skipped" -Level 'DEBUG'
            continue
        }

        # Chromium apps and themes are not extensions. Themes carry a "theme" key; hosted and
        # packaged apps carry an "app" key.
        if ($manifest.ContainsKey('theme') -or $manifest.ContainsKey('app')) { continue }

        $sourceInfo = Get-ChromiumExtensionSource -Entry $entry -Manifest $manifest
        $isDefault = $sourceInfo.IsDefault -or ($script:DefaultExtensionIds -contains $id)
        if ($isDefault -and -not $IncludeDefaultExtensions) { continue }

        $name = [string](Get-JsonValue -Object $manifest -KeyPath 'name')
        if ($name -like '__MSG_*__' -and $extensionPath) {
            $resolved = Resolve-ChromiumLocalizedName -Token $name -ExtensionPath $extensionPath `
                -DefaultLocale ([string](Get-JsonValue -Object $manifest -KeyPath 'default_locale'))
            if ($resolved) { $name = $resolved }
        }
        if (-not $name) { $name = '(unnamed)' }

        # Granted permissions from the preferences are what the extension can use now. The manifest
        # is the fallback for entries that predate the granted_permissions block.
        $apiPermissions  = ConvertTo-StringArray (Get-JsonValue -Object $entry -KeyPath 'granted_permissions', 'api')
        $hostPermissions = ConvertTo-StringArray `
            (Get-JsonValue -Object $entry -KeyPath 'granted_permissions', 'explicit_host')
        if ($apiPermissions.Count -eq 0 -and $hostPermissions.Count -eq 0) {
            $apiPermissions  = ConvertTo-StringArray (Get-JsonValue -Object $manifest -KeyPath 'permissions')
            $hostPermissions = ConvertTo-StringArray (Get-JsonValue -Object $manifest -KeyPath 'host_permissions')
        }

        # state 1 = enabled. disable_reasons was a bit mask; newer Chromium builds store a list.
        # Either shape with content means the browser disabled the extension.
        $state = Get-JsonValue -Object $entry -KeyPath 'state'
        $disableReasons = Get-JsonValue -Object $entry -KeyPath 'disable_reasons'
        $enabled = ($null -eq $state -or [int]$state -eq 1)
        if ($disableReasons -is [string] -or $disableReasons -is [System.ValueType]) {
            if ([int64]$disableReasons -ne 0) { $enabled = $false }
        }
        elseif ($disableReasons -is [System.Collections.IEnumerable]) {
            if (@($disableReasons).Count -gt 0) { $enabled = $false }
        }

        $records += New-ExtensionRecord -Browser $Browser -UserName $UserName -ProfileName $ProfileName `
            -Id $id -Name $name -Version ([string](Get-JsonValue -Object $manifest -KeyPath 'version')) `
            -Source $sourceInfo.Source -Sideloaded $sourceInfo.Sideloaded -Unsigned $false -Enabled $enabled `
            -Installed (ConvertFrom-ChromiumInstallTime (Get-JsonValue -Object $entry -KeyPath 'install_time')) `
            -ApiPermissions $apiPermissions -HostPermissions $hostPermissions -Path $extensionPath
    }
    return $records
}

function Get-ChromiumExtension {
    <#
    .SYNOPSIS
        Finds every Chromium-family browser profile under one user profile and reads it.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$UserProfilePath
    )

    $records = @()
    foreach ($browser in $script:ChromiumBrowsers) {
        $root = Join-Path $UserProfilePath $browser.Path
        if (-not (Test-Path -Path $root -PathType Container)) { continue }

        if ($browser.SingleProfile) {
            $profileFolders = @(Get-Item -Path $root)
        }
        else {
            $profileFolders = @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin $script:ChromiumSkipProfiles })
        }

        foreach ($folder in $profileFolders) {
            $hasPrefs = (Test-Path -Path (Join-Path $folder.FullName 'Preferences') -PathType Leaf) -or
                        (Test-Path -Path (Join-Path $folder.FullName 'Secure Preferences') -PathType Leaf)
            if (-not $hasPrefs) { continue }

            Write-Log "Scanning $($browser.Name) profile '$($folder.Name)' for $UserName" -Level 'DEBUG'
            $records += Get-ChromiumProfileExtension -Browser $browser.Name -UserName $UserName `
                -ProfilePath $folder.FullName -ProfileName $folder.Name
        }
    }
    return $records
}

function Get-FirefoxExtension {
    <#
    .SYNOPSIS
        Reads extensions.json from every Firefox profile under one user profile.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$UserProfilePath
    )

    $records = @()
    $profilesRoot = Join-Path $UserProfilePath $script:FirefoxProfilesPath
    if (-not (Test-Path -Path $profilesRoot -PathType Container)) { return $records }

    foreach ($folder in (Get-ChildItem -Path $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
        $extensionsFile = Join-Path $folder.FullName 'extensions.json'
        if (-not (Test-Path -Path $extensionsFile -PathType Leaf)) { continue }

        Write-Log "Scanning Firefox profile '$($folder.Name)' for $UserName" -Level 'DEBUG'
        try {
            $data = ConvertFrom-JsonFile -Path $extensionsFile
        }
        catch {
            Write-Log "Could not read $extensionsFile : $_" -Level 'WARNING'
            $script:ReadFailures++
            continue
        }

        $records += ConvertFrom-FirefoxExtensionData -Data $data -UserName $UserName -ProfileName $folder.Name
    }
    return $records
}

function ConvertFrom-FirefoxExtensionData {
    <#
    .SYNOPSIS
        Converts parsed Firefox extensions.json content into extension records.
    #>
    param (
        $Data,

        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    $records = @()
    $addons = Get-JsonValue -Object $Data -KeyPath 'addons'
    if ($addons -isnot [System.Collections.IEnumerable]) { return $records }

    foreach ($addon in $addons) {
        if ($addon -isnot [System.Collections.IDictionary]) { continue }
        if ([string](Get-JsonValue -Object $addon -KeyPath 'type') -ne 'extension') { continue }

        $location = [string](Get-JsonValue -Object $addon -KeyPath 'location')
        $isDefault = $location -in @('app-builtin', 'app-system-defaults', 'app-system-addons', 'app-system-share')
        if ($isDefault -and -not $IncludeDefaultExtensions) { continue }

        $sourceUri = [string](Get-JsonValue -Object $addon -KeyPath 'sourceURI')
        $sideloaded = $false
        switch ($location) {
            'app-profile' {
                if ($sourceUri -like 'https://addons.mozilla.org/*') { $source = 'store' }
                else { $source = 'sideloaded'; $sideloaded = $true }
            }
            'app-global'         { $source = 'external'; $sideloaded = $true }
            'winreg-app-global'  { $source = 'external-registry'; $sideloaded = $true }
            'winreg-app-user'    { $source = 'external-registry'; $sideloaded = $true }
            'app-system-defaults' { $source = 'component' }
            'app-builtin'        { $source = 'component' }
            default              { $source = $location }
        }

        # Firefox signedState: 2 = signed, 3 = system, 4 = privileged, 1 = preliminary,
        # 0 = missing, negative = broken or unknown. Store installs are always signed.
        $signedState = Get-JsonValue -Object $addon -KeyPath 'signedState'
        $unsigned = ($null -ne $signedState -and [int]$signedState -le 0)

        $userDisabled = [bool](Get-JsonValue -Object $addon -KeyPath 'userDisabled')
        $appDisabled  = [bool](Get-JsonValue -Object $addon -KeyPath 'appDisabled')
        $active       = Get-JsonValue -Object $addon -KeyPath 'active'
        $enabled = (-not $userDisabled) -and (-not $appDisabled) -and ($null -eq $active -or [bool]$active)

        $installed = $null
        $installDate = Get-JsonValue -Object $addon -KeyPath 'installDate'
        if ($installDate) {
            try { $installed = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$installDate).UtcDateTime }
            catch { $installed = $null }
        }

        $name = [string](Get-JsonValue -Object $addon -KeyPath 'defaultLocale', 'name')
        if (-not $name) { $name = '(unnamed)' }

        $grantedApi      = Get-JsonValue -Object $addon -KeyPath 'userPermissions', 'permissions'
        $grantedOrigins  = Get-JsonValue -Object $addon -KeyPath 'userPermissions', 'origins'
        $apiPermissions  = ConvertTo-StringArray $grantedApi
        $hostPermissions = ConvertTo-StringArray $grantedOrigins

        $records += New-ExtensionRecord -Browser 'Firefox' -UserName $UserName -ProfileName $ProfileName `
            -Id ([string](Get-JsonValue -Object $addon -KeyPath 'id')) -Name $name `
            -Version ([string](Get-JsonValue -Object $addon -KeyPath 'version')) `
            -Source $source -Sideloaded $sideloaded -Unsigned $unsigned -Enabled $enabled -Installed $installed `
            -ApiPermissions $apiPermissions -HostPermissions $hostPermissions `
            -Path ([string](Get-JsonValue -Object $addon -KeyPath 'path'))
    }
    return $records
}

function Get-RiskyPermission {
    <#
    .SYNOPSIS
        Returns the subset of an extension's permissions that are on the risky lists.
    #>
    param (
        [string[]]$ApiPermissions,
        [string[]]$HostPermissions
    )

    $risky = @()
    foreach ($permission in $ApiPermissions) {
        if ($permission -in $script:RiskyApiPermissions) { $risky += $permission }
        if ($permission -in $script:RiskyHostPatterns) { $risky += $permission }
    }
    foreach ($hostPattern in $HostPermissions) {
        if ($hostPattern -in $script:RiskyHostPatterns) { $risky += $hostPattern }
    }
    return @($risky | Select-Object -Unique)
}

function New-ExtensionRecord {
    <#
    .SYNOPSIS
        Builds the one record shape every browser reader returns.
    #>
    param (
        [Parameter(Mandatory)] [string]$Browser,
        [Parameter(Mandatory)] [string]$UserName,
        [Parameter(Mandatory)] [string]$ProfileName,
        [string]$Id,
        [string]$Name,
        [string]$Version,
        [string]$Source,
        [bool]$Sideloaded,
        [bool]$Unsigned,
        [bool]$Enabled,
        $Installed,
        [string[]]$ApiPermissions = @(),
        [string[]]$HostPermissions = @(),
        [string]$Path
    )

    $riskyPermissions = Get-RiskyPermission -ApiPermissions $ApiPermissions -HostPermissions $HostPermissions
    if (-not $Id)     { $Id = '(no-id)' }
    if (-not $Name)   { $Name = '(unnamed)' }
    if (-not $Source) { $Source = 'unknown' }

    return [pscustomobject]@{
        Browser          = $Browser
        User             = $UserName
        Profile          = $ProfileName
        Id               = $Id
        Name             = $Name
        Version          = $Version
        Source           = $Source
        Sideloaded       = $Sideloaded
        Unsigned         = $Unsigned
        Enabled          = $Enabled
        Blocked          = $false
        Installed        = $Installed
        ApiPermissions   = $ApiPermissions
        HostPermissions  = $HostPermissions
        RiskyPermissions = $riskyPermissions
        Path             = $Path
    }
}

function Get-ExtensionFlag {
    <#
    .SYNOPSIS
        Returns the flag labels for one record, severe flags first.
    #>
    param ($Record)

    $flags = @()
    if ($Record.Blocked)    { $flags += 'blocked' }
    if ($Record.Sideloaded) { $flags += 'sideloaded' }
    if ($Record.Unsigned)   { $flags += 'unsigned' }
    if (-not $Record.Enabled) { $flags += 'disabled' }
    if ($Record.RiskyPermissions.Count -gt 0) { $flags += 'risk' }
    return $flags
}

function Group-ExtensionRecord {
    <#
    .SYNOPSIS
        Collapses per-user records into one summary per browser + extension ID.
    .DESCRIPTION
        The custom field has a 10,000 character limit and the same extension is often installed
        for every user on a shared device. One line per browser + ID with the users listed keeps
        the field short and still answers "who has it". A flag set by any user's copy is kept.
    #>
    param ([object[]]$Records)

    $groups = @{}
    $order = @()
    foreach ($record in $Records) {
        $key = "$($record.Browser)|$($record.Id)"
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{
                Browser          = $record.Browser
                Id               = $record.Id
                Name             = $record.Name
                Versions         = @()
                Sources          = @()
                Users            = @()
                Blocked          = $false
                Sideloaded       = $false
                Unsigned         = $false
                Enabled          = $false
                RiskyPermissions = @()
                Installed        = $null
            }
            $order += $key
        }
        $group = $groups[$key]
        if ($record.Version -and $record.Version -notin $group.Versions) { $group.Versions += $record.Version }
        if ($record.Source -notin $group.Sources) { $group.Sources += $record.Source }
        if ($record.User -notin $group.Users) { $group.Users += $record.User }
        if ($record.Blocked)    { $group.Blocked = $true }
        if ($record.Sideloaded) { $group.Sideloaded = $true }
        if ($record.Unsigned)   { $group.Unsigned = $true }
        if ($record.Enabled)    { $group.Enabled = $true }
        foreach ($permission in $record.RiskyPermissions) {
            if ($permission -notin $group.RiskyPermissions) { $group.RiskyPermissions += $permission }
        }
        if ($record.Installed -and (-not $group.Installed -or $record.Installed -lt $group.Installed)) {
            $group.Installed = $record.Installed
        }
        if ($group.Name -eq '(unnamed)' -and $record.Name -ne '(unnamed)') { $group.Name = $record.Name }
    }

    $summaries = @($order | ForEach-Object { $groups[$_] })

    # Severe flags first so the top of the field is what a technician needs to see.
    return @($summaries | Sort-Object -Property @{ Expression = { Get-FlagRank $_ } }, Browser, Name)
}

function Get-FlagRank {
    param ($Summary)
    if ($Summary.Blocked) { return 0 }
    if ($Summary.Sideloaded -or $Summary.Unsigned) { return 1 }
    if ($Summary.RiskyPermissions.Count -gt 0) { return 2 }
    return 3
}

function Format-InventoryText {
    <#
    .SYNOPSIS
        Renders the pipe-separated inventory and keeps it under the multi-line field limit.
    #>
    param (
        [object[]]$Summaries,

        [int]$Limit = $script:InventoryFieldLimit
    )

    if (-not $Summaries -or $Summaries.Count -eq 0) { return 'No extensions found' }

    $header = 'browser|id|name|version|source|state|users|flags'
    $lines = @($header)
    foreach ($summary in $Summaries) {
        $flags = Get-ExtensionFlag -Record $summary
        $flagText = if ($flags.Count -gt 0) { $flags -join ',' } else { '-' }
        $state = if ($summary.Enabled) { 'enabled' } else { 'disabled' }
        $name = ($summary.Name -replace '[|\r\n]', ' ').Trim()
        $lines += "$($summary.Browser.ToLowerInvariant())|$($summary.Id)|$name|$($summary.Versions -join ',')|" +
                  "$($summary.Sources -join ',')|$state|$($summary.Users -join ',')|$flagText"
    }

    $text = $lines -join "`n"
    if ($text.Length -le $Limit) { return $text }

    # Keep whole lines only, then say how many were cut so the reader knows to check the log.
    $kept = @()
    $length = 0
    foreach ($line in $lines) {
        $trailerAllowance = 80
        if (($length + $line.Length + 1) -gt ($Limit - $trailerAllowance)) { break }
        $kept += $line
        $length += $line.Length + 1
    }
    $cut = $lines.Count - $kept.Count
    $kept += "... $cut more entries not shown (field limit $Limit characters, see the log)"
    return ($kept -join "`n")
}

function Format-InventoryHtml {
    <#
    .SYNOPSIS
        Renders the HTML table for the WYSIWYG field and keeps it under the field limit.
    #>
    param (
        [object[]]$Summaries,

        [int]$UserCount,

        [int]$FlagCount,

        [int]$Limit = $script:TableFieldLimit
    )

    $encode = { param ($value) [System.Net.WebUtility]::HtmlEncode([string]$value) }
    $scanned = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $total = if ($Summaries) { $Summaries.Count } else { 0 }

    $summaryLine = "<p><b>Browser extensions</b> - scanned $scanned - $total extensions across " +
                   "$UserCount user profiles - <b>$FlagCount flagged</b></p>"
    if ($total -eq 0) { return "$summaryLine<p>No extensions found.</p>" }

    $head = '<table><thead><tr><th>Flags</th><th>Browser</th><th>Name</th><th>ID</th><th>Version</th>' +
            '<th>Source</th><th>State</th><th>Users</th><th>Risky permissions</th></tr></thead><tbody>'
    $foot = '</tbody></table>'

    $rows = @()
    foreach ($summary in $Summaries) {
        $flags = Get-ExtensionFlag -Record $summary
        $flagText = if ($flags.Count -gt 0) { "<b>$(& $encode ($flags -join ', '))</b>" } else { '' }
        $state = if ($summary.Enabled) { 'enabled' } else { 'disabled' }
        $rows += '<tr>' +
            "<td>$flagText</td>" +
            "<td>$(& $encode $summary.Browser)</td>" +
            "<td>$(& $encode $summary.Name)</td>" +
            "<td>$(& $encode $summary.Id)</td>" +
            "<td>$(& $encode ($summary.Versions -join ', '))</td>" +
            "<td>$(& $encode ($summary.Sources -join ', '))</td>" +
            "<td>$state</td>" +
            "<td>$(& $encode ($summary.Users -join ', '))</td>" +
            "<td>$(& $encode ($summary.RiskyPermissions -join ', '))</td>" +
            '</tr>'
    }

    $html = $summaryLine + $head + ($rows -join '') + $foot
    if ($html.Length -le $Limit) { return $html }

    $kept = @()
    $length = $summaryLine.Length + $head.Length + $foot.Length + 120
    foreach ($row in $rows) {
        if (($length + $row.Length) -gt $Limit) { break }
        $kept += $row
        $length += $row.Length
    }
    $cut = $rows.Count - $kept.Count
    $kept += "<tr><td colspan='9'>... $cut more entries not shown (field limit), " +
             'see the inventory field and the log</td></tr>'
    return $summaryLine + $head + ($kept -join '') + $foot
}

function Get-NinjaCliPath {
    <#
    .SYNOPSIS
        Returns the path to ninjarmm-cli.exe when the NinjaOne agent is installed, else $null.
    #>
    $roots = @($env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($root in $roots) {
        $candidate = Join-Path (Join-Path $root 'NinjaRMMAgent') 'ninjarmm-cli.exe'
        if (Test-Path -Path $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Set-NinjaFieldValue {
    <#
    .SYNOPSIS
        Writes one custom field through the NinjaOne wrapper functions or the agent CLI.
    .DESCRIPTION
        When a script runs from NinjaOne, the host defines Ninja-Property-Set and
        Ninja-Property-Set-Piped. The piped form is used for every value because it accepts the
        larger WYSIWYG and multi-line limits. Outside NinjaOne the agent CLI is tried next. When
        neither exists the value is logged and the function returns $false.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$FieldName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if (Get-Command -Name 'Ninja-Property-Set-Piped' -ErrorAction SilentlyContinue) {
        $Value | Ninja-Property-Set-Piped $FieldName
        return $true
    }

    $cli = Get-NinjaCliPath
    if ($cli) {
        $Value | & $cli set $FieldName --stdin | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "ninjarmm-cli returned exit code $LASTEXITCODE for field $FieldName" }
        return $true
    }

    Write-Log "NinjaOne CLI not found; value for '$FieldName' not written ($($Value.Length) characters)" `
        -Level 'WARNING'
    return $false
}

function Initialize-Script {
    Initialize-LogDirectory
    Write-Log "Script started - MSP: $MSPName" -Level 'INFO'
    Write-Log "Log file: $($script:LogPath)" -Level 'INFO'
    Write-Log ("Parameters: InventoryFieldName=$InventoryFieldName, TableFieldName=$TableFieldName, " +
               "FlagCountFieldName=$FlagCountFieldName, IncludeDefaultExtensions=$IncludeDefaultExtensions, " +
               "Verbosity=$Verbosity, DryRun=$DryRun") -Level 'INFO'

    if ($script:DryRun) {
        Write-Log '*** DRYRUN MODE - No custom field will be written ***' -Level 'WARNING'
    }
    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
        throw 'This script reads Windows browser profiles and must run on Windows.'
    }
}

function Invoke-ExtensionInventory {
    <#
    .SYNOPSIS
        Collects every extension record for every user profile on the device.
    #>
    $script:ReadFailures = 0
    $records = @()

    $userProfiles = @(Get-UserProfilePath)
    Write-Log "Found $($userProfiles.Count) user profiles" -Level 'INFO'

    foreach ($userProfile in $userProfiles) {
        try {
            $records += Get-ChromiumExtension -UserName $userProfile.UserName -UserProfilePath $userProfile.Path
            $records += Get-FirefoxExtension  -UserName $userProfile.UserName -UserProfilePath $userProfile.Path
        }
        catch {
            Write-Log "Could not scan profile $($userProfile.UserName): $_" -Level 'WARNING'
            $script:ReadFailures++
        }
    }

    return [pscustomobject]@{
        Records   = $records
        UserCount = $userProfiles.Count
    }
}

function Publish-ExtensionInventory {
    <#
    .SYNOPSIS
        Formats the records and writes the three custom fields.
    #>
    param (
        [object[]]$Records,
        [int]$UserCount,
        [string[]]$BlockList
    )

    foreach ($record in $Records) {
        if ($record.Id.ToLowerInvariant() -in $BlockList) { $record.Blocked = $true }
    }

    $summaries = Group-ExtensionRecord -Records $Records
    $flagCount = @($summaries | Where-Object { $_.Blocked -or $_.Sideloaded -or $_.Unsigned }).Count

    Write-Log ("Inventory: $($Records.Count) records, $($summaries.Count) unique extensions, " +
               "$flagCount flagged, $UserCount user profiles") -Level 'INFO'
    foreach ($summary in $summaries) {
        $flags = Get-ExtensionFlag -Record $summary
        Write-Log ("  $($summary.Browser) $($summary.Id) '$($summary.Name)' v$($summary.Versions -join ',') " +
                   "source=$($summary.Sources -join ',') users=$($summary.Users -join ',') " +
                   "flags=$($flags -join ',')") -Level 'DEBUG'
    }

    $inventoryText = Format-InventoryText -Summaries $summaries
    $tableHtml     = Format-InventoryHtml -Summaries $summaries -UserCount $UserCount -FlagCount $flagCount

    # The report is a local file for the technician, not a NinjaOne write, so DryRun still
    # produces it. That is the point of a DryRun on a test device.
    if ($ReportPath) {
        Write-Log "Writing JSON report to $ReportPath" -Level 'INFO'
        $reportDir = Split-Path -Path $ReportPath -Parent
        if ($reportDir -and -not (Test-Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }
        [pscustomobject]@{
            Scanned   = (Get-Date).ToString('o')
            Device    = $env:COMPUTERNAME
            UserCount = $UserCount
            FlagCount = $flagCount
            Records   = $Records
            Inventory = $inventoryText
            TableHtml = $tableHtml
        } | ConvertTo-Json -Depth 6 | Set-Content -Path $ReportPath -Encoding UTF8
    }

    Invoke-Action -Description "Set custom field '$InventoryFieldName' ($($inventoryText.Length) characters)" -Action {
        if (Set-NinjaFieldValue -FieldName $InventoryFieldName -Value $inventoryText) { $script:FieldsWritten++ }
    }
    Invoke-Action -Description "Set custom field '$TableFieldName' ($($tableHtml.Length) characters)" -Action {
        if (Set-NinjaFieldValue -FieldName $TableFieldName -Value $tableHtml) { $script:FieldsWritten++ }
    }
    Invoke-Action -Description "Set custom field '$FlagCountFieldName' to $flagCount" -Action {
        if (Set-NinjaFieldValue -FieldName $FlagCountFieldName -Value ([string]$flagCount)) { $script:FieldsWritten++ }
    }

    if ($script:DryRun) {
        Write-Log "[DRYRUN] Inventory field value:`n$inventoryText" -Level 'DEBUG'
        Write-Log "[DRYRUN] Table field length: $($tableHtml.Length) characters; flag count: $flagCount" -Level 'DEBUG'
    }

    return $flagCount
}

#endregion

#region Script Body

# Dot-sourcing (InvocationName '.') loads the functions and stops, which is how the Pester suite
# exercises the parsers and formatters on any platform without touching a real device.
if ($MyInvocation.InvocationName -ne '.') {
    $script:FieldsWritten = 0
    $script:ReadFailures  = 0
    try {
        Initialize-Script

        $blockList = Get-BlockedExtensionIdList -ParameterValue $BlockedExtensionId `
            -EnvironmentValue $env:blockedExtensionIds
        if ($blockList.Count -gt 0) { Write-Log "Block list holds $($blockList.Count) IDs" -Level 'INFO' }

        $inventory = Invoke-ExtensionInventory
        $flagCount = Publish-ExtensionInventory -Records $inventory.Records -UserCount $inventory.UserCount `
            -BlockList $blockList

        if ($script:ReadFailures -gt 0) {
            Write-Log "Completed with $($script:ReadFailures) unreadable profiles or files; $flagCount flagged" `
                -Level 'WARNING'
            exit 50
        }
        Write-Log "Inventory complete: $flagCount flagged extensions, $($script:FieldsWritten) fields written" `
            -Level 'SUCCESS'
        exit 0
    }
    catch {
        Write-Log "Script failed: $_" -Level 'ERROR'
        Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
        exit 1
    }
    finally {
        $duration = (Get-Date) - $scriptStartTime
        Write-Log "Total duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Level 'INFO'
    }
}

#endregion
