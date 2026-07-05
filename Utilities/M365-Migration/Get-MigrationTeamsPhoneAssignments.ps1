#Requires -Version 7.0

<#
.SYNOPSIS
    Exports every Microsoft Teams phone number assignment in a tenant to a CSV -
    one row per user with their assigned number, number type and voice settings.

.DESCRIPTION
    Connects to Microsoft Teams (interactive sign-in) and reads the tenant's
    telephone number inventory plus every user's Teams voice configuration, then
    writes a CSV pairing each user (UPN) with their currently assigned phone
    number. The export is designed to feed the other two Teams Phone scripts in
    this toolkit:

      Remove-MigrationTeamsPhoneAssignments.ps1  - bulk-unassign in the source
      Set-MigrationTeamsPhoneAssignments.ps1     - bulk-reassign in the destination

    Columns include UserPrincipalName, DisplayName, PhoneNumber (E.164),
    Extension, PhoneNumberType (CallingPlan / OperatorConnect / DirectRouting),
    EnterpriseVoiceEnabled, OnlineVoiceRoutingPolicy, TenantDialPlan,
    TeamsCallingPolicy, LocationId, UsageLocation and AccountEnabled.

    The number inventory is pulled once (paged) and joined to the user list
    locally, so users are not queried one number at a time. The script is
    read-only against the tenant.

.PARAMETER OutputPath
    Directory where the CSV is written. If omitted, defaults to
    "<LocalAppData>\Migration-Automations", prints that path, and asks you to
    confirm it or supply a different directory.

.PARAMETER Prefix
    Text prepended to the output file name (e.g. 'Contoso' ->
    'Contoso_TeamsPhoneAssignments_...'). If omitted, you are asked whether you
    want a custom prefix; if not, whether this is the Source or Destination
    tenant and that label is used instead.

.PARAMETER TenantId
    Tenant ID (GUID) to sign in to. Useful for MSP / multi-tenant admins so the
    interactive sign-in lands in the intended tenant.

.PARAMETER IncludeUsersWithoutNumbers
    Also include enterprise-voice-capable users that have NO phone number
    assigned. By default only users with an assigned number are exported.

.PARAMETER IncludeUnassignedNumbers
    Also write a second CSV listing every telephone number in the tenant
    inventory that is NOT assigned to anyone (number, type, location, country).
    Handy for planning which numbers are free in the destination tenant.

.PARAMETER DryRun
    Preview only - resolve the prefix and output location and print the planned
    output files, then exit without connecting to Microsoft 365 or writing
    anything.

.EXAMPLE
    .\Get-MigrationTeamsPhoneAssignments.ps1

    Interactive sign-in, prompts for prefix + output location, writes the
    assignments CSV.

.EXAMPLE
    .\Get-MigrationTeamsPhoneAssignments.ps1 -OutputPath 'C:\Migrations\Contoso' -Prefix Source -IncludeUnassignedNumbers

.EXAMPLE
    .\Get-MigrationTeamsPhoneAssignments.ps1 -Prefix Destination -IncludeUsersWithoutNumbers

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, MicrosoftTeams module
    Permissions : Teams Administrator (or Teams Communications Administrator /
                  Global Reader for a read-only pull).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string]$Prefix,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeUsersWithoutNumbers,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeUnassignedNumbers,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

#region Shared helpers ---------------------------------------------------------

function Resolve-MigrationOutputDirectory {
    <#
        Returns a usable output directory. If -Path is supplied it is used as-is.
        Otherwise the user is shown the default (<LocalAppData>\Migration-Automations)
        and asked to accept it or provide another. The directory is created if it
        does not exist.
    #>
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

function Initialize-RequiredModule {
    <# Ensures a module is available, installing it for the current user if not. #>
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
        Determines the file-name prefix. If -Value is supplied it is sanitised and
        used. Otherwise the user is asked whether to use a custom prefix; if not,
        whether this is the Source or Destination tenant - that label becomes the
        prefix so file names are self-describing.
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
    <#
        Pages through the tenant telephone number inventory. Optionally filtered
        (e.g. @{ PstnAssignmentStatus = 'Unassigned' }).
    #>
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

#endregion ---------------------------------------------------------------------

Write-Host '=== M365 Migration - Teams Phone Assignment Export ===' -ForegroundColor Cyan

$filePrefix = Resolve-FilePrefix -Value $Prefix
$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$assignmentsCsv = Join-Path -Path $outputDir -ChildPath "${filePrefix}_TeamsPhoneAssignments_$timestamp.csv"
$unassignedCsv = Join-Path -Path $outputDir -ChildPath "${filePrefix}_TeamsPhoneNumbers-Unassigned_$timestamp.csv"

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN - nothing will be queried or written.' -ForegroundColor Magenta
    Write-Host 'Planned output files:' -ForegroundColor Cyan
    Write-Host "  $assignmentsCsv"
    if ($IncludeUnassignedNumbers) { Write-Host "  $unassignedCsv" }
    Write-Host 'Re-run without -DryRun to export.' -ForegroundColor Cyan
    return
}

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

#region Pull number inventory and users ----------------------------------------

Write-Host 'Retrieving telephone number inventory...' -ForegroundColor Cyan
$allNumbers = Get-AllPhoneNumberAssignments
Write-Host "  Numbers in inventory: $($allNumbers.Count)" -ForegroundColor Cyan

# Index the inventory by the assigned user's object ID so each user's number
# type / location resolves without a per-user lookup. Direct Routing numbers
# that were never uploaded to the inventory simply won't be in this map - the
# user's LineUri still captures the number itself.
$numbersByTarget = @{}
foreach ($num in $allNumbers) {
    if (-not [string]::IsNullOrWhiteSpace($num.AssignedPstnTargetId)) {
        $numbersByTarget[[string]$num.AssignedPstnTargetId] = $num
    }
}

Write-Host 'Retrieving Teams users (this can take a while on large tenants)...' -ForegroundColor Cyan
$users = $null
if (-not $IncludeUsersWithoutNumbers) {
    # Server-side filter keeps the pull small; fall back to a full pull if the
    # connected module version rejects the filter syntax.
    try {
        $users = @(Get-CsOnlineUser -Filter 'LineUri -ne $null')
    }
    catch {
        Write-Host '  Server-side LineUri filter not supported by this module version - pulling all users and filtering locally.' -ForegroundColor Yellow
        $users = $null
    }
}
if ($null -eq $users) {
    $users = @(Get-CsOnlineUser)
    if (-not $IncludeUsersWithoutNumbers) {
        $users = @($users | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) })
    }
}
Write-Host "  Users to export: $($users.Count)" -ForegroundColor Cyan

#endregion ---------------------------------------------------------------------

#region Build and write the export ---------------------------------------------

$rows = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($user in $users) {
    $index++
    Write-Progress -Activity 'Exporting Teams phone assignments' `
        -Status "$index of $($users.Count): $($user.UserPrincipalName)" `
        -PercentComplete (($index / [math]::Max($users.Count, 1)) * 100)

    $line = Split-TeamsLineUri -LineUri $user.LineUri
    $userId = [string]$user.Identity
    $numberInfo = if ($userId -and $numbersByTarget.ContainsKey($userId)) { $numbersByTarget[$userId] } else { $null }

    $rows.Add([pscustomobject][ordered]@{
            UserPrincipalName        = $user.UserPrincipalName
            DisplayName              = $user.DisplayName
            PhoneNumber              = if ($line.Number) { $line.Number } elseif ($numberInfo) { $numberInfo.TelephoneNumber } else { $null }
            Extension                = $line.Extension
            PhoneNumberType          = if ($numberInfo) { [string]$numberInfo.NumberType } elseif ($line.Number) { 'DirectRouting' } else { $null }
            EnterpriseVoiceEnabled   = $user.EnterpriseVoiceEnabled
            OnlineVoiceRoutingPolicy = Get-PolicyNameValue -Policy $user.OnlineVoiceRoutingPolicy
            TenantDialPlan           = Get-PolicyNameValue -Policy $user.TenantDialPlan
            TeamsCallingPolicy       = Get-PolicyNameValue -Policy $user.TeamsCallingPolicy
            LocationId               = if ($numberInfo) { [string]$numberInfo.LocationId } else { $null }
            UsageLocation            = $user.UsageLocation
            AccountEnabled           = $user.AccountEnabled
            LineUri                  = $user.LineUri
        })
}

Write-Progress -Activity 'Exporting Teams phone assignments' -Completed

if ($rows.Count -eq 0) {
    Write-Host 'No users matched - nothing to export.' -ForegroundColor Yellow
}
else {
    $rows | Export-Csv -Path $assignmentsCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Assignments CSV ($($rows.Count) row(s)): $assignmentsCsv" -ForegroundColor Green
}

if ($IncludeUnassignedNumbers) {
    $unassigned = @($allNumbers | Where-Object { [string]$_.PstnAssignmentStatus -eq 'Unassigned' })
    Write-Host "Unassigned numbers in inventory: $($unassigned.Count)" -ForegroundColor Cyan
    if ($unassigned.Count -gt 0) {
        $unassigned | ForEach-Object {
            [pscustomobject][ordered]@{
                PhoneNumber        = $_.TelephoneNumber
                PhoneNumberType    = [string]$_.NumberType
                AssignmentCategory = [string]$_.AssignmentCategory
                Capability         = ($_.Capability -join ';')
                IsoCountryCode     = $_.IsoCountryCode
                LocationId         = [string]$_.LocationId
                ActivationState    = [string]$_.ActivationState
            }
        } | Export-Csv -Path $unassignedCsv -NoTypeInformation -Encoding UTF8
        Write-Host "Unassigned numbers CSV: $unassignedCsv" -ForegroundColor Green
    }
}

#endregion ---------------------------------------------------------------------

Disconnect-MicrosoftTeams -Confirm:$false | Out-Null
Write-Host 'Done.' -ForegroundColor Green
