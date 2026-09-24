#Requires -Version 7.4

<#
    End-to-end tests for the Main region of Set-MigrationLicenses.ps1.

    Set-MigrationLicenses.Tests.ps1 lifts the script's functions out by AST and exercises them in
    isolation, which leaves Main - the seat pre-check, the refusal gate and the exit codes - untested.
    This file covers that region the way New-MigrationUsers.Tests.ps1 does: the script is invoked with
    the call operator against scope-shadowing stubs defined in BeforeAll. PowerShell resolves a command
    from the innermost scope outwards, so a function defined here wins over the module's exported
    function of the same name for everything the script calls, including the scriptblocks it hands to
    Invoke-MigrationAction. The real module keeps doing the logging, run context, results export and
    DryRun gating, so those are exercised rather than mocked away.

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

    $script:scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Set-MigrationLicenses.ps1')).Path

    # Obviously synthetic identifiers - this repo is public.
    $global:licenseTenantId = '00000000-0000-0000-0000-000000000001'
    $global:licenseE3SkuId = '00000000-0000-0000-0000-000000000e30'
    $global:licenseJohnId = '00000000-0000-0000-0000-0000000000a1'
    $global:licenseJaneId = '00000000-0000-0000-0000-0000000000a2'

    $global:licenseConnectCalls = 0
    $global:licenseGraphCalls = [System.Collections.Generic.List[object]]::new()
    # How many SPE_E3 seats the stub catalogue reports spare. Each scenario sets it before the run:
    # 1 against two licensed rows is the shortfall, 5 is a tenant with room.
    $global:licenseSeatsAvailable = 5

    function Connect-MigrationGraph {
        param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
        $global:licenseConnectCalls++
        return [pscustomobject]@{ TenantId = $global:licenseTenantId; Account = 'tech@newco.onmicrosoft.com' }
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
                SkuId         = $global:licenseE3SkuId
                SkuPartNumber = 'SPE_E3'
                Available     = $global:licenseSeatsAvailable
            })
    }

    function Invoke-MigrationGraphRequest {
        param([string]$Method, [string]$Uri, $Body, [hashtable]$Headers, [switch]$All, [int]$MaxRetry = 5)
        $global:licenseGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })

        # Get-DestinationUserMap's batched lookup. Both licensed rows resolve, already carry a usage
        # location and hold no licence, so each one needs exactly one new SPE_E3 seat.
        if ($Method -eq 'GET' -and $Uri -like '/v1.0/users?*$filter=*') {
            return @(
                [pscustomobject]@{
                    id                      = $global:licenseJohnId
                    userPrincipalName       = 'john.smith@newco.onmicrosoft.com'
                    displayName             = 'John Smith'
                    accountEnabled          = $true
                    usageLocation           = 'US'
                    licenseAssignmentStates = @()
                }
                [pscustomobject]@{
                    id                      = $global:licenseJaneId
                    userPrincipalName       = 'jane.doe@newco.onmicrosoft.com'
                    displayName             = 'Jane Doe'
                    accountEnabled          = $true
                    usageLocation           = 'US'
                    licenseAssignmentStates = @()
                }
            )
        }
        return $null
    }

    # A three-row plan: two licensed users and one Excluded row. The Excluded row is what puts a
    # Skipped result in the list before the seat pre-check runs, so the shortfall scenario can show
    # that a run stopped at the pre-check still writes its results file.
    function New-LicensePlanFile {
        param([Parameter(Mandatory)][string]$Path)

        $rows = @(
            @{ Name = 'john.smith'; ObjectId = $global:licenseJohnId; Status = 'Planned' }
            @{ Name = 'jane.doe'; ObjectId = $global:licenseJaneId; Status = 'Planned' }
            @{ Name = 'breakglass'; ObjectId = ''; Status = 'Excluded' }
        ) | ForEach-Object {
            $row = New-MigrationPlanRow
            $row.ObjectType = 'User'
            $row.Wave = '1'
            $row.SourceUserPrincipalName = "$($_.Name)@contoso.com"
            $row.DisplayName = $_.Name
            $row.UsageLocation = 'US'
            $row.IsSynced = 'False'
            $row.InterimUserPrincipalName = "$($_.Name)@newco.onmicrosoft.com"
            $row.TargetUserPrincipalName = "$($_.Name)@newco.com"
            $row.TargetMailNickname = $_.Name
            $row.TargetLicenses = 'SPE_E3'
            $row.PlanStatus = $_.Status
            $row.TargetObjectId = $_.ObjectId
            $row
        }

        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
    }

    # One workspace per scenario: Get-MigrationOutputPath stamps filenames to the second, so two runs
    # sharing a folder could produce two files a Get-ChildItem filter cannot tell apart.
    function New-LicenseWorkspace {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)

        $workspace = Join-Path $Root $Name
        $null = New-Item -Path $workspace -ItemType Directory -Force
        $planPath = Join-Path $workspace 'IdentityPlan.csv'
        New-LicensePlanFile -Path $planPath

        $global:licenseConnectCalls = 0
        $global:licenseGraphCalls.Clear()
        # Reset to the stated default - 5 spare SPE_E3 seats, enough for both licensed rows - so a
        # Describe that does not set it cannot silently inherit the shortfall from the one before.
        $global:licenseSeatsAvailable = 5

        return [pscustomobject]@{ Workspace = $workspace; PlanPath = $planPath }
    }
}

AfterAll {
    Remove-Variable -Scope Global -ErrorAction SilentlyContinue -Name `
        licenseTenantId, licenseE3SkuId, licenseJohnId, licenseJaneId,
    licenseConnectCalls, licenseGraphCalls, licenseSeatsAvailable
}

Describe 'Set-MigrationLicenses Main - a seat shortfall stops the run before the first write' {

    BeforeAll {
        $context = New-LicenseWorkspace -Root $TestDrive -Name 'Shortfall'
        # One spare seat against two rows that each need one.
        $global:licenseSeatsAvailable = 1

        & $script:scriptPath -PlanPath $context.PlanPath -Wave '1' -OutputPath $context.Workspace `
            -Verbosity Low -Confirm:$false
        $script:shortfallExitCode = $LASTEXITCODE
        $script:shortfallFiles = @(Get-ChildItem -LiteralPath $context.Workspace -Filter 'Set-Licenses-Results_*.csv')
        $script:shortfallRows = if ($script:shortfallFiles.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:shortfallFiles[0].FullName)
        }
        else { @() }
    }

    It 'Exits 1' {
        $script:shortfallExitCode | Should -Be 1
    }

    It 'Still writes a results file' {
        $script:shortfallFiles.Count | Should -Be 1
    }

    It 'Holds the row the plan excluded, which is all the list had when the pre-check stopped the run' {
        $script:shortfallRows.Count | Should -Be 1
        $script:shortfallRows[0].Status | Should -BeExactly 'Skipped'
        $script:shortfallRows[0].Detail | Should -Match "PlanStatus is 'Excluded'"
    }

    It 'Sends no assignLicense call' {
        @($global:licenseGraphCalls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
    }
}

Describe 'Set-MigrationLicenses Main - -Force presses on through the shortfall' {

    BeforeAll {
        $context = New-LicenseWorkspace -Root $TestDrive -Name 'Force'
        $global:licenseSeatsAvailable = 1

        & $script:scriptPath -PlanPath $context.PlanPath -Wave '1' -OutputPath $context.Workspace `
            -Verbosity Low -Force -Confirm:$false
        $script:forceExitCode = $LASTEXITCODE
        $script:forceFiles = @(Get-ChildItem -LiteralPath $context.Workspace -Filter 'Set-Licenses-Results_*.csv')
        $script:forceRows = if ($script:forceFiles.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:forceFiles[0].FullName)
        }
        else { @() }
    }

    It 'Exits 0' {
        $script:forceExitCode | Should -Be 0
    }

    It 'Assigns the licence to both eligible rows anyway' {
        $assign = @($global:licenseGraphCalls | Where-Object { $_.Uri -like '*/assignLicense' })
        $assign.Count | Should -Be 2
        @($assign.Method | Sort-Object -Unique) | Should -Be @('POST')
    }

    It 'Records both assignments as Succeeded' {
        @($script:forceRows | Where-Object { $_.Status -eq 'Succeeded' }).Count | Should -Be 2
    }
}

Describe 'Set-MigrationLicenses Main - -RemoveUnplanned refuses without the acknowledgement' {

    BeforeAll {
        $context = New-LicenseWorkspace -Root $TestDrive -Name 'Refusal'
        $script:refusalWorkspace = $context.Workspace

        & $script:scriptPath -PlanPath $context.PlanPath -Wave '1' -OutputPath $context.Workspace `
            -Verbosity Low -RemoveUnplanned -Confirm:$false
        $script:refusalExitCode = $LASTEXITCODE
    }

    It 'Exits 1' {
        $script:refusalExitCode | Should -Be 1
    }

    It 'Refuses before signing in to anything' {
        $global:licenseConnectCalls | Should -Be 0
        $global:licenseGraphCalls.Count | Should -Be 0
    }

    It 'Writes no results file, because the refusal precedes even the plan read' {
        @(Get-ChildItem -LiteralPath $script:refusalWorkspace -Filter 'Set-Licenses-*.csv').Count | Should -Be 0
    }
}

Describe 'Set-MigrationLicenses Main - a dry run plans everything and changes nothing' {

    BeforeAll {
        $context = New-LicenseWorkspace -Root $TestDrive -Name 'DryRun'
        $global:licenseSeatsAvailable = 5

        & $script:scriptPath -PlanPath $context.PlanPath -Wave '1' -OutputPath $context.Workspace `
            -Verbosity Low -DryRun -Confirm:$false
        $script:dryRunExitCode = $LASTEXITCODE
        $script:dryRunFiles = @(Get-ChildItem -LiteralPath $context.Workspace -Filter 'Set-Licenses-DryRun_*.csv')
        $script:dryRunRows = if ($script:dryRunFiles.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:dryRunFiles[0].FullName)
        }
        else { @() }
    }

    It 'Exits 0' {
        $script:dryRunExitCode | Should -Be 0
    }

    It 'Writes exactly one DryRun results file' {
        $script:dryRunFiles.Count | Should -Be 1
    }

    It 'Plans both licensed rows without sending a single write' {
        @($script:dryRunRows | Where-Object { $_.Status -eq 'Planned' }).Count | Should -Be 2
        @($global:licenseGraphCalls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
    }

    It 'Still performs the read-only user lookup a live run would' {
        @($global:licenseGraphCalls | Where-Object { $_.Method -eq 'GET' }).Count | Should -BeGreaterThan 0
    }
}
