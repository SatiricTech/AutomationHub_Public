#Requires -Version 7.4

<#
    Tests for Remove-MigrationTeamsPhoneAssignments.ps1.

    The script has no pure inner functions; everything worth testing is the per-row decision
    inside the main loop. So the script is run with the call operator while plain functions
    declared here shadow the Teams cmdlets and the toolkit's connection and inventory helpers.
    PowerShell resolves commands innermost-scope-first, so the stubs win for anything the
    script calls directly, while the real module still supplies the run context, the logger
    and the results export. No sign-in ever happens: Connect-MigrationTeams itself is a stub.

    Author: AutomationHub
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script under test binds, including ones a particular test does not read; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Remove-CsPhoneNumberAssignment here is a stand-in named after the real cmdlet so the script under test resolves it. It changes nothing, so ShouldProcess would be meaningless.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
    Justification = 'Connect-MigrationTeams mirrors the module function it shadows; Teams is a product name.')]
param()

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:scriptPath = Join-Path $PSScriptRoot '..' 'Remove-MigrationTeamsPhoneAssignments.ps1'
    $script:fixtureCsv = Join-Path $PSScriptRoot 'Fixtures' 'Remove-MigrationTeamsPhoneAssignments' 'Source_TeamsPhoneAssignments.csv'
    $script:workspaces = [System.Collections.Generic.List[string]]::new()

    <#
        The stub tenant. Every user is a plain object shaped like Get-CsOnlineUser output:
          john.smith     cloud number with an extension, in the inventory as CallingPlan
          hybrid.user    OnPremLineURI populated - must never reach the removal cmdlet
          synced.number  no OnPremLineURI property at all (older module shape); the inventory
                         reports NumberSource OnPremises - must never reach the removal cmdlet
          no.number      empty LineUri
          legacy.result  cloud number; the removal stub answers with a pre-4.2.1 result object
          aa-main        resource account with a number, only visible to the -All set
        ghost@contoso.com is in the fixture CSV and resolves nothing.
    #>
    function Get-StubTeamsUser {
        return @(
            [pscustomobject]@{
                Identity                 = 'obj-john'
                UserPrincipalName        = 'john.smith@contoso.com'
                DisplayName              = 'John Smith'
                LineUri                  = 'tel:+15551234567;ext=101'
                OnPremLineURI            = $null
                AccountType              = 'User'
                OnlineVoiceRoutingPolicy = 'US-East'
            }
            [pscustomobject]@{
                Identity                 = 'obj-hybrid'
                UserPrincipalName        = 'hybrid.user@contoso.com'
                DisplayName              = 'Hybrid User'
                LineUri                  = 'tel:+15557654321'
                OnPremLineURI            = 'tel:+15557654321'
                AccountType              = 'User'
                OnlineVoiceRoutingPolicy = 'US-East'
            }
            [pscustomobject]@{
                Identity                 = 'obj-synced'
                UserPrincipalName        = 'synced.number@contoso.com'
                DisplayName              = 'Synced Number'
                LineUri                  = 'tel:+15559990000'
                AccountType              = 'User'
                OnlineVoiceRoutingPolicy = 'US-East'
            }
            [pscustomobject]@{
                Identity                 = 'obj-nonumber'
                UserPrincipalName        = 'no.number@contoso.com'
                DisplayName              = 'No Number'
                LineUri                  = ''
                OnPremLineURI            = ''
                AccountType              = 'User'
                OnlineVoiceRoutingPolicy = $null
            }
            [pscustomobject]@{
                Identity                 = 'obj-legacy'
                UserPrincipalName        = 'legacy.result@contoso.com'
                DisplayName              = 'Legacy Result'
                LineUri                  = 'tel:+15553330000'
                OnPremLineURI            = ''
                AccountType              = 'User'
                OnlineVoiceRoutingPolicy = 'US-East'
            }
            [pscustomobject]@{
                Identity                 = 'obj-aa'
                UserPrincipalName        = 'aa-main@contoso.com'
                DisplayName              = 'Main Auto Attendant'
                LineUri                  = 'tel:+15551110000'
                OnPremLineURI            = ''
                AccountType              = 'ResourceAccount'
                OnlineVoiceRoutingPolicy = $null
            }
        )
    }

    function Initialize-MigrationModule {
        param([string[]]$Name, [string]$MinimumVersion)
    }

    function Connect-MigrationTeams {
        param([string]$TenantId, [switch]$Reconnect)
        return [pscustomobject]@{ TenantId = 'contoso.onmicrosoft.com'; DisplayName = 'Contoso' }
    }

    function Resolve-MigrationTeamsUser {
        param([string]$Identity)
        return Get-StubTeamsUser | Where-Object { $_.UserPrincipalName -eq $Identity } | Select-Object -First 1
    }

    function Get-CsOnlineUser {
        param($Identity, $Filter, $ErrorAction)
        if ($Filter) {
            return Get-StubTeamsUser | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) }
        }
        return Get-StubTeamsUser
    }

    function Get-MigrationPhoneNumberInventory {
        param([hashtable]$Filter, [int]$PageSize)
        return @(
            [pscustomobject]@{ TelephoneNumber = '+15551234567'; AssignedPstnTargetId = 'obj-john'; NumberType = 'CallingPlan'; LocationId = 'loc-hq'; NumberSource = 'Online' }
            [pscustomobject]@{ TelephoneNumber = '+15559990000'; AssignedPstnTargetId = 'obj-synced'; NumberType = 'DirectRouting'; LocationId = ''; NumberSource = 'OnPremises' }
            [pscustomobject]@{ TelephoneNumber = '+15551110000'; AssignedPstnTargetId = 'obj-aa'; NumberType = 'CallingPlan'; LocationId = 'loc-hq'; NumberSource = 'Online' }
            [pscustomobject]@{ TelephoneNumber = '+15552220000'; AssignedPstnTargetId = ''; NumberType = 'CallingPlan'; LocationId = ''; NumberSource = 'Online' }
        )
    }

    function Remove-CsPhoneNumberAssignment {
        param($Identity, [switch]$RemoveAll, $ErrorAction)
        if ($Identity -in @('hybrid.user@contoso.com', 'synced.number@contoso.com')) {
            throw "Remove-CsPhoneNumberAssignment was reached for $Identity, which the on-prem pre-check must have prevented."
        }
        if ($Identity -eq 'legacy.result@contoso.com') {
            # Teams PowerShell before 4.2.1 reports failure this way instead of throwing.
            return [pscustomobject]@{ Code = 'BadRequest'; Message = 'Simulated pre-4.2.1 result object.' }
        }
    }

    # Runs the script into a throwaway workspace and hands back everything a test may need.
    # 'exit' inside a script run with '&' ends that script only and sets $LASTEXITCODE.
    function Invoke-ScriptUnderTest {
        param([hashtable]$Arguments)

        $workspace = Join-Path ([System.IO.Path]::GetTempPath()) "RemoveTeamsPhone-$([guid]::NewGuid())"
        $null = New-Item -Path $workspace -ItemType Directory -Force
        $script:workspaces.Add($workspace)

        & $script:scriptPath @Arguments -OutputPath $workspace -Verbosity Low
        $exitCode = $LASTEXITCODE

        $csv = @(Get-ChildItem -LiteralPath $workspace -Filter 'Remove-TeamsPhoneAssignments-*.csv')
        $log = @(Get-ChildItem -LiteralPath $workspace -Filter '*.log')
        return [pscustomobject]@{
            ExitCode   = $exitCode
            ResultFile = if ($csv.Count -eq 1) { $csv[0].Name } else { $null }
            Rows       = if ($csv.Count -eq 1) { @(Import-Csv -LiteralPath $csv[0].FullName) } else { @() }
            Log        = if ($log.Count -ge 1) { Get-Content -LiteralPath $log[0].FullName -Raw } else { '' }
        }
    }
}

AfterAll {
    foreach ($workspace in $script:workspaces) {
        if (Test-Path -LiteralPath $workspace) {
            Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Remove-MigrationTeamsPhoneAssignments parameter contract' {

    It 'Requires -TenantId with -All so a whole-tenant release is always pinned' {
        $parameter = (Get-Command $script:scriptPath).Parameters['TenantId']
        $parameter.ParameterSets['All'].IsMandatory | Should -BeTrue
    }

    It 'Leaves -TenantId optional for a single user and a CSV' {
        $parameter = (Get-Command $script:scriptPath).Parameters['TenantId']
        $parameter.ParameterSets['User'].IsMandatory | Should -BeFalse
        $parameter.ParameterSets['Csv'].IsMandatory | Should -BeFalse
    }
}

Describe 'DryRun over the Get- export' {

    BeforeAll {
        $script:dryRun = Invoke-ScriptUnderTest -Arguments @{ CsvPath = $script:fixtureCsv; DryRun = $true }
        $script:dryRows = @{}
        foreach ($row in $script:dryRun.Rows) { $script:dryRows[$row.Identity] = $row }
    }

    It 'Writes a DryRun-named results file with one row per CSV user' {
        $script:dryRun.ResultFile | Should -Match 'Remove-TeamsPhoneAssignments-DryRun_'
        $script:dryRun.Rows.Count | Should -Be 6
    }

    It 'Starts every row with Identity, Action, Status, Detail and carries the new columns' {
        $columns = @($script:dryRun.Rows[0].PSObject.Properties.Name)
        $columns[0..3] | Should -Be @('Identity', 'Action', 'Status', 'Detail')
        $columns | Should -Contain 'OnPremLineURI'
        $columns | Should -Contain 'AccountType'
    }

    It 'Plans a cloud number and keeps the round-trip columns for Set-' {
        $row = $script:dryRows['john.smith@contoso.com']
        $row.Status | Should -BeExactly 'Planned'
        $row.Detail | Should -BeExactly 'Would remove +15551234567 (CallingPlan).'
        $row.PhoneNumber | Should -Be '+15551234567'
        $row.Extension | Should -Be '101'
        $row.LocationId | Should -Be 'loc-hq'
        $row.OnlineVoiceRoutingPolicy | Should -Be 'US-East'
        $row.AccountType | Should -Be 'User'
    }

    It 'Fails a user whose OnPremLineURI is populated without attempting it' {
        $row = $script:dryRows['hybrid.user@contoso.com']
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match 'on-premises'
        $row.Detail | Should -Match 'not attempted'
        $row.OnPremLineURI | Should -Be 'tel:+15557654321'
    }

    It 'Fails a user the inventory reports as NumberSource OnPremises, even without an OnPremLineURI property' {
        $row = $script:dryRows['synced.number@contoso.com']
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match 'on-premises'
        $row.Detail | Should -Not -Match 'property'
    }

    It 'Skips a user with no number' {
        $row = $script:dryRows['no.number@contoso.com']
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -BeExactly 'No phone number assigned.'
    }

    It 'Fails rather than skips an identity that does not resolve' {
        $row = $script:dryRows['ghost@contoso.com']
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -BeExactly 'User not found in this tenant.'
    }

    It 'Exits 2 because rows failed, even in a rehearsal' {
        $script:dryRun.ExitCode | Should -Be 2
    }

    It 'Names the target tenant at WARNING before touching anything' {
        $script:dryRun.Log | Should -Match '\[WARNING\] TARGET TENANT: contoso\.onmicrosoft\.com \(Contoso\)'
    }
}

Describe 'A live run with the prompt suppressed' {

    BeforeAll {
        $script:live = Invoke-ScriptUnderTest -Arguments @{ CsvPath = $script:fixtureCsv; Confirm = $false }
        $script:liveRows = @{}
        foreach ($row in $script:live.Rows) { $script:liveRows[$row.Identity] = $row }
    }

    It 'Writes a Results-named file' {
        $script:live.ResultFile | Should -Match 'Remove-TeamsPhoneAssignments-Results_'
    }

    It 'Records a removal the cmdlet completed as Succeeded' {
        $row = $script:liveRows['john.smith@contoso.com']
        $row.Status | Should -BeExactly 'Succeeded'
        $row.Detail | Should -BeExactly 'Removed +15551234567 (CallingPlan).'
    }

    It 'Never calls the removal cmdlet for an on-prem number' {
        foreach ($upn in @('hybrid.user@contoso.com', 'synced.number@contoso.com')) {
            $script:liveRows[$upn].Status | Should -BeExactly 'Failed'
            $script:liveRows[$upn].Detail | Should -Match 'not attempted'
            $script:liveRows[$upn].Detail | Should -Not -Match 'was reached'
        }
    }

    It 'Treats a pre-4.2.1 result object as a failure instead of a success' {
        $row = $script:liveRows['legacy.result@contoso.com']
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match 'BadRequest'
        $row.Detail | Should -Match 'Simulated pre-4\.2\.1 result object'
    }

    It 'Exits 2' {
        $script:live.ExitCode | Should -Be 2
    }
}

Describe 'The -All set' {

    BeforeAll {
        $script:all = Invoke-ScriptUnderTest -Arguments @{ All = $true; TenantId = 'contoso.onmicrosoft.com'; DryRun = $true }
        $script:allRows = @{}
        foreach ($row in $script:all.Rows) { $script:allRows[$row.Identity] = $row }
    }

    It 'Includes resource accounts and labels them in the AccountType column' {
        $script:allRows.ContainsKey('aa-main@contoso.com') | Should -BeTrue
        $script:allRows['aa-main@contoso.com'].AccountType | Should -Be 'ResourceAccount'
        $script:allRows['aa-main@contoso.com'].Status | Should -BeExactly 'Planned'
        $script:allRows['john.smith@contoso.com'].AccountType | Should -Be 'User'
    }

    It 'Leaves users without a number out of the set' {
        $script:allRows.ContainsKey('no.number@contoso.com') | Should -BeFalse
    }

    Context 'when the server-side LineUri filter throws' {

        BeforeAll {
            function Get-CsOnlineUser {
                param($Identity, $Filter, $ErrorAction)
                if ($Filter) { throw 'Simulated throttle: too many requests' }
                return Get-StubTeamsUser
            }

            $script:fallback = Invoke-ScriptUnderTest -Arguments @{ All = $true; TenantId = 'contoso.onmicrosoft.com'; DryRun = $true }
        }

        It 'Logs the cause with the fallback warning' {
            $script:fallback.Log | Should -Match '\[WARNING\] Server-side LineUri filter failed \(Simulated throttle: too many requests\)'
        }

        It 'Still produces the same set from the local filter' {
            $identities = @($script:fallback.Rows | ForEach-Object { $_.Identity })
            $identities | Should -Contain 'aa-main@contoso.com'
            $identities | Should -Not -Contain 'no.number@contoso.com'
            $script:fallback.Rows.Count | Should -Be $script:all.Rows.Count
        }
    }
}
