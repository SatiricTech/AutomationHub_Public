#Requires -Version 7.0

<#
.SYNOPSIS
    Builds a migration-tool user mapping file (source address -> target
    address) from a user CSV export.

.DESCRIPTION
    Reads one or MORE user CSVs - e.g. the M365Users and SharedMailboxes CSVs
    produced by Get-MigrationInventory, or any CSV with a UPN/email column -
    and writes a single mapping file in the selected migration tool's format,
    so users and shared mailboxes land in one upload. No tenant connection is
    needed; this is a pure file transform, so it is safe to run and re-run
    anywhere.

    Columns are detected per file. The source address prefers the primary SMTP
    column (PrimarySmtpAddress / PrimaryEmail / Email / Mail) and falls back to
    UPN per row - for shared mailboxes the UPN is often a meaningless
    onmicrosoft account, while the SMTP address is what the migration tool
    matches on.

    The target address for each row is decided in this order:
      1. A Target column in the CSV (TargetUserPrincipalName / TargetUPN /
         TargetEmail / Target), if present and populated for that row - this
         lets you hand-craft exceptions.
      2. Otherwise the source local part + -TargetDomain
         (jsmith@old.com -> jsmith@new.com).
    If -TargetDomain is omitted and any row lacks a Target value, you are
    prompted for the domain.

    Tool formats live in ONE registry ($script:ToolFormats) near the top of the
    script. Each entry declares the output file name/type and how a
    source/target pair becomes an output row (the row object's property names
    become the header row). To support another tool - BitTitan, ShareGate,
    Quest, ... - add one entry there; -Tool is validated against the registry
    at runtime, so nothing else needs to change.

    The built-in AvePoint format reproduces AvePoint's own Fly_User_Mapping
    template: an .xlsx workbook, sheet 'Migration mappings', columns
    'Source user/group' and 'Destination user/group'.

    Rows without a usable source address are reported and skipped; duplicate
    source addresses keep the first occurrence.

.PARAMETER CsvPath
    One or more CSVs to build the mapping from. All rows are combined into a
    single mapping file; duplicate source addresses keep the first occurrence.

.PARAMETER Tool
    Which migration tool's format to write. Default 'AvePoint'. Valid values
    are the keys of the format registry inside the script.

.PARAMETER TargetDomain
    Domain for the target side of each mapping (accepts 'contoso.com' or
    '@contoso.com'). Optional when every row has a Target column value.

.PARAMETER OutputPath
    Directory where the mapping file is written. If omitted, defaults to
    "<LocalAppData>\Migration-Automations" after confirming with you.

.PARAMETER DryRun
    Preview only - resolve everything and print the planned output file plus
    the first few mappings, then exit without writing.

.EXAMPLE
    .\New-MigrationUserMapping.ps1 -CsvPath .\Source_M365Users.csv -TargetDomain newcompany.com -DryRun

.EXAMPLE
    .\New-MigrationUserMapping.ps1 -CsvPath .\Source_M365Users.csv, .\Source_SharedMailboxes.csv -TargetDomain newcompany.com

    Users and shared mailboxes combined into one AvePoint mapping workbook.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7. No tenant connection. ImportExcel is
                  auto-installed for formats that write .xlsx (AvePoint).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$Tool = 'AvePoint',

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^@?[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$')]
    [string]$TargetDomain,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

#region Tool format registry ----------------------------------------------------

# One entry per migration tool. Adding a tool here is the ONLY change needed to
# support it - the key becomes a valid -Tool value automatically.
#   Description   : shown in errors and the run banner.
#   FileName      : output file name; '{timestamp}' is replaced at runtime.
#   FileType      : 'Csv' (default) or 'Xlsx'. Xlsx needs the ImportExcel
#                   module, auto-installed on first use.
#   WorksheetName : Xlsx only - the sheet name the tool expects.
#   NewRow        : scriptblock turning one (Source, Target) pair into one
#                   output row; the object's property names become the header
#                   row, so match the tool's template exactly.
$script:ToolFormats = [ordered]@{
    # Matches AvePoint's Fly_User_Mapping.xlsx template: one sheet named
    # 'Migration mappings', columns 'Source user/group' / 'Destination user/group'.
    AvePoint = @{
        Description   = "AvePoint Fly user mapping workbook ('Source user/group' -> 'Destination user/group')"
        FileName      = 'Fly_User_Mapping_{timestamp}.xlsx'
        FileType      = 'Xlsx'
        WorksheetName = 'Migration mappings'
        NewRow        = {
            param($Source, $Target)
            [pscustomobject][ordered]@{
                'Source user/group'      = $Source
                'Destination user/group' = $Target
            }
        }
    }
    # To add another tool, copy the shape above, e.g.:
    # BitTitan = @{
    #     Description = 'BitTitan MigrationWiz recipient mapping CSV'
    #     FileName    = 'BitTitan-RecipientMapping_{timestamp}.csv'
    #     NewRow      = {
    #         param($Source, $Target)
    #         [pscustomobject][ordered]@{ 'Source Email Address' = $Source; 'Destination Email Address' = $Target }
    #     }
    # }
}

#endregion ---------------------------------------------------------------------

#region Shared helpers ---------------------------------------------------------

function Resolve-MigrationOutputDirectory {
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        $resolved = $Path
    }
    else {
        $appData = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($appData)) {
            $appData = [Environment]::GetFolderPath('LocalApplicationData')
        }
        if ([string]::IsNullOrWhiteSpace($appData)) {
            $appData = Join-Path -Path $HOME -ChildPath '.local/share'
        }
        $resolved = Join-Path -Path $appData -ChildPath 'Migration-Automations'

        Write-Host ''
        Write-Host 'No -OutputPath was provided.' -ForegroundColor Yellow
        Write-Host "Default output location: $resolved" -ForegroundColor Cyan

        while ($true) {
            $answer = (Read-Host 'Use this location? [Y] Yes  [N] Choose another') ?? ''
            $answer = $answer.Trim()
            if ($answer -match '^(y|yes|)$') {
                break
            }
            elseif ($answer -match '^(n|no)$') {
                $custom = (Read-Host 'Enter the full path to use for output') ?? ''
                if (-not [string]::IsNullOrWhiteSpace($custom)) {
                    $resolved = $custom.Trim()
                    Write-Host "Output location set to: $resolved" -ForegroundColor Cyan
                    break
                }
                Write-Host 'No path entered - please try again.' -ForegroundColor Red
            }
            else {
                Write-Host 'Please answer Y or N.' -ForegroundColor Red
            }
        }
    }

    if (-not (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
        Write-Host "Created output directory: $resolved" -ForegroundColor Green
    }

    return (Resolve-Path -LiteralPath $resolved).Path
}

function Initialize-RequiredModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [version]$MinimumVersion
    )
    $available = Get-Module -ListAvailable -Name $Name
    if ($MinimumVersion) { $available = $available | Where-Object { $_.Version -ge $MinimumVersion } }
    if ($available) { return }
    Write-Host "Installing required module '$Name' (CurrentUser scope)..." -ForegroundColor Yellow
    Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
}

function Resolve-ColumnName {
    param([string[]]$Headers, [string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        $hit = $Headers | Where-Object { $_ -ieq $candidate } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-CsvValue {
    param($Record, [string]$Column)
    if (-not $Column) { return $null }
    $value = $Record.$Column
    if ($null -eq $value) { return $null }
    $text = ([string]$value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

#endregion ---------------------------------------------------------------------

Write-Host '=== Migration User Mapping File ===' -ForegroundColor Cyan

if (-not $script:ToolFormats.Contains($Tool)) {
    throw "Unknown tool '$Tool'. Supported: $($script:ToolFormats.Keys -join ', '). Add new formats to `$script:ToolFormats inside this script."
}
$format = $script:ToolFormats[$Tool]
Write-Host "Format: $($format.Description)" -ForegroundColor Cyan

# Load every CSV and normalise to (Source, TargetOverride) pairs. Columns are
# detected per file so differently-shaped exports can feed one mapping file.
$pairs = [System.Collections.Generic.List[object]]::new()
foreach ($file in $CsvPath) {
    if (-not (Test-Path -LiteralPath $file)) { throw "CSV not found: $file" }
    $fileName = [System.IO.Path]::GetFileName($file)
    $rows = @(Import-Csv -LiteralPath $file)
    if ($rows.Count -eq 0) {
        Write-Host "'$fileName' contains no rows - skipping." -ForegroundColor Yellow
        continue
    }

    $headers = $rows[0].PSObject.Properties.Name
    # Primary SMTP is preferred over UPN: for shared mailboxes the UPN is often
    # a meaningless onmicrosoft account, and migration tools match on SMTP.
    $primaryColumn = Resolve-ColumnName -Headers $headers -Candidates @(
        'PrimarySmtpAddress', 'PrimaryEmail', 'Email', 'Mail', 'EmailAddress')
    $upnColumn = Resolve-ColumnName -Headers $headers -Candidates @(
        'UserPrincipalName', 'UPN', 'User Principal Name')
    $targetColumn = Resolve-ColumnName -Headers $headers -Candidates @(
        'TargetUserPrincipalName', 'TargetUPN', 'TargetEmail', 'Target')

    if (-not $primaryColumn -and -not $upnColumn) {
        throw "Could not find a UPN/email column in '$file'. Headers: $($headers -join ', ')"
    }
    $columnNote = (@($primaryColumn, $upnColumn) | Where-Object { $_ }) -join "', falling back to '"
    Write-Host "${fileName}: source addresses from '$columnNote'" -ForegroundColor Cyan
    if ($targetColumn) {
        Write-Host "${fileName}: per-row target overrides from '$targetColumn'" -ForegroundColor Cyan
    }

    foreach ($row in $rows) {
        $pairs.Add([pscustomobject]@{
            Source         = (Get-CsvValue -Record $row -Column $primaryColumn) ?? (Get-CsvValue -Record $row -Column $upnColumn)
            TargetOverride = Get-CsvValue -Record $row -Column $targetColumn
        })
    }
}
if ($pairs.Count -eq 0) { throw 'No rows found in the supplied CSV file(s).' }

# The domain is only required for rows without a per-row target override.
$normalizedDomain = $null
if ($TargetDomain) {
    $normalizedDomain = $TargetDomain.TrimStart('@').Trim().ToLowerInvariant()
}
elseif ($pairs | Where-Object { -not $_.TargetOverride } | Select-Object -First 1) {
    while (-not $normalizedDomain) {
        $answer = ((Read-Host 'Target domain for the mapping (e.g. contoso.com)') ?? '').Trim().TrimStart('@').ToLowerInvariant()
        if ($answer -match '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$') { $normalizedDomain = $answer }
        else { Write-Host 'That does not look like a domain - please try again.' -ForegroundColor Red }
    }
}
if ($normalizedDomain) {
    Write-Host "Target addresses will use '@$normalizedDomain'." -ForegroundColor Cyan
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$mappingPath = Join-Path -Path $outputDir -ChildPath ($format.FileName -replace '\{timestamp\}', $timestamp)

# Build the mappings.
$mappings = [System.Collections.Generic.List[object]]::new()
$seenSources = [System.Collections.Generic.HashSet[string]]::new()
$skipped = 0
$duplicates = 0

foreach ($pair in $pairs) {
    $source = $pair.Source
    if (-not $source -or $source -notmatch '@') {
        $skipped++
        continue
    }
    if (-not $seenSources.Add($source.ToLowerInvariant())) {
        $duplicates++
        continue
    }

    $target = $pair.TargetOverride
    if (-not $target) {
        if (-not $normalizedDomain) {
            $skipped++
            Write-Host "  [Skipped] $source - no target value and no -TargetDomain to fall back on." -ForegroundColor Yellow
            continue
        }
        $target = '{0}@{1}' -f ($source -split '@')[0], $normalizedDomain
    }

    $mappings.Add((& $format.NewRow $source $target))
}

if ($mappings.Count -eq 0) { throw 'No usable rows - nothing to map.' }

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN - no file will be written.' -ForegroundColor Magenta
    Write-Host "Would write $($mappings.Count) mapping(s) to:" -ForegroundColor Magenta
    Write-Host "  $mappingPath" -ForegroundColor Magenta
    Write-Host 'First mappings:' -ForegroundColor Magenta
    $mappings | Select-Object -First 5 | Format-Table -AutoSize | Out-String |
        ForEach-Object { Write-Host $_.TrimEnd() -ForegroundColor Magenta }
    if ($skipped) { Write-Host "Rows skipped (no usable source/target): $skipped" -ForegroundColor Yellow }
    if ($duplicates) { Write-Host "Duplicate source addresses ignored: $duplicates" -ForegroundColor Yellow }
    return
}

if ($format.FileType -eq 'Xlsx') {
    # ImportExcel releases before 7.1 fail to load on current PowerShell 7.
    Initialize-RequiredModule -Name 'ImportExcel' -MinimumVersion '7.1.0'
    Import-Module ImportExcel -MinimumVersion '7.1.0'
    if (Test-Path -LiteralPath $mappingPath) { Remove-Item -LiteralPath $mappingPath -Force }
    $mappings | Export-Excel -Path $mappingPath -WorksheetName $format.WorksheetName
}
else {
    $mappings | Export-Csv -Path $mappingPath -NoTypeInformation -Encoding UTF8
}

Write-Host ''
Write-Host "Mapping file written: $mappingPath" -ForegroundColor Green
Write-Host "  Mappings : $($mappings.Count)" -ForegroundColor Cyan
if ($skipped) { Write-Host "  Skipped  : $skipped row(s) without a usable source/target address" -ForegroundColor Yellow }
if ($duplicates) { Write-Host "  Duplicates ignored: $duplicates" -ForegroundColor Yellow }
Write-Host 'Done.' -ForegroundColor Green
