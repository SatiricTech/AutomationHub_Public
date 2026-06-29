#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Standardises Microsoft 365 UserPrincipalNames to a chosen naming scheme,
    driven by a CSV of current UPN + first name + last name.

.DESCRIPTION
    Connects to Microsoft Graph (interactive sign-in) and, for each CSV row,
    matches the existing account by its current UPN / email and rewrites the
    UPN local part to the selected naming scheme. The domain portion is kept
    from the existing UPN unless you override it with -DomainSuffix.

    Supported schemes:
      - First.Last   ->  john.smith@domain
      - FLast        ->  jsmith@domain      (first initial + last name)
      - FirstLast    ->  johnsmith@domain
      - F.Last       ->  j.smith@domain     (first initial + '.' + last name)

    If -Scheme is not supplied you are prompted to pick one interactively.

    Names are sanitised (spaces and non-alphanumeric characters removed,
    accents stripped, lower-cased) so the resulting UPN is valid. Rows whose
    computed UPN already matches the account are skipped. Supports
    -WhatIf / -Confirm.

.PARAMETER CsvPath
    CSV containing the current UPN, first name and last name. Recognised
    columns (case-insensitive): UserPrincipalName/UPN/Email, FirstName/GivenName,
    LastName/Surname.

.PARAMETER Scheme
    The target naming scheme: First.Last, FLast, FirstLast or F.Last. Prompted
    for if omitted.

.PARAMETER DomainSuffix
    Force the domain portion of the new UPN (e.g. 'contoso.com' or
    '@contoso.com'). If omitted, each account keeps its existing UPN domain.

.PARAMETER OutputPath
    Directory where the results CSV is written. If omitted, defaults to
    "<LocalAppData>\Migration-Automations" after confirming with you.

.EXAMPLE
    .\Set-MigrationUserPrincipalNames.ps1 -CsvPath .\Users.csv -Scheme FLast -WhatIf

.EXAMPLE
    .\Set-MigrationUserPrincipalNames.ps1 -CsvPath .\Users.csv -Scheme First.Last -DomainSuffix contoso.com

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, Microsoft.Graph
    Permissions : User.ReadWrite.All
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('First.Last', 'FLast', 'FirstLast', 'F.Last')]
    [string]$Scheme,

    [Parameter(Mandatory = $false)]
    [string]$DomainSuffix,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
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

function Get-CleanNamePart {
    <# Lower-cases, strips accents and removes anything that is not a letter or digit. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $normalized.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne
            [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $clean = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
    return ($clean -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
}

function ConvertTo-UpnLocalPart {
    param(
        [string]$Scheme,
        [string]$First,
        [string]$Last
    )
    $f = Get-CleanNamePart -Value $First
    $l = Get-CleanNamePart -Value $Last
    if (-not $f -or -not $l) { return $null }

    switch ($Scheme) {
        'First.Last' { return "$f.$l" }
        'FLast'      { return "$($f.Substring(0,1))$l" }
        'FirstLast'  { return "$f$l" }
        'F.Last'     { return "$($f.Substring(0,1)).$l" }
    }
    return $null
}

#endregion ---------------------------------------------------------------------

Write-Host '=== UPN Standardisation ===' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

# Prompt for scheme if not supplied.
if (-not $Scheme) {
    Write-Host ''
    Write-Host 'Select a UPN naming scheme:' -ForegroundColor Yellow
    Write-Host '  [1] First.Last   (john.smith@domain)'
    Write-Host '  [2] FLast        (jsmith@domain)'
    Write-Host '  [3] FirstLast    (johnsmith@domain)'
    Write-Host '  [4] F.Last       (j.smith@domain)'
    while (-not $Scheme) {
        $choice = (Read-Host 'Enter 1-4') ?? ''
        switch ($choice.Trim()) {
            '1' { $Scheme = 'First.Last' }
            '2' { $Scheme = 'FLast' }
            '3' { $Scheme = 'FirstLast' }
            '4' { $Scheme = 'F.Last' }
            default { Write-Host 'Please enter a number from 1 to 4.' -ForegroundColor Red }
        }
    }
}
Write-Host "Using scheme: $Scheme" -ForegroundColor Cyan

# Normalise an optional forced domain (accept 'contoso.com' or '@contoso.com').
$forcedDomain = $null
if ($DomainSuffix) {
    $forcedDomain = $DomainSuffix.TrimStart('@').Trim()
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultsCsv = Join-Path -Path $outputDir -ChildPath "Set-UPN-Results_$timestamp.csv"

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) { throw "CSV '$CsvPath' contains no rows." }

$headers = $rows[0].PSObject.Properties.Name
$col = @{
    Upn   = Resolve-ColumnName -Headers $headers -Candidates @('UserPrincipalName', 'UPN', 'Email', 'PrimaryEmail', 'CurrentUPN', 'User Principal Name')
    First = Resolve-ColumnName -Headers $headers -Candidates @('FirstName', 'GivenName', 'First Name')
    Last  = Resolve-ColumnName -Headers $headers -Candidates @('LastName', 'Surname', 'Last Name')
}
if (-not $col.Upn) { throw "Could not find a current UPN/Email column in '$CsvPath'. Headers: $($headers -join ', ')" }
if (-not $col.First) { throw "Could not find a FirstName column in '$CsvPath'. Headers: $($headers -join ', ')" }
if (-not $col.Last) { throw "Could not find a LastName column in '$CsvPath'. Headers: $($headers -join ', ')" }

Initialize-RequiredModule -Name 'Microsoft.Graph.Users'

Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
Connect-MgGraph -Scopes 'User.ReadWrite.All' -NoWelcome

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($row in $rows) {
    $index++
    $currentUpn = Get-CsvValue -Record $row -Column $col.Upn
    $first = Get-CsvValue -Record $row -Column $col.First
    $last = Get-CsvValue -Record $row -Column $col.Last

    Write-Progress -Activity 'Updating UPNs' `
        -Status "$index of $($rows.Count): $currentUpn" `
        -PercentComplete (($index / [math]::Max($rows.Count, 1)) * 100)

    $status = 'Updated'
    $detail = ''
    $newUpn = ''

    try {
        if (-not $currentUpn) { throw 'Row has no current UPN/Email value.' }

        # Match the live account by UPN first, then by primary mail.
        $account = Get-MgUser -Filter "userPrincipalName eq '$currentUpn'" `
            -Property 'Id,UserPrincipalName,Mail' -ErrorAction SilentlyContinue
        if (-not $account) {
            $account = Get-MgUser -Filter "mail eq '$currentUpn'" `
                -Property 'Id,UserPrincipalName,Mail' -ErrorAction SilentlyContinue
        }
        if (-not $account) {
            throw "No active account found matching '$currentUpn'."
        }
        if ($account -is [array]) { $account = $account[0] }

        $localPart = ConvertTo-UpnLocalPart -Scheme $Scheme -First $first -Last $last
        if (-not $localPart) {
            throw "Could not build a UPN from first='$first' last='$last'."
        }

        $domain = if ($forcedDomain) { $forcedDomain } else { ($account.UserPrincipalName -split '@')[1] }
        $newUpn = "$localPart@$domain"

        if ($newUpn -ieq $account.UserPrincipalName) {
            $status = 'Skipped'
            $detail = 'UPN already matches the target scheme.'
        }
        elseif ($PSCmdlet.ShouldProcess($account.UserPrincipalName, "Update UPN to $newUpn")) {
            Update-MgUser -UserId $account.Id -UserPrincipalName $newUpn
            $detail = 'UPN updated.'
        }
        else {
            $status = 'WhatIf'
            $detail = 'Would update UPN.'
        }
    }
    catch {
        $status = 'Failed'
        $detail = $_.Exception.Message
    }

    $color = switch ($status) {
        'Updated' { 'Green' }
        'Skipped' { 'Yellow' }
        'WhatIf'  { 'Cyan' }
        default   { 'Red' }
    }
    Write-Host ("  [{0}] {1} -> {2} {3}" -f $status, $currentUpn, $newUpn, $detail) -ForegroundColor $color

    $results.Add([pscustomobject][ordered]@{
        CurrentUPN = $currentUpn
        NewUPN     = $newUpn
        FirstName  = $first
        LastName   = $last
        Scheme     = $Scheme
        Status     = $status
        Detail     = $detail
    })

    Start-Sleep -Milliseconds 200  # gentle throttle guard
}

Write-Progress -Activity 'Updating UPNs' -Completed

$results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8

$updated = ($results | Where-Object Status -eq 'Updated').Count
$skipped = ($results | Where-Object Status -eq 'Skipped').Count
$failed = ($results | Where-Object Status -eq 'Failed').Count

Write-Host ''
Write-Host "Updated: $updated   Skipped: $skipped   Failed: $failed" -ForegroundColor Green
Write-Host "Results: $resultsCsv" -ForegroundColor Cyan

Disconnect-MgGraph | Out-Null
Write-Host 'Done.' -ForegroundColor Green
