#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Migration cutover password reset. Resets the sign-in credentials of a set of
    Microsoft 365 (Entra ID) users to a freshly generated passphrase, forces a
    change at next sign-in, and logs every changed credential to a CSV.

.DESCRIPTION
    At cutover you often need to reset every migrating user to a known credential
    so it can be handed out, then force the user to set their own on first
    sign-in. This script does exactly that for a batch of users described either
    by a CSV or by an Entra security group.

    The target users are supplied one of three ways (choose exactly one):
      -CsvPath   A CSV of users. The UserPrincipalName / UPN / Email column is
                 auto-detected. One reset per row.
      -Group     An Entra security group, given by its object ID (GUID) or its
                 display name (NOT the group's email address). Every user member
                 (transitively expanded members that are users) is reset.
      -TestUser  A single user (UPN, email or object ID) so you can rehearse the
                 whole flow against one account before running the batch.

    Each user is assigned a UNIQUE passphrase (not a password) that meets the
    requested policy:
      - at least 3 words (configurable with -WordCount)
      - at least one word capitalised
      - at least one number
      - at least one special character
    The result reads like "Silver-Copper-lantern74!". All four character classes
    (upper, lower, digit, symbol) are present, so it also satisfies the default
    Entra password-complexity rules.

    Every reset account is set to "change password at next sign-in".

    Every changed credential is written to a results CSV (username + passphrase)
    in the current directory by default, so you can distribute the temporary
    credentials. Store that file securely and delete it once handed out.

    Supports -WhatIf / -Confirm and a dedicated -DryRun that resolves and reports
    exactly which users would be affected without changing anything or emitting a
    passphrase.

.PARAMETER CsvPath
    Path to a CSV describing the users to reset. Recognised UPN column headers
    (case-insensitive): UserPrincipalName, UPN, User Principal Name, Email,
    PrimaryEmail, Mail, UserName.

.PARAMETER Group
    An Entra security group by object ID (GUID) or display name. All user members
    are reset. Provide the group's object ID or name - not its email address.

.PARAMETER TestUser
    A single user (UPN, email or object ID) to reset. Use to rehearse against one
    account.

.PARAMETER OutputPath
    Directory where the results CSV (username + passphrase) is written. Defaults
    to the current directory.

.PARAMETER WordCount
    Number of words in each generated passphrase. Minimum (and default) 3.

.PARAMETER ForceChangePassword
    Require the user to change their password at next sign-in. Default $true and
    intended to stay true for a cutover.

.PARAMETER DryRun
    Preview only - make no changes. Resolves the target users and reports who
    would be reset, but changes nothing and generates no passphrases.

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -CsvPath .\CutoverUsers.csv -DryRun

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -Group "Migration Wave 1"

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -Group 6f2b1d3e-1a2b-4c5d-8e9f-0a1b2c3d4e5f

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -TestUser john.smith@contoso.com

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -TestUser john.smith@contoso.com -DryRun

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, Microsoft.Graph
    Permissions : User.ReadWrite.All, Directory.ReadWrite.All, Group.Read.All
                  (the signed-in admin must be allowed to reset the target
                  users' passwords).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Csv')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Csv')]
    [string]$CsvPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Group')]
    [string]$Group,

    [Parameter(Mandatory = $true, ParameterSetName = 'TestUser')]
    [string]$TestUser,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidateRange(3, 12)]
    [int]$WordCount = 3,

    [Parameter(Mandatory = $false)]
    [bool]$ForceChangePassword = $true,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# -DryRun makes no changes - read-only checks still run, mutating calls are skipped.
if ($DryRun) {
    Write-Host 'DRY RUN enabled - read-only checks run, but no changes will be made.' -ForegroundColor Magenta
}

$GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

#region Shared helpers ---------------------------------------------------------

function Resolve-MigrationOutputDirectory {
    <# Defaults to the current directory for the cutover credential log. #>
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

function New-MigrationPassphrase {
    <#
        Generates a passphrase meeting the cutover policy:
          - at least 3 words (WordCount)
          - at least one word capitalised
          - at least one number
          - at least one special character
        Example: "Silver-Copper-lantern74!"
    #>
    param([int]$WordCount = 3)
    if ($WordCount -lt 3) { $WordCount = 3 }

    # Short, unambiguous words (no easily confused look-alikes).
    $words = @(
        'apple', 'anchor', 'amber', 'basil', 'birch', 'brave', 'bronze', 'cactus',
        'candle', 'cedar', 'cobalt', 'copper', 'coral', 'cotton', 'cricket', 'crimson',
        'delta', 'ember', 'falcon', 'fern', 'flint', 'forest', 'garnet', 'ginger',
        'granite', 'harbor', 'hazel', 'indigo', 'ivory', 'jasper', 'juniper', 'kettle',
        'lantern', 'laurel', 'lemon', 'lily', 'lotus', 'maple', 'marble', 'meadow',
        'mint', 'mocha', 'nectar', 'nimbus', 'oak', 'olive', 'onyx', 'orchid',
        'pepper', 'pewter', 'pine', 'plum', 'quartz', 'raven', 'river', 'rustic',
        'saffron', 'sage', 'silver', 'slate', 'spruce', 'stone', 'sunset', 'thistle',
        'timber', 'topaz', 'tulip', 'velvet', 'willow', 'winter', 'zephyr'
    )

    # -Count returns distinct items, so no repeated words in a phrase.
    $picked = @(Get-Random -InputObject $words -Count $WordCount)

    # Capitalise one randomly chosen word.
    $capIndex = Get-Random -Maximum $picked.Count
    $w = $picked[$capIndex]
    $picked[$capIndex] = $w.Substring(0, 1).ToUpper() + $w.Substring(1)

    $number = Get-Random -Minimum 10 -Maximum 100          # two-digit number
    $symbols = '!@#$%^*-_=+?'
    $symbol = $symbols[(Get-Random -Maximum $symbols.Length)]

    return ('{0}{1}{2}' -f ($picked -join '-'), $number, $symbol)
}

function Resolve-MgUserByIdentity {
    <# Resolves a UPN, email or object ID to a Graph user object (or $null). #>
    param([Parameter(Mandatory)][string]$Identity)

    $props = 'Id', 'UserPrincipalName', 'DisplayName'

    if ($Identity -match $GuidPattern) {
        return Get-MgUser -UserId $Identity -Property $props -ErrorAction SilentlyContinue
    }

    # Escape single quotes for the OData filter.
    $safe = $Identity.Replace("'", "''")
    $user = Get-MgUser -Filter "userPrincipalName eq '$safe'" -Property $props -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $user) {
        $user = Get-MgUser -Filter "mail eq '$safe'" -Property $props -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    return $user
}

function Resolve-MgGroupByIdentity {
    <# Resolves a group object ID (GUID) or display name to a Graph group. #>
    param([Parameter(Mandatory)][string]$Identity)

    if ($Identity -match $GuidPattern) {
        return Get-MgGroup -GroupId $Identity -Property 'Id', 'DisplayName' -ErrorAction Stop
    }

    $safe = $Identity.Replace("'", "''")
    $hits = @(Get-MgGroup -Filter "displayName eq '$safe'" -Property 'Id', 'DisplayName' -All)
    if ($hits.Count -eq 0) {
        throw "No group found with display name '$Identity'. Provide the group's object ID or exact display name (not its email address)."
    }
    if ($hits.Count -gt 1) {
        throw "Multiple groups match display name '$Identity'. Re-run with the group's object ID to disambiguate."
    }
    return $hits[0]
}

#endregion ---------------------------------------------------------------------

Write-Host '=== M365 Migration Cutover - Password Reset ===' -ForegroundColor Cyan

# Validate inputs that do not need Graph first.
if ($PSCmdlet.ParameterSetName -eq 'Csv' -and -not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultsCsv = Join-Path -Path $outputDir -ChildPath "Cutover-PasswordResets_$timestamp.csv"

Initialize-RequiredModule -Name 'Microsoft.Graph.Users'
Initialize-RequiredModule -Name 'Microsoft.Graph.Groups'

Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
Connect-MgGraph -Scopes 'User.ReadWrite.All', 'Directory.ReadWrite.All', 'Group.Read.All' -NoWelcome

#region Build the target list --------------------------------------------------

# Each target is a Graph user object with Id / UserPrincipalName / DisplayName.
$targets = [System.Collections.Generic.List[object]]::new()
$notFound = [System.Collections.Generic.List[string]]::new()

switch ($PSCmdlet.ParameterSetName) {
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
            $user = Resolve-MgUserByIdentity -Identity $id
            if ($user) { $targets.Add($user) } else { $notFound.Add($id) }
        }
    }

    'Group' {
        $grp = Resolve-MgGroupByIdentity -Identity $Group
        Write-Host "Group: $($grp.DisplayName) [$($grp.Id)]" -ForegroundColor Cyan
        Write-Host 'Expanding user members...' -ForegroundColor Cyan

        $members = @(Get-MgGroupMember -GroupId $grp.Id -All)
        foreach ($m in $members) {
            $type = $m.AdditionalProperties['@odata.type']
            if ($type -ne '#microsoft.graph.user') { continue }
            $targets.Add([pscustomobject]@{
                    Id                = $m.Id
                    UserPrincipalName = $m.AdditionalProperties['userPrincipalName']
                    DisplayName       = $m.AdditionalProperties['displayName']
                })
        }
        if ($targets.Count -eq 0) {
            Write-Host 'Group has no user members to reset.' -ForegroundColor Yellow
        }
    }

    'TestUser' {
        Write-Host "Resolving single test user '$TestUser'..." -ForegroundColor Cyan
        $user = Resolve-MgUserByIdentity -Identity $TestUser
        if ($user) { $targets.Add($user) } else { $notFound.Add($TestUser) }
    }
}

foreach ($miss in $notFound) {
    Write-Host "  [Not found] $miss" -ForegroundColor Red
}

if ($targets.Count -eq 0) {
    Write-Host 'No matching users to process. Nothing to do.' -ForegroundColor Yellow
    Disconnect-MgGraph | Out-Null
    return
}

Write-Host "Users to process: $($targets.Count)" -ForegroundColor Cyan

#endregion ---------------------------------------------------------------------

#region Reset loop -------------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($user in $targets) {
    $index++
    $upn = $user.UserPrincipalName
    $displayName = $user.DisplayName

    Write-Progress -Activity 'Resetting passwords' `
        -Status "$index of $($targets.Count): $upn" `
        -PercentComplete (($index / [math]::Max($targets.Count, 1)) * 100)

    $status = 'Reset'
    $detail = ''
    $passphrase = ''

    try {
        if (-not $user.Id) { throw 'User has no directory object ID.' }

        $passphrase = New-MigrationPassphrase -WordCount $WordCount
        $passwordProfile = @{
            Password                      = $passphrase
            ForceChangePasswordNextSignIn = $ForceChangePassword
        }

        if (-not $DryRun -and $PSCmdlet.ShouldProcess($upn, 'Reset password to a new passphrase')) {
            Update-MgUser -UserId $user.Id -PasswordProfile $passwordProfile
            $detail = 'Password reset; change required at next sign-in.'
        }
        else {
            $status = 'WhatIf'
            $detail = 'Would reset password.'
            $passphrase = ''   # do not surface a credential for a non-action
        }
    }
    catch {
        $status = 'Failed'
        $detail = $_.Exception.Message
        $passphrase = ''
    }

    $color = switch ($status) {
        'Reset'  { 'Green' }
        'WhatIf' { 'Cyan' }
        default  { 'Red' }
    }
    Write-Host ("  [{0}] {1} - {2}" -f $status, $upn, $detail) -ForegroundColor $color

    $results.Add([pscustomobject][ordered]@{
            UserName                      = $upn
            DisplayName                   = $displayName
            Passphrase                    = $passphrase
            ForceChangePasswordNextSignIn = $ForceChangePassword
            Status                        = $status
            Detail                        = $detail
        })
}

Write-Progress -Activity 'Resetting passwords' -Completed

#endregion ---------------------------------------------------------------------

# Only write a credential log when real changes were made.
$reset = ($results | Where-Object Status -eq 'Reset').Count
$failed = ($results | Where-Object Status -eq 'Failed').Count
$whatif = ($results | Where-Object Status -eq 'WhatIf').Count

Write-Host ''
if ($DryRun -or $whatif -gt 0) {
    Write-Host "DRY RUN / WhatIf: $whatif user(s) would be reset, $failed error(s). No changes made, no credential log written." -ForegroundColor Magenta
}
else {
    $results | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Reset: $reset   Failed: $failed" -ForegroundColor Green
    Write-Host "Credential log (username + passphrase): $resultsCsv" -ForegroundColor Cyan
    Write-Host 'Store this file securely and delete it once credentials are distributed.' -ForegroundColor Yellow
}

Disconnect-MgGraph | Out-Null
Write-Host 'Done.' -ForegroundColor Green
