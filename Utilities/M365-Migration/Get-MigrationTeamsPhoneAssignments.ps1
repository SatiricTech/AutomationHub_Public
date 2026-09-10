#Requires -Version 7.4

<#
.SYNOPSIS
    Exports every Microsoft Teams phone number assignment in a tenant to a CSV - one row per
    user with their assigned number, number type and voice settings.

.DESCRIPTION
    Connects to Microsoft Teams and reads the tenant's telephone number inventory plus every
    user's Teams voice configuration, then writes a CSV pairing each user (UPN) with their
    currently assigned phone number. The export feeds the other two Teams Phone scripts in
    this toolkit: Remove-MigrationTeamsPhoneAssignments.ps1 (bulk-unassign in the source) and
    Set-MigrationTeamsPhoneAssignments.ps1 (bulk-reassign in the destination).

    The assignments CSV columns are the round-trip contract between those three scripts and
    are deliberately left exactly as they are: UserPrincipalName, DisplayName, PhoneNumber
    (E.164), Extension, PhoneNumberType (CallingPlan / OperatorConnect / OCMobile /
    DirectRouting), EnterpriseVoiceEnabled, OnlineVoiceRoutingPolicy, TenantDialPlan,
    TeamsCallingPolicy, LocationId, UsageLocation, AccountEnabled and LineUri. Two
    informational columns follow them, which the consumers ignore: AccountType (User,
    ResourceAccount, Guest, IneligibleUser...) and AdditionalNumbers - any Alternate or
    Private lines the user holds beyond the one in PhoneNumber, as 'number:category' joined
    by ';'. Set-MigrationTeamsPhoneAssignments reassigns only PhoneNumber, so the run logs a
    warning whenever AdditionalNumbers is populated for anyone.

    EVERY account Get-CsOnlineUser returns is exported, whether or not it has a phone number -
    accounts without one simply have blank phone columns, so the CSV is also your list of who
    still needs a number. That includes resource accounts (auto attendants, call queues),
    guests and unlicensed accounts, which are counted in the log and marked by AccountType so
    you can prune them before feeding the CSV to Remove-/Set-. Soft-deleted accounts are
    excluded. Use -OnlyUsersWithNumbers to narrow the export to accounts that currently have
    an assignment.

    The number inventory is pulled once (paged) and joined to the user list locally, so users
    are not queried one number at a time. The script is read-only against the tenant, and
    also writes the toolkit's standard Identity / Action / Status / Detail results file.

.PARAMETER OutputPath
    Root directory for the log, the assignments CSV and the results CSV. Defaults to the
    toolkit's standard root: %LOCALAPPDATA%\Migration-Automations on Windows,
    ~/Migration-Automations elsewhere.

.PARAMETER Prefix
    Names the client or run (e.g. 'Contoso' or 'Source'). When supplied, output lands in
    <root>\<Prefix>\ and file names start with <Prefix>_.

.PARAMETER LogPath
    Overrides the auto-derived log file path.

.PARAMETER TenantId
    Tenant ID (GUID) or a verified domain such as contoso.onmicrosoft.com to sign in to, so
    the interactive sign-in lands in the intended tenant when the admin account can see more
    than one. A GUID lets Connect-MigrationTeams reuse a live session for the same tenant; a
    domain always forces a fresh sign-in. Whichever form is used, the tenant that was read is
    named on the console and in the log before anything is written.

.PARAMETER OnlyUsersWithNumbers
    Narrow the export to users that currently have a phone number assigned. By default every
    user is exported, with blank phone columns for users that have no number.

.PARAMETER IncludeUnassignedNumbers
    Also write a second CSV listing every telephone number in the tenant inventory that is
    NOT assigned to anyone (number, type, location, country). Handy for planning which
    numbers are free in the destination tenant.

.PARAMETER DryRun
    Preview only. Connects read-only, pulls the inventory and the user list, and writes a
    -DryRun_ results file whose rows are Status 'Planned' describing what would be exported.
    The assignments and unassigned-numbers CSVs are not written.

.PARAMETER Verbosity
    Console noise level: Low (errors and successes), Medium (adds warnings), High
    (everything). The log file always receives every line regardless of this setting.

.EXAMPLE
    .\Get-MigrationTeamsPhoneAssignments.ps1 -Prefix Source -TenantId contoso.onmicrosoft.com

    Signs in interactively as the source tenant's Global Admin and writes
    Source\Source_TeamsPhoneAssignments_<timestamp>.csv plus the run log and results file.

.EXAMPLE
    .\Get-MigrationTeamsPhoneAssignments.ps1 -OutputPath 'D:\Migrations' -Prefix Contoso -IncludeUnassignedNumbers

    Exports the assignments and, alongside them, every free number left in the inventory.

.EXAMPLE
    .\Get-MigrationTeamsPhoneAssignments.ps1 -Prefix Destination -OnlyUsersWithNumbers -DryRun

    Connects and reports how many users would be exported without writing the export.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4, the M365Migration module shipped beside this script, and
                  the MicrosoftTeams module (installed on demand).
    Permissions : Teams Administrator, or Teams Communications Administrator / Global Reader
                  for this read-only pull. No Graph scopes are used.
    GDAP        : supported through -TenantId, which Connect-MigrationTeams passes to
                  Connect-MicrosoftTeams. This script never connects to Exchange.
    Exit codes  : 0 success, 1 fatal error, 2 completed with one or more failed rows.

    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding()]
param(
    [string]$OutputPath,

    [string]$Prefix,

    [string]$LogPath,

    [string]$TenantId,

    [switch]$OnlyUsersWithNumbers,

    [switch]$IncludeUnassignedNumbers,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Main -------------------------------------------------------------------

$exitCode = 0
$run = Initialize-MigrationRun -ScriptName 'Get-MigrationTeamsPhoneAssignments' -OutputPath $OutputPath `
    -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    $isDryRun = [bool]$run.DryRun
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leader = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
    $assignmentsCsv = Join-Path -Path $run.OutputDirectory -ChildPath "${leader}TeamsPhoneAssignments_$timestamp.csv"
    $unassignedCsv = Join-Path -Path $run.OutputDirectory -ChildPath "${leader}TeamsPhoneNumbers-Unassigned_$timestamp.csv"

    # These two CSVs are read back by the Set-/Remove- scripts, so they are written here
    # rather than through Export-MigrationReport: a dry run must not leave a stale export
    # behind for the next script in the chain to pick up.
    $writeCsv = {
        param([object[]]$Rows, [string]$Path, [string]$Label)
        if ($isDryRun) {
            Write-MigrationLog -Message "[DRYRUN] Would write $($Rows.Count) $Label row(s) to $Path" -Level WARNING
            return
        }
        try {
            $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8 -ErrorAction Stop
        }
        catch {
            throw "Could not write the $Label CSV '$Path': $($_.Exception.Message)"
        }
        Write-MigrationLog -Message "$Label CSV ($($Rows.Count) row(s)): $Path" -Level SUCCESS
    }

    $tenant = Connect-MigrationTeams -TenantId $TenantId

    # Name the tenant at SUCCESS, which every verbosity shows on the console. A session reused
    # from an earlier script in the same console is logged by Connect-MigrationTeams at INFO
    # only, so without this line a 'Source' export could silently read the destination tenant.
    # Both reads go through Get-MigrationProperty: Get-CsTenant's property bag varies by module
    # version and the script runs under strict mode.
    $connectedTenantId = [string](Get-MigrationProperty -InputObject $tenant -Name 'TenantId' -Default '')
    $connectedTenantName = [string](Get-MigrationProperty -InputObject $tenant -Name 'DisplayName' -Default '')
    Write-MigrationLog -Message "Reading tenant $connectedTenantId ($connectedTenantName)" -Level SUCCESS

    Write-MigrationLog -Message 'Retrieving telephone number inventory...' -Level INFO
    $allNumbers = @(Get-MigrationPhoneNumberInventory)
    Write-MigrationLog -Message "Numbers in inventory: $($allNumbers.Count)" -Level INFO

    # The inventory is indexed three ways so each user's number type and location resolve
    # without a per-user lookup:
    #   - by TelephoneNumber, in the inventory's own form ('+E164' or '+E164;ext=NNN'), so the
    #     type and location come from the number actually in the user's LineUri. A user can
    #     hold a Primary plus Private/Alternate lines under one AssignedPstnTargetId, and the
    #     cmdlet sorts by number, so keying on the user alone hands back whichever line sorted
    #     last;
    #   - by AssignedPstnTargetId, preferring the Primary row, as the fallback for users whose
    #     LineUri is blank;
    #   - every row per AssignedPstnTargetId, to report the extra lines in AdditionalNumbers.
    # Direct Routing numbers that were never uploaded to the inventory are in none of these -
    # the user's LineUri still captures the number itself.
    $numbersByPhone = @{}
    $numbersByTarget = @{}
    $numbersPerTarget = @{}
    foreach ($number in $allNumbers) {
        $phoneKey = [string](Get-MigrationProperty -InputObject $number -Name 'TelephoneNumber' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($phoneKey)) {
            $numbersByPhone[$phoneKey.Trim()] = $number
        }

        $targetId = [string](Get-MigrationProperty -InputObject $number -Name 'AssignedPstnTargetId' -Default '')
        if ([string]::IsNullOrWhiteSpace($targetId)) { continue }

        if (-not $numbersPerTarget.ContainsKey($targetId)) {
            $numbersPerTarget[$targetId] = [System.Collections.Generic.List[object]]::new()
        }
        $numbersPerTarget[$targetId].Add($number)

        $category = [string](Get-MigrationProperty -InputObject $number -Name 'AssignmentCategory' -Default '')
        if (-not $numbersByTarget.ContainsKey($targetId) -or $category -ieq 'Primary') {
            $numbersByTarget[$targetId] = $number
        }
    }

    Write-MigrationLog -Message 'Retrieving Teams users (this can take a while on large tenants)...' -Level INFO
    $users = $null
    if ($OnlyUsersWithNumbers) {
        # Server-side filter keeps the pull small; fall back to a full pull if the connected
        # module version rejects the filter syntax. The real error is logged because the same
        # catch also sees auth and throttling failures, which the full pull will then repeat.
        try {
            $users = @(Get-CsOnlineUser -Filter 'LineUri -ne $null' -ErrorAction Stop)
        }
        catch {
            Write-MigrationLog -Message "Server-side LineUri filter failed ($($_.Exception.Message)) - pulling all users and filtering locally." -Level WARNING
            $users = $null
        }
    }
    if ($null -eq $users) {
        $users = @(Get-CsOnlineUser -ErrorAction Stop)
        if ($OnlyUsersWithNumbers) {
            $users = @($users | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) })
        }
    }

    # Get-CsOnlineUser returns soft-deleted accounts alongside live ones (SoftDeletionTimestamp
    # set). They must not reach the Remove-/Set- scripts, so they are dropped here rather than
    # in the server-side filter, which already has a fallback path for unsupported syntax.
    $pulledCount = $users.Count
    $users = @($users | Where-Object {
            [string]::IsNullOrWhiteSpace([string](Get-MigrationProperty -InputObject $_ -Name 'SoftDeletionTimestamp' -Default ''))
        })
    $softDeletedCount = $pulledCount - $users.Count
    if ($softDeletedCount -gt 0) {
        Write-MigrationLog -Message "Excluded $softDeletedCount soft-deleted account(s) from the export." -Level WARNING
    }

    # Resource accounts, guests and unlicensed accounts come back too and can carry a LineUri
    # (an auto attendant's number, say). They stay in the export, marked by AccountType, and
    # are counted here so the operator knows to prune them before a cutover run.
    $flaggedAccountTypes = @('ResourceAccount', 'Guest', 'IneligibleUser')
    $accountTypeCounts = @{}
    foreach ($candidate in $users) {
        $candidateType = [string](Get-MigrationProperty -InputObject $candidate -Name 'AccountType' -Default '')
        if ($candidateType -in $flaggedAccountTypes) {
            $accountTypeCounts[$candidateType] = [int]$accountTypeCounts[$candidateType] + 1
        }
    }
    if ($accountTypeCounts.Count -gt 0) {
        $typeSummary = @($accountTypeCounts.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { "$($_.Value) $($_.Name)" }) -join ', '
        Write-MigrationLog -Message "Export includes non-user accounts ($typeSummary) - check the AccountType column before feeding the CSV to Remove-/Set-MigrationTeamsPhoneAssignments." -Level WARNING
    }

    $withNumber = @($users | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) }).Count
    Write-MigrationLog -Message "Users to export: $($users.Count) ($withNumber with a phone number, $($users.Count - $withNumber) without)" -Level INFO

    # $exportRows carries the round-trip columns exactly as the Set-/Remove- scripts read
    # them; $results is the toolkit's standard summary of the same pass.
    $exportRows = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    $usersWithAdditionalNumbers = 0
    $index = 0

    foreach ($user in $users) {
        $index++
        $upn = [string]$user.UserPrincipalName

        Write-Progress -Activity 'Exporting Teams phone assignments' `
            -Status "$index of $($users.Count): $upn" `
            -PercentComplete (($index / [math]::Max($users.Count, 1)) * 100)

        $status = 'Failed'
        $detail = ''
        $phoneNumber = $null
        $numberType = $null

        try {
            $line = Split-MigrationTeamsLineUri -LineUri $user.LineUri
            $userId = [string]$user.Identity
            $accountType = [string](Get-MigrationProperty -InputObject $user -Name 'AccountType' -Default '')

            # Resolve the inventory row for the number in the user's LineUri. Only a blank
            # LineUri falls back to the per-user map; otherwise a second line held by the same
            # user could supply the wrong type and location.
            $numberInfo = $null
            $phoneKey = $null
            if ($line.Number) {
                $phoneKey = if ($line.Extension) { "$($line.Number);ext=$($line.Extension)" } else { $line.Number }
                if ($numbersByPhone.ContainsKey($phoneKey)) {
                    $numberInfo = $numbersByPhone[$phoneKey]
                }
                elseif ($line.Extension -and $numbersByPhone.ContainsKey($line.Number)) {
                    # The LineUri carries an extension the inventory row does not. Accept the
                    # bare number only when the inventory says it belongs to this user.
                    $bare = $numbersByPhone[$line.Number]
                    $bareTarget = [string](Get-MigrationProperty -InputObject $bare -Name 'AssignedPstnTargetId' -Default '')
                    if ($userId -and $bareTarget -eq $userId) { $numberInfo = $bare }
                }
            }
            elseif ($userId -and $numbersByTarget.ContainsKey($userId)) {
                $numberInfo = $numbersByTarget[$userId]
            }

            $phoneNumber = if ($line.Number) { $line.Number }
            elseif ($numberInfo) { [string]$numberInfo.TelephoneNumber }
            else { $null }

            $numberType = if ($numberInfo) { [string]$numberInfo.NumberType }
            elseif ($line.Number) { 'DirectRouting' }
            else { $null }

            # Every other inventory row assigned to this user is an Alternate/Private line the
            # Set- script will not carry; list them so the operator can handle them by hand.
            $exportedNumber = if ($numberInfo) { [string](Get-MigrationProperty -InputObject $numberInfo -Name 'TelephoneNumber' -Default '') } else { $phoneKey }
            $additionalNumbers = [System.Collections.Generic.List[string]]::new()
            if ($userId -and $numbersPerTarget.ContainsKey($userId)) {
                foreach ($held in $numbersPerTarget[$userId]) {
                    $heldNumber = [string](Get-MigrationProperty -InputObject $held -Name 'TelephoneNumber' -Default '')
                    if ([string]::IsNullOrWhiteSpace($heldNumber) -or $heldNumber -eq $exportedNumber) { continue }
                    $heldCategory = [string](Get-MigrationProperty -InputObject $held -Name 'AssignmentCategory' -Default '')
                    $additionalNumbers.Add($(if ($heldCategory) { "${heldNumber}:${heldCategory}" } else { $heldNumber }))
                }
            }
            if ($additionalNumbers.Count -gt 0) { $usersWithAdditionalNumbers++ }

            $exportRows.Add([pscustomobject][ordered]@{
                    UserPrincipalName        = $user.UserPrincipalName
                    DisplayName              = $user.DisplayName
                    PhoneNumber              = $phoneNumber
                    Extension                = $line.Extension
                    PhoneNumberType          = $numberType
                    EnterpriseVoiceEnabled   = $user.EnterpriseVoiceEnabled
                    OnlineVoiceRoutingPolicy = Get-MigrationTeamsPolicyName -Policy $user.OnlineVoiceRoutingPolicy
                    TenantDialPlan           = Get-MigrationTeamsPolicyName -Policy $user.TenantDialPlan
                    TeamsCallingPolicy       = Get-MigrationTeamsPolicyName -Policy $user.TeamsCallingPolicy
                    LocationId               = if ($numberInfo) { [string]$numberInfo.LocationId } else { $null }
                    UsageLocation            = $user.UsageLocation
                    AccountEnabled           = $user.AccountEnabled
                    LineUri                  = $user.LineUri
                    AccountType              = $accountType
                    AdditionalNumbers        = ($additionalNumbers -join ';')
                })

            $status = if ($isDryRun) { 'Planned' } else { 'Succeeded' }
            $typeNote = if ($accountType) { " Account type $accountType." } else { '' }
            $detail = if ($phoneNumber) { "Read assignment $phoneNumber ($numberType).$typeNote" } else { "No phone number assigned.$typeNote" }
        }
        catch {
            $status = 'Failed'
            $detail = $_.Exception.Message
            $exitCode = 2
        }

        $results.Add([pscustomobject][ordered]@{
                Identity        = $upn
                Action          = 'Export phone assignment'
                Status          = $status
                Detail          = $detail
                PhoneNumber     = $phoneNumber
                PhoneNumberType = $numberType
            })
    }

    Write-Progress -Activity 'Exporting Teams phone assignments' -Completed

    if ($usersWithAdditionalNumbers -gt 0) {
        Write-MigrationLog -Message "$usersWithAdditionalNumbers user(s) hold Alternate/Private numbers beyond the one in PhoneNumber. They are listed in the AdditionalNumbers column; Set-MigrationTeamsPhoneAssignments will not carry them." -Level WARNING
    }

    if ($exportRows.Count -eq 0) {
        Write-MigrationLog -Message 'No users matched - nothing to export.' -Level WARNING
    }
    else {
        & $writeCsv $exportRows.ToArray() $assignmentsCsv 'Assignments'
    }

    if ($IncludeUnassignedNumbers) {
        $unassigned = @($allNumbers | Where-Object { [string]$_.PstnAssignmentStatus -eq 'Unassigned' })
        Write-MigrationLog -Message "Unassigned numbers in inventory: $($unassigned.Count)" -Level INFO

        if ($unassigned.Count -gt 0) {
            $unassignedReport = @($unassigned | ForEach-Object {
                    [pscustomobject][ordered]@{
                        PhoneNumber        = $_.TelephoneNumber
                        PhoneNumberType    = [string]$_.NumberType
                        AssignmentCategory = [string]$_.AssignmentCategory
                        Capability         = ($_.Capability -join ';')
                        IsoCountryCode     = $_.IsoCountryCode
                        LocationId         = [string]$_.LocationId
                        ActivationState    = [string]$_.ActivationState
                    }
                })
            & $writeCsv $unassignedReport $unassignedCsv 'Unassigned numbers'
        }
    }

    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Get-TeamsPhoneAssignments'
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
