#Requires -Version 7.0

<#
.SYNOPSIS
    Bulk-assigns Microsoft Teams phone numbers - to a single user, or to users
    listed in a CSV (by UPN). Can also list every unassigned phone number in the
    tenant so you know what is available before assigning.

.DESCRIPTION
    The destination-tenant half of a Teams Phone migration. After numbers are
    released in the source (Remove-MigrationTeamsPhoneAssignments.ps1) and land
    in the destination tenant, this script assigns them back to users.

    The work is supplied one of three ways (choose exactly one):
      -User + -PhoneNumber   Assign one number to one user. Handy for rehearsing
                             the flow before running the batch.
      -CsvPath               A CSV pairing users (UPN) with phone numbers. The
                             export from Get-MigrationTeamsPhoneAssignments.ps1
                             and the results CSV from
                             Remove-MigrationTeamsPhoneAssignments.ps1 both work
                             directly. Every row is processed, so "all users" is
                             simply the full export CSV.
      -ListUnassigned        No changes - list every telephone number in the
                             tenant inventory that is NOT assigned to anyone and
                             export it to a CSV.

    Phone numbers are normalised automatically (a leading 'tel:', spaces,
    dashes and parentheses are stripped; a missing leading '+' is added), and
    ';ext=' extensions are preserved.

    The number type (CallingPlan / OperatorConnect / DirectRouting) is
    auto-detected from the tenant's number inventory when the CSV / parameters
    don't provide one: numbers found in the inventory use their real type,
    numbers not in the inventory are assumed to be Direct Routing. A number that
    is already assigned to a DIFFERENT user is reported as Failed rather than
    stolen from its current owner.

    If the CSV has an OnlineVoiceRoutingPolicy column (or -VoiceRoutingPolicy is
    passed), the policy is granted after a successful assignment - Direct
    Routing numbers don't work without one.

    Supports -WhatIf / -Confirm and a dedicated -DryRun that resolves and
    reports exactly what would be assigned without changing anything.

.PARAMETER User
    A single user (UPN or object ID) to assign -PhoneNumber to.

.PARAMETER PhoneNumber
    The phone number to assign to -User, in E.164 format (e.g. +15551234567 or
    +15551234567;ext=123). Common formatting is cleaned up automatically.

.PARAMETER PhoneNumberType
    The number type: CallingPlan, OperatorConnect, OCMobile or DirectRouting.
    Auto-detected from the tenant number inventory when omitted.

.PARAMETER LocationId
    Emergency location ID to associate with the assignment (Calling Plan /
    Operator Connect). Auto-filled from a LocationId CSV column when present.

.PARAMETER VoiceRoutingPolicy
    Online voice routing policy to grant after assignment (required for Direct
    Routing numbers to place PSTN calls). With -CsvPath, an
    OnlineVoiceRoutingPolicy / VoiceRoutingPolicy column does the same per row.

.PARAMETER CsvPath
    Path to a CSV pairing users with numbers. Recognised columns
    (case-insensitive):
      UPN         : UserPrincipalName, UPN, User Principal Name, Email,
                    PrimaryEmail, Mail, UserName            (required)
      PhoneNumber : PhoneNumber, TelephoneNumber, Phone, Number, LineUri,
                    Phone Number                            (required)
      Type        : PhoneNumberType, NumberType, Type       (optional)
      Location    : LocationId, Location Id                 (optional)
      Policy      : OnlineVoiceRoutingPolicy, VoiceRoutingPolicy (optional)

.PARAMETER ListUnassigned
    Read-only. List every unassigned telephone number in the tenant inventory
    and export it to a CSV. Note: Direct Routing numbers only appear in the
    inventory if they were uploaded/acquired there - unassigned DR ranges
    managed purely on your SBC won't show.

.PARAMETER OutputPath
    Directory where the results CSV (or the unassigned-numbers CSV) is written.
    Defaults to the current directory.

.PARAMETER TenantId
    Tenant ID (GUID) to sign in to. Useful for MSP / multi-tenant admins so the
    interactive sign-in lands in the intended tenant.

.PARAMETER DryRun
    Preview only - make no changes. Resolves users and numbers and reports what
    would be assigned, but changes nothing.

.EXAMPLE
    .\Set-MigrationTeamsPhoneAssignments.ps1 -ListUnassigned

.EXAMPLE
    .\Set-MigrationTeamsPhoneAssignments.ps1 -User john.smith@contoso.com -PhoneNumber +15551234567 -DryRun

.EXAMPLE
    .\Set-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Source_TeamsPhoneAssignments.csv -DryRun

.EXAMPLE
    .\Set-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\TeamsPhone-Removals_20260705-101500.csv

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, MicrosoftTeams module
    Permissions : Teams Administrator (or Teams Communications Administrator).
                  Users must hold a Teams Phone license (e.g. Teams Phone
                  Standard) before a number can be assigned - unlicensed users
                  are reported as Failed by the service.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Csv')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'User')]
    [string]$User,

    [Parameter(Mandatory = $true, ParameterSetName = 'User')]
    [string]$PhoneNumber,

    [Parameter(Mandatory = $false, ParameterSetName = 'User')]
    [ValidateSet('CallingPlan', 'OperatorConnect', 'OCMobile', 'DirectRouting')]
    [string]$PhoneNumberType,

    [Parameter(Mandatory = $false, ParameterSetName = 'User')]
    [string]$LocationId,

    [Parameter(Mandatory = $false, ParameterSetName = 'User')]
    [string]$VoiceRoutingPolicy,

    [Parameter(Mandatory = $true, ParameterSetName = 'Csv')]
    [string]$CsvPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Unassigned')]
    [switch]$ListUnassigned,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

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
    <# Defaults to the current directory for the results CSV. #>
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        $resolved = $Path
    }
    else {
        $resolved = (Get-Location).Path
        Write-Host ''
        Write-Host "No -OutputPath provided - writing results to the current directory:" -ForegroundColor Cyan
        Write-Host "  $resolved" -ForegroundColor Cyan
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

function Format-E164PhoneNumber {
    <#
        Normalises a phone number to E.164: strips 'tel:', spaces, dashes,
        dots and parentheses, keeps a ';ext=' suffix, and adds a leading '+'
        when the remainder is all digits. Returns $null for unusable input.
    #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $number = $Value.Trim() -replace '^(?i)tel:', ''
    $extension = $null
    if ($number -match '^(?<num>[^;]+);(?i)ext=(?<ext>.+)$') {
        $number = $Matches['num']
        $extension = $Matches['ext'].Trim()
    }

    $number = $number -replace '[\s\-\.\(\)]', ''
    if ($number -match '^\+?\d+$') {
        if (-not $number.StartsWith('+')) { $number = "+$number" }
    }
    else {
        return $null
    }

    if ($extension) { return "$number;ext=$extension" }
    return $number
}

function Get-AllPhoneNumberAssignments {
    <# Pages through the tenant telephone number inventory. #>
    param([hashtable]$Filter = @{})

    $all = [System.Collections.Generic.List[object]]::new()
    $pageSize = 1000
    $skip = 0
    while ($true) {
        $page = @(Get-CsPhoneNumberAssignment @Filter -Top $pageSize -Skip $skip)
        if ($page.Count -gt 0) { $all.AddRange($page) }
        if ($page.Count -lt $pageSize) { break }
        $skip += $pageSize
    }
    return $all
}

function Resolve-TeamsUserByIdentity {
    <# Resolves a UPN or object ID to a Teams user object (or $null). #>
    param([Parameter(Mandatory)][string]$Identity)
    try {
        return Get-CsOnlineUser -Identity $Identity -ErrorAction Stop
    }
    catch {
        return $null
    }
}

#endregion ---------------------------------------------------------------------

Write-Host '=== M365 Migration - Teams Phone Number Assignment ===' -ForegroundColor Cyan

# Validate inputs that do not need Teams first.
if ($PSCmdlet.ParameterSetName -eq 'Csv' -and -not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

Initialize-RequiredModule -Name 'MicrosoftTeams'
Import-Module MicrosoftTeams -ErrorAction Stop

Write-Host 'Connecting to Microsoft Teams...' -ForegroundColor Cyan
$connectParams = @{}
if ($TenantId) { $connectParams['TenantId'] = $TenantId }
Connect-MicrosoftTeams @connectParams | Out-Null

$tenant = Get-CsTenant -ErrorAction SilentlyContinue
if ($tenant) {
    Write-Host "Connected to tenant: $($tenant.DisplayName) [$($tenant.TenantId)]" -ForegroundColor Green
}

#region List unassigned numbers (read-only mode) --------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Unassigned') {
    Write-Host 'Retrieving unassigned telephone numbers...' -ForegroundColor Cyan
    $unassigned = @(Get-AllPhoneNumberAssignments -Filter @{ PstnAssignmentStatus = 'Unassigned' })

    if ($unassigned.Count -eq 0) {
        Write-Host 'No unassigned numbers found in the tenant inventory.' -ForegroundColor Yellow
    }
    else {
        $report = $unassigned | ForEach-Object {
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
        $report | Format-Table PhoneNumber, PhoneNumberType, IsoCountryCode, ActivationState -AutoSize | Out-Host
        Write-Host "Unassigned numbers: $($unassigned.Count)" -ForegroundColor Green

        if (-not $DryRun) {
            $unassignedCsv = Join-Path -Path $outputDir -ChildPath "TeamsPhoneNumbers-Unassigned_$timestamp.csv"
            $report | Export-Csv -Path $unassignedCsv -NoTypeInformation -Encoding UTF8
            Write-Host "Unassigned numbers CSV: $unassignedCsv" -ForegroundColor Cyan
        }
    }

    Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
    Write-Host 'Done.' -ForegroundColor Green
    return
}

#endregion ---------------------------------------------------------------------

#region Build the work list -----------------------------------------------------

# Each item: Identity (as supplied), PhoneNumber (raw), PhoneNumberType,
# LocationId, VoiceRoutingPolicy - resolved/validated in the assignment loop.
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
        $rows = @(Import-Csv -LiteralPath $CsvPath)
        if ($rows.Count -eq 0) { throw "CSV '$CsvPath' contains no rows." }

        $headers = $rows[0].PSObject.Properties.Name
        $upnCol = Resolve-ColumnName -Headers $headers -Candidates @(
            'UserPrincipalName', 'UPN', 'User Principal Name',
            'Email', 'PrimaryEmail', 'Mail', 'UserName', 'User Name'
        )
        $numberCol = Resolve-ColumnName -Headers $headers -Candidates @(
            'PhoneNumber', 'TelephoneNumber', 'Phone Number', 'Phone', 'Number', 'LineUri', 'LineURI'
        )
        $typeCol = Resolve-ColumnName -Headers $headers -Candidates @('PhoneNumberType', 'NumberType', 'Type')
        $locationCol = Resolve-ColumnName -Headers $headers -Candidates @('LocationId', 'Location Id', 'EmergencyLocationId')
        $policyCol = Resolve-ColumnName -Headers $headers -Candidates @('OnlineVoiceRoutingPolicy', 'VoiceRoutingPolicy')
        $extensionCol = Resolve-ColumnName -Headers $headers -Candidates @('Extension', 'Ext')

        if (-not $upnCol) {
            throw "Could not find a UserPrincipalName/UPN/Email column in '$CsvPath'. Headers: $($headers -join ', ')"
        }
        if (-not $numberCol) {
            throw "Could not find a PhoneNumber/TelephoneNumber/LineUri column in '$CsvPath'. Headers: $($headers -join ', ')"
        }

        foreach ($row in $rows) {
            $id = Get-CsvValue -Record $row -Column $upnCol
            if (-not $id) { continue }

            $number = Get-CsvValue -Record $row -Column $numberCol
            # Re-attach a separate Extension column when the number itself has none.
            $extension = Get-CsvValue -Record $row -Column $extensionCol
            if ($number -and $extension -and $number -notmatch ';(?i)ext=') {
                $number = "$number;ext=$extension"
            }

            $workItems.Add([pscustomobject]@{
                    Identity           = $id
                    PhoneNumber        = $number
                    PhoneNumberType    = Get-CsvValue -Record $row -Column $typeCol
                    LocationId         = Get-CsvValue -Record $row -Column $locationCol
                    VoiceRoutingPolicy = Get-CsvValue -Record $row -Column $policyCol
                })
        }
    }
}

if ($workItems.Count -eq 0) {
    Write-Host 'No rows with a user to process. Nothing to do.' -ForegroundColor Yellow
    Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
    return
}

Write-Host "Assignments to process: $($workItems.Count)" -ForegroundColor Cyan

# One paged pull of the number inventory: used to auto-detect each number's
# type and to refuse numbers already assigned to someone else.
Write-Host 'Retrieving telephone number inventory...' -ForegroundColor Cyan
$numbersByTelephone = @{}
foreach ($num in (Get-AllPhoneNumberAssignments)) {
    if (-not [string]::IsNullOrWhiteSpace($num.TelephoneNumber)) {
        $numbersByTelephone[[string]$num.TelephoneNumber] = $num
    }
}

#endregion ---------------------------------------------------------------------

#region Assignment loop ---------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
$index = 0
$validTypes = @('CallingPlan', 'OperatorConnect', 'OCMobile', 'DirectRouting')

foreach ($item in $workItems) {
    $index++
    Write-Progress -Activity 'Assigning phone numbers' `
        -Status "$index of $($workItems.Count): $($item.Identity)" `
        -PercentComplete (($index / [math]::Max($workItems.Count, 1)) * 100)

    $status = 'Assigned'
    $detail = ''
    $upn = $item.Identity
    $displayName = $null
    $number = Format-E164PhoneNumber -Value $item.PhoneNumber
    $numberType = $item.PhoneNumberType
    $policy = $item.VoiceRoutingPolicy

    try {
        if (-not $number) {
            $status = 'Skipped'
            $detail = "No usable phone number ('$($item.PhoneNumber)')."
        }
        else {
            $target = Resolve-TeamsUserByIdentity -Identity $item.Identity
            if (-not $target) { throw "User not found in this tenant." }
            $upn = $target.UserPrincipalName
            $displayName = $target.DisplayName

            # The inventory is keyed without any extension suffix.
            $bareNumber = ($number -split ';')[0]
            $numberInfo = if ($numbersByTelephone.ContainsKey($bareNumber)) { $numbersByTelephone[$bareNumber] } else { $null }

            if ($numberInfo -and -not [string]::IsNullOrWhiteSpace($numberInfo.AssignedPstnTargetId) -and
                [string]$numberInfo.AssignedPstnTargetId -ne [string]$target.Identity) {
                throw "Number $bareNumber is already assigned to another target ($($numberInfo.AssignedPstnTargetId)). Unassign it first."
            }

            if ([string]::IsNullOrWhiteSpace($numberType)) {
                # Numbers absent from the tenant inventory are Direct Routing -
                # Calling Plan / Operator Connect numbers always appear there.
                $numberType = if ($numberInfo) { [string]$numberInfo.NumberType } else { 'DirectRouting' }
            }
            $matchedType = $validTypes | Where-Object { $_ -ieq $numberType } | Select-Object -First 1
            if (-not $matchedType) {
                throw "Unknown PhoneNumberType '$numberType'. Expected one of: $($validTypes -join ', ')."
            }
            $numberType = $matchedType

            if (-not $DryRun -and $PSCmdlet.ShouldProcess($upn, "Assign phone number $number ($numberType)")) {
                $assignParams = @{
                    Identity        = $upn
                    PhoneNumber     = $number
                    PhoneNumberType = $numberType
                    ErrorAction     = 'Stop'
                }
                if ($item.LocationId) { $assignParams['LocationId'] = $item.LocationId }
                Set-CsPhoneNumberAssignment @assignParams
                $detail = "Assigned $number ($numberType)."

                if ($policy) {
                    Grant-CsOnlineVoiceRoutingPolicy -Identity $upn -PolicyName $policy -ErrorAction Stop
                    $detail += " Granted voice routing policy '$policy'."
                }
            }
            else {
                $status = 'WhatIf'
                $detail = "Would assign $number ($numberType)."
                if ($policy) { $detail += " Would grant voice routing policy '$policy'." }
            }
        }
    }
    catch {
        $status = 'Failed'
        $message = $_.Exception.Message
        if ($message -match 'license|licence|capability') {
            $detail = "The user likely lacks a Teams Phone license (assignment needs e.g. Teams Phone Standard). Original error: $message"
        }
        else {
            $detail = $message
        }
    }

    $color = switch ($status) {
        'Assigned' { 'Green' }
        'WhatIf'   { 'Cyan' }
        'Skipped'  { 'Yellow' }
        default    { 'Red' }
    }
    Write-Host ("  [{0}] {1} - {2}" -f $status, $upn, $detail) -ForegroundColor $color

    $results.Add([pscustomobject][ordered]@{
            UserPrincipalName        = $upn
            DisplayName              = $displayName
            PhoneNumber              = $number
            PhoneNumberType          = $numberType
            LocationId               = $item.LocationId
            OnlineVoiceRoutingPolicy = $policy
            Status                   = $status
            Detail                   = $detail
        })
}

Write-Progress -Activity 'Assigning phone numbers' -Completed

#endregion ---------------------------------------------------------------------

$assigned = ($results | Where-Object Status -eq 'Assigned').Count
$failed = ($results | Where-Object Status -eq 'Failed').Count
$skipped = ($results | Where-Object Status -eq 'Skipped').Count
$whatif = ($results | Where-Object Status -eq 'WhatIf').Count

Write-Host ''
if ($DryRun) {
    Write-Host "DRY RUN: $whatif number(s) would be assigned, $skipped skipped, $failed error(s). No changes made, no results CSV written." -ForegroundColor Magenta
}
else {
    $resultsCsv = Join-Path -Path $outputDir -ChildPath "TeamsPhone-Assignments_$timestamp.csv"
    $results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Assigned: $assigned   Skipped: $skipped   Failed: $failed   WhatIf: $whatif" -ForegroundColor Green
    Write-Host "Results CSV: $resultsCsv" -ForegroundColor Cyan
}

Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
Write-Host 'Done.' -ForegroundColor Green
