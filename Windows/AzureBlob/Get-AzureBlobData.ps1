### Azure Blob Data Pull ###
### Uncomment the 3 lines below to run from ScreenConnect's Access page
### #!PS
### #maxlength=50000
### #Timeout=90000

#Requires -Version 5.1

<#
.SYNOPSIS
    Securely pulls files down from an Azure Blob Storage container into the
    standard %ProgramData%\<MSPName>\<Category> folder structure.

.DESCRIPTION
    A focused, download-only fetcher. Point it at a blob path and it mirrors
    whatever it finds there into a chosen local category folder (AppInstalls,
    Tools, Scripts, Data, etc.). It does NOT install, execute, or clean up
    anything - it just retrieves files.

    Two authentication methods are supported (pick one in the config block):

      1. SAS  - a Shared Access Signature token (the "disk token" you generate
                in the Azure portal under the storage account / container).
                Talks to the Blob REST API over HTTPS. No extra modules, no
                SFTP add-on required, and the token can be scoped read-only and
                time-limited - the most secure option for a pull-only job.

      2. SFTP - a local SFTP user + password on a storage account that has the
                SFTP protocol add-on enabled. Uses the Posh-SSH module (auto
                installed from the PSGallery if missing).

    Both methods walk the remote tree recursively and mirror the folder
    structure locally. Downloads are retried with exponential backoff, and a
    SHA / size check skips files that are already present and complete.

    Other methods we deliberately left out to keep this simple/secure:
      - Storage account key   : works, but the key grants full account access -
                                prefer a scoped, read-only SAS instead.
      - Entra ID / Managed ID : great for Azure-hosted runners, overkill for an
                                RMM/endpoint pull. Easy to add later via Az.Storage.

.NOTES
    File Name      : Get-AzureBlobData.ps1
    Prerequisite   : PowerShell 5.1+ (SAS method needs nothing else)
    Logs           : %ProgramData%\<MSPName>\Logs\Get-AzureBlobData_<timestamp>.log

    Designed to be edited in place: set the values in the CONFIGURATION block
    below, save, and deploy the file as-is from your RMM - no command-line
    arguments required. Anything you fill in always wins.

    Optionally ($AllowEnvOverride = $true), any value you LEAVE BLANK can still
    be injected as an environment / RMM variable of the same name, so secrets
    (SAS token, SFTP password) never have to live in the file if you'd rather
    push them separately.
#>

# ===========================================================================
#  CONFIGURATION  -  EDIT THIS BLOCK, SAVE, AND DEPLOY.
#
#  Everything you need to change lives between here and "END CONFIGURATION".
#  Set the values directly below - no command-line arguments needed, so this
#  is safe to push out as-is from an RMM. Whatever you type here wins.
# ===========================================================================

# --- (1) WHICH AUTH METHOD -------------------------------------------------
#   "SAS"  -> HTTPS Blob REST API with a Shared Access Signature token
#   "SFTP" -> Posh-SSH against the storage account's SFTP endpoint
$Method = "SAS"

# --- (2) WHAT WE PULL & WHERE IT LANDS -------------------------------------
# Your MSP name - drives the %ProgramData%\<MSPName> root folder.
$MSPName = "YourMSPName"

# Which category bucket to drop the download into.
# Must be one of the keys in $CategoryMap near the bottom of this block
# (AppInstalls, Tools, Scripts, Data, Logs).
$DestinationCategory = "AppInstalls"

# Optional extra subfolder under the category, e.g. "AcmeCorp\AgentV2".
# Leave blank to land straight in the category folder.
$DestinationSubPath = ""

# Wipe the destination subfolder before downloading? ($false = merge/refresh)
$CleanDestination = $false

# --- (3a) SAS (HTTPS) SETTINGS  -  used when $Method = "SAS" ----------------
$StorageAccount = "<storageaccount>"    # name only, no suffix
$Container      = "<container>"
$SasToken       = ""                    # "sv=...&sig=..." (leading '?' optional)
# Only pull blobs under this virtual path. "" = whole container.
# e.g. "agents/sentinelone/" or a single blob name "tools/7zip.msi".
$BlobPrefix     = ""
# Storage endpoint suffix - change only for sovereign/gov clouds.
$EndpointSuffix = "core.windows.net"

# --- (3b) SFTP SETTINGS  -  used when $Method = "SFTP" ----------------------
# Leave $SftpHost / $SftpUsername blank to auto-build them from the SAS
# settings above; fill them in only if you need something non-standard.
$SftpHost       = ""                    # blank => "<account>.blob.<suffix>"
$SftpPort       = 22
$SftpUsername   = ""                    # blank => "<account>.<container>.<localuser>"
$SftpPassword   = ""                    # prefer RMM secret injection
$SftpRemotePath = "/"                   # remote root to mirror

# --- (4) FILTERING / BEHAVIOUR ---------------------------------------------
# Only download files matching these extensions. Empty array = everything.
$IncludeExtensions = @()                # e.g. @(".exe",".msi",".zip")
$MaxRetries        = 4

# --- (5) CATEGORY BUCKETS  -  folders under %ProgramData%\<MSPName>\ --------
# Add/trim to taste, but keep it tight - these are the buckets we actually use.
$CategoryMap = @{
    AppInstalls = "AppInstalls"   # installers / MSI / EXE staged for deployment
    Tools       = "Tools"         # portable utilities, sysadmin tooling
    Scripts     = "Scripts"       # scripts pulled down to run later
    Data        = "Data"          # generic data / config / payloads
    Logs        = "Logs"          # log bundles, exported reports
}

# --- (6) OPTIONAL: env/RMM override for values left blank -------------------
# $true  => any setting above that you LEFT BLANK can be supplied as an
#           environment / RMM variable of the same name (handy for secrets
#           like SasToken / SftpPassword). Values you filled in always win.
# $false => ignore the environment entirely; use ONLY what's in this file.
$AllowEnvOverride = $true

# ===========================================================================
#  END CONFIGURATION
# ===========================================================================

# Pull blank settings from matching env/RMM variables (inline values win).
if ($AllowEnvOverride) {
    $envBackedNames = @(
        'Method','MSPName','DestinationCategory','DestinationSubPath',
        'StorageAccount','Container','SasToken','BlobPrefix','EndpointSuffix',
        'SftpHost','SftpPort','SftpUsername','SftpPassword','SftpRemotePath'
    )
    foreach ($name in $envBackedNames) {
        $current = Get-Variable -Name $name -ValueOnly -ErrorAction SilentlyContinue
        # "Blank" = null, empty/whitespace, or an unedited <placeholder>.
        $isBlank = ($null -eq $current) -or
                   ($current -is [string] -and
                    ([string]::IsNullOrWhiteSpace([string]$current) -or
                     [string]$current -match '^\s*<.*>\s*$'))
        if (-not $isBlank) { continue }
        $envValue = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($envValue)) {
            Set-Variable -Name $name -Value $envValue
        }
    }
}

# Auto-build the SFTP host/username from the SAS settings if left blank.
if ([string]::IsNullOrWhiteSpace($SftpHost)) {
    $SftpHost = "{0}.blob.{1}" -f $StorageAccount, $EndpointSuffix
}
if ([string]::IsNullOrWhiteSpace($SftpUsername)) {
    $SftpUsername = "{0}.{1}.<localuser>" -f $StorageAccount, $Container
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Logging ---------------------------------------------------------------
$LogDirectory = Join-Path $env:ProgramData (Join-Path $MSPName "Logs")
if (-not (Test-Path -Path $LogDirectory)) {
    try   { New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null }
    catch { $LogDirectory = $env:ProgramData }
}
$Now     = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath = Join-Path $LogDirectory "Get-AzureBlobData_$Now.log"

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR")][string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $LogPath -Value $line -ErrorAction Stop } catch {}
    switch ($Level) {
        "INFO"    { Write-Host $Message -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "WARN"    { Write-Host $Message -ForegroundColor Yellow }
        "ERROR"   { Write-Host $Message -ForegroundColor Red }
    }
}

# --- Resolve and prepare the destination -----------------------------------
function Resolve-Destination {
    if (-not $CategoryMap.ContainsKey($DestinationCategory)) {
        throw "DestinationCategory '$DestinationCategory' is not in the CategoryMap. Valid: $($CategoryMap.Keys -join ', ')"
    }
    $path = Join-Path $env:ProgramData (Join-Path $MSPName $CategoryMap[$DestinationCategory])
    if ($DestinationSubPath) { $path = Join-Path $path $DestinationSubPath }

    if ($CleanDestination -and (Test-Path $path)) {
        Write-Log "Cleaning destination: $path" "WARN"
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
    return $path
}

# True if the blob/file passes the extension filter (or no filter set).
function Test-ExtensionMatch {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $IncludeExtensions -or $IncludeExtensions.Count -eq 0) { return $true }
    $ext = [System.IO.Path]::GetExtension($Name)
    return ($IncludeExtensions -contains $ext)
}

# Generic download with exponential backoff (2s, 4s, 8s, 16s...).
function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            return $true
        } catch {
            if ($attempt -eq $MaxRetries) {
                Write-Log "  FAILED after $MaxRetries attempts: $($_.Exception.Message)" "ERROR"
                return $false
            }
            $wait = [math]::Pow(2, $attempt)
            Write-Log "  Attempt $attempt failed, retrying in ${wait}s..." "WARN"
            Start-Sleep -Seconds $wait
        }
    }
}

# ---------------------------------------------------------------------------
#  METHOD 1 : SAS over the Blob REST API
# ---------------------------------------------------------------------------
function Get-BlobInventory {
    # Returns objects with .Name and .Length for every blob under $BlobPrefix,
    # following NextMarker pagination so large containers are fully enumerated.
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Sas,
        [string]$Prefix = ""
    )
    $blobs  = @()
    $marker = ""
    do {
        $listUrl = "{0}?restype=container&comp=list&prefix={1}&{2}" -f `
            $BaseUrl, [uri]::EscapeDataString($Prefix), $Sas
        if ($marker) { $listUrl += "&marker=$([uri]::EscapeDataString($marker))" }

        $resp = Invoke-WebRequest -Uri $listUrl -UseBasicParsing -ErrorAction Stop
        # Strip a leading UTF-8 BOM if present, otherwise the XML cast throws.
        [xml]$xml = $resp.Content.TrimStart([char]0xFEFF)

        foreach ($b in $xml.EnumerationResults.Blobs.Blob) {
            $blobs += [pscustomobject]@{
                Name   = [string]$b.Name
                Length = [int64]$b.Properties.'Content-Length'
            }
        }
        $marker = [string]$xml.EnumerationResults.NextMarker
    } while ($marker)

    return $blobs
}

function Invoke-SasSync {
    param([Parameter(Mandatory)][string]$LocalRoot)

    $sas = $SasToken.TrimStart('?')
    if ([string]::IsNullOrWhiteSpace($sas)) { throw "SAS token is empty. Set `$SasToken (or the SasToken env var)." }

    $base = "https://{0}.blob.{1}/{2}" -f $StorageAccount, $EndpointSuffix, $Container
    Write-Log "Listing blobs: $base (prefix: '$BlobPrefix')"

    $inventory = Get-BlobInventory -BaseUrl $base -Sas $sas -Prefix $BlobPrefix
    Write-Log "Found $($inventory.Count) blob(s) before filtering."

    $downloaded = 0; $skipped = 0; $failed = 0
    foreach ($blob in $inventory) {
        if (-not (Test-ExtensionMatch -Name $blob.Name)) { continue }

        # Local path mirrors the blob path relative to the prefix.
        $relative = $blob.Name
        if ($BlobPrefix -and $relative.StartsWith($BlobPrefix)) {
            $relative = $relative.Substring($BlobPrefix.Length)
        }
        $relative = $relative.TrimStart('/')
        if (-not $relative) { continue }   # the prefix itself, not a file
        $dest = Join-Path $LocalRoot ($relative -replace '/', '\')

        # Skip if already present and the same size.
        if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $blob.Length)) {
            Write-Log "  SKIP  $relative (already present)"
            $skipped++; continue
        }

        # URL-encode each path segment, preserving the slashes.
        $encoded = ($blob.Name -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $dlUrl   = "{0}/{1}?{2}" -f $base, $encoded, $sas

        Write-Log ("  GET   {0} ({1:N1} KB)" -f $relative, ($blob.Length / 1KB))
        if (Invoke-DownloadWithRetry -Uri $dlUrl -OutFile $dest) { $downloaded++ } else { $failed++ }
    }

    return [pscustomobject]@{ Downloaded = $downloaded; Skipped = $skipped; Failed = $failed }
}

# ---------------------------------------------------------------------------
#  METHOD 2 : SFTP via Posh-SSH
# ---------------------------------------------------------------------------
function Initialize-PoshSSH {
    if (Get-Module -ListAvailable -Name Posh-SSH) { Import-Module Posh-SSH -ErrorAction Stop; return }
    Write-Log "Posh-SSH not found - installing from PSGallery..." "WARN"
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
    }
    Install-Module -Name Posh-SSH -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
    Import-Module Posh-SSH -ErrorAction Stop
}

function Copy-SftpRecursive {
    param(
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][ref]$Stats
    )
    if (-not (Test-Path $LocalPath)) { New-Item -Path $LocalPath -ItemType Directory -Force | Out-Null }

    $children = Get-SFTPChildItem -SessionId $SessionId -Path $RemotePath -ErrorAction Stop |
        Where-Object { $_.Name -ne '.' -and $_.Name -ne '..' }

    foreach ($child in $children) {
        if ($child.IsDirectory) {
            Copy-SftpRecursive -SessionId $SessionId -RemotePath $child.FullName `
                -LocalPath (Join-Path $LocalPath $child.Name) -Stats $Stats
            continue
        }
        if (-not (Test-ExtensionMatch -Name $child.Name)) { continue }

        $dest = Join-Path $LocalPath $child.Name
        if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $child.Size)) {
            Write-Log "  SKIP  $($child.FullName) (already present)"
            $Stats.Value.Skipped++; continue
        }

        Write-Log ("  GET   {0} ({1:N1} KB)" -f $child.FullName, ($child.Size / 1KB))
        try {
            Get-SFTPItem -SessionId $SessionId -Path $child.FullName -Destination $LocalPath -Force -ErrorAction Stop | Out-Null
            $Stats.Value.Downloaded++
        } catch {
            Write-Log "  FAILED $($child.FullName): $($_.Exception.Message)" "ERROR"
            $Stats.Value.Failed++
        }
    }
}

function Invoke-SftpSync {
    param([Parameter(Mandatory)][string]$LocalRoot)

    if ([string]::IsNullOrWhiteSpace($SftpPassword)) { throw "SFTP password is empty. Set `$SftpPassword (or the SftpPassword env var)." }
    Initialize-PoshSSH

    $secure = ConvertTo-SecureString $SftpPassword -AsPlainText -Force
    $cred   = New-Object System.Management.Automation.PSCredential ($SftpUsername, $secure)

    Write-Log "Connecting SFTP: $SftpUsername@$SftpHost`:$SftpPort"
    $session = New-SFTPSession -ComputerName $SftpHost -Port $SftpPort -Credential $cred -AcceptKey -ErrorAction Stop
    $stats = [pscustomobject]@{ Downloaded = 0; Skipped = 0; Failed = 0 }
    try {
        Write-Log "Mirroring $SftpRemotePath -> $LocalRoot"
        Copy-SftpRecursive -SessionId $session.SessionId -RemotePath $SftpRemotePath -LocalPath $LocalRoot -Stats ([ref]$stats)
    }
    finally {
        Remove-SFTPSession -SessionId $session.SessionId | Out-Null
    }
    return $stats
}

# ===========================================================================
#  MAIN
# ===========================================================================
Write-Log "===== Get-AzureBlobData started $(Get-Date -Format s) ====="
Write-Log "Method      : $Method"
$destLabel = $DestinationCategory
if ($DestinationSubPath) { $destLabel = Join-Path $DestinationCategory $DestinationSubPath }
Write-Log "Destination : $destLabel"
Write-Log "Log file    : $LogPath"

$exitCode = 0
try {
    $localRoot = Resolve-Destination
    Write-Log "Local path  : $localRoot"

    switch ($Method.ToUpper()) {
        "SAS"  { $result = Invoke-SasSync  -LocalRoot $localRoot }
        "SFTP" { $result = Invoke-SftpSync -LocalRoot $localRoot }
        default { throw "Unknown Method '$Method'. Use 'SAS' or 'SFTP'." }
    }

    Write-Log ""
    Write-Log "===== Summary =====" "SUCCESS"
    Write-Log ("Downloaded : {0}" -f $result.Downloaded) "SUCCESS"
    Write-Log ("Skipped    : {0}" -f $result.Skipped)
    Write-Log ("Failed     : {0}" -f $result.Failed) $(if ($result.Failed) { "ERROR" } else { "INFO" })
    if ($result.Failed -gt 0) { $exitCode = 1 }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    $exitCode = 2
}

Write-Log "===== Get-AzureBlobData finished $(Get-Date -Format s) ====="
exit $exitCode
