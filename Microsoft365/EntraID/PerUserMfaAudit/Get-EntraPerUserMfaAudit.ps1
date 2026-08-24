#Requires -Version 7.0

<#
.SYNOPSIS
    Audits legacy per-user MFA state (Enabled/Enforced/Disabled) across a Microsoft Entra tenant.

.DESCRIPTION
    Read-only reporting tool that enumerates users and queries each one's legacy per-user
    multifactor authentication state via the Microsoft Graph beta endpoint:

        GET /beta/users/{id}/authentication/requirements  ->  perUserMfaState

    WHY THIS MATTERS
    Legacy per-user MFA (states "enabled" and "enforced") is evaluated independently of
    Conditional Access. It overrides Conditional Access application exclusions and silently
    breaks non-interactive authentication flows - most notably Entra-joined VM sign-in
    (Azure Virtual Desktop / Azure Windows VM Sign-In) and identity-based SMB mounts to
    Azure Files (FSLogix profile containers). Tenants migrating to Conditional Access-based
    MFA need to find every account still set to Enabled or Enforced. This script finds them.

    This script performs no writes to Entra ID of any kind - it is read-only by design; the
    only thing it creates is the local CSV report. Remediation (setting perUserMfaState to
    "disabled") is documented in the accompanying README but deliberately not implemented.

    SCOPE OF THE AUDIT
    - Default (no targeting parameters): all enabled member users in the tenant. Guests are
      excluded. Runs over 1,000 users require -Force or an interactive confirmation.
    - -GroupId: transitive user members of one Entra group.
    - -UserPrincipalName: only the users you name. Explicitly named users are audited even
      if their account is disabled.
    - Disabled accounts are excluded from tenant-wide and group audits unless
      -IncludeDisabledAccounts is specified.

    AUTHENTICATION AND PERMISSIONS
    Uses the Microsoft Graph PowerShell SDK. If no Graph session exists, an interactive
    (delegated) sign-in is started with the required scopes. An existing Connect-MgGraph
    session - including app-only (client credential) sessions - is reused as-is. Graph
    calls are issued with relative URIs, so sovereign-cloud sessions (Connect-MgGraph
    -Environment USGov and similar) are honored.

    Required Graph permissions:
      - Policy.Read.All        Reads perUserMfaState. Least-privileged permission for
                               GET /users/{id}/authentication/requirements (delegated and
                               application). UserAuthenticationMethod.Read.All is NOT
                               sufficient - it covers system-preferred MFA sign-in
                               preferences, not the legacy per-user MFA state.
      - User.Read.All          Enumerates users and reads UPN / display name /
                               accountEnabled.
      - GroupMember.Read.All   Only when -GroupId is used; reads transitive group
                               membership.

    Delegated callers must also hold an Entra role that permits reading authentication
    requirements - Global Reader or Authentication Policy Administrator are the
    least-privileged built-in roles.

    App-only (unattended) use: grant the same permissions as application permissions with
    admin consent, then connect before running this script, e.g.:
      Connect-MgGraph -ClientId <appId> -TenantId <tenantId> -CertificateThumbprint <thumb>

    NOTE ON THE BETA ENDPOINT
    perUserMfaState is only exposed on the Graph beta endpoint. The call is made with
    Invoke-MgGraphRequest against an explicit beta URL, so the beta SDK module is NOT
    required. Beta APIs can change without notice; if Microsoft promotes this API to v1.0,
    prefer that version.

.PARAMETER GroupId
    Object ID (GUID) of an Entra group. Audits the group's transitive user members
    (members of nested groups are included). Mutually exclusive with -UserPrincipalName.

.PARAMETER UserPrincipalName
    One or more user principal names to audit. Mutually exclusive with -GroupId.
    Users named here are audited even if disabled.

.PARAMETER IncludeDisabledAccounts
    Include disabled accounts in tenant-wide and group audits. Off by default because
    disabled accounts cannot sign in; their per-user MFA state is usually only interesting
    for pre-reenablement cleanup. Not applicable with -UserPrincipalName (named users are
    always audited).

.PARAMETER Force
    Skip the interactive confirmation shown when a tenant-wide audit targets more than
    1,000 users. Required for unattended tenant-wide runs on large tenants. A runtime
    warning is still emitted.

.PARAMETER OutputPath
    Path for the CSV export. Defaults to a timestamped file in the platform temp
    directory. The resolved path is printed at completion (all verbosity levels). Pass an
    empty string ('') to skip the CSV export entirely.

.PARAMETER PassThru
    Also emit the per-user result objects to the pipeline (in addition to the CSV export).
    Includes ERROR rows for user principal names that could not be resolved.

.PARAMETER Verbosity
    Console output level. Silent = warnings, errors, and the report path only (results
    still export / emit); Normal = progress and summary; Detailed = adds one line per
    audited user.

.OUTPUTS
    With -PassThru: one [pscustomobject] per audited user with properties
    UserPrincipalName, DisplayName, AccountEnabled, PerUserMfaState, Flag, ErrorDetail.
    Flag is "REVIEW" (state enabled/enforced, or an unrecognized state - see ErrorDetail),
    "OK" (disabled), or "ERROR" (lookup failed; see ErrorDetail).

.EXAMPLE
    ./Get-EntraPerUserMfaAudit.ps1 -GroupId 11111111-2222-3333-4444-555555555555

    Audits the transitive user members of one group - for example, an AVD users group -
    and writes the CSV report to the temp directory.

.EXAMPLE
    ./Get-EntraPerUserMfaAudit.ps1 -Force -OutputPath ./mfa-audit.csv

    Audits every enabled member user in the tenant without the large-tenant confirmation
    prompt and writes the report to ./mfa-audit.csv. In CI, check the exit code:
    0 = all disabled, 1 = accounts need review (or some lookups failed), 2 = fatal.

.EXAMPLE
    ./Get-EntraPerUserMfaAudit.ps1 -UserPrincipalName user1@contoso.com,user2@contoso.com -PassThru -Verbosity Silent |
        Where-Object Flag -eq 'REVIEW'

    Pipeline consumption: audits two specific accounts silently and passes only the
    accounts still set to enabled/enforced down the pipeline.

.NOTES
    Version : 1.0.0
    Created : 2026-08-24
    Requires: PowerShell 7+ (cross-platform: Windows, macOS, Linux) and the
              Microsoft.Graph.Authentication + Microsoft.Graph.Users modules.

    Exit codes:
      0  Completed; every audited user is in the "disabled" per-user MFA state.
      1  Completed; one or more users are enabled/enforced, or some per-user lookups
         failed (inspect the ERROR rows). Nonzero here means "needs attention", which
         makes the script usable as a scheduled/CI compliance check.
      2  Fatal error (module missing, authentication failed, target group not found,
         audit scope resolved to zero users, confirmation declined, throttling retries
         exhausted during enumeration, or every single lookup failed - i.e. the audit
         produced no usable evidence).

    This tool is READ-ONLY. It never modifies per-user MFA state.

    Developed with AI assistance (Claude); reviewed before publication.

.LINK
    https://learn.microsoft.com/graph/api/authentication-get?view=graph-rest-beta

.LINK
    https://learn.microsoft.com/entra/identity/authentication/howto-mfa-userstates
#>

[CmdletBinding(DefaultParameterSetName = 'AllUsers')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Group')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$',
        ErrorMessage = 'GroupId must be a GUID (the group object ID, not its display name).')]
    [string]$GroupId,

    [Parameter(Mandatory, ParameterSetName = 'Users')]
    [ValidateNotNullOrEmpty()]
    [string[]]$UserPrincipalName,

    [Parameter(ParameterSetName = 'Group')]
    [Parameter(ParameterSetName = 'AllUsers')]
    [switch]$IncludeDisabledAccounts,

    [Parameter(ParameterSetName = 'AllUsers')]
    [switch]$Force,

    [Parameter()]
    [AllowEmptyString()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru,

    [Parameter()]
    [ValidateSet('Silent', 'Normal', 'Detailed')]
    [string]$Verbosity = 'Normal'
)

#region Configuration & Constants

# Relative URIs so Invoke-MgGraphRequest resolves against the connected cloud
# (commercial, US Gov, China) instead of pinning graph.microsoft.com.
$graphBetaBase = '/beta'
$graphV1Base = '/v1.0'
$largeTenantThreshold = 1000
$maxRetries = 5
$maxBackoffSeconds = 60
$userSelectProperties = 'Id', 'UserPrincipalName', 'DisplayName', 'AccountEnabled'

$exitClean = 0
$exitReview = 1
$exitFatal = 2

# Default computed here (not in the param block) to keep the declaration readable and to
# distinguish "omitted" from the explicit '' that disables the export.
if (-not $PSBoundParameters.ContainsKey('OutputPath')) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "EntraPerUserMfaAudit-$timestamp.csv"
}

#endregion Configuration & Constants

#region Helper Functions

function Write-AuditStatus {
    <#
        Console status messages, gated by -Verbosity. Data never flows through here -
        results go to the pipeline and CSV; this is human-facing status only.
        -InformationAction Continue deliberately overrides the common parameter: the
        script's -Verbosity is the single knob for console noise.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Normal', 'Detailed')]
        [string]$Level = 'Normal'
    )

    if ($script:Verbosity -eq 'Silent') { return }
    if ($Level -eq 'Detailed' -and $script:Verbosity -ne 'Detailed') { return }
    Write-Information -MessageData $Message -InformationAction Continue
}

function Get-ResponseStatusCode {
    # Extracts an HTTP status code from a Graph SDK / HTTP error record, if one exists.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
        Justification = 'Probing optional members on unknown exception shapes; absence is expected.')]
    param([Parameter(Mandatory)]$ErrorRecord)

    $ex = $ErrorRecord.Exception
    while ($ex) {
        foreach ($propName in 'StatusCode', 'Response') {
            $prop = $ex.PSObject.Properties[$propName]
            if (-not $prop -or $null -eq $prop.Value) { continue }
            try {
                if ($propName -eq 'StatusCode') { return [int]$prop.Value }
                if ($null -ne $prop.Value.StatusCode) { return [int]$prop.Value.StatusCode }
            }
            catch { }
        }
        $ex = $ex.InnerException
    }
    return $null
}

function Get-RetryAfterDelay {
    <#
        Returns the server-requested Retry-After delay in whole seconds, or $null.
        PowerShell auto-unwraps Nullable<T> on property access, so RetryAfter.Delta is a
        bare TimeSpan (never test .HasValue on it - that resolves to $null and both
        branches would silently never run).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
        Justification = 'Probing optional members on unknown exception shapes; absence is expected.')]
    param([Parameter(Mandatory)]$ErrorRecord)

    $ex = $ErrorRecord.Exception
    while ($ex) {
        try {
            $retryAfter = $ex.Response.Headers.RetryAfter
            if ($retryAfter) {
                if ($null -ne $retryAfter.Delta) {
                    return [int][Math]::Ceiling(([timespan]$retryAfter.Delta).TotalSeconds)
                }
                if ($null -ne $retryAfter.Date) {
                    $until = ([datetimeoffset]$retryAfter.Date) - [DateTimeOffset]::UtcNow
                    return [int][Math]::Ceiling($until.TotalSeconds)
                }
            }
        }
        catch { }
        $ex = $ex.InnerException
    }
    return $null
}

function Invoke-GraphRequestWithRetry {
    <#
        Invoke-MgGraphRequest with throttling awareness: honors Retry-After on 429/503,
        otherwise falls back to capped exponential backoff. The Graph SDK has its own
        internal retry handler; this wrapper is the safety net for the retries it gives
        up on, and gives us a single choke point for actionable error messages.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [string]$Method = 'GET',

        [hashtable]$Headers
    )

    for ($attempt = 1; $attempt -le $script:maxRetries; $attempt++) {
        try {
            $request = @{ Method = $Method; Uri = $Uri; ErrorAction = 'Stop' }
            if ($Headers) { $request.Headers = $Headers }
            return Invoke-MgGraphRequest @request
        }
        catch {
            $statusCode = Get-ResponseStatusCode -ErrorRecord $_

            if ($statusCode -in 401, 403) {
                throw "Access denied (HTTP $statusCode) for '$Uri'. Confirm the required Graph permissions " +
                'are consented for this tenant (Policy.Read.All, User.Read.All, and GroupMember.Read.All ' +
                'for group audits) and - for delegated sign-in - that the caller holds an Entra role able ' +
                'to read authentication requirements (Global Reader or Authentication Policy ' +
                "Administrator). Original error: $($_.Exception.Message)"
            }

            $retryable = $statusCode -in 429, 503, 504
            if (-not $retryable -or $attempt -eq $script:maxRetries) {
                if ($retryable) {
                    throw "Graph throttling persisted after $script:maxRetries attempts for '$Uri'. " +
                    'Re-run later or narrow the audit scope (-GroupId / -UserPrincipalName). ' +
                    "Last error: $($_.Exception.Message)"
                }
                throw
            }

            $delay = Get-RetryAfterDelay -ErrorRecord $_
            if ($null -eq $delay -or $delay -lt 1) {
                $delay = [Math]::Min([Math]::Pow(2, $attempt), $script:maxBackoffSeconds)
            }
            $delay = [Math]::Min($delay, $script:maxBackoffSeconds)

            Write-Verbose ("HTTP $statusCode from Graph; attempt $attempt/$script:maxRetries, " +
                "retrying in $delay second(s): $Uri")
            Start-Sleep -Seconds $delay
        }
    }
}

function Test-RequiredModule {
    # Fails fast with an install instruction rather than auto-installing - a public
    # audit tool should not modify the machine it runs on.
    param([Parameter(Mandatory)][string[]]$Name)

    $missing = $Name | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if ($missing) {
        $installCmd = ($missing | ForEach-Object { "Install-Module $_ -Scope CurrentUser" }) -join '; '
        throw "Missing required module(s): $($missing -join ', '). Install with:  $installCmd"
    }
}

function New-AuditResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory object factory; changes no system state.')]
    param(
        [string]$Upn,
        [string]$DisplayName,
        [nullable[bool]]$AccountEnabled,
        [string]$PerUserMfaState,
        [Parameter(Mandatory)][ValidateSet('REVIEW', 'OK', 'ERROR')][string]$Flag,
        [string]$ErrorDetail = ''
    )

    [pscustomobject]@{
        UserPrincipalName = $Upn
        DisplayName       = $DisplayName
        AccountEnabled    = $AccountEnabled
        PerUserMfaState   = $PerUserMfaState
        Flag              = $Flag
        ErrorDetail       = $ErrorDetail
    }
}

#endregion Helper Functions

#region Main Functions

function Resolve-AuditTarget {
    <#
        Resolves the audit population for the active parameter set. Returns objects with
        Id, UserPrincipalName, DisplayName, AccountEnabled. Enumeration failures here are
        fatal (exit 2) - without a population there is nothing to audit. Per-user lookup
        failures for explicit -UserPrincipalName targets are NOT fatal; they become ERROR
        rows in $UnresolvedResults so one typo doesn't abort a scheduled run.
    #>
    param(
        [Parameter(Mandatory)][string]$ParameterSetName,
        [string]$GroupId,
        [string[]]$UserPrincipalName,
        [switch]$IncludeDisabledAccounts,
        [switch]$Force,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$UnresolvedResults
    )

    switch ($ParameterSetName) {
        'Users' {
            $resolved = [System.Collections.Generic.List[object]]::new()
            foreach ($upn in $UserPrincipalName) {
                try {
                    $user = Get-MgUser -UserId $upn -Property $script:userSelectProperties -ErrorAction Stop
                    $resolved.Add($user)
                }
                catch {
                    Write-AuditStatus "Could not resolve '$upn': $($_.Exception.Message)"
                    $UnresolvedResults.Add(
                        (New-AuditResult -Upn $upn -Flag ERROR -ErrorDetail "Lookup failed: $($_.Exception.Message)"))
                }
            }
            return $resolved
        }

        'Group' {
            # Raw REST keeps the module footprint to Authentication + Users; the
            # user-typed cast segment filters out nested non-user members server-side.
            $members = [System.Collections.Generic.List[object]]::new()
            $select = $script:userSelectProperties -join ','
            $uri = "$script:graphV1Base/groups/$GroupId/transitiveMembers/microsoft.graph.user" +
                "?`$select=$select&`$top=999"

            try {
                while ($uri) {
                    $page = Invoke-GraphRequestWithRetry -Uri $uri
                    foreach ($member in $page.value) {
                        $members.Add([pscustomobject]@{
                                Id                = $member.id
                                UserPrincipalName = $member.userPrincipalName
                                DisplayName       = $member.displayName
                                AccountEnabled    = $member.accountEnabled
                            })
                    }
                    $uri = $page.'@odata.nextLink'
                }
            }
            catch {
                throw "Group '$GroupId' could not be read: $($_.Exception.Message) Confirm the value is " +
                'the group OBJECT ID (not its display name) and that the session holds GroupMember.Read.All.'
            }

            if (-not $IncludeDisabledAccounts) {
                $members = $members | Where-Object AccountEnabled
            }
            return $members
        }

        'AllUsers' {
            # userType eq 'Member' is a standard (non-advanced) filter, but the /$count
            # probe needs the ConsistencyLevel: eventual header. Raw REST here also
            # avoids Get-MgUser -CountVariable, which writes to the GLOBAL scope and is
            # easy to shadow accidentally.
            $filter = "userType eq 'Member'"
            if (-not $IncludeDisabledAccounts) {
                $filter += ' and accountEnabled eq true'
            }

            $countUri = "$script:graphV1Base/users/`$count?`$filter=$([uri]::EscapeDataString($filter))"
            $probeCount = [int](Invoke-GraphRequestWithRetry -Uri $countUri -Headers @{ ConsistencyLevel = 'eventual' })

            if ($probeCount -gt $script:largeTenantThreshold) {
                $estimateMinutes = [Math]::Max(1, [Math]::Ceiling($probeCount / 600))
                Write-Warning ("Tenant-wide audit targets $probeCount users - one Graph call each, " +
                    "roughly $estimateMinutes minute(s) at typical throughput.")

                if (-not $Force) {
                    $prompt = "Audit all $probeCount users?"
                    $proceed = $false
                    try {
                        $proceed = $PSCmdlet.ShouldContinue($prompt, 'Large tenant audit')
                    }
                    catch {
                        # Non-interactive host: ShouldContinue cannot prompt.
                        throw "Tenant-wide audit targets $probeCount users (> $script:largeTenantThreshold) " +
                        'and no interactive confirmation is possible. Re-run with -Force, or narrow the ' +
                        'scope with -GroupId / -UserPrincipalName.'
                    }
                    if (-not $proceed) {
                        throw 'Audit cancelled at the large-tenant confirmation prompt. Re-run with -Force to skip it.'
                    }
                }
            }

            # The SDK's built-in retry handler covers throttling on this paged
            # enumeration; the custom wrapper is deliberately not layered on top.
            return Get-MgUser -Filter $filter -All -Property $script:userSelectProperties `
                -PageSize 999 -ErrorAction Stop
        }
    }
}

function Get-PerUserMfaResult {
    # One user in, one result row out. Never throws - failures become ERROR rows.
    param([Parameter(Mandatory)]$User)

    $row = @{
        Upn            = $User.UserPrincipalName
        DisplayName    = $User.DisplayName
        AccountEnabled = $User.AccountEnabled
    }

    try {
        $requirementsUri = "$script:graphBetaBase/users/$($User.Id)/authentication/requirements"
        $requirements = Invoke-GraphRequestWithRetry -Uri $requirementsUri
        $state = [string]$requirements.perUserMfaState

        switch ($state) {
            'disabled' {
                New-AuditResult @row -PerUserMfaState $state -Flag 'OK'
            }
            { $_ -in 'enabled', 'enforced' } {
                New-AuditResult @row -PerUserMfaState $state -Flag 'REVIEW'
            }
            default {
                # A successful read of a value this script doesn't know (e.g. a future
                # enum member on this beta API) is not a failed lookup - flag it for
                # human review rather than reporting it as an error.
                New-AuditResult @row -PerUserMfaState $state -Flag 'REVIEW' `
                    -ErrorDetail "Unrecognized perUserMfaState value '$state'; verify this account in the portal."
            }
        }
    }
    catch {
        New-AuditResult @row -Flag 'ERROR' -ErrorDetail $_.Exception.Message
    }
}

#endregion Main Functions

#region Script Body

$exitCode = $exitFatal
try {
    Test-RequiredModule -Name 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users'

    $requiredScopes = @('User.Read.All', 'Policy.Read.All')
    if ($PSCmdlet.ParameterSetName -eq 'Group') {
        $requiredScopes += 'GroupMember.Read.All'
    }

    $context = Get-MgContext
    if (-not $context) {
        Write-AuditStatus "Connecting to Microsoft Graph (delegated) with scopes: $($requiredScopes -join ', ')"
        try {
            Connect-MgGraph -Scopes $requiredScopes -NoWelcome -ErrorAction Stop
        }
        catch {
            throw "Microsoft Graph sign-in failed: $($_.Exception.Message). For unattended use, connect " +
            'app-only first (Connect-MgGraph -ClientId ... -CertificateThumbprint ...) - see the script help.'
        }
        $context = Get-MgContext
    }
    else {
        Write-AuditStatus "Reusing existing Graph session ($($context.AuthType)) for tenant $($context.TenantId)."
        if ($context.AuthType -eq 'Delegated') {
            # Best-effort check: higher-privileged scopes can satisfy these, so warn
            # rather than fail; the actual Graph calls are the authority.
            $missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
            if ($missingScopes) {
                Write-Warning ("Current session may lack scope(s): $($missingScopes -join ', '). " +
                    'If calls fail with 403, run Disconnect-MgGraph and let this script reconnect.')
            }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $resolveArgs = @{
        ParameterSetName        = $PSCmdlet.ParameterSetName
        GroupId                 = $GroupId
        UserPrincipalName       = $UserPrincipalName
        IncludeDisabledAccounts = $IncludeDisabledAccounts
        Force                   = $Force
        UnresolvedResults       = $results
    }
    $targets = @(Resolve-AuditTarget @resolveArgs)

    # Rows added during target resolution (unresolvable UPNs) must reach the pipeline
    # too, or -PassThru and the CSV would disagree about the same run.
    if ($PassThru -and $results.Count -gt 0) { $results }

    if ($targets.Count -eq 0 -and $PSCmdlet.ParameterSetName -ne 'Users') {
        # Exit 0 on an empty scope would assert "all clear" about an audit that
        # inspected nothing - fail loudly instead.
        throw 'Audit scope resolved to zero users. Check -GroupId (empty group?) or -IncludeDisabledAccounts.'
    }

    Write-AuditStatus "Auditing per-user MFA state for $($targets.Count) user(s)..."

    $processed = 0
    foreach ($user in $targets) {
        $processed++
        if ($script:Verbosity -ne 'Silent') {
            Write-Progress -Activity 'Auditing per-user MFA state' `
                -Status "$processed of $($targets.Count): $($user.UserPrincipalName)" `
                -PercentComplete (($processed / $targets.Count) * 100)
        }

        $result = Get-PerUserMfaResult -User $user
        $results.Add($result)
        Write-AuditStatus "[$($result.Flag)] $($result.UserPrincipalName) : $($result.PerUserMfaState)" -Level Detailed
        if ($PassThru) { $result }
    }
    if ($script:Verbosity -ne 'Silent') {
        Write-Progress -Activity 'Auditing per-user MFA state' -Completed
    }

    # -- Export ------------------------------------------------------------------
    $resolvedOutputPath = $null
    if ($OutputPath -and $results.Count -gt 0) {
        $outputDir = Split-Path -Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path -Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        }
        # utf8BOM so Excel on Windows renders non-ASCII display names correctly.
        $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8BOM
        $resolvedOutputPath = (Resolve-Path -Path $OutputPath).Path
    }

    # -- Summary -----------------------------------------------------------------
    $reviewRows = @($results | Where-Object Flag -eq 'REVIEW')
    $errorRows = @($results | Where-Object Flag -eq 'ERROR')

    $summary = [pscustomobject]@{
        TotalAudited = $results.Count
        Disabled     = @($results | Where-Object PerUserMfaState -eq 'disabled').Count
        Enabled      = @($results | Where-Object PerUserMfaState -eq 'enabled').Count
        Enforced     = @($results | Where-Object PerUserMfaState -eq 'enforced').Count
        Errors       = $errorRows.Count
        ReportPath   = $resolvedOutputPath ?? '(export skipped)'
    }

    if ($script:Verbosity -ne 'Silent') {
        Write-Information -MessageData ($summary | Format-List | Out-String).TrimEnd() -InformationAction Continue
    }

    if ($reviewRows.Count -gt 0) {
        # Write-Warning so the callout survives -Verbosity Silent and stands out in logs.
        $reviewList = ($reviewRows | ForEach-Object { "  $($_.UserPrincipalName) [$($_.PerUserMfaState)]" }) -join
            [Environment]::NewLine
        Write-Warning ("$($reviewRows.Count) account(s) still have legacy per-user MFA enabled/enforced:" +
            [Environment]::NewLine + $reviewList)
    }
    if ($errorRows.Count -gt 0) {
        Write-Warning "$($errorRows.Count) user(s) could not be audited - see the ErrorDetail column."
    }
    if ($resolvedOutputPath) {
        # Spec: the resolved path is always printed, even at -Verbosity Silent -
        # otherwise a scripted run exports to a temp path the caller is never told.
        Write-Information -MessageData "Report written to: $resolvedOutputPath" -InformationAction Continue
    }

    if ($results.Count -gt 0 -and $errorRows.Count -eq $results.Count) {
        # Every single lookup failed (the shape a blanket 403 takes): the audit
        # produced no usable evidence, which is a fatal condition, not "needs review".
        throw "All $($results.Count) lookups failed - see the ErrorDetail column. " +
        "First error: $($errorRows[0].ErrorDetail)"
    }

    $exitCode = if ($reviewRows.Count -gt 0 -or $errorRows.Count -gt 0) { $exitReview } else { $exitClean }
}
catch {
    $message = $_.Exception.Message
    if ($message -match 'Assembly with same name is already loaded') {
        $message += ' This usually means mismatched Microsoft.Graph.* module versions - update them to ' +
        'matching versions: Update-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users'
    }
    # -ErrorAction Continue: under a caller's $ErrorActionPreference = 'Stop' a bare
    # Write-Error would terminate here and exit 1, breaking the exit-code contract.
    Write-Error "Fatal: $message" -ErrorAction Continue
    $exitCode = $exitFatal
}

#endregion Script Body

exit $exitCode
