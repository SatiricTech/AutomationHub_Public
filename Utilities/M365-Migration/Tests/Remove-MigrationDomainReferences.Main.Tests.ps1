#Requires -Version 7.4

<#
    End-to-end tests for the Main region of Remove-MigrationDomainReferences.ps1.

    Remove-MigrationDomainReferences.Tests.ps1 lifts the script's functions out by AST and exercises
    them in isolation, which leaves Main - the report/remediate split, the re-enumeration and the exit
    codes - untested. This file covers that region the way New-MigrationUsers.Tests.ps1 does: the
    script is invoked with the call operator against scope-shadowing stubs defined in BeforeAll.
    PowerShell resolves a command from the innermost scope outwards, so a function defined here wins
    over the module's exported function of the same name for everything the script calls, including
    the scriptblocks it hands to Invoke-MigrationAction. The real module keeps doing the logging, run
    context, report and results export and DryRun gating, so those are exercised rather than mocked.

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

    $script:scriptPath =
    (Resolve-Path (Join-Path $PSScriptRoot '..' 'Remove-MigrationDomainReferences.ps1')).Path

    # Obviously synthetic identifiers - this repo is public.
    $global:domainTenantId = '00000000-0000-0000-0000-000000000001'
    $global:domainJohnId = '00000000-0000-0000-0000-0000000000a1'
    $global:domainJaneId = '00000000-0000-0000-0000-0000000000a2'

    $global:domainGraphCalls = [System.Collections.Generic.List[object]]::new()
    # The users the directory pass reports, as @{ Id = ...; Name = ... } entries. Each scenario sets
    # it before the run: empty is a tenant with nothing left on the domain.
    $global:domainUsers = @()
    # Object id whose UPN PATCH throws, which is how the row-failure scenario is staged.
    $global:domainPatchFailsFor = ''
    # How many times the directory pass has run. The remediation scenario uses it to make the
    # post-change re-enumeration return only the user whose PATCH failed.
    $global:domainUserQueryCount = 0

    function Connect-MigrationGraph {
        param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
        return [pscustomobject]@{ TenantId = $global:domainTenantId; Account = 'tech@contoso.onmicrosoft.com' }
    }

    function Connect-MigrationExchange {
        param([string]$DelegatedOrganization, [string]$TenantId, [switch]$Reconnect)
        return [pscustomobject]@{
            State                 = 'Connected'
            TenantID              = $global:domainTenantId
            UserPrincipalName     = 'tech@contoso.onmicrosoft.com'
            DelegatedOrganization = ''
        }
    }

    function Assert-MigrationTenant {
        param(
            [string]$ExpectedTenantId, $GraphContext, $ExchangeConnection, $TeamsTenant, [string]$Purpose
        )
        return [pscustomobject]@{ Matches = $true; ExpectedTenantId = $ExpectedTenantId; Reason = '' }
    }

    # No Exchange recipient holds the domain, so every reference in these scenarios comes from the
    # Graph user pass and is a plain UPN move.
    function Get-EXORecipient {
        param([string]$Filter, [string]$ResultSize, [string[]]$Properties)
        return @()
    }

    function Invoke-MigrationGraphRequest {
        param([string]$Method, [string]$Uri, $Body, [hashtable]$Headers, [switch]$All, [int]$MaxRetry = 5)
        $global:domainGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })

        if ($Method -eq 'PATCH') {
            if ($global:domainPatchFailsFor -and $Uri -like "*$($global:domainPatchFailsFor)") {
                throw 'Insufficient privileges to complete the operation.'
            }
            return $null
        }

        # '?' is a single-character wildcard to -like, so the order here matters: the more specific
        # URIs are matched first and '/v1.0/domains*' is only reached by the domain list.
        if ($Uri -like '*organization*') {
            return @([pscustomobject]@{ id = $global:domainTenantId; displayName = 'Contoso Ltd' })
        }
        if ($Uri -like '*domainNameReferences*') { return @() }
        if ($Uri -like '/v1.0/domains*') {
            return @(
                [pscustomobject]@{ id = 'contoso.com'; isInitial = $false; isVerified = $true }
                [pscustomobject]@{ id = 'contoso.onmicrosoft.com'; isInitial = $true; isVerified = $true }
            )
        }
        if ($Uri -like '*deletedItems*') { return @() }
        if ($Uri -like '/v1.0/users*') {
            $global:domainUserQueryCount++
            # After a remediation pass the users whose PATCH succeeded are off the domain, so the
            # re-enumeration only still sees the one that failed.
            $wanted = if ($global:domainUserQueryCount -gt 1 -and $global:domainPatchFailsFor) {
                @($global:domainUsers | Where-Object { $_.Id -eq $global:domainPatchFailsFor })
            }
            else { @($global:domainUsers) }

            return @(foreach ($user in $wanted) {
                    [pscustomobject]@{
                        id                    = $user.Id
                        displayName           = $user.Name
                        userPrincipalName     = "$($user.Name)@contoso.com"
                        mail                  = ''
                        proxyAddresses        = @()
                        onPremisesSyncEnabled = $false
                        userType              = 'Member'
                    }
                })
        }
        return @()
    }

    # One workspace per scenario: Get-MigrationOutputPath stamps filenames to the second, so two runs
    # sharing a folder could produce two files a Get-ChildItem filter cannot tell apart.
    function New-DomainWorkspace {
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)

        $workspace = Join-Path $Root $Name
        $null = New-Item -Path $workspace -ItemType Directory -Force

        $global:domainGraphCalls.Clear()
        $global:domainUserQueryCount = 0
        $global:domainPatchFailsFor = ''

        return $workspace
    }
}

AfterAll {
    Remove-Variable -Scope Global -ErrorAction SilentlyContinue -Name `
        domainTenantId, domainJohnId, domainJaneId, domainGraphCalls, domainUsers,
    domainPatchFailsFor, domainUserQueryCount
}

Describe 'Remove-MigrationDomainReferences Main - a report run with references still standing' {

    BeforeAll {
        $script:reportWorkspace = New-DomainWorkspace -Root $TestDrive -Name 'ReportOnly'
        $global:domainUsers = @(@{ Id = $global:domainJohnId; Name = 'john.smith' })

        # No -AcknowledgeSourceTenant: the run computes everything and changes nothing.
        & $script:scriptPath -Domain 'contoso.com' -OutputPath $script:reportWorkspace -Verbosity Low
        $script:reportExitCode = $LASTEXITCODE
        $script:reportFiles = @(Get-ChildItem -LiteralPath $script:reportWorkspace -Filter 'DomainReferences_*.csv')
        $script:reportRows = if ($script:reportFiles.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:reportFiles[0].FullName)
        }
        else { @() }
    }

    It 'Exits 3, because the domain still cannot be removed' {
        $script:reportExitCode | Should -Be 3
    }

    It 'Writes the DomainReferences report' {
        $script:reportFiles.Count | Should -Be 1
    }

    It 'Reports the UPN as fixable and names where it would move' {
        $script:reportRows.Count | Should -Be 1
        $script:reportRows[0].Class | Should -BeExactly 'Fixable'
        $script:reportRows[0].Target | Should -BeExactly 'john.smith@contoso.onmicrosoft.com'
    }

    It 'Changes nothing without the acknowledgement' {
        @($global:domainGraphCalls | Where-Object { $_.Method -ne 'GET' }).Count | Should -Be 0
    }
}

Describe 'Remove-MigrationDomainReferences Main - a tenant with nothing left on the domain' {

    BeforeAll {
        $script:cleanWorkspace = New-DomainWorkspace -Root $TestDrive -Name 'Clean'
        $global:domainUsers = @()

        & $script:scriptPath -Domain 'contoso.com' -OutputPath $script:cleanWorkspace -Verbosity Low
        $script:cleanExitCode = $LASTEXITCODE
        $script:cleanFiles = @(Get-ChildItem -LiteralPath $script:cleanWorkspace -Filter 'DomainReferences_*.csv')
        $script:cleanRows = if ($script:cleanFiles.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:cleanFiles[0].FullName)
        }
        else { @() }
    }

    It 'Exits 0' {
        $script:cleanExitCode | Should -Be 0
    }

    # Exit 0 on its own would also be what a run that never enumerated anything produced, so the
    # next two assertions are what separate 'scanned, found nothing' from 'never scanned'.
    It 'Ran the directory pass exactly once' {
        $global:domainUserQueryCount | Should -Be 1
    }

    It 'Wrote the DomainReferences report with no reference in it' {
        $script:cleanFiles.Count | Should -Be 1
        $script:cleanRows.Count | Should -Be 1
        $script:cleanRows[0].Info | Should -BeExactly 'No DomainReferences records found.'
    }

    It 'Read the domain list, the soft-deleted users and domainNameReferences as well' {
        # 'isInitial' appears only in the domain-list query, so it identifies that pass without a
        # pattern that '?' (a single-character wildcard to -like) could blur into a different URI.
        foreach ($fragment in @('isInitial', 'deletedItems', 'domainNameReferences')) {
            @($global:domainGraphCalls | Where-Object { $_.Uri -like "*$fragment*" }).Count |
                Should -BeGreaterThan 0 -Because "the $fragment pass has to have run for exit 0 to mean anything"
        }
    }
}

Describe 'Remove-MigrationDomainReferences Main - one row fails during remediation' {

    BeforeAll {
        $script:failWorkspace = New-DomainWorkspace -Root $TestDrive -Name 'RowFailure'
        $global:domainUsers = @(
            @{ Id = $global:domainJohnId; Name = 'john.smith' }
            @{ Id = $global:domainJaneId; Name = 'jane.doe' }
        )
        $global:domainPatchFailsFor = $global:domainJaneId

        & $script:scriptPath -Domain 'contoso.com' -OutputPath $script:failWorkspace -Verbosity Low `
            -AcknowledgeSourceTenant -Confirm:$false
        $script:failExitCode = $LASTEXITCODE
        $script:failFiles = @(Get-ChildItem -LiteralPath $script:failWorkspace `
                -Filter 'Remove-DomainReferences-Results_*.csv')
        $script:failRows = if ($script:failFiles.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:failFiles[0].FullName)
        }
        else { @() }
    }

    It 'Exits 2, because a row failure outranks the references still left' {
        $script:failExitCode | Should -Be 2
    }

    It 'Patched both UPNs' {
        @($global:domainGraphCalls | Where-Object { $_.Method -eq 'PATCH' }).Count | Should -Be 2
    }

    It 'Records one Succeeded row and one Failed row' {
        @($script:failRows | Where-Object { $_.Status -eq 'Succeeded' }).Count | Should -Be 1
        $failed = @($script:failRows | Where-Object { $_.Status -eq 'Failed' })
        $failed.Count | Should -Be 1
        $failed[0].Identity | Should -BeExactly 'jane.doe@contoso.com'
    }

    It 'Re-enumerates the domain after the changes' {
        $global:domainUserQueryCount | Should -Be 2
        @(Get-ChildItem -LiteralPath $script:failWorkspace -Filter 'DomainBlockers-Recheck_*.csv').Count |
            Should -Be 1
    }
}
