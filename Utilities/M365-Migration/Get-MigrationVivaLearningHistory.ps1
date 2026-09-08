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
        (client credential) tokens are rejected. Microsoft's docs disagree with
        themselves about the delegated scope names (the list page says
        LearningAssignedCourse.Read.All / LearningSelfInitiatedCourse.Read.All,
        the permissions reference says only the non-.All variants exist as
        delegated scopes), so the script tries the .All set first and falls back
        to the non-.All set if sign-in is refused or the scopes are not granted.
      - Whether a delegated token can read OTHER users' activities is not
        documented. The script attempts it and, if every other-user call returns
        403, tells you so and points at the fallback (the Viva Learning admin
        "Download learner completion records" export).
      - peerRecommended assignment types are only returned when the request
        carries a 'Prefer: include-unknown-enum-members' header; without it they
        surface as unknownFutureValue.
      - Course metadata is only readable for API-registered providers. Activities
        pointing at content the API cannot resolve (typically built-in providers
        like LinkedIn Learning) export with blank Course* columns - fill in at
        least CourseTitle and CourseWebUrl in the CSV before importing those rows.

.PARAMETER OutputPath
    Root directory for the log, the export and the results CSV. Defaults to
    %LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations
    elsewhere.

.PARAMETER Prefix
    Client/run label (e.g. 'Contoso' or 'Source'). When given, files land in
    <root>\<Prefix>\ and file names start with <Prefix>_.

.PARAMETER TenantId
    Tenant ID (GUID) to sign in to. Useful for MSP / multi-tenant admins so the
    interactive sign-in lands in the intended tenant.

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
    connecting to Microsoft 365 or exporting anything.

.PARAMETER Verbosity
    Console detail: Low (errors and successes), Medium (adds warnings) or High
    (everything). The log file always receives everything.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -Prefix Source

    Interactive sign-in, exports every member user's learner history into
    <root>\Source\.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -OutputPath 'C:\Migrations' -Prefix Contoso -TenantId 00000000-0000-0000-0000-000000000000

    Signs in to a specific tenant (useful under GDAP) and files the export under
    C:\Migrations\Contoso.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -User john.smith@contoso.com -Prefix Test -Verbosity High

    Rehearses the pull against one account with full console detail before
    running it tenant-wide.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -SkipCourseMetadata -DryRun

    Shows which files would be written, without consenting to the catalog
    scopes or touching the tenant.

.NOTES
    Author       : AutomationHub
    Requires     : PowerShell 7.4, the M365Migration module beside this script,
                   Microsoft.Graph.Authentication (installed on demand)
    Graph scopes : Delegated - LearningAssignedCourse.Read.All +
                   LearningSelfInitiatedCourse.Read.All (falls back to the
                   non-.All variants), User.Read.All, and unless
                   -SkipCourseMetadata: LearningProvider.Read,
                   LearningContent.Read.All. Most of these need admin consent.
                   App-only tokens are rejected by this API.
    EXO roles    : none - this script does not use Exchange Online PowerShell
    GDAP         : supported through -TenantId (Connect-MgGraph honours an active
                   GDAP relationship); there is no -DelegatedOrganization here
                   because no Exchange connection is made. The signed-in user
                   must be licensed for Viva Learning in the target tenant -
                   without a Viva Learning/Viva Suite service plan the employee
                   learning endpoints return 403.
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

# The docs contradict themselves on the delegated scope names for listing course
# activities: the API page lists the .All variants as delegated, the permissions
# reference says only the non-.All variants exist as delegated scopes. Try the
# .All set first; if the sign-in is refused - or the scopes come back ungranted -
# fall back to the non-.All set.
$metadataScopes = if ($SkipCourseMetadata) { @() } else { @('LearningProvider.Read', 'LearningContent.Read.All') }
$requiredGraphScopes = @('LearningAssignedCourse.Read.All', 'LearningSelfInitiatedCourse.Read.All', 'User.Read.All') + $metadataScopes
$fallbackGraphScopes = @('LearningAssignedCourse.Read', 'LearningSelfInitiatedCourse.Read', 'User.Read.All') + $metadataScopes
$graphScopeSets = @($requiredGraphScopes, $fallbackGraphScopes)

# peerRecommended assignment types are only returned with this header; without it
# they surface as unknownFutureValue.
$learningPreferHeader = @{ Prefer = 'include-unknown-enum-members' }

#endregion ---------------------------------------------------------------------

#region Functions --------------------------------------------------------------

function Get-VivaGraphStatusCode {
    <#
        Best-effort HTTP status code from a failed Graph request. The SDK doesn't
        expose the response object consistently, so the Graph error body's code
        string and the exception text are both consulted. The module has an
        equivalent private helper but does not export it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)]$ErrorRecord)

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        $status = $response.Value.PSObject.Properties['StatusCode']
        if ($status -and $status.Value) { return [int]$status.Value }
    }

    # ErrorDetails is null on many SDK failures and strict mode makes a blind read
    # on it fatal, so it is checked before being dereferenced.
    $detail = ''
    if ($ErrorRecord.ErrorDetails) { $detail = [string]$ErrorRecord.ErrorDetails.Message }
    if ($detail) {
        # A non-JSON body (or none) just means we fall through to the message text.
        $code = [string]$(try { (ConvertFrom-Json $detail -ErrorAction Stop).error.code } catch { $null })
        switch -Regex ($code) {
            '^(notFound|ResourceNotFound|Request_ResourceNotFound)$' { return 404 }
            '^tooManyRequests$' { return 429 }
            '^serviceUnavailable$' { return 503 }
            '^(forbidden|accessDenied|Authorization_RequestDenied)$' { return 403 }
            '^badRequest$' { return 400 }
            '^(unauthorized|InvalidAuthenticationToken)$' { return 401 }
        }
    }

    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match 'HTTP/[\d.]+\s+(\d{3})' -or $message -match '\b([45]\d{2})\s*\(' -or
        $message -match '\b(40[0-9]|429|50[0-9])\b') {
        return [int]$Matches[1]
    }
    return 0
}

function Get-VivaProperty {
    <#
        Strict-mode-safe read of an optional property on a Graph object. Almost
        every learningCourseActivity and learningContent field is optional on the
        wire, and a missing property is a fatal error under Set-StrictMode.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Invoke-VivaLearningRequest {
    <#
        A paged, retrying GET that carries a request header. It exists only because
        Invoke-MigrationGraphRequest has no -Headers parameter and the employee
        learning API drops peerRecommended assignment types without
        'Prefer: include-unknown-enum-members'. Retry and paging follow the same
        contract as the module function so behaviour is identical everywhere else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [ValidateRange(1, 20)][int]$MaxRetry = 5
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Uri

    while (-not [string]::IsNullOrWhiteSpace($next)) {
        $attempt = 0
        $page = $null
        while ($true) {
            $attempt++
            try {
                $page = Invoke-MgGraphRequest -Method GET -Uri $next -Headers $Headers -OutputType PSObject -ErrorAction Stop
                break
            }
            catch {
                $statusCode = Get-VivaGraphStatusCode -ErrorRecord $_
                if ($statusCode -notin @(429, 503, 504) -or $attempt -ge $MaxRetry) { throw }

                # The employee learning API expresses its retry hint in MINUTES in the
                # error body rather than the usual Retry-After seconds header.
                $delay = [int][Math]::Min([Math]::Pow(2, $attempt), 60)
                $errorBody = ''
                if ($_.ErrorDetails) { $errorBody = [string]$_.ErrorDetails.Message }
                if ($errorBody -match 'Retry after (\d+) minute') { $delay = [int]$Matches[1] * 60 }

                Write-MigrationLog -Message "Graph returned $statusCode - waiting $delay second(s) before retry $attempt of $MaxRetry." -Level WARNING
                Start-Sleep -Seconds $delay
            }
        }

        if ($page -and $page.PSObject.Properties['value'] -and $null -ne $page.value) {
            $items.AddRange(@($page.value))
        }
        $next = [string](Get-VivaProperty -InputObject $page -Name '@odata.nextLink' -Default '')
    }

    return $items.ToArray()
}

function ConvertTo-FlatDateTime {
    <# Graph returns some timestamps without the trailing 'Z' - normalise to ISO 8601 UTC. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return [string]$Value
}

function Connect-VivaLearningGraph {
    <#
        Signs in with the first scope set that Entra accepts AND grants. Both
        published scope spellings are tried because Microsoft's own docs disagree
        about which of them exist as delegated scopes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$ScopeSets,
        [AllowNull()][AllowEmptyString()][string]$Tenant
    )

    foreach ($scopes in $ScopeSets) {
        try {
            $parameters = @{ Scopes = @($scopes) }
            if ($Tenant) { $parameters['TenantId'] = $Tenant }
            return Connect-MigrationGraph @parameters
        }
        catch {
            Write-MigrationLog -Message "Sign-in with scopes [$(@($scopes) -join ', ')] was refused: $($_.Exception.Message)" -Level WARNING
            Write-MigrationLog -Message 'Trying the alternate scope set...' -Level WARNING
        }
    }

    throw ('Could not sign in with either documented scope set. Check that the tenant is licensed for Viva ' +
        'Learning and that an admin can consent to the employee learning scopes.')
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

        $planned = if ($User) { @($User) } else { @('(every member user in the tenant)') }
        foreach ($identity in $planned) {
            $results.Add([pscustomobject][ordered]@{
                    Identity      = $identity
                    Action        = 'ExportLearningHistory'
                    Status        = 'Planned'
                    Detail        = "Would read learningCourseActivities and write $historyCsv."
                    ActivityCount = 0
                })
        }
    }
    else {
        #region Connect --------------------------------------------------------
        $context = Connect-VivaLearningGraph -ScopeSets $graphScopeSets -Tenant $TenantId
        $grantedLearningScopes = @(@($context.Scopes) | Where-Object { $_ -like 'Learning*' })
        Write-MigrationLog -Message "Granted learning scopes: $($grantedLearningScopes -join ', ')" -Level INFO
        #endregion -------------------------------------------------------------

        #region Resolve the user set -------------------------------------------
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
                    $statusCode = Get-VivaGraphStatusCode -ErrorRecord $_
                    $detail = if ($statusCode -eq 404) {
                        'Not found in this tenant.'
                    }
                    else {
                        "Could not be resolved (HTTP $statusCode): $($_.Exception.Message)"
                    }
                    Write-MigrationLog -Message "  [Failed] $identity - $detail" -Level ERROR
                    $results.Add([pscustomobject][ordered]@{
                            Identity      = $identity
                            Action        = 'ResolveUser'
                            Status        = 'Failed'
                            Detail        = $detail
                            ActivityCount = 0
                        })
                }
            }
        }
        else {
            Write-MigrationLog -Message 'Retrieving users (this can take a while on large tenants)...' -Level INFO
            $allUsers = @(Invoke-MigrationGraphRequest -Method GET -All `
                    -Uri '/v1.0/users?$select=id,userPrincipalName,displayName,accountEnabled,userType&$top=999')
            foreach ($u in $allUsers) {
                if (-not $IncludeGuests -and [string](Get-VivaProperty -InputObject $u -Name 'userType') -eq 'Guest') { continue }
                $targetUsers.Add($u)
            }
        }

        if ($targetUsers.Count -eq 0) {
            Write-MigrationLog -Message 'No users to export. Nothing to do.' -Level WARNING
        }
        else {
            Write-MigrationLog -Message "Users to read: $($targetUsers.Count)" -Level INFO
        }
        #endregion -------------------------------------------------------------

        #region Read provider catalogs for course metadata ---------------------
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
                    $providerId = [string](Get-VivaProperty -InputObject $provider -Name 'id')
                    $providerName = [string](Get-VivaProperty -InputObject $provider -Name 'displayName')
                    $providerNamesById[$providerId] = $providerName
                    try {
                        $contents = @(Invoke-MigrationGraphRequest -Method GET -All `
                                -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningContents")
                        foreach ($content in $contents) {
                            $contentById[[string](Get-VivaProperty -InputObject $content -Name 'id')] = $content
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
        #endregion -------------------------------------------------------------

        #region Pull activities per user ---------------------------------------
        # Every other call in this script goes through Invoke-MigrationGraphRequest;
        # only the activity listing needs the Prefer header, so only it uses the
        # local wrapper.
        $rows = [System.Collections.Generic.List[object]]::new()
        $rawByUser = [System.Collections.Generic.List[object]]::new()
        $assignerUpnById = @{}
        $usersWithActivities = 0
        $deniedUsers = 0
        $unresolvedContent = 0
        $index = 0

        foreach ($target in $targetUsers) {
            $index++
            $upn = [string](Get-VivaProperty -InputObject $target -Name 'userPrincipalName')
            $userId = [string](Get-VivaProperty -InputObject $target -Name 'id')
            $displayName = [string](Get-VivaProperty -InputObject $target -Name 'displayName')
            Write-Progress -Activity 'Exporting Viva Learning history' `
                -Status "$index of $($targetUsers.Count): $upn" `
                -PercentComplete (($index / [math]::Max($targetUsers.Count, 1)) * 100)

            # /me is the one path guaranteed to work with the delegated non-.All scopes;
            # use it when the target is the signed-in account.
            $listUri = if ($upn -and $context.Account -and $upn -ieq [string]$context.Account) {
                '/v1.0/me/employeeExperience/learningCourseActivities?$top=100'
            }
            else {
                "/v1.0/users/$userId/employeeExperience/learningCourseActivities?`$top=100"
            }

            $activities = @()
            try {
                $activities = @(Invoke-VivaLearningRequest -Uri $listUri -Headers $learningPreferHeader)
            }
            catch {
                $statusCode = Get-VivaGraphStatusCode -ErrorRecord $_
                if ($statusCode -eq 403) {
                    $deniedUsers++
                    Write-MigrationLog -Message "  [Denied] $upn - 403 reading this user's activities." -Level WARNING
                    $results.Add([pscustomobject][ordered]@{
                            Identity      = $upn
                            Action        = 'ExportLearningHistory'
                            Status        = 'Failed'
                            Detail        = "403 reading this user's learningCourseActivities - the delegated token may not read other users."
                            ActivityCount = 0
                        })
                    continue
                }
                if ($statusCode -eq 404) {
                    # The user has no employee experience surface at all.
                    $results.Add([pscustomobject][ordered]@{
                            Identity      = $upn
                            Action        = 'ExportLearningHistory'
                            Status        = 'Skipped'
                            Detail        = 'No employee experience surface for this user (404).'
                            ActivityCount = 0
                        })
                    continue
                }
                Write-MigrationLog -Message "  [Failed] $upn - $($_.Exception.Message)" -Level ERROR
                $results.Add([pscustomobject][ordered]@{
                        Identity      = $upn
                        Action        = 'ExportLearningHistory'
                        Status        = 'Failed'
                        Detail        = "HTTP $statusCode - $($_.Exception.Message)"
                        ActivityCount = 0
                    })
                continue
            }

            if ($activities.Count -eq 0) {
                $results.Add([pscustomobject][ordered]@{
                        Identity      = $upn
                        Action        = 'ExportLearningHistory'
                        Status        = 'Skipped'
                        Detail        = 'No learner history recorded for this user.'
                        ActivityCount = 0
                    })
                continue
            }

            $usersWithActivities++
            $rawByUser.Add([pscustomobject]@{
                    userId            = $userId
                    userPrincipalName = $upn
                    activities        = $activities
                })

            foreach ($activity in $activities) {
                $odataType = [string](Get-VivaProperty -InputObject $activity -Name '@odata.type')
                $activityType = if ($odataType -match 'learningAssignment') { 'Assignment' } else { 'SelfInitiated' }

                # Resolve the assigner's UPN so the destination tenant can remap it - the
                # raw GUID is meaningless outside this tenant. Deleted assigners resolve blank.
                $assignerUpn = $null
                $assignerId = [string](Get-VivaProperty -InputObject $activity -Name 'assignerUserId')
                if ($assignerId) {
                    if (-not $assignerUpnById.ContainsKey($assignerId)) {
                        try {
                            $assigner = Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/users/$assignerId`?`$select=userPrincipalName"
                            $assignerUpnById[$assignerId] = [string](Get-VivaProperty -InputObject $assigner -Name 'userPrincipalName')
                        }
                        catch {
                            $assignerUpnById[$assignerId] = $null
                        }
                    }
                    $assignerUpn = $assignerUpnById[$assignerId]
                }

                $content = $contentById[[string](Get-VivaProperty -InputObject $activity -Name 'learningContentId')]
                if (-not $content) { $unresolvedContent++ }

                # dueDateTime is a dateTimeTimeZone object and notes an itemBody object on
                # the wire (whatever the doc tables claim) - flatten both for the CSV.
                $dueDateTime = Get-VivaProperty -InputObject $activity -Name 'dueDateTime'
                $notes = Get-VivaProperty -InputObject $activity -Name 'notes'
                $providerId = [string](Get-VivaProperty -InputObject $activity -Name 'learningProviderId')

                $rows.Add([pscustomobject][ordered]@{
                        UserPrincipalName         = $upn
                        UserDisplayName           = $displayName
                        UserId                    = $userId
                        ActivityType              = $activityType
                        Status                    = [string](Get-VivaProperty -InputObject $activity -Name 'status')
                        CompletionPercentage      = Get-VivaProperty -InputObject $activity -Name 'completionPercentage'
                        CompletedDateTime         = ConvertTo-FlatDateTime -Value (Get-VivaProperty -InputObject $activity -Name 'completedDateTime')
                        StartedDateTime           = ConvertTo-FlatDateTime -Value (Get-VivaProperty -InputObject $activity -Name 'startedDateTime')
                        AssignedDateTime          = ConvertTo-FlatDateTime -Value (Get-VivaProperty -InputObject $activity -Name 'assignedDateTime')
                        AssignmentType            = [string](Get-VivaProperty -InputObject $activity -Name 'assignmentType')
                        AssignerUserId            = $assignerId
                        AssignerUserPrincipalName = $assignerUpn
                        DueDateTime               = [string](Get-VivaProperty -InputObject $dueDateTime -Name 'dateTime')
                        DueDateTimeZone           = [string](Get-VivaProperty -InputObject $dueDateTime -Name 'timeZone')
                        Notes                     = [string](Get-VivaProperty -InputObject $notes -Name 'content')
                        ActivityId                = [string](Get-VivaProperty -InputObject $activity -Name 'id')
                        ExternalCourseActivityId  = [string](Get-VivaProperty -InputObject $activity -Name 'externalCourseActivityId')
                        LearningProviderId        = $providerId
                        LearningProviderName      = $providerNamesById[$providerId]
                        LearningContentId         = [string](Get-VivaProperty -InputObject $activity -Name 'learningContentId')
                        CourseExternalId          = [string](Get-VivaProperty -InputObject $content -Name 'externalId')
                        CourseTitle               = [string](Get-VivaProperty -InputObject $content -Name 'title')
                        CourseWebUrl              = [string](Get-VivaProperty -InputObject $content -Name 'contentWebUrl')
                        CourseDescription         = [string](Get-VivaProperty -InputObject $content -Name 'description')
                        CourseLanguage            = [string](Get-VivaProperty -InputObject $content -Name 'languageTag')
                        CourseDuration            = [string](Get-VivaProperty -InputObject $content -Name 'duration')
                        CourseFormat              = [string](Get-VivaProperty -InputObject $content -Name 'format')
                        CourseLevel               = [string](Get-VivaProperty -InputObject $content -Name 'level')
                        CourseSourceName          = [string](Get-VivaProperty -InputObject $content -Name 'sourceName')
                        CourseThumbnailUrl        = [string](Get-VivaProperty -InputObject $content -Name 'thumbnailWebUrl')
                        CourseSkillTags           = (@(Get-VivaProperty -InputObject $content -Name 'skillTags' -Default @()) -join ';')
                        CourseContributors        = (@(Get-VivaProperty -InputObject $content -Name 'contributors' -Default @()) -join ';')
                    })
            }

            $results.Add([pscustomobject][ordered]@{
                    Identity      = $upn
                    Action        = 'ExportLearningHistory'
                    Status        = 'Succeeded'
                    Detail        = "Exported $($activities.Count) activity record(s)."
                    ActivityCount = $activities.Count
                })
        }

        Write-Progress -Activity 'Exporting Viva Learning history' -Completed
        #endregion -------------------------------------------------------------

        #region Write the export -----------------------------------------------
        if ($deniedUsers -gt 0 -and $usersWithActivities -eq 0 -and $targetUsers.Count -gt 1) {
            Write-MigrationLog -Message "Every cross-user read was denied (403 x $deniedUsers)." -Level ERROR
            Write-MigrationLog -Message ("Reading OTHER users' learner history with a delegated token is a documented grey area of " +
                'the employee learning API. Fallbacks: run this script as each user (-User with their own sign-in), or use the ' +
                'Viva Learning admin tab''s "Download learner completion records" bulk export.') -Level WARNING
        }

        if ($rows.Count -eq 0) {
            Write-MigrationLog -Message 'No learner history found - nothing to export.' -Level WARNING
        }
        else {
            Invoke-MigrationAction -Description "Write $($rows.Count) activity row(s) to $historyCsv" -Action {
                $rows | Export-Csv -LiteralPath $historyCsv -NoTypeInformation -Encoding utf8
                # -InputObject keeps the JSON an array even when exactly one user has history.
                ConvertTo-Json -InputObject @($rawByUser) -Depth 10 | Set-Content -LiteralPath $historyJson -Encoding utf8
            }

            Write-MigrationLog -Message "Activities exported : $($rows.Count) (from $usersWithActivities user(s))" -Level SUCCESS
            if ($deniedUsers -gt 0) {
                Write-MigrationLog -Message "Users denied (403)  : $deniedUsers" -Level WARNING
            }
            if ($unresolvedContent -gt 0) {
                Write-MigrationLog -Message ("Rows without course metadata: $unresolvedContent - fill in CourseTitle and " +
                    'CourseWebUrl in the CSV before importing those rows.') -Level WARNING
            }
            Write-MigrationLog -Message "History CSV : $historyCsv" -Level SUCCESS
            Write-MigrationLog -Message "Raw JSON    : $historyJson" -Level SUCCESS
        }
        #endregion -------------------------------------------------------------
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

if (-not $DryRun) {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
}

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion ---------------------------------------------------------------------
