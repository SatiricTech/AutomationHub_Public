#Requires -Version 7.4

<#
.SYNOPSIS
    Exports every user's Viva Learning learner history (course assignments and
    self-initiated courses) from a tenant to a CSV + JSON pair, ready to re-import
    in a destination tenant.

.DESCRIPTION
    Connects to Microsoft Graph (interactive sign-in) and pulls each user's
    learningCourseActivities from the employee learning API, one user at a time
    (the API has no tenant-wide listing endpoint). Where possible each activity is
    enriched with the course metadata (title, URL, description, duration...) by
    reading the catalogs of the tenant's API-registered learning providers, so the
    export can be replayed into another tenant by the companion script:

      Import-MigrationVivaLearningHistory.ps1 - recreate the records in the destination

    Three files are written to the run's output directory:
      <Prefix>_VivaLearningHistory_<timestamp>.csv      - flat, one row per activity
      <Prefix>_VivaLearningHistory_<timestamp>.json     - raw Graph objects (fidelity backup)
      <Prefix>_Get-VivaLearningHistory-Results_<ts>.csv - one row per user read

    API quirks this script works around (documented behaviour as of Aug 2026):
      - Listing course activities supports DELEGATED sign-in only; app-only
        (client credential) tokens are rejected. The delegated scopes are
        LearningAssignedCourse.Read and LearningSelfInitiatedCourse.Read. The
        .All variants that Microsoft's list page mentions exist only as
        application permissions (the permissions reference carries their
        identifiers), so requesting them at a delegated sign-in fails at Entra
        before the consent prompt - this script never asks for them.
      - Whether a delegated token can read OTHER users' activities is not
        documented. The signed-in account is read through /me (the documented
        path); every other user goes through /users/{id}. A 403 there is
        reported as Failed and, after 10 consecutive cross-user denials, the
        remaining users are marked Skipped rather than making one doomed call
        each. When no cross-user read succeeded at all, the log points at the
        fallback (the Viva Learning admin "Download learner completion records"
        export).
      - peerRecommended assignment types are only returned when the request
        carries a 'Prefer: include-unknown-enum-members' header; without it they
        surface as unknownFutureValue.
      - Course metadata is only readable for API-registered providers. Activities
        pointing at content the API cannot resolve (typically built-in providers
        like LinkedIn Learning) export with blank Course* columns - fill in at
        least CourseTitle and CourseWebUrl in the CSV before importing those rows.
      - An assigner whose account no longer exists exports with a blank
        AssignerUserPrincipalName. A lookup that fails for any other reason (403,
        5xx, exhausted throttling) is logged once per assigner and counted in the
        summary; the raw JSON still carries the assignerUserId.

.PARAMETER OutputPath
    Root directory for the log, the export and the results CSV. Defaults to
    %LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations
    elsewhere.

.PARAMETER Prefix
    Client/run label (e.g. 'Contoso' or 'Source'). When given, files land in
    <root>\<Prefix>\ and file names start with <Prefix>_.

.PARAMETER TenantId
    Tenant ID (GUID) or verified domain (for example contoso.onmicrosoft.com) to
    sign in to. Pins the interactive sign-in to the intended tenant, which
    matters when the admin account can reach several.

.PARAMETER User
    One or more users (UPN or object ID) to export instead of the whole tenant.
    Use it to rehearse against a single account before running the full pull.

.PARAMETER IncludeGuests
    Include guest accounts in the pull. By default only member users are read.

.PARAMETER SkipCourseMetadata
    Skip reading the learning provider catalogs (and don't request the
    LearningProvider.Read / LearningContent.Read.All scopes). Activities still
    export, but every Course* column is blank.

.PARAMETER DryRun
    Preview only - resolve the output location, print the planned output files
    and write a -DryRun_ results file with Status Planned, then exit without
    connecting to Microsoft 365 or exporting anything. A real run writes nothing
    to the tenant either, so the rehearsal that tells you something is
    -User <your own account>: it exercises the sign-in and the scope consent
    against one account.

.PARAMETER Verbosity
    Console detail: Low (errors and successes), Medium (adds warnings) or High
    (everything). The log file always receives everything.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -Prefix Source

    Interactive sign-in, exports every member user's learner history into
    <root>\Source\.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -OutputPath 'C:\Migrations' -Prefix Contoso -TenantId contoso.onmicrosoft.com

    Pins the sign-in to the source tenant (recommended when the admin account
    can reach several) and files the export under C:\Migrations\Contoso.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -User john.smith@contoso.com -Prefix Test -Verbosity High

    Rehearses the pull against one account with full console detail before
    running it tenant-wide.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -SkipCourseMetadata -DryRun

    Shows which files would be written, without signing in, consenting to the
    catalog scopes or touching the tenant.

.NOTES
    Author       : AutomationHub
    Requires     : PowerShell 7.4, the M365Migration module beside this script,
                   Microsoft.Graph.Authentication (installed on demand)
    Graph scopes : Delegated - LearningAssignedCourse.Read,
                   LearningSelfInitiatedCourse.Read, User.Read.All, and unless
                   -SkipCourseMetadata: LearningProvider.Read,
                   LearningContent.Read.All. Most of these need admin consent.
                   App-only tokens are rejected by this API.
    EXO roles    : none - this script does not use Exchange Online PowerShell
    Sign-in      : a dedicated Global Admin of the source tenant, pinned with
                   -TenantId. A partner account with an active GDAP relationship
                   also works through -TenantId; there is no -DelegatedOrganization
                   here because no Exchange connection is made. Either way the
                   signed-in user must be licensed for Viva Learning in the target
                   tenant - without a Viva Learning/Viva Suite service plan the
                   employee learning endpoints return 403.
    Session      : the Graph session is left open for the next script in the
                   chain (callers own connections). Run Disconnect-MgGraph
                   yourself before switching accounts.
    Cloud        : Global cloud only. The employee learning API is not available
                   in US Government (GCC High/DoD) or 21Vianet clouds.
    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding()]
param(
    [string]$OutputPath,

    [string]$Prefix,

    [string]$TenantId,

    [string[]]$User,

    [switch]$IncludeGuests,

    [switch]$SkipCourseMetadata,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Configuration ----------------------------------------------------------

# Only the non-.All learning scopes exist as delegated permissions. The .All
# variants are application-only (the permissions reference lists an application
# identifier and no delegated one), and requesting a scope the resource does not
# offer fails at Entra before consent - so they are never asked for here.
$metadataScopes = if ($SkipCourseMetadata) { @() } else { @('LearningProvider.Read', 'LearningContent.Read.All') }
$requiredGraphScopes = @('LearningAssignedCourse.Read', 'LearningSelfInitiatedCourse.Read', 'User.Read.All') + $metadataScopes

# peerRecommended assignment types are only returned with this header; without it
# they surface as unknownFutureValue.
$learningPreferHeader = @{ Prefer = 'include-unknown-enum-members' }

# Consecutive 403s on /users/{id} reads before the rest of the tenant is marked
# Skipped instead of making one rejected call per user. Any successful cross-user
# read resets the count, so a few genuinely restricted accounts do not trip it.
$crossUserDenialLimit = 10

#endregion ---------------------------------------------------------------------

#region Functions --------------------------------------------------------------

function ConvertTo-FlatDateTime {
    <#
        Graph returns some timestamps without the trailing 'Z' - normalise to ISO 8601
        UTC. The SDK's PSObject output (and ConvertFrom-Json) may already have turned
        the value into a [datetime], whose [string] form is culture-dependent, so those
        are formatted directly rather than round-tripped through text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($Value -is [datetime]) {
        $utc = if ($Value.Kind -eq [DateTimeKind]::Unspecified) { [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }
        return $utc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return [string]$Value
}

function Add-LearningResultRow {
    <#
        Appends one row to a results list. Identity, Action, Status and Detail lead
        because that is the toolkit's fixed results-file contract; ActivityCount is
        this script's one extra column.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        # AllowEmptyCollection: the list is always empty when the first row arrives.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Target,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Identity,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateSet('Planned', 'Succeeded', 'Skipped', 'Failed')]
        [string]$Status,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Detail,

        [int]$ActivityCount = 0
    )

    $Target.Add([pscustomobject][ordered]@{
            Identity      = $Identity
            Action        = $Action
            Status        = $Status
            Detail        = $Detail
            ActivityCount = $ActivityCount
        })
}

function Get-LearningActivityUri {
    <#
        Picks the list URI for one user. /me is the path the delegated non-.All
        scopes are documented for, so the signed-in account always goes that way;
        everyone else goes through /users/{id}, which is the undocumented case the
        caller has to watch for 403s.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$UserId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$UserPrincipalName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$SignedInAccount
    )

    $isSelf = [bool]($UserPrincipalName -and $SignedInAccount -and ($UserPrincipalName -ieq $SignedInAccount))
    $uri = if ($isSelf) {
        '/v1.0/me/employeeExperience/learningCourseActivities?$top=100'
    }
    else {
        "/v1.0/users/$UserId/employeeExperience/learningCourseActivities?`$top=100"
    }

    return [pscustomobject]@{ Uri = $uri; IsSelf = $isSelf }
}

function Resolve-LearningAssignerUpn {
    <#
        Resolves an assigner's object id to a UPN so the destination tenant can remap
        it - the raw GUID is meaningless outside this tenant. Results are cached per
        id because one manager typically assigns many courses. Outcome says why a
        blank came back:
          Resolved / Cached - UPN found (Cached may itself be a blank from earlier)
          NotFound          - 404, or 400 for a malformed id: the assigner is gone.
                              Cached blank silently; this is the expected case.
          Failed            - any other status (403, 5xx, network). Warned once and
                              cached blank, because the same call would fail for
                              every later activity from this assigner.
          Retryable         - 429/503/504 after the wrapper's own retries. Warned
                              and NOT cached, so a later activity from the same
                              assigner gets another attempt.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$AssignerId,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable]$Cache
    )

    if ($Cache.ContainsKey($AssignerId)) {
        return [pscustomobject]@{ UserPrincipalName = $Cache[$AssignerId]; Outcome = 'Cached' }
    }

    try {
        $assigner = Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/users/$AssignerId`?`$select=userPrincipalName"
        $upn = [string](Get-MigrationProperty -InputObject $assigner -Name 'userPrincipalName')
        $Cache[$AssignerId] = $upn
        return [pscustomobject]@{ UserPrincipalName = $upn; Outcome = 'Resolved' }
    }
    catch {
        $statusCode = Get-MigrationGraphErrorStatusCode -ErrorRecord $_
        if ($statusCode -in @(429, 503, 504)) {
            Write-MigrationLog -Message ("  Could not resolve assigner $AssignerId (HTTP $statusCode after retries) - " +
                'will try again on the next activity from this assigner.') -Level WARNING
            return [pscustomobject]@{ UserPrincipalName = $null; Outcome = 'Retryable' }
        }

        $Cache[$AssignerId] = $null
        if ($statusCode -in @(400, 404)) {
            return [pscustomobject]@{ UserPrincipalName = $null; Outcome = 'NotFound' }
        }

        Write-MigrationLog -Message ("  Could not resolve assigner $AssignerId (HTTP $statusCode): $($_.Exception.Message) - " +
            'AssignerUserPrincipalName exports blank for this assigner.') -Level WARNING
        return [pscustomobject]@{ UserPrincipalName = $null; Outcome = 'Failed' }
    }
}

function ConvertTo-LearningHistoryRow {
    <#
        Flattens one learningCourseActivity, plus the catalog entry it points at, into
        the CSV row Import-MigrationVivaLearningHistory reads. The column names are
        that script's contract - rename here and the import stops recognising them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $Activity,

        [Parameter(Mandatory)]
        $User,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$AssignerUserPrincipalName,

        [AllowNull()]
        $Content,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable]$ProviderNamesById
    )

    $odataType = [string](Get-MigrationProperty -InputObject $Activity -Name '@odata.type')
    $activityType = if ($odataType -match 'learningAssignment') { 'Assignment' } else { 'SelfInitiated' }

    # dueDateTime is a dateTimeTimeZone object and notes an itemBody object on
    # the wire (whatever the doc tables claim) - flatten both for the CSV. The due
    # date is wall-clock time in DueDateTimeZone, so it is NOT converted to UTC;
    # a value the SDK already parsed into a [datetime] is written back in Graph's
    # own ISO format rather than the culture-dependent [string] form.
    $dueDateTime = Get-MigrationProperty -InputObject $Activity -Name 'dueDateTime'
    $dueValue = Get-MigrationProperty -InputObject $dueDateTime -Name 'dateTime'
    $dueText = if ($dueValue -is [datetime]) { $dueValue.ToString('yyyy-MM-ddTHH:mm:ss.fffffff') } else { [string]$dueValue }
    $notes = Get-MigrationProperty -InputObject $Activity -Name 'notes'
    $providerId = [string](Get-MigrationProperty -InputObject $Activity -Name 'learningProviderId')

    return [pscustomobject][ordered]@{
        UserPrincipalName         = [string](Get-MigrationProperty -InputObject $User -Name 'userPrincipalName')
        UserDisplayName           = [string](Get-MigrationProperty -InputObject $User -Name 'displayName')
        UserId                    = [string](Get-MigrationProperty -InputObject $User -Name 'id')
        ActivityType              = $activityType
        Status                    = [string](Get-MigrationProperty -InputObject $Activity -Name 'status')
        CompletionPercentage      = Get-MigrationProperty -InputObject $Activity -Name 'completionPercentage'
        CompletedDateTime         = ConvertTo-FlatDateTime -Value (Get-MigrationProperty -InputObject $Activity -Name 'completedDateTime')
        StartedDateTime           = ConvertTo-FlatDateTime -Value (Get-MigrationProperty -InputObject $Activity -Name 'startedDateTime')
        AssignedDateTime          = ConvertTo-FlatDateTime -Value (Get-MigrationProperty -InputObject $Activity -Name 'assignedDateTime')
        AssignmentType            = [string](Get-MigrationProperty -InputObject $Activity -Name 'assignmentType')
        AssignerUserId            = [string](Get-MigrationProperty -InputObject $Activity -Name 'assignerUserId')
        AssignerUserPrincipalName = $AssignerUserPrincipalName
        DueDateTime               = $dueText
        DueDateTimeZone           = [string](Get-MigrationProperty -InputObject $dueDateTime -Name 'timeZone')
        Notes                     = [string](Get-MigrationProperty -InputObject $notes -Name 'content')
        ActivityId                = [string](Get-MigrationProperty -InputObject $Activity -Name 'id')
        ExternalCourseActivityId  = [string](Get-MigrationProperty -InputObject $Activity -Name 'externalCourseActivityId')
        LearningProviderId        = $providerId
        LearningProviderName      = $ProviderNamesById[$providerId]
        LearningContentId         = [string](Get-MigrationProperty -InputObject $Activity -Name 'learningContentId')
        CourseExternalId          = [string](Get-MigrationProperty -InputObject $Content -Name 'externalId')
        CourseTitle               = [string](Get-MigrationProperty -InputObject $Content -Name 'title')
        CourseWebUrl              = [string](Get-MigrationProperty -InputObject $Content -Name 'contentWebUrl')
        CourseDescription         = [string](Get-MigrationProperty -InputObject $Content -Name 'description')
        CourseLanguage            = [string](Get-MigrationProperty -InputObject $Content -Name 'languageTag')
        CourseDuration            = [string](Get-MigrationProperty -InputObject $Content -Name 'duration')
        CourseFormat              = [string](Get-MigrationProperty -InputObject $Content -Name 'format')
        CourseLevel               = [string](Get-MigrationProperty -InputObject $Content -Name 'level')
        CourseSourceName          = [string](Get-MigrationProperty -InputObject $Content -Name 'sourceName')
        CourseThumbnailUrl        = [string](Get-MigrationProperty -InputObject $Content -Name 'thumbnailWebUrl')
        CourseSkillTags           = (@(Get-MigrationProperty -InputObject $Content -Name 'skillTags' -Default @()) -join ';')
        CourseContributors        = (@(Get-MigrationProperty -InputObject $Content -Name 'contributors' -Default @()) -join ';')
    }
}

function Write-LearningCrossUserDenialGuidance {
    <# Logs why cross-user reads are failing and what the operator can do instead. #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Reason
    )

    Write-MigrationLog -Message $Reason -Level ERROR
    Write-MigrationLog -Message ("Reading OTHER users' learner history with a delegated token is a documented grey area of " +
        'the employee learning API. Fallbacks: run this script as each user (-User with their own sign-in), or use the ' +
        'Viva Learning admin tab''s "Download learner completion records" bulk export.') -Level WARNING
}

function Read-LearningHistory {
    <#
        Reads every target user's learningCourseActivities and shapes the export.
        Returns the flattened rows, the raw Graph objects, one results row per user
        and the counters the summary block prints. It lives in a function rather than
        inline in Main so the 403/404 row mapping and the cross-user circuit breaker
        can be exercised offline with Invoke-MigrationGraphRequest mocked.

        Only /users/{id} reads count towards the circuit breaker and the "every
        cross-user read was denied" guidance; the signed-in account's /me read is
        the documented path and says nothing about whether other users are readable.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$TargetUser,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$SignedInAccount,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable]$ContentById,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable]$ProviderNamesById,

        [Parameter(Mandatory)]
        [hashtable]$PreferHeader,

        [ValidateRange(1, 1000)]
        [int]$CrossUserDenialLimit = 10
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $rawByUser = [System.Collections.Generic.List[object]]::new()
    $userResults = [System.Collections.Generic.List[object]]::new()
    $assignerUpnById = @{}
    $unresolvedAssigners = [System.Collections.Generic.HashSet[string]]::new()
    $usersWithActivities = 0
    $deniedUsers = 0
    $otherUsersRead = 0
    $otherUsersDenied = 0
    $consecutiveDenials = 0
    $unresolvedContent = 0
    $guidanceShown = $false
    $total = $TargetUser.Count

    for ($index = 0; $index -lt $total; $index++) {
        $target = $TargetUser[$index]
        $upn = [string](Get-MigrationProperty -InputObject $target -Name 'userPrincipalName')
        $userId = [string](Get-MigrationProperty -InputObject $target -Name 'id')
        Write-Progress -Activity 'Exporting Viva Learning history' `
            -Status "$($index + 1) of ${total}: $upn" `
            -PercentComplete ((($index + 1) / [math]::Max($total, 1)) * 100)

        $request = Get-LearningActivityUri -UserId $userId -UserPrincipalName $upn -SignedInAccount $SignedInAccount

        $activities = @()
        $readFailed = $false
        $statusCode = 0
        $errorMessage = ''
        try {
            $activities = @(Invoke-MigrationGraphRequest -Method GET -Uri $request.Uri -Headers $PreferHeader -All)
        }
        catch {
            $readFailed = $true
            $statusCode = Get-MigrationGraphErrorStatusCode -ErrorRecord $_
            $errorMessage = $_.Exception.Message
        }

        if ($readFailed) {
            if ($statusCode -eq 403) {
                $deniedUsers++
                Write-MigrationLog -Message "  [Denied] $upn - 403 reading this user's activities." -Level WARNING
                $detail = if ($request.IsSelf) {
                    "403 reading the signed-in account's learningCourseActivities - is it licensed for Viva Learning?"
                }
                else {
                    "403 reading this user's learningCourseActivities - the delegated token may not read other users."
                }
                Add-LearningResultRow -Target $userResults -Identity $upn -Action 'ExportLearningHistory' -Status 'Failed' -Detail $detail

                if (-not $request.IsSelf) {
                    $otherUsersDenied++
                    $consecutiveDenials++
                    $remainingCount = $total - $index - 1
                    if ($consecutiveDenials -ge $CrossUserDenialLimit -and $remainingCount -gt 0) {
                        Write-LearningCrossUserDenialGuidance -Reason ("$consecutiveDenials consecutive cross-user reads were denied (403) - " +
                            "stopping; the remaining $remainingCount user(s) are marked Skipped.")
                        $guidanceShown = $true
                        for ($remaining = $index + 1; $remaining -lt $total; $remaining++) {
                            $skippedUpn = [string](Get-MigrationProperty -InputObject $TargetUser[$remaining] -Name 'userPrincipalName')
                            Add-LearningResultRow -Target $userResults -Identity $skippedUpn -Action 'ExportLearningHistory' `
                                -Status 'Skipped' -Detail 'Not attempted - cross-user reads are being denied.'
                        }
                        break
                    }
                }
                continue
            }
            if ($statusCode -eq 404) {
                # The user has no employee experience surface at all.
                Add-LearningResultRow -Target $userResults -Identity $upn -Action 'ExportLearningHistory' `
                    -Status 'Skipped' -Detail 'No employee experience surface for this user (404).'
                continue
            }
            Write-MigrationLog -Message "  [Failed] $upn - $errorMessage" -Level ERROR
            Add-LearningResultRow -Target $userResults -Identity $upn -Action 'ExportLearningHistory' `
                -Status 'Failed' -Detail "HTTP $statusCode - $errorMessage"
            continue
        }

        # An empty list is still a successful cross-user read: the token can see this user.
        if (-not $request.IsSelf) {
            $otherUsersRead++
            $consecutiveDenials = 0
        }

        if ($activities.Count -eq 0) {
            Add-LearningResultRow -Target $userResults -Identity $upn -Action 'ExportLearningHistory' `
                -Status 'Skipped' -Detail 'No learner history recorded for this user.'
            continue
        }

        $usersWithActivities++
        $rawByUser.Add([pscustomobject]@{
                userId            = $userId
                userPrincipalName = $upn
                activities        = $activities
            })

        foreach ($activity in $activities) {
            $assignerUpn = $null
            $assignerId = [string](Get-MigrationProperty -InputObject $activity -Name 'assignerUserId')
            if ($assignerId) {
                $lookup = Resolve-LearningAssignerUpn -AssignerId $assignerId -Cache $assignerUpnById
                $assignerUpn = $lookup.UserPrincipalName
                if ($lookup.Outcome -in @('Failed', 'Retryable')) { $null = $unresolvedAssigners.Add($assignerId) }
            }

            $content = $ContentById[[string](Get-MigrationProperty -InputObject $activity -Name 'learningContentId')]
            if (-not $content) { $unresolvedContent++ }

            $rows.Add((ConvertTo-LearningHistoryRow -Activity $activity -User $target -AssignerUserPrincipalName $assignerUpn `
                        -Content $content -ProviderNamesById $ProviderNamesById))
        }

        Add-LearningResultRow -Target $userResults -Identity $upn -Action 'ExportLearningHistory' -Status 'Succeeded' `
            -Detail "Exported $($activities.Count) activity record(s)." -ActivityCount $activities.Count
    }

    Write-Progress -Activity 'Exporting Viva Learning history' -Completed

    if (-not $guidanceShown -and $otherUsersDenied -gt 0 -and $otherUsersRead -eq 0) {
        Write-LearningCrossUserDenialGuidance -Reason "Every cross-user read was denied (403 x $otherUsersDenied)."
    }

    return [pscustomobject]@{
        Rows                = $rows.ToArray()
        RawByUser           = $rawByUser.ToArray()
        Results             = $userResults.ToArray()
        UsersWithActivities = $usersWithActivities
        DeniedUsers         = $deniedUsers
        OtherUsersRead      = $otherUsersRead
        OtherUsersDenied    = $otherUsersDenied
        UnresolvedContent   = $unresolvedContent
        UnresolvedAssigners = $unresolvedAssigners.Count
    }
}

#endregion ---------------------------------------------------------------------

#region Main -------------------------------------------------------------------

$exitCode = 0

$run = Initialize-MigrationRun -ScriptName 'Get-MigrationVivaLearningHistory' -OutputPath $OutputPath `
    -Prefix $Prefix -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

$results = [System.Collections.Generic.List[object]]::new()

try {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leader = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
    $historyCsv = Join-Path -Path $run.OutputDirectory -ChildPath "${leader}VivaLearningHistory_$timestamp.csv"
    $historyJson = Join-Path -Path $run.OutputDirectory -ChildPath "${leader}VivaLearningHistory_$timestamp.json"

    if ($DryRun) {
        # This script only reads, so the DryRun stops before the sign-in: there is
        # nothing to preview that consenting to the learning scopes would reveal.
        Write-MigrationLog -Message 'Planned output files:' -Level WARNING
        Write-MigrationLog -Message "  $historyCsv" -Level WARNING
        Write-MigrationLog -Message "  $historyJson" -Level WARNING
        Write-MigrationLog -Message ('-DryRun does not sign in. To rehearse the sign-in and the scope consent, run ' +
            '-User <your own account> instead.') -Level WARNING

        $planned = if ($User) { @($User) } else { @('(every member user in the tenant)') }
        foreach ($identity in $planned) {
            Add-LearningResultRow -Target $results -Identity $identity -Action 'ExportLearningHistory' -Status 'Planned' `
                -Detail "Would read learningCourseActivities and write $historyCsv."
        }
    }
    else {
        $context = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId
        $grantedLearningScopes = @(@($context.Scopes) | Where-Object { $_ -like 'Learning*' })
        Write-MigrationLog -Message "Granted learning scopes: $($grantedLearningScopes -join ', ')" -Level INFO

        $targetUsers = [System.Collections.Generic.List[object]]::new()

        if ($User) {
            Write-MigrationLog -Message "Resolving $($User.Count) requested user(s)..." -Level INFO
            foreach ($identity in $User) {
                try {
                    $escaped = [uri]::EscapeDataString($identity)
                    $resolved = Invoke-MigrationGraphRequest -Method GET `
                        -Uri "/v1.0/users/$escaped`?`$select=id,userPrincipalName,displayName,accountEnabled,userType"
                    $targetUsers.Add($resolved)
                }
                catch {
                    # Only a genuine 404 means the account doesn't exist - anything else
                    # (403 consent gap, exhausted throttle, network) must not masquerade
                    # as "not found" or the operator chases the wrong problem.
                    $statusCode = Get-MigrationGraphErrorStatusCode -ErrorRecord $_
                    $detail = if ($statusCode -eq 404) {
                        'Not found in this tenant.'
                    }
                    else {
                        "Could not be resolved (HTTP $statusCode): $($_.Exception.Message)"
                    }
                    Write-MigrationLog -Message "  [Failed] $identity - $detail" -Level ERROR
                    Add-LearningResultRow -Target $results -Identity $identity -Action 'ResolveUser' -Status 'Failed' -Detail $detail
                }
            }
        }
        else {
            Write-MigrationLog -Message 'Retrieving users (this can take a while on large tenants)...' -Level INFO
            $allUsers = @(Invoke-MigrationGraphRequest -Method GET -All `
                    -Uri '/v1.0/users?$select=id,userPrincipalName,displayName,accountEnabled,userType&$top=999')
            foreach ($u in $allUsers) {
                if (-not $IncludeGuests -and [string](Get-MigrationProperty -InputObject $u -Name 'userType') -eq 'Guest') { continue }
                $targetUsers.Add($u)
            }
        }

        if ($targetUsers.Count -eq 0) {
            Write-MigrationLog -Message 'No users to export. Nothing to do.' -Level WARNING
        }
        else {
            Write-MigrationLog -Message "Users to read: $($targetUsers.Count)" -Level INFO
        }

        # Course metadata is only exposed for API-registered providers; built-in
        # sources (LinkedIn Learning, Microsoft Learn...) may not be resolvable.
        # Activities whose content cannot be resolved export with blank Course*
        # columns.
        $providerNamesById = @{}
        $contentById = @{}

        if (-not $SkipCourseMetadata -and $targetUsers.Count -gt 0) {
            Write-MigrationLog -Message 'Reading learning provider catalogs for course metadata...' -Level INFO
            try {
                $providers = @(Invoke-MigrationGraphRequest -Method GET -All -Uri '/v1.0/employeeExperience/learningProviders')
                foreach ($provider in $providers) {
                    $providerId = [string](Get-MigrationProperty -InputObject $provider -Name 'id')
                    $providerName = [string](Get-MigrationProperty -InputObject $provider -Name 'displayName')
                    $providerNamesById[$providerId] = $providerName
                    try {
                        $contents = @(Invoke-MigrationGraphRequest -Method GET -All `
                                -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningContents")
                        foreach ($content in $contents) {
                            $contentById[[string](Get-MigrationProperty -InputObject $content -Name 'id')] = $content
                        }
                        Write-MigrationLog -Message "  ${providerName}: $($contents.Count) catalog item(s)" -Level INFO
                    }
                    catch {
                        Write-MigrationLog -Message "  Could not read the catalog of provider '$providerName': $($_.Exception.Message)" -Level WARNING
                    }
                }
            }
            catch {
                Write-MigrationLog -Message "  Could not list learning providers - continuing without course metadata: $($_.Exception.Message)" -Level WARNING
            }
        }

        $history = Read-LearningHistory -TargetUser $targetUsers.ToArray() -SignedInAccount ([string]$context.Account) `
            -ContentById $contentById -ProviderNamesById $providerNamesById -PreferHeader $learningPreferHeader `
            -CrossUserDenialLimit $crossUserDenialLimit
        $results.AddRange([object[]]$history.Results)

        if ($history.Rows.Count -eq 0) {
            Write-MigrationLog -Message 'No learner history found - nothing to export.' -Level WARNING
        }
        else {
            Invoke-MigrationAction -Description "Write $($history.Rows.Count) activity row(s) to $historyCsv" -Action {
                $history.Rows | Export-Csv -LiteralPath $historyCsv -NoTypeInformation -Encoding utf8
                # -InputObject keeps the JSON an array even when exactly one user has history.
                ConvertTo-Json -InputObject @($history.RawByUser) -Depth 10 | Set-Content -LiteralPath $historyJson -Encoding utf8
            }

            Write-MigrationLog -Message "Activities exported : $($history.Rows.Count) (from $($history.UsersWithActivities) user(s))" -Level SUCCESS
            if ($history.DeniedUsers -gt 0) {
                Write-MigrationLog -Message "Users denied (403)  : $($history.DeniedUsers)" -Level WARNING
            }
            if ($history.UnresolvedContent -gt 0) {
                Write-MigrationLog -Message ("Rows without course metadata: $($history.UnresolvedContent) - fill in CourseTitle and " +
                    'CourseWebUrl in the CSV before importing those rows.') -Level WARNING
            }
            if ($history.UnresolvedAssigners -gt 0) {
                Write-MigrationLog -Message ("Assigners not resolved (non-404): $($history.UnresolvedAssigners) - their rows export a blank " +
                    'AssignerUserPrincipalName; see the warnings above and the assignerUserId in the raw JSON.') -Level WARNING
            }
            Write-MigrationLog -Message "History CSV : $historyCsv" -Level SUCCESS
            Write-MigrationLog -Message "Raw JSON    : $historyJson" -Level SUCCESS
        }
    }

    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Get-VivaLearningHistory'
    if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { $exitCode = 2 }
}
catch {
    Write-MigrationLog -Message "Fatal: $($_.Exception.Message)" -Level ERROR
    $exitCode = 1
}

#endregion ---------------------------------------------------------------------

#region Cleanup ----------------------------------------------------------------

# The Graph session is deliberately left open: callers own connections, and the
# next script in the chain reuses it (or drops it itself if it needs other scopes).
exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion ---------------------------------------------------------------------
