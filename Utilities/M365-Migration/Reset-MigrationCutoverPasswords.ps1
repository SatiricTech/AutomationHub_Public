#Requires -Version 7.4

<#
.SYNOPSIS
    Resets the sign-in credentials of a set of Microsoft 365 (Entra ID) users to a freshly
    generated passphrase, forces a change at next sign-in, and records every credential in
    the run's results CSV.

.DESCRIPTION
    At cutover you often need to reset every migrating user to a known credential so it can
    be handed out, then force the user to set their own on first sign-in.

    The target users are supplied one of four ways (choose exactly one): -PlanPath (an
    IdentityPlan.csv, filtered by -Wave, acting only on PlanStatus Planned /
    ManualOverride / UpnSmtpDiverge, plus Collision with -IncludeCollisions - every other
    User row in the wave is recorded as Skipped with its PlanStatus in Detail - and reset by
    TargetUserPrincipalName falling back to InterimUserPrincipalName), -CsvPath (a CSV of
    users), -Group (an Entra security group, all user members) or -TestUser (one account,
    to rehearse the flow).

    Each user is assigned a UNIQUE passphrase: hyphenated dictionary words plus a two-digit
    number and a symbol, reading like "silver-copper-Lantern74!". All four character classes
    are present, so it clears the default Entra complexity rules while staying dictatable
    over the phone. Every reset account is set to "change password at next sign-in".

    Generated credentials are written ONLY to the results CSV - never to the run log, and
    never to the console. Store that file securely and delete it once the credentials have
    been handed out.

    DryRun signs in with the same scopes as the real run but performs no writes: it
    resolves exactly which users would be affected, writes a -DryRun_ results file whose
    rows are Status 'Planned', and generates no passphrases at all - a credential is never
    emitted for a reset that did not happen.

.PARAMETER PlanPath
    Path to the IdentityPlan.csv produced by the planning phase.

.PARAMETER Wave
    One or more wave labels to restrict the plan to. Omit to take every non-excluded row.

.PARAMETER IncludeCollisions
    Also act on plan rows whose PlanStatus is Collision. Off by default: a collision means
    the planned address is contested and the row usually needs an operator decision first.

.PARAMETER CsvPath
    Path to a CSV describing the users to reset. The user column is resolved through the
    toolkit's alias vocabulary: a UPN column (UserPrincipalName, UPN, User Principal Name,
    UserName, User, CurrentUPN, Login) or an email column (PrimarySmtpAddress, Email, Mail,
    PrimaryEmail, EmailAddress, PrimarySMTP, WindowsEmailAddress), which is resolved by the
    user's mail attribute. When both are present the UPN column wins.

.PARAMETER Group
    An Entra security group by object ID (GUID) or display name. All user members are reset.
    Provide the group's object ID or name - not its email address.

.PARAMETER TestUser
    A single user (UPN, email or object ID) to reset. Use to rehearse against one account.

.PARAMETER OutputPath
    Root directory for the log and results CSV. Defaults to the toolkit's standard root:
    %LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations elsewhere.

.PARAMETER Prefix
    Names the client or run. When supplied, output lands in <root>\<Prefix>\ and file names
    start with <Prefix>_.

.PARAMETER LogPath
    Overrides the auto-derived log file path.

.PARAMETER TenantId
    Tenant ID (GUID) to sign in to. Useful for MSP / multi-tenant admins, and for partner
    access under an active GDAP relationship.

.PARAMETER WordCount
    Number of words in each generated passphrase. Minimum (and default) 3.

.PARAMETER ForceChangePassword
    Require the user to change their password at next sign-in. Default $true and intended to
    stay true for a cutover.

.PARAMETER DryRun
    Preview only. Signs in with the same scopes as the real run but performs no writes:
    resolves the target users, reports who would be reset, writes a -DryRun_ results file
    with Status 'Planned', and changes nothing.

.PARAMETER Verbosity
    Console noise level: Low (errors and successes), Medium (adds warnings), High
    (everything). The log file always receives every line regardless of this setting.

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -Prefix Contoso -DryRun

    Reports which wave 1 accounts would be reset, writing a -DryRun_ results file.

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -Prefix Contoso

    Performs the wave 1 resets and writes the credential file alongside the run log.

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -CsvPath .\CutoverUsers.csv -WordCount 4

    Resets every user named in a CSV to a four-word passphrase.

.EXAMPLE
    .\Reset-MigrationCutoverPasswords.ps1 -TestUser john.smith@contoso.com -Verbosity High

    Rehearses the whole flow against one account with full console tracing.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4, the M365Migration module shipped beside this script, and
                  Microsoft.Graph.Authentication (installed on demand by Connect-MigrationGraph).
                  All Graph reads and writes go through raw REST calls via
                  Invoke-MigrationGraphRequest - no Microsoft.Graph.Users or
                  Microsoft.Graph.Groups submodule is required.
    Graph scopes: User.ReadWrite.All, User-PasswordProfile.ReadWrite.All, Group.Read.All.
                  The password profile write is gated behind
                  User-PasswordProfile.ReadWrite.All specifically - User.ReadWrite.All alone
                  returns 403 whatever the admin's role.
    Roles       : the signed-in account needs a role that can reset the target users (e.g.
                  User Administrator); resetting another ADMINISTRATOR requires Privileged
                  Authentication Administrator. GDAP works through -TenantId.
    Exit codes  : 0 success, 1 fatal error, 2 completed with one or more failed rows.

    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Csv')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Plan')]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [Parameter(ParameterSetName = 'Plan')]
    [AllowNull()]
    [string[]]$Wave,

    [Parameter(ParameterSetName = 'Plan')]
    [switch]$IncludeCollisions,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory, ParameterSetName = 'Group')]
    [ValidateNotNullOrEmpty()]
    [string]$Group,

    [Parameter(Mandatory, ParameterSetName = 'TestUser')]
    [ValidateNotNullOrEmpty()]
    [string]$TestUser,

    [string]$OutputPath,

    [string]$Prefix,

    [string]$LogPath,

    [string]$TenantId,

    [ValidateRange(3, 8)]
    [int]$WordCount = 3,

    [bool]$ForceChangePassword = $true,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Configuration ----------------------------------------------------------

# Resetting a password writes user.passwordProfile, gated behind the dedicated
# User-PasswordProfile.ReadWrite.All permission - User.ReadWrite.All alone returns 403.
# Connect-MigrationGraph verifies every scope was granted, so a declined consent fails once
# here rather than 403-ing on every single user.
$requiredGraphScopes = @(
    'User.ReadWrite.All'
    'User-PasswordProfile.ReadWrite.All'
    'Group.Read.All'
)

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$graphUserSelect = 'id,userPrincipalName,displayName'

#endregion ---------------------------------------------------------------------

#region Functions --------------------------------------------------------------

function Resolve-CutoverPlanIdentity {
    <#
        Picks the account a plan row should be reset by, returning Identity, Source
        ('Target', 'Interim' or 'None') and Reason. A cutover reset happens in the
        destination tenant, so the target UPN is the right identity; early in a migration
        the vanity domain may not be verified yet and the user only exists under the
        interim .onmicrosoft.com name, so an empty TargetUserPrincipalName falls back to
        InterimUserPrincipalName. A row carrying neither is reported, never guessed at.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Row
    )

    $target = [string](Get-MigrationCsvValue -Row $Row -Name 'TargetUserPrincipalName' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($target)) {
        return [pscustomobject]@{ Identity = $target.Trim(); Source = 'Target'; Reason = '' }
    }

    $interim = [string](Get-MigrationCsvValue -Row $Row -Name 'InterimUserPrincipalName' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($interim)) {
        return [pscustomobject]@{
            Identity = $interim.Trim()
            Source   = 'Interim'
            Reason   = 'TargetUserPrincipalName is empty; used InterimUserPrincipalName instead.'
        }
    }

    [pscustomobject]@{
        Identity = $null
        Source   = 'None'
        Reason   = 'Plan row has neither TargetUserPrincipalName nor InterimUserPrincipalName.'
    }
}

function Resolve-CutoverUser {
    <#
        Resolves a UPN, email or object ID to a Graph user. Returns User (the Graph user, or
        $null when the identity is unknown) and Error (empty, or the failure text when the
        lookup itself broke - 403, 429 after retries, 5xx, an expired token). The two are kept
        apart so a per-row loop records a miss as Skipped and a broken lookup as Failed, rather
        than passing a throttled wave off as a hundred users that do not exist.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity
    )

    $raw = $null
    try {
        if ($Identity -match $guidPattern) {
            $raw = Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/users/$Identity`?`$select=$graphUserSelect"
        }
        else {
            $safe = ConvertTo-MigrationODataString -Value $Identity
            $raw = @(Invoke-MigrationGraphRequest -Method GET `
                    -Uri "/v1.0/users?`$filter=userPrincipalName eq '$safe'&`$select=$graphUserSelect") |
                Select-Object -First 1
            if ($null -eq $raw) {
                $raw = @(Invoke-MigrationGraphRequest -Method GET `
                        -Uri "/v1.0/users?`$filter=mail eq '$safe'&`$select=$graphUserSelect") |
                    Select-Object -First 1
            }
        }
    }
    catch {
        # Only the by-id GET can 404 (a $filter miss returns an empty set); Get-MigrationGraphErrorStatusCode
        # maps Graph's error body (or the SDK's 'Request_ResourceNotFound' message shape) to 404.
        $code = Get-MigrationGraphErrorStatusCode -ErrorRecord $_
        if ($code -ne 404) {
            return [pscustomobject]@{
                User  = $null
                Error = "Could not resolve user '$Identity': $($_.Exception.Message)"
            }
        }
        Write-MigrationLog -Message "User '$Identity' does not exist in this tenant." -Level DEBUG
    }

    $user = $null
    if ($null -ne $raw) {
        $user = [pscustomobject]@{
            Id                = [string](Get-MigrationProperty -InputObject $raw -Name 'id' -Default '')
            UserPrincipalName = [string](Get-MigrationProperty -InputObject $raw -Name 'userPrincipalName' -Default '')
            DisplayName       = [string](Get-MigrationProperty -InputObject $raw -Name 'displayName' -Default '')
        }
    }

    [pscustomobject]@{ User = $user; Error = '' }
}

function Resolve-CutoverGroup {
    <#
        Resolves a group object ID (GUID) or exact display name to a Graph group. Throws with
        actionable text when the name misses or is ambiguous - an unresolved group would otherwise
        reset nobody with no explanation. Not the group's email address.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity
    )

    if ($Identity -match $guidPattern) {
        $raw = Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/groups/$Identity`?`$select=id,displayName"
        return [pscustomobject]@{
            Id          = [string](Get-MigrationProperty -InputObject $raw -Name 'id' -Default '')
            DisplayName = [string](Get-MigrationProperty -InputObject $raw -Name 'displayName' -Default '')
        }
    }

    $safe = ConvertTo-MigrationODataString -Value $Identity
    $hits = @(Invoke-MigrationGraphRequest -Method GET -All `
            -Uri "/v1.0/groups?`$filter=displayName eq '$safe'&`$select=id,displayName")
    if ($hits.Count -eq 0) {
        throw ("No group found with display name '$Identity'. Provide the group's object ID or its exact " +
            'display name - not its email address.')
    }
    if ($hits.Count -gt 1) {
        throw "Multiple groups match display name '$Identity'. Re-run with the group's object ID to disambiguate."
    }
    [pscustomobject]@{
        Id          = [string](Get-MigrationProperty -InputObject $hits[0] -Name 'id' -Default '')
        DisplayName = [string](Get-MigrationProperty -InputObject $hits[0] -Name 'displayName' -Default '')
    }
}

#endregion ---------------------------------------------------------------------

#region Main -------------------------------------------------------------------

$exitCode = 0
$run = Initialize-MigrationRun -ScriptName 'Reset-MigrationCutoverPasswords' -OutputPath $OutputPath `
    -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    $isDryRun = [bool]$run.DryRun

    # Fail on bad input paths before a sign-in prompt is put in front of the operator.
    switch ($PSCmdlet.ParameterSetName) {
        'Csv' { if (-not (Test-Path -LiteralPath $CsvPath)) { throw "CSV not found: $CsvPath" } }
        'Plan' { if (-not (Test-Path -LiteralPath $PlanPath)) { throw "Identity plan not found: $PlanPath" } }
    }

    # Connect-MigrationGraph installs and imports Microsoft.Graph.Authentication itself; every
    # Graph call this script makes is raw REST through Invoke-MigrationGraphRequest, so no
    # Microsoft.Graph.Users / .Groups submodule - and the version-matching failure they can
    # trigger against an already-loaded Microsoft.Graph.Authentication - ever enters the picture.
    $context = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId
    # Connect-MigrationGraph logs a reused cached session at INFO, which the default verbosity
    # hides; a credential reset must show the tenant it is about to act on at every verbosity.
    Write-MigrationLog -Message "Target tenant: $($context.TenantId) as $($context.Account)" -Level SUCCESS

    # Each entry pairs the Graph user (or $null when unresolved) with the identity the
    # operator supplied, so an unresolved row still reports something recognisable. Error
    # carries a lookup that failed outright (throttling, 403, expired token) so the row is
    # recorded as Failed rather than passed off as a user that does not exist.
    $targets = [System.Collections.Generic.List[object]]::new()
    $addTarget = {
        param([string]$Supplied, $User, [string]$Note, [string]$LookupError = '')
        $targets.Add([pscustomobject]@{ Supplied = $Supplied; User = $User; Note = $Note; Error = $LookupError })
    }
    $addResolvedTarget = {
        param([string]$Supplied, [string]$Note)
        $lookup = Resolve-CutoverUser -Identity $Supplied
        & $addTarget $Supplied $lookup.User $Note $lookup.Error
    }

    switch ($PSCmdlet.ParameterSetName) {
        'Plan' {
            $planRows = @(Import-MigrationPlan -Path $PlanPath -Wave $Wave -ObjectType 'User')
            Write-MigrationLog -Message "Plan rows to process: $($planRows.Count)" -Level INFO

            foreach ($row in $planRows) {
                $choice = Resolve-CutoverPlanIdentity -Row $row
                $sourceUpn = [string](Get-MigrationCsvValue -Row $row -Name 'SourceUserPrincipalName' -Default '(unknown source row)')
                $shown = if ([string]::IsNullOrWhiteSpace($choice.Identity)) { $sourceUpn } else { $choice.Identity }

                # -AllowSynced: the plan's IsSynced column describes the SOURCE object, while
                # this reset targets the freshly created cloud user in the destination tenant,
                # which carries no sync state. Every other gate reason becomes a Skipped row
                # so the wave's results reconcile against the plan row for row.
                $gate = Test-MigrationPlanRowActionable -Row $row -IncludeCollisions:$IncludeCollisions -AllowSynced
                if (-not $gate.Actionable) {
                    $reason = $gate.Reason
                    if ((Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default '') -eq 'Collision') {
                        $reason += ' Re-run with -IncludeCollisions to process it.'
                    }
                    & $addTarget $shown $null $reason
                    continue
                }

                if ([string]::IsNullOrWhiteSpace($choice.Identity)) {
                    & $addTarget $sourceUpn $null $choice.Reason
                    continue
                }
                if ($choice.Source -eq 'Interim') {
                    Write-MigrationLog -Message "$($choice.Identity): $($choice.Reason)" -Level WARNING
                }
                & $addResolvedTarget $choice.Identity $choice.Reason
            }
        }

        'Csv' {
            $rows = @(Import-MigrationCsv -Path $CsvPath)

            # Import-MigrationCsv maps a bare Email/Mail column to PrimarySmtpAddress rather
            # than UserPrincipalName, and Resolve-CutoverUser looks a user up by either, so
            # fall back to it before rejecting the file.
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
                & $addResolvedTarget $identity ''
            }
        }

        'Group' {
            $resolvedGroup = Resolve-CutoverGroup -Identity $Group
            Write-MigrationLog -Message "Group: $($resolvedGroup.DisplayName) [$($resolvedGroup.Id)]" -Level INFO

            # Group members arrive as directory objects; only #microsoft.graph.user entries
            # can hold a password profile, so nested groups and service principals are dropped.
            $members = @(Invoke-MigrationGraphRequest -Method GET -All `
                    -Uri "/v1.0/groups/$($resolvedGroup.Id)/members?`$select=id,userPrincipalName,displayName")
            foreach ($member in $members) {
                if ([string](Get-MigrationProperty -InputObject $member -Name '@odata.type' -Default '') -ne '#microsoft.graph.user') { continue }
                $memberUpn = [string](Get-MigrationProperty -InputObject $member -Name 'userPrincipalName' -Default '')
                & $addTarget $memberUpn ([pscustomobject]@{
                        Id                = [string](Get-MigrationProperty -InputObject $member -Name 'id' -Default '')
                        UserPrincipalName = $memberUpn
                        DisplayName       = [string](Get-MigrationProperty -InputObject $member -Name 'displayName' -Default '')
                    }) ''
            }
            if ($targets.Count -eq 0) {
                Write-MigrationLog -Message 'Group has no user members to reset.' -Level WARNING
            }
        }

        'TestUser' {
            Write-MigrationLog -Message "Resolving single test user '$TestUser'..." -Level INFO
            & $addResolvedTarget $TestUser ''
        }
    }

    Write-MigrationLog -Message "Users to process: $($targets.Count)" -Level INFO

    $results = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($target in $targets) {
        $index++
        $identity = $target.Supplied
        $user = $target.User
        $displayName = ''

        Write-Progress -Activity 'Resetting cutover passwords' `
            -Status "$index of $($targets.Count): $identity" `
            -PercentComplete (($index / [math]::Max($targets.Count, 1)) * 100)

        $status = 'Failed'
        $detail = ''
        $generated = ''
        $passwordProfile = $null

        try {
            # A lookup that broke (throttling, 403, expired token) is a Failed row with the
            # Graph message, never a Skipped 'not found' - the wave must not look clean.
            if ($target.Error) { throw $target.Error }

            if ($null -eq $user) {
                $status = 'Skipped'
                $detail = if ($target.Note) { $target.Note } else { 'User not found in this tenant.' }
            }
            else {
                $identity = if ($user.UserPrincipalName) { [string]$user.UserPrincipalName } else { $identity }
                $displayName = [string]$user.DisplayName
                if (-not $user.Id) { throw 'User has no directory object ID.' }

                if ($isDryRun) {
                    # No passphrase is generated in DryRun: a credential must never appear
                    # for a reset that did not happen.
                    $null = Invoke-MigrationAction -Description "Reset the password for $identity" -Action { }
                    $status = 'Planned'
                    $detail = 'Would reset the password and require a change at next sign-in.'
                }
                elseif ($PSCmdlet.ShouldProcess($identity, 'Reset password to a new passphrase')) {
                    $generated = New-MigrationPassphrase -WordCount $WordCount
                    $passwordProfile = @{
                        password                      = $generated
                        forceChangePasswordNextSignIn = $ForceChangePassword
                    }
                    # Invoke-MigrationGraphRequest throws on a failed call (after its own retry
                    # budget) so a failed reset lands in catch and is recorded as Failed - never
                    # reported as a success with a credential that was never actually set.
                    $null = Invoke-MigrationAction -Description "Reset the password for $identity" -Action {
                        $null = Invoke-MigrationGraphRequest -Method PATCH -Uri "/v1.0/users/$($user.Id)" `
                            -Body @{ passwordProfile = $passwordProfile }
                    }
                    $status = 'Succeeded'
                    $detail = 'Password reset; change required at next sign-in.'
                }
                else {
                    # Not a rehearsal: -WhatIf or a declined prompt means the reset was never
                    # attempted, so the row is a skip. 'Planned' is reserved for -DryRun.
                    $status = 'Skipped'
                    $detail = 'Declined at the confirmation prompt.'
                }
            }
        }
        catch {
            $status = 'Failed'
            $generated = ''   # the reset did not take - do not surface a credential
            $message = $_.Exception.Message
            if ($message -match 'Authorization_RequestDenied|Insufficient privileges') {
                $detail = 'Access denied - the signed-in account lacks rights to reset this user ' +
                    '(needs User-PasswordProfile.ReadWrite.All and a suitable admin role; resetting an ' +
                    "administrator requires Privileged Authentication Administrator). Original error: $message"
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

        $results.Add([pscustomobject][ordered]@{
                Identity                      = $identity
                Action                        = 'Reset password'
                Status                        = $status
                Detail                        = $detail
                GeneratedPassword             = $generated
                DisplayName                   = $displayName
                ForceChangePasswordNextSignIn = $ForceChangePassword
            })
    }

    Write-Progress -Activity 'Resetting cutover passwords' -Completed

    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Reset-CutoverPasswords'
    if (-not $isDryRun -and @($results | Where-Object { $_.Status -eq 'Succeeded' }).Count -gt 0) {
        Write-MigrationLog -Message 'Generated passwords were written to the results file, not to this log. Store it securely and delete it once the credentials have been distributed.' -Level WARNING
    }
}
catch {
    Write-MigrationLog -Message "Fatal: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message $_.ScriptStackTrace -Level DEBUG
    $exitCode = 1
}
finally {
    #region Cleanup ------------------------------------------------------------
    # The Graph session is deliberately left connected: Connect-MigrationGraph reuses a live
    # context, so disconnecting here would force a fresh sign-in for the next script in the run.
    $null = Complete-MigrationRun -ExitCode $exitCode
    #endregion -----------------------------------------------------------------
}

exit $exitCode

#endregion ---------------------------------------------------------------------
