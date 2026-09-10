#Requires -Version 7.4

<#
    Offline tests for Import-MigrationVivaLearningHistory.ps1.

    The same two techniques as the other writer tests, chosen because they work in Pester 6
    without modifying the script under test:

    1. The script's own functions are loaded by parsing it and dot-sourcing only its
       FunctionDefinitionAst nodes. Dot-sourcing the whole .ps1 would run its Main region
       (and its 'exit'); parsing it gives the same functions with none of the side effects.

    2. The end-to-end runs invoke the script with the call operator and shadow every
       tenant-facing command with a plain function defined in BeforeAll: the toolkit's
       Graph wrappers, the Microsoft.Graph.Authentication cmdlets the app-only phase calls
       directly, Initialize-MigrationModule (which would otherwise try to install
       Microsoft.Graph.Authentication offline) and Read-Host (so a prompt shows up as a
       counter, not a hung test). PowerShell resolves a command from the innermost scope
       outwards, so a function defined here wins over the module's exported function of the
       same name for anything the script calls - including a scriptblock the script hands to
       Invoke-MigrationAction. That keeps the real module (logging, run context, results
       export, DryRun gating) in the test rather than mocking the thing being tested. 'exit'
       inside a script invoked with '&' ends that script only, so the run's exit code is
       readable from $LASTEXITCODE and Pester carries on.

    Call logs live in $global: because a function defined in BeforeAll does not share the
    $script: scope Pester gives the It blocks.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The call logs must be reachable from the stub functions defined in BeforeAll, and a function defined there does not share the $script: scope Pester gives the It blocks. $global: is the only scope both sides can see.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script passes, including ones a particular test does not assert on; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'These are stand-ins for Graph cmdlets whose names the script under test calls. They exist to record that a call happened and change nothing, so ShouldProcess would be meaningless.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The client secret is a placeholder handed to a stubbed Connect-MgGraph; no real credential exists in this test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Read-Host is shadowed on purpose so a logo or domain prompt in the script under test shows up as a counter the tests assert on, instead of a hung test run.')]
param()

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1'
    Import-Module $script:moduleRoot -Force

    $script:scriptPath = Join-Path $PSScriptRoot '..' 'Import-MigrationVivaLearningHistory.ps1'
    $script:fixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'Import-MigrationVivaLearningHistory'

    # --- Technique 1: load the script's functions without running its Main region ---------
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw "Import-MigrationVivaLearningHistory.ps1 failed to parse: $($parseErrors[0].Message)" }
    $functionText = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
            ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    . ([scriptblock]::Create($functionText))

    # --- Technique 2: stubs for everything that would reach a tenant ----------------------
    $global:vivaGraphCalls = [System.Collections.Generic.List[object]]::new()
    $global:vivaMutations = [System.Collections.Generic.List[string]]::new()
    $global:vivaDelegatedScopes = @()
    $global:vivaAppConnects = 0
    $global:vivaReadHostCalls = 0

    # What the provider list returns and which activity external IDs already exist; each
    # end-to-end Describe sets these to build its scenario.
    $global:vivaProviders = @()
    $global:vivaExistingActivityIds = @()

    # Destination directory: pat.moore is deliberately absent so an assigner lookup 404s.
    $global:vivaKnownUsers = @{
        'john.smith@newco.com'  = 'user-john'
        'bob.jones@newco.com'   = 'user-bob'
        'alice.dean@newco.com'  = 'user-alice'
        'chris.white@newco.com' = 'user-chris'
    }

    function Initialize-MigrationModule {
        param([string[]]$Name, [string]$MinimumVersion)
    }

    function Connect-MigrationGraph {
        param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
        $global:vivaDelegatedScopes = @($Scopes)
        return [pscustomobject]@{ TenantId = $TenantId; Account = 'admin@newco.onmicrosoft.com' }
    }

    function Connect-MgGraph {
        param([string]$TenantId, [string]$ClientId, [string]$CertificateThumbprint,
            [pscredential]$ClientSecretCredential, [switch]$NoWelcome, [string]$ErrorAction)
        $global:vivaAppConnects++
    }

    function Get-MgContext {
        return [pscustomobject]@{ TenantId = '00000000-0000-0000-0000-000000000000' }
    }

    function Disconnect-MgGraph {
        param([string]$ErrorAction)
    }

    function Read-Host {
        param([string]$Prompt)
        $global:vivaReadHostCalls++
        return ''
    }

    function Invoke-MigrationGraphRequest {
        param([string]$Method, [string]$Uri, $Body, [hashtable]$Headers, [switch]$All, [int]$MaxRetry = 5)
        $global:vivaGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
        if ($Method -ne 'GET') { $global:vivaMutations.Add("$Method $Uri") }

        if ($Method -eq 'GET' -and $Uri -eq '/v1.0/employeeExperience/learningProviders') {
            return $global:vivaProviders
        }

        if ($Method -eq 'GET' -and $Uri -like '/v1.0/users/*') {
            $upn = [uri]::UnescapeDataString((($Uri -replace '^/v1.0/users/', '') -split '\?')[0])
            if ($upn -eq 'forbidden@newco.com') {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            if ($global:vivaKnownUsers.ContainsKey($upn)) {
                return [pscustomobject]@{ id = $global:vivaKnownUsers[$upn] }
            }
            throw "Response status code does not indicate success: 404 (NotFound). User '$upn' does not exist."
        }

        if ($Method -eq 'PATCH' -and $Uri -like '*/learningContents(externalId=*') {
            $key = if ($Uri -match "externalId='([^']+)'") { [uri]::UnescapeDataString($Matches[1]) } else { 'unknown' }
            return [pscustomobject]@{ id = "content-$key" }
        }

        if ($Method -eq 'GET' -and $Uri -like '*/learningCourseActivities(externalCourseActivityId=*') {
            $activityId = if ($Uri -match "externalCourseActivityId='([^']+)'") { [uri]::UnescapeDataString($Matches[1]) } else { '' }
            if ($global:vivaExistingActivityIds -contains $activityId) {
                return [pscustomobject]@{ id = "existing-$activityId" }
            }
            throw "Response status code does not indicate success: 404 (NotFound). Activity '$activityId' does not exist."
        }

        if ($Method -eq 'POST' -and $Uri -like '*/learningCourseActivities') {
            if ($Body['learnerUserId'] -eq 'user-chris') {
                # The wording Graph uses for an unlicensed learner, which the script classifies.
                throw "Response status code does not indicate success: 403 (Forbidden). The user license isn't valid for this request."
            }
            return $null
        }

        if ($Method -eq 'POST' -and $Uri -eq '/v1.0/employeeExperience/learningProviders') {
            return [pscustomobject]@{ id = 'provider-registered' }
        }

        return $null
    }

    # --- Shared fixtures ------------------------------------------------------------------
    $script:tenantId = '00000000-0000-0000-0000-000000000000'
    $script:clientId = '11111111-1111-1111-1111-111111111111'
    $script:clientSecret = ConvertTo-SecureString -String 'placeholder-secret' -AsPlainText -Force

    function script:New-VivaWorkspace {
        param([string]$Label)
        $workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Viva-$Label-$([guid]::NewGuid())"
        New-Item -Path $workspace -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination (Join-Path $workspace 'IdentityPlan.csv')
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'VivaLearningHistory.csv') -Destination (Join-Path $workspace 'VivaLearningHistory.csv')
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'VivaLearningHistory-Invalid.csv') -Destination (Join-Path $workspace 'VivaLearningHistory-Invalid.csv')
        return $workspace
    }

    function script:Reset-VivaCallLog {
        $global:vivaGraphCalls.Clear()
        $global:vivaMutations.Clear()
        $global:vivaDelegatedScopes = @()
        $global:vivaAppConnects = 0
        $global:vivaReadHostCalls = 0
    }

    function script:Get-VivaLogText {
        param([string]$Workspace)
        $log = @(Get-ChildItem -LiteralPath $Workspace -Filter 'Import-MigrationVivaLearningHistory_*.log')
        if ($log.Count -ne 1) { return '' }
        return Get-Content -LiteralPath $log[0].FullName -Raw
    }
}

AfterAll {
    Remove-Variable -Name vivaGraphCalls, vivaMutations, vivaDelegatedScopes, vivaAppConnects, vivaReadHostCalls,
    vivaProviders, vivaExistingActivityIds, vivaKnownUsers -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Import-MigrationVivaLearningHistory - ConvertTo-TargetUpn' {

    BeforeAll {
        $script:planMap = @{ 'jsmith@contoso.com' = 'john.smith@newco.com' }
    }

    It 'Lets an explicit TargetUserPrincipalName on the row win over everything' {
        ConvertTo-TargetUpn -SourceUpn 'jsmith@contoso.com' -OverrideUpn 'override@newco.com' -PlanMap $script:planMap -Domain 'other.com' |
            Should -BeExactly 'override@newco.com'
    }

    It 'Maps through the identity plan case-insensitively' {
        ConvertTo-TargetUpn -SourceUpn 'JSmith@Contoso.com' -PlanMap $script:planMap | Should -BeExactly 'john.smith@newco.com'
    }

    It 'Falls back to -TargetDomain for a source the plan does not cover' {
        ConvertTo-TargetUpn -SourceUpn 'bjones@contoso.com' -PlanMap $script:planMap -Domain 'newco.com' | Should -BeExactly 'bjones@newco.com'
    }

    It 'Keeps the CSV address with -KeepCsvDomains' {
        ConvertTo-TargetUpn -SourceUpn 'bjones@contoso.com' -Domain 'newco.com' -KeepDomains $true | Should -BeExactly 'bjones@contoso.com'
    }

    It 'Returns nothing when only a plan was given and it has no entry' {
        ConvertTo-TargetUpn -SourceUpn 'bjones@contoso.com' -PlanMap $script:planMap | Should -BeNullOrEmpty
    }

    It 'Leaves the address alone when no mapping at all was configured' {
        ConvertTo-TargetUpn -SourceUpn 'bjones@contoso.com' | Should -BeExactly 'bjones@contoso.com'
    }
}

Describe 'Import-MigrationVivaLearningHistory - Get-NormalizedStatus' {

    It 'Normalises the export casing and spacing to the courseStatus enum' {
        Get-NormalizedStatus -Value 'Not Started' | Should -BeExactly 'notStarted'
        Get-NormalizedStatus -Value 'notstarted' | Should -BeExactly 'notStarted'
        Get-NormalizedStatus -Value ' In Progress ' | Should -BeExactly 'inProgress'
        Get-NormalizedStatus -Value 'Complete' | Should -BeExactly 'completed'
        Get-NormalizedStatus -Value 'completed' | Should -BeExactly 'completed'
    }

    It 'Rejects a value it does not recognise instead of guessing' {
        Get-NormalizedStatus -Value 'Done' | Should -BeNullOrEmpty
        Get-NormalizedStatus -Value '' | Should -BeNullOrEmpty
    }
}

Describe 'Import-MigrationVivaLearningHistory - Resolve-ColumnName' {

    It 'Returns the header as spelled in the file, matched case-insensitively' {
        Resolve-ColumnName -Headers @('userprincipalname', 'CourseTitle') -Candidates @('UserPrincipalName', 'UPN') |
            Should -BeExactly 'userprincipalname'
    }

    It 'Prefers the earliest candidate that exists' {
        Resolve-ColumnName -Headers @('Email', 'UserPrincipalName') -Candidates @('UserPrincipalName', 'UPN', 'Email') |
            Should -BeExactly 'UserPrincipalName'
    }

    It 'Returns nothing when no candidate is present' {
        Resolve-ColumnName -Headers @('Foo') -Candidates @('UserPrincipalName') | Should -BeNullOrEmpty
    }
}

Describe 'Import-MigrationVivaLearningHistory - ConvertTo-GraphKeyLiteral' {

    It 'Doubles single quotes, then percent-encodes everything for an OData key literal' {
        # Graph decodes the escape before parsing the literal, so %27%27 arrives as ''.
        ConvertTo-GraphKeyLiteral -Value "it's here" | Should -BeExactly 'it%27%27s%20here'
    }

    It 'Encodes a URL used as a content key' {
        ConvertTo-GraphKeyLiteral -Value 'https://learn.contoso.com/a?b=1' | Should -BeExactly 'https%3A%2F%2Flearn.contoso.com%2Fa%3Fb%3D1'
    }
}

Describe 'Import-MigrationVivaLearningHistory - Resolve-TargetUserId' {

    BeforeAll {
        $script:UserIdByUpn = @{}
        Reset-VivaCallLog
    }

    It 'Resolves a known user and serves repeat lookups from the cache' {
        Resolve-TargetUserId -Upn 'john.smith@newco.com' | Should -BeExactly 'user-john'
        Resolve-TargetUserId -Upn 'john.smith@newco.com' | Should -BeExactly 'user-john'
        @($global:vivaGraphCalls | Where-Object { $_.Uri -like '/v1.0/users/john.smith*' }).Count | Should -Be 1
    }

    It 'Caches a genuine 404 as not-found without retrying' {
        Resolve-TargetUserId -Upn 'pat.moore@newco.com' | Should -BeFalse
        Resolve-TargetUserId -Upn 'pat.moore@newco.com' | Should -BeFalse
        @($global:vivaGraphCalls | Where-Object { $_.Uri -like '/v1.0/users/pat.moore*' }).Count | Should -Be 1
    }

    It 'Surfaces anything other than a 404 rather than caching a phantom missing user' {
        { Resolve-TargetUserId -Upn 'forbidden@newco.com' } | Should -Throw -ExpectedMessage '*403*'
        $script:UserIdByUpn.ContainsKey('forbidden@newco.com') | Should -BeFalse
    }
}

Describe 'Import-MigrationVivaLearningHistory - DryRun with a provider that does not exist yet' {

    BeforeAll {
        $script:dryWorkspace = New-VivaWorkspace -Label 'DryRun'
        Reset-VivaCallLog
        $global:vivaProviders = @()
        $global:vivaExistingActivityIds = @()

        # No -LogoUrl and no -Confirm:$false on purpose: a rehearsal must neither prompt for
        # a logo it never sends nor raise a High-impact confirmation for a registration it
        # never performs. Example 1 in the script's help is exactly this shape.
        & $script:scriptPath -CsvPath (Join-Path $script:dryWorkspace 'VivaLearningHistory.csv') `
            -TenantId $script:tenantId -ClientId $script:clientId -ClientSecret $script:clientSecret `
            -PlanPath (Join-Path $script:dryWorkspace 'IdentityPlan.csv') `
            -OutputPath $script:dryWorkspace -Verbosity Low -DryRun
        $script:dryExitCode = $LASTEXITCODE

        $script:dryFile = @(Get-ChildItem -LiteralPath $script:dryWorkspace -Filter 'Import-VivaLearningHistory-DryRun_*.csv')
        $script:dryRows = if ($script:dryFile.Count -eq 1) { @(Import-Csv -LiteralPath $script:dryFile[0].FullName) } else { @() }
        $script:dryLog = Get-VivaLogText -Workspace $script:dryWorkspace
    }

    AfterAll {
        if ($script:dryWorkspace -and (Test-Path -LiteralPath $script:dryWorkspace)) {
            Remove-Item -LiteralPath $script:dryWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits successfully' {
        $script:dryExitCode | Should -Be 0
    }

    It 'Writes exactly one DryRun results file and no Results file' {
        $script:dryFile.Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:dryWorkspace -Filter 'Import-VivaLearningHistory-Results_*.csv').Count | Should -Be 0
    }

    It 'Makes no write call of any kind' {
        $global:vivaMutations | Should -BeNullOrEmpty
    }

    It 'Never prompts for a logo URL' {
        $global:vivaReadHostCalls | Should -Be 0
    }

    It 'Signs in with the read-only provider scope' {
        $global:vivaDelegatedScopes | Should -Be @('LearningProvider.Read')
    }

    It 'Logs the registration as an intent rather than a decline' {
        $script:dryLog | Should -Match 'Would: Register learning provider'
        $script:dryLog | Should -Not -Match '\[SKIPPED\]'
    }

    It 'Still connects app-only and resolves every learner read-only' {
        $global:vivaAppConnects | Should -Be 1
        @($global:vivaGraphCalls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -like '/v1.0/users/*' }).Count | Should -BeGreaterThan 0
    }

    It 'Reports every row as Planned' {
        $script:dryRows.Count | Should -Be 6
        @($script:dryRows | Where-Object { $_.Status -ne 'Planned' }).Count | Should -Be 0
    }

    It 'Starts every results row with Identity, Action, Status, Detail' {
        @($script:dryRows[0].PSObject.Properties.Name)[0..3] | Should -Be @('Identity', 'Action', 'Status', 'Detail')
    }

    It 'Maps learners through the identity plan and says what it would create' {
        $row = @($script:dryRows | Where-Object { $_.Identity -eq 'john.smith@newco.com' -and $_.ActivityType -eq 'Assignment' })[0]
        $row.SourceUserPrincipalName | Should -BeExactly 'jsmith@contoso.com'
        $row.Detail | Should -Match "Would create Assignment 'Security Awareness 101' for john.smith@newco.com"
    }
}

Describe 'Import-MigrationVivaLearningHistory - DryRun with an existing provider whose sync is off' {

    BeforeAll {
        $script:syncWorkspace = New-VivaWorkspace -Label 'DryRunSync'
        Reset-VivaCallLog
        $global:vivaProviders = @(
            [pscustomobject]@{ id = 'provider-existing'; displayName = 'Imported Learning History'; isCourseActivitySyncEnabled = $false }
        )
        $global:vivaExistingActivityIds = @()

        & $script:scriptPath -CsvPath (Join-Path $script:syncWorkspace 'VivaLearningHistory.csv') `
            -TenantId $script:tenantId -ClientId $script:clientId -ClientSecret $script:clientSecret `
            -PlanPath (Join-Path $script:syncWorkspace 'IdentityPlan.csv') `
            -OutputPath $script:syncWorkspace -Verbosity Low -DryRun
        $script:syncExitCode = $LASTEXITCODE
        $script:syncLog = Get-VivaLogText -Workspace $script:syncWorkspace
    }

    AfterAll {
        if ($script:syncWorkspace -and (Test-Path -LiteralPath $script:syncWorkspace)) {
            Remove-Item -LiteralPath $script:syncWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits successfully without a confirmation prompt' {
        $script:syncExitCode | Should -Be 0
    }

    It 'Logs the sync enable as an intent and sends no PATCH' {
        $script:syncLog | Should -Match 'Would: Enable course-activity sync'
        $global:vivaMutations | Should -BeNullOrEmpty
    }

    It 'Reuses the provider it found by display name' {
        $script:syncLog | Should -Match "Reusing existing provider 'Imported Learning History' \[provider-existing\]"
    }
}

Describe 'Import-MigrationVivaLearningHistory - a declined provider registration is a Skip, not a Plan' {

    BeforeAll {
        $script:whatIfWorkspace = New-VivaWorkspace -Label 'WhatIf'
        Reset-VivaCallLog
        $global:vivaProviders = @()
        $global:vivaExistingActivityIds = @()

        # -WhatIf answers No to the ConfirmImpact=High registration; -LogoUrl is supplied
        # because a real run (which -WhatIf is a preview of) requires one.
        & $script:scriptPath -CsvPath (Join-Path $script:whatIfWorkspace 'VivaLearningHistory.csv') `
            -TenantId $script:tenantId -ClientId $script:clientId -ClientSecret $script:clientSecret `
            -PlanPath (Join-Path $script:whatIfWorkspace 'IdentityPlan.csv') -LogoUrl 'https://www.example.com/logo.png' `
            -OutputPath $script:whatIfWorkspace -Verbosity Low -WhatIf
        $script:whatIfExitCode = $LASTEXITCODE

        $script:whatIfFile = @(Get-ChildItem -LiteralPath $script:whatIfWorkspace -Filter 'Import-VivaLearningHistory-Results_*.csv')
        $script:whatIfRows = if ($script:whatIfFile.Count -eq 1) { @(Import-Csv -LiteralPath $script:whatIfFile[0].FullName) } else { @() }
        $script:whatIfLog = Get-VivaLogText -Workspace $script:whatIfWorkspace
    }

    AfterAll {
        if ($script:whatIfWorkspace -and (Test-Path -LiteralPath $script:whatIfWorkspace)) {
            Remove-Item -LiteralPath $script:whatIfWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Writes a Results file, not a DryRun file, because -WhatIf is not a rehearsal' {
        $script:whatIfFile.Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:whatIfWorkspace -Filter 'Import-VivaLearningHistory-DryRun_*.csv').Count | Should -Be 0
    }

    It 'Requests the write scope, since only the confirmation was declined' {
        $global:vivaDelegatedScopes | Should -Be @('LearningProvider.ReadWrite')
    }

    It 'Makes no write call of any kind' {
        $global:vivaMutations | Should -BeNullOrEmpty
    }

    It 'Reports every row as Skipped, naming the declined registration' {
        $script:whatIfRows.Count | Should -Be 6
        @($script:whatIfRows | Where-Object { $_.Status -ne 'Skipped' }).Count | Should -Be 0
        @($script:whatIfRows | Where-Object { $_.Detail -notmatch 'Provider registration was declined' }).Count | Should -Be 0
    }

    It 'Leaves no row claiming an outcome the tenant never saw' {
        @($script:whatIfRows | Where-Object { $_.Status -in @('Planned', 'Succeeded') }).Count | Should -Be 0
    }

    It 'Writes no DRYRUN lines to the log' {
        $script:whatIfLog | Should -Not -Match '\[DRYRUN\]'
        $script:whatIfLog | Should -Match '\[SKIPPED\] Provider registration was declined'
    }

    It 'Exits successfully' {
        $script:whatIfExitCode | Should -Be 0
    }
}

Describe 'Import-MigrationVivaLearningHistory - unattended import under a supplied provider' {

    BeforeAll {
        $script:liveWorkspace = New-VivaWorkspace -Label 'Live'
        Reset-VivaCallLog
        $global:vivaProviders = @()
        $global:vivaExistingActivityIds = @('act-005')

        & $script:scriptPath -CsvPath (Join-Path $script:liveWorkspace 'VivaLearningHistory.csv') `
            -TenantId $script:tenantId -ClientId $script:clientId -ClientSecret $script:clientSecret `
            -PlanPath (Join-Path $script:liveWorkspace 'IdentityPlan.csv') -LearningProviderId 'provider-existing' `
            -OutputPath $script:liveWorkspace -Verbosity Low -Confirm:$false
        $script:liveExitCode = $LASTEXITCODE

        $script:liveFile = @(Get-ChildItem -LiteralPath $script:liveWorkspace -Filter 'Import-VivaLearningHistory-Results_*.csv')
        $script:liveRows = if ($script:liveFile.Count -eq 1) { @(Import-Csv -LiteralPath $script:liveFile[0].FullName) } else { @() }
        $script:activityPosts = @($global:vivaGraphCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/learningCourseActivities' })

        function script:Get-LiveRow {
            param([string]$Identity, [string]$ActivityType, [string]$CourseTitle)
            return @($script:liveRows | Where-Object {
                    $_.Identity -eq $Identity -and $_.ActivityType -eq $ActivityType -and $_.CourseTitle -eq $CourseTitle
                })[0]
        }

        function script:Get-ActivityBody {
            param([string]$ExternalId)
            return @($script:activityPosts | Where-Object { $_.Body['externalCourseActivityId'] -eq $ExternalId })[0].Body
        }
    }

    AfterAll {
        if ($script:liveWorkspace -and (Test-Path -LiteralPath $script:liveWorkspace)) {
            Remove-Item -LiteralPath $script:liveWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits 2 because one learner is unlicensed' {
        $script:liveExitCode | Should -Be 2
    }

    It 'Never signs in interactively when a provider id is supplied' {
        $global:vivaDelegatedScopes | Should -BeNullOrEmpty
        $global:vivaAppConnects | Should -Be 1
    }

    It 'Upserts each distinct course exactly once under the supplied provider' {
        $patches = @($global:vivaMutations | Where-Object { $_ -like 'PATCH */learningProviders/provider-existing/learningContents(externalId=*' })
        $patches.Count | Should -Be 2
    }

    It 'Creates an assignment with its assigner mapped through the plan' {
        $body = Get-ActivityBody -ExternalId 'act-001'
        $body['@odata.type'] | Should -BeExactly '#microsoft.graph.learningAssignment'
        $body['assignerUserId'] | Should -BeExactly 'user-alice'
        $body['assignmentType'] | Should -BeExactly 'required'
        $body['completionPercentage'] | Should -Be 100
        $body['learningContentId'] | Should -BeExactly 'content-course-001'
        $body['dueDateTime'].timeZone | Should -BeExactly 'UTC'
        $row = Get-LiveRow -Identity 'john.smith@newco.com' -ActivityType 'Assignment' -CourseTitle 'Security Awareness 101'
        $row.Status | Should -BeExactly 'Succeeded'
        $row.Detail | Should -Not -Match 'Assigner'
    }

    It 'Records an assigner the plan cannot map instead of dropping it silently' {
        $body = Get-ActivityBody -ExternalId 'act-003'
        $body.Contains('assignerUserId') | Should -BeFalse
        $row = Get-LiveRow -Identity 'bob.jones@newco.com' -ActivityType 'Assignment' -CourseTitle 'Security Awareness 101'
        $row.Status | Should -BeExactly 'Succeeded'
        $row.Detail | Should -Match "Assigner 'ghost@contoso.com' could not be mapped to the destination"
    }

    It 'Records an assigner missing from the destination, alongside a dropped percentage' {
        $body = Get-ActivityBody -ExternalId 'act-004'
        $body.Contains('assignerUserId') | Should -BeFalse
        $body.Contains('completionPercentage') | Should -BeFalse
        $row = Get-LiveRow -Identity 'bob.jones@newco.com' -ActivityType 'Assignment' -CourseTitle 'PowerShell Fundamentals'
        $row.Status | Should -BeExactly 'Succeeded'
        $row.Detail | Should -Match "Assigner 'pat.moore@newco.com' was not found in the destination tenant"
        $row.Detail | Should -Match "CompletionPercentage 'lots' was not numeric"
    }

    It 'Imports a Recommendation row as a recommended assignment' {
        $body = Get-ActivityBody -ExternalId 'act-004'
        $body['@odata.type'] | Should -BeExactly '#microsoft.graph.learningAssignment'
        $body['assignmentType'] | Should -BeExactly 'recommended'
    }

    It 'Skips an activity whose external id already exists under the provider' {
        $row = Get-LiveRow -Identity 'john.smith@newco.com' -ActivityType 'SelfInitiated' -CourseTitle 'Security Awareness 101'
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'already exists'
        @($script:activityPosts | Where-Object { $_.Body['externalCourseActivityId'] -eq 'act-005' }).Count | Should -Be 0
    }

    It 'Normalises the CSV status and percentage before sending them' {
        $body = Get-ActivityBody -ExternalId 'act-002'
        $body['@odata.type'] | Should -BeExactly '#microsoft.graph.learningSelfInitiatedCourse'
        $body['status'] | Should -BeExactly 'inProgress'
        $body['completionPercentage'] | Should -Be 45
        (Get-ActivityBody -ExternalId 'act-006')['status'] | Should -BeExactly 'inProgress'
    }

    It 'Classifies an unlicensed learner from the Graph error text' {
        $row = Get-LiveRow -Identity 'chris.white@newco.com' -ActivityType 'SelfInitiated' -CourseTitle 'PowerShell Fundamentals'
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match 'no Viva Learning premium license'
    }
}

Describe 'Import-MigrationVivaLearningHistory - rows the CSV cannot describe fail individually' {

    BeforeAll {
        $script:badWorkspace = New-VivaWorkspace -Label 'Invalid'
        Reset-VivaCallLog
        $global:vivaProviders = @()
        $global:vivaExistingActivityIds = @()

        & $script:scriptPath -CsvPath (Join-Path $script:badWorkspace 'VivaLearningHistory-Invalid.csv') `
            -TenantId $script:tenantId -ClientId $script:clientId -ClientSecret $script:clientSecret `
            -PlanPath (Join-Path $script:badWorkspace 'IdentityPlan.csv') -LearningProviderId 'provider-existing' `
            -OutputPath $script:badWorkspace -Verbosity Low -DryRun
        $script:badExitCode = $LASTEXITCODE

        $script:badFile = @(Get-ChildItem -LiteralPath $script:badWorkspace -Filter 'Import-VivaLearningHistory-DryRun_*.csv')
        $script:badRows = if ($script:badFile.Count -eq 1) { @(Import-Csv -LiteralPath $script:badFile[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:badWorkspace -and (Test-Path -LiteralPath $script:badWorkspace)) {
            Remove-Item -LiteralPath $script:badWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Still writes the DryRun file and exits 2 for the row failures' {
        $script:badFile.Count | Should -Be 1
        $script:badExitCode | Should -Be 2
        $script:badRows.Count | Should -Be 4
    }

    It 'Fails a learner the plan does not cover rather than importing a source-domain UPN' {
        $row = @($script:badRows | Where-Object { $_.SourceUserPrincipalName -eq 'nobody@contoso.com' })[0]
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match 'not in the identity plan'
        $row.Identity | Should -BeExactly 'nobody@contoso.com'
    }

    It 'Fails an ActivityType it does not recognise' {
        $row = @($script:badRows | Where-Object { $_.ActivityType -eq 'Webinar' })[0]
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match "Unrecognised ActivityType value 'Webinar'"
    }

    It 'Fails a Status it does not recognise' {
        $row = @($script:badRows | Where-Object { $_.Detail -like "*Status value 'Done'*" })[0]
        $row.Status | Should -BeExactly 'Failed'
    }

    It 'Fails a row whose course has no title or URL to build content from' {
        $row = @($script:badRows | Where-Object { $_.SourceUserPrincipalName -eq 'bjones@contoso.com' })[0]
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match 'Missing CourseTitle or CourseWebUrl'
    }
}
