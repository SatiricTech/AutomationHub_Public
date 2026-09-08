#Requires -Version 7.4

<#
.SYNOPSIS
    Exports every Microsoft Teams phone number assignment in a tenant to a CSV - one row per
    user with their assigned number, number type and voice settings.

.DESCRIPTION
    Connects to Microsoft Teams and reads the tenant's telephone number inventory plus every
    user's Teams voice configuration, then writes a CSV pairing each user (UPN) with their
    currently assigned phone number. The export is designed to feed the other two Teams Phone
    scripts in this toolkit:

      Remove-MigrationTeamsPhoneAssignments.ps1  - bulk-unassign in the source
      Set-MigrationTeamsPhoneAssignments.ps1     - bulk-reassign in the destination

    The assignments CSV columns are the round-trip contract between those three scripts and
    are deliberately left exactly as they are: UserPrincipalName, DisplayName, PhoneNumber
    (E.164), Extension, PhoneNumberType (CallingPlan / OperatorConnect / DirectRouting),
    EnterpriseVoiceEnabled, OnlineVoiceRoutingPolicy, TenantDialPlan, TeamsCallingPolicy,
    LocationId, UsageLocation, AccountEnabled and LineUri.

    EVERY user is exported, whether or not they have a phone number - users without one
    simply have blank phone columns, so the CSV is also your list of who still needs a
    number. Use -OnlyUsersWithNumbers to narrow the export to users that currently have an
    assignment.

    The number inventory is pulled once (paged) and joined to the user list locally, so users
    are not queried one number at a time. The script is read-only against the tenant.

    Alongside the assignments CSV the run writes the toolkit's standard results file, one row
    per user in the Identity / Action / Status / Detail shape, so a Teams Phone export
    summarises the same way every other script in the toolkit does.

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
    Tenant ID (GUID) to sign in to. Useful for MSP / multi-tenant admins so the interactive
    sign-in lands in the intended tenant.

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
    .\Get-MigrationTeamsPhoneAssignments.ps1 -Prefix Source

    Signs in interactively and writes Source\Source_TeamsPhoneAssignments_<timestamp>.csv
    plus the run log and results file.

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
                  Connect-MicrosoftTeams. -DelegatedOrganization is an Exchange Online
                  concept and does not apply - this script never connects to Exchange.

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
$run = Initialize-MigrationRun -ScriptName 'Get-MigrationTeamsPhoneAssignments' -OutputPath $OutputPath `
    -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    $isDryRun = [bool]$run.DryRun
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leader = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
    $assignmentsCsv = Join-Path -Path $run.OutputDirectory -ChildPath "${leader}TeamsPhoneAssignments_$timestamp.csv"
    $unassignedCsv = Join-Path -Path $run.OutputDirectory -ChildPath "${leader}TeamsPhoneNumbers-Unassigned_$timestamp.csv"

    $null = Connect-MigrationTeams -TenantId $TenantId

    #region Pull number inventory and users ------------------------------------

    Write-MigrationLog -Message 'Retrieving telephone number inventory...' -Level INFO
    $allNumbers = @(Get-MigrationPhoneNumberInventory)
    Write-MigrationLog -Message "Numbers in inventory: $($allNumbers.Count)" -Level INFO

    # Index the inventory by the assigned user's object ID so each user's number type and
    # location resolve without a per-user lookup. Direct Routing numbers that were never
    # uploaded to the inventory simply are not in this map - the user's LineUri still
    # captures the number itself.
    $numbersByTarget = @{}
    foreach ($number in $allNumbers) {
        if (-not [string]::IsNullOrWhiteSpace($number.AssignedPstnTargetId)) {
            $numbersByTarget[[string]$number.AssignedPstnTargetId] = $number
        }
    }

    Write-MigrationLog -Message 'Retrieving Teams users (this can take a while on large tenants)...' -Level INFO
    $users = $null
    if ($OnlyUsersWithNumbers) {
        # Server-side filter keeps the pull small; fall back to a full pull if the connected
        # module version rejects the filter syntax.
        try {
            $users = @(Get-CsOnlineUser -Filter 'LineUri -ne $null' -ErrorAction Stop)
        }
        catch {
            Write-MigrationLog -Message 'Server-side LineUri filter not supported by this module version - pulling all users and filtering locally.' -Level WARNING
            $users = $null
        }
    }
    if ($null -eq $users) {
        $users = @(Get-CsOnlineUser -ErrorAction Stop)
        if ($OnlyUsersWithNumbers) {
            $users = @($users | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) })
        }
    }

    $withNumber = @($users | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) }).Count
    Write-MigrationLog -Message "Users to export: $($users.Count) ($withNumber with a phone number, $($users.Count - $withNumber) without)" -Level INFO

    #endregion -----------------------------------------------------------------

    #region Build the export ---------------------------------------------------

    # $exportRows carries the round-trip columns exactly as the Set-/Remove- scripts read
    # them; $results is the toolkit's standard summary of the same pass.
    $exportRows = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
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
            $numberInfo = if ($userId -and $numbersByTarget.ContainsKey($userId)) { $numbersByTarget[$userId] } else { $null }

            $phoneNumber = if ($line.Number) { $line.Number }
            elseif ($numberInfo) { [string]$numberInfo.TelephoneNumber }
            else { $null }

            $numberType = if ($numberInfo) { [string]$numberInfo.NumberType }
            elseif ($line.Number) { 'DirectRouting' }
            else { $null }

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
                })

            $status = if ($isDryRun) { 'Planned' } else { 'Succeeded' }
            $detail = if ($phoneNumber) { "Read assignment $phoneNumber ($numberType)." } else { 'No phone number assigned.' }
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

    #endregion -----------------------------------------------------------------

    #region Write the files ----------------------------------------------------

    if ($exportRows.Count -eq 0) {
        Write-MigrationLog -Message 'No users matched - nothing to export.' -Level WARNING
    }
    elseif ($isDryRun) {
        Write-MigrationLog -Message "[DRYRUN] Would write $($exportRows.Count) assignment row(s) to $assignmentsCsv" -Level WARNING
    }
    else {
        try {
            $exportRows | Export-Csv -LiteralPath $assignmentsCsv -NoTypeInformation -Encoding utf8 -ErrorAction Stop
        }
        catch {
            throw "Could not write the assignments CSV '$assignmentsCsv': $($_.Exception.Message)"
        }
        Write-MigrationLog -Message "Assignments CSV ($($exportRows.Count) row(s)): $assignmentsCsv" -Level SUCCESS
    }

    if ($IncludeUnassignedNumbers) {
        $unassigned = @($allNumbers | Where-Object { [string]$_.PstnAssignmentStatus -eq 'Unassigned' })
        Write-MigrationLog -Message "Unassigned numbers in inventory: $($unassigned.Count)" -Level INFO

        if ($unassigned.Count -gt 0) {
            $unassignedReport = $unassigned | ForEach-Object {
                [pscustomobject][ordered]@{
                    PhoneNumber        = $_.TelephoneNumber
                    PhoneNumberType    = [string]$_.NumberType
                    AssignmentCategory = [string]$_.AssignmentCategory
                    Capability         = ($_.Capability -join ';')
                    IsoCountryCode     = $_.IsoCountryCode
                    LocationId         = [string]$_.LocationId
                    ActivationState    = [string]$_.ActivationState
                }
            }

            if ($isDryRun) {
                Write-MigrationLog -Message "[DRYRUN] Would write $($unassigned.Count) unassigned number(s) to $unassignedCsv" -Level WARNING
            }
            else {
                try {
                    $unassignedReport | Export-Csv -LiteralPath $unassignedCsv -NoTypeInformation -Encoding utf8 -ErrorAction Stop
                }
                catch {
                    throw "Could not write the unassigned-numbers CSV '$unassignedCsv': $($_.Exception.Message)"
                }
                Write-MigrationLog -Message "Unassigned numbers CSV: $unassignedCsv" -Level SUCCESS
            }
        }
    }

    #endregion -----------------------------------------------------------------

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
