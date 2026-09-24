#Requires -Version 7.4

<#
    The four run rules the three front ends used to restate, now owned by the engine
    (Docs/Workbench-Design.md, sections 7.1, 7.2, 8, 9 and 10): which parameters the workbench
    decides for itself, whether a workspace may be run against at all, whether a typed
    confirmation clears a hard gate, how a map is read out of a text box, and what to say about
    the tenant a finished run actually reached.

    Each of these was a Minor or Important finding of the whole-branch review whose shape was
    the same: a rule the WinForms fix rounds established that the console and the unattended
    path did not share. They are tested here, once, because that is now where they live.
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:FixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Workspace1')).Path
}

Describe 'Get-MigrationWorkbenchOwnedParameter' {

    It 'Names exactly the nine parameters the workbench decides for every run' {
        Get-MigrationWorkbenchOwnedParameter | Should -Be @(
            'DryRun', 'Wave', 'OutputPath', 'TenantId', 'LogPath', 'Confirm', 'WhatIf', 'Verbose', 'Debug')
    }

    It 'Is one list, so a front end cannot filter on a different set than the resolver drops' {
        # The window's form filter, the window's override converter, the console's E action and
        # Resolve-MigrationStepArguments all read this. A second copy anywhere is the bug.
        $first = @(Get-MigrationWorkbenchOwnedParameter)
        $second = @(Get-MigrationWorkbenchOwnedParameter)
        $second | Should -Be $first
    }
}

Describe 'Test-MigrationWorkspaceRunnable' {

    BeforeAll {
        $script:GoodWorkspace = Get-MigrationWorkspace -Path $script:FixtureRoot

        $script:BrokenPath = Join-Path $TestDrive 'RunnableRefusal'
        Copy-Item -LiteralPath $script:FixtureRoot -Destination $script:BrokenPath -Recurse -Force

        # Label blanked and nothing else: the smallest edit that makes a settings document fail
        # validation, and the one whose consequences an operator notices least.
        $settingsPath = Join-Path $script:BrokenPath 'M365Migration.settings.json'
        $document = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $document.Label = ''
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsPath
        $script:BrokenWorkspace = Get-MigrationWorkspace -Path $script:BrokenPath
    }

    It 'Lets a workspace whose settings validate run' {
        $verdict = Test-MigrationWorkspaceRunnable -Workspace $script:GoodWorkspace
        $verdict.CanRun | Should -BeTrue
        $verdict.Keys | Should -HaveCount 0
        $verdict.Reason | Should -BeExactly ''
    }

    It 'Refuses a workspace whose Label was blanked, and names the key to fix' {
        $script:BrokenWorkspace.SettingsResult.IsValid | Should -BeFalse
        $verdict = Test-MigrationWorkspaceRunnable -Workspace $script:BrokenWorkspace
        $verdict.CanRun | Should -BeFalse
        $verdict.Keys | Should -Contain 'Label'
        $verdict.Reason | Should -BeLike '*Label*'
        $verdict.Reason | Should -BeLike '*Settings*'
    }

    It 'Refuses before a workspace is open at all' {
        $verdict = Test-MigrationWorkspaceRunnable -Workspace $null
        $verdict.CanRun | Should -BeFalse
        $verdict.Reason | Should -BeLike '*workspace*'
    }
}

Describe 'Test-MigrationTypedConfirmation' {

    It 'Accepts a domain without case, because DNS has none' {
        Test-MigrationTypedConfirmation -Typed 'NEWCO.COM' -Required 'newco.com' | Should -BeTrue
        Test-MigrationTypedConfirmation -Typed '  newco.com  ' -Required 'newco.com' | Should -BeTrue
    }

    It 'Demands the case of a keyword, because shouting it is the point' {
        Test-MigrationTypedConfirmation -Typed 'REMOVE' -Required 'REMOVE' | Should -BeTrue
        Test-MigrationTypedConfirmation -Typed 'remove' -Required 'REMOVE' | Should -BeFalse
    }

    It 'Refuses a gate that names nothing to type rather than treating it as satisfied' {
        Test-MigrationTypedConfirmation -Typed '' -Required '' | Should -BeFalse
        Test-MigrationTypedConfirmation -Typed 'anything' -Required '' | Should -BeFalse
    }

    It 'Refuses an empty answer to a gate that does name something' {
        Test-MigrationTypedConfirmation -Typed '' -Required 'newco.com' | Should -BeFalse
    }
}

Describe 'ConvertFrom-MigrationMapText' {

    It 'Reads the settings form''s semicolon-separated pairs' {
        $map = ConvertFrom-MigrationMapText -Text 'old.com=new.com;legacy.com=new.com'
        @($map.Keys) | Should -Be @('old.com', 'legacy.com')
        $map['legacy.com'] | Should -BeExactly 'new.com'
    }

    It 'Reads the window''s one-pair-per-line editor the same way' {
        $map = ConvertFrom-MigrationMapText -Text "old.com=new.com`r`nlegacy.com=new.com"
        @($map.Keys) | Should -Be @('old.com', 'legacy.com')
    }

    It 'Trims both sides of each pair' {
        (ConvertFrom-MigrationMapText -Text '  old.com  =  new.com  ')['old.com'] | Should -BeExactly 'new.com'
    }

    It 'Skips a line with no separator, and one whose key is blank' {
        # A blank key binds and then matches nothing, which is worse than no entry at all.
        $map = ConvertFrom-MigrationMapText -Text 'nonsense;=new.com;old.com=new.com'
        @($map.Keys) | Should -Be @('old.com')
    }

    It 'Reads empty text as an empty map, which is how a map is cleared' {
        @((ConvertFrom-MigrationMapText -Text '').Keys) | Should -HaveCount 0
        @((ConvertFrom-MigrationMapText -Text $null).Keys) | Should -HaveCount 0
    }

    It 'Keeps a value that itself contains an equals sign' {
        (ConvertFrom-MigrationMapText -Text 'a=b=c')['a'] | Should -BeExactly 'b=c'
    }
}

Describe 'Format-MigrationTenantVerdict' {

    BeforeAll {
        function New-VerdictResult {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Pester helper that builds an in-memory run result.')]
            param($TenantVerified, [string[]]$Connected = @(), [string]$Expected = '')
            return [pscustomobject]@{
                TenantVerified     = $TenantVerified
                ConnectedTenantIds = @($Connected)
                ExpectedTenantId   = $Expected
            }
        }
    }

    It 'Says nothing was checked when the step signs in to nothing' {
        Format-MigrationTenantVerdict -Result (New-VerdictResult -TenantVerified $null) |
            Should -BeExactly 'No tenant was expected for this step, so none was checked.'
    }

    It 'Says the tenant was verified when every line named the expected one' {
        Format-MigrationTenantVerdict -Result (New-VerdictResult -TenantVerified $true `
                -Connected @('11111111-1111-1111-1111-111111111111')) |
            Should -BeExactly 'Tenant verified.'
    }

    It 'Names the tenants a mismatched run actually reached' {
        Format-MigrationTenantVerdict -Result (New-VerdictResult -TenantVerified $false `
                -Connected @('22222222-2222-2222-2222-222222222222') `
                -Expected '11111111-1111-1111-1111-111111111111') |
            Should -BeExactly ('This run signed in to 22222222-2222-2222-2222-222222222222, which is not ' +
                'the tenant it was given.')
    }

    It 'Calls a run that printed no tenant line a sign-in failure, not a mismatch' {
        # 'Signed in to no tenant at all' sends an operator looking for a wrong GUID that was
        # never there. Nothing connected is the step not signing in, or its connector saying
        # nothing - and the expected GUID is what they check next.
        $verdict = Format-MigrationTenantVerdict -Result (New-VerdictResult -TenantVerified $false `
                -Expected '11111111-1111-1111-1111-111111111111')
        $verdict | Should -BeExactly ("No tenant line was found in the run's output — the step did not " +
            'sign in, or its connector printed nothing; expected 11111111-1111-1111-1111-111111111111.')
        $verdict | Should -Not -BeLike '*no tenant at all*'
    }

    It 'Falls back to the ledger entry for the tenant that was expected' {
        $result = [pscustomobject]@{
            TenantVerified     = $false
            ConnectedTenantIds = @()
            LedgerEntry        = [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111' }
        }
        Format-MigrationTenantVerdict -Result $result |
            Should -BeLike '*expected 11111111-1111-1111-1111-111111111111.'
    }
}
