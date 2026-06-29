#Requires -Version 7.0
#Requires -Modules ExchangeOnlineManagement

<#
.SYNOPSIS
    Sets each mailbox's primary SMTP (email) address - independent of the UPN -
    from a CSV that pairs a UPN with the desired primary email.

.DESCRIPTION
    Connects to Exchange Online (interactive sign-in) and, for each CSV row,
    locates the mailbox by its UPN and sets the primary SMTP address to the
    value in the email column. This is the common migration step where a user
    signs in with one address (UPN) but should send/receive as another.

    By default the previous primary address is retained as a secondary alias
    (so existing mail still routes). Use -RemoveOldPrimaryAlias to drop it
    instead. If an account has an Email Address Policy applied, use
    -DisableEmailAddressPolicy so the manual primary address is not overwritten.

    Column headers are auto-detected (case-insensitive):
      - UPN column   : UserPrincipalName / UPN / User Principal Name
      - Email column : PrimaryEmail / Email / PrimarySmtpAddress / NewPrimary /
                       Primary Email Address

    Supports -WhatIf / -Confirm.

.PARAMETER CsvPath
    CSV pairing each UPN with its desired primary email address.

.PARAMETER OutputPath
    Directory where the results CSV is written. If omitted, defaults to
    "<LocalAppData>\Migration-Automations" after confirming with you.

.PARAMETER RemoveOldPrimaryAlias
    Remove the former primary address instead of keeping it as an alias.

.PARAMETER DisableEmailAddressPolicy
    Turn off the Email Address Policy on each mailbox before changing the
    address, so the new primary is not reverted by policy.

.PARAMETER DryRun
    Preview only - make no changes. Equivalent to -WhatIf: every row is
    evaluated and the planned primary-address change reported, but no mailbox
    is modified.

.EXAMPLE
    .\Set-MailboxPrimaryAddress.ps1 -CsvPath .\PrimaryMap.csv -DryRun

.EXAMPLE
    .\Set-MailboxPrimaryAddress.ps1 -CsvPath .\PrimaryMap.csv -WhatIf

.EXAMPLE
    .\Set-MailboxPrimaryAddress.ps1 -CsvPath .\PrimaryMap.csv -OutputPath C:\Migrations -DisableEmailAddressPolicy

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, ExchangeOnlineManagement
    Permissions : A role that can modify mailbox email addresses
                  (e.g. Exchange Administrator).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveOldPrimaryAlias,

    [Parameter(Mandatory = $false)]
    [switch]$DisableEmailAddressPolicy,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# -DryRun makes no changes - read-only checks still run, mutating calls are skipped.
if ($DryRun) {
    Write-Host 'DRY RUN enabled - read-only checks run, but no changes will be made.' -ForegroundColor Magenta
}

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

#endregion ---------------------------------------------------------------------

Write-Host '=== Set Mailbox Primary Address ===' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultsCsv = Join-Path -Path $outputDir -ChildPath "Set-PrimaryAddress-Results_$timestamp.csv"

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) { throw "CSV '$CsvPath' contains no rows." }

$headers = $rows[0].PSObject.Properties.Name
$col = @{
    Upn   = Resolve-ColumnName -Headers $headers -Candidates @('UserPrincipalName', 'UPN', 'User Principal Name')
    Email = Resolve-ColumnName -Headers $headers -Candidates @('PrimaryEmail', 'Email', 'PrimarySmtpAddress', 'NewPrimary', 'NewPrimaryEmail', 'Primary Email Address', 'EmailAddress')
}
if (-not $col.Upn) { throw "Could not find a UPN column in '$CsvPath'. Headers: $($headers -join ', ')" }
if (-not $col.Email) { throw "Could not find a primary email column in '$CsvPath'. Headers: $($headers -join ', ')" }

Initialize-RequiredModule -Name 'ExchangeOnlineManagement'

Write-Host 'Connecting to Exchange Online...' -ForegroundColor Cyan
Connect-ExchangeOnline -ShowBanner:$false

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($row in $rows) {
    $index++
    $upn = Get-CsvValue -Record $row -Column $col.Upn
    $newPrimary = Get-CsvValue -Record $row -Column $col.Email

    Write-Progress -Activity 'Setting primary addresses' `
        -Status "$index of $($rows.Count): $upn" `
        -PercentComplete (($index / [math]::Max($rows.Count, 1)) * 100)

    $status = 'Updated'
    $detail = ''
    $oldPrimary = ''

    try {
        if (-not $upn) { throw 'Row has no UPN value.' }
        if (-not $newPrimary) { throw 'Row has no primary email value.' }
        if ($newPrimary -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            throw "Primary email '$newPrimary' is not a valid SMTP address."
        }

        $mailbox = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
        if (-not $mailbox) {
            throw "No mailbox found for UPN '$upn'."
        }
        $oldPrimary = $mailbox.PrimarySmtpAddress.ToString()

        if ($oldPrimary -ieq $newPrimary) {
            $status = 'Skipped'
            $detail = 'Primary address already set.'
        }
        elseif (-not $DryRun -and $PSCmdlet.ShouldProcess($upn, "Set primary SMTP to $newPrimary")) {
            if ($DisableEmailAddressPolicy -and $mailbox.EmailAddressPolicyEnabled) {
                Set-Mailbox -Identity $upn -EmailAddressPolicyEnabled $false -ErrorAction Stop
                $detail += 'Disabled email address policy. '
            }

            # WindowsEmailAddress sets the new primary and demotes the old one to an alias.
            Set-Mailbox -Identity $upn -WindowsEmailAddress $newPrimary -ErrorAction Stop
            $detail += "Primary set to $newPrimary. "

            if ($RemoveOldPrimaryAlias -and $oldPrimary -and $oldPrimary -ine $newPrimary) {
                Set-Mailbox -Identity $upn -EmailAddresses @{ Remove = "smtp:$oldPrimary" } -ErrorAction Stop
                $detail += "Removed old alias $oldPrimary. "
            }
        }
        else {
            $status = 'WhatIf'
            $detail = "Would set primary to $newPrimary."
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
    Write-Host ("  [{0}] {1} -> {2} {3}" -f $status, $upn, $newPrimary, $detail.Trim()) -ForegroundColor $color

    $results.Add([pscustomobject][ordered]@{
        UserPrincipalName = $upn
        OldPrimaryEmail   = $oldPrimary
        NewPrimaryEmail   = $newPrimary
        Status            = $status
        Detail            = $detail.Trim()
    })
}

Write-Progress -Activity 'Setting primary addresses' -Completed

$results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8

$updated = ($results | Where-Object Status -eq 'Updated').Count
$skipped = ($results | Where-Object Status -eq 'Skipped').Count
$failed = ($results | Where-Object Status -eq 'Failed').Count

Write-Host ''
Write-Host "Updated: $updated   Skipped: $skipped   Failed: $failed" -ForegroundColor Green
Write-Host "Results: $resultsCsv" -ForegroundColor Cyan

Disconnect-ExchangeOnline -Confirm:$false | Out-Null
Write-Host 'Done.' -ForegroundColor Green
