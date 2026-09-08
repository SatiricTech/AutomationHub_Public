#Requires -Version 7.4

<#
.SYNOPSIS
    Bulk-unassigns Microsoft Teams phone numbers - from a single user, from users listed in a
    CSV (by UPN), or from every user in the tenant - and records each removed number so it
    can be reassigned later.

.DESCRIPTION
    The source-tenant half of a Teams Phone migration. Before numbers can be ported or
    reassigned in the destination tenant they usually have to be released in the source. This
    script removes the Teams phone number assignment (Calling Plan, Operator Connect or
    Direct Routing) from a batch of users.

    The target users are supplied one of three ways (choose exactly one):
      -User     A single user (UPN or object ID). Handy for rehearsing the flow against one
                account before running the batch.
      -CsvPath  A CSV of users. The user column is resolved through the toolkit's shared
                column-alias vocabulary, so the export from
                Get-MigrationTeamsPhoneAssignments.ps1 works directly.
      -All      Every user in the tenant that currently has a phone number assigned.

    Before each removal the user's current number, number type and voice routing policy are
    captured, and every processed user lands in the run's results CSV. That file carries the
    same PhoneNumber / PhoneNumberType / LocationId / OnlineVoiceRoutingPolicy columns that
    Set-MigrationTeamsPhoneAssignments.ps1 reads, so it doubles as your rollback and
    reassignment input.

    Only the number assignment is removed. Voice routing policies, dial plans and calling
    policies are left in place.

    DryRun connects read-only, resolves exactly which users and numbers would be affected,
    writes a -DryRun_ results file whose rows are Status 'Planned', and changes nothing.

.PARAMETER User
    A single user (UPN or object ID) whose phone number should be unassigned.

.PARAMETER CsvPath
    Path to a CSV describing the users to unassign. The user column is resolved through the
    toolkit's alias vocabulary (UserPrincipalName, UPN, User Principal Name, UserName, User,
    CurrentUPN, Login).

.PARAMETER All
    Unassign the phone number of EVERY user in the tenant that has one.

.PARAMETER OutputPath
    Root directory for the log and results CSV. Defaults to the toolkit's standard root:
    %LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations elsewhere.

.PARAMETER Prefix
    Names the client or run. When supplied, output lands in <root>\<Prefix>\ and file names
    start with <Prefix>_.

.PARAMETER LogPath
    Overrides the auto-derived log file path.

.PARAMETER TenantId
    Tenant ID (GUID) to sign in to. Useful for MSP / multi-tenant admins so the interactive
    sign-in lands in the intended tenant.

.PARAMETER DryRun
    Preview only. Connects read-only, reports which numbers would be removed, writes a
    -DryRun_ results file with Status 'Planned', and changes nothing.

.PARAMETER Verbosity
    Console noise level: Low (errors and successes), Medium (adds warnings), High
    (everything). The log file always receives every line regardless of this setting.

.EXAMPLE
    .\Remove-MigrationTeamsPhoneAssignments.ps1 -User john.smith@contoso.com -Prefix Source -DryRun

    Rehearses the removal against one account and writes only the DryRun results file.

.EXAMPLE
    .\Remove-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Source_TeamsPhoneAssignments.csv -Prefix Source

    Releases every number named in the export produced by Get-MigrationTeamsPhoneAssignments.ps1.

.EXAMPLE
    .\Remove-MigrationTeamsPhoneAssignments.ps1 -All -Prefix Contoso -Verbosity High

    Releases every assigned number in the tenant, with full console tracing.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4, the M365Migration module shipped beside this script, and
                  the MicrosoftTeams module (installed on demand).
    Permissions : Teams Administrator, or Teams Communications Administrator. No Graph scopes
                  are used.
    GDAP        : supported through -TenantId, which Connect-MigrationTeams passes to
                  Connect-MicrosoftTeams. -DelegatedOrganization is an Exchange Online
                  concept and does not apply - this script never connects to Exchange.

    Hybrid      : users whose number is set on-premises (OnPremLineURI synced from AD) cannot
                  be unassigned here - change them in on-prem AD instead. Such rows are
                  reported as Failed with that explanation in Detail.

    Exit codes  : 0 success, 1 fatal error, 2 completed with one or more failed rows.

    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Csv')]
param(
    [Parameter(Mandatory, ParameterSetName = 'User')]
    [ValidateNotNullOrEmpty()]
    [string]$User,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory, ParameterSetName = 'All')]
    [switch]$All,

    [string]$OutputPath,

    [string]$Prefix,

    [string]$LogPath,

    [string]$TenantId,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Configuration ----------------------------------------------------------

# Get-CsPhoneNumberAssignment caps a response well below a large tenant's inventory, so the
# inventory is walked in pages of this size.
$inventoryPageSize = 1000

#endregion ---------------------------------------------------------------------

#region Functions --------------------------------------------------------------

function Get-MigrationTeamsPolicyName {
    <#
        Get-CsOnlineUser returns policy properties inconsistently: a bare string, an object with
        a Name property, or null for the global policy. Everything collapses to a string here so
        the CSV round-trip has one shape; null stays null.

        Verbatim copy of the M365Migration module's private helper of the same name;
        the module does not export it, so this script cannot call it. Delete this copy
        once the module promotes it to Public/ - the code is identical.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Policy
    )

    if ($null -eq $Policy) { return $null }
    if ($Policy.PSObject.Properties['Name']) { return [string]$Policy.Name }

    $text = [string]$Policy
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Split-MigrationTeamsLineUri {
    <#
        Splits a LineUri such as 'tel:+15551234567;ext=123' into Number and Extension. The plan
        tracks them separately because a ported number keeps its E.164 form while the extension
        is often re-issued in the destination tenant. Blank input returns both members null.

        Verbatim copy of the M365Migration module's private helper of the same name;
        the module does not export it, so this script cannot call it. Delete this copy
        once the module promotes it to Public/ - the code is identical.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LineUri
    )

    if ([string]::IsNullOrWhiteSpace($LineUri)) {
        return [pscustomobject]@{ Number = $null; Extension = $null }
    }

    $value = $LineUri.Trim() -replace '^(?i)tel:', ''
    $extension = $null
    if ($value -match '^(?<num>[^;]+);(?i)ext=(?<ext>.+)$') {
        $value = $Matches['num']
        $extension = $Matches['ext'].Trim()
    }

    return [pscustomobject]@{ Number = $value; Extension = $extension }
}

function Resolve-MigrationTeamsUser {
    <#
        Resolves a UPN or object ID to a Teams user, returning $null instead of throwing when the
        identity is unknown, so a per-row loop records the miss and carries on rather than
        aborting the whole wave. Requires an active MicrosoftTeams session.

        Verbatim copy of the M365Migration module's private helper of the same name;
        the module does not export it, so this script cannot call it. Delete this copy
        once the module promotes it to Public/ - the code is identical.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity
    )

    try {
        return Get-CsOnlineUser -Identity $Identity -ErrorAction Stop
    }
    catch {
        Write-MigrationLog -Message "Teams user '$Identity' could not be resolved: $($_.Exception.Message)" -Level DEBUG
        return $null
    }
}

function Get-MigrationPhoneNumberInventory {
    <#
        Returns the tenant's telephone number inventory, walking -Skip until a short page comes
        back: Get-CsPhoneNumberAssignment returns a bounded page, so a large tenant silently loses
        the tail unless the caller pages itself. -Filter splats extra named arguments onto the
        cmdlet, e.g. @{ PstnAssignmentStatus = 'Unassigned' }.

        Not present in the M365Migration module at all - all three Teams Phone scripts carry an
        identical copy. Flagged for promotion.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [hashtable]$Filter = @{}
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $skip = 0
    while ($true) {
        $page = @(Get-CsPhoneNumberAssignment @Filter -Top $inventoryPageSize -Skip $skip -ErrorAction Stop)
        if ($page.Count -gt 0) { $all.AddRange($page) }
        if ($page.Count -lt $inventoryPageSize) { break }
        $skip += $inventoryPageSize
    }
    return $all.ToArray()
}

#endregion ---------------------------------------------------------------------

#region Main -------------------------------------------------------------------

$exitCode = 0
$run = Initialize-MigrationRun -ScriptName 'Remove-MigrationTeamsPhoneAssignments' -OutputPath $OutputPath `
    -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    $isDryRun = [bool]$run.DryRun

    # Fail on a bad input path before a sign-in prompt is put in front of the operator.
    if ($PSCmdlet.ParameterSetName -eq 'Csv' -and -not (Test-Path -LiteralPath $CsvPath)) {
        throw "CSV not found: $CsvPath"
    }

    $null = Connect-MigrationTeams -TenantId $TenantId

    #region Build the target list ----------------------------------------------

    # Each entry pairs the resolved Teams user (or $null) with the identity supplied, so an
    # unresolved row still reports something the operator recognises.
    $targets = [System.Collections.Generic.List[object]]::new()

    switch ($PSCmdlet.ParameterSetName) {
        'User' {
            Write-MigrationLog -Message "Resolving single user '$User'..." -Level INFO
            $targets.Add([pscustomobject]@{ Supplied = $User; User = Resolve-MigrationTeamsUser -Identity $User })
        }

        'Csv' {
            $rows = @(Import-MigrationCsv -Path $CsvPath)

            # Import-MigrationCsv maps a bare Email/Mail column to PrimarySmtpAddress rather
            # than UserPrincipalName, and Get-CsOnlineUser -Identity accepts either, so fall
            # back to it before rejecting the file.
            $headers = @($rows[0].PSObject.Properties.Name)
            $userColumn = @('UserPrincipalName', 'PrimarySmtpAddress') |
                Where-Object { $headers -contains $_ } | Select-Object -First 1
            if (-not $userColumn) {
                throw "Could not find a user column in '$CsvPath'. Headers: $($headers -join ', ')"
            }
            Write-MigrationLog -Message "Resolving $($rows.Count) user(s) from CSV column '$userColumn'..." -Level INFO

            foreach ($row in $rows) {
                $identity = [string](Get-MigrationCsvValue -Row $row -Name $userColumn -Default '')
                if ([string]::IsNullOrWhiteSpace($identity)) { continue }
                $targets.Add([pscustomobject]@{ Supplied = $identity; User = Resolve-MigrationTeamsUser -Identity $identity })
            }
        }

        'All' {
            Write-MigrationLog -Message 'Retrieving every user with an assigned phone number...' -Level INFO
            $withNumbers = $null
            try {
                $withNumbers = @(Get-CsOnlineUser -Filter 'LineUri -ne $null' -ErrorAction Stop)
            }
            catch {
                Write-MigrationLog -Message 'Server-side LineUri filter not supported by this module version - pulling all users and filtering locally.' -Level WARNING
                $withNumbers = @(Get-CsOnlineUser -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) })
            }
            foreach ($candidate in $withNumbers) {
                $targets.Add([pscustomobject]@{ Supplied = [string]$candidate.UserPrincipalName; User = $candidate })
            }
        }
    }

    Write-MigrationLog -Message "Users to process: $($targets.Count)" -Level INFO

    # One paged pull of the number inventory so each user's number type and location resolve
    # without a per-user lookup.
    Write-MigrationLog -Message 'Retrieving telephone number inventory...' -Level INFO
    $numbersByTarget = @{}
    foreach ($number in (Get-MigrationPhoneNumberInventory)) {
        if (-not [string]::IsNullOrWhiteSpace($number.AssignedPstnTargetId)) {
            $numbersByTarget[[string]$number.AssignedPstnTargetId] = $number
        }
    }

    #endregion -----------------------------------------------------------------

    #region Removal loop -------------------------------------------------------

    $results = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($entry in $targets) {
        $index++
        $identity = $entry.Supplied
        $target = $entry.User

        Write-Progress -Activity 'Unassigning phone numbers' `
            -Status "$index of $($targets.Count): $identity" `
            -PercentComplete (($index / [math]::Max($targets.Count, 1)) * 100)

        $status = 'Failed'
        $detail = ''
        $displayName = ''
        $phoneNumber = $null
        $extension = $null
        $numberType = $null
        $locationId = $null
        $voicePolicy = $null

        try {
            if ($null -eq $target) {
                $status = 'Skipped'
                $detail = 'User not found in this tenant.'
            }
            else {
                $identity = if ($target.UserPrincipalName) { [string]$target.UserPrincipalName } else { $identity }
                $displayName = [string]$target.DisplayName
                $voicePolicy = Get-MigrationTeamsPolicyName -Policy $target.OnlineVoiceRoutingPolicy

                $line = Split-MigrationTeamsLineUri -LineUri $target.LineUri
                $phoneNumber = $line.Number
                $extension = $line.Extension

                $userId = [string]$target.Identity
                $numberInfo = if ($userId -and $numbersByTarget.ContainsKey($userId)) { $numbersByTarget[$userId] } else { $null }
                $locationId = if ($numberInfo) { [string]$numberInfo.LocationId } else { $null }
                $numberType = if ($numberInfo) { [string]$numberInfo.NumberType }
                elseif ($phoneNumber) { 'DirectRouting' }
                else { $null }

                if (-not $phoneNumber) {
                    $status = 'Skipped'
                    $detail = 'No phone number assigned.'
                }
                elseif ($isDryRun) {
                    $null = Invoke-MigrationAction -Description "Unassign phone number $phoneNumber from $identity" -Action { }
                    $status = 'Planned'
                    $detail = "Would remove $phoneNumber ($numberType)."
                }
                elseif ($PSCmdlet.ShouldProcess($identity, "Unassign phone number $phoneNumber")) {
                    # -ErrorAction Stop so a failed removal (e.g. an on-prem synced
                    # OnPremLineURI) lands in catch and is recorded as Failed.
                    $null = Invoke-MigrationAction -Description "Unassign phone number $phoneNumber from $identity" -Action {
                        Remove-CsPhoneNumberAssignment -Identity $identity -RemoveAll -ErrorAction Stop
                    }
                    $status = 'Succeeded'
                    $detail = "Removed $phoneNumber ($numberType)."
                }
                else {
                    $status = 'Planned'
                    $detail = "Skipped by -WhatIf; would have removed $phoneNumber ($numberType)."
                }
            }
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
            if ($message -match 'OnPrem|on-premises|dirsync|synchroniz') {
                $detail = 'This number appears to be set on-premises (OnPremLineURI synced from AD) and must be ' +
                    "removed in on-prem AD. Original error: $message"
            }
            else {
                $detail = $message
            }
        }

        if ($status -eq 'Failed') { $exitCode = 2 }

        $level = switch ($status) {
            'Succeeded' { 'SUCCESS' }
            'Failed' { 'ERROR' }
            'Skipped' { 'WARNING' }
            default { 'INFO' }
        }
        Write-MigrationLog -Message ("[{0}] {1} - {2}" -f $status, $identity, $detail) -Level $level

        # The columns after the four standard ones are the round-trip contract with
        # Set-MigrationTeamsPhoneAssignments.ps1, so this file doubles as the reassignment input.
        $results.Add([pscustomobject][ordered]@{
                Identity                 = $identity
                Action                   = 'Unassign phone number'
                Status                   = $status
                Detail                   = $detail
                UserPrincipalName        = $identity
                DisplayName              = $displayName
                PhoneNumber              = $phoneNumber
                Extension                = $extension
                PhoneNumberType          = $numberType
                LocationId               = $locationId
                OnlineVoiceRoutingPolicy = $voicePolicy
            })
    }

    Write-Progress -Activity 'Unassigning phone numbers' -Completed

    #endregion -----------------------------------------------------------------

    $resultPath = Export-MigrationResult -Rows $results.ToArray() -Name 'Remove-TeamsPhoneAssignments'
    Write-MigrationLog -Message "Keep $resultPath - it records which number each user had and is the input for Set-MigrationTeamsPhoneAssignments.ps1." -Level INFO
}
catch {
    Write-MigrationLog -Message "Fatal: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message $_.ScriptStackTrace -Level DEBUG
    $exitCode = 1
}
finally {
    #region Cleanup ------------------------------------------------------------
    # The Teams session is deliberately left connected: Connect-MigrationTeams reuses a live
    # session, so disconnecting here would force a fresh sign-in for the next script in the run.
    $null = Complete-MigrationRun -ExitCode $exitCode
    #endregion -----------------------------------------------------------------
}

exit $exitCode

#endregion ---------------------------------------------------------------------
