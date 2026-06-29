#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Bulk-creates Microsoft 365 (Entra ID) user accounts from a CSV mapping file.

.DESCRIPTION
    Connects to Microsoft Graph (interactive sign-in) and creates one cloud user
    per row in the supplied CSV. Column headers are auto-detected so exports from
    this toolkit or most migration tools work directly.

    Recognised columns (first match wins, case-insensitive):
      - UserPrincipalName / UPN                      (required)
      - DisplayName / Display Name / Name            (required; built from
                                                       first+last if absent)
      - FirstName / GivenName
      - LastName / Surname
      - MailNickname / Alias                         (defaults to UPN local part)
      - Password                                     (generated if absent)
      - UsageLocation                                (defaults to -DefaultUsageLocation)
      - JobTitle, Department, Office/OfficeLocation,
        MobilePhone, City, State, Country

    For each row a result is recorded (Created / Skipped / Failed) and, where a
    password was generated, it is written to a results CSV so you can distribute
    initial credentials. Existing users (same UPN) are skipped, not modified.

    Supports -WhatIf / -Confirm so you can preview exactly what would be created.

.PARAMETER CsvPath
    Path to the CSV describing the users to create.

.PARAMETER OutputPath
    Directory where the results CSV (including any generated passwords) is
    written. If omitted, defaults to "<AppData>\Migration-Automations" after
    confirming with you.

.PARAMETER DefaultUsageLocation
    Two-letter usage location applied when a row has none (required before
    licensing). Default 'US'.

.PARAMETER ForceChangePassword
    Require the user to change their password at next sign-in. Default $true.

.EXAMPLE
    .\New-MigrationUsers.ps1 -CsvPath .\NewUsers.csv -WhatIf

.EXAMPLE
    .\New-MigrationUsers.ps1 -CsvPath .\NewUsers.csv -OutputPath C:\Migrations -DefaultUsageLocation GB

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, Microsoft.Graph
    Permissions : User.ReadWrite.All (and Directory.ReadWrite.All for some tenants).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z]{2}$')]
    [string]$DefaultUsageLocation = 'US',

    [Parameter(Mandatory = $false)]
    [bool]$ForceChangePassword = $true
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
        $appData = $env:APPDATA
        if ([string]::IsNullOrWhiteSpace($appData)) {
            $appData = [Environment]::GetFolderPath('ApplicationData')
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
    param([Parameter(Mandatory)][string]$Name)
    if (Get-Module -ListAvailable -Name $Name) { return }
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

function New-RandomPassword {
    <# Generates a 16-char password meeting M365 complexity requirements. #>
    param([int]$Length = 16)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!@#$%^&*-_=+'
    $all = ($upper + $lower + $digit + $symbol).ToCharArray()

    # Guarantee one of each class, then fill the rest randomly.
    $chars = [System.Collections.Generic.List[char]]::new()
    $chars.Add($upper[(Get-Random -Maximum $upper.Length)])
    $chars.Add($lower[(Get-Random -Maximum $lower.Length)])
    $chars.Add($digit[(Get-Random -Maximum $digit.Length)])
    $chars.Add($symbol[(Get-Random -Maximum $symbol.Length)])
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars.Add($all[(Get-Random -Maximum $all.Length)])
    }
    # Shuffle.
    $shuffled = $chars | Sort-Object { Get-Random }
    return -join $shuffled
}

#endregion ---------------------------------------------------------------------

Write-Host '=== Bulk M365 User Creation ===' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultsCsv = Join-Path -Path $outputDir -ChildPath "New-Users-Results_$timestamp.csv"

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) { throw "CSV '$CsvPath' contains no rows." }

$headers = $rows[0].PSObject.Properties.Name
$col = @{
    Upn      = Resolve-ColumnName -Headers $headers -Candidates @('UserPrincipalName', 'UPN', 'User Principal Name')
    Name     = Resolve-ColumnName -Headers $headers -Candidates @('DisplayName', 'Display Name', 'Name')
    First    = Resolve-ColumnName -Headers $headers -Candidates @('FirstName', 'GivenName', 'First Name')
    Last     = Resolve-ColumnName -Headers $headers -Candidates @('LastName', 'Surname', 'Last Name')
    Nick     = Resolve-ColumnName -Headers $headers -Candidates @('MailNickname', 'Alias', 'MailNickName')
    Password = Resolve-ColumnName -Headers $headers -Candidates @('Password', 'InitialPassword')
    Usage    = Resolve-ColumnName -Headers $headers -Candidates @('UsageLocation', 'Usage Location')
    Title    = Resolve-ColumnName -Headers $headers -Candidates @('JobTitle', 'Title', 'Job Title')
    Dept     = Resolve-ColumnName -Headers $headers -Candidates @('Department')
    Office   = Resolve-ColumnName -Headers $headers -Candidates @('Office', 'OfficeLocation', 'Office Location')
    Mobile   = Resolve-ColumnName -Headers $headers -Candidates @('MobilePhone', 'Mobile', 'Mobile Phone')
    City     = Resolve-ColumnName -Headers $headers -Candidates @('City')
    State    = Resolve-ColumnName -Headers $headers -Candidates @('State')
    Country  = Resolve-ColumnName -Headers $headers -Candidates @('Country')
}

if (-not $col.Upn) {
    throw "Could not find a UserPrincipalName/UPN column in '$CsvPath'. Headers: $($headers -join ', ')"
}

Initialize-RequiredModule -Name 'Microsoft.Graph.Users'

Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
Connect-MgGraph -Scopes 'User.ReadWrite.All', 'Directory.ReadWrite.All' -NoWelcome

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($row in $rows) {
    $index++
    $upn = Get-CsvValue -Record $row -Column $col.Upn
    Write-Progress -Activity 'Creating users' `
        -Status "$index of $($rows.Count): $upn" `
        -PercentComplete (($index / [math]::Max($rows.Count, 1)) * 100)

    $status = 'Created'
    $detail = ''
    $generatedPassword = ''

    try {
        if (-not $upn) { throw 'Row has no UserPrincipalName/UPN value.' }

        $first = Get-CsvValue -Record $row -Column $col.First
        $last = Get-CsvValue -Record $row -Column $col.Last
        $displayName = Get-CsvValue -Record $row -Column $col.Name
        if (-not $displayName) {
            $displayName = (@($first, $last) | Where-Object { $_ }) -join ' '
        }
        if (-not $displayName) { throw 'Row has no DisplayName and no first/last name to build one.' }

        $nick = Get-CsvValue -Record $row -Column $col.Nick
        if (-not $nick) { $nick = ($upn -split '@')[0] }

        $usage = Get-CsvValue -Record $row -Column $col.Usage
        if (-not $usage) { $usage = $DefaultUsageLocation }

        # Does the user already exist?
        $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
        if ($existing) {
            $status = 'Skipped'
            $detail = 'User already exists.'
        }
        else {
            $password = Get-CsvValue -Record $row -Column $col.Password
            if (-not $password) {
                $password = New-RandomPassword
                $generatedPassword = $password
            }

            $params = @{
                AccountEnabled    = $true
                DisplayName       = $displayName
                UserPrincipalName = $upn
                MailNickname      = $nick
                UsageLocation     = $usage
                PasswordProfile   = @{
                    Password                      = $password
                    ForceChangePasswordNextSignIn = $ForceChangePassword
                }
            }
            if ($first) { $params['GivenName'] = $first }
            if ($last) { $params['Surname'] = $last }
            $title = Get-CsvValue -Record $row -Column $col.Title;    if ($title) { $params['JobTitle'] = $title }
            $dept = Get-CsvValue -Record $row -Column $col.Dept;      if ($dept) { $params['Department'] = $dept }
            $office = Get-CsvValue -Record $row -Column $col.Office;  if ($office) { $params['OfficeLocation'] = $office }
            $mobile = Get-CsvValue -Record $row -Column $col.Mobile;  if ($mobile) { $params['MobilePhone'] = $mobile }
            $city = Get-CsvValue -Record $row -Column $col.City;      if ($city) { $params['City'] = $city }
            $state = Get-CsvValue -Record $row -Column $col.State;    if ($state) { $params['State'] = $state }
            $country = Get-CsvValue -Record $row -Column $col.Country; if ($country) { $params['Country'] = $country }

            if ($PSCmdlet.ShouldProcess($upn, 'Create Microsoft 365 user')) {
                New-MgUser @params | Out-Null
                $detail = 'User created.'
            }
            else {
                $status = 'WhatIf'
                $detail = 'Would create user.'
                $generatedPassword = ''  # do not surface a password for a non-action
            }
        }
    }
    catch {
        $status = 'Failed'
        $detail = $_.Exception.Message
    }

    $color = switch ($status) {
        'Created' { 'Green' }
        'Skipped' { 'Yellow' }
        'WhatIf'  { 'Cyan' }
        default   { 'Red' }
    }
    Write-Host ("  [{0}] {1} - {2}" -f $status, $upn, $detail) -ForegroundColor $color

    $results.Add([pscustomobject][ordered]@{
        UserPrincipalName = $upn
        DisplayName       = $displayName
        Status            = $status
        Detail            = $detail
        GeneratedPassword = $generatedPassword
    })
}

Write-Progress -Activity 'Creating users' -Completed

$results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8

$created = ($results | Where-Object Status -eq 'Created').Count
$skipped = ($results | Where-Object Status -eq 'Skipped').Count
$failed = ($results | Where-Object Status -eq 'Failed').Count

Write-Host ''
Write-Host "Created: $created   Skipped: $skipped   Failed: $failed" -ForegroundColor Green
Write-Host "Results (with any generated passwords): $resultsCsv" -ForegroundColor Cyan
Write-Host 'Store the results CSV securely - it contains initial passwords.' -ForegroundColor Yellow

Disconnect-MgGraph | Out-Null
Write-Host 'Done.' -ForegroundColor Green
