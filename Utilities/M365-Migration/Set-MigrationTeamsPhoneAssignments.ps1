#Requires -Version 7.4

<#
.SYNOPSIS
    Bulk-assigns Microsoft Teams phone numbers - to a single user, or to users listed in a CSV
    (by UPN). Can also list every unassigned phone number in the tenant so you know what is
    available before assigning.

.DESCRIPTION
    The destination-tenant half of a Teams Phone migration. After numbers are released in the
    source (Remove-MigrationTeamsPhoneAssignments.ps1) and land in the destination tenant,
    this script assigns them back to users.

    The work is supplied one of three ways (choose exactly one): -User + -PhoneNumber (one
    number to one user, to rehearse the flow), -CsvPath (a CSV pairing users with numbers -
    both the Get- export and the Remove- results file work directly, so "all users" is simply
    the full export CSV), or -ListUnassigned (no changes; lists every free number in the
    tenant inventory into the same CSV name the Get- script writes).

    Phone numbers are normalised automatically (a leading 'tel:', spaces, dashes and
    parentheses are stripped; a missing leading '+' is added), and ';ext=' extensions are
    preserved. The number type (CallingPlan / OperatorConnect / DirectRouting) is
    auto-detected from the tenant's inventory when nothing supplies one - numbers absent from
    the inventory are assumed to be Direct Routing. A number already assigned to a DIFFERENT
    user is reported as Failed rather than stolen from its current owner.

    If the CSV has an OnlineVoiceRoutingPolicy column (or -VoiceRoutingPolicy is passed), the
    policy is granted after a successful assignment - Direct Routing numbers do not place
    PSTN calls without one.

    DryRun connects read-only, resolves every user and number, writes a -DryRun_ results file
    whose rows are Status 'Planned', and changes nothing.

.PARAMETER User
    A single user (UPN or object ID) to assign -PhoneNumber to.

.PARAMETER PhoneNumber
    The phone number to assign to -User, in E.164 format (e.g. +15551234567 or
    +15551234567;ext=123). Common formatting is cleaned up automatically.

.PARAMETER PhoneNumberType
    The number type: CallingPlan, OperatorConnect, OCMobile or DirectRouting. Auto-detected
    from the tenant number inventory when omitted.

.PARAMETER LocationId
    Emergency location ID to associate with the assignment (Calling Plan / Operator Connect).
    Auto-filled from a LocationId CSV column when present.

.PARAMETER VoiceRoutingPolicy
    Online voice routing policy to grant after assignment (required for Direct Routing
    numbers to place PSTN calls). With -CsvPath, an OnlineVoiceRoutingPolicy /
    VoiceRoutingPolicy column does the same per row.

.PARAMETER CsvPath
    Path to a CSV pairing users with numbers. The user column is resolved through the
    toolkit's shared alias vocabulary (UserPrincipalName, UPN, User Principal Name, UserName,
    User, CurrentUPN, Login), falling back to the primary SMTP column when no UPN column
    exists. The phone columns are resolved locally:
      PhoneNumber : PhoneNumber, TelephoneNumber, Phone Number, Phone, Number, LineUri (required)
      Type        : PhoneNumberType, NumberType                                        (optional)
      Location    : LocationId, Location Id, EmergencyLocationId                       (optional)
      Policy      : OnlineVoiceRoutingPolicy, VoiceRoutingPolicy                       (optional)
      Extension   : Extension, Ext                                                     (optional)
    A bare 'Type' header is no longer read as the number type: the toolkit's shared
    vocabulary claims 'Type' for the plan's ObjectType column. Use 'PhoneNumberType'.

.PARAMETER ListUnassigned
    Read-only. List every unassigned telephone number in the tenant inventory and export it to
    a CSV. Note: Direct Routing numbers only appear in the inventory if they were uploaded or
    acquired there - unassigned DR ranges managed purely on your SBC will not show.

.PARAMETER OutputPath
    Root directory for the log, the results CSV and the unassigned-numbers CSV. Defaults to
    the toolkit's standard root: %LOCALAPPDATA%\Migration-Automations on Windows,
    ~/Migration-Automations elsewhere.

.PARAMETER Prefix
    Names the client or run. When supplied, output lands in <root>\<Prefix>\ and file names
    start with <Prefix>_.

.PARAMETER LogPath
    Overrides the auto-derived log file path.

.PARAMETER TenantId
    Tenant ID (GUID) to sign in to. Useful for MSP / multi-tenant admins so the interactive
    sign-in lands in the intended tenant.

.PARAMETER DryRun
    Preview only. Connects read-only, reports what would be assigned, writes a -DryRun_
    results file with Status 'Planned', and changes nothing.

.PARAMETER Verbosity
    Console noise level: Low (errors and successes), Medium (adds warnings), High
    (everything). The log file always receives every line regardless of this setting.

.EXAMPLE
    .\Set-MigrationTeamsPhoneAssignments.ps1 -ListUnassigned -Prefix Destination

    Writes Destination\Destination_TeamsPhoneNumbers-Unassigned_<timestamp>.csv - the same
    file name Get-MigrationTeamsPhoneAssignments.ps1 -IncludeUnassignedNumbers produces.

.EXAMPLE
    .\Set-MigrationTeamsPhoneAssignments.ps1 -User john.smith@contoso.com -PhoneNumber +15551234567 -DryRun

    Rehearses a single assignment and writes only the DryRun results file.

.EXAMPLE
    .\Set-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Source_TeamsPhoneAssignments.csv -Prefix Destination

    Reassigns every number from a source-tenant export into the destination tenant.

.EXAMPLE
    .\Set-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Contoso_Remove-TeamsPhoneAssignments-Results_20260908-101500.csv -Prefix Contoso

    Restores the numbers a previous Remove- run released, using its results file as the input.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4, the M365Migration module shipped beside this script, and
                  the MicrosoftTeams module (installed on demand).
    Permissions : Teams Administrator, or Teams Communications Administrator. No Graph scopes
                  are used.
    GDAP        : supported through -TenantId, which Connect-MigrationTeams passes to
                  Connect-MicrosoftTeams. This script never connects to Exchange.
    Licensing   : users must hold a Teams Phone license (e.g. Teams Phone Standard) before a
                  number can be assigned. Unlicensed users are reported as Failed by the
                  service, and the row's Detail says so.
    Exit codes  : 0 success, 1 fatal error, 2 completed with one or more failed rows.

    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Csv')]
param(
    [Parameter(Mandatory, ParameterSetName = 'User')]
    [ValidateNotNullOrEmpty()]
    [string]$User,

    [Parameter(Mandatory, ParameterSetName = 'User')]
    [ValidateNotNullOrEmpty()]
    [string]$PhoneNumber,

    [Parameter(ParameterSetName = 'User')]
    [ValidateSet('CallingPlan', 'OperatorConnect', 'OCMobile', 'DirectRouting')]
    [string]$PhoneNumberType,

    [Parameter(ParameterSetName = 'User')]
    [string]$LocationId,

    [Parameter(ParameterSetName = 'User')]
    [string]$VoiceRoutingPolicy,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory, ParameterSetName = 'Unassigned')]
    [switch]$ListUnassigned,

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

$validNumberTypes = @('CallingPlan', 'OperatorConnect', 'OCMobile', 'DirectRouting')

# Header spellings Import-MigrationCsv's shared vocabulary does not already canonicalise.
# 'Type' and 'Email' are deliberately absent: the vocabulary claims them for ObjectType and
# PrimarySmtpAddress, so accepting them here would read the wrong column.
$phoneColumnCandidates = @{
    Number    = @('PhoneNumber', 'TelephoneNumber', 'Phone Number', 'Phone')
    Type      = @('PhoneNumberType')
    Location  = @('LocationId', 'Location Id')
    Policy    = @('OnlineVoiceRoutingPolicy')
    Extension = @('Extension', 'Ext')
}

#endregion ---------------------------------------------------------------------

#region Main -------------------------------------------------------------------

$exitCode = 0
$run = Initialize-MigrationRun -ScriptName 'Set-MigrationTeamsPhoneAssignments' -OutputPath $OutputPath `
    -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    $isDryRun = [bool]$run.DryRun

    # Fail on a bad input path before a sign-in prompt is put in front of the operator.
    if ($PSCmdlet.ParameterSetName -eq 'Csv' -and -not (Test-Path -LiteralPath $CsvPath)) {
        throw "CSV not found: $CsvPath"
    }

    $null = Connect-MigrationTeams -TenantId $TenantId

    if ($PSCmdlet.ParameterSetName -eq 'Unassigned') {
        Write-MigrationLog -Message 'Retrieving unassigned telephone numbers...' -Level INFO
        $unassigned = @(Get-MigrationPhoneNumberInventory -Filter @{ PstnAssignmentStatus = 'Unassigned' })
        Write-MigrationLog -Message "Unassigned numbers: $($unassigned.Count)" -Level INFO

        $unassignedReport = [System.Collections.Generic.List[object]]::new()
        $listResults = [System.Collections.Generic.List[object]]::new()

        foreach ($number in $unassigned) {
            $unassignedReport.Add([pscustomobject][ordered]@{
                    PhoneNumber        = $number.TelephoneNumber
                    PhoneNumberType    = [string]$number.NumberType
                    AssignmentCategory = [string]$number.AssignmentCategory
                    Capability         = ($number.Capability -join ';')
                    IsoCountryCode     = $number.IsoCountryCode
                    LocationId         = [string]$number.LocationId
                    ActivationState    = [string]$number.ActivationState
                })
            $listResults.Add([pscustomobject][ordered]@{
                    Identity        = [string]$number.TelephoneNumber
                    Action          = 'List unassigned number'
                    Status          = if ($isDryRun) { 'Planned' } else { 'Succeeded' }
                    Detail          = "Free in the inventory ($([string]$number.NumberType), $($number.IsoCountryCode))."
                    PhoneNumberType = [string]$number.NumberType
                    IsoCountryCode  = $number.IsoCountryCode
                    ActivationState = [string]$number.ActivationState
                })
        }

        if ($unassigned.Count -eq 0) {
            Write-MigrationLog -Message 'No unassigned numbers found in the tenant inventory.' -Level WARNING
        }
        elseif ($isDryRun) {
            Write-MigrationLog -Message "[DRYRUN] Would write $($unassigned.Count) unassigned number(s) to the unassigned-numbers CSV." -Level WARNING
        }
        else {
            # Same file name Get-MigrationTeamsPhoneAssignments.ps1 -IncludeUnassignedNumbers
            # writes, so the two scripts' output is interchangeable.
            $leader = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
            $unassignedCsv = Join-Path -Path $run.OutputDirectory `
                -ChildPath ("${leader}TeamsPhoneNumbers-Unassigned_" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
            try {
                $unassignedReport | Export-Csv -LiteralPath $unassignedCsv -NoTypeInformation -Encoding utf8 -ErrorAction Stop
            }
            catch {
                throw "Could not write the unassigned-numbers CSV '$unassignedCsv': $($_.Exception.Message)"
            }
            Write-MigrationLog -Message "Unassigned numbers CSV: $unassignedCsv" -Level SUCCESS
        }

        $null = Export-MigrationResult -Rows $listResults.ToArray() -Name 'Set-TeamsPhoneNumbers-Unassigned'

        # The finally block below still runs on exit, so Complete-MigrationRun is called
        # exactly once and the exit code survives.
        exit $exitCode
    }

    # Each item: Identity (as supplied), PhoneNumber (raw), PhoneNumberType, LocationId,
    # VoiceRoutingPolicy - resolved and validated in the assignment loop.
    $workItems = [System.Collections.Generic.List[object]]::new()

    switch ($PSCmdlet.ParameterSetName) {
        'User' {
            $workItems.Add([pscustomobject]@{
                    Identity           = $User
                    PhoneNumber        = $PhoneNumber
                    PhoneNumberType    = $PhoneNumberType
                    LocationId         = $LocationId
                    VoiceRoutingPolicy = $VoiceRoutingPolicy
                })
        }

        'Csv' {
            $rows = @(Import-MigrationCsv -Path $CsvPath)
            $headers = @($rows[0].PSObject.Properties.Name)

            # -contains and the PSObject property indexer are both case-insensitive, so the
            # candidate spelling can be handed straight to Get-MigrationCsvValue.
            $pickColumn = {
                param([string[]]$Candidates)
                foreach ($candidate in $Candidates) {
                    if ($headers -contains $candidate) { return $candidate }
                }
                return $null
            }

            # Import-MigrationCsv maps a bare Email/Mail column to PrimarySmtpAddress rather
            # than UserPrincipalName, so fall back to it before giving up on the file.
            $userColumn = & $pickColumn @('UserPrincipalName', 'PrimarySmtpAddress')
            if (-not $userColumn) {
                throw "Could not find a user column in '$CsvPath'. Headers: $($headers -join ', ')"
            }

            $numberColumn = & $pickColumn $phoneColumnCandidates.Number
            if (-not $numberColumn) {
                throw "Could not find a PhoneNumber/TelephoneNumber/LineUri column in '$CsvPath'. Headers: $($headers -join ', ')"
            }

            $typeColumn = & $pickColumn $phoneColumnCandidates.Type
            $locationColumn = & $pickColumn $phoneColumnCandidates.Location
            $policyColumn = & $pickColumn $phoneColumnCandidates.Policy
            $extensionColumn = & $pickColumn $phoneColumnCandidates.Extension

            foreach ($row in $rows) {
                $identity = [string](Get-MigrationCsvValue -Row $row -Name $userColumn -Default '')
                if ([string]::IsNullOrWhiteSpace($identity)) { continue }

                $number = [string](Get-MigrationCsvValue -Row $row -Name $numberColumn -Default '')

                # Re-attach a separate Extension column when the number itself carries none.
                if ($extensionColumn) {
                    $extension = [string](Get-MigrationCsvValue -Row $row -Name $extensionColumn -Default '')
                    if ($number -and $extension -and $number -notmatch ';(?i)ext=') {
                        $number = "$number;ext=$extension"
                    }
                }

                $workItems.Add([pscustomobject]@{
                        Identity           = $identity
                        PhoneNumber        = $number
                        PhoneNumberType    = if ($typeColumn) { [string](Get-MigrationCsvValue -Row $row -Name $typeColumn -Default '') } else { '' }
                        LocationId         = if ($locationColumn) { [string](Get-MigrationCsvValue -Row $row -Name $locationColumn -Default '') } else { '' }
                        VoiceRoutingPolicy = if ($policyColumn) { [string](Get-MigrationCsvValue -Row $row -Name $policyColumn -Default '') } else { '' }
                    })
            }
        }
    }

    Write-MigrationLog -Message "Assignments to process: $($workItems.Count)" -Level INFO

    # One paged pull of the number inventory: used to auto-detect each number's type and to
    # refuse numbers already assigned to someone else.
    Write-MigrationLog -Message 'Retrieving telephone number inventory...' -Level INFO
    $numbersByTelephone = @{}
    foreach ($number in (Get-MigrationPhoneNumberInventory)) {
        if (-not [string]::IsNullOrWhiteSpace($number.TelephoneNumber)) {
            $numbersByTelephone[[string]$number.TelephoneNumber] = $number
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($item in $workItems) {
        $index++
        $identity = $item.Identity

        Write-Progress -Activity 'Assigning phone numbers' `
            -Status "$index of $($workItems.Count): $identity" `
            -PercentComplete (($index / [math]::Max($workItems.Count, 1)) * 100)

        $status = 'Failed'
        $detail = ''
        $displayName = ''
        $number = Format-MigrationE164 -Value $item.PhoneNumber
        $numberType = $item.PhoneNumberType
        $policy = $item.VoiceRoutingPolicy

        try {
            if (-not $number) {
                $status = 'Skipped'
                $detail = "No usable phone number ('$($item.PhoneNumber)')."
            }
            else {
                $target = Resolve-MigrationTeamsUser -Identity $identity
                if ($null -eq $target) { throw 'User not found in this tenant.' }
                $identity = [string]$target.UserPrincipalName
                $displayName = [string]$target.DisplayName

                # The inventory is keyed without any extension suffix.
                $bareNumber = ($number -split ';')[0]
                $numberInfo = if ($numbersByTelephone.ContainsKey($bareNumber)) { $numbersByTelephone[$bareNumber] } else { $null }

                if ($numberInfo -and -not [string]::IsNullOrWhiteSpace($numberInfo.AssignedPstnTargetId) -and
                    [string]$numberInfo.AssignedPstnTargetId -ne [string]$target.Identity) {
                    throw ("Number $bareNumber is already assigned to another target " +
                        "($($numberInfo.AssignedPstnTargetId)). Unassign it first.")
                }

                if ([string]::IsNullOrWhiteSpace($numberType)) {
                    # Numbers absent from the tenant inventory are Direct Routing - Calling
                    # Plan and Operator Connect numbers always appear there.
                    $numberType = if ($numberInfo) { [string]$numberInfo.NumberType } else { 'DirectRouting' }
                }
                $matchedType = $validNumberTypes | Where-Object { $_ -ieq $numberType } | Select-Object -First 1
                if (-not $matchedType) {
                    throw "Unknown PhoneNumberType '$numberType'. Expected one of: $($validNumberTypes -join ', ')."
                }
                $numberType = $matchedType

                $assignParameters = @{
                    Identity        = $identity
                    PhoneNumber     = $number
                    PhoneNumberType = $numberType
                    ErrorAction     = 'Stop'
                }
                if ($item.LocationId) { $assignParameters['LocationId'] = $item.LocationId }

                if ($isDryRun) {
                    $null = Invoke-MigrationAction -Description "Assign $number ($numberType) to $identity" -Action { }
                    $status = 'Planned'
                    $detail = "Would assign $number ($numberType)."
                    if ($policy) {
                        $null = Invoke-MigrationAction -Description "Grant voice routing policy '$policy' to $identity" -Action { }
                        $detail += " Would grant voice routing policy '$policy'."
                    }
                }
                elseif ($PSCmdlet.ShouldProcess($identity, "Assign phone number $number ($numberType)")) {
                    $null = Invoke-MigrationAction -Description "Assign $number ($numberType) to $identity" -Action {
                        Set-CsPhoneNumberAssignment @assignParameters
                    }
                    $status = 'Succeeded'
                    $detail = "Assigned $number ($numberType)."

                    if ($policy) {
                        $null = Invoke-MigrationAction -Description "Grant voice routing policy '$policy' to $identity" -Action {
                            Grant-CsOnlineVoiceRoutingPolicy -Identity $identity -PolicyName $policy -ErrorAction Stop
                        }
                        $detail += " Granted voice routing policy '$policy'."
                    }
                }
                else {
                    $status = 'Planned'
                    $detail = "Skipped by -WhatIf; would have assigned $number ($numberType)."
                    if ($policy) { $detail += " Would grant voice routing policy '$policy'." }
                }
            }
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
            if ($message -match 'license|licence|capability') {
                $detail = 'The user likely lacks a Teams Phone license (assignment needs e.g. Teams Phone ' +
                    "Standard). Original error: $message"
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

        # The columns after the four standard ones are the round-trip contract shared with
        # Get- and Remove-MigrationTeamsPhoneAssignments.ps1.
        $results.Add([pscustomobject][ordered]@{
                Identity                 = $identity
                Action                   = 'Assign phone number'
                Status                   = $status
                Detail                   = $detail
                UserPrincipalName        = $identity
                DisplayName              = $displayName
                PhoneNumber              = $number
                PhoneNumberType          = $numberType
                LocationId               = $item.LocationId
                OnlineVoiceRoutingPolicy = $policy
            })
    }

    Write-Progress -Activity 'Assigning phone numbers' -Completed

    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Set-TeamsPhoneAssignments'
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
