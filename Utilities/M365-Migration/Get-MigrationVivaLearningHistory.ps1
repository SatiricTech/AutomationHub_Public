#Requires -Version 7.0

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

    Two files are written:
      <Prefix>_VivaLearningHistory_<timestamp>.csv   - flat, one row per activity
      <Prefix>_VivaLearningHistory_<timestamp>.json  - raw Graph objects (fidelity backup)

    API quirks this script works around (documented behaviour as of Aug 2026):
      - Listing course activities supports DELEGATED sign-in only; app-only
        (client credential) tokens are rejected. Microsoft's docs disagree with
        themselves about the delegated scope names (the list page says
        LearningAssignedCourse.Read.All / LearningSelfInitiatedCourse.Read.All,
        the permissions reference says only the non-.All variants exist as
        delegated scopes), so the script tries the .All set first and falls back
        to the non-.All set if sign-in is refused.
      - Whether a delegated token can read OTHER users' activities is not
        documented. The script attempts it and, if every other-user call returns
        403, tells you so and points at the fallback (the Viva Learning admin
        "Download learner completion records" export).
      - Course metadata is only readable for API-registered providers. Activities
        pointing at content the API cannot resolve (typically built-in providers
        like LinkedIn Learning) export with blank Course* columns - fill in at
        least CourseTitle and CourseWebUrl in the CSV before importing those rows.

.PARAMETER OutputPath
    Directory where the CSV/JSON files are written. If omitted, defaults to
    "<LocalAppData>\Migration-Automations", prints that path, and asks you to
    confirm it or supply a different directory.

.PARAMETER Prefix
    Text prepended to the output file names (e.g. 'Contoso' ->
    'Contoso_VivaLearningHistory_...'). If omitted, you are asked whether you
    want a custom prefix; if not, whether this is the Source or Destination
    tenant and that label is used instead.

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
    Preview only - resolve the prefix and output location and print the planned
    output files, then exit without connecting to Microsoft 365 or writing
    anything.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1

    Interactive sign-in, prompts for prefix + output location, exports every
    member user's learner history.

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -OutputPath 'C:\Migrations\Contoso' -Prefix Source

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -User john.smith@contoso.com -Prefix Test

.EXAMPLE
    .\Get-MigrationVivaLearningHistory.ps1 -DryRun

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, Microsoft.Graph.Authentication module
    Permissions : Delegated - LearningAssignedCourse.Read.All +
                  LearningSelfInitiatedCourse.Read.All (falls back to the
                  non-.All variants), User.Read.All, and unless
                  -SkipCourseMetadata: LearningProvider.Read,
                  LearningContent.Read.All. Most of these need admin consent.
                  The tenant (and the signed-in user) must be licensed for
                  Viva Learning - without a Viva Learning/Viva Suite service
                  plan the employee learning endpoints return 403.
    Cloud       : Global cloud only. The employee learning API is not available
                  in US Government (GCC High/DoD) or 21Vianet clouds.
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
    [string[]]$User,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeGuests,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCourseMetadata,

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
    param([string]$Path, [switch]$NoCreate)

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

    # A dry run must leave the filesystem untouched - report the would-be path only.
    if ($NoCreate) {
        return [System.IO.Path]::GetFullPath($resolved, (Get-Location).Path)
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

function Get-GraphErrorStatusCode {
    <#
        Best-effort HTTP status code from an Invoke-MgGraphRequest failure. The
        cmdlet doesn't expose the response object consistently, so the Graph
        error body's code string and the exception text are both consulted.
    #>
    param($ErrorRecord)

    $response = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) {
        $status = $response.Value.PSObject.Properties['StatusCode']
        if ($status -and $status.Value) { return [int]$status.Value }
    }

    $detail = [string]$ErrorRecord.ErrorDetails.Message
    if ($detail) {
        # A non-JSON body (or none) just means we fall through to the message text.
        $code = [string]$(try { (ConvertFrom-Json $detail -ErrorAction Stop).error.code } catch { $null })
        switch -Regex ($code) {
            '^(notFound|ResourceNotFound|Request_ResourceNotFound)$' { return 404 }
            '^tooManyRequests$'                                      { return 429 }
            '^serviceUnavailable$'                                   { return 503 }
            '^(forbidden|accessDenied|Authorization_RequestDenied)$' { return 403 }
            '^badRequest$'                                           { return 400 }
            '^(unauthorized|InvalidAuthenticationToken)$'            { return 401 }
        }
    }

    $message = [string]$ErrorRecord.Exception.Message
    if ($message -match 'HTTP/[\d.]+\s+(\d{3})' -or $message -match '\b([45]\d{2})\s*\(' -or
        $message -match '\b(40[0-9]|429|50[0-9])\b') {
        return [int]$Matches[1]
    }
    return 0
}

function Invoke-GraphWithRetry {
    <#
        Invoke-MgGraphRequest with retry on 429/503. The employee learning API
        expresses its retry hint in MINUTES ("Retry after {n} minutes"), not the
        usual Retry-After seconds header, so both forms are honoured.
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        $Body,
        [int]$MaxRetries = 5
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $params = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
            if ($Headers) { $params['Headers'] = $Headers }
            if ($null -ne $Body) {
                $params['Body'] = ($Body | ConvertTo-Json -Depth 10)
                $params['ContentType'] = 'application/json'
            }
            return Invoke-MgGraphRequest @params
        }
        catch {
            $status = Get-GraphErrorStatusCode -ErrorRecord $_
            if (($status -ne 429 -and $status -ne 503) -or $attempt -ge $MaxRetries) { throw }

            $delaySeconds = 30 * $attempt
            $detail = [string]$_.ErrorDetails.Message
            if ($detail -match 'Retry after (\d+) minute') { $delaySeconds = [int]$Matches[1] * 60 }
            Write-Host "  Throttled ($status) - waiting $delaySeconds s before retry $attempt/$MaxRetries..." -ForegroundColor Yellow
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-GraphPagedResult {
    <# Follows @odata.nextLink until the collection is exhausted. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next) {
        $page = Invoke-GraphWithRetry -Method GET -Uri $next -Headers $Headers
        if ($page.value) { $all.AddRange(@($page.value)) }
        $next = $page.'@odata.nextLink'
    }
    return $all
}

function ConvertTo-FlatDateTime {
    <# Graph returns some timestamps without the trailing 'Z' - normalise to ISO 8601 UTC. #>
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return [string]$Value
}

#endregion ---------------------------------------------------------------------

Write-Host '=== M365 Migration - Viva Learning Learner History Export ===' -ForegroundColor Cyan

$filePrefix = Resolve-FilePrefix -Value $Prefix
$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath -NoCreate:$DryRun
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$historyCsv = Join-Path -Path $outputDir -ChildPath "${filePrefix}_VivaLearningHistory_$timestamp.csv"
$historyJson = Join-Path -Path $outputDir -ChildPath "${filePrefix}_VivaLearningHistory_$timestamp.json"

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN - nothing will be queried or written.' -ForegroundColor Magenta
    Write-Host 'Planned output files:' -ForegroundColor Cyan
    Write-Host "  $historyCsv"
    Write-Host "  $historyJson"
    Write-Host 'Re-run without -DryRun to export.' -ForegroundColor Cyan
    return
}

Initialize-RequiredModule -Name 'Microsoft.Graph.Authentication'
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

#region Connect ----------------------------------------------------------------

# The docs contradict themselves on the delegated scope names for listing course
# activities: the API page lists the .All variants as delegated, the permissions
# reference says only the non-.All variants exist as delegated scopes. Try the
# .All set first; if Entra refuses the sign-in (invalid scope), fall back.
$metadataScopes = if ($SkipCourseMetadata) { @() } else { @('LearningProvider.Read', 'LearningContent.Read.All') }
$scopeSets = @(
    @('LearningAssignedCourse.Read.All', 'LearningSelfInitiatedCourse.Read.All', 'User.Read.All') + $metadataScopes,
    @('LearningAssignedCourse.Read', 'LearningSelfInitiatedCourse.Read', 'User.Read.All') + $metadataScopes
)

# A cached session from an earlier run may lack the learning scopes and would be
# reused without re-prompting. Drop it so consent is requested afresh.
$existingContext = Get-MgContext
if ($existingContext -and -not (@($existingContext.Scopes) -match '^LearningAssignedCourse')) {
    Write-Host 'Existing Graph session is missing the employee learning scopes - reconnecting...' -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
$connected = $false
foreach ($scopes in $scopeSets) {
    try {
        $connectParams = @{ Scopes = $scopes; NoWelcome = $true }
        if ($TenantId) { $connectParams['TenantId'] = $TenantId }
        Connect-MgGraph @connectParams
        $connected = $true
        break
    }
    catch {
        Write-Host "  Sign-in with scopes [$($scopes -join ', ')] was refused: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '  Trying the alternate scope set...' -ForegroundColor Yellow
    }
}
if (-not $connected) {
    throw 'Could not sign in with either documented scope set. Check that the tenant is licensed for Viva Learning and that an admin can consent to the employee learning scopes.'
}

$context = Get-MgContext
Write-Host "Connected to tenant $($context.TenantId) as $($context.Account)" -ForegroundColor Green
Write-Host "Granted scopes: $((@($context.Scopes) | Where-Object { $_ -like 'Learning*' }) -join ', ')" -ForegroundColor Cyan

#endregion ---------------------------------------------------------------------

#region Resolve the user set ---------------------------------------------------

$targetUsers = [System.Collections.Generic.List[object]]::new()
$unresolvedUsers = 0

if ($User) {
    Write-Host "Resolving $($User.Count) requested user(s)..." -ForegroundColor Cyan
    foreach ($identity in $User) {
        try {
            $escaped = [uri]::EscapeDataString($identity)
            $resolved = Invoke-GraphWithRetry -Method GET -Uri "/v1.0/users/$escaped`?`$select=id,userPrincipalName,displayName,accountEnabled,userType"
            $targetUsers.Add($resolved)
        }
        catch {
            # Only a genuine 404 means the account doesn't exist - anything else
            # (403 consent gap, exhausted throttle, network) must not masquerade
            # as "not found" or the operator chases the wrong problem.
            $unresolvedUsers++
            if ((Get-GraphErrorStatusCode -ErrorRecord $_) -eq 404) {
                Write-Host "  [Not found] $identity" -ForegroundColor Red
            }
            else {
                Write-Host "  [Failed] $identity - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}
else {
    Write-Host 'Retrieving users (this can take a while on large tenants)...' -ForegroundColor Cyan
    $allUsers = Get-GraphPagedResult -Uri '/v1.0/users?$select=id,userPrincipalName,displayName,accountEnabled,userType&$top=999'
    foreach ($u in $allUsers) {
        if (-not $IncludeGuests -and [string]$u.userType -eq 'Guest') { continue }
        $targetUsers.Add($u)
    }
}

if ($targetUsers.Count -eq 0) {
    Write-Host 'No users to export. Nothing to do.' -ForegroundColor Yellow
    Disconnect-MgGraph | Out-Null
    return
}
Write-Host "Users to read: $($targetUsers.Count)" -ForegroundColor Cyan

#endregion ---------------------------------------------------------------------

#region Read provider catalogs for course metadata -----------------------------

# Course metadata is only exposed for API-registered providers; built-in sources
# (LinkedIn Learning, Microsoft Learn...) may not be resolvable. Activities whose
# content cannot be resolved export with blank Course* columns.
$providerNamesById = @{}
$contentById = @{}

if (-not $SkipCourseMetadata) {
    Write-Host 'Reading learning provider catalogs for course metadata...' -ForegroundColor Cyan
    try {
        $providers = Get-GraphPagedResult -Uri '/v1.0/employeeExperience/learningProviders'
        foreach ($provider in $providers) {
            $providerNamesById[[string]$provider.id] = [string]$provider.displayName
            try {
                $contents = Get-GraphPagedResult -Uri "/v1.0/employeeExperience/learningProviders/$($provider.id)/learningContents"
                foreach ($content in $contents) {
                    $contentById[[string]$content.id] = $content
                }
                Write-Host "  $($provider.displayName): $($contents.Count) catalog item(s)" -ForegroundColor Cyan
            }
            catch {
                Write-Host "  Could not read the catalog of provider '$($provider.displayName)': $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Host "  Could not list learning providers - continuing without course metadata: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

#endregion ---------------------------------------------------------------------

#region Pull activities per user -----------------------------------------------

# peerRecommended assignment types are only returned with this header; without it
# they surface as unknownFutureValue.
$listHeaders = @{ Prefer = 'include-unknown-enum-members' }

$rows = [System.Collections.Generic.List[object]]::new()
$rawByUser = [System.Collections.Generic.List[object]]::new()
$assignerUpnById = @{}
$usersWithActivities = 0
$deniedUsers = 0
$unresolvedContent = 0
$index = 0

foreach ($target in $targetUsers) {
    $index++
    $upn = [string]$target.userPrincipalName
    Write-Progress -Activity 'Exporting Viva Learning history' `
        -Status "$index of $($targetUsers.Count): $upn" `
        -PercentComplete (($index / [math]::Max($targetUsers.Count, 1)) * 100)

    # /me is the one path guaranteed to work with the delegated non-.All scopes;
    # use it when the target is the signed-in account.
    $listUri = if ($upn -and $context.Account -and $upn -ieq [string]$context.Account) {
        '/v1.0/me/employeeExperience/learningCourseActivities?$top=100'
    }
    else {
        "/v1.0/users/$($target.id)/employeeExperience/learningCourseActivities?`$top=100"
    }

    $activities = @()
    try {
        $activities = @(Get-GraphPagedResult -Uri $listUri -Headers $listHeaders)
    }
    catch {
        $status = Get-GraphErrorStatusCode -ErrorRecord $_
        if ($status -eq 403) {
            $deniedUsers++
            Write-Host "  [Denied] $upn - 403 reading this user's activities." -ForegroundColor Yellow
            continue
        }
        if ($status -eq 404) { continue }   # user has no employee experience surface
        Write-Host "  [Failed] $upn - $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    if ($activities.Count -eq 0) { continue }
    $usersWithActivities++
    $rawByUser.Add([pscustomobject]@{
            userId            = $target.id
            userPrincipalName = $upn
            activities        = $activities
        })

    foreach ($activity in $activities) {
        $odataType = [string]$activity.'@odata.type'
        $activityType = if ($odataType -match 'learningAssignment') { 'Assignment' } else { 'SelfInitiated' }

        # Resolve the assigner's UPN so the destination tenant can remap it - the
        # raw GUID is meaningless outside this tenant. Deleted assigners resolve blank.
        $assignerUpn = $null
        $assignerId = [string]$activity.assignerUserId
        if ($assignerId) {
            if (-not $assignerUpnById.ContainsKey($assignerId)) {
                try {
                    $assigner = Invoke-GraphWithRetry -Method GET -Uri "/v1.0/users/$assignerId`?`$select=userPrincipalName"
                    $assignerUpnById[$assignerId] = [string]$assigner.userPrincipalName
                }
                catch {
                    $assignerUpnById[$assignerId] = $null
                }
            }
            $assignerUpn = $assignerUpnById[$assignerId]
        }

        $content = $contentById[[string]$activity.learningContentId]
        if (-not $content) { $unresolvedContent++ }

        # dueDateTime is a dateTimeTimeZone object and notes an itemBody object on
        # the wire (whatever the doc tables claim) - flatten both for the CSV.
        $rows.Add([pscustomobject][ordered]@{
                UserPrincipalName        = $upn
                UserDisplayName          = [string]$target.displayName
                UserId                   = [string]$target.id
                ActivityType             = $activityType
                Status                   = [string]$activity.status
                CompletionPercentage     = $activity.completionPercentage
                CompletedDateTime        = ConvertTo-FlatDateTime -Value $activity.completedDateTime
                StartedDateTime          = ConvertTo-FlatDateTime -Value $activity.startedDateTime
                AssignedDateTime         = ConvertTo-FlatDateTime -Value $activity.assignedDateTime
                AssignmentType           = [string]$activity.assignmentType
                AssignerUserId           = $assignerId
                AssignerUserPrincipalName = $assignerUpn
                DueDateTime              = [string]$activity.dueDateTime.dateTime
                DueDateTimeZone          = [string]$activity.dueDateTime.timeZone
                Notes                    = [string]$activity.notes.content
                ActivityId               = [string]$activity.id
                ExternalCourseActivityId = [string]$activity.externalCourseActivityId
                LearningProviderId       = [string]$activity.learningProviderId
                LearningProviderName     = $providerNamesById[[string]$activity.learningProviderId]
                LearningContentId        = [string]$activity.learningContentId
                CourseExternalId         = [string]$content.externalId
                CourseTitle              = [string]$content.title
                CourseWebUrl             = [string]$content.contentWebUrl
                CourseDescription        = [string]$content.description
                CourseLanguage           = [string]$content.languageTag
                CourseDuration           = [string]$content.duration
                CourseFormat             = [string]$content.format
                CourseLevel              = [string]$content.level
                CourseSourceName         = [string]$content.sourceName
                CourseThumbnailUrl       = [string]$content.thumbnailWebUrl
                CourseSkillTags          = (@($content.skillTags) -join ';')
                CourseContributors       = (@($content.contributors) -join ';')
            })
    }
}

Write-Progress -Activity 'Exporting Viva Learning history' -Completed

#endregion ---------------------------------------------------------------------

#region Write the export -------------------------------------------------------

Write-Host ''
if ($deniedUsers -gt 0 -and $usersWithActivities -eq 0 -and $targetUsers.Count -gt 1) {
    Write-Host "Every cross-user read was denied (403 x $deniedUsers)." -ForegroundColor Red
    Write-Host 'Reading OTHER users'' learner history with a delegated token is a documented grey area of the' -ForegroundColor Yellow
    Write-Host 'employee learning API. Fallbacks: run this script as each user (-User with their own sign-in),' -ForegroundColor Yellow
    Write-Host 'or use the Viva Learning admin tab''s "Download learner completion records" bulk export.' -ForegroundColor Yellow
}

if ($rows.Count -eq 0) {
    Write-Host 'No learner history found - nothing to export.' -ForegroundColor Yellow
}
else {
    $rows | Export-Csv -Path $historyCsv -NoTypeInformation -Encoding UTF8
    # -InputObject keeps the JSON an array even when exactly one user has history.
    ConvertTo-Json -InputObject @($rawByUser) -Depth 10 | Set-Content -Path $historyJson -Encoding UTF8

    Write-Host "Activities exported : $($rows.Count) (from $usersWithActivities user(s))" -ForegroundColor Green
    if ($deniedUsers -gt 0) {
        Write-Host "Users denied (403)  : $deniedUsers" -ForegroundColor Yellow
    }
    if ($unresolvedUsers -gt 0) {
        Write-Host "Users not resolved  : $unresolvedUsers (see the [Not found]/[Failed] lines above)" -ForegroundColor Yellow
    }
    if ($unresolvedContent -gt 0) {
        Write-Host "Rows without course metadata: $unresolvedContent - fill in CourseTitle and CourseWebUrl in the CSV before importing those rows." -ForegroundColor Yellow
    }
    Write-Host "History CSV : $historyCsv" -ForegroundColor Green
    Write-Host "Raw JSON    : $historyJson" -ForegroundColor Green
}

#endregion ---------------------------------------------------------------------

Disconnect-MgGraph | Out-Null
Write-Host 'Done.' -ForegroundColor Green
