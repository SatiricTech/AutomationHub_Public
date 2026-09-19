#Requires -Version 7.4

<#
    End-to-end tests for the Main region of Test-MigrationReadiness.ps1.

    Test-MigrationReadiness.Tests.ps1 lifts the script's functions out by AST and exercises them in
    isolation, which leaves Main - stage selection, the plan write-back and the exit codes - untested.
    This file covers that region the way New-MigrationUsers.Tests.ps1 does: the script is invoked with
    the call operator against scope-shadowing stubs defined in BeforeAll. PowerShell resolves a command
    from the innermost scope outwards, so a function defined here wins over the module's exported
    function of the same name for everything the script calls, including the scriptblocks it hands to
    Invoke-MigrationAction. The real module keeps doing the logging, run context, plan save, results
    export and DryRun gating, so those are exercised rather than mocked away.

    'exit' inside a script invoked with '&' ends that script only, so $LASTEXITCODE is readable and
    Pester carries on.

    Fixtures and call logs live in $global: because a function defined in BeforeAll does not share the
    $script: scope Pester gives the It blocks.

    Author: AutomationHub
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Stubs defined in BeforeAll cannot see the $script: scope Pester gives the It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must bind every parameter the script passes, asserted on or not.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Stand-ins for module functions; they record a call and change nothing.')]
param()

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Test-MigrationReadiness.ps1')).Path

    # Obviously synthetic identifiers - this repo is public.
    $global:readinessTenantId = '00000000-0000-0000-0000-000000000001'
    $global:readinessUserIds = @{ 'john.smith' = '00000000-0000-0000-0000-0000000000a1'
        'jane.doe' = '00000000-0000-0000-0000-0000000000a2'
    }

    $global:readinessGraphCalls = [System.Collections.Generic.List[object]]::new()
    $global:readinessMailboxCalls = [System.Collections.Generic.List[string]]::new()

    function Connect-MigrationGraph {
        param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
        return [pscustomobject]@{ TenantId = $global:readinessTenantId; Account = 'tech@newco.onmicrosoft.com' }
    }

    function Connect-MigrationExchange {
        param([string]$DelegatedOrganization, [string]$TenantId, [switch]$Reconnect)
        return [pscustomobject]@{
            State                 = 'Connected'
            TenantId              = $global:readinessTenantId
            UserPrincipalName     = 'tech@newco.onmicrosoft.com'
            DelegatedOrganization = ''
        }
    }

    function Assert-MigrationTenant {
        param(
            [string]$ExpectedTenantId, $GraphContext, $ExchangeConnection, $TeamsTenant, [string]$Purpose
        )
        return [pscustomobject]@{ Matches = $true; ExpectedTenantId = $ExpectedTenantId; Reason = '' }
    }

    function Get-MigrationSkuCatalog {
        param([switch]$Refresh)
        return @([pscustomobject]@{
                SkuId = '00000000-0000-0000-0000-000000000e30'; SkuPartNumber = 'SPE_E3'; Available = 5
            })
    }

    function Invoke-MigrationGraphRequest {
        param([string]$Method, [string]$Uri, $Body, [hashtable]$Headers, [switch]$All, [int]$MaxRetry = 5)
        $global:readinessGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })

        # Both planned domains are verified, so the Pre stage's DomainVerified check passes and the
        # scenarios stay about the stage logic rather than about a domain that was never set up.
        if ($Uri -eq '/v1.0/domains') {
            return @(
                [pscustomobject]@{ id = 'newco.com'; isVerified = $true }
                [pscustomobject]@{ id = 'newco.onmicrosoft.com'; isVerified = $true }
            )
        }
        # The Provisioned stage's per-row drive read; a drive is present, so OneDriveExists passes.
        if ($Uri -like '*/drive') { return [pscustomobject]@{ id = 'drive-1'; driveType = 'business' } }
        # The Provisioned stage's per-row user read. The clash queries are '/v1.0/users?...', which
        # has no slash after 'users' and so does not match this pattern.
        if ($Uri -like '/v1.0/users/*') {
            $id = ($Uri -split '\?')[0].Split('/')[-1]
            # Select-Object, not [0]: indexing an empty array throws under Set-StrictMode -Version
            # Latest, which would make the not-found guard below unreachable.
            $name = $global:readinessUserIds.Keys |
                Where-Object { $global:readinessUserIds[$_] -eq $id } |
                Select-Object -First 1
            if (-not $name) { return $null }
            return [pscustomobject]@{
                id                = $id
                userPrincipalName = "$name@newco.com"
                displayName       = $name
                accountEnabled    = $true
                usageLocation     = 'US'
            }
        }
        # Every clash lookup - users, groups, soft-deleted users - finds nothing.
        return @()
    }

    function Get-EXORecipient {
        param([string]$Filter, [string]$ResultSize, [string[]]$Properties)
        return @()
    }

    function Get-EXOMailbox {
        param([string]$Identity, [string]$PropertySets, [string[]]$Properties)
        $global:readinessMailboxCalls.Add($Identity)
        return [pscustomobject]@{
            PrimarySmtpAddress            = 'mailbox@newco.com'
            LitigationHoldEnabled         = $false
            ArchiveStatus                 = 'None'
            ArchiveGuid                   = '00000000-0000-0000-0000-000000000000'
            ProhibitSendReceiveQuota      = '100 GB (107,374,182,400 bytes)'
            HiddenFromAddressListsEnabled = $false
            EmailAddresses                = @('SMTP:mailbox@newco.com')
        }
    }

    # A two-row plan on verified domains. -FirstRowPlanStatus dirties one row for the failing-check
    # scenario; -WithTargetObjectId is what makes a row eligible for the Provisioned stage.
    function New-ReadinessPlanFile {
        param(
            [Parameter(Mandatory)][string]$Path,
            [string]$FirstRowPlanStatus = 'Planned',
            [switch]$WithTargetObjectId
        )

        $names = @('john.smith', 'jane.doe')
        $rows = for ($index = 0; $index -lt $names.Count; $index++) {
            $name = $names[$index]
            $row = New-MigrationPlanRow
            $row.ObjectType = 'User'
            $row.Wave = '1'
            $row.SourceUserPrincipalName = "$name@contoso.com"
            $row.SourcePrimarySmtp = "$name@contoso.com"
            $row.DisplayName = $name
            $row.UsageLocation = 'US'
            $row.IsSynced = 'False'
            $row.InterimUserPrincipalName = "$name@newco.onmicrosoft.com"
            $row.InterimPrimarySmtp = "$name@newco.onmicrosoft.com"
            $row.TargetUserPrincipalName = "$name@newco.com"
            $row.TargetPrimarySmtp = "$name@newco.com"
            $row.TargetMailNickname = $name
            $row.TargetLicenses = 'SPE_E3'
            $row.PlanStatus = if ($index -eq 0) { $FirstRowPlanStatus } else { 'Planned' }
            if ($WithTargetObjectId) { $row.TargetObjectId = $global:readinessUserIds[$name] }
            $row
        }

        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
    }

    # One workspace per scenario: Get-MigrationOutputPath stamps filenames to the second, so two runs
    # sharing a folder could produce two files a Get-ChildItem filter cannot tell apart.
    function New-ReadinessWorkspace {
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$Name,
            [string]$FirstRowPlanStatus = 'Planned',
            [switch]$WithTargetObjectId
        )

        $workspace = Join-Path $Root $Name
        $null = New-Item -Path $workspace -ItemType Directory -Force
        $planPath = Join-Path $workspace 'IdentityPlan.csv'
        New-ReadinessPlanFile -Path $planPath -FirstRowPlanStatus $FirstRowPlanStatus `
            -WithTargetObjectId:$WithTargetObjectId

        $global:readinessGraphCalls.Clear()
        $global:readinessMailboxCalls.Clear()

        return [pscustomobject]@{ Workspace = $workspace; PlanPath = $planPath }
    }
}

AfterAll {
    Remove-Variable -Scope Global -ErrorAction SilentlyContinue -Name `
        readinessTenantId, readinessUserIds, readinessGraphCalls, readinessMailboxCalls
}

Describe 'Test-MigrationReadiness Main - a clean Pre run' {

    BeforeAll {
        $context = New-ReadinessWorkspace -Root $TestDrive -Name 'PreClean'

        & $script:scriptPath -PlanPath $context.PlanPath -Stage Pre -Wave '1' `
            -OutputPath $context.Workspace -Verbosity Low
        $script:preExitCode = $LASTEXITCODE
        $script:preFiles = @(Get-ChildItem -LiteralPath $context.Workspace -Filter 'Test-Readiness-Results_*.csv')
        $script:preRows = if ($script:preFiles.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:preFiles[0].FullName)
        }
        else { @() }
    }

    It 'Exits 0' {
        $script:preExitCode | Should -Be 0
    }

    It 'Fails no check' {
        @($script:preRows | Where-Object { $_.Status -eq 'Failed' }).Count | Should -Be 0
    }

    It 'Runs the whole Pre battery' {
        $actions = @($script:preRows.Action | Sort-Object -Unique)
        foreach ($check in @('PlanClean', 'DomainVerified', 'SkuSeats', 'UsageLocation', 'AddressClash',
                'SyncedSource')) {
            $actions | Should -Contain $check
        }
    }

    It 'Reads no mailbox, because that is the Provisioned stage' {
        $global:readinessMailboxCalls.Count | Should -Be 0
    }
}

Describe 'Test-MigrationReadiness Main - a failing check sets exit 2' {

    BeforeAll {
        # NeedsReview is one of the statuses PlanClean treats as a blocker.
        $context = New-ReadinessWorkspace -Root $TestDrive -Name 'PreDirty' -FirstRowPlanStatus 'NeedsReview'

        & $script:scriptPath -PlanPath $context.PlanPath -Stage Pre -Wave '1' `
            -OutputPath $context.Workspace -Verbosity Low
        $script:dirtyExitCode = $LASTEXITCODE
        $script:dirtyFiles = @(Get-ChildItem -LiteralPath $context.Workspace -Filter 'Test-Readiness-Results_*.csv')
        $script:dirtyRows = if ($script:dirtyFiles.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:dirtyFiles[0].FullName)
        }
        else { @() }
    }

    It 'Exits 2' {
        $script:dirtyExitCode | Should -Be 2
    }

    It 'Names the row PlanClean rejected' {
        $failed = @($script:dirtyRows | Where-Object { $_.Status -eq 'Failed' })
        $failed.Count | Should -Be 1
        $failed[0].Action | Should -BeExactly 'PlanClean'
        $failed[0].Detail | Should -Match 'NeedsReview'
    }
}

Describe 'Test-MigrationReadiness Main - the Provisioned stage writes the plan back' {

    BeforeAll {
        $context = New-ReadinessWorkspace -Root $TestDrive -Name 'Provisioned' -WithTargetObjectId
        $script:provisionedPlan = $context.PlanPath
        $script:provisionedHashBefore = (Get-FileHash -LiteralPath $context.PlanPath -Algorithm SHA256).Hash

        & $script:scriptPath -PlanPath $context.PlanPath -Stage Provisioned -Wave '1' `
            -OutputPath $context.Workspace -Verbosity Low
        $script:provisionedExitCode = $LASTEXITCODE
        $script:provisionedRows = @(Import-Csv -LiteralPath $context.PlanPath)
    }

    It 'Exits 0' {
        $script:provisionedExitCode | Should -Be 0
    }

    It 'Reads a mailbox for every provisioned row' {
        $global:readinessMailboxCalls.Count | Should -Be 2
    }

    It 'Rewrites the plan file' {
        (Get-FileHash -LiteralPath $script:provisionedPlan -Algorithm SHA256).Hash |
            Should -Not -BeExactly $script:provisionedHashBefore
    }

    It 'Takes a backup of the state the run started from' {
        Test-Path -LiteralPath "$($script:provisionedPlan).bak" | Should -BeTrue
    }

    It 'Records MailboxProvisioned as True on every row' {
        @($script:provisionedRows | Where-Object { $_.MailboxProvisioned -eq 'True' }).Count | Should -Be 2
    }
}

Describe 'Test-MigrationReadiness Main - a dry run skips the write-back' {

    BeforeAll {
        $context = New-ReadinessWorkspace -Root $TestDrive -Name 'ProvisionedDryRun' -WithTargetObjectId
        $script:dryPlan = $context.PlanPath
        $script:dryHashBefore = (Get-FileHash -LiteralPath $context.PlanPath -Algorithm SHA256).Hash

        & $script:scriptPath -PlanPath $context.PlanPath -Stage Provisioned -Wave '1' `
            -OutputPath $context.Workspace -Verbosity Low -DryRun
        $script:dryExitCode = $LASTEXITCODE
        $script:dryRows = @(Import-Csv -LiteralPath $context.PlanPath)
        $script:dryFiles = @(Get-ChildItem -LiteralPath $context.Workspace -Filter 'Test-Readiness-DryRun_*.csv')
    }

    It 'Exits 0' {
        $script:dryExitCode | Should -Be 0
    }

    It 'Writes a DryRun results file' {
        $script:dryFiles.Count | Should -Be 1
    }

    It 'Leaves the plan file byte-for-byte unchanged and takes no backup' {
        (Get-FileHash -LiteralPath $script:dryPlan -Algorithm SHA256).Hash | Should -BeExactly $script:dryHashBefore
        Test-Path -LiteralPath "$($script:dryPlan).bak" | Should -BeFalse
    }

    It 'Leaves MailboxProvisioned empty on every row' {
        @($script:dryRows | Where-Object { $_.MailboxProvisioned }).Count | Should -Be 0
    }

    It 'Skips the OneDrive read, because that read provisions a drive' {
        @($global:readinessGraphCalls | Where-Object { $_.Uri -like '*/drive' }).Count | Should -Be 0
    }
}
