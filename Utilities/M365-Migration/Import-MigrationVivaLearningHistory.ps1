#Requires -Version 7.4

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
        admin-consented application permissions (see .NOTES). Client-credential
        sign-in is not something Connect-MigrationGraph can express, so this
        phase calls Connect-MgGraph directly.

    Source users are mapped to destination users by UPN, in this order:

      1. a TargetUserPrincipalName column on the CSV row (always wins),
      2. the identity plan supplied with -PlanPath (matched on the plan's
         SourceUserPrincipalName, then SourcePrimarySmtp),
      3. the UPN's local part combined with -TargetDomain, or the CSV UPN
         unchanged with -KeepCsvDomains.

    Every row's outcome lands in a results CSV with the standard
    Identity / Action / Status / Detail columns, and is written to the run log as
    it happens so the audit trail survives a lost session mid-import. Note that
    each target learner needs a Viva Learning premium license - rows for
    unlicensed users fail with a licensing 403 and are recorded as such. Imported
    records surface on the users' My Learning tab; catalog content can take up to
    24 hours to appear in Viva Learning search/browse.

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

.PARAMETER PlanPath
    Path to IdentityPlan.csv. When supplied, each CSV row's source UPN is looked
    up in the plan and mapped to its TargetUserPrincipalName. A
    TargetUserPrincipalName column on the CSV row still wins, and rows the plan
    does not cover fall back to -TargetDomain / -KeepCsvDomains - or fail with a
    clear message when neither was given.

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
    TargetUserPrincipalName or the plan covers it. If omitted (and neither
    -KeepCsvDomains nor -PlanPath is set) you are prompted once.

.PARAMETER KeepCsvDomains
    Use the CSV UPNs unchanged instead of mapping to -TargetDomain.

.PARAMETER DefaultLanguageTag
    Language tag applied to catalog items whose CourseLanguage column is empty.
    Default: 'en-us'.

.PARAMETER OutputPath
    Root directory for the log and the results CSV. Defaults to
    %LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations
    elsewhere.

.PARAMETER Prefix
    Client/run label. When given, files land in <root>\<Prefix>\ and file names
    start with <Prefix>_.

.PARAMETER DryRun
    Preview - signs in and resolves everything read-only (provider match, user
    mapping, per-row plan), creates and changes nothing, and writes a -DryRun_
    results file whose rows all carry Status Planned.

.PARAMETER Verbosity
    Console detail: Low (errors and successes), Medium (adds warnings) or High
    (everything). The log file always receives everything.

.EXAMPLE
    .\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\Source_VivaLearningHistory.csv `
        -TenantId 00000000-0000-0000-0000-000000000000 -ClientId 11111111-1111-1111-1111-111111111111 `
        -ClientSecret (Read-Host -AsSecureString 'Secret') -TargetDomain newco.com -DryRun

    Full read-only rehearsal: resolves the provider, maps every learner and
    reports what would be created, without touching the destination tenant.

.EXAMPLE
    .\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\Source_VivaLearningHistory.csv `
        -TenantId 00000000-0000-0000-0000-000000000000 -ClientId 11111111-1111-1111-1111-111111111111 `
        -CertificateThumbprint ABCDEF0123456789ABCDEF0123456789ABCDEF01 `
        -PlanPath .\IdentityPlan.csv -Prefix Contoso -LogoUrl https://www.example.com/logo.png

    Certificate auth, learner mapping taken from the identity plan, output filed
    under the Contoso folder.

.EXAMPLE
    .\Import-MigrationVivaLearningHistory.ps1 -CsvPath .\History.csv `
        -TenantId 00000000-0000-0000-0000-000000000000 -ClientId 11111111-1111-1111-1111-111111111111 `
        -ClientSecret $secret -LearningProviderId 22222222-2222-2222-2222-222222222222 `
        -KeepCsvDomains -Confirm:$false

    Fully unattended: existing provider registration, CSV domains kept, no
    confirmation prompts.

.NOTES
    Author       : AutomationHub
    Requires     : PowerShell 7.4, the M365Migration module beside this script,
                   Microsoft.Graph.Authentication (installed on demand)
    Graph scopes : Delegated (interactive, only when registering/reusing a
                   provider by name): LearningProvider.ReadWrite - the signed-in
                   user needs a Viva Learning or Viva Suite license and the
                   Knowledge Administrator role (least privileged).
                   Application (app registration, admin-consented):
                   LearningContent.ReadWrite.All,
                   LearningAssignedCourse.ReadWrite.All,
                   LearningSelfInitiatedCourse.ReadWrite.All, User.Read.All.
                   Each target learner must hold a Viva Learning premium license
                   or their rows fail with a licensing 403.
    EXO roles    : none - this script does not use Exchange Online PowerShell
    GDAP         : the delegated provider step honours -TenantId under an active
                   GDAP relationship. The app-only phase does NOT: cross-tenant
                   client-credential auth needs the app registered multitenant
                   with per-tenant admin consent. There is no
                   -DelegatedOrganization here because no Exchange connection is
                   made.
    Cloud        : Global cloud only. The employee learning API is not available
                   in US Government (GCC High/DoD) or 21Vianet clouds.
    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,

    [securestring]$ClientSecret,

    [string]$CertificateThumbprint,

    [string]$PlanPath,

    [string]$LearningProviderId,

    [string]$ProviderDisplayName = 'Imported Learning History',

    [string]$LogoUrl,

    [string]$SquareLogoUrl,

    [string]$SquareLogoDarkUrl,

    [string]$LongLogoUrl,

    [string]$LongLogoDarkUrl,

    [string]$TargetDomain,

    [switch]$KeepCsvDomains,

    [string]$DefaultLanguageTag = 'en-us',

    [string]$OutputPath,

    [string]$Prefix,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Configuration ----------------------------------------------------------

# Delegated scopes for the provider step only. The content and activity phases
# run app-only against the application permissions listed in .NOTES; the employee
# learning API rejects app-only tokens for provider management and rejects
# delegated tokens for content ingestion, hence the split.
$requiredGraphScopes = @('LearningProvider.ReadWrite')

# The sentinel a DryRun (or a declined provider registration) carries in place of
# a real registration id. Everything downstream tests $providerIsReal instead of
# comparing against it in more than one place.
$newProviderPlaceholder = '(new-provider-id)'
$newContentPlaceholder = '(content-id)'

# Destination user id cache shared by Resolve-TargetUserId; $false means the
# lookup returned a genuine 404 and must not be retried.
$script:UserIdByUpn = @{}

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
        Strict-mode-safe read of an optional property on a Graph object. Graph
        omits absent properties entirely and a missing property is a fatal error
        under Set-StrictMode.
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

function Resolve-ColumnName {
    <#
        Returns the actual header matching one of $Candidates. This stays local
        rather than deferring to Import-MigrationCsv: the toolkit's alias
        vocabulary maps 'Title' to JobTitle and 'Type' to ObjectType, which are
        the wrong columns for a learner-history CSV, where they mean CourseTitle
        and ActivityType.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Headers,
        [Parameter(Mandatory)][string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        $hit = @($Headers | Where-Object { $_ -ieq $candidate }) | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-CsvValue {
    <# Tolerant read of one column; an unresolved column name yields $null. #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Record,
        [AllowNull()][AllowEmptyString()][string]$Column
    )

    if ([string]::IsNullOrWhiteSpace($Column)) { return $null }
    return Get-MigrationCsvValue -Row $Record -Name $Column -Default $null
}

function ConvertTo-GraphKeyLiteral {
    <# Escapes a value for use inside an OData key literal: (...='{value}'). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Value)

    return [uri]::EscapeDataString($Value.Replace("'", "''"))
}

function ConvertTo-TargetUpn {
    <#
        Maps a source UPN to the destination tenant. Precedence: an explicit
        TargetUserPrincipalName on the row, then the identity plan, then the
        -TargetDomain / -KeepCsvDomains scheme. Returns $null when nothing can
        map the address - only reachable with -PlanPath and no domain fallback,
        which the caller turns into a per-row failure rather than silently
        importing a source-domain UPN.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SourceUpn,
        [AllowNull()][AllowEmptyString()][string]$OverrideUpn,
        [AllowNull()][hashtable]$PlanMap,
        [AllowNull()][AllowEmptyString()][string]$Domain,
        [bool]$KeepDomains
    )

    if ($OverrideUpn) { return $OverrideUpn }

    if ($PlanMap) {
        $key = $SourceUpn.ToLowerInvariant()
        if ($PlanMap.ContainsKey($key)) { return [string]$PlanMap[$key] }
    }

    if ($KeepDomains) { return $SourceUpn }
    if ($Domain) { return ('{0}@{1}' -f ($SourceUpn -split '@')[0], $Domain) }
    if ($PlanMap) { return $null }
    return $SourceUpn
}

function Get-NormalizedStatus {
    <# Normalises a CSV status value to the courseStatus enum casing. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    switch -Regex ($Value) {
        '^\s*not\s*started\s*$' { return 'notStarted' }
        '^\s*in\s*progress\s*$' { return 'inProgress' }
        '^\s*completed?\s*$' { return 'completed' }
        default { return $null }
    }
}

function Resolve-TargetUserId {
    <# Resolves a destination UPN to its object ID, caching results ($false = not found). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Upn)

    if ($script:UserIdByUpn.ContainsKey($Upn)) { return $script:UserIdByUpn[$Upn] }
    try {
        $escaped = [uri]::EscapeDataString($Upn)
        $resolved = Invoke-MigrationGraphRequest -Method GET -Uri "/v1.0/users/$escaped`?`$select=id"
        $script:UserIdByUpn[$Upn] = [string](Get-VivaProperty -InputObject $resolved -Name 'id')
    }
    catch {
        # Only a real 404 means "user not found". A 403 (User.Read.All missing),
        # 401 or exhausted throttle must surface as itself, not be cached as a
        # phantom missing user for the rest of the run.
        if ((Get-VivaGraphStatusCode -ErrorRecord $_) -ne 404) { throw }
        $script:UserIdByUpn[$Upn] = $false
    }
    return $script:UserIdByUpn[$Upn]
}

#endregion ---------------------------------------------------------------------

#region Main -------------------------------------------------------------------

$exitCode = 0

# -WhatIf:$false so the run folder and log still exist during a -WhatIf preview:
# the audit trail is not one of the changes -WhatIf is meant to withhold.
$run = Initialize-MigrationRun -ScriptName 'Import-MigrationVivaLearningHistory' -OutputPath $OutputPath `
    -Prefix $Prefix -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters -WhatIf:$false
$null = $run

$results = [System.Collections.Generic.List[object]]::new()

try {
    if (-not $ClientSecret -and -not $CertificateThumbprint) {
        throw ('Provide either -ClientSecret or -CertificateThumbprint for the app-only phase ' +
            '(content + activities are application-permission-only).')
    }
    if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
        throw "CSV not found: $CsvPath"
    }

    Initialize-MigrationModule -Name 'Microsoft.Graph.Authentication'

    #region Load and validate the CSV ------------------------------------------
    $csvRows = @(Import-Csv -LiteralPath $CsvPath)
    if ($csvRows.Count -eq 0) { throw "CSV '$CsvPath' contains no rows." }

    $headers = @($csvRows[0].PSObject.Properties.Name)
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
        throw ("Could not find the CourseTitle and CourseWebUrl columns in '$CsvPath' - both are required to " +
            "create catalog content. Headers: $($headers -join ', ')")
    }

    Write-MigrationLog -Message "CSV rows: $($csvRows.Count)" -Level INFO

    # Source -> target lookup from the identity plan. Both the plan's source UPN
    # and its source primary SMTP are indexed, because a hand-built history CSV
    # may be keyed on either.
    $planUpnMap = $null
    if ($PlanPath) {
        $planUpnMap = @{}
        foreach ($planRow in @(Import-MigrationPlan -Path $PlanPath)) {
            $planTarget = Get-MigrationCsvValue -Row $planRow -Name 'TargetUserPrincipalName' -Default ''
            if (-not $planTarget) { continue }
            foreach ($sourceColumn in @('SourceUserPrincipalName', 'SourcePrimarySmtp')) {
                $planSource = Get-MigrationCsvValue -Row $planRow -Name $sourceColumn -Default ''
                if (-not $planSource) { continue }
                $planKey = $planSource.ToLowerInvariant()
                if (-not $planUpnMap.ContainsKey($planKey)) { $planUpnMap[$planKey] = $planTarget }
            }
        }
        Write-MigrationLog -Message "Identity plan supplies $($planUpnMap.Count) source-to-target address mapping(s)." -Level INFO
    }

    # Ask for the mapping domain once when neither -TargetDomain, -KeepCsvDomains
    # nor -PlanPath was chosen, so hand-off runs don't silently import
    # source-domain UPNs. A TargetUserPrincipalName column doesn't suppress the
    # prompt - it may only cover some rows, and blank cells fall back to this
    # mapping.
    if (-not $TargetDomain -and -not $KeepCsvDomains -and -not $PlanPath) {
        $answer = ((Read-Host 'Destination UPN domain to map users to (blank = keep the CSV domains)') ?? '').Trim()
        if ($answer) { $TargetDomain = $answer.TrimStart('@') }
        else { $KeepCsvDomains = $true }
    }
    #endregion -----------------------------------------------------------------

    #region Step 1 - resolve or register the learning provider -----------------
    $providerId = $LearningProviderId

    if ($providerId) {
        Write-MigrationLog -Message "Using supplied learning provider registration: $providerId" -Level INFO
    }
    else {
        # Provider management is delegated-only in the employee learning API, so
        # this step needs its own interactive sign-in before the app-only phase.
        Write-MigrationLog -Message 'Connecting to Microsoft Graph interactively for the provider step (sign in as a Viva-licensed Knowledge Administrator)...' -Level INFO
        $null = Connect-MigrationGraph -Scopes $requiredGraphScopes -TenantId $TenantId -Reconnect

        $providers = @(Invoke-MigrationGraphRequest -Method GET -All -Uri '/v1.0/employeeExperience/learningProviders')
        $existing = $providers |
            Where-Object { [string](Get-VivaProperty -InputObject $_ -Name 'displayName') -ieq $ProviderDisplayName } |
            Select-Object -First 1

        if ($existing) {
            $providerId = [string](Get-VivaProperty -InputObject $existing -Name 'id')
            Write-MigrationLog -Message "Reusing existing provider '$ProviderDisplayName' [$providerId]" -Level SUCCESS

            if (-not (Get-VivaProperty -InputObject $existing -Name 'isCourseActivitySyncEnabled' -Default $false)) {
                # Course activity writes are rejected while sync is disabled on the provider.
                if ($PSCmdlet.ShouldProcess($ProviderDisplayName, 'Enable course-activity sync on the learning provider')) {
                    Invoke-MigrationAction -Description "Enable course-activity sync on provider '$ProviderDisplayName'" -Action {
                        $null = Invoke-MigrationGraphRequest -Method PATCH `
                            -Uri "/v1.0/employeeExperience/learningProviders/$providerId" `
                            -Body @{ isCourseActivitySyncEnabled = $true }
                    }
                }
                else {
                    Write-MigrationLog -Message '[SKIPPED] Course-activity sync was not enabled - activity writes will be rejected.' -Level WARNING
                }
            }
        }
        else {
            $square = $SquareLogoUrl ?? $LogoUrl
            $squareDark = $SquareLogoDarkUrl ?? $LogoUrl
            $long = $LongLogoUrl ?? $LogoUrl
            $longDark = $LongLogoDarkUrl ?? $LogoUrl

            if (-not ($square -and $squareDark -and $long -and $longDark)) {
                Write-MigrationLog -Message ("Provider '$ProviderDisplayName' does not exist yet and registering one requires " +
                    'logo image URLs (publicly reachable - Viva Learning copies the image to its own storage).') -Level WARNING
                $answer = ((Read-Host 'Image URL to use for all logo slots (e.g. your company logo PNG)') ?? '').Trim()
                if (-not $answer) { throw 'A logo URL is required to register a learning provider.' }
                if (-not $square) { $square = $answer }
                if (-not $squareDark) { $squareDark = $answer }
                if (-not $long) { $long = $answer }
                if (-not $longDark) { $longDark = $answer }
            }

            $providerId = $newProviderPlaceholder
            if ($PSCmdlet.ShouldProcess($ProviderDisplayName, 'Register a new Viva Learning provider')) {
                $created = Invoke-MigrationAction -PassThru -Description "Register learning provider '$ProviderDisplayName' with course-activity sync enabled" -Action {
                    Invoke-MigrationGraphRequest -Method POST -Uri '/v1.0/employeeExperience/learningProviders' -Body @{
                        displayName                   = $ProviderDisplayName
                        squareLogoWebUrlForLightTheme = $square
                        squareLogoWebUrlForDarkTheme  = $squareDark
                        longLogoWebUrlForLightTheme   = $long
                        longLogoWebUrlForDarkTheme    = $longDark
                        isCourseActivitySyncEnabled   = $true
                    }
                }
                if ($created) {
                    $providerId = [string](Get-VivaProperty -InputObject $created -Name 'id')
                    Write-MigrationLog -Message "Registered provider '$ProviderDisplayName' [$providerId]" -Level SUCCESS
                }
            }
        }

        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }
    }
    #endregion -----------------------------------------------------------------

    #region Connect app-only for content + activities --------------------------
    # Client-credential auth is outside Connect-MigrationGraph's remit (it owns
    # the interactive/GDAP path), so this phase calls Connect-MgGraph directly.
    Write-MigrationLog -Message 'Connecting to Microsoft Graph with application credentials...' -Level INFO
    try {
        if ($CertificateThumbprint) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome -ErrorAction Stop
        }
        else {
            $appCredential = [pscredential]::new($ClientId, $ClientSecret)
            Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $appCredential -NoWelcome -ErrorAction Stop
        }
    }
    catch {
        throw ("App-only sign-in to tenant $TenantId failed: $($_.Exception.Message). Check the client id, the " +
            'secret/certificate, and that the application permissions listed in the script NOTES have admin consent.')
    }
    Write-MigrationLog -Message "Connected app-only to tenant $((Get-MgContext).TenantId)" -Level SUCCESS

    # The API only accepts activity writes for real, licensed provider registrations;
    # a DryRun with a placeholder provider id skips every call that would need it.
    $providerIsReal = $providerId -and $providerId -ne $newProviderPlaceholder
    #endregion -----------------------------------------------------------------

    #region Step 2 - build and upsert the course catalog -----------------------
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
            Key          = $key
            Title        = Get-CsvValue -Record $row -Column $columns.Title
            WebUrl       = Get-CsvValue -Record $row -Column $columns.WebUrl
            Description  = Get-CsvValue -Record $row -Column $columns.Description
            Language     = (Get-CsvValue -Record $row -Column $columns.Language) ?? $DefaultLanguageTag
            Duration     = Get-CsvValue -Record $row -Column $columns.Duration
            Format       = Get-CsvValue -Record $row -Column $columns.Format
            Level        = Get-CsvValue -Record $row -Column $columns.Level
            SourceName   = Get-CsvValue -Record $row -Column $columns.SourceName
            Thumbnail    = Get-CsvValue -Record $row -Column $columns.Thumbnail
            SkillTags    = @((Get-CsvValue -Record $row -Column $columns.SkillTags) -split ';' | Where-Object { $_ })
            Contributors = @((Get-CsvValue -Record $row -Column $columns.Contributors) -split ';' | Where-Object { $_ })
        }
    }

    Write-MigrationLog -Message "Distinct courses in the CSV: $($catalog.Count)" -Level INFO

    $contentIdByKey = @{}
    $contentFailures = @{}
    $contentSkipped = @{}   # operator/WhatIf declines - dependent rows report Skipped, not Failed
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
            Write-MigrationLog -Message "[DRYRUN] Would upsert catalog item: $($course.Title)" -Level WARNING
            $contentIdByKey[$course.Key] = $newContentPlaceholder
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($course.Title, 'Upsert Viva Learning catalog content')) {
            $contentSkipped[$course.Key] = $true
            Write-MigrationLog -Message "[SKIPPED] Catalog item declined: $($course.Title)" -Level WARNING
            continue
        }

        try {
            # PATCH by externalId is the documented ingestion path: it creates the
            # content when absent and replaces its metadata when present. The 202
            # response body carries the Graph-assigned content id that activity
            # records must reference.
            $keyLiteral = ConvertTo-GraphKeyLiteral -Value $course.Key
            $upserted = Invoke-MigrationAction -PassThru -Description "Upsert catalog item '$($course.Title)'" -Action {
                Invoke-MigrationGraphRequest -Method PATCH `
                    -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningContents(externalId='$keyLiteral')" `
                    -Body $body
            }
            $contentId = [string](Get-VivaProperty -InputObject $upserted -Name 'id')
            if (-not $contentId) {
                # 202 is asynchronous - fall back to reading the item if the body had no id.
                $readBack = Invoke-MigrationGraphRequest -Method GET `
                    -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningContents(externalId='$keyLiteral')"
                $contentId = [string](Get-VivaProperty -InputObject $readBack -Name 'id')
            }
            $contentIdByKey[$course.Key] = $contentId
        }
        catch {
            $contentFailures[$course.Key] = "Content upsert failed: $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity 'Upserting learning content' -Completed
    Write-MigrationLog -Message "Catalog items ready: $($contentIdByKey.Count)   Failed: $($contentFailures.Count)" -Level INFO
    #endregion -----------------------------------------------------------------

    #region Step 3 - create the course activities ------------------------------
    $rowIndex = 0

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
            'self' { 'SelfInitiated'; break }
            'assignment|recommend' { 'Assignment'; break }
            default { $null }
        }

        $targetUpn = $null
        $contentKey = $null
        $rowStatus = $null
        $detail = ''

        try {
            if (-not $sourceUpn) { throw 'Row has no UserPrincipalName.' }
            if (-not $activityType) {
                throw "Unrecognised ActivityType value '$typeText' (expected Assignment or SelfInitiated)."
            }

            $targetUpn = ConvertTo-TargetUpn -SourceUpn $sourceUpn `
                -OverrideUpn (Get-CsvValue -Record $row -Column $columns.TargetUpn) `
                -PlanMap $planUpnMap -Domain $TargetDomain -KeepDomains $KeepCsvDomains.IsPresent
            if (-not $targetUpn) {
                throw ("Source UPN '$sourceUpn' is not in the identity plan and the row has no " +
                    'TargetUserPrincipalName - add it to the plan, or pass -TargetDomain / -KeepCsvDomains.')
            }

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
                $rowStatus = 'Planned'
                $detail = "Would create $activityType '$courseTitle' for $targetUpn (status $status)."
            }
            else {
                # Idempotency probe: the provider-scoped alternate-key GET returns the
                # existing record (skip) or 404 (create).
                $activityKeyLiteral = ConvertTo-GraphKeyLiteral -Value $externalActivityId
                $existingActivity = $null
                try {
                    $existingActivity = Invoke-MigrationGraphRequest -Method GET `
                        -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningCourseActivities(externalCourseActivityId='$activityKeyLiteral')"
                }
                catch {
                    if ((Get-VivaGraphStatusCode -ErrorRecord $_) -ne 404) { throw }
                }

                if ($existingActivity) {
                    $rowStatus = 'Skipped'
                    $detail = 'An activity with this external ID already exists under the provider - skipped.'
                }
                elseif ($PSCmdlet.ShouldProcess($targetUpn, "Create $activityType activity '$courseTitle'")) {
                    $activityBody = @{
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
                            $activityBody['completionPercentage'] = [int][math]::Min([math]::Max([math]::Round($parsedPercent), 0), 100)
                        }
                        else {
                            $percentNote = " CompletionPercentage '$percentText' was not numeric and was ignored."
                        }
                    }
                    $completed = Get-CsvValue -Record $row -Column $columns.Completed
                    if ($completed) { $activityBody['completedDateTime'] = $completed }

                    if ($activityType -eq 'Assignment') {
                        $activityBody['@odata.type'] = '#microsoft.graph.learningAssignment'

                        # peerRecommended/unknownFutureValue are not accepted as input -
                        # anything that isn't 'required' imports as 'recommended'.
                        $assignmentType = Get-CsvValue -Record $row -Column $columns.AssignmentType
                        $activityBody['assignmentType'] = if ($assignmentType -match '^required$') { 'required' } else { 'recommended' }

                        $assigned = Get-CsvValue -Record $row -Column $columns.Assigned
                        if ($assigned) { $activityBody['assignedDateTime'] = $assigned }

                        $assignerUpn = Get-CsvValue -Record $row -Column $columns.AssignerUpn
                        if ($assignerUpn) {
                            $mappedAssigner = ConvertTo-TargetUpn -SourceUpn $assignerUpn -PlanMap $planUpnMap `
                                -Domain $TargetDomain -KeepDomains $KeepCsvDomains.IsPresent
                            if ($mappedAssigner) {
                                $assignerId = Resolve-TargetUserId -Upn $mappedAssigner
                                if ($assignerId) { $activityBody['assignerUserId'] = $assignerId }
                            }
                        }

                        $due = Get-CsvValue -Record $row -Column $columns.Due
                        if ($due) {
                            # dateTimeTimeZone object on the wire, despite the doc tables.
                            $activityBody['dueDateTime'] = @{
                                dateTime = $due
                                timeZone = (Get-CsvValue -Record $row -Column $columns.DueZone) ?? 'UTC'
                            }
                        }

                        $notes = Get-CsvValue -Record $row -Column $columns.Notes
                        if ($notes) { $activityBody['notes'] = @{ contentType = 'text'; content = $notes } }
                    }
                    else {
                        $activityBody['@odata.type'] = '#microsoft.graph.learningSelfInitiatedCourse'
                        $started = Get-CsvValue -Record $row -Column $columns.Started
                        if ($started) { $activityBody['startedDateTime'] = $started }
                    }

                    Invoke-MigrationAction -Description "Create $activityType activity '$courseTitle' for $targetUpn" -Action {
                        $null = Invoke-MigrationGraphRequest -Method POST `
                            -Uri "/v1.0/employeeExperience/learningProviders/$providerId/learningCourseActivities" `
                            -Body $activityBody
                    }
                    $rowStatus = 'Succeeded'
                    $detail = "$activityType '$courseTitle' created (status $status).$percentNote"
                }
                else {
                    $rowStatus = 'Skipped'
                    $detail = 'Skipped by operator (ShouldProcess declined).'
                }
            }
        }
        catch {
            if ($contentKey -and $contentSkipped.Contains($contentKey)) {
                # The row only "failed" because its catalog upsert was declined
                # (-WhatIf / answering No) - report it as a skip, not an error.
                $rowStatus = 'Skipped'
                $detail = 'Catalog upsert was declined in this run - activity creation not attempted.'
            }
            else {
                $rowStatus = 'Failed'
                # Graph puts the useful error text in ErrorDetails (the response body);
                # Exception.Message is usually just the status line - match on both.
                $errorBody = ''
                if ($_.ErrorDetails) { $errorBody = [string]$_.ErrorDetails.Message }
                $combined = @($errorBody, [string]$_.Exception.Message) -join ' '
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

        $level = switch ($rowStatus) {
            'Succeeded' { 'SUCCESS' }
            'Failed' { 'ERROR' }
            'Skipped' { 'WARNING' }
            default { 'WARNING' }
        }
        # Written per row rather than only in the summary: Write-MigrationLog appends
        # to the log file as it goes, so activities already created in the destination
        # tenant stay accounted for even if the session is lost mid-import.
        Write-MigrationLog -Message ('  [{0}] {1} -> {2} - {3}' -f $rowStatus, $sourceUpn, $targetUpn, $detail) -Level $level

        $results.Add([pscustomobject][ordered]@{
                Identity                = $targetUpn ?? $sourceUpn
                Action                  = 'ImportLearningActivity'
                Status                  = $rowStatus
                Detail                  = $detail
                SourceUserPrincipalName = $sourceUpn
                TargetUserPrincipalName = $targetUpn
                ActivityType            = $activityType ?? $typeText
                CourseTitle             = $courseTitle
            })
    }

    Write-Progress -Activity 'Importing course activities' -Completed
    #endregion -----------------------------------------------------------------

    if (-not $DryRun) {
        Write-MigrationLog -Message ("Imported records appear on each user's My Learning tab; catalog content can take up to " +
            '24 hours to show up in Viva Learning search and browse - absence within a day is not a failure.') -Level INFO
    }
}
catch {
    Write-MigrationLog -Message "Fatal: $($_.Exception.Message)" -Level ERROR
    $exitCode = 1
}

# The results file is written whatever happened, so a run that died part-way still
# accounts for every activity it created.
if ($results.Count -gt 0 -or $exitCode -eq 0) {
    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'Import-VivaLearningHistory'
}
if ($exitCode -eq 0 -and @($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { $exitCode = 2 }

#endregion ---------------------------------------------------------------------

#region Cleanup ----------------------------------------------------------------

try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { $null = $_ }

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion ---------------------------------------------------------------------
