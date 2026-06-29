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
    "<LocalAppData>\Migration-Automations", prints that path, and asks you to
    confirm it or supply a different directory.

.PARAMETER Prefix
    Text prepended to the output file names (e.g. 'Contoso' ->
    'Contoso_Exchange-Mailboxes-Full_...'). If omitted, you are asked whether
    you want a custom prefix; if not, you are asked whether this is the Source
    or Destination tenant and that label is used instead.

.PARAMETER RecipientTypeDetails
    Limit the export to specific mailbox types (e.g. UserMailbox,
    SharedMailbox, RoomMailbox, EquipmentMailbox). Defaults to all of these.

.PARAMETER SkipStatistics
    Skip the per-mailbox Get-MailboxStatistics lookup for a faster run.

.PARAMETER DryRun
    Preview only - resolve the prefix and output location and print the planned
    output files, then exit without connecting to Exchange Online or writing any
    file.

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
    [string]$Prefix,

    [Parameter(Mandatory = $false)]
    [ValidateSet('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox')]
    [string[]]$RecipientTypeDetails = @('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox'),

    [Parameter(Mandatory = $false)]
    [switch]$SkipStatistics,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
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

function Format-FilePrefix {
    <# Strips characters that are unsafe in file names and trims separators. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value -replace '[^A-Za-z0-9._-]', '').Trim('_', '.', '-', ' ')
}

function Resolve-FilePrefix {
    <#
        Determines the file-name prefix. If -Value is supplied it is sanitised
        and used. Otherwise the user is asked whether to use a custom prefix; if
        not, whether this is the Source or Destination tenant - that label
        becomes the prefix so file names are self-describing.
    #>
    [CmdletBinding()]
    param([string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $clean = Format-FilePrefix -Value $Value
        if ($clean) { return $clean }
        Write-Host "Provided prefix '$Value' was empty after cleanup; falling back to a prompt." -ForegroundColor Yellow
    }

    Write-Host ''
    while ($true) {
        $answer = ((Read-Host 'Add a custom file-name prefix? [Y] Yes  [N] No (label as Source/Destination)') ?? '').Trim()
        if ($answer -match '^(y|yes)$') {
            $custom = ((Read-Host 'Enter the prefix to use') ?? '').Trim()
            $clean = Format-FilePrefix -Value $custom
            if ($clean) { return $clean }
            Write-Host 'Prefix was empty after cleanup - please try again.' -ForegroundColor Red
        }
        elseif ($answer -match '^(n|no)$') {
            while ($true) {
                $sd = ((Read-Host 'Is this the [S]ource or [D]estination tenant?') ?? '').Trim()
                if ($sd -match '^(s|source)$') { return 'Source' }
                if ($sd -match '^(d|destination)$') { return 'Destination' }
                Write-Host 'Please enter S or D.' -ForegroundColor Red
            }
        }
        else {
            Write-Host 'Please answer Y or N.' -ForegroundColor Red
        }
    }
}

#endregion ---------------------------------------------------------------------

Write-Host '=== Exchange Online Mailbox Export ===' -ForegroundColor Cyan

$filePrefix = Resolve-FilePrefix -Value $Prefix
$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$fullCsv = Join-Path -Path $outputDir -ChildPath "${filePrefix}_Exchange-Mailboxes-Full_$timestamp.csv"
$summaryCsv = Join-Path -Path $outputDir -ChildPath "${filePrefix}_Exchange-Mailboxes-Summary_$timestamp.csv"

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN - no connection or file write will occur.' -ForegroundColor Magenta
    Write-Host 'Would connect to Exchange Online and export all mailboxes.' -ForegroundColor Magenta
    Write-Host "Planned output files:" -ForegroundColor Magenta
    Write-Host "  Full    : $fullCsv" -ForegroundColor Magenta
    Write-Host "  Summary : $summaryCsv" -ForegroundColor Magenta
    return
}

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
