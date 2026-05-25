### Windows Font Deployment ###
### Uncomment the 3 lines below to run from ScreenConnect's Access page
### #!PS
### #maxlength=50000
### #Timeout=90000

#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs every font found in one or more source directories (recursively)
    system-wide on Windows.

.DESCRIPTION
    Copies .ttf / .otf / .ttc / .fon files to %windir%\Fonts and registers each font in
    HKLM so it is available to all users (avoids the Windows 10 1809+ per-user
    install behaviour that Shell.Application.CopyHere introduced).

    $FontSourcePath accepts a single path or an array of paths. Each root is
    walked recursively with no depth limit, so deeply-nested foundry/vendor
    trees (4+ levels deep) are all covered. When pulling over SFTP, the
    remote tree is also walked recursively and mirrored into the local
    staging folder before the install pass runs.

    The script supports multiple delivery methods for the source font files:

      1. SFTP pull from Azure Blob Storage (recommended - central, auditable, easy
         to rotate keys). Requires the SFTP protocol support add-on to be enabled
         on the Azure Storage account and the Posh-SSH PowerShell module (the
         script will install it from the PSGallery if it is missing).

      2. Pre-staged folder - a UNC path, mapped drive, or local directory that
         already contains the fonts (e.g. dropped there by GPO, Intune Win32 app,
         NinjaOne file-drop, or an RMM "upload-before-run" step).

      3. HTTPS download of a .zip from Azure Blob (not implemented here but trivial
         to add - use Invoke-WebRequest against a SAS URL and Expand-Archive).

    The default flow is: if $UseSFTP is $true, pull the remote folder into
    $FontSourcePath first, then install every font in $FontSourcePath.

.NOTES
    File Name      : Install-Fonts.ps1
    Prerequisite   : PowerShell 5.1+, Administrator privileges
    Logs           : %ProgramData%\<MSPName>\Logs\Install-Fonts_<timestamp>.log

    Font install mechanics adapted from Ben Whitmore's (byteben) Install_Font.ps1:
    https://github.com/byteben/Windows-10/blob/master/Install_Font.ps1
    Full credit to Ben for the original approach and the NoUI flag research.
#>

# ---------------------------------------------------------------------------
# Inputs - override these by setting them as env/RMM variables before the run,
# or edit the defaults here.
# ---------------------------------------------------------------------------

# MSP name used for the ProgramData log folder
if (-not $MSPName) { $MSPName = "YourMSPName" }

# Local staging directory (or directories) the fonts live in / download to.
# Pass a single path or an array: @("C:\Fonts\Brand", "C:\Fonts\Vendor").
# Each root is scanned recursively (arbitrary depth) for .ttf/.otf/.ttc/.fon.
if (-not $FontSourcePath) { $FontSourcePath = @("$env:ProgramData\$MSPName\Fonts") }
$FontSourcePath = @($FontSourcePath)   # normalise to array

# Set to $true to pull fonts over SFTP before installing
if ($null -eq $UseSFTP) { $UseSFTP = $false }

# SFTP settings - point at an Azure Blob storage account with SFTP enabled.
# $SFTPRemotePath can be a single path or an array of remote roots; each is
# walked recursively and mirrored into the first entry of $FontSourcePath.
if (-not $SFTPHost)       { $SFTPHost       = "<storageaccount>.blob.core.windows.net" }
if (-not $SFTPPort)       { $SFTPPort       = 22 }
if (-not $SFTPUsername)   { $SFTPUsername   = "<storageaccount>.<container>.<localuser>" }
if (-not $SFTPPassword)   { $SFTPPassword   = "" }   # prefer RMM secret/custom-field injection
if (-not $SFTPRemotePath) { $SFTPRemotePath = @("/fonts") }
$SFTPRemotePath = @($SFTPRemotePath)

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
$LogDirectory = "$env:ProgramData\$MSPName\Logs"
if (-not (Test-Path -Path $LogDirectory)) {
    try {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    } catch {
        $LogDirectory = "$env:ProgramData"
    }
}
$Now     = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath = Join-Path $LogDirectory "Install-Fonts_$Now.log"
Start-Transcript -Path $LogPath -Force | Out-Null

Write-Output "===== Install-Fonts started $(Get-Date -Format s) ====="
Write-Output "Source path(s) : $($FontSourcePath -join '; ')"
Write-Output "Use SFTP       : $UseSFTP"
Write-Output "Log file       : $LogPath"

# ---------------------------------------------------------------------------
# Helper: ensure each staging directory exists
# ---------------------------------------------------------------------------
foreach ($root in $FontSourcePath) {
    if (-not (Test-Path -Path $root)) {
        try {
            New-Item -Path $root -ItemType Directory -Force | Out-Null
            Write-Output "Created staging directory: $root"
        } catch {
            Write-Error "Failed to create staging directory '$root': $_"
            Stop-Transcript | Out-Null
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Optional: pull fonts from Azure Blob over SFTP using Posh-SSH
# ---------------------------------------------------------------------------
# Recursively walks a remote SFTP tree, mirrors the directory structure
# locally, and downloads any font files it finds. Depth-safe for the 4-levels
# case the user mentioned (and beyond - the recursion has no hard limit).
function Copy-SFTPFontsRecursive {
    param(
        [Parameter(Mandatory)] [int]    $SessionId,
        [Parameter(Mandatory)] [string] $RemotePath,
        [Parameter(Mandatory)] [string] $LocalPath
    )

    if (-not (Test-Path $LocalPath)) {
        New-Item -Path $LocalPath -ItemType Directory -Force | Out-Null
    }

    $downloaded = 0
    $children = Get-SFTPChildItem -SessionId $SessionId -Path $RemotePath -ErrorAction Stop |
        Where-Object { $_.Name -ne '.' -and $_.Name -ne '..' }

    foreach ($child in $children) {
        if ($child.IsDirectory) {
            $subLocal = Join-Path $LocalPath $child.Name
            $downloaded += Copy-SFTPFontsRecursive -SessionId $SessionId `
                -RemotePath $child.FullName -LocalPath $subLocal
        }
        elseif ($child.Name -match '\.(ttf|otf|ttc|fon)$') {
            $dest = Join-Path $LocalPath $child.Name
            Write-Output "  Downloading $($child.FullName) ($([math]::Round($child.Size/1KB,1)) KB)"
            Get-SFTPItem -SessionId $SessionId -Path $child.FullName `
                -Destination $LocalPath -Force -ErrorAction Stop | Out-Null
            if (Test-Path $dest) { $downloaded++ }
        }
    }

    return $downloaded
}

function Invoke-FontSFTPSync {
    param(
        [Parameter(Mandatory)] [string]   $SFTPHost,
        [Parameter(Mandatory)] [int]      $SFTPPort,
        [Parameter(Mandatory)] [string]   $SFTPUsername,
        [Parameter(Mandatory)] [string]   $SFTPPassword,
        [Parameter(Mandatory)] [string[]] $SFTPRemotePath,
        [Parameter(Mandatory)] [string]   $LocalPath
    )

    Write-Output "Preparing SFTP sync from $SFTPHost -> $LocalPath"
    Write-Output "Remote roots : $($SFTPRemotePath -join '; ')"

    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        Write-Output "Posh-SSH module not found. Installing from PSGallery..."
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
            }
            Install-Module -Name Posh-SSH -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        } catch {
            throw "Failed to install Posh-SSH module: $_"
        }
    }
    Import-Module Posh-SSH -ErrorAction Stop

    $securePwd  = ConvertTo-SecureString $SFTPPassword -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($SFTPUsername, $securePwd)

    $session = New-SFTPSession -ComputerName $SFTPHost -Port $SFTPPort -Credential $credential -AcceptKey -ErrorAction Stop
    try {
        $total = 0
        foreach ($remoteRoot in $SFTPRemotePath) {
            # Mirror each remote root as a subfolder of $LocalPath so trees from
            # different roots never collide with each other.
            $rootLeaf  = Split-Path -Leaf ($remoteRoot.TrimEnd('/'))
            if ([string]::IsNullOrWhiteSpace($rootLeaf)) { $rootLeaf = 'root' }
            $rootLocal = Join-Path $LocalPath $rootLeaf
            Write-Output "Walking $remoteRoot -> $rootLocal"
            $total += Copy-SFTPFontsRecursive -SessionId $session.SessionId `
                -RemotePath $remoteRoot -LocalPath $rootLocal
        }
        Write-Output "SFTP sync complete. $total font file(s) downloaded."
        return $total
    }
    finally {
        Remove-SFTPSession -SessionId $session.SessionId | Out-Null
    }
}

if ($UseSFTP) {
    try {
        Invoke-FontSFTPSync -SFTPHost $SFTPHost -SFTPPort $SFTPPort `
            -SFTPUsername $SFTPUsername -SFTPPassword $SFTPPassword `
            -SFTPRemotePath $SFTPRemotePath -LocalPath $FontSourcePath[0] | Out-Null
    } catch {
        Write-Error "SFTP sync failed: $_"
        Stop-Transcript | Out-Null
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Font install
# ---------------------------------------------------------------------------
$FontsFolder   = Join-Path $env:windir 'Fonts'
$FontsRegPath  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$FontExtensions = '*.ttf','*.otf','*.ttc','*.fon'

# Map extension -> the suffix Windows appends in the Fonts registry key
function Get-FontRegistrySuffix {
    param([Parameter(Mandatory)][string]$Extension)
    switch ($Extension.ToLower()) {
        '.ttf' { ' (TrueType)';     break }
        '.ttc' { ' (TrueType)';     break }
        '.otf' { ' (OpenType)';     break }
        '.fon' { '';                break }
        default { ' (TrueType)' }
    }
}

# Read the English font-family name from the file so the registry key matches
# what Windows itself would have written. Falls back to the filename if the
# shell lookup fails.
function Get-FontDisplayName {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    try {
        $shell  = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace($File.DirectoryName)
        $item   = $folder.ParseName($File.Name)
        # Attribute 21 ("Title" for fonts) returns the font family name on Win10+
        $name = $folder.GetDetailsOf($item, 21)
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        }
        return $name
    } catch {
        return [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    }
}

# Use AddFontResource so new fonts show up in running apps without a reboot
$signature = @'
[DllImport("gdi32.dll", CharSet = CharSet.Auto)]
public static extern int AddFontResource(string lpFilename);
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern int SendMessage(int hWnd, uint wMsg, int wParam, int lParam);
'@
if (-not ([System.Management.Automation.PSTypeName]'FontInstaller.Native').Type) {
    Add-Type -MemberDefinition $signature -Name 'Native' -Namespace 'FontInstaller' | Out-Null
}
$HWND_BROADCAST = 0xFFFF
$WM_FONTCHANGE  = 0x001D

$fontFiles = @()
foreach ($root in $FontSourcePath) {
    $found = Get-ChildItem -Path $root -Include $FontExtensions -File -Recurse -ErrorAction SilentlyContinue
    if ($found) {
        Write-Output "Scanned $root -> $($found.Count) font file(s)"
        $fontFiles += $found
    } else {
        Write-Output "Scanned $root -> 0 font files"
    }
}

# De-dupe by filename - same font reached via two paths shouldn't install twice
$fontFiles = $fontFiles | Sort-Object FullName -Unique |
    Group-Object Name | ForEach-Object { $_.Group | Select-Object -First 1 }

if (-not $fontFiles) {
    Write-Output "No font files found under any source path. Nothing to install."
    Stop-Transcript | Out-Null
    exit 0
}

Write-Output "Total unique font file(s) to process: $($fontFiles.Count)"

$installed = 0
$skipped   = 0
$failed    = 0

foreach ($file in $fontFiles) {
    $destPath   = Join-Path $FontsFolder $file.Name
    $regSuffix  = Get-FontRegistrySuffix -Extension $file.Extension
    $regName    = (Get-FontDisplayName -File $file) + $regSuffix

    try {
        # Skip if the file is already in place AND already registered
        $alreadyRegistered = $null -ne (Get-ItemProperty -Path $FontsRegPath -Name $regName -ErrorAction SilentlyContinue)
        if ((Test-Path $destPath) -and $alreadyRegistered) {
            Write-Output "  SKIP  $regName (already installed)"
            $skipped++
            continue
        }

        if (-not (Test-Path $destPath)) {
            Copy-Item -Path $file.FullName -Destination $destPath -Force -ErrorAction Stop
        }

        New-ItemProperty -Path $FontsRegPath -Name $regName -Value $file.Name `
            -PropertyType String -Force -ErrorAction Stop | Out-Null

        [void][FontInstaller.Native]::AddFontResource($destPath)

        Write-Output "  OK    $regName"
        $installed++
    } catch {
        Write-Output "  FAIL  $($file.Name): $($_.Exception.Message)"
        $failed++
    }
}

# Tell running apps to refresh their font caches
[void][FontInstaller.Native]::SendMessage($HWND_BROADCAST, $WM_FONTCHANGE, 0, 0)

Write-Output ""
Write-Output "===== Summary ====="
Write-Output "Installed : $installed"
Write-Output "Skipped   : $skipped"
Write-Output "Failed    : $failed"
Write-Output "===== Install-Fonts finished $(Get-Date -Format s) ====="

Stop-Transcript | Out-Null

if ($failed -gt 0) { exit 1 } else { exit 0 }
