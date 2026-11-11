#Requires -Version 7.4

<#
.SYNOPSIS
    Enables Exchange Online auto-expanding archiving for the whole organization or for each mailbox.

.DESCRIPTION
    Turns on auto-expanding archiving in Exchange Online. Two scopes are available:

      -Scope Organization (default)
          Runs Set-OrganizationConfig -AutoExpandingArchive one time. This covers every
          existing mailbox and every mailbox created later. It is also the ONLY method that
          works in an Exchange hybrid deployment for users whose primary mailbox is
          on-premises and whose archive is in the cloud.

      -Scope Mailbox
          Runs Enable-Mailbox -AutoExpandingArchive on each in-scope mailbox. Use it when you
          want auto-expansion for specific users only, or when you want the extra 10 GB
          buffer that Microsoft adds to the archive (and to Recoverable Items when the
          mailbox is on hold) while the auto-expanded storage is provisioned. The org-wide
          command does not add that buffer. If org-wide auto-expansion is already on,
          Exchange returns an "already enabled" error but still adds the buffer; this
          script records that case as a success (Result = BufferAdded).

    WARNING - THIS CHANGE CANNOT BE UNDONE
    - After auto-expanding archiving is on (for the org or for a mailbox), it can't be
      turned off.
    - A mailbox with auto-expanding archiving can't be recovered or restored as an inactive
      mailbox later. The only recovery path is a Purview content search export.
    - In hybrid, a cloud archive with auto-expansion can't be off-boarded to on-premises.
    The script asks for confirmation before it changes anything. Use -Force to skip the
    prompt (required for unattended runs). -DryRun never prompts and never changes anything.

    MAIN ARCHIVE REQUIREMENT
    Auto-expansion applies only to a mailbox whose main archive is already enabled.
    Mailboxes without an archive (ArchiveStatus = None) are reported and skipped. Add
    -EnableArchive to enable the main archive on those mailboxes first. The archive and
    auto-expansion need a license that includes them; check the Exchange Online archiving
    service description for current license coverage:
    https://learn.microsoft.com/office365/servicedescriptions/exchange-online-archiving-service-description/exchange-online-archiving-service-description

    SCOPE OF MAILBOXES
    User mailboxes by default. Add -IncludeSharedMailboxes for shared mailboxes. Use
    -UserPrincipalName to target named mailboxes only. Inactive mailboxes are never
    touched (Get-EXOMailbox does not return them by default).

    AUTHENTICATION AND PERMISSIONS
    Uses the ExchangeOnlineManagement module (3.0 or later). An existing Exchange Online
    session is reused, including app-only sessions. If no session exists, the script starts
    an interactive sign-in and disconnects at the end.
      - Organization scope: Global Administrator or the Organization Management role group.
      - Mailbox scope / -EnableArchive: a role group that includes the Mail Recipients role.

    OUTPUT
    A CSV report written next to the log file unless -OutputPath is given. Mailbox scope
    writes one row per in-scope mailbox. Organization scope writes one row for the
    organization setting plus one row for each mailbox whose archive was enabled or skipped.

    Microsoft reference:
    https://learn.microsoft.com/purview/enable-autoexpanding-archiving

.PARAMETER Scope
    Organization (default) or Mailbox. See DESCRIPTION.

.PARAMETER UserPrincipalName
    One or more mailboxes to target (UPN or any identity that Get-EXOMailbox accepts).
    When omitted, all user mailboxes (and shared mailboxes with -IncludeSharedMailboxes)
    are in scope. Requires -Scope Mailbox; the script exits 2 if it is used with
    -Scope Organization, because an org-wide change can't be narrowed to named users.

.PARAMETER IncludeSharedMailboxes
    Add shared mailboxes to the scope. Microsoft supports auto-expansion on shared
    mailboxes whose growth rate does not exceed 1 GB per day.

.PARAMETER EnableArchive
    Enable the main archive on in-scope mailboxes that do not have one, before
    auto-expansion is applied.

.PARAMETER Force
    Skip the confirmation prompt. Required for non-interactive runs.

.PARAMETER OutputPath
    Path for the CSV report. Defaults to the log folder.

.PARAMETER Verbosity
    Console output level. Low = errors and success only. Medium = adds warnings.
    High = everything. The log file always gets everything.

.PARAMETER DryRun
    Reads the tenant and reports what would change. Makes no changes and shows no prompt.

.PARAMETER LogPath
    Path to the log file. Defaults to $env:ProgramData\<MSPName>\Logs on Windows and to
    ~/.local/state/<MSPName>/Logs on macOS/Linux.

.EXAMPLE
    ./Enable-M365ArchiveAutoExpand.ps1 -DryRun -Verbosity High

    Shows the organization setting, the mailbox count, and the mailboxes with no archive.
    Changes nothing.

.EXAMPLE
    ./Enable-M365ArchiveAutoExpand.ps1 -EnableArchive

    Enables the main archive where it is missing, then turns on org-wide auto-expanding
    archiving. Prompts for confirmation first.

.EXAMPLE
    ./Enable-M365ArchiveAutoExpand.ps1 -Scope Mailbox -IncludeSharedMailboxes -Force

    Enables auto-expansion per mailbox (adds the 10 GB buffer) for every user and shared
    mailbox that has an archive. No prompt.

.EXAMPLE
    ./Enable-M365ArchiveAutoExpand.ps1 -Scope Mailbox -UserPrincipalName user1@contoso.com,user2@contoso.com

    Enables auto-expansion for two named mailboxes only.

.NOTES
    Version  : 1.0.0
    Created  : 2026-11-11
    AI Assist: Claude Code (Claude Opus 5.5) - reviewed against Microsoft Learn documentation
    Requires : PowerShell 7.4+, ExchangeOnlineManagement 3.0+

    Exit codes:
      0   Completed; every in-scope item succeeded or needed no change.
      1   Fatal error.
      2   Confirmation declined, a confirmation was needed in a non-interactive session
          without -Force, -UserPrincipalName was used with -Scope Organization, or more than
          one Exchange Online session was open.
      20  Connection to Exchange Online failed.
      50  Partial success; one or more mailboxes failed (see the CSV report).
#>

[CmdletBinding()]
param (
    [ValidateSet('Organization', 'Mailbox')]
    [string]$Scope = 'Organization',

    [ValidateNotNullOrEmpty()]
    [string[]]$UserPrincipalName,

    [switch]$IncludeSharedMailboxes,

    [switch]$EnableArchive,

    [switch]$Force,

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

# Errors that are worth a retry. Anything else (license, permission, bad identity) fails fast.
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
    <# DryRun-aware wrapper. Every tenant mutation goes through here so -DryRun stays honest. #>
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

function Test-IsTrue {
    <# The value can come back as [bool] or as the string 'True'/'False'; '[bool]"False"' is $true. #>
    param ($Value)
    return ([string]$Value -eq 'True')
}

function Get-MailboxIdentity {
    <# ExchangeGuid is unambiguous; fall back to the UPN if the property did not come back. #>
    param ([Parameter(Mandatory)] $Mailbox)

    if ($Mailbox.ExchangeGuid -and [string]$Mailbox.ExchangeGuid -ne [guid]::Empty.ToString()) {
        return [string]$Mailbox.ExchangeGuid
    }
    return [string]$Mailbox.UserPrincipalName
}

function Get-TargetMailbox {
    <# Returns in-scope mailboxes plus result rows for identities that could not be resolved. #>
    $properties = @('ExchangeGuid', 'ArchiveStatus', 'AutoExpandingArchiveEnabled')
    $types      = @('UserMailbox')
    if ($IncludeSharedMailboxes) { $types += 'SharedMailbox' }

    $mailboxes  = [System.Collections.Generic.List[object]]::new()
    $lookupFail = [System.Collections.Generic.List[object]]::new()

    if ($UserPrincipalName) {
        foreach ($upn in $UserPrincipalName) {
            try {
                $mbx = Invoke-WithRetry -Description "lookup $upn" -Action {
                    Get-EXOMailbox -Identity $upn -Properties $properties -ErrorAction Stop
                }
                if ($mbx.RecipientTypeDetails -notin $types) {
                    Write-Log "$upn is a $($mbx.RecipientTypeDetails); skipped (not in scope)" -Level 'WARNING'
                    $lookupFail.Add((New-ResultRow -Identity $upn -Action 'Lookup' -Result 'Skipped' `
                        -Detail "RecipientTypeDetails $($mbx.RecipientTypeDetails) is not in scope"))
                    continue
                }
                $mailboxes.Add($mbx)
            }
            catch {
                Write-Log "Mailbox lookup failed for ${upn}: $($_.Exception.Message)" -Level 'ERROR'
                $lookupFail.Add((New-ResultRow -Identity $upn -Action 'Lookup' -Result 'Failed' `
                    -Detail $_.Exception.Message))
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

    [pscustomobject]@{
        Mailboxes  = $mailboxes
        LookupRows = $lookupFail
    }
}

function New-ResultRow {
    param (
        [string]$Identity,
        [string]$RecipientType = '',
        [string]$ArchiveStatusBefore = '',
        [string]$AutoExpandBefore = '',
        [string]$Action,
        [string]$Result,
        [string]$Detail = ''
    )

    [pscustomobject]@{
        Identity            = $Identity
        RecipientType       = $RecipientType
        ArchiveStatusBefore = $ArchiveStatusBefore
        AutoExpandBefore    = $AutoExpandBefore
        Action              = $Action
        Result              = $Result
        Detail              = $Detail
    }
}

function Test-ArchiveEnabled {
    param ([Parameter(Mandatory)] $Mailbox)

    # Microsoft's own guidance uses ArchiveStatus -eq 'None' to find mailboxes with no archive.
    return ([string]$Mailbox.ArchiveStatus -ne 'None' -and -not [string]::IsNullOrEmpty([string]$Mailbox.ArchiveStatus))
}

function Confirm-IrreversibleChange {
    param ([Parameter(Mandatory)] [string]$Summary)

    if ($script:DryRun -or $Force) { return $true }

    $message = @"
Tenant: $($script:TenantLabel)
$Summary

Auto-expanding archiving CANNOT be turned off after it is enabled.
Mailboxes with it enabled can't be recovered or restored as inactive mailboxes later.
"@

    # hasSecurityImpact = $true makes the default answer No, so a stray Enter does not apply it.
    $yesToAll = $false
    $noToAll  = $false
    try {
        return $PSCmdlet.ShouldContinue($message, 'Enable auto-expanding archiving?', $true, [ref]$yesToAll,
            [ref]$noToAll)
    }
    catch {
        # Non-interactive host: ShouldContinue can't prompt.
        Write-Log ('Confirmation is needed but the session is non-interactive. Re-run with -Force. ' +
            "($($_.Exception.Message))") -Level 'ERROR'
        return $false
    }
}

function Enable-MainArchive {
    param (
        [Parameter(Mandatory)] $Mailbox,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]]$Results
    )

    $id = $Mailbox.UserPrincipalName
    try {
        Invoke-Action -Description "Enable main archive on $id" -Action {
            Invoke-WithRetry -Description "enable archive $id" -Action {
                Enable-Mailbox -Identity (Get-MailboxIdentity -Mailbox $Mailbox) -Archive -ErrorAction Stop | Out-Null
            }
        }
        $Results.Add((New-ResultRow -Identity $id -RecipientType $Mailbox.RecipientTypeDetails `
            -ArchiveStatusBefore $Mailbox.ArchiveStatus -AutoExpandBefore $Mailbox.AutoExpandingArchiveEnabled `
            -Action 'EnableArchive' -Result ($script:DryRun ? 'WouldChange' : 'Changed')))
        return $true
    }
    catch {
        Write-Log "Enable archive failed for ${id}: $($_.Exception.Message)" -Level 'ERROR'
        $Results.Add((New-ResultRow -Identity $id -RecipientType $Mailbox.RecipientTypeDetails `
            -ArchiveStatusBefore $Mailbox.ArchiveStatus -AutoExpandBefore $Mailbox.AutoExpandingArchiveEnabled `
            -Action 'EnableArchive' -Result 'Failed' -Detail $_.Exception.Message))
        return $false
    }
}

function Enable-MailboxAutoExpand {
    param (
        [Parameter(Mandatory)] $Mailbox,
        [Parameter(Mandatory)] [bool]$OrgEnabled,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]]$Results
    )

    $id   = $Mailbox.UserPrincipalName
    $row  = @{
        Identity            = $id
        RecipientType       = $Mailbox.RecipientTypeDetails
        ArchiveStatusBefore = $Mailbox.ArchiveStatus
        AutoExpandBefore    = $Mailbox.AutoExpandingArchiveEnabled
        Action              = 'EnableAutoExpand'
    }

    try {
        Invoke-Action -Description "Enable auto-expanding archive on $id" -Action {
            Invoke-WithRetry -Description "auto-expand $id" -Action {
                $identity = Get-MailboxIdentity -Mailbox $Mailbox
                Enable-Mailbox -Identity $identity -AutoExpandingArchive -ErrorAction Stop | Out-Null
            }
        }
        $Results.Add((New-ResultRow @row -Result ($script:DryRun ? 'WouldChange' : 'Changed')))
    }
    catch {
        # With org-wide auto-expansion on, Exchange throws "already enabled" but still adds the
        # 10 GB buffer to the mailbox. That is the outcome the caller asked for, not a failure.
        if ($OrgEnabled -and $_.Exception.Message -match 'already') {
            Write-Log "$id - org-wide auto-expansion already on; buffer added" -Level 'DEBUG'
            $Results.Add((New-ResultRow @row -Result 'BufferAdded' -Detail $_.Exception.Message))
        }
        else {
            Write-Log "Enable auto-expand failed for ${id}: $($_.Exception.Message)" -Level 'ERROR'
            $Results.Add((New-ResultRow @row -Result 'Failed' -Detail $_.Exception.Message))
        }
    }
}

#endregion

#region Script Body

function Invoke-Main {
    <# Returns the exit code. Kept in a function so early exits can 'return' a code. #>
    Write-Log ("Script started - Scope=$Scope, IncludeShared=$IncludeSharedMailboxes, " +
        "EnableArchive=$EnableArchive, DryRun=$DryRun, Force=$Force") -Level 'INFO'
    Write-Log "Log file: $($script:LogPath)" -Level 'INFO'
    if ($script:DryRun) {
        Write-Log '*** DRYRUN MODE - no changes will be made ***' -Level 'SUCCESS'
    }

    # -UserPrincipalName can't narrow an org-wide change. Refuse rather than silently turn it on
    # for every mailbox in the tenant.
    if ($UserPrincipalName -and $Scope -eq 'Organization') {
        Write-Log '-UserPrincipalName needs -Scope Mailbox. -Scope Organization always changes the whole tenant.' `
            -Level 'ERROR'
        return 2
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

    $orgConfig  = Get-OrganizationConfig -ErrorAction Stop
    $orgEnabled = Test-IsTrue $orgConfig.AutoExpandingArchiveEnabled
    Write-Log "Organization AutoExpandingArchiveEnabled = $orgEnabled" -Level 'INFO'

    $target    = Get-TargetMailbox
    $mailboxes = $target.Mailboxes
    $results   = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $target.LookupRows) { $results.Add($row) }

    $noArchive   = @($mailboxes | Where-Object { -not (Test-ArchiveEnabled -Mailbox $_) })
    $withArchive = @($mailboxes | Where-Object { Test-ArchiveEnabled -Mailbox $_ })
    $alreadyMbx  = @($withArchive | Where-Object { Test-IsTrue $_.AutoExpandingArchiveEnabled })

    Write-Log ("In-scope mailboxes: $($mailboxes.Count) (with archive: $($withArchive.Count), " +
        "no archive: $($noArchive.Count), mailbox-level auto-expand already on: $($alreadyMbx.Count))") -Level 'SUCCESS'
    if ($noArchive.Count -and -not $EnableArchive) {
        Write-Log ("$($noArchive.Count) mailbox(es) have no main archive. Auto-expansion does not apply " +
            'to them until the archive is enabled. Use -EnableArchive to enable it.') -Level 'WARNING'
    }

    # Work out what will change before asking, so the prompt shows real numbers.
    $archiveToEnable = if ($EnableArchive) { $noArchive.Count } else { 0 }
    $summaryLines    = [System.Collections.Generic.List[string]]::new()
    if ($archiveToEnable) {
        $summaryLines.Add("Enable the main archive on $archiveToEnable mailbox(es).")
    }
    if ($Scope -eq 'Organization' -and -not $orgEnabled) {
        $summaryLines.Add(
            'Turn on auto-expanding archiving for the WHOLE ORGANIZATION (existing and future mailboxes).')
    }
    if ($Scope -eq 'Mailbox') {
        $mbxToChange = ($withArchive.Count - $alreadyMbx.Count) + $archiveToEnable
        if ($mbxToChange) {
            $summaryLines.Add("Turn on auto-expanding archiving on $mbxToChange mailbox(es).")
        }
    }

    if ($summaryLines.Count -eq 0) {
        Write-Log 'Nothing to change.' -Level 'SUCCESS'
    }
    elseif (-not (Confirm-IrreversibleChange -Summary ($summaryLines -join [Environment]::NewLine))) {
        Write-Log 'Confirmation declined; no changes made.' -Level 'ERROR'
        return 2
    }
    else {
        # 1. Main archive first - auto-expansion requires it.
        $archiveReady = [System.Collections.Generic.HashSet[string]]::new()
        if ($EnableArchive) {
            foreach ($mbx in $noArchive) {
                if (Enable-MainArchive -Mailbox $mbx -Results $results) {
                    [void]$archiveReady.Add($mbx.UserPrincipalName)
                }
            }
        }

        # 2. Auto-expansion.
        if ($Scope -eq 'Organization') {
            if ($orgEnabled) {
                $results.Add((New-ResultRow -Identity '(Organization)' -AutoExpandBefore 'True' `
                    -Action 'EnableAutoExpandOrg' -Result 'NoChange' -Detail 'Already enabled'))
            }
            else {
                $null = Invoke-Action -Description 'Set-OrganizationConfig -AutoExpandingArchive' -Action {
                    Invoke-WithRetry -Description 'org-wide auto-expand' -Action {
                        Set-OrganizationConfig -AutoExpandingArchive -ErrorAction Stop
                    }
                }
                $results.Add((New-ResultRow -Identity '(Organization)' -AutoExpandBefore 'False' `
                    -Action 'EnableAutoExpandOrg' -Result ($script:DryRun ? 'WouldChange' : 'Changed')))
            }
        }
        else {
            $newlyArchived = @($noArchive | Where-Object { $archiveReady.Contains($_.UserPrincipalName) })
            $candidates    = @($withArchive) + $newlyArchived
            $total      = $candidates.Count
            $i          = 0
            foreach ($mbx in $candidates) {
                $i++
                Write-Progress -Activity 'Enabling auto-expanding archive' `
                    -Status "$i of $total - $($mbx.UserPrincipalName)" `
                    -PercentComplete (($i / [math]::Max($total, 1)) * 100)

                if (Test-IsTrue $mbx.AutoExpandingArchiveEnabled) {
                    $results.Add((New-ResultRow -Identity $mbx.UserPrincipalName `
                        -RecipientType $mbx.RecipientTypeDetails -ArchiveStatusBefore $mbx.ArchiveStatus `
                        -AutoExpandBefore 'True' `
                        -Action 'EnableAutoExpand' -Result 'NoChange' -Detail 'Already enabled on mailbox'))
                    continue
                }
                Enable-MailboxAutoExpand -Mailbox $mbx -OrgEnabled $orgEnabled -Results $results
            }
            Write-Progress -Activity 'Enabling auto-expanding archive' -Completed
        }
    }

    # Mailboxes left without an archive get a row so the report is complete.
    if (-not $EnableArchive) {
        foreach ($mbx in $noArchive) {
            $results.Add((New-ResultRow -Identity $mbx.UserPrincipalName -RecipientType $mbx.RecipientTypeDetails `
                -ArchiveStatusBefore $mbx.ArchiveStatus -AutoExpandBefore $mbx.AutoExpandingArchiveEnabled `
                -Action 'None' -Result 'SkippedNoArchive' -Detail 'Main archive not enabled'))
        }
    }

    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Log "Report: $OutputPath" -Level 'SUCCESS'

    $failed = @($results | Where-Object Result -eq 'Failed').Count
    $grouped = $results | Group-Object Result | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Log "Summary: $($grouped -join ', ')" -Level 'SUCCESS'

    if ($failed) {
        Write-Log "$failed item(s) failed. See the report." -Level 'ERROR'
        return 50
    }
    Write-Log 'Script completed successfully' -Level 'SUCCESS'
    return 0
}

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
