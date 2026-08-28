#Requires -Version 7.0

<#
.SYNOPSIS
    Imports Viva Learning learner history (course assignments and self-initiated
    courses) into a destination tenant from the CSV produced by
    Get-MigrationVivaLearningHistory.ps1.

.DESCRIPTION
    Replays exported learner history into a destination tenant through the Graph
    employee learning API, in three steps:

      1. Provider  - registers (or reuses) a custom learning provider that the
                     imported records will live under, with course-activity sync
                     enabled. Records can only be attached to content owned by
                     your own provider registration - they cannot be written into
                     built-in providers such as LinkedIn Learning.
      2. Content   - upserts one learning catalog item per distinct course in
                     the CSV (keyed by CourseExternalId / LearningContentId /
                     CourseWebUrl, in that order of preference).
      3. Activities - creates one learningCourseActivity per CSV row against the
                     matching catalog item and target user. Re-runs are safe:
                     rows whose activity already exists (matched by external
                     activity ID) are skipped, not duplicated. That idempotency
                     holds only while the key columns are unchanged between runs
                     (CourseExternalId / LearningContentId / CourseWebUrl,
                     ExternalCourseActivityId / ActivityId,
                     TargetUserPrincipalName) - editing them re-keys the rows
                     and a re-run creates new records instead of skipping.

    The employee learning API forces a split authentication model, so the script
    uses TWO sign-ins in sequence:

      - Provider registration is DELEGATED-ONLY: an interactive sign-in by a user
        holding a Viva Learning (or Viva Suite) license and the Knowledge
        Administrator role (least privileged). Skip this sign-in entirely by
        passing -LearningProviderId for an already-registered provider.
      - Content upsert and activity creation are APPLICATION-ONLY: an app
        registration with client-credential auth (secret or certificate) and
        admin-consented application permissions (see .NOTES).

    Source users are mapped to destination users by UPN: a
    TargetUserPrincipalName CSV column wins when present; otherwise the UPN's
    local part is combined with -TargetDomain (you are prompted if it is
    omitted); -KeepCsvDomains uses the CSV UPNs unchanged.

    Every row's outcome lands in a results CSV. Note that each target learner
    needs a Viva Learning premium license - rows for unlicensed users fail with
    a licensing 403 and are recorded as such. Imported records surface on the
    users' My Learning tab; catalog content can take up to 24 hours to appear
    in Viva Learning search/browse.

.PARAMETER CsvPath
    Path to the learner history CSV. Expected columns match the export script's
    output; the minimum per row is UserPrincipalName, ActivityType, Status,
    CourseTitle and CourseWebUrl (plus a content key when CourseWebUrl is empty).

.PARAMETER TenantId
    Destination tenant ID (GUID). Required - client-credential sign-in cannot
    discover the tenant on its own.

.PARAMETER ClientId
    Application (client) ID of the app registration used for the app-only phase.

.PARAMETER ClientSecret
    Client secret of the app registration, as a SecureString. Provide either
    this or -CertificateThumbprint.

.PARAMETER CertificateThumbprint
    Thumbprint of a certificate uploaded to the app registration, present in the
    local certificate store. Provide either this or -ClientSecret.

.PARAMETER LearningProviderId
    Registration ID of an existing learning provider to import under. When
    supplied the interactive/delegated provider step is skipped entirely; add
    -Confirm:$false and the whole run is unattended (without it each change
    still raises a confirmation prompt, which a non-interactive host turns
    into an error). The provider must have course-activity sync enabled.

.PARAMETER ProviderDisplayName
    Display name of the provider to reuse or create when -LearningProviderId is
    not supplied. Default: 'Imported Learning History'.

.PARAMETER LogoUrl
    Publicly reachable image URL used for every provider logo slot that isn't
    given its own parameter. Viva Learning copies the image to its own storage.
    Required (or prompted) only when the provider doesn't exist yet.

.PARAMETER SquareLogoUrl
    Square logo for light theme. Falls back to -LogoUrl.

.PARAMETER SquareLogoDarkUrl
    Square logo for dark theme. Falls back to -LogoUrl.

.PARAMETER LongLogoUrl
    Long logo for light theme. Falls back to -LogoUrl.

.PARAMETER LongLogoDarkUrl
    Long logo for dark theme. Falls back to -LogoUrl.

.PARAMETER TargetDomain
    UPN domain of the destination tenant (e.g. newco.com). Each source UPN's
    local part is mapped to this domain unless the row has a
    TargetUserPrincipalName. If omitted (and -KeepCsvDomains isn't set) you are
    prompted once.

.PARAMETER KeepCsvDomains
    Use the CSV UPNs unchanged instead of mapping to -TargetDomain.

.PARAMETER DefaultLanguageTag
    Language tag applied to catalog items whose CourseLanguage column is empty.
    Default: 'en-us'.

.PARAMETER OutputPath
    Directory where the results CSV is written. Defaults to the current
    directory.

.PARAMETER DryRun
    Preview - signs in and resolves everything read-only (provider match, user
    mapping, per-row plan) but creates and changes nothing.

.EXAMPLE
    .\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\Source_VivaLearningHistory.csv -TenantId 00000000-0000-0000-0000-000000000000 -ClientId 11111111-1111-1111-1111-111111111111 -ClientSecret (Read-Host -AsSecureString 'Secret') -TargetDomain newco.com -DryRun

.EXAMPLE
    .\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\Source_VivaLearningHistory.csv -TenantId 00000000-0000-0000-0000-000000000000 -ClientId 11111111-1111-1111-1111-111111111111 -CertificateThumbprint ABCDEF0123456789ABCDEF0123456789ABCDEF01 -TargetDomain newco.com -LogoUrl https://www.example.com/logo.png

.EXAMPLE
    .\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\History.csv -TenantId 00000000-0000-0000-0000-000000000000 -ClientId 11111111-1111-1111-1111-111111111111 -ClientSecret $secret -LearningProviderId 22222222-2222-2222-2222-222222222222 -KeepCsvDomains -Confirm:$false
    # Fully unattended: existing provider registration + no confirmation prompts

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7, Microsoft.Graph.Authentication module
    Permissions : Delegated (interactive, only when registering/reusing a
                  provider by name): LearningProvider.ReadWrite - the signed-in
                  user needs a Viva Learning or Viva Suite license and the
                  Knowledge Administrator role (least privileged).
                  Application (app registration, admin-consented):
                  LearningContent.ReadWrite.All,
                  LearningAssignedCourse.ReadWrite.All,
                  LearningSelfInitiatedCourse.ReadWrite.All, User.Read.All.
                  Each target learner must hold a Viva Learning premium license
                  or their rows fail with a licensing 403.
    Cloud       : Global cloud only. The employee learning API is not available
                  in US Government (GCC High/DoD) or 21Vianet clouds.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [securestring]$ClientSecret,

    [Parameter(Mandatory = $false)]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory = $false)]
    [string]$LearningProviderId,

    [Parameter(Mandatory = $false)]
    [string]$ProviderDisplayName = 'Imported Learning History',

    [Parameter(Mandatory = $false)]
    [string]$LogoUrl,

    [Parameter(Mandatory = $false)]
    [string]$SquareLogoUrl,

    [Parameter(Mandatory = $false)]
    [string]$SquareLogoDarkUrl,

    [Parameter(Mandatory = $false)]
    [string]$LongLogoUrl,

    [Parameter(Mandatory = $false)]
    [string]$LongLogoDarkUrl,

    [Parameter(Mandatory = $false)]
    [string]$TargetDomain,

    [Parameter(Mandatory = $false)]
    [switch]$KeepCsvDomains,

    [Parameter(Mandatory = $false)]
    [string]$DefaultLanguageTag = 'en-us',

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $ClientSecret -and -not $CertificateThumbprint) {
    throw 'Provide either -ClientSecret or -CertificateThumbprint for the app-only phase (content + activities are application-permission-only).'
}

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
        Write-Host 'No -OutputPath provided - writing results to the current directory:' -ForegroundColor Cyan
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

function ConvertTo-GraphKeyLiteral {
    <# Escapes a value for use inside an OData key literal: (...='{value}'). #>
    param([Parameter(Mandatory)][string]$Value)
    return [uri]::EscapeDataString($Value.Replace("'", "''"))
}

function ConvertTo-TargetUpn {
    <# Maps a source UPN to the destination tenant per the chosen scheme. #>
    param(
        [Parameter(Mandatory)][string]$SourceUpn,
        [string]$OverrideUpn,
        [string]$Domain,
        [bool]$KeepDomains
    )
    if ($OverrideUpn) { return $OverrideUpn }
    if ($KeepDomains -or -not $Domain) { return $SourceUpn }
    $localPart = ($SourceUpn -split '@')[0]
    return "$localPart@$Domain"
}

function Get-NormalizedStatus {
    <# Normalises a CSV status value to the courseStatus enum casing. #>
    param([string]$Value)
    switch -Regex ($Value) {
        '^\s*not\s*started\s*$' { return 'notStarted' }
        '^\s*in\s*progress\s*$' { return 'inProgress' }
        '^\s*completed?\s*$'    { return 'completed' }
        default                 { return $null }
    }
}

#endregion ---------------------------------------------------------------------

Write-Host '=== M365 Migration - Viva Learning Learner History Import ===' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$outputDir = Resolve-MigrationOutputDirectory -Path $OutputPath
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultsCsv = Join-Path -Path $outputDir -ChildPath "VivaLearningHistory-ImportResults_$timestamp.csv"

Initialize-RequiredModule -Name 'Microsoft.Graph.Authentication'
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

#region Load and validate the CSV ----------------------------------------------

$csvRows = @(Import-Csv -LiteralPath $CsvPath)
if ($csvRows.Count -eq 0) { throw "CSV '$CsvPath' contains no rows." }

$headers = $csvRows[0].PSObject.Properties.Name
$columns = @{
    Upn            = Resolve-ColumnName -Headers $headers -Candidates @('UserPrincipalName', 'UPN', 'User Principal Name', 'Email', 'PrimaryEmail', 'Mail')
    TargetUpn      = Resolve-ColumnName -Headers $headers -Candidates @('TargetUserPrincipalName', 'TargetUPN', 'TargetEmail')
    ActivityType   = Resolve-ColumnName -Headers $headers -Candidates @('ActivityType', 'Type', 'RecordType', 'Record Type')
    Status         = Resolve-ColumnName -Headers $headers -Candidates @('Status', 'CompletionStatus', 'Completion Status')
    Percentage     = Resolve-ColumnName -Headers $headers -Candidates @('CompletionPercentage', 'PercentComplete')
    Completed      = Resolve-ColumnName -Headers $headers -Candidates @('CompletedDateTime', 'CompletedDate', 'CompletionDate')
    Started        = Resolve-ColumnName -Headers $headers -Candidates @('StartedDateTime', 'StartedDate')
    Assigned       = Resolve-ColumnName -Headers $headers -Candidates @('AssignedDateTime', 'AssignedDate')
    AssignmentType = Resolve-ColumnName -Headers $headers -Candidates @('AssignmentType')
    AssignerUpn    = Resolve-ColumnName -Headers $headers -Candidates @('AssignerUserPrincipalName', 'AssignerUpn')
    Due            = Resolve-ColumnName -Headers $headers -Candidates @('DueDateTime', 'DueDate')
    DueZone        = Resolve-ColumnName -Headers $headers -Candidates @('DueDateTimeZone')
    Notes          = Resolve-ColumnName -Headers $headers -Candidates @('Notes')
    ActivityId     = Resolve-ColumnName -Headers $headers -Candidates @('ActivityId')
    ExternalActId  = Resolve-ColumnName -Headers $headers -Candidates @('ExternalCourseActivityId', 'External ID')
    ContentId      = Resolve-ColumnName -Headers $headers -Candidates @('LearningContentId')
    ContentExtId   = Resolve-ColumnName -Headers $headers -Candidates @('CourseExternalId')
    Title          = Resolve-ColumnName -Headers $headers -Candidates @('CourseTitle', 'Title', 'ContentTitle')
    WebUrl         = Resolve-ColumnName -Headers $headers -Candidates @('CourseWebUrl', 'ContentWebUrl', 'CourseUrl')
    Description    = Resolve-ColumnName -Headers $headers -Candidates @('CourseDescription', 'Description')
    Language       = Resolve-ColumnName -Headers $headers -Candidates @('CourseLanguage', 'LanguageTag')
    Duration       = Resolve-ColumnName -Headers $headers -Candidates @('CourseDuration', 'Duration')
    Format         = Resolve-ColumnName -Headers $headers -Candidates @('CourseFormat', 'Format')
    SourceName     = Resolve-ColumnName -Headers $headers -Candidates @('CourseSourceName', 'SourceName', 'LearningProviderName')
    Level          = Resolve-ColumnName -Headers $headers -Candidates @('CourseLevel', 'Level')
    Thumbnail      = Resolve-ColumnName -Headers $headers -Candidates @('CourseThumbnailUrl', 'ThumbnailWebUrl')
    SkillTags      = Resolve-ColumnName -Headers $headers -Candidates @('CourseSkillTags', 'SkillTags')
    Contributors   = Resolve-ColumnName -Headers $headers -Candidates @('CourseContributors', 'Contributors')
}

if (-not $columns.Upn) {
    throw "Could not find a UserPrincipalName/UPN column in '$CsvPath'. Headers: $($headers -join ', ')"
}
if (-not $columns.Title -or -not $columns.WebUrl) {
    throw "Could not find the CourseTitle and CourseWebUrl columns in '$CsvPath' - both are required to create catalog content. Headers: $($headers -join ', ')"
}

Write-Host "CSV rows: $($csvRows.Count)" -ForegroundColor Cyan

# Ask for the mapping domain once when neither -TargetDomain nor -KeepCsvDomains
# was chosen, so hand-off runs don't silently import source-domain UPNs. A
# TargetUserPrincipalName column doesn't suppress the prompt - it may only
# cover some rows, and blank cells fall back to this mapping.
if (-not $TargetDomain -and -not $KeepCsvDomains) {
    Write-Host ''
    $answer = ((Read-Host 'Destination UPN domain to map users to (blank = keep the CSV domains)') ?? '').Trim()
    if ($answer) { $TargetDomain = $answer.TrimStart('@') }
    else { $KeepCsvDomains = $true }
}

#endregion ---------------------------------------------------------------------

#region Step 1 - resolve or register the learning provider ---------------------

$providerId = $LearningProviderId

if ($providerId) {
    Write-Host "Using supplied learning provider registration: $providerId" -ForegroundColor Cyan
}
else {
    # Provider management is delegated-only in the employee learning API, so this
    # step needs its own interactive sign-in before the app-only phase.
    Write-Host ''
    Write-Host 'Connecting to Microsoft Graph interactively for the provider step...' -ForegroundColor Cyan
    Write-Host '(sign in as a Viva-licensed Knowledge Administrator)' -ForegroundColor Cyan
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Connect-MgGraph -Scopes 'LearningProvider.ReadWrite' -TenantId $TenantId -NoWelcome

    $providers = @(Get-GraphPagedResult -Uri '/v1.0/employeeExperience/learningProviders')
    $existing = $providers | Where-Object { [string]$_.displayName -ieq $ProviderDisplayName } | Select-Object -First 1

    if ($existing) {
        $providerId = [string]$existing.id
        Write-Host "Reusing existing provider '$($existing.displayName)' [$providerId]" -ForegroundColor Green

        if (-not $existing.isCourseActivitySyncEnabled) {
            # Course activity writes are rejected while sync is disabled on the provider.
            if (-not $DryRun -and $PSCmdlet.ShouldProcess($ProviderDisplayName, 'Enable course-activity sync on the learning provider')) {
                Invoke-GraphWithRetry -Method PATCH -Uri "/v1.0/employeeExperience/learningProviders/$providerId" `
                    -Body @{ isCourseActivitySyncEnabled = $true } | Out-Null
                Write-Host 'Enabled course-activity sync on the provider.' -ForegroundColor Green
            }
            else {
                $label = $DryRun ? '[DRYRUN]' : '[SKIPPED]'
                Write-Host "$label Would enable course-activity sync on the provider." -ForegroundColor Magenta
            }
        }
    }
    else {
        $square = $SquareLogoUrl ?? $LogoUrl
        $squareDark = $SquareLogoDarkUrl ?? $LogoUrl
        $long = $LongLogoUrl ?? $LogoUrl
        $longDark = $LongLogoDarkUrl ?? $LogoUrl

        if (-not ($square -and $squareDark -and $long -and $longDark)) {
            Write-Host ''
            Write-Host "Provider '$ProviderDisplayName' does not exist yet and registering one requires logo image URLs" -ForegroundColor Yellow
            Write-Host '(publicly reachable - Viva Learning copies the image to its own storage).' -ForegroundColor Yellow
            $answer = ((Read-Host 'Image URL to use for all logo slots (e.g. your company logo PNG)') ?? '').Trim()
            if (-not $answer) { throw 'A logo URL is required to register a learning provider.' }
            if (-not $square) { $square = $answer }
            if (-not $squareDark) { $squareDark = $answer }
            if (-not $long) { $long = $answer }
            if (-not $longDark) { $longDark = $answer }
        }

        if (-not $DryRun -and $PSCmdlet.ShouldProcess($ProviderDisplayName, 'Register a new Viva Learning provider')) {
            $created = Invoke-GraphWithRetry -Method POST -Uri '/v1.0/employeeExperience/learningProviders' -Body @{
                displayName                   = $ProviderDisplayName
                squareLogoWebUrlForLightTheme = $square
                squareLogoWebUrlForDarkTheme  = $squareDark
                longLogoWebUrlForLightTheme   = $long
                longLogoWebUrlForDarkTheme    = $longDark
                isCourseActivitySyncEnabled   = $true
            }
            $providerId = [string]$created.id
            Write-Host "Registered provider '$ProviderDisplayName' [$providerId]" -ForegroundColor Green
        }
        else {
            $label = $DryRun ? '[DRYRUN]' : '[SKIPPED]'
            Write-Host "$label Would register provider '$ProviderDisplayName' with course-activity sync enabled." -ForegroundColor Magenta
            $providerId = '(new-provider-id)'
        }
    }

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

#endregion ---------------------------------------------------------------------

#region Connect app-only for content + activities ------------------------------

Write-Host ''
Write-Host 'Connecting to Microsoft Graph with application credentials...' -ForegroundColor Cyan
if ($CertificateThumbprint) {
    Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome
}
else {
    $appCredential = [pscredential]::new($ClientId, $ClientSecret)
    Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $appCredential -NoWelcome
}
Write-Host "Connected app-only to tenant $((Get-MgContext).TenantId)" -ForegroundColor Green

# The API only accepts activity writes for real, licensed provider registrations;
# a DryRun with a placeholder provider id skips every call that would need it.
$providerIsReal = $providerId -and $providerId -ne '(new-provider-id)'

#endregion ---------------------------------------------------------------------

#region Step 2 - build and upsert the course catalog ---------------------------

# One catalog item per distinct course. Preference order for the upsert key:
# the source catalog's own external ID, then the source content GUID, then the
# course URL as a last resort (hand-built CSVs may only have URLs).
$catalog = [ordered]@{}
foreach ($row in $csvRows) {
    $key = (Get-CsvValue -Record $row -Column $columns.ContentExtId) ??
           (Get-CsvValue -Record $row -Column $columns.ContentId) ??
           (Get-CsvValue -Record $row -Column $columns.WebUrl)
    if (-not $key -or $catalog.Contains($key)) { continue }

    $catalog[$key] = [pscustomobject]@{
        Key         = $key
        Title       = Get-CsvValue -Record $row -Column $columns.Title
        WebUrl      = Get-CsvValue -Record $row -Column $columns.WebUrl
        Description = Get-CsvValue -Record $row -Column $columns.Description
        Language    = (Get-CsvValue -Record $row -Column $columns.Language) ?? $DefaultLanguageTag
        Duration    = Get-CsvValue -Record $row -Column $columns.Duration
        Format      = Get-CsvValue -Record $row -Column $columns.Format
        Level       = Get-CsvValue -Record $row -Column $columns.Level
        SourceName  = Get-CsvValue -Record $row -Column $columns.SourceName
        Thumbnail   = Get-CsvValue -Record $row -Column $columns.Thumbnail
        SkillTags   = @((Get-CsvValue -Record $row -Column $columns.SkillTags) -split ';' | Where-Object { $_ })
        Contributors = @((Get-CsvValue -Record $row -Column $columns.Contributors) -split ';' | Where-Object { $_ })
    }
}

Write-Host ''
Write-Host "Distinct courses in the CSV: $($catalog.Count)" -ForegroundColor Cyan

$contentIdByKey = @{}
$contentFailures = @{}
$contentSkipped = @{}   # operator/WhatIf declines - dependent rows report WhatIf, not Failed
$contentIndex = 0

foreach ($course in $catalog.Values) {
    $contentIndex++
    Write-Progress -Activity 'Upserting learning content' `
        -Status "$contentIndex of $($catalog.Count): $($course.Title ?? $course.Key)" `
        -PercentComplete (($contentIndex / [math]::Max($catalog.Count, 1)) * 100)

    if (-not $course.Title -or -not $course.WebUrl) {
        $contentFailures[$course.Key] = 'Missing CourseTitle or CourseWebUrl - fill these in the CSV (metadata could not be exported for built-in providers).'
        continue
    }

    $body = @{
        externalId    = $course.Key
        title         = $course.Title
        contentWebUrl = $course.WebUrl
        languageTag   = $course.Language
        isActive      = $true
        isSearchable  = $true
    }
    if ($course.Description) { $body['description'] = $course.Description }
    if ($course.Duration) { $body['duration'] = $course.Duration }
    if ($course.Format) { $body['format'] = $course.Format }
    if ($course.Level) { $body['level'] = $course.Level }
    if ($course.SourceName) { $body['sourceName'] = $course.SourceName }
    if ($course.Thumbnail) { $body['thumbnailWebUrl'] = $course.Thumbnail }
    if ($course.SkillTags.Count -gt 0) { $body['skillTags'] = $course.SkillTags }
    if ($course.Contributors.Count -gt 0) { $body['contributors'] = $course.Contributors }

    if ($DryRun -or -not $providerIsReal) {
        Write-Host "  [DRYRUN] Would upsert catalog item: $($course.Title)" -ForegroundColor Magenta
        $contentIdByKey[$course.Key] = '(content-id)'
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($course.Title, 'Upsert Viva Learning catalog content')) {
        $contentSkipped[$course.Key] = $true
        Write-Host "  [SKIPPED] Catalog item declined: $($course.Title)" -ForegroundColor Magenta
        continue
    }

    try {
        # PATCH by externalId is the documented ingestion path: it creates the
        # content when absent and replaces its metadata when present. The 202
        # response body carries the Graph-assigned content id that activity
        # records must reference.
        $keyLiteral = ConvertTo-GraphKeyLiteral -Value $course.Key
        $upserted = Invoke-GraphWithRetry -Method PATCH `
            -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningContents(externalId='$keyLiteral')" `
            -Body $body
        $contentId = [string]$upserted.id
        if (-not $contentId) {
            # 202 is asynchronous - fall back to reading the item if the body had no id.
            $readBack = Invoke-GraphWithRetry -Method GET `
                -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningContents(externalId='$keyLiteral')"
            $contentId = [string]$readBack.id
        }
        $contentIdByKey[$course.Key] = $contentId
    }
    catch {
        $contentFailures[$course.Key] = "Content upsert failed: $($_.Exception.Message)"
    }
}

Write-Progress -Activity 'Upserting learning content' -Completed
Write-Host "Catalog items ready: $($contentIdByKey.Count)   Failed: $($contentFailures.Count)" -ForegroundColor Cyan

#endregion ---------------------------------------------------------------------

#region Step 3 - create the course activities ----------------------------------

$results = [System.Collections.Generic.List[object]]::new()
$userIdByUpn = @{}
$rowIndex = 0

function Resolve-TargetUserId {
    <# Resolves a destination UPN to its object ID, caching results ($false = not found). #>
    param([Parameter(Mandatory)][string]$Upn)
    if ($userIdByUpn.ContainsKey($Upn)) { return $userIdByUpn[$Upn] }
    try {
        $escaped = [uri]::EscapeDataString($Upn)
        $resolved = Invoke-GraphWithRetry -Method GET -Uri "/v1.0/users/$escaped`?`$select=id"
        $userIdByUpn[$Upn] = [string]$resolved.id
    }
    catch {
        # Only a real 404 means "user not found". A 403 (User.Read.All missing),
        # 401 or exhausted throttle must surface as itself, not be cached as a
        # phantom missing user for the rest of the run.
        if ((Get-GraphErrorStatusCode -ErrorRecord $_) -ne 404) { throw }
        $userIdByUpn[$Upn] = $false
    }
    return $userIdByUpn[$Upn]
}

foreach ($row in $csvRows) {
    $rowIndex++
    $sourceUpn = Get-CsvValue -Record $row -Column $columns.Upn
    $courseTitle = Get-CsvValue -Record $row -Column $columns.Title
    Write-Progress -Activity 'Importing course activities' `
        -Status "$rowIndex of $($csvRows.Count): $sourceUpn" `
        -PercentComplete (($rowIndex / [math]::Max($csvRows.Count, 1)) * 100)

    # Strict, like Status below: a value this map doesn't recognise fails the row
    # instead of silently importing as the wrong record type. 'Recommendation'
    # (the Viva admin export's label) is an assignment with type recommended.
    $typeText = Get-CsvValue -Record $row -Column $columns.ActivityType
    $activityType = switch -Regex ($typeText) {
        'self'                 { 'SelfInitiated'; break }
        'assignment|recommend' { 'Assignment'; break }
        default                { $null }
    }

    $targetUpn = $null
    $contentKey = $null
    $outcome = $null
    $detail = ''

    try {
        if (-not $sourceUpn) { throw 'Row has no UserPrincipalName.' }
        if (-not $activityType) {
            throw "Unrecognised ActivityType value '$typeText' (expected Assignment or SelfInitiated)."
        }

        $targetUpn = ConvertTo-TargetUpn -SourceUpn $sourceUpn `
            -OverrideUpn (Get-CsvValue -Record $row -Column $columns.TargetUpn) `
            -Domain $TargetDomain -KeepDomains $KeepCsvDomains.IsPresent

        $contentKey = (Get-CsvValue -Record $row -Column $columns.ContentExtId) ??
                      (Get-CsvValue -Record $row -Column $columns.ContentId) ??
                      (Get-CsvValue -Record $row -Column $columns.WebUrl)
        if (-not $contentKey) { throw 'Row has no course key (CourseExternalId / LearningContentId / CourseWebUrl are all empty).' }
        if ($contentFailures.Contains($contentKey)) { throw $contentFailures[$contentKey] }
        $contentId = $contentIdByKey[$contentKey]
        if (-not $contentId) { throw 'Catalog content for this row was not created.' }

        $status = Get-NormalizedStatus -Value (Get-CsvValue -Record $row -Column $columns.Status)
        if (-not $status) { throw "Unrecognised Status value '$(Get-CsvValue -Record $row -Column $columns.Status)' (expected notStarted / inProgress / completed)." }

        $userId = Resolve-TargetUserId -Upn $targetUpn
        if (-not $userId) { throw "Target user '$targetUpn' was not found in the destination tenant." }

        # Stable per-row identity so re-runs skip instead of duplicating. Prefer the
        # source tenant's IDs; hand-built CSVs fall back to a derived key.
        $externalActivityId = (Get-CsvValue -Record $row -Column $columns.ExternalActId) ??
                              (Get-CsvValue -Record $row -Column $columns.ActivityId) ??
                              "$contentKey|$targetUpn|$activityType"

        if ($DryRun -or -not $providerIsReal) {
            $outcome = 'WhatIf'
            $detail = "Would create $activityType '$courseTitle' for $targetUpn (status $status)."
        }
        else {
            # Idempotency probe: the provider-scoped alternate-key GET returns the
            # existing record (skip) or 404 (create).
            $activityKeyLiteral = ConvertTo-GraphKeyLiteral -Value $externalActivityId
            $existing = $null
            try {
                $existing = Invoke-GraphWithRetry -Method GET `
                    -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningCourseActivities(externalCourseActivityId='$activityKeyLiteral')"
            }
            catch {
                if ((Get-GraphErrorStatusCode -ErrorRecord $_) -ne 404) { throw }
            }

            if ($existing) {
                $outcome = 'Exists'
                $detail = 'An activity with this external ID already exists under the provider - skipped.'
            }
            elseif ($PSCmdlet.ShouldProcess($targetUpn, "Create $activityType activity '$courseTitle'")) {
                $body = @{
                    learnerUserId            = $userId
                    learningContentId        = $contentId
                    learningProviderId       = $providerId
                    externalCourseActivityId = $externalActivityId
                    status                   = $status
                }

                # Tolerate hand-built CSVs: '85', '85%', '87.5' all round and clamp
                # to 0-100; a non-numeric value is dropped with a note rather than
                # silently, so the operator can see the data loss in the results.
                $percentNote = ''
                $percentText = Get-CsvValue -Record $row -Column $columns.Percentage
                if ($percentText) {
                    $parsedPercent = 0.0
                    $cleanPercent = ($percentText -replace '%', '').Trim()
                    if ([double]::TryParse($cleanPercent, [System.Globalization.NumberStyles]::Float,
                            [cultureinfo]::InvariantCulture, [ref]$parsedPercent)) {
                        $body['completionPercentage'] = [int][math]::Min([math]::Max([math]::Round($parsedPercent), 0), 100)
                    }
                    else {
                        $percentNote = " CompletionPercentage '$percentText' was not numeric and was ignored."
                    }
                }
                $completed = Get-CsvValue -Record $row -Column $columns.Completed
                if ($completed) { $body['completedDateTime'] = $completed }

                if ($activityType -eq 'Assignment') {
                    $body['@odata.type'] = '#microsoft.graph.learningAssignment'

                    # peerRecommended/unknownFutureValue are not accepted as input -
                    # anything that isn't 'required' imports as 'recommended'.
                    $assignmentType = Get-CsvValue -Record $row -Column $columns.AssignmentType
                    $body['assignmentType'] = if ($assignmentType -match '^required$') { 'required' } else { 'recommended' }

                    $assigned = Get-CsvValue -Record $row -Column $columns.Assigned
                    if ($assigned) { $body['assignedDateTime'] = $assigned }

                    $assignerUpn = Get-CsvValue -Record $row -Column $columns.AssignerUpn
                    if ($assignerUpn) {
                        $mappedAssigner = ConvertTo-TargetUpn -SourceUpn $assignerUpn -Domain $TargetDomain -KeepDomains $KeepCsvDomains.IsPresent
                        $assignerId = Resolve-TargetUserId -Upn $mappedAssigner
                        if ($assignerId) { $body['assignerUserId'] = $assignerId }
                    }

                    $due = Get-CsvValue -Record $row -Column $columns.Due
                    if ($due) {
                        # dateTimeTimeZone object on the wire, despite the doc tables.
                        $body['dueDateTime'] = @{
                            dateTime = $due
                            timeZone = (Get-CsvValue -Record $row -Column $columns.DueZone) ?? 'UTC'
                        }
                    }

                    $notes = Get-CsvValue -Record $row -Column $columns.Notes
                    if ($notes) { $body['notes'] = @{ contentType = 'text'; content = $notes } }
                }
                else {
                    $body['@odata.type'] = '#microsoft.graph.learningSelfInitiatedCourse'
                    $started = Get-CsvValue -Record $row -Column $columns.Started
                    if ($started) { $body['startedDateTime'] = $started }
                }

                Invoke-GraphWithRetry -Method POST `
                    -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningCourseActivities" `
                    -Body $body | Out-Null
                $outcome = 'Created'
                $detail = "$activityType '$courseTitle' created (status $status).$percentNote"
            }
            else {
                $outcome = 'WhatIf'
                $detail = 'Skipped by operator (ShouldProcess declined).'
            }
        }
    }
    catch {
        if ($contentKey -and $contentSkipped.Contains($contentKey)) {
            # The row only "failed" because its catalog upsert was declined
            # (-WhatIf / answering No) - report it as a preview, not an error.
            $outcome = 'WhatIf'
            $detail = 'Catalog upsert was declined in this run - activity creation not attempted.'
        }
        else {
            $outcome = 'Failed'
            # Graph puts the useful error text in ErrorDetails (the response body);
            # Exception.Message is usually just the status line - match on both.
            $combined = @([string]$_.ErrorDetails.Message, [string]$_.Exception.Message) -join ' '
            if ($combined -match "user license isn't valid") {
                $detail = "Target user '$targetUpn' has no Viva Learning premium license - the API refuses activity records for unlicensed learners."
            }
            elseif ($combined -match 'adequate service plan') {
                $detail = 'The tenant/app has no adequate Viva Learning service plan for this request.'
            }
            else {
                $detail = $_.Exception.Message
            }
        }
    }

    $color = switch ($outcome) {
        'Created' { 'Green' }
        'Exists'  { 'Cyan' }
        'WhatIf'  { 'Magenta' }
        default   { 'Red' }
    }
    Write-Host ("  [{0}] {1} -> {2} - {3}" -f $outcome, $sourceUpn, $targetUpn, $detail) -ForegroundColor $color

    $rowResult = [pscustomobject][ordered]@{
        SourceUserPrincipalName = $sourceUpn
        TargetUserPrincipalName = $targetUpn
        ActivityType            = $activityType ?? $typeText
        CourseTitle             = $courseTitle
        Outcome                 = $outcome
        Detail                  = $detail
    }
    $results.Add($rowResult)
    # Appended per row (not once at the end) so the audit trail survives a
    # Ctrl+C or lost session mid-import - activities already created in the
    # destination tenant stay accounted for. -WhatIf:$false keeps the log
    # itself out of ShouldProcess so a -WhatIf preview still records outcomes.
    $rowResult | Export-Csv -Path $resultsCsv -NoTypeInformation -Encoding UTF8 -Append -Confirm:$false -WhatIf:$false
}

Write-Progress -Activity 'Importing course activities' -Completed

#endregion ---------------------------------------------------------------------

#region Summary ----------------------------------------------------------------

$created = ($results | Where-Object Outcome -eq 'Created').Count
$exists = ($results | Where-Object Outcome -eq 'Exists').Count
$whatif = ($results | Where-Object Outcome -eq 'WhatIf').Count
$failed = ($results | Where-Object Outcome -eq 'Failed').Count

Write-Host ''
if ($DryRun) {
    Write-Host "DRY RUN: $whatif row(s) would be imported, $failed row(s) have problems to fix first." -ForegroundColor Magenta
}
else {
    Write-Host "Created: $created   Already existed: $exists   WhatIf: $whatif   Failed: $failed" -ForegroundColor Green
    Write-Host 'Imported records appear on each user''s My Learning tab; catalog content can take up to 24 hours' -ForegroundColor Cyan
    Write-Host 'to show up in Viva Learning search and browse - absence within a day is not a failure.' -ForegroundColor Cyan
}

if ($results.Count -gt 0) {
    Write-Host "Results CSV: $resultsCsv" -ForegroundColor Green
}
else {
    Write-Host 'No rows were processed - no results CSV written.' -ForegroundColor Yellow
}

#endregion ---------------------------------------------------------------------

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Host 'Done.' -ForegroundColor Green
