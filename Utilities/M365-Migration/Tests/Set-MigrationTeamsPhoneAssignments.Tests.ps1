#Requires -Version 7.4

<#
    Tests for Set-MigrationTeamsPhoneAssignments.ps1.

    The script has no pure inner functions; everything worth testing is the per-row decision
    inside the main loop. So the script is run with the call operator while plain functions
    declared here shadow the Teams cmdlets and the toolkit's connection and inventory helpers.
    PowerShell resolves commands innermost-scope-first, so the stubs win for anything the
    script calls directly, while the real module still supplies the run context, the logger
    and the results export. No sign-in ever happens: Connect-MigrationTeams itself is a stub,
    and the mutating stubs (Set-CsPhoneNumberAssignment / Grant-CsOnlineVoiceRoutingPolicy)
    throw if reached under -DryRun, which -DryRun must prevent.

    Author: AutomationHub
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script under test binds, including ones a particular test does not read; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Set-CsPhoneNumberAssignment and Grant-CsOnlineVoiceRoutingPolicy here are stand-ins named after the real cmdlets so the script under test resolves them. They change nothing, so ShouldProcess would be meaningless.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
    Justification = 'Connect-MigrationTeams mirrors the module function it shadows; Teams is a product name.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The mutating stubs run inside the script under test, whose scope chain does not reach this file''s script scope, so calls they receive are captured in a global list and removed again in AfterAll.')]
param()

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:scriptPath = Join-Path $PSScriptRoot '..' 'Set-MigrationTeamsPhoneAssignments.ps1'
    $script:fixtureCsv = Join-Path $PSScriptRoot 'Fixtures' 'Set-MigrationTeamsPhoneAssignments' 'Destination_Assignments.csv'
    $script:workspaces = [System.Collections.Generic.List[string]]::new()

    <#
        The stub tenant.
          mary.jones     the destination owner of +15551110000;ext=524 - the SAME base number
                         a resource account (obj-aa) holds as its bare main line. The ownership
                         check must key on the full number with the extension, or this row
                         wrongly reads as a conflict with the AA.
          other.target   resolves fine, but +15553330000 is already assigned to obj-owner in
                         the inventory - a genuine conflict that must Fail.
          newuser        +15552220000 is unassigned in the inventory - type auto-detects from
                         the inventory entry (DirectRouting) rather than defaulting blind.
          badloc.user    CSV row carries a LocationId that does not exist in this tenant - the
                         assignment must still succeed, just without a location.
    #>
    function Get-StubTeamsUser {
        return @(
            [pscustomobject]@{ Identity = 'obj-mary'; UserPrincipalName = 'mary.jones@newco.onmicrosoft.com'; DisplayName = 'Mary Jones' }
            [pscustomobject]@{ Identity = 'obj-target'; UserPrincipalName = 'other.target@newco.onmicrosoft.com'; DisplayName = 'Other Target' }
            [pscustomobject]@{ Identity = 'obj-new'; UserPrincipalName = 'newuser@newco.onmicrosoft.com'; DisplayName = 'New User' }
            [pscustomobject]@{ Identity = 'obj-badloc'; UserPrincipalName = 'badloc.user@newco.onmicrosoft.com'; DisplayName = 'Bad Location User' }
            [pscustomobject]@{ Identity = 'obj-typo'; UserPrincipalName = 'typo.user@newco.onmicrosoft.com'; DisplayName = 'Typo User' }
            [pscustomobject]@{ Identity = 'obj-blank'; UserPrincipalName = 'blank.user@newco.onmicrosoft.com'; DisplayName = 'Blank User' }
            [pscustomobject]@{ Identity = 'obj-solo'; UserPrincipalName = 'solo.user@newco.onmicrosoft.com'; DisplayName = 'Solo User' }
        )
    }

    function Initialize-MigrationModule {
        param([string[]]$Name, [string]$MinimumVersion)
    }

    function Connect-MigrationTeams {
        param([string]$TenantId, [switch]$Reconnect)
        return [pscustomobject]@{ TenantId = 'newco-tenant-guid'; DisplayName = 'Newco' }
    }

    function Resolve-MigrationTeamsUser {
        param([string]$Identity)
        return Get-StubTeamsUser | Where-Object { $_.UserPrincipalName -eq $Identity -or $_.Identity -eq $Identity } | Select-Object -First 1
    }

    function Get-CsOnlineUser {
        param($Identity, $Filter, $ErrorAction)
        return Get-StubTeamsUser
    }

    function Get-MigrationPhoneNumberInventory {
        param([hashtable]$Filter, [int]$PageSize)
        return @(
            [pscustomobject]@{ TelephoneNumber = '+15551110000'; AssignedPstnTargetId = 'obj-aa'; NumberType = 'CallingPlan'; LocationId = 'loc-aa' }
            [pscustomobject]@{ TelephoneNumber = '+15551110000;ext=524'; AssignedPstnTargetId = 'obj-mary'; NumberType = 'CallingPlan'; LocationId = 'loc-good' }
            [pscustomobject]@{ TelephoneNumber = '+15553330000'; AssignedPstnTargetId = 'obj-owner'; NumberType = 'CallingPlan'; LocationId = '' }
            [pscustomobject]@{ TelephoneNumber = '+15552220000'; AssignedPstnTargetId = ''; NumberType = 'DirectRouting'; LocationId = '' }
        )
    }

    function Get-CsOnlineLisLocation {
        param($LocationId, $ErrorAction)
        if ($LocationId -eq 'loc-good') { return [pscustomobject]@{ LocationId = 'loc-good'; Description = 'HQ' } }
        throw "Location '$LocationId' was not found."
    }

    function Set-CsPhoneNumberAssignment {
        param($Identity, $PhoneNumber, $PhoneNumberType, $LocationId, $ErrorAction)
        if ($global:currentDryRun) {
            throw 'Set-CsPhoneNumberAssignment was reached, which -DryRun must have prevented.'
        }
        $global:setPhoneCalls.Add([pscustomobject]@{ Identity = $Identity; PhoneNumber = $PhoneNumber; PhoneNumberType = $PhoneNumberType; LocationId = $LocationId })
    }

    function Grant-CsOnlineVoiceRoutingPolicy {
        param($Identity, $PolicyName, $ErrorAction)
        if ($global:currentDryRun) {
            throw 'Grant-CsOnlineVoiceRoutingPolicy was reached, which -DryRun must have prevented.'
        }
        $global:grantPolicyCalls.Add([pscustomobject]@{ Identity = $Identity; PolicyName = $PolicyName })
    }

    # Runs the script into a throwaway workspace and hands back everything a test may need.
    # 'exit' inside a script run with '&' ends that script only and sets $LASTEXITCODE.
    function Invoke-ScriptUnderTest {
        param([hashtable]$Arguments)

        $workspace = Join-Path ([System.IO.Path]::GetTempPath()) "SetTeamsPhone-$([guid]::NewGuid())"
        $null = New-Item -Path $workspace -ItemType Directory -Force
        $script:workspaces.Add($workspace)

        $global:setPhoneCalls = [System.Collections.Generic.List[object]]::new()
        $global:grantPolicyCalls = [System.Collections.Generic.List[object]]::new()
        $global:currentDryRun = $Arguments.ContainsKey('DryRun') -and [bool]$Arguments['DryRun']

        & $script:scriptPath @Arguments -OutputPath $workspace -Verbosity Low
        $exitCode = $LASTEXITCODE

        $csv = @(Get-ChildItem -LiteralPath $workspace -Filter 'Set-TeamsPhoneAssignments-*.csv')
        $log = @(Get-ChildItem -LiteralPath $workspace -Filter '*.log')
        return [pscustomobject]@{
            ExitCode         = $exitCode
            ResultFile       = if ($csv.Count -eq 1) { $csv[0].Name } else { $null }
            Rows             = if ($csv.Count -eq 1) { @(Import-Csv -LiteralPath $csv[0].FullName) } else { @() }
            Log              = if ($log.Count -ge 1) { Get-Content -LiteralPath $log[0].FullName -Raw } else { '' }
            SetPhoneCalls    = @($global:setPhoneCalls)
            GrantPolicyCalls = @($global:grantPolicyCalls)
        }
    }
}

AfterAll {
    foreach ($workspace in $script:workspaces) {
        if (Test-Path -LiteralPath $workspace) {
            Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Variable -Name setPhoneCalls, grantPolicyCalls, currentDryRun -Scope Global -ErrorAction SilentlyContinue
}

Describe 'DryRun over a CSV of assignments' {

    BeforeAll {
        $script:dryRun = Invoke-ScriptUnderTest -Arguments @{ CsvPath = $script:fixtureCsv; DryRun = $true }
        $script:dryRows = @{}
        foreach ($row in $script:dryRun.Rows) { $script:dryRows[$row.Identity] = $row }
    }

    It 'Writes a DryRun-named results file with one row per CSV user' {
        $script:dryRun.ResultFile | Should -Match 'Set-TeamsPhoneAssignments-DryRun_'
        $script:dryRun.Rows.Count | Should -Be 6
    }

    It 'Never reaches Set-CsPhoneNumberAssignment or Grant-CsOnlineVoiceRoutingPolicy' {
        $script:dryRun.SetPhoneCalls.Count | Should -Be 0
        $script:dryRun.GrantPolicyCalls.Count | Should -Be 0
    }

    It 'Starts every row with Identity, Action, Status, Detail and carries the round-trip columns' {
        $columns = @($script:dryRun.Rows[0].PSObject.Properties.Name)
        $columns[0..3] | Should -Be @('Identity', 'Action', 'Status', 'Detail')
        $columns | Should -Contain 'PhoneNumberType'
        $columns | Should -Contain 'LocationId'
        $columns | Should -Contain 'OnlineVoiceRoutingPolicy'
    }

    It 'Plans a user extension whose base number a different target holds, instead of reporting a false conflict' {
        $row = $script:dryRows['mary.jones@newco.onmicrosoft.com']
        $row.Status | Should -BeExactly 'Planned'
        $row.PhoneNumber | Should -Be '+15551110000;ext=524'
        $row.Detail | Should -Not -Match 'already assigned'
    }

    It 'Fails a number genuinely assigned to a different target' {
        $row = $script:dryRows['other.target@newco.onmicrosoft.com']
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match 'already assigned to another target'
    }

    It 'Auto-detects the number type from the inventory for an unassigned number' {
        $row = $script:dryRows['newuser@newco.onmicrosoft.com']
        $row.Status | Should -BeExactly 'Planned'
        $row.PhoneNumberType | Should -Be 'DirectRouting'
    }

    It 'Plans an assignment with an unresolvable source LocationId, dropping it and noting the row' {
        $row = $script:dryRows['badloc.user@newco.onmicrosoft.com']
        $row.Status | Should -BeExactly 'Planned'
        $row.Detail | Should -Match 'assign an emergency location manually'
    }

    It 'Fails a malformed phone number rather than skipping it silently' {
        $row = $script:dryRows['typo.user@newco.onmicrosoft.com']
        $row.Status | Should -BeExactly 'Failed'
        $row.Detail | Should -Match 'Unparseable phone number'
    }

    It 'Skips a genuinely blank phone number' {
        $row = $script:dryRows['blank.user@newco.onmicrosoft.com']
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'No usable phone number'
    }

    It 'Sets exit code 2 because the run has Failed rows, including the malformed number' {
        $script:dryRun.ExitCode | Should -Be 2
    }
}

Describe 'A live run assigns and grants the policy' {

    BeforeAll {
        $script:live = Invoke-ScriptUnderTest -Arguments @{ User = 'solo.user@newco.onmicrosoft.com'; PhoneNumber = '+15559998888'; VoiceRoutingPolicy = 'US-East'; Confirm = $false }
    }

    It 'Succeeds and reaches Set-CsPhoneNumberAssignment and Grant-CsOnlineVoiceRoutingPolicy' {
        $script:live.Rows[0].Status | Should -BeExactly 'Succeeded'
        $script:live.SetPhoneCalls.Count | Should -Be 1
        $script:live.SetPhoneCalls[0].Identity | Should -Be 'solo.user@newco.onmicrosoft.com'
        $script:live.GrantPolicyCalls.Count | Should -Be 1
        $script:live.GrantPolicyCalls[0].PolicyName | Should -Be 'US-East'
    }

    It 'Exits 0' {
        $script:live.ExitCode | Should -Be 0
    }
}

Describe 'A single unresolvable -LocationId fails the row instead of being silently dropped' {

    BeforeAll {
        $script:badLocationUser = Invoke-ScriptUnderTest -Arguments @{ User = 'solo.user@newco.onmicrosoft.com'; PhoneNumber = '+15559997777'; LocationId = 'loc-bad'; DryRun = $true }
    }

    It 'Fails the row and never resolves to a Planned assignment' {
        $script:badLocationUser.Rows[0].Status | Should -BeExactly 'Failed'
        $script:badLocationUser.Rows[0].Detail | Should -Match "LocationId 'loc-bad' does not exist"
    }
}
