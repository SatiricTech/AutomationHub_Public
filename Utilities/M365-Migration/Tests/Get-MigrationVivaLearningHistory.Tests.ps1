#Requires -Version 7.4

<#
    Offline tests for Get-MigrationVivaLearningHistory.ps1.

    The script is tenant-bound and has never run against a tenant, so what these tests pin
    down is everything that can be proved without one: the /me routing, the assigner lookup
    cache and its failure handling, the CSV column set (Import-MigrationVivaLearningHistory's
    contract), the 403/404 -> results-row mapping, the "every cross-user read was denied"
    guidance and the circuit breaker that stops a large tenant making one rejected call per
    user. Two structural checks pin the documented deviations from the toolkit norm: -DryRun
    never reaches Connect-MigrationGraph, and the script never disconnects the session.

    How the script's functions get into the test session: dot-sourcing the script would run
    Main and try to sign in, so the file is parsed and only its FunctionDefinitionAst nodes
    are re-created here. The functions then live in the test's session state, so a plain
    `Mock Invoke-MigrationGraphRequest` intercepts their Graph calls.

    Fixtures under Fixtures/Get-MigrationVivaLearningHistory are Graph-shaped pages (a
    learningAssignment plus a learningSelfInitiatedCourse, and one catalog entry) with
    placeholder GUIDs and contoso.com addresses only.

    Author: AutomationHub
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Get-MigrationVivaLearningHistory.ps1')).Path
    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'Get-MigrationVivaLearningHistory'

    $tokens = $null
    $parseErrors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Get-MigrationVivaLearningHistory.ps1 does not parse: $($parseErrors[0].Message)"
    }
    $functionPredicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    foreach ($definition in $script:Ast.FindAll($functionPredicate, $true)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $script:ActivityPage = Get-Content -Raw -LiteralPath (Join-Path $script:FixtureRoot 'learningCourseActivities.json') | ConvertFrom-Json
    $script:ContentPage = Get-Content -Raw -LiteralPath (Join-Path $script:FixtureRoot 'learningContents.json') | ConvertFrom-Json
    $script:Assignment = $script:ActivityPage.value[0]
    $script:SelfInitiated = $script:ActivityPage.value[1]
    $script:Content = $script:ContentPage.value[0]

    $script:LearnerId = '00000000-0000-0000-0000-00000000a001'
    $script:AssignerId = '00000000-0000-0000-0000-00000000a002'
    $script:ProviderId = '00000000-0000-0000-0000-00000000f001'
    $script:ContentById = @{ $script:Content.id = $script:Content }
    $script:ProviderNamesById = @{ $script:ProviderId = 'Contoso Academy' }
    $script:PreferHeader = @{ Prefer = 'include-unknown-enum-members' }

    $script:Forbidden = 'Response status code does not indicate success: 403 (Forbidden).'
    $script:NotFound = 'Response status code does not indicate success: 404 (NotFound).'
    $script:Throttled = 'Response status code does not indicate success: 429 (TooManyRequests).'
    $script:ServerError = 'Response status code does not indicate success: 500 (InternalServerError).'

    function New-TestUser {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds an in-memory Graph user; it changes no state.')]
        param(
            [string]$Id = '00000000-0000-0000-0000-00000000a001',
            [string]$UserPrincipalName = 'jane.smith@contoso.com',
            [string]$DisplayName = 'Jane Smith'
        )
        return [pscustomobject]@{
            id                = $Id
            userPrincipalName = $UserPrincipalName
            displayName       = $DisplayName
            accountEnabled    = $true
            userType          = 'Member'
        }
    }

    function New-TestUserSet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds an in-memory Graph user list; it changes no state.')]
        param([int]$Count)
        return @(1..$Count | ForEach-Object {
                New-TestUser -Id ('00000000-0000-0000-0000-0000000000{0:d2}' -f $_) -UserPrincipalName "user$_@contoso.com" -DisplayName "User $_"
            })
    }

    function Invoke-TestRead {
        param(
            [object[]]$TargetUser,
            [string]$SignedInAccount = 'admin@contoso.com',
            [int]$CrossUserDenialLimit = 10
        )
        return Read-LearningHistory -TargetUser $TargetUser -SignedInAccount $SignedInAccount -ContentById $script:ContentById `
            -ProviderNamesById $script:ProviderNamesById -PreferHeader $script:PreferHeader -CrossUserDenialLimit $CrossUserDenialLimit
    }
}

Describe 'ConvertTo-FlatDateTime' {

    It 'Adds the UTC marker Graph sometimes omits' {
        ConvertTo-FlatDateTime -Value '2026-08-01T09:00:00' | Should -BeExactly '2026-08-01T09:00:00Z'
    }

    It 'Normalises an offset timestamp to UTC' {
        ConvertTo-FlatDateTime -Value '2026-08-01T09:00:00+02:00' | Should -BeExactly '2026-08-01T07:00:00Z'
    }

    It 'Returns null for null or blank so the CSV cell stays empty' {
        ConvertTo-FlatDateTime -Value $null | Should -BeNullOrEmpty
        ConvertTo-FlatDateTime -Value '   ' | Should -BeNullOrEmpty
    }

    It 'Passes an unparseable value through rather than dropping it' {
        ConvertTo-FlatDateTime -Value 'not a date' | Should -BeExactly 'not a date'
    }

    It 'Formats a value the SDK already parsed into a [datetime] without going through the current culture' {
        ConvertTo-FlatDateTime -Value ([DateTime]::new(2026, 8, 1, 9, 0, 0, [DateTimeKind]::Utc)) | Should -BeExactly '2026-08-01T09:00:00Z'
        ConvertTo-FlatDateTime -Value ([DateTime]::new(2026, 8, 1, 9, 0, 0, [DateTimeKind]::Unspecified)) | Should -BeExactly '2026-08-01T09:00:00Z'
        ConvertTo-FlatDateTime -Value ([DateTimeOffset]::new(2026, 8, 1, 9, 0, 0, [TimeSpan]::FromHours(2))) | Should -BeExactly '2026-08-01T07:00:00Z'
    }
}

Describe 'Add-LearningResultRow' {

    It 'Leads with the four toolkit results columns, then ActivityCount' {
        $list = [System.Collections.Generic.List[object]]::new()
        Add-LearningResultRow -Target $list -Identity 'jane.smith@contoso.com' -Action 'ExportLearningHistory' -Status 'Succeeded' -Detail 'ok' -ActivityCount 2
        $list.Count | Should -Be 1
        @($list[0].PSObject.Properties.Name) | Should -Be @('Identity', 'Action', 'Status', 'Detail', 'ActivityCount')
        $list[0].ActivityCount | Should -Be 2
    }

    It 'Rejects a status outside the toolkit vocabulary' {
        $list = [System.Collections.Generic.List[object]]::new()
        { Add-LearningResultRow -Target $list -Identity 'x' -Action 'ExportLearningHistory' -Status 'Done' -Detail 'x' } | Should -Throw
    }
}

Describe 'Get-LearningActivityUri' {

    It 'Routes the signed-in account through /me, case-insensitively' {
        $request = Get-LearningActivityUri -UserId $script:LearnerId -UserPrincipalName 'Jane.Smith@Contoso.com' -SignedInAccount 'jane.smith@contoso.com'
        $request.IsSelf | Should -BeTrue
        $request.Uri | Should -BeExactly '/v1.0/me/employeeExperience/learningCourseActivities?$top=100'
    }

    It 'Routes any other user through /users/{id}' {
        $request = Get-LearningActivityUri -UserId $script:LearnerId -UserPrincipalName 'jane.smith@contoso.com' -SignedInAccount 'admin@contoso.com'
        $request.IsSelf | Should -BeFalse
        $request.Uri | Should -BeExactly "/v1.0/users/$($script:LearnerId)/employeeExperience/learningCourseActivities?`$top=100"
    }

    It 'Never treats a user as self when no signed-in account is known' {
        (Get-LearningActivityUri -UserId $script:LearnerId -UserPrincipalName 'jane.smith@contoso.com' -SignedInAccount '').IsSelf | Should -BeFalse
    }
}

Describe 'Resolve-LearningAssignerUpn' {

    BeforeAll {
        Mock Write-MigrationLog { }
    }

    It 'Resolves the UPN once and serves later lookups from the cache' {
        Mock Invoke-MigrationGraphRequest { return [pscustomobject]@{ userPrincipalName = 'manager@contoso.com' } }
        $cache = @{}

        $first = Resolve-LearningAssignerUpn -AssignerId $script:AssignerId -Cache $cache
        $second = Resolve-LearningAssignerUpn -AssignerId $script:AssignerId -Cache $cache

        $first.Outcome | Should -BeExactly 'Resolved'
        $first.UserPrincipalName | Should -BeExactly 'manager@contoso.com'
        $second.Outcome | Should -BeExactly 'Cached'
        $second.UserPrincipalName | Should -BeExactly 'manager@contoso.com'
        Should -Invoke Invoke-MigrationGraphRequest -Times 1 -Exactly
    }

    It 'Caches a deleted assigner (404) as blank without a warning' {
        Mock Invoke-MigrationGraphRequest { throw $script:NotFound }
        $cache = @{}

        $result = Resolve-LearningAssignerUpn -AssignerId $script:AssignerId -Cache $cache
        $again = Resolve-LearningAssignerUpn -AssignerId $script:AssignerId -Cache $cache

        $result.Outcome | Should -BeExactly 'NotFound'
        $result.UserPrincipalName | Should -BeNullOrEmpty
        $again.Outcome | Should -BeExactly 'Cached'
        $cache.ContainsKey($script:AssignerId) | Should -BeTrue
        Should -Invoke Invoke-MigrationGraphRequest -Times 1 -Exactly
        Should -Invoke Write-MigrationLog -ParameterFilter { $Level -eq 'WARNING' } -Times 0 -Exactly
    }

    It 'Warns once for a 403 and still caches, so the failing call is not repeated' {
        Mock Invoke-MigrationGraphRequest { throw $script:Forbidden }
        $cache = @{}

        $result = Resolve-LearningAssignerUpn -AssignerId $script:AssignerId -Cache $cache
        $again = Resolve-LearningAssignerUpn -AssignerId $script:AssignerId -Cache $cache

        $result.Outcome | Should -BeExactly 'Failed'
        $result.UserPrincipalName | Should -BeNullOrEmpty
        $again.Outcome | Should -BeExactly 'Cached'
        Should -Invoke Invoke-MigrationGraphRequest -Times 1 -Exactly
        Should -Invoke Write-MigrationLog -ParameterFilter {
            $Level -eq 'WARNING' -and $Message -like "*$($script:AssignerId)*" -and $Message -like '*403*'
        } -Times 1 -Exactly
    }

    It 'Does not cache exhausted throttling, so a later activity gets another attempt' {
        Mock Invoke-MigrationGraphRequest { throw $script:Throttled }
        $cache = @{}

        $result = Resolve-LearningAssignerUpn -AssignerId $script:AssignerId -Cache $cache
        $again = Resolve-LearningAssignerUpn -AssignerId $script:AssignerId -Cache $cache

        $result.Outcome | Should -BeExactly 'Retryable'
        $again.Outcome | Should -BeExactly 'Retryable'
        $cache.ContainsKey($script:AssignerId) | Should -BeFalse
        Should -Invoke Invoke-MigrationGraphRequest -Times 2 -Exactly
        Should -Invoke Write-MigrationLog -ParameterFilter { $Level -eq 'WARNING' -and $Message -like '*429*' } -Times 2 -Exactly
    }
}

Describe 'ConvertTo-LearningHistoryRow' {

    BeforeAll {
        $script:User = New-TestUser
        $script:AssignmentRow = ConvertTo-LearningHistoryRow -Activity $script:Assignment -User $script:User `
            -AssignerUserPrincipalName 'manager@contoso.com' -Content $script:Content -ProviderNamesById $script:ProviderNamesById
        $script:SelfRow = ConvertTo-LearningHistoryRow -Activity $script:SelfInitiated -User $script:User `
            -AssignerUserPrincipalName $null -Content $null -ProviderNamesById $script:ProviderNamesById
    }

    It 'Emits exactly the columns Import-MigrationVivaLearningHistory reads, in order' {
        $expected = @(
            'UserPrincipalName', 'UserDisplayName', 'UserId', 'ActivityType', 'Status', 'CompletionPercentage',
            'CompletedDateTime', 'StartedDateTime', 'AssignedDateTime', 'AssignmentType', 'AssignerUserId',
            'AssignerUserPrincipalName', 'DueDateTime', 'DueDateTimeZone', 'Notes', 'ActivityId',
            'ExternalCourseActivityId', 'LearningProviderId', 'LearningProviderName', 'LearningContentId',
            'CourseExternalId', 'CourseTitle', 'CourseWebUrl', 'CourseDescription', 'CourseLanguage', 'CourseDuration',
            'CourseFormat', 'CourseLevel', 'CourseSourceName', 'CourseThumbnailUrl', 'CourseSkillTags', 'CourseContributors'
        )
        @($script:AssignmentRow.PSObject.Properties.Name) | Should -Be $expected
    }

    It 'Takes the learner columns from the user object, not the activity' {
        $script:AssignmentRow.UserPrincipalName | Should -BeExactly 'jane.smith@contoso.com'
        $script:AssignmentRow.UserDisplayName | Should -BeExactly 'Jane Smith'
        $script:AssignmentRow.UserId | Should -BeExactly $script:LearnerId
    }

    It 'Classifies a learningAssignment and flattens its assignment-only fields' {
        $script:AssignmentRow.ActivityType | Should -BeExactly 'Assignment'
        $script:AssignmentRow.AssignmentType | Should -BeExactly 'required'
        $script:AssignmentRow.AssignerUserId | Should -BeExactly $script:AssignerId
        $script:AssignmentRow.AssignerUserPrincipalName | Should -BeExactly 'manager@contoso.com'
        $script:AssignmentRow.DueDateTime | Should -BeExactly '2026-09-30T00:00:00.0000000'
        $script:AssignmentRow.DueDateTimeZone | Should -BeExactly 'UTC'
        $script:AssignmentRow.Notes | Should -BeExactly 'Complete before onboarding week.'
        $script:AssignmentRow.ExternalCourseActivityId | Should -BeExactly 'assign-001'
    }

    It 'Normalises timestamps and leaves a null completion blank' {
        $script:AssignmentRow.StartedDateTime | Should -BeExactly '2026-08-01T09:00:00Z'
        $script:AssignmentRow.AssignedDateTime | Should -BeExactly '2026-07-15T08:30:00Z'
        $script:AssignmentRow.CompletedDateTime | Should -BeNullOrEmpty
        $script:AssignmentRow.CompletionPercentage | Should -Be 40
    }

    It 'Joins the catalog metadata onto the row' {
        $script:AssignmentRow.LearningProviderName | Should -BeExactly 'Contoso Academy'
        $script:AssignmentRow.CourseExternalId | Should -BeExactly 'course-security-101'
        $script:AssignmentRow.CourseTitle | Should -BeExactly 'Security Awareness 101'
        $script:AssignmentRow.CourseWebUrl | Should -BeExactly 'https://learning.contoso.com/courses/security-101'
        $script:AssignmentRow.CourseDuration | Should -BeExactly 'PT1H30M'
        $script:AssignmentRow.CourseSkillTags | Should -BeExactly 'security;phishing'
        $script:AssignmentRow.CourseContributors | Should -BeExactly 'Contoso Academy'
    }

    It 'Classifies a self-initiated course and leaves the assignment columns blank' {
        $script:SelfRow.ActivityType | Should -BeExactly 'SelfInitiated'
        $script:SelfRow.Status | Should -BeExactly 'completed'
        $script:SelfRow.CompletedDateTime | Should -BeExactly '2026-08-20T16:45:00Z'
        $script:SelfRow.AssignmentType | Should -BeExactly ''
        $script:SelfRow.AssignerUserId | Should -BeExactly ''
        $script:SelfRow.AssignerUserPrincipalName | Should -BeNullOrEmpty
        $script:SelfRow.DueDateTime | Should -BeExactly ''
        $script:SelfRow.Notes | Should -BeExactly ''
    }

    It 'Exports blank Course* columns when the content could not be resolved' {
        $script:SelfRow.CourseTitle | Should -BeExactly ''
        $script:SelfRow.CourseWebUrl | Should -BeExactly ''
        $script:SelfRow.CourseSkillTags | Should -BeExactly ''
        $script:SelfRow.LearningProviderName | Should -BeNullOrEmpty
        $script:SelfRow.LearningContentId | Should -BeExactly '00000000-0000-0000-0000-00000000c999'
    }
}

Describe 'Read-LearningHistory' {

    BeforeAll {
        Mock Write-MigrationLog { }
        Mock Write-Progress { }
    }

    Context 'Users that can be read' {

        BeforeAll {
            Mock Invoke-MigrationGraphRequest {
                if ($Uri -match "/users/$($script:AssignerId)\?") { return [pscustomobject]@{ userPrincipalName = 'manager@contoso.com' } }
                if ($Uri -match "/users/$($script:LearnerId)/employeeExperience/") { return $script:ActivityPage.value }
                return @()
            }
            $script:Learner = New-TestUser
            $script:Quiet = New-TestUser -Id '00000000-0000-0000-0000-00000000a003' -UserPrincipalName 'bob.jones@contoso.com' -DisplayName 'Bob Jones'
            $script:Read = Invoke-TestRead -TargetUser @($script:Learner, $script:Quiet)
        }

        It 'Reports Succeeded with the activity count, and Skipped for a user with no history' {
            $success = @($script:Read.Results | Where-Object Identity -eq 'jane.smith@contoso.com')
            $success.Count | Should -Be 1
            $success[0].Action | Should -BeExactly 'ExportLearningHistory'
            $success[0].Status | Should -BeExactly 'Succeeded'
            $success[0].ActivityCount | Should -Be 2

            $quiet = @($script:Read.Results | Where-Object Identity -eq 'bob.jones@contoso.com')
            $quiet[0].Status | Should -BeExactly 'Skipped'
            $quiet[0].Detail | Should -BeLike 'No learner history*'
        }

        It 'Shapes one row per activity and keeps the raw objects per user' {
            $script:Read.Rows.Count | Should -Be 2
            @($script:Read.Rows | Select-Object -ExpandProperty ActivityType) | Should -Be @('Assignment', 'SelfInitiated')
            $script:Read.Rows[0].AssignerUserPrincipalName | Should -BeExactly 'manager@contoso.com'
            $script:Read.RawByUser.Count | Should -Be 1
            $script:Read.RawByUser[0].userPrincipalName | Should -BeExactly 'jane.smith@contoso.com'
            @($script:Read.RawByUser[0].activities).Count | Should -Be 2
        }

        It 'Counts an empty list as a successful cross-user read' {
            $script:Read.UsersWithActivities | Should -Be 1
            $script:Read.OtherUsersRead | Should -Be 2
            $script:Read.OtherUsersDenied | Should -Be 0
            $script:Read.DeniedUsers | Should -Be 0
        }

        It 'Counts rows whose content is in no readable catalog' {
            $script:Read.UnresolvedContent | Should -Be 1
            $script:Read.UnresolvedAssigners | Should -Be 0
        }

        It 'Sends the include-unknown-enum-members header on every activity read' {
            Should -Invoke Invoke-MigrationGraphRequest -Scope Context -ParameterFilter {
                $Uri -like '*/learningCourseActivities*' -and $Headers.Prefer -eq 'include-unknown-enum-members' -and $All
            } -Times 2 -Exactly
        }
    }

    Context 'The signed-in account' {

        It 'Is read through /me rather than /users/{id}' {
            Mock Invoke-MigrationGraphRequest { return @() }
            $null = Invoke-TestRead -TargetUser @(New-TestUser) -SignedInAccount 'jane.smith@contoso.com'
            Should -Invoke Invoke-MigrationGraphRequest -ParameterFilter { $Uri -like '/v1.0/me/*' } -Times 1 -Exactly
            Should -Invoke Invoke-MigrationGraphRequest -ParameterFilter { $Uri -like '*/users/*' } -Times 0 -Exactly
        }

        It 'Reports a /me denial as a licensing problem, not a cross-user one' {
            Mock Invoke-MigrationGraphRequest { throw $script:Forbidden }
            $read = Invoke-TestRead -TargetUser @(New-TestUser) -SignedInAccount 'jane.smith@contoso.com'
            $read.Results[0].Status | Should -BeExactly 'Failed'
            $read.Results[0].Detail | Should -BeLike '*licensed for Viva Learning*'
            $read.DeniedUsers | Should -Be 1
            $read.OtherUsersDenied | Should -Be 0
            Should -Invoke Write-MigrationLog -ParameterFilter { $Message -like 'Every cross-user read was denied*' } -Times 0 -Exactly
        }
    }

    Context 'Per-user failures' {

        It 'Maps a 403 on another user to a Failed row that names the cross-user grey area' {
            Mock Invoke-MigrationGraphRequest { throw $script:Forbidden }
            $read = Invoke-TestRead -TargetUser @(New-TestUser)
            $read.Results[0].Status | Should -BeExactly 'Failed'
            $read.Results[0].Detail | Should -BeLike '403*may not read other users*'
            $read.DeniedUsers | Should -Be 1
            $read.OtherUsersDenied | Should -Be 1
            $read.OtherUsersRead | Should -Be 0
        }

        It 'Maps a 404 to Skipped because the user has no employee experience surface' {
            Mock Invoke-MigrationGraphRequest { throw $script:NotFound }
            $read = Invoke-TestRead -TargetUser @(New-TestUser)
            $read.Results[0].Status | Should -BeExactly 'Skipped'
            $read.Results[0].Detail | Should -BeLike '*404*'
            $read.DeniedUsers | Should -Be 0
        }

        It 'Maps any other failure to a Failed row carrying the status and message' {
            Mock Invoke-MigrationGraphRequest { throw $script:ServerError }
            $read = Invoke-TestRead -TargetUser @(New-TestUser)
            $read.Results[0].Status | Should -BeExactly 'Failed'
            $read.Results[0].Detail | Should -BeLike 'HTTP 500 - *'
            Should -Invoke Write-MigrationLog -ParameterFilter { $Level -eq 'ERROR' -and $Message -like '*[[]Failed]*' } -Times 1 -Exactly
        }
    }

    Context 'The cross-user denial guidance' {

        It 'Is shown for a single denied user - one user is enough to prove the token cannot read others' {
            Mock Invoke-MigrationGraphRequest { throw $script:Forbidden }
            $null = Invoke-TestRead -TargetUser @(New-TestUser)
            Should -Invoke Write-MigrationLog -ParameterFilter { $Message -like 'Every cross-user read was denied (403 x 1)*' } -Times 1 -Exactly
            Should -Invoke Write-MigrationLog -ParameterFilter { $Message -like '*Download learner completion records*' } -Times 1 -Exactly
        }

        It 'Is still shown when the admin''s own /me read returned history' {
            $admin = New-TestUser -Id '00000000-0000-0000-0000-00000000a0ad' -UserPrincipalName 'admin@contoso.com' -DisplayName 'Admin'
            Mock Invoke-MigrationGraphRequest {
                if ($Uri -like '/v1.0/me/*') { return @($script:SelfInitiated) }
                throw $script:Forbidden
            }
            $read = Invoke-TestRead -TargetUser @($admin, (New-TestUser)) -SignedInAccount 'admin@contoso.com'
            $read.UsersWithActivities | Should -Be 1
            $read.OtherUsersRead | Should -Be 0
            $read.OtherUsersDenied | Should -Be 1
            Should -Invoke Write-MigrationLog -ParameterFilter { $Message -like 'Every cross-user read was denied*' } -Times 1 -Exactly
        }

        It 'Is not shown when at least one other user could be read' {
            Mock Invoke-MigrationGraphRequest {
                if ($Uri -match "/users/$($script:LearnerId)/") { return @() }
                throw $script:Forbidden
            }
            $restricted = New-TestUser -Id '00000000-0000-0000-0000-00000000a003' -UserPrincipalName 'bob.jones@contoso.com'
            $read = Invoke-TestRead -TargetUser @((New-TestUser), $restricted)
            $read.OtherUsersRead | Should -Be 1
            $read.OtherUsersDenied | Should -Be 1
            Should -Invoke Write-MigrationLog -ParameterFilter { $Message -like 'Every cross-user read was denied*' } -Times 0 -Exactly
        }
    }

    Context 'The circuit breaker' {

        It 'Stops after the consecutive-denial limit and marks the remaining users Skipped' {
            Mock Invoke-MigrationGraphRequest { throw $script:Forbidden }
            $read = Invoke-TestRead -TargetUser (New-TestUserSet -Count 15)

            Should -Invoke Invoke-MigrationGraphRequest -Times 10 -Exactly
            $read.Results.Count | Should -Be 15
            @($read.Results | Where-Object Status -eq 'Failed').Count | Should -Be 10
            $skipped = @($read.Results | Where-Object Status -eq 'Skipped')
            $skipped.Count | Should -Be 5
            $skipped[0].Identity | Should -BeExactly 'user11@contoso.com'
            $skipped[-1].Identity | Should -BeExactly 'user15@contoso.com'
            $skipped | ForEach-Object { $_.Detail | Should -BeExactly 'Not attempted - cross-user reads are being denied.' }
            $read.OtherUsersDenied | Should -Be 10
        }

        It 'Logs the guidance once when it trips, not again at the end of the run' {
            Mock Invoke-MigrationGraphRequest { throw $script:Forbidden }
            $null = Invoke-TestRead -TargetUser (New-TestUserSet -Count 12)
            Should -Invoke Write-MigrationLog -ParameterFilter { $Level -eq 'ERROR' -and $Message -like '10 consecutive cross-user reads were denied*2 user(s)*' } -Times 1 -Exactly
            Should -Invoke Write-MigrationLog -ParameterFilter { $Message -like 'Every cross-user read was denied*' } -Times 0 -Exactly
            Should -Invoke Write-MigrationLog -ParameterFilter { $Message -like '*Download learner completion records*' } -Times 1 -Exactly
        }

        It 'Honours a custom limit' {
            Mock Invoke-MigrationGraphRequest { throw $script:Forbidden }
            $read = Invoke-TestRead -TargetUser (New-TestUserSet -Count 6) -CrossUserDenialLimit 2
            Should -Invoke Invoke-MigrationGraphRequest -Times 2 -Exactly
            @($read.Results | Where-Object Status -eq 'Skipped').Count | Should -Be 4
        }

        It 'Resets on any successful cross-user read, so scattered restricted accounts do not trip it' {
            Mock Invoke-MigrationGraphRequest {
                if ($Uri -match '/users/00000000-0000-0000-0000-0000000000(03|06)/') { return @() }
                throw $script:Forbidden
            }
            $read = Invoke-TestRead -TargetUser (New-TestUserSet -Count 8) -CrossUserDenialLimit 3

            Should -Invoke Invoke-MigrationGraphRequest -Times 8 -Exactly
            @($read.Results | Where-Object Detail -like 'Not attempted*').Count | Should -Be 0
            $read.OtherUsersRead | Should -Be 2
            $read.OtherUsersDenied | Should -Be 6
        }

        It 'Does not trip when the limit is reached on the last user - there is nothing left to skip' {
            Mock Invoke-MigrationGraphRequest { throw $script:Forbidden }
            $read = Invoke-TestRead -TargetUser (New-TestUserSet -Count 10)
            Should -Invoke Invoke-MigrationGraphRequest -Times 10 -Exactly
            @($read.Results | Where-Object Status -eq 'Skipped').Count | Should -Be 0
            Should -Invoke Write-MigrationLog -ParameterFilter { $Message -like 'Every cross-user read was denied (403 x 10)*' } -Times 1 -Exactly
        }
    }

    Context 'Assigner resolution inside the loop' {

        It 'Looks an assigner up once for all of their activities and counts a non-404 failure' {
            Mock Invoke-MigrationGraphRequest {
                if ($Uri -match "/users/$($script:AssignerId)\?") { throw $script:Forbidden }
                return @($script:Assignment, $script:Assignment)
            }
            $read = Invoke-TestRead -TargetUser @(New-TestUser)

            $read.Rows.Count | Should -Be 2
            $read.Rows | ForEach-Object { $_.AssignerUserPrincipalName | Should -BeNullOrEmpty }
            $read.Rows | ForEach-Object { $_.AssignerUserId | Should -BeExactly $script:AssignerId }
            $read.UnresolvedAssigners | Should -Be 1
            Should -Invoke Invoke-MigrationGraphRequest -ParameterFilter { $Uri -match "/users/$($script:AssignerId)\?" } -Times 1 -Exactly
            Should -Invoke Write-MigrationLog -ParameterFilter { $Level -eq 'WARNING' -and $Message -like '*Could not resolve assigner*' } -Times 1 -Exactly
        }

        It 'Treats a deleted assigner as expected: blank UPN, nothing counted, nothing warned' {
            Mock Invoke-MigrationGraphRequest {
                if ($Uri -match "/users/$($script:AssignerId)\?") { throw $script:NotFound }
                return @($script:Assignment)
            }
            $read = Invoke-TestRead -TargetUser @(New-TestUser)

            $read.Rows[0].AssignerUserPrincipalName | Should -BeNullOrEmpty
            $read.UnresolvedAssigners | Should -Be 0
            Should -Invoke Write-MigrationLog -ParameterFilter { $Level -eq 'WARNING' -and $Message -like '*Could not resolve assigner*' } -Times 0 -Exactly
        }
    }

    It 'Returns empty collections and zero counters for an empty user list' {
        Mock Invoke-MigrationGraphRequest { throw 'must not be called' }
        $read = Invoke-TestRead -TargetUser @()
        $read.Rows.Count | Should -Be 0
        $read.Results.Count | Should -Be 0
        $read.OtherUsersDenied | Should -Be 0
        Should -Invoke Invoke-MigrationGraphRequest -Times 0 -Exactly
    }
}

Describe 'Script structure' {

    BeforeAll {
        $commandPredicate = { param($node) $node -is [System.Management.Automation.Language.CommandAst] }
        $script:AllCommandNames = @($script:Ast.FindAll($commandPredicate, $true) | ForEach-Object { $_.GetCommandName() })

        $ifPredicate = { param($node) $node -is [System.Management.Automation.Language.IfStatementAst] }
        $script:DryRunIf = @($script:Ast.FindAll($ifPredicate, $true) | Where-Object { $_.Clauses[0].Item1.Extent.Text -eq '$DryRun' })[0]
    }

    It 'Requests only the learning scopes that exist as delegated permissions' {
        $assignment = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$requiredGraphScopes'
            }, $true)
        $assignment | Should -Not -BeNullOrEmpty

        # The right-hand side appends $metadataScopes; evaluate it with that empty so only the
        # learning scopes are under test.
        $evaluate = [scriptblock]::Create('param([string[]]$metadataScopes) ' + $assignment.Right.Extent.Text)
        $scopes = @(& $evaluate @())
        $scopes | Should -Be @('LearningAssignedCourse.Read', 'LearningSelfInitiatedCourse.Read', 'User.Read.All')
        $script:AllCommandNames | Should -Not -Contain 'Connect-VivaLearningGraph'
    }

    It 'Never reaches Graph under -DryRun, as the help promises' {
        $script:DryRunIf | Should -Not -BeNullOrEmpty
        $commandPredicate = { param($node) $node -is [System.Management.Automation.Language.CommandAst] }
        $dryRunCommands = @($script:DryRunIf.Clauses[0].Item2.FindAll($commandPredicate, $true) | ForEach-Object { $_.GetCommandName() })
        $dryRunCommands | Should -Not -Contain 'Connect-MigrationGraph'
        $dryRunCommands | Should -Not -Contain 'Invoke-MigrationGraphRequest'
        $dryRunCommands | Should -Not -Contain 'Read-LearningHistory'
        $dryRunCommands | Should -Contain 'Add-LearningResultRow'

        $liveCommands = @($script:DryRunIf.ElseClause.FindAll($commandPredicate, $true) | ForEach-Object { $_.GetCommandName() })
        $liveCommands | Should -Contain 'Connect-MigrationGraph'
    }

    It 'Leaves the Graph session open because callers own connections' {
        $script:AllCommandNames | Should -Not -Contain 'Disconnect-MgGraph'
    }

    It 'Writes the export only through Invoke-MigrationAction' {
        $writers = @($script:Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('Export-Csv', 'Set-Content')
                }, $true))
        $writers.Count | Should -Be 2
        foreach ($writer in $writers) {
            $wrapped = $false
            $parent = $writer.Parent
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.CommandAst] -and $parent.GetCommandName() -eq 'Invoke-MigrationAction') {
                    $wrapped = $true
                    break
                }
                $parent = $parent.Parent
            }
            $wrapped | Should -BeTrue -Because "$($writer.GetCommandName()) at line $($writer.Extent.StartLineNumber) must be wrapped"
        }
    }
}
