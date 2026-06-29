#Requires -Version 7.0

<#
.SYNOPSIS
    Compares two user-data CSVs (e.g. source-tenant vs destination-tenant
    exports) and reports which users are the same or similar.

.DESCRIPTION
    Reads a reference CSV and a difference CSV and, for every user in the
    reference CSV, finds the best-matching user in the difference CSV. It writes
    one row per reference user to an output CSV with:

      - Status   : 'Exact Match', 'Partial Match' or 'No Match'
      - MatchedOn: the criteria that matched (UPN, Email, DisplayName,
                   FirstName+LastName, EmailLocalPart, SimilarName)
      - The matched target user's identity columns alongside the source's

    Matching is column-name aware: it auto-detects common headers (UPN /
    UserPrincipalName, Email / PrimaryEmail / Mail, FirstName / GivenName,
    LastName / Surname, DisplayName) so it works with exports from this toolkit
    or most migration tools. You can override any column name with parameters.

    Match logic:
      - Exact Match  : UPN equal OR primary email equal.
      - Partial Match: display name equal, first+last equal, email local-part
                       equal, or a close (fuzzy) display-name similarity.
      - No Match     : nothing above the similarity threshold.

    This script is fully local - it reads and writes CSVs only.

.PARAMETER ReferenceCsv
    Path to the first CSV (the "source" / left side).

.PARAMETER DifferenceCsv
    Path to the second CSV (the "target" / right side) to match against.

.PARAMETER OutputPath
    Directory where the comparison CSV is written. If omitted, defaults to
    "<LocalAppData>\Migration-Automations" after confirming with you.

.PARAMETER SimilarityThreshold
    Display-name similarity (0.0 - 1.0) at/above which two non-identical names
    are treated as a "SimilarName" partial match. Default 0.85.

.PARAMETER UpnColumn
.PARAMETER EmailColumn
.PARAMETER FirstNameColumn
.PARAMETER LastNameColumn
.PARAMETER DisplayNameColumn
    Optional explicit column-name overrides if auto-detection picks the wrong
    header for either CSV.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -ReferenceCsv .\Source.csv -DifferenceCsv .\Target.csv

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -ReferenceCsv .\A.csv -DifferenceCsv .\B.csv `
        -OutputPath C:\Migrations -SimilarityThreshold 0.9

.NOTES
    Author   : AutomationHub
    Requires : PowerShell 7
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReferenceCsv,

    [Parameter(Mandatory = $true)]
    [string]$DifferenceCsv,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0.0, 1.0)]
    [double]$SimilarityThreshold = 0.85,

    [Parameter(Mandatory = $false)]
    [string]$UpnColumn,

    [Parameter(Mandatory = $false)]
    [string]$EmailColumn,

    [Parameter(Mandatory = $false)]
    [string]$FirstNameColumn,

    [Parameter(Mandatory = $false)]
    [string]$LastNameColumn,

    [Parameter(Mandatory = $false)]
    [string]$DisplayNameColumn
)

$ErrorActionPreference = 'Stop'

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

#endregion ---------------------------------------------------------------------

function Resolve-ColumnName {
    <# Returns the actual header in $headers that matches one of $candidates (case-insensitive). #>
    param(
        [string[]]$Headers,
        [string[]]$Candidates,
        [string]$Override
    )
    if ($Override) {
        $hit = $Headers | Where-Object { $_ -ieq $Override } | Select-Object -First 1
        if ($hit) { return $hit }
        Write-Warning "Override column '$Override' not found; falling back to auto-detect."
    }
    foreach ($candidate in $Candidates) {
        $hit = $Headers | Where-Object { $_ -ieq $candidate } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-NormalizedValue {
    param($Record, [string]$Column)
    if (-not $Column) { return '' }
    $value = $Record.$Column
    if ($null -eq $value) { return '' }
    return ([string]$value).Trim().ToLowerInvariant()
}

function Get-StringSimilarity {
    <# Returns 0.0 - 1.0 similarity based on Levenshtein distance. #>
    param([string]$A, [string]$B)
    if ([string]::IsNullOrEmpty($A) -and [string]::IsNullOrEmpty($B)) { return 0.0 }
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return 0.0 }
    if ($A -eq $B) { return 1.0 }

    $lenA = $A.Length
    $lenB = $B.Length
    $d = [int[,]]::new(($lenA + 1), ($lenB + 1))
    for ($i = 0; $i -le $lenA; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $lenB; $j++) { $d[0, $j] = $j }

    for ($i = 1; $i -le $lenA; $i++) {
        for ($j = 1; $j -le $lenB; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $d[$i, $j] = [math]::Min([math]::Min($d[($i - 1), $j] + 1, $d[$i, ($j - 1)] + 1), $d[($i - 1), ($j - 1)] + $cost)
        }
    }
    $distance = $d[$lenA, $lenB]
    $maxLen = [math]::Max($lenA, $lenB)
    return [math]::Round(1.0 - ($distance / $maxLen), 4)
}

function Get-EmailLocalPart {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email)) { return '' }
    return ($Email -split '@')[0]
}

# --- Begin ---------------------------------------------------------------------

Write-Host '=== Migration User Data Comparison ===' -ForegroundColor Cyan

foreach ($p in @($ReferenceCsv, $DifferenceCsv)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "CSV not found: $p"
    }
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = Join-Path -Path $outputDir -ChildPath "User-Comparison_$timestamp.csv"

$reference = @(Import-Csv -LiteralPath $ReferenceCsv)
$difference = @(Import-Csv -LiteralPath $DifferenceCsv)

if ($reference.Count -eq 0) { throw "Reference CSV '$ReferenceCsv' contains no rows." }
if ($difference.Count -eq 0) { throw "Difference CSV '$DifferenceCsv' contains no rows." }

$refHeaders = $reference[0].PSObject.Properties.Name
$difHeaders = $difference[0].PSObject.Properties.Name

# Resolve columns on each side independently.
$cols = @{
    RefUpn   = Resolve-ColumnName -Headers $refHeaders -Candidates @('UserPrincipalName', 'UPN', 'User Principal Name') -Override $UpnColumn
    RefEmail = Resolve-ColumnName -Headers $refHeaders -Candidates @('PrimaryEmail', 'Email', 'Mail', 'PrimarySmtpAddress', 'EmailAddress', 'Primary Email Address') -Override $EmailColumn
    RefFirst = Resolve-ColumnName -Headers $refHeaders -Candidates @('FirstName', 'GivenName', 'First Name') -Override $FirstNameColumn
    RefLast  = Resolve-ColumnName -Headers $refHeaders -Candidates @('LastName', 'Surname', 'Last Name') -Override $LastNameColumn
    RefName  = Resolve-ColumnName -Headers $refHeaders -Candidates @('DisplayName', 'Display Name', 'Name') -Override $DisplayNameColumn
    DifUpn   = Resolve-ColumnName -Headers $difHeaders -Candidates @('UserPrincipalName', 'UPN', 'User Principal Name') -Override $UpnColumn
    DifEmail = Resolve-ColumnName -Headers $difHeaders -Candidates @('PrimaryEmail', 'Email', 'Mail', 'PrimarySmtpAddress', 'EmailAddress', 'Primary Email Address') -Override $EmailColumn
    DifFirst = Resolve-ColumnName -Headers $difHeaders -Candidates @('FirstName', 'GivenName', 'First Name') -Override $FirstNameColumn
    DifLast  = Resolve-ColumnName -Headers $difHeaders -Candidates @('LastName', 'Surname', 'Last Name') -Override $LastNameColumn
    DifName  = Resolve-ColumnName -Headers $difHeaders -Candidates @('DisplayName', 'Display Name', 'Name') -Override $DisplayNameColumn
}

Write-Host 'Detected columns:' -ForegroundColor Cyan
Write-Host ("  Reference -> UPN:{0} Email:{1} First:{2} Last:{3} Name:{4}" -f $cols.RefUpn, $cols.RefEmail, $cols.RefFirst, $cols.RefLast, $cols.RefName)
Write-Host ("  Difference-> UPN:{0} Email:{1} First:{2} Last:{3} Name:{4}" -f $cols.DifUpn, $cols.DifEmail, $cols.DifFirst, $cols.DifLast, $cols.DifName)

# Pre-normalize the difference set once.
$difIndex = foreach ($d in $difference) {
    [pscustomobject]@{
        Record    = $d
        Upn       = Get-NormalizedValue -Record $d -Column $cols.DifUpn
        Email     = Get-NormalizedValue -Record $d -Column $cols.DifEmail
        First     = Get-NormalizedValue -Record $d -Column $cols.DifFirst
        LastName  = Get-NormalizedValue -Record $d -Column $cols.DifLast
        Name      = Get-NormalizedValue -Record $d -Column $cols.DifName
    }
}

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($ref in $reference) {
    $index++
    Write-Progress -Activity 'Comparing users' `
        -Status "$index of $($reference.Count)" `
        -PercentComplete (($index / [math]::Max($reference.Count, 1)) * 100)

    $rUpn = Get-NormalizedValue -Record $ref -Column $cols.RefUpn
    $rEmail = Get-NormalizedValue -Record $ref -Column $cols.RefEmail
    $rFirst = Get-NormalizedValue -Record $ref -Column $cols.RefFirst
    $rLast = Get-NormalizedValue -Record $ref -Column $cols.RefLast
    $rName = Get-NormalizedValue -Record $ref -Column $cols.RefName
    $rLocal = Get-EmailLocalPart -Email $rEmail

    $bestScore = -1
    $bestMatch = $null
    $bestCriteria = @()
    $bestStatus = 'No Match'

    foreach ($dif in $difIndex) {
        $criteria = [System.Collections.Generic.List[string]]::new()
        $score = 0
        $isExact = $false

        if ($rUpn -and $dif.Upn -and $rUpn -eq $dif.Upn) {
            $criteria.Add('UPN'); $score += 100; $isExact = $true
        }
        if ($rEmail -and $dif.Email -and $rEmail -eq $dif.Email) {
            $criteria.Add('Email'); $score += 100; $isExact = $true
        }
        if ($rName -and $dif.Name -and $rName -eq $dif.Name) {
            $criteria.Add('DisplayName'); $score += 40
        }
        if ($rFirst -and $rLast -and $dif.First -and $dif.LastName -and
            $rFirst -eq $dif.First -and $rLast -eq $dif.LastName) {
            $criteria.Add('FirstName+LastName'); $score += 40
        }
        if ($rLocal -and (Get-EmailLocalPart -Email $dif.Email) -and
            $rLocal -eq (Get-EmailLocalPart -Email $dif.Email)) {
            $criteria.Add('EmailLocalPart'); $score += 25
        }

        # Fuzzy display-name similarity (only worth checking if not already exact).
        if (-not $isExact -and $rName -and $dif.Name) {
            $sim = Get-StringSimilarity -A $rName -B $dif.Name
            if ($sim -ge $SimilarityThreshold) {
                $criteria.Add("SimilarName($sim)"); $score += [int]($sim * 20)
            }
        }

        if ($score -gt $bestScore -and $criteria.Count -gt 0) {
            $bestScore = $score
            $bestMatch = $dif.Record
            $bestCriteria = $criteria.ToArray()
            $bestStatus = if ($isExact) { 'Exact Match' } else { 'Partial Match' }
        }
    }

    $results.Add([pscustomobject][ordered]@{
        Status                = $bestStatus
        MatchedOn             = ($bestCriteria -join '; ')
        MatchScore            = if ($bestScore -lt 0) { 0 } else { $bestScore }
        Source_DisplayName    = if ($cols.RefName) { $ref.$($cols.RefName) } else { '' }
        Source_UPN            = if ($cols.RefUpn) { $ref.$($cols.RefUpn) } else { '' }
        Source_Email          = if ($cols.RefEmail) { $ref.$($cols.RefEmail) } else { '' }
        Source_FirstName      = if ($cols.RefFirst) { $ref.$($cols.RefFirst) } else { '' }
        Source_LastName       = if ($cols.RefLast) { $ref.$($cols.RefLast) } else { '' }
        Target_DisplayName    = if ($bestMatch -and $cols.DifName) { $bestMatch.$($cols.DifName) } else { '' }
        Target_UPN            = if ($bestMatch -and $cols.DifUpn) { $bestMatch.$($cols.DifUpn) } else { '' }
        Target_Email          = if ($bestMatch -and $cols.DifEmail) { $bestMatch.$($cols.DifEmail) } else { '' }
        Target_FirstName      = if ($bestMatch -and $cols.DifFirst) { $bestMatch.$($cols.DifFirst) } else { '' }
        Target_LastName       = if ($bestMatch -and $cols.DifLast) { $bestMatch.$($cols.DifLast) } else { '' }
    })
}

Write-Progress -Activity 'Comparing users' -Completed

$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$exact = ($results | Where-Object Status -eq 'Exact Match').Count
$partial = ($results | Where-Object Status -eq 'Partial Match').Count
$none = ($results | Where-Object Status -eq 'No Match').Count

Write-Host ''
Write-Host "Compared $($reference.Count) reference user(s) against $($difference.Count) target user(s)." -ForegroundColor Green
Write-Host "  Exact Match  : $exact" -ForegroundColor Green
Write-Host "  Partial Match: $partial" -ForegroundColor Yellow
Write-Host "  No Match     : $none" -ForegroundColor Red
Write-Host "Output: $csvPath" -ForegroundColor Cyan
Write-Host 'Done.' -ForegroundColor Green
