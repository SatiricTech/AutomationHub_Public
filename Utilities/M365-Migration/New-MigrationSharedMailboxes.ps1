#Requires -Version 7.0
#Requires -Modules ExchangeOnlineManagement

<#
.SYNOPSIS
    Bulk-creates Exchange Online shared mailboxes from a CSV mapping file,
    optionally adding aliases and Full Access / Send As permissions.

.DESCRIPTION
    Connects to Exchange Online (interactive sign-in) and creates one shared
    mailbox per CSV row. Column headers are auto-detected so exports from this
    toolkit (e.g. the Shared Mailboxes tab/CSV from Get-MigrationInventory) or
    most migration tools work directly.

    Recognised columns (first match wins, case-insensitive):
      - PrimarySmtpAddress / Email / PrimaryEmail     (required)
      - DisplayName / Display Name / Name             (required)
      - Alias / MailNickname                          (defaults to SMTP local part)
      - AliasAddresses / ProxyAddresses / EmailAliases (';'- or ','-separated
                                                        extra smtp addresses)
      - FullAccess / FullAccessMembers                (';'/',' list of users to
                                                        grant Full Access)
      - SendAs / SendAsMembers                        (';'/',' list of users to
                                                        grant Send As)
      - HiddenFromAddressLists                        (true/false)

    Existing mailboxes (same primary address) are not recreated; the script
    still applies any aliases/permissions specified for them. Supports
    -WhatIf / -Confirm.

.PARAMETER CsvPath
    Path to the CSV describing the shared mailboxes to create.

.PARAMETER OutputPath
    Directory where the results CSV is written. If omitted, defaults to
    "<LocalAppData>\Migration-Automations" after confirming with you.

.PARAMETER DryRun
    Preview only - make no changes. Equivalent to -WhatIf: every row is
    evaluated and reported but no mailbox, alias or permission is created.

.EXAMPLE
    .\New-MigrationSharedMailboxes.ps1 -CsvPath .\Shared.csv -DryRun

.EXAMPLE
    .\New-MigrationSharedMailboxes.ps1 -CsvPath .\Shared.csv -WhatIf

.EXAMPLE
    .\New-MigrationSharedMailboxes.ps1 -CsvPath .\Shared.csv -OutputPath C:\Migrations

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, ExchangeOnlineManagement
    Permissions : A role that can create mailboxes and manage permissions
                  (e.g. Exchange Administrator).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

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

function Split-List {
    <# Splits a ';' or ',' separated string into trimmed, non-empty values. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return $Value -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

#endregion ---------------------------------------------------------------------

Write-Host '=== Bulk Shared Mailbox Creation ===' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultsCsv = Join-Path -Path $outputDir -ChildPath "New-SharedMailboxes-Results_$timestamp.csv"

$rows = @(Import-Csv -LiteralPath $CsvPath)
if ($rows.Count -eq 0) { throw "CSV '$CsvPath' contains no rows." }

$headers = $rows[0].PSObject.Properties.Name
$col = @{
    Smtp       = Resolve-ColumnName -Headers $headers -Candidates @('PrimarySmtpAddress', 'Email', 'PrimaryEmail', 'EmailAddress', 'Primary Email Address')
    Name       = Resolve-ColumnName -Headers $headers -Candidates @('DisplayName', 'Display Name', 'Name')
    Alias      = Resolve-ColumnName -Headers $headers -Candidates @('Alias', 'MailNickname')
    Aliases    = Resolve-ColumnName -Headers $headers -Candidates @('AliasAddresses', 'ProxyAddresses', 'EmailAliases', 'Aliases')
    FullAccess = Resolve-ColumnName -Headers $headers -Candidates @('FullAccess', 'FullAccessMembers', 'FullAccessUsers')
    SendAs     = Resolve-ColumnName -Headers $headers -Candidates @('SendAs', 'SendAsMembers', 'SendAsUsers')
    Hidden     = Resolve-ColumnName -Headers $headers -Candidates @('HiddenFromAddressLists', 'Hidden', 'HiddenFromAddressListsEnabled')
}

if (-not $col.Smtp) {
    throw "Could not find a primary SMTP/Email column in '$CsvPath'. Headers: $($headers -join ', ')"
}
if (-not $col.Name) {
    throw "Could not find a DisplayName column in '$CsvPath'. Headers: $($headers -join ', ')"
}

Initialize-RequiredModule -Name 'ExchangeOnlineManagement'

Write-Host 'Connecting to Exchange Online...' -ForegroundColor Cyan
Connect-ExchangeOnline -ShowBanner:$false

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($row in $rows) {
    $index++
    $smtp = Get-CsvValue -Record $row -Column $col.Smtp
    $displayName = Get-CsvValue -Record $row -Column $col.Name
    Write-Progress -Activity 'Creating shared mailboxes' `
        -Status "$index of $($rows.Count): $smtp" `
        -PercentComplete (($index / [math]::Max($rows.Count, 1)) * 100)

    $status = 'Created'
    $detail = [System.Collections.Generic.List[string]]::new()

    try {
        if (-not $smtp) { throw 'Row has no primary SMTP/Email value.' }
        if (-not $displayName) { throw 'Row has no DisplayName value.' }

        $alias = Get-CsvValue -Record $row -Column $col.Alias
        if (-not $alias) { $alias = ($smtp -split '@')[0] }

        $existing = Get-Mailbox -Identity $smtp -ErrorAction SilentlyContinue
        if ($existing) {
            $status = 'Exists'
            $detail.Add('Mailbox already exists.')
        }
        elseif (-not $DryRun -and $PSCmdlet.ShouldProcess($smtp, 'Create shared mailbox')) {
            New-Mailbox -Shared -Name $displayName -DisplayName $displayName `
                -PrimarySmtpAddress $smtp -Alias $alias | Out-Null
            $detail.Add('Shared mailbox created.')
        }
        else {
            $status = 'WhatIf'
            $detail.Add('Would create shared mailbox.')
        }

        # Apply aliases / hidden flag / permissions for real (non-dry) runs.
        if ($DryRun -and $status -in @('Created', 'Exists')) {
            $detail.Add('Dry run: alias/permission changes skipped.')
        }
        elseif ($status -in @('Created', 'Exists')) {
            $aliasAddresses = Split-List -Value (Get-CsvValue -Record $row -Column $col.Aliases)
            if ($aliasAddresses.Count -gt 0) {
                Set-Mailbox -Identity $smtp -EmailAddresses @{ Add = $aliasAddresses } -ErrorAction Stop
                $detail.Add("Added $($aliasAddresses.Count) alias(es).")
            }

            $hiddenRaw = Get-CsvValue -Record $row -Column $col.Hidden
            if ($hiddenRaw) {
                $hidden = $hiddenRaw -match '^(1|true|yes|y)$'
                Set-Mailbox -Identity $smtp -HiddenFromAddressListsEnabled $hidden -ErrorAction Stop
                $detail.Add("HiddenFromAddressLists=$hidden.")
            }

            foreach ($member in (Split-List -Value (Get-CsvValue -Record $row -Column $col.FullAccess))) {
                try {
                    Add-MailboxPermission -Identity $smtp -User $member -AccessRights FullAccess `
                        -AutoMapping $true -ErrorAction Stop | Out-Null
                    $detail.Add("FullAccess: $member.")
                }
                catch {
                    $detail.Add("FullAccess FAILED ($member): $($_.Exception.Message)")
                }
            }

            foreach ($member in (Split-List -Value (Get-CsvValue -Record $row -Column $col.SendAs))) {
                try {
                    Add-RecipientPermission -Identity $smtp -Trustee $member -AccessRights SendAs `
                        -Confirm:$false -ErrorAction Stop | Out-Null
                    $detail.Add("SendAs: $member.")
                }
                catch {
                    $detail.Add("SendAs FAILED ($member): $($_.Exception.Message)")
                }
            }
        }
    }
    catch {
        $status = 'Failed'
        $detail.Add($_.Exception.Message)
    }

    $color = switch ($status) {
        'Created' { 'Green' }
        'Exists'  { 'Yellow' }
        'WhatIf'  { 'Cyan' }
        default   { 'Red' }
    }
    Write-Host ("  [{0}] {1}" -f $status, $smtp) -ForegroundColor $color

    $results.Add([pscustomobject][ordered]@{
        PrimarySmtpAddress = $smtp
        DisplayName        = $displayName
        Status             = $status
        Detail             = ($detail -join ' ')
    })
}

Write-Progress -Activity 'Creating shared mailboxes' -Completed

$results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8

$created = ($results | Where-Object Status -eq 'Created').Count
$exists = ($results | Where-Object Status -eq 'Exists').Count
$failed = ($results | Where-Object Status -eq 'Failed').Count

Write-Host ''
Write-Host "Created: $created   Existing: $exists   Failed: $failed" -ForegroundColor Green
Write-Host "Results: $resultsCsv" -ForegroundColor Cyan

Disconnect-ExchangeOnline -Confirm:$false | Out-Null
Write-Host 'Done.' -ForegroundColor Green
