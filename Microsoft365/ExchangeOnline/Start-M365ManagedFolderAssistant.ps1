#Requires -Version 7.4

<#
.SYNOPSIS
    Starts the Managed Folder Assistant on every Exchange Online mailbox (or on named mailboxes).

.DESCRIPTION
    The Managed Folder Assistant (MFA) applies retention and archive policies to a mailbox:
    it moves items to the archive, deletes expired items, and applies retention tags.
    Exchange Online runs it on its own schedule, which can take up to 7 days per mailbox.
    This script runs Start-ManagedFolderAssistant on each in-scope mailbox so new policies,
    a newly enabled archive, or auto-expanding archiving take effect now.

    Typical use: run it after Enable-M365ArchiveAutoExpand.ps1, after you assign a new
    retention policy, or after you change archive tags.

    WHAT IT CHANGES
    Start-ManagedFolderAssistant only queues a processing request. It does not change any
    mailbox setting. The assistant then applies the policies that already exist, which can
    move or delete items according to those policies. -DryRun lists the mailboxes and
    queues nothing.

    SCOPE OF MAILBOXES
    User mailboxes by default. Add -IncludeSharedMailboxes for shared mailboxes. Use
    -UserPrincipalName for named mailboxes only. Use -ArchiveEnabledOnly to skip mailboxes
    with no main archive. Inactive mailboxes are not processed.

    ERRORS AND THROTTLING
    One failed mailbox does not stop the run. Each mailbox gets a row in the CSV report.
    Throttling and timeout errors are retried with exponential backoff. -DelayMilliseconds
    adds a pause between mailboxes for large tenants.

    AUTHENTICATION AND PERMISSIONS
    Uses the ExchangeOnlineManagement module (3.0 or later). An existing Exchange Online
    session is reused, including app-only sessions. If no session exists, the script starts
    an interactive sign-in and disconnects at the end. The account needs a role that can run
    Start-ManagedFolderAssistant (for example the Organization Management or Compliance
    Management role group, or the Retention Management role).

    Microsoft reference:
    https://learn.microsoft.com/powershell/module/exchangepowershell/start-managedfolderassistant

.PARAMETER UserPrincipalName
    One or more mailboxes to process (UPN or any identity that Get-EXOMailbox accepts).
    When omitted, all user mailboxes (and shared mailboxes with -IncludeSharedMailboxes)
    are processed.

.PARAMETER IncludeSharedMailboxes
    Add shared mailboxes to the scope.

.PARAMETER ArchiveEnabledOnly
    Process only mailboxes whose main archive is enabled.

.PARAMETER HoldCleanup
    Pass -HoldCleanup to Start-ManagedFolderAssistant. This cleans up duplicate versions
    of items in Recoverable Items for mailboxes on hold. Use it when Recoverable Items is
    near its quota.

.PARAMETER DelayMilliseconds
    Pause between mailboxes, 0 to 60000 ms. Default 0.

.PARAMETER OutputPath
    Path for the CSV report. Defaults to the log folder.

.PARAMETER Verbosity
    Console output level. Low = errors and success only. Medium = adds warnings.
    High = everything. The log file always gets everything.

.PARAMETER DryRun
    Lists the mailboxes that would be processed. Queues nothing.

.PARAMETER LogPath
    Path to the log file. Defaults to $env:ProgramData\<MSPName>\Logs on Windows and to
    ~/.local/state/<MSPName>/Logs on macOS/Linux.

.EXAMPLE
    ./Start-M365ManagedFolderAssistant.ps1 -DryRun -Verbosity High

    Lists every user mailbox that would be processed. Queues nothing.

.EXAMPLE
    ./Start-M365ManagedFolderAssistant.ps1 -IncludeSharedMailboxes -ArchiveEnabledOnly

    Starts the assistant on every user and shared mailbox that has an archive.

.EXAMPLE
    ./Start-M365ManagedFolderAssistant.ps1 -UserPrincipalName user1@contoso.com -HoldCleanup

    Starts the assistant with hold cleanup on one mailbox.

.NOTES
    Version  : 1.0.0
    Created  : 2026-11-11
    AI Assist: Claude Code (Claude Opus 5.5) - reviewed against Microsoft Learn documentation
    Requires : PowerShell 7.4+, ExchangeOnlineManagement 3.0+

    Exit codes:
      0   Completed; the assistant was queued on every in-scope mailbox.
      1   Fatal error, or every mailbox failed.
      2   More than one Exchange Online session was open.
      20  Connection to Exchange Online failed.
      50  Partial success; one or more mailboxes failed (see the CSV report).
#>

[CmdletBinding()]
param (
    [ValidateNotNullOrEmpty()]
    [string[]]$UserPrincipalName,

    [switch]$IncludeSharedMailboxes,

    [switch]$ArchiveEnabledOnly,

    [switch]$HoldCleanup,

    [ValidateRange(0, 60000)]
    [int]$DelayMilliseconds = 0,

    [string]$OutputPath,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Low',

    [switch]$DryRun,

    [string]$LogPath
)

#region Configuration & Constants

$MSPName = '{mspname}'   # <-- Replace with your MSP name (e.g., 'SentinelCyber')

$ErrorActionPreference = 'Stop'
$script:Verbosity      = $Verbosity
$script:DryRun         = $DryRun.IsPresent
$scriptStartTime       = Get-Date
$timestamp             = Get-Date -Format 'yyyyMMdd-HHmmss'
$scriptName            = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)

# $env:ProgramData does not exist on macOS/Linux. Use a folder in the user's own profile there,
# not the temp directory: /tmp is shared on Linux, and another local user could pre-create the
# folder or a symlink to read the report (UPNs, tenant name) or redirect the writes.
if (-not $LogPath) {
    $logRoot = if ($IsWindows -and $env:ProgramData) {
        Join-Path $env:ProgramData $MSPName 'Logs'
    }
    else {
        Join-Path $HOME '.local' 'state' $MSPName 'Logs'
    }
    $LogPath = Join-Path $logRoot "$scriptName-$timestamp.log"
}
$script:LogPath = $LogPath

$logDir = Split-Path -Path $script:LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $logDir "$scriptName-$timestamp.csv"
}

$requiredModule = @{ Name = 'ExchangeOnlineManagement'; MinVersion = [version]'3.0.0' }

# Errors that are worth a retry. Anything else (permission, bad identity) fails fast.
$retryablePattern = 'throttl|server busy|too many requests|\b429\b|timed? ?out|temporarily|try again'

#endregion

#region Helper Functions

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'DEBUG', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $logTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logMessage   = "[$logTimestamp] [$Level] $Message"

    $writeToConsole = switch ($script:Verbosity) {
        'Low'    { $Level -in 'ERROR', 'SUCCESS' }
        'Medium' { $Level -in 'ERROR', 'WARNING', 'SUCCESS' }
        'High'   { $true }
        default  { $true }
    }

    if ($writeToConsole) {
        $color = switch ($Level) {
            'ERROR'   { 'Red' }
            'WARNING' { 'Yellow' }
            'SUCCESS' { 'Green' }
            'DEBUG'   { 'Cyan' }
            default   { 'White' }
        }
        Write-Host $logMessage -ForegroundColor $color
    }

    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $logMessage
    }
}

function Invoke-Action {
    <# DryRun-aware wrapper. Every tenant call that starts work goes through here. #>
    param (
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    if ($script:DryRun) {
        Write-Log "[DRYRUN] Would execute: $Description" -Level 'INFO'
        return
    }

    Write-Log "Executing: $Description" -Level 'DEBUG'
    & $Action
}

function Invoke-WithRetry {
    <#
        Retries only transient errors (throttling, timeouts). Exchange Online throttles bulk
        cmdlet runs, and one 429 should not turn into a failed mailbox in the report.
    #>
    param (
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [string]$Description = 'operation',

        [ValidateRange(1, 10)]
        [int]$MaxRetries = 4,

        [ValidateRange(100, 60000)]
        [int]$BaseDelayMs = 2000
    )

    $attempt = 0
    while ($true) {
        try {
            $attempt++
            return (& $Action)
        }
        catch {
            $isRetryable = $_.Exception.Message -match $retryablePattern
            if (-not $isRetryable -or $attempt -ge $MaxRetries) {
                throw
            }
            $delay = $BaseDelayMs * [math]::Pow(2, $attempt - 1)
            Write-Log ("Transient error on $Description (attempt $attempt): $($_.Exception.Message). " +
                "Retrying in ${delay}ms.") -Level 'WARNING'
            Start-Sleep -Milliseconds $delay
        }
    }
}

function Assert-ExchangeModule {
    $installed = Get-Module -ListAvailable -Name $requiredModule.Name |
        Where-Object Version -ge $requiredModule.MinVersion |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $installed) {
        Write-Log "Installing $($requiredModule.Name) $($requiredModule.MinVersion)+ for the current user" `
            -Level 'WARNING'
        try {
            Install-PSResource -Name $requiredModule.Name -Scope CurrentUser -TrustRepository -ErrorAction Stop
        }
        catch {
            Write-Log 'Install-PSResource failed; falling back to Install-Module' -Level 'WARNING'
            Install-Module -Name $requiredModule.Name -MinimumVersion $requiredModule.MinVersion `
                -Scope CurrentUser -Force -ErrorAction Stop
        }
    }

    Import-Module -Name $requiredModule.Name -MinimumVersion $requiredModule.MinVersion -ErrorAction Stop
    Write-Log "Module $($requiredModule.Name) loaded" -Level 'DEBUG'
}

function Get-ExchangeSession {
    <# Live Exchange Online sessions only; Security & Compliance (IPPS) sessions are excluded. #>
    @(Get-ConnectionInformation -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Connected' -and $_.TokenStatus -eq 'Active' -and -not $_.IsEopSession })
}

function Connect-ExchangeSession {
    <#
        Reuses a live session (including app-only). Returns $true if this script opened it.
        Refuses to run with more than one Exchange Online session: the EXO cmdlets use the
        most recent connection, so the tenant this script names could differ from the tenant
        it changes. Throws 'MultipleSessions' in that case.
    #>
    $sessions = Get-ExchangeSession

    if ($sessions.Count -gt 1) {
        $list = ($sessions | ForEach-Object { "$($_.Organization) ($($_.TenantID))" }) -join '; '
        Write-Log ("More than one Exchange Online session is open: $list. Run Disconnect-ExchangeOnline, " +
            'connect to the one target tenant, and run again.') -Level 'ERROR'
        throw 'MultipleSessions'
    }

    if ($sessions.Count -eq 1) {
        $existing = $sessions[0]
        # SUCCESS level so the tenant shows at every verbosity, including Low: a leftover session
        # to another tenant is the easiest way to change the wrong organization.
        $script:TenantLabel = "$($existing.Organization) ($($existing.TenantID))"
        Write-Log "Reusing Exchange Online session: $($existing.UserPrincipalName) in tenant $($script:TenantLabel)" `
            -Level 'SUCCESS'
        return $false
    }

    Write-Log 'No Exchange Online session found; starting interactive sign-in' -Level 'INFO'
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop | Out-Null
    $info = Get-ExchangeSession | Select-Object -Last 1
    $script:TenantLabel = "$($info.Organization) ($($info.TenantID))"
    Write-Log "Connected: $($info.UserPrincipalName) in tenant $($script:TenantLabel)" -Level 'SUCCESS'
    return $true
}

#endregion

#region Main Functions

function Get-MailboxIdentity {
    <# ExchangeGuid is unambiguous; fall back to the UPN if the property did not come back. #>
    param ([Parameter(Mandatory)] $Mailbox)

    if ($Mailbox.ExchangeGuid -and [string]$Mailbox.ExchangeGuid -ne [guid]::Empty.ToString()) {
        return [string]$Mailbox.ExchangeGuid
    }
    return [string]$Mailbox.UserPrincipalName
}

function New-ResultRow {
    param (
        [string]$Identity,
        [string]$RecipientType = '',
        [string]$ArchiveStatus = '',
        [string]$Result,
        [string]$Detail = ''
    )

    [pscustomobject]@{
        Identity      = $Identity
        RecipientType = $RecipientType
        ArchiveStatus = $ArchiveStatus
        Result        = $Result
        Detail        = $Detail
    }
}

function Test-ArchiveEnabled {
    param ([Parameter(Mandatory)] $Mailbox)

    # Microsoft's own guidance uses ArchiveStatus -eq 'None' to find mailboxes with no archive.
    return ([string]$Mailbox.ArchiveStatus -ne 'None' -and -not [string]::IsNullOrEmpty([string]$Mailbox.ArchiveStatus))
}

function Get-TargetMailbox {
    <# Returns in-scope mailboxes plus result rows for identities that could not be resolved. #>
    param ([Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]]$Results)

    $properties = @('ExchangeGuid', 'ArchiveStatus')
    $types      = @('UserMailbox')
    if ($IncludeSharedMailboxes) { $types += 'SharedMailbox' }

    $mailboxes = [System.Collections.Generic.List[object]]::new()

    if ($UserPrincipalName) {
        foreach ($upn in $UserPrincipalName) {
            try {
                $mbx = Invoke-WithRetry -Description "lookup $upn" -Action {
                    Get-EXOMailbox -Identity $upn -Properties $properties -ErrorAction Stop
                }
                if ($mbx.RecipientTypeDetails -notin $types) {
                    Write-Log "$upn is a $($mbx.RecipientTypeDetails); skipped (not in scope)" -Level 'WARNING'
                    $Results.Add((New-ResultRow -Identity $upn -RecipientType $mbx.RecipientTypeDetails `
                        -Result 'Skipped' -Detail 'RecipientTypeDetails not in scope'))
                    continue
                }
                $mailboxes.Add($mbx)
            }
            catch {
                Write-Log "Mailbox lookup failed for ${upn}: $($_.Exception.Message)" -Level 'ERROR'
                $Results.Add((New-ResultRow -Identity $upn -Result 'Failed' -Detail $_.Exception.Message))
            }
        }
    }
    else {
        Write-Log "Enumerating mailboxes of type: $($types -join ', ')" -Level 'INFO'
        $all = Invoke-WithRetry -Description 'mailbox enumeration' -Action {
            Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails $types -Properties $properties `
                -ErrorAction Stop
        }
        foreach ($mbx in @($all)) { $mailboxes.Add($mbx) }
    }

    if ($ArchiveEnabledOnly) {
        $skipped = @($mailboxes | Where-Object { -not (Test-ArchiveEnabled -Mailbox $_) })
        foreach ($mbx in $skipped) {
            $Results.Add((New-ResultRow -Identity $mbx.UserPrincipalName -RecipientType $mbx.RecipientTypeDetails `
                -ArchiveStatus $mbx.ArchiveStatus -Result 'SkippedNoArchive'))
        }
        Write-Log "$($skipped.Count) mailbox(es) skipped: no main archive" -Level 'INFO'
        return @($mailboxes | Where-Object { Test-ArchiveEnabled -Mailbox $_ })
    }

    return @($mailboxes)
}

function Start-MailboxAssistant {
    param (
        [Parameter(Mandatory)] $Mailbox,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]]$Results
    )

    $id     = $Mailbox.UserPrincipalName
    $suffix = $HoldCleanup ? ' -HoldCleanup' : ''

    try {
        $splat = @{ Identity = (Get-MailboxIdentity -Mailbox $Mailbox); ErrorAction = 'Stop' }
        if ($HoldCleanup) { $splat.HoldCleanup = $true }
        Invoke-Action -Description "Start-ManagedFolderAssistant$suffix on $id" -Action {
            Invoke-WithRetry -Description "MFA $id" -Action {
                Start-ManagedFolderAssistant @splat | Out-Null
            }
        }
        $Results.Add((New-ResultRow -Identity $id -RecipientType $Mailbox.RecipientTypeDetails `
            -ArchiveStatus $Mailbox.ArchiveStatus -Result ($script:DryRun ? 'WouldStart' : 'Started')))
    }
    catch {
        Write-Log "Start-ManagedFolderAssistant failed for ${id}: $($_.Exception.Message)" -Level 'ERROR'
        $Results.Add((New-ResultRow -Identity $id -RecipientType $Mailbox.RecipientTypeDetails `
            -ArchiveStatus $Mailbox.ArchiveStatus -Result 'Failed' -Detail $_.Exception.Message))
    }
}

function Invoke-Main {
    <# Returns the exit code. Kept in a function so early exits can 'return' a code. #>
    Write-Log ("Script started - IncludeShared=$IncludeSharedMailboxes, ArchiveEnabledOnly=$ArchiveEnabledOnly, " +
        "HoldCleanup=$HoldCleanup, DelayMs=$DelayMilliseconds, DryRun=$DryRun") -Level 'INFO'
    Write-Log "Log file: $($script:LogPath)" -Level 'INFO'
    if ($script:DryRun) {
        Write-Log '*** DRYRUN MODE - the assistant will not be started ***' -Level 'SUCCESS'
    }

    Assert-ExchangeModule

    try {
        $script:ConnectedByScript = Connect-ExchangeSession
    }
    catch {
        if ($_.Exception.Message -eq 'MultipleSessions') { return 2 }
        Write-Log "Connection to Exchange Online failed: $($_.Exception.Message)" -Level 'ERROR'
        return 20
    }

    $results   = [System.Collections.Generic.List[object]]::new()
    $mailboxes = Get-TargetMailbox -Results $results
    $total     = $mailboxes.Count
    Write-Log "Mailboxes to process: $total" -Level 'SUCCESS'

    $i = 0
    foreach ($mbx in $mailboxes) {
        $i++
        Write-Progress -Activity 'Starting Managed Folder Assistant' `
            -Status "$i of $total - $($mbx.UserPrincipalName)" `
            -PercentComplete (($i / [math]::Max($total, 1)) * 100)

        Start-MailboxAssistant -Mailbox $mbx -Results $results

        if ($DelayMilliseconds -gt 0 -and $i -lt $total) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }
    Write-Progress -Activity 'Starting Managed Folder Assistant' -Completed

    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Log "Report: $OutputPath" -Level 'SUCCESS'

    $grouped = $results | Group-Object Result | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Log "Summary: $($grouped -join ', ')" -Level 'SUCCESS'

    $failed    = @($results | Where-Object Result -eq 'Failed').Count
    $succeeded = @($results | Where-Object Result -in 'Started', 'WouldStart').Count

    if ($failed -and -not $succeeded) {
        Write-Log "Every mailbox failed ($failed). See the report." -Level 'ERROR'
        return 1
    }
    if ($failed) {
        Write-Log "$failed mailbox(es) failed. See the report." -Level 'ERROR'
        return 50
    }
    Write-Log 'Script completed successfully' -Level 'SUCCESS'
    return 0
}

#endregion

#region Script Body

$script:ConnectedByScript = $false
$script:TenantLabel       = '(unknown)'
$exitCode                 = 1

try {
    # Last value + [int] so stray pipeline output can never turn a failure into exit 0.
    $mainResult = Invoke-Main | Select-Object -Last 1
    $exitCode   = ($null -eq $mainResult) ? 1 : [int]$mainResult
}
catch {
    Write-Log "Script failed: $($_.Exception.Message)" -Level 'ERROR'
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level 'ERROR'
    $exitCode = 1
}
finally {
    if ($script:ConnectedByScript) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log 'Disconnected from Exchange Online' -Level 'DEBUG'
    }
    $duration = (Get-Date) - $scriptStartTime
    Write-Log "Total duration: $($duration.ToString('hh\:mm\:ss\.fff'))" -Level 'INFO'
}

exit $exitCode

#endregion
