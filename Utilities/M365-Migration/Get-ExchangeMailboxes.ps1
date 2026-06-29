#Requires -Version 7.0
#Requires -Modules ExchangeOnlineManagement

<#
.SYNOPSIS
    Exports every Exchange Online mailbox with its full property set, plus
    mailbox statistics, to a CSV for migration planning.

.DESCRIPTION
    Connects to Exchange Online (interactive sign-in) and enumerates all
    mailboxes (user, shared, room, equipment). For each mailbox it captures the
    complete set of Get-Mailbox properties and merges in key statistics from
    Get-MailboxStatistics (total size and item count), with sizes reported in
    GB.

    Two CSVs are produced:
      - A "full" CSV containing every Get-Mailbox column plus the merged size
        fields (everything, for completeness).
      - A "summary" CSV with the fields most useful for a migration mapping
        sheet (alias, type, primary SMTP, all proxy addresses, size, etc.).

    The script is read-only against the tenant.

.PARAMETER OutputPath
    Directory where the CSVs are written. If omitted, the script defaults to
    "<AppData>\Migration-Automations", prints that path, and asks you to
    confirm it or supply a different directory.

.PARAMETER RecipientTypeDetails
    Limit the export to specific mailbox types (e.g. UserMailbox,
    SharedMailbox, RoomMailbox, EquipmentMailbox). Defaults to all of these.

.PARAMETER SkipStatistics
    Skip the per-mailbox Get-MailboxStatistics lookup for a faster run.

.EXAMPLE
    .\Get-ExchangeMailboxes.ps1

.EXAMPLE
    .\Get-ExchangeMailboxes.ps1 -OutputPath 'C:\Migrations\Contoso' -RecipientTypeDetails SharedMailbox

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, ExchangeOnlineManagement
    Permissions : View-Only Recipients (e.g. Exchange / Global Reader).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox')]
    [string[]]$RecipientTypeDetails = @('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox'),

    [Parameter(Mandatory = $false)]
    [switch]$SkipStatistics
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

function ConvertTo-GBValue {
    param($Bytes)
    if ($null -eq $Bytes -or $Bytes -eq '') { return $null }
    return [math]::Round(([double]$Bytes / 1GB), 2)
}

function Convert-ExchangeSizeToBytes {
    param($Size)
    if ($null -eq $Size) { return $null }
    $text = $Size.ToString()
    if ($text -match '\(([\d,]+)\s*bytes\)') {
        return [int64]($Matches[1] -replace ',', '')
    }
    return $null
}

function Initialize-RequiredModule {
    param([Parameter(Mandatory)][string]$Name)
    if (Get-Module -ListAvailable -Name $Name) { return }
    Write-Host "Installing required module '$Name' (CurrentUser scope)..." -ForegroundColor Yellow
    Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
}

#endregion ---------------------------------------------------------------------

Write-Host '=== Exchange Online Mailbox Export ===' -ForegroundColor Cyan

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$fullCsv = Join-Path -Path $outputDir -ChildPath "Exchange-Mailboxes-Full_$timestamp.csv"
$summaryCsv = Join-Path -Path $outputDir -ChildPath "Exchange-Mailboxes-Summary_$timestamp.csv"

Initialize-RequiredModule -Name 'ExchangeOnlineManagement'

Write-Host 'Connecting to Exchange Online...' -ForegroundColor Cyan
Connect-ExchangeOnline -ShowBanner:$false

Write-Host 'Retrieving mailboxes...' -ForegroundColor Cyan
$mailboxes = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails $RecipientTypeDetails
Write-Host "Found $($mailboxes.Count) mailbox(es)." -ForegroundColor Green

# Build statistics lookup keyed by primary SMTP (one pass, optional).
$statsByAddress = @{}
if (-not $SkipStatistics) {
    $index = 0
    foreach ($mbx in $mailboxes) {
        $index++
        Write-Progress -Activity 'Collecting mailbox statistics' `
            -Status "$index of $($mailboxes.Count): $($mbx.PrimarySmtpAddress)" `
            -PercentComplete (($index / [math]::Max($mailboxes.Count, 1)) * 100)
        try {
            $stats = Get-EXOMailboxStatistics -Identity $mbx.ExchangeGuid.ToString() -ErrorAction Stop
            $statsByAddress[$mbx.PrimarySmtpAddress.ToString()] = [pscustomobject]@{
                SizeGB        = ConvertTo-GBValue -Bytes (Convert-ExchangeSizeToBytes -Size $stats.TotalItemSize)
                ItemCount     = $stats.ItemCount
                LastLogonTime = $stats.LastLogonTime
            }
        }
        catch {
            Write-Verbose "No statistics for $($mbx.PrimarySmtpAddress): $($_.Exception.Message)"
        }
    }
    Write-Progress -Activity 'Collecting mailbox statistics' -Completed
}

# FULL export: every Get-Mailbox property + merged size fields.
Write-Host 'Building full export...' -ForegroundColor Cyan
$fullRows = foreach ($mbx in $mailboxes) {
    $stat = $statsByAddress[$mbx.PrimarySmtpAddress.ToString()]
    $mbx | Select-Object *,
        @{ Name = 'MailboxSizeGB'; Expression = { $stat.SizeGB } },
        @{ Name = 'MailboxItemCount'; Expression = { $stat.ItemCount } },
        @{ Name = 'LastLogonTime'; Expression = { $stat.LastLogonTime } }
}
$fullRows | Export-Csv -Path $fullCsv -NoTypeInformation -Encoding UTF8

# SUMMARY export: the columns most useful for a migration mapping sheet.
Write-Host 'Building summary export...' -ForegroundColor Cyan
$summaryRows = foreach ($mbx in $mailboxes) {
    $stat = $statsByAddress[$mbx.PrimarySmtpAddress.ToString()]
    $aliases = ($mbx.EmailAddresses | Where-Object { $_ -clike 'smtp:*' } |
        ForEach-Object { $_ -replace '^smtp:', '' }) -join '; '

    [pscustomobject][ordered]@{
        DisplayName          = $mbx.DisplayName
        Alias                = $mbx.Alias
        RecipientTypeDetails = $mbx.RecipientTypeDetails
        UserPrincipalName    = $mbx.UserPrincipalName
        PrimarySmtpAddress   = $mbx.PrimarySmtpAddress
        AliasAddresses       = $aliases
        MailboxSizeGB        = $stat.SizeGB
        MailboxItemCount     = $stat.ItemCount
        LastLogonTime        = $stat.LastLogonTime
        ArchiveStatus        = $mbx.ArchiveStatus
        LitigationHoldEnabled = $mbx.LitigationHoldEnabled
        HiddenFromAddressLists = $mbx.HiddenFromAddressListsEnabled
        ForwardingAddress    = $mbx.ForwardingAddress
        ForwardingSmtpAddress = $mbx.ForwardingSmtpAddress
        WhenCreated          = $mbx.WhenCreated
    }
}
$summaryRows | Export-Csv -Path $summaryCsv -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "Exported $($mailboxes.Count) mailbox(es):" -ForegroundColor Green
Write-Host "  Full    : $fullCsv" -ForegroundColor Cyan
Write-Host "  Summary : $summaryCsv" -ForegroundColor Cyan

Disconnect-ExchangeOnline -Confirm:$false | Out-Null
Write-Host 'Done.' -ForegroundColor Green
