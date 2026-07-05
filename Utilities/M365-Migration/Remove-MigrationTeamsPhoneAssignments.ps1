#Requires -Version 7.0

<#
.SYNOPSIS
    Bulk-unassigns Microsoft Teams phone numbers - from a single user, from
    users listed in a CSV (by UPN), or from every user in the tenant - and logs
    each removed number to a CSV you can use to reassign later.

.DESCRIPTION
    The source-tenant half of a Teams Phone migration. Before numbers can be
    ported or reassigned in the destination tenant they usually have to be
    released in the source. This script removes the Teams phone number
    assignment (Calling Plan, Operator Connect or Direct Routing) from a batch
    of users.

    The target users are supplied one of three ways (choose exactly one):
      -User     A single user (UPN or object ID). Handy for rehearsing the flow
                against one account before running the batch.
      -CsvPath  A CSV of users. The UserPrincipalName / UPN / Email column is
                auto-detected - the export from
                Get-MigrationTeamsPhoneAssignments.ps1 works directly.
      -All      Every user in the tenant that currently has a phone number
                assigned.

    Before each removal the user's current number, number type and voice
    routing policy are captured, and every processed user is written to a
    results CSV. That file uses the same column names the assignment script
    reads (UserPrincipalName, PhoneNumber, PhoneNumberType, LocationId,
    OnlineVoiceRoutingPolicy), so it doubles as your rollback / reassignment
    input.

    Only the number assignment is removed. Voice routing policies, dial plans
    and calling policies are left in place.

    Supports -WhatIf / -Confirm and a dedicated -DryRun that resolves and
    reports exactly which users (and numbers) would be affected without
    changing anything.

.PARAMETER User
    A single user (UPN or object ID) whose phone number should be unassigned.

.PARAMETER CsvPath
    Path to a CSV describing the users to unassign. Recognised UPN column
    headers (case-insensitive): UserPrincipalName, UPN, User Principal Name,
    Email, PrimaryEmail, Mail, UserName.

.PARAMETER All
    Unassign the phone number of EVERY user in the tenant that has one.

.PARAMETER OutputPath
    Directory where the results CSV is written. Defaults to the current
    directory.

.PARAMETER TenantId
    Tenant ID (GUID) to sign in to. Useful for MSP / multi-tenant admins so the
    interactive sign-in lands in the intended tenant.

.PARAMETER DryRun
    Preview only - make no changes. Resolves the target users and reports which
    numbers would be removed, but changes nothing.

.EXAMPLE
    .\Remove-MigrationTeamsPhoneAssignments.ps1 -User john.smith@contoso.com -DryRun

.EXAMPLE
    .\Remove-MigrationTeamsPhoneAssignments.ps1 -CsvPath .\Source_TeamsPhoneAssignments.csv

.EXAMPLE
    .\Remove-MigrationTeamsPhoneAssignments.ps1 -All -DryRun

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, MicrosoftTeams module
    Permissions : Teams Administrator (or Teams Communications Administrator).
                  Hybrid users whose number is set on-premises (OnPremLineURI
                  synced from AD) cannot be unassigned here - change them in
                  on-prem AD instead; such rows are reported as Failed.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Csv')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'User')]
    [string]$User,

    [Parameter(Mandatory = $true, ParameterSetName = 'Csv')]
    [string]$CsvPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'All')]
    [switch]$All,

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
    <# Defaults to the current directory for the removal log. #>
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

function Get-PolicyNameValue {
    <# Teams policy properties come back as strings or objects with .Name - normalise to a string. #>
    param($Policy)
    if ($null -eq $Policy) { return $null }
    if ($Policy.PSObject.Properties['Name']) { return [string]$Policy.Name }
    $text = [string]$Policy
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Split-TeamsLineUri {
    <# Splits a LineUri like 'tel:+15551234567;ext=123' into number and extension. #>
    param([string]$LineUri)
    if ([string]::IsNullOrWhiteSpace($LineUri)) {
        return [pscustomobject]@{ Number = $null; Extension = $null }
    }
    $value = $LineUri.Trim() -replace '^(?i)tel:', ''
    $extension = $null
    if ($value -match '^(?<num>[^;]+);ext=(?<ext>.+)$') {
        $value = $Matches['num']
        $extension = $Matches['ext']
    }
    return [pscustomobject]@{ Number = $value; Extension = $extension }
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

Write-Host '=== M365 Migration - Teams Phone Number Unassignment ===' -ForegroundColor Cyan

# Validate inputs that do not need Teams first.
if ($PSCmdlet.ParameterSetName -eq 'Csv' -and -not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultsCsv = Join-Path -Path $outputDir -ChildPath "TeamsPhone-Removals_$timestamp.csv"

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

#region Build the target list --------------------------------------------------

$targets = [System.Collections.Generic.List[object]]::new()
$notFound = [System.Collections.Generic.List[string]]::new()

switch ($PSCmdlet.ParameterSetName) {
    'User' {
        Write-Host "Resolving single user '$User'..." -ForegroundColor Cyan
        $resolved = Resolve-TeamsUserByIdentity -Identity $User
        if ($resolved) { $targets.Add($resolved) } else { $notFound.Add($User) }
    }

    'Csv' {
        $rows = @(Import-Csv -LiteralPath $CsvPath)
        if ($rows.Count -eq 0) { throw "CSV '$CsvPath' contains no rows." }

        $headers = $rows[0].PSObject.Properties.Name
        $upnCol = Resolve-ColumnName -Headers $headers -Candidates @(
            'UserPrincipalName', 'UPN', 'User Principal Name',
            'Email', 'PrimaryEmail', 'Mail', 'UserName', 'User Name'
        )
        if (-not $upnCol) {
            throw "Could not find a UserPrincipalName/UPN/Email column in '$CsvPath'. Headers: $($headers -join ', ')"
        }

        Write-Host "Resolving $($rows.Count) user(s) from CSV..." -ForegroundColor Cyan
        foreach ($row in $rows) {
            $id = Get-CsvValue -Record $row -Column $upnCol
            if (-not $id) { continue }
            $resolved = Resolve-TeamsUserByIdentity -Identity $id
            if ($resolved) { $targets.Add($resolved) } else { $notFound.Add($id) }
        }
    }

    'All' {
        Write-Host 'Retrieving every user with an assigned phone number...' -ForegroundColor Cyan
        $withNumbers = $null
        try {
            $withNumbers = @(Get-CsOnlineUser -Filter 'LineUri -ne $null')
        }
        catch {
            Write-Host '  Server-side LineUri filter not supported by this module version - pulling all users and filtering locally.' -ForegroundColor Yellow
            $withNumbers = @(Get-CsOnlineUser | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) })
        }
        foreach ($u in $withNumbers) { $targets.Add($u) }
    }
}

foreach ($miss in $notFound) {
    Write-Host "  [Not found] $miss" -ForegroundColor Red
}

if ($targets.Count -eq 0) {
    Write-Host 'No matching users to process. Nothing to do.' -ForegroundColor Yellow
    Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
    return
}

Write-Host "Users to process: $($targets.Count)" -ForegroundColor Cyan

# One paged pull of the number inventory so each user's number type / location
# resolves without a per-user lookup.
Write-Host 'Retrieving telephone number inventory...' -ForegroundColor Cyan
$numbersByTarget = @{}
foreach ($num in (Get-AllPhoneNumberAssignments)) {
    if (-not [string]::IsNullOrWhiteSpace($num.AssignedPstnTargetId)) {
        $numbersByTarget[[string]$num.AssignedPstnTargetId] = $num
    }
}

#endregion ---------------------------------------------------------------------

#region Removal loop -----------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($target in $targets) {
    $index++
    $upn = $target.UserPrincipalName
    Write-Progress -Activity 'Unassigning phone numbers' `
        -Status "$index of $($targets.Count): $upn" `
        -PercentComplete (($index / [math]::Max($targets.Count, 1)) * 100)

    $line = Split-TeamsLineUri -LineUri $target.LineUri
    $userId = [string]$target.Identity
    $numberInfo = if ($userId -and $numbersByTarget.ContainsKey($userId)) { $numbersByTarget[$userId] } else { $null }
    $numberType = if ($numberInfo) { [string]$numberInfo.NumberType } elseif ($line.Number) { 'DirectRouting' } else { $null }

    $status = 'Removed'
    $detail = ''

    if (-not $line.Number) {
        $status = 'Skipped'
        $detail = 'No phone number assigned.'
    }
    else {
        try {
            if (-not $DryRun -and $PSCmdlet.ShouldProcess($upn, "Unassign phone number $($line.Number)")) {
                # -ErrorAction Stop so a failed removal (e.g. an on-prem synced
                # OnPremLineURI) lands in catch and is recorded as Failed.
                Remove-CsPhoneNumberAssignment -Identity $upn -RemoveAll -ErrorAction Stop
                $detail = "Removed $($line.Number) ($numberType)."
            }
            else {
                $status = 'WhatIf'
                $detail = "Would remove $($line.Number) ($numberType)."
            }
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
            if ($message -match 'OnPrem|on-premises|dirsync|synchroniz') {
                $detail = "This number appears to be set on-premises (OnPremLineURI synced from AD) and must be removed in on-prem AD. Original error: $message"
            }
            else {
                $detail = $message
            }
        }
    }

    $color = switch ($status) {
        'Removed' { 'Green' }
        'WhatIf'  { 'Cyan' }
        'Skipped' { 'Yellow' }
        default   { 'Red' }
    }
    Write-Host ("  [{0}] {1} - {2}" -f $status, $upn, $detail) -ForegroundColor $color

    # Same column names Set-MigrationTeamsPhoneAssignments reads, so this log
    # doubles as the reassignment / rollback input.
    $results.Add([pscustomobject][ordered]@{
            UserPrincipalName        = $upn
            DisplayName              = $target.DisplayName
            PhoneNumber              = $line.Number
            Extension                = $line.Extension
            PhoneNumberType          = $numberType
            LocationId               = if ($numberInfo) { [string]$numberInfo.LocationId } else { $null }
            OnlineVoiceRoutingPolicy = Get-PolicyNameValue -Policy $target.OnlineVoiceRoutingPolicy
            Status                   = $status
            Detail                   = $detail
        })
}

Write-Progress -Activity 'Unassigning phone numbers' -Completed

#endregion ---------------------------------------------------------------------

$removed = ($results | Where-Object Status -eq 'Removed').Count
$failed = ($results | Where-Object Status -eq 'Failed').Count
$skipped = ($results | Where-Object Status -eq 'Skipped').Count
$whatif = ($results | Where-Object Status -eq 'WhatIf').Count

Write-Host ''
if ($DryRun) {
    Write-Host "DRY RUN: $whatif number(s) would be removed, $skipped skipped, $failed error(s). No changes made, no results CSV written." -ForegroundColor Magenta
}
else {
    $results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Removed: $removed   Skipped: $skipped   Failed: $failed   WhatIf: $whatif" -ForegroundColor Green
    Write-Host "Results CSV (also usable as the reassignment input): $resultsCsv" -ForegroundColor Cyan
    Write-Host 'Keep this file - it records which number each user had.' -ForegroundColor Yellow
}

Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
Write-Host 'Done.' -ForegroundColor Green
