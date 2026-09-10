#Requires -Version 7.4

<#
.SYNOPSIS
    Bulk-unassigns Microsoft Teams phone numbers - from a single user, from users listed in a
    CSV (by UPN), or from every user and resource account in the tenant - and records each
    removed number so it can be reassigned later.

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
      -All      Every user in the tenant that currently has a phone number assigned. Resource
                accounts (auto attendant and call queue service numbers) are included, matching
                the Get- export; the AccountType results column shows which rows they are.

    Before each removal the user's current number, number type and voice routing policy are
    captured, and every processed user lands in the run's results CSV. That file carries the
    same PhoneNumber / PhoneNumberType / LocationId / OnlineVoiceRoutingPolicy columns that
    Set-MigrationTeamsPhoneAssignments.ps1 reads, so it doubles as your rollback and
    reassignment input.

    Only the number assignment is removed. Voice routing policies, dial plans and calling
    policies are left in place.

    Numbers set on-premises are never attempted. A user whose OnPremLineURI is populated, or
    whose number the inventory reports with NumberSource 'OnPremises', is written as Failed
    with that reason: the assignment lives in on-prem AD, and releasing it online would only
    last until the next sync. Clear it in AD, let it sync, then re-run. The OnPremLineURI
    results column shows the on-prem value so these rows are visible in a DryRun file.

    An identity supplied through -User or -CsvPath that does not resolve in the tenant is
    also Failed (exit code 2), so a file with the wrong domain cannot read as a clean run.

    DryRun signs in normally, resolves exactly which users and numbers would be affected,
    writes a -DryRun_ results file whose rows are Status 'Planned', and changes nothing.

.PARAMETER User
    A single user (UPN or object ID) whose phone number should be unassigned.

.PARAMETER CsvPath
    Path to a CSV describing the users to unassign. The user column is resolved through the
    toolkit's alias vocabulary (UserPrincipalName, UPN, User Principal Name, UserName, User,
    CurrentUPN, Login). A bare Email / Mail / PrimarySmtpAddress column is accepted as a
    fallback, but Get-CsOnlineUser resolves only a UPN, SIP address, alias or object ID, so an
    email address that differs from the user's UPN or SIP address reports 'User not found'.

.PARAMETER All
    Unassign the phone number of EVERY user in the tenant that has one, resource accounts
    (auto attendant / call queue numbers) included. Requires -TenantId so a whole-tenant
    release is always pinned to a named tenant rather than whichever cached session is live.

.PARAMETER OutputPath
    Root directory for the log and results CSV. Defaults to the toolkit's standard root:
    %LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations elsewhere.

.PARAMETER Prefix
    Names the client or run. When supplied, output lands in <root>\<Prefix>\ and file names
    start with <Prefix>_.

.PARAMETER LogPath
    Overrides the auto-derived log file path.

.PARAMETER TenantId
    Tenant ID (GUID) or tenant domain (contoso.onmicrosoft.com) to sign in to. Useful for
    MSP / multi-tenant admins so the interactive sign-in lands in the intended tenant, and
    mandatory with -All. Connect-MigrationTeams compares the value with the tenant GUID when
    deciding whether a cached session can be reused, so a domain value currently forces a
    fresh sign-in on every script.

.PARAMETER DryRun
    Preview only. Signs in normally, reports which numbers would be removed, writes a
    -DryRun_ results file with Status 'Planned', and changes nothing. On-prem and unresolved
    rows still report Failed so the rehearsal shows what a live run cannot do.

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
    .\Remove-MigrationTeamsPhoneAssignments.ps1 -All -TenantId contoso.onmicrosoft.com -Prefix Contoso -Verbosity High

    Releases every assigned number in the named tenant, with full console tracing.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4, the M365Migration module shipped beside this script, and
                  the MicrosoftTeams module version 5.7.0 or later (installed on demand when
                  absent). Older module versions report a failed removal by returning a
                  result object instead of throwing and do not expose NumberSource; the
                  script tolerates both, but 5.7.0 is the supported floor.
    Permissions : Teams Administrator, or Teams Communications Administrator. No Graph scopes
                  are used.
    GDAP        : supported through -TenantId, which Connect-MigrationTeams passes to
                  Connect-MicrosoftTeams. This script never connects to Exchange.
    Hybrid      : users whose number is set on-premises (OnPremLineURI synced from AD, or
                  NumberSource 'OnPremises' in the number inventory) are detected before any
                  call is made and reported as Failed with that explanation in Detail. Change
                  them in on-prem AD instead.
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

    # Optional for a single user or a CSV; mandatory for -All, where a cached session left
    # over from a destination-side script would otherwise be accepted silently.
    [Parameter(ParameterSetName = 'User')]
    [Parameter(ParameterSetName = 'Csv')]
    [Parameter(Mandatory, ParameterSetName = 'All')]
    [string]$TenantId,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

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

    $tenant = Connect-MigrationTeams -TenantId $TenantId

    # Name the tenant at WARNING so it shows at the default verbosity even when a cached
    # session was reused (Connect-MigrationTeams logs that reuse at INFO only). This is the
    # last thing the operator sees before numbers start coming off.
    $tenantIdText = [string](Get-MigrationProperty -InputObject $tenant -Name 'TenantId' -Default '<unknown>')
    $tenantName = [string](Get-MigrationProperty -InputObject $tenant -Name 'DisplayName' -Default '')
    $tenantLabel = "$tenantIdText ($tenantName)"
    $tenantVerb = if ($isDryRun) { 'would be released from' } else { 'will be released from' }
    Write-MigrationLog -Message "TARGET TENANT: $tenantLabel - phone numbers $tenantVerb this tenant." -Level WARNING

    # Each entry pairs the resolved Teams user (or $null) with the identity supplied, so an
    # unresolved row still reports something the operator recognises.
    $targets = [System.Collections.Generic.List[object]]::new()
    $addTarget = {
        param([string]$Supplied, $TeamsUser)
        $targets.Add([pscustomobject]@{ Supplied = $Supplied; User = $TeamsUser })
    }

    switch ($PSCmdlet.ParameterSetName) {
        'User' {
            Write-MigrationLog -Message "Resolving single user '$User'..." -Level INFO
            & $addTarget $User (Resolve-MigrationTeamsUser -Identity $User)
        }

        'Csv' {
            $rows = @(Import-MigrationCsv -Path $CsvPath)

            # Import-MigrationCsv maps a bare Email/Mail column to PrimarySmtpAddress rather
            # than UserPrincipalName. Get-CsOnlineUser -Identity resolves a UPN, SIP address,
            # alias or object ID - not a mail address as such - so the fallback only works
            # where the address equals the UPN or SIP address; otherwise the row is Failed
            # as 'User not found'. It is kept so a hand-built file with an Email column is
            # not rejected outright.
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
                & $addTarget $identity (Resolve-MigrationTeamsUser -Identity $identity)
            }
        }

        'All' {
            Write-MigrationLog -Message 'Retrieving every user with an assigned phone number...' -Level INFO
            $withNumbers = $null
            try {
                $withNumbers = @(Get-CsOnlineUser -Filter 'LineUri -ne $null' -ErrorAction Stop)
            }
            catch {
                # The cause is logged with the fallback: a rejected filter syntax and a
                # throttled or expired session look identical without it, and the full pull
                # below fails fast on its own if the cause was transient.
                Write-MigrationLog -Message ("Server-side LineUri filter failed ({0}) - pulling all users and filtering locally." -f $_.Exception.Message) -Level WARNING
                $withNumbers = @(Get-CsOnlineUser -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) })
            }
            foreach ($candidate in $withNumbers) {
                & $addTarget ([string]$candidate.UserPrincipalName) $candidate
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
        $onPremLineUri = ''
        $accountType = ''

        try {
            if ($null -eq $target) {
                # A Failed row, not a skip: the operator named this identity and the removal
                # they asked for did not happen, so the exit code has to reflect it.
                $status = 'Failed'
                $detail = 'User not found in this tenant.'
            }
            else {
                $identity = if ($target.UserPrincipalName) { [string]$target.UserPrincipalName } else { $identity }
                $displayName = [string]$target.DisplayName
                $voicePolicy = Get-MigrationTeamsPolicyName -Policy $target.OnlineVoiceRoutingPolicy

                # Get-MigrationProperty rather than a direct read: AccountType and OnPremLineURI
                # are absent on older module versions and StrictMode would abort the row.
                $accountType = [string](Get-MigrationProperty -InputObject $target -Name 'AccountType' -Default '')
                $onPremLineUri = [string](Get-MigrationProperty -InputObject $target -Name 'OnPremLineURI' -Default '')

                $line = Split-MigrationTeamsLineUri -LineUri $target.LineUri
                $phoneNumber = $line.Number
                $extension = $line.Extension

                $userId = [string]$target.Identity
                $numberInfo = if ($userId -and $numbersByTarget.ContainsKey($userId)) { $numbersByTarget[$userId] } else { $null }
                $locationId = if ($numberInfo) { [string]$numberInfo.LocationId } else { $null }
                $numberType = if ($numberInfo) { [string]$numberInfo.NumberType }
                elseif ($phoneNumber) { 'DirectRouting' }
                else { $null }
                # NumberSource exists from Teams PowerShell 5.7.0; 'OnPremises' marks a number
                # assigned in on-prem AD even where OnPremLineURI was not returned.
                $numberSource = if ($numberInfo) { [string](Get-MigrationProperty -InputObject $numberInfo -Name 'NumberSource' -Default '') } else { '' }

                if (-not [string]::IsNullOrWhiteSpace($onPremLineUri) -or $numberSource -eq 'OnPremises') {
                    # Checked before the no-number case so a user with only OnPremLineURI still
                    # gets the on-prem reason. Remove-CsPhoneNumberAssignment is not documented
                    # to refuse these, and a release that AD sync reverts would read as Succeeded.
                    $status = 'Failed'
                    $detail = 'Number is set on-premises (OnPremLineURI) - clear it in on-prem AD and let it sync; not attempted.'
                }
                elseif (-not $phoneNumber) {
                    $status = 'Skipped'
                    $detail = 'No phone number assigned.'
                }
                elseif ($isDryRun) {
                    $null = Invoke-MigrationAction -Description "Unassign phone number $phoneNumber from $identity" -Action { }
                    $status = 'Planned'
                    $detail = "Would remove $phoneNumber ($numberType)."
                }
                elseif ($PSCmdlet.ShouldProcess($identity, "Unassign phone number $phoneNumber")) {
                    # -ErrorAction Stop so a failed removal lands in catch and is recorded as
                    # Failed. Module versions before 4.2.1 report failure by returning an object
                    # with Code and Message instead of throwing, so the output is inspected too.
                    $result = Invoke-MigrationAction -Description "Unassign phone number $phoneNumber from $identity" -Action {
                        Remove-CsPhoneNumberAssignment -Identity $identity -RemoveAll -ErrorAction Stop
                    } -PassThru
                    $failureCode = [string](Get-MigrationProperty -InputObject $result -Name 'Code' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($failureCode)) {
                        $failureMessage = [string](Get-MigrationProperty -InputObject $result -Name 'Message' -Default '')
                        throw "Remove-CsPhoneNumberAssignment returned $failureCode`: $failureMessage"
                    }
                    $status = 'Succeeded'
                    $detail = "Removed $phoneNumber ($numberType)."
                }
                else {
                    # Not a rehearsal: -WhatIf or a declined prompt means nothing was attempted,
                    # so the row is a skip. 'Planned' is reserved for -DryRun.
                    $status = 'Skipped'
                    $detail = 'Declined at the confirmation prompt.'
                }
            }
        }
        catch {
            $status = 'Failed'
            $message = $_.Exception.Message
            # Backstop for the pre-check above: the service's own wording if it does refuse.
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
        # Set-MigrationTeamsPhoneAssignments.ps1, so this file doubles as the reassignment
        # input. OnPremLineURI and AccountType are informational and are ignored on the way back.
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
                OnPremLineURI            = $onPremLineUri
                AccountType              = $accountType
            })
    }

    Write-Progress -Activity 'Unassigning phone numbers' -Completed

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
