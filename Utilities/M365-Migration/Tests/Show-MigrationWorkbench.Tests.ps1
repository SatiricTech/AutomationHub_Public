#Requires -Version 7.4

<#
    The console workbench loop, driven end to end through the prompt seam.

    Every question Show-MigrationWorkbench, Invoke-MigrationWorkbenchStep and
    Edit-MigrationSettingsInteractive ask goes through Read-MigrationPrompt, so a
    Set-MigrationPromptHandler that returns scripted answers is a whole operator session. Each
    handler below throws when its answers run out, so a loop that asks one question too many
    fails the test in a second instead of hanging the suite.

    Write-Host is mocked inside the module rather than allowed through: the console's output is
    what these tests assert on, and a suite that printed a full workbench board per test would
    be unreadable.

    Invoke-MigrationStep is mocked too, but the driver it would have run is generated for real,
    because the driver is the evidence of what the run would have been - which wave, which
    plan, rehearsal or not - and a mocked driver would prove nothing about the console.

    The workspace is always a copy of Tests/Fixtures/Workbench/Workspace1 under TestDrive: the
    loop writes drivers and settings, and the committed fixture must stay exactly as scanned.

    The captured console and run log live in $global: because a mock body registered with
    -ModuleName runs in the module's own scope, not this file's; $global: is the only scope
    both sides can see.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'A mock body runs in the module scope; $global: is the only scope it and the It blocks share.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'A prompt handler declares the seam''s four arguments whether or not it reads them all.')]
param()

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:FixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Workspace1')).Path

    function Copy-FixtureWorkspace {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that copies the fixture into TestDrive.')]
        param([string]$Name)
        $destination = Join-Path $TestDrive $Name
        Copy-Item -LiteralPath $script:FixtureRoot -Destination $destination -Recurse -Force
        return $destination
    }

    function New-EmptyWorkspace {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that creates a bare workspace folder under TestDrive.')]
        param([string]$Name)
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        return $path
    }

    # Called at the start of every session rather than from a BeforeEach, because several
    # contexts run one session in their BeforeAll and then assert on it from many It blocks.
    function Reset-ConsoleCapture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that clears the captured console and run log.')]
        param()
        $global:MigrationConsole = [System.Collections.Generic.List[string]]::new()
        $global:MigrationStepRuns = [System.Collections.Generic.List[object]]::new()
        $global:MigrationPromptLog = [System.Collections.Generic.List[string]]::new()
    }

    # A scripted operator: the answers in order, and an exception the moment the console asks
    # for one more than the session was written for. GetNewClosure keeps the queue alive after
    # this function returns - a scriptblock carries its session state, not its caller's scope.
    function Set-ScriptedAnswer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that installs a prompt handler for the test.')]
        param([string[]]$Answer)

        Reset-ConsoleCapture
        $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$Answer)
        Set-MigrationPromptHandler -Handler {
            param($Kind, $Message)
            $global:MigrationPromptLog.Add("$Kind|$Message")
            if ($queue.Count -eq 0) { throw "The scripted answers ran out at '$Message'." }
            return $queue.Dequeue()
        }.GetNewClosure()
    }

    # The other kind of session: accept every suggestion the form offers, answer the keys named
    # in -Answer differently, and take the menu keys from -Menu. The settings form's length is
    # the schema's business and not a number a test should have to keep in step with.
    function Set-FormAnswer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that installs a prompt handler for the test.')]
        param([hashtable]$Answer = @{}, [string[]]$Menu = @('Q'))

        Reset-ConsoleCapture
        $menuQueue = [System.Collections.Generic.Queue[string]]::new([string[]]$Menu)
        Set-MigrationPromptHandler -Handler {
            param($Kind, $Message, $Choices, $Default)
            $global:MigrationPromptLog.Add("$Kind|$Message")
            # A cap rather than a queue: a form that re-prompted for ever still has to fail the
            # test rather than hang it.
            if ($global:MigrationPromptLog.Count -gt 200) { throw 'The console asked far too many questions.' }

            if ($Message -like 'Choose*') {
                if ($menuQueue.Count -eq 0) { throw 'The scripted menu keys ran out.' }
                return $menuQueue.Dequeue()
            }
            foreach ($key in $Answer.Keys) {
                if ($Message -like "*$key*") { return $Answer[$key] }
            }
            return $Default
        }.GetNewClosure()
    }

    function Get-ConsoleText {
        return (@($global:MigrationConsole) -join "`n")
    }

    function Get-PromptText {
        return (@($global:MigrationPromptLog) -join "`n")
    }

    # The run result the mocked runner hands back, so the console has something real to render.
    function New-TestRunResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that builds an in-memory result object.')]
        param([string]$StepId, [string]$RunId, [string]$RunFolder, [bool]$TenantVerified = $true, $Summary)
        return [pscustomobject]@{
            RunId              = $RunId
            StepId             = $StepId
            ExitCode           = 0
            Meaning            = 'Completed'
            Aborted            = $false
            Started            = [datetime]'2026-09-18T12:00:00'
            Ended              = [datetime]'2026-09-18T12:01:00'
            StdoutPath         = (Join-Path $RunFolder 'stdout.txt')
            StderrPath         = (Join-Path $RunFolder 'stderr.txt')
            ConnectedTenantIds = @(if ($TenantVerified) { '00000000-0000-0000-0000-000000000000' }
                else { '11111111-1111-1111-1111-111111111111' })
            TenantVerified     = $TenantVerified
            Files              = @()
            Summary            = $Summary
            LedgerEntry        = $null
        }
    }
}

AfterAll {
    # A handler left set would answer the next test file's questions.
    Set-MigrationPromptHandler
}

Describe 'Show-MigrationWorkbench' {

    BeforeAll {
        Mock -ModuleName M365Migration -CommandName Write-Host -MockWith {
            $global:MigrationConsole.Add([string]$Object)
        }

        Mock -ModuleName M365Migration -CommandName Invoke-MigrationStep -MockWith {
            $global:MigrationStepRuns.Add([pscustomobject]@{
                    StepId           = [string]$Step.Id
                    Driver           = $Driver
                    DryRun           = [bool]$DryRun
                    Wave             = @($Wave)
                    GateOverrides    = @($GateOverrides)
                    ExpectedTenantId = [string]$ExpectedTenantId
                    Environment      = $Environment
                })
            return (New-TestRunResult -StepId ([string]$Step.Id) -RunId ([string]$Driver.RunId) `
                    -RunFolder ([string]$Driver.RunFolder) `
                    -Summary ([pscustomobject]@{ Succeeded = 2; Failed = 0; Skipped = 1; Planned = 0 }))
        }
    }

    Context 'a rehearsal of step 6' {

        BeforeAll {
            $script:RehearsalPath = Copy-FixtureWorkspace -Name 'Rehearsal'
            # 6 = Provision users, the whole plan, dry run, yes run it, Enter, quit.
            Set-ScriptedAnswer -Answer @('6', 'all', 'D', 'y', '', 'Q')
            $script:RehearsalResult = Show-MigrationWorkbench -Path $script:RehearsalPath -Version '1.0.0'
            $script:RehearsalRun = @($global:MigrationStepRuns)[0]
            $script:RehearsalConsole = Get-ConsoleText
        }

        It 'runs the provisioning step, once, as a dry run' {
            @($global:MigrationStepRuns).Count | Should -Be 1
            $script:RehearsalRun.StepId | Should -BeExactly 'New-Users'
            $script:RehearsalRun.DryRun | Should -BeTrue
        }

        It 'hands the runner a driver that names the script and the rehearsal' {
            $script:RehearsalRun.Driver.DisplayLine | Should -BeLike '*New-MigrationUsers.ps1*'
            $script:RehearsalRun.Driver.DisplayLine | Should -BeLike '*-DryRun*'
        }

        It 'leaves the driver in the workspace as the record of what ran' {
            $driverPath = [string]$script:RehearsalRun.Driver.DriverPath
            Test-Path -LiteralPath $driverPath | Should -BeTrue
            (Get-Content -LiteralPath $driverPath -Raw) | Should -Match 'DryRun\s+= \$true'
        }

        It 'passes the destination tenant as the one the run must reach' {
            $script:RehearsalRun.ExpectedTenantId | Should -BeExactly '00000000-0000-0000-0000-000000000000'
        }

        It 'shows the resolved arguments with where each value came from' {
            $script:RehearsalConsole | Should -BeLike '*PlanPath*Resolved*'
            $script:RehearsalConsole | Should -BeLike '*Prefix*Contoso*Settings*'
        }

        It 'prints the command it is about to run, and the outcome afterwards' {
            $script:RehearsalConsole | Should -BeLike '*New-MigrationUsers.ps1*'
            $script:RehearsalConsole | Should -BeLike '*Completed*'
            $script:RehearsalConsole | Should -BeLike '*2 Succeeded*'
        }

        It 'returns the run it last made' {
            $script:RehearsalResult.StepId | Should -BeExactly 'New-Users'
        }
    }

    Context 'a destructive live run whose typed confirmation is wrong' {

        BeforeAll {
            $script:RefusedPath = Copy-FixtureWorkspace -Name 'Refused'
            # 11 = Domain release - remediate: live, both soft gates overridden, then the
            # effective release domain typed wrongly.
            Set-ScriptedAnswer -Answer @('11', 'R', 'y', 'y', 'wrong.example', 'B', 'Q')
            $script:RefusedResult = Show-MigrationWorkbench -Path $script:RefusedPath -Version '1.0.0'
            $script:RefusedConsole = Get-ConsoleText
        }

        It 'does not start the run' {
            @($global:MigrationStepRuns).Count | Should -Be 0
            $script:RefusedResult | Should -BeNullOrEmpty
        }

        It 'names the input it expected' {
            $script:RefusedConsole | Should -BeLike '*newco.com*'
            $script:RefusedConsole | Should -BeLike '*not started*'
        }

        It 'records nothing in the workspace for a run that never happened' {
            $runs = Join-Path $script:RefusedPath 'Workbench' 'Runs'
            @(Get-ChildItem -LiteralPath $runs -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It 'asked for the typed confirmation rather than a keypress' {
            Get-PromptText | Should -BeLike "*Type 'newco.com'*"
        }
    }

    Context 'the other views' {

        It 'renders the seventeen scripts for A, and leaves on Q' {
            $path = Copy-FixtureWorkspace -Name 'Tools'
            Set-ScriptedAnswer -Answer @('A', 'Q')
            Show-MigrationWorkbench -Path $path -Version '1.0.0' | Should -BeNullOrEmpty

            Get-ConsoleText | Should -BeLike '*All tools*'
            Get-ConsoleText | Should -BeLike '*New-MigrationUsers.ps1*'
            Get-ConsoleText | Should -BeLike '*Test-MigrationReadiness.ps1*'
        }

        It 'lists the ledger newest first for R' {
            $path = Copy-FixtureWorkspace -Name 'Results'
            Set-ScriptedAnswer -Answer @('R', 'Q')
            Show-MigrationWorkbench -Path $path -Version '1.0.0' | Should -BeNullOrEmpty

            Get-ConsoleText | Should -BeLike '*Results & logs*'
            Get-ConsoleText | Should -BeLike '*Set-Licenses*exit 2*'
        }

        It 'says so, and stays put, when the key means nothing' {
            $path = Copy-FixtureWorkspace -Name 'BadKey'
            Set-ScriptedAnswer -Answer @('Z', '99', 'Q')
            Show-MigrationWorkbench -Path $path -Version '1.0.0' | Should -BeNullOrEmpty
            Get-ConsoleText | Should -BeLike "*'Z'*"
            Get-ConsoleText | Should -BeLike '*99*'
        }
    }

    Context 'a workspace with no settings yet' {

        BeforeAll {
            $script:GreenfieldPath = New-EmptyWorkspace -Name 'Greenfield'
            Set-FormAnswer -Answer @{ 'Label' = 'Greenfield' }
            Show-MigrationWorkbench -Path $script:GreenfieldPath -Version '1.0.0' | Out-Null
            $script:GreenfieldAsked = @($global:MigrationPromptLog)
            $script:GreenfieldSettings = Resolve-MigrationSettings `
                -Path (Join-Path $script:GreenfieldPath 'M365Migration.settings.json')
        }

        It 'runs the settings form first and leaves a valid settings file behind' {
            $script:GreenfieldSettings.Exists | Should -BeTrue
            $script:GreenfieldSettings.IsValid | Should -BeTrue
            $script:GreenfieldSettings.Settings.Label | Should -BeExactly 'Greenfield'
            $script:GreenfieldSettings.Settings.Scenario | Should -BeExactly 'TenantToTenant'
        }

        It 'asks for every settings key the schema defines except the file format version' {
            $asked = @($script:GreenfieldAsked | Where-Object { $_ -notlike '*Choose*' })
            $expected = @(Get-MigrationSettingsSchema | Where-Object { $_.Key -ne 'SchemaVersion' })
            $asked.Count | Should -Be $expected.Count
            ($asked -join "`n") | Should -BeLike '*Domains.Target*'
            ($asked -join "`n") | Should -Not -BeLike '*SchemaVersion*'
        }

        It 'asks for the scenario as a choice and the booleans as confirmations' {
            ($script:GreenfieldAsked -join "`n") | Should -BeLike '*Choice|Scenario*'
            ($script:GreenfieldAsked -join "`n") | Should -BeLike '*Confirm|Plan.PreserveAliases*'
        }
    }

    Context 'the settings editor reached from the menu' {

        BeforeAll {
            $script:RelabelPath = Copy-FixtureWorkspace -Name 'Relabel'
            Set-FormAnswer -Answer @{ 'Label' = 'Relabelled' } -Menu @('S', 'Q')
            Show-MigrationWorkbench -Path $script:RelabelPath -Version '1.0.0' | Out-Null
        }

        It 'saves the edited label' {
            $settings = Resolve-MigrationSettings -Path (Join-Path $script:RelabelPath 'M365Migration.settings.json')
            $settings.IsValid | Should -BeTrue
            $settings.Settings.Label | Should -BeExactly 'Relabelled'
        }

        It 'rescans afterwards, so the board shows the new label' {
            Get-ConsoleText | Should -BeLike '*Relabelled ·*'
        }
    }
}

Describe 'Edit-MigrationSettingsInteractive' {

    BeforeAll {
        Mock -ModuleName M365Migration -CommandName Write-Host -MockWith {
            $global:MigrationConsole.Add([string]$Object)
        }
    }

    It 'edits a field in place, pre-filled with the values already on disk' {
        $path = Copy-FixtureWorkspace -Name 'EditInPlace'
        Set-FormAnswer -Answer @{ 'Label' = 'Relabelled' }

        $workspace = Get-MigrationWorkspace -Path $path
        InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Edit-MigrationSettingsInteractive -Workspace $Workspace | Out-Null
        }

        $settings = Resolve-MigrationSettings -Path (Join-Path $path 'M365Migration.settings.json')
        $settings.IsValid | Should -BeTrue
        $settings.Settings.Label | Should -BeExactly 'Relabelled'
        # Everything else was accepted as suggested, so it is still what the fixture held.
        $settings.Settings.Domains.Target | Should -BeExactly 'newco.com'
        $settings.Settings.Destination.OnMicrosoftDomain | Should -BeExactly 'newco.onmicrosoft.com'
        $settings.Settings.Defaults.PasswordLength | Should -Be 16
    }

    It 'suggests the commonest destination sign-in domain as the target domain' {
        $path = New-EmptyWorkspace -Name 'DomainSuggestion'
        $destination = Join-Path $path 'Destination'
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        # Two vanity domains and an onmicrosoft one: the vanity domain the most people sign in
        # with is the suggestion, and the tenant's own onmicrosoft domain never is.
        Set-Content -LiteralPath (Join-Path $destination 'Destination_Users_20260917-094000.csv') -Value @(
            '"UserPrincipalName","DisplayName"'
            '"ada@newco.com","Ada"'
            '"grace@newco.com","Grace"'
            '"alan@other.example","Alan"'
            '"svc@newco.onmicrosoft.com","Service"'
        ) -Encoding utf8

        $workspace = Get-MigrationWorkspace -Path $path
        $suggestion = InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Get-MigrationSettingsSuggestion -Workspace $Workspace -Key 'Domains.Target' -Current ''
        }
        $suggestion | Should -BeExactly 'newco.com'
    }

    It 'suggests the folder name as the label of a workspace that has none' {
        $path = New-EmptyWorkspace -Name 'Unlabelled'
        $workspace = Get-MigrationWorkspace -Path $path
        $suggestion = InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Get-MigrationSettingsSuggestion -Workspace $Workspace -Key 'Label' -Current ''
        }
        $suggestion | Should -BeExactly 'Unlabelled'
    }

    It 'says when the target domain is already verified in the destination' {
        $path = Copy-FixtureWorkspace -Name 'InterimHint'
        $workspace = Get-MigrationWorkspace -Path $path
        $hint = InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Get-MigrationSettingsHint -Workspace $Workspace -Key 'Domains.Interim'
        }
        # The fixture's Destination_Domains lists newco.com as verified.
        $hint | Should -BeLike '*already verified in the destination*'
    }

    It 'says that a blank release domain means the target domain' {
        $path = Copy-FixtureWorkspace -Name 'ReleaseHint'
        $workspace = Get-MigrationWorkspace -Path $path
        $hint = InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Get-MigrationSettingsHint -Workspace $Workspace -Key 'Domains.Release'
        }
        $hint | Should -BeLike '*same as Target*'
    }

    It 'keeps a tenant value that will not resolve, and says why' {
        $path = Copy-FixtureWorkspace -Name 'BadTenant'
        Mock -ModuleName M365Migration -CommandName Resolve-MigrationTenantId -MockWith {
            throw "Tenant '$Tenant' could not be resolved to a tenant ID: no such host is known."
        }
        Set-FormAnswer -Answer @{ 'Source.TenantId' = 'nowhere.example' }

        $workspace = Get-MigrationWorkspace -Path $path
        InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Edit-MigrationSettingsInteractive -Workspace $Workspace | Out-Null
        }

        Get-ConsoleText | Should -BeLike '*could not be resolved*'
        # Kept as typed, so it is the validator that names the key rather than the form
        # silently emptying a field the operator filled in - and nothing invalid is written.
        Get-ConsoleText | Should -BeLike "*Key 'Source.TenantId'*"
        Get-ConsoleText | Should -BeLike '*were not saved*'
        $raw = Get-Content -LiteralPath (Join-Path $path 'M365Migration.settings.json') -Raw
        $raw | Should -Not -BeLike '*nowhere.example*'
    }

    It 'resolves a tenant domain to its GUID' {
        $path = Copy-FixtureWorkspace -Name 'GoodTenant'
        Mock -ModuleName M365Migration -CommandName Resolve-MigrationTenantId -MockWith {
            return '22222222-2222-2222-2222-222222222222'
        }
        Set-FormAnswer -Answer @{ 'Destination.TenantId' = 'newco.com' }

        $workspace = Get-MigrationWorkspace -Path $path
        InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Edit-MigrationSettingsInteractive -Workspace $Workspace | Out-Null
        }

        $settings = Resolve-MigrationSettings -Path (Join-Path $path 'M365Migration.settings.json')
        $settings.Settings.Destination.TenantId | Should -BeExactly '22222222-2222-2222-2222-222222222222'
    }

    It 'parses an alias domain map typed as old=new pairs' {
        $path = Copy-FixtureWorkspace -Name 'AliasMap'
        Set-FormAnswer -Answer @{ 'AliasDomainMap' = 'old.example=new.example;two.example=three.example' }

        $workspace = Get-MigrationWorkspace -Path $path
        InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Edit-MigrationSettingsInteractive -Workspace $Workspace | Out-Null
        }

        $settings = Resolve-MigrationSettings -Path (Join-Path $path 'M365Migration.settings.json')
        $settings.IsValid | Should -BeTrue
        $settings.Settings.Plan.AliasDomainMap.'old.example' | Should -BeExactly 'new.example'
        $settings.Settings.Plan.AliasDomainMap.'two.example' | Should -BeExactly 'three.example'
    }

    It 're-prompts only the keys that failed validation' {
        $path = Copy-FixtureWorkspace -Name 'Revalidate'
        Reset-ConsoleCapture
        # A label the validator rejects, then one it accepts: only Label is asked twice.
        $labels = [System.Collections.Generic.Queue[string]]::new([string[]]@('Not A Label!', 'Accepted'))
        Set-MigrationPromptHandler -Handler {
            param($Kind, $Message, $Choices, $Default)
            $global:MigrationPromptLog.Add("$Kind|$Message")
            if ($global:MigrationPromptLog.Count -gt 200) { throw 'The console asked far too many questions.' }
            if ($Message -like '*Label*' -and $labels.Count -gt 0) { return $labels.Dequeue() }
            return $Default
        }.GetNewClosure()

        $workspace = Get-MigrationWorkspace -Path $path
        InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            Edit-MigrationSettingsInteractive -Workspace $Workspace | Out-Null
        }

        @($global:MigrationPromptLog | Where-Object { $_ -like '*Label*' }).Count | Should -Be 2
        @($global:MigrationPromptLog | Where-Object { $_ -like '*Domains.Target*' }).Count | Should -Be 1

        $settings = Resolve-MigrationSettings -Path (Join-Path $path 'M365Migration.settings.json')
        $settings.Settings.Label | Should -BeExactly 'Accepted'
    }
}

Describe 'Invoke-MigrationWorkbenchStep' {

    BeforeAll {
        Mock -ModuleName M365Migration -CommandName Write-Host -MockWith {
            $global:MigrationConsole.Add([string]$Object)
        }

        Mock -ModuleName M365Migration -CommandName Invoke-MigrationStep -MockWith {
            $global:MigrationStepRuns.Add([pscustomobject]@{
                    StepId        = [string]$Step.Id
                    Driver        = $Driver
                    DryRun        = [bool]$DryRun
                    Wave          = @($Wave)
                    GateOverrides = @($GateOverrides)
                    Environment   = $Environment
                })
            return (New-TestRunResult -StepId ([string]$Step.Id) -RunId ([string]$Driver.RunId) `
                    -RunFolder ([string]$Driver.RunFolder) -TenantVerified $false -Summary $null)
        }

        function Invoke-TestStep {
            param([string]$Id, [string]$Path, [switch]$Live)
            $workspace = Get-MigrationWorkspace -Path $Path
            return InModuleScope M365Migration -Parameters @{
                Workspace = $workspace; Id = $Id; Live = [bool]$Live
            } {
                param($Workspace, $Id, $Live)
                Invoke-MigrationWorkbenchStep -Step (Get-MigrationStep -Id $Id) -Workspace $Workspace `
                    -Live:$Live
            }
        }
    }

    It 'limits the run to the wave the operator picked' {
        Set-ScriptedAnswer -Answer @('2', 'D', 'y')
        Invoke-TestStep -Id 'New-Users' -Path (Copy-FixtureWorkspace -Name 'WavePick') | Out-Null

        @($global:MigrationStepRuns)[0].Wave | Should -Be @('2')
        @($global:MigrationStepRuns)[0].Driver.DisplayLine | Should -BeLike '*-Wave 2*'
    }

    It 'shouts about a tenant mismatch and names the tenant that answered' {
        Set-ScriptedAnswer -Answer @('all', 'D', 'y')
        Invoke-TestStep -Id 'New-Users' -Path (Copy-FixtureWorkspace -Name 'Mismatch') | Out-Null

        Get-ConsoleText | Should -BeLike '*TENANT MISMATCH*'
        Get-ConsoleText | Should -BeLike '*11111111-1111-1111-1111-111111111111*'
    }

    It 'lets the operator edit a value before the run, and shows where it came from' {
        Set-ScriptedAnswer -Answer @('all', 'E', 'DefaultUsageLocation', 'GB', 'D', 'y')
        Invoke-TestStep -Id 'New-Users' -Path (Copy-FixtureWorkspace -Name 'EditValue') | Out-Null

        @($global:MigrationStepRuns)[0].Driver.DisplayLine | Should -BeLike '*-DefaultUsageLocation GB*'
        Get-ConsoleText | Should -BeLike '*DefaultUsageLocation*Operator*'
    }

    It 'backs out without running anything' {
        Set-ScriptedAnswer -Answer @('all', 'B')
        $result = Invoke-TestStep -Id 'New-Users' -Path (Copy-FixtureWorkspace -Name 'BackOut')

        $result | Should -BeNullOrEmpty
        @($global:MigrationStepRuns).Count | Should -Be 0
    }

    It 'prints a command that could be pasted back, without running it' {
        Set-ScriptedAnswer -Answer @('all', 'C', 'B')
        Invoke-TestStep -Id 'New-Users' -Path (Copy-FixtureWorkspace -Name 'CommandOnly') | Out-Null

        @($global:MigrationStepRuns).Count | Should -Be 0
        Get-ConsoleText | Should -BeLike '*-NoProfile -NonInteractive -ExecutionPolicy Bypass -File*'
    }

    It 'declining the last confirmation leaves the step unrun' {
        Set-ScriptedAnswer -Answer @('all', 'D', 'n', 'B')
        Invoke-TestStep -Id 'New-Users' -Path (Copy-FixtureWorkspace -Name 'Declined') | Out-Null

        @($global:MigrationStepRuns).Count | Should -Be 0
    }

    It 'records an overridden soft gate so the ledger says the operator was asked' {
        # A live run over the whole plan: WaveRequired is the soft gate, overridden.
        Set-ScriptedAnswer -Answer @('all', 'R', 'y', 'y')
        Invoke-TestStep -Id 'New-Users' -Path (Copy-FixtureWorkspace -Name 'SoftOverride') -Live | Out-Null

        $overrides = @(@($global:MigrationStepRuns)[0].GateOverrides)
        $overrides.Count | Should -BeGreaterThan 0
        $overrides[0] | Should -BeLike 'WaveRequired:*'
        @($global:MigrationStepRuns)[0].DryRun | Should -BeFalse
    }

    It 'does not gate a rehearsal on the soft gates a live run would have to clear' {
        # The same step, rehearsed: no override is asked for, so the scripted answers do not
        # include one and would throw if the console asked.
        Set-ScriptedAnswer -Answer @('all', 'D', 'y')
        Invoke-TestStep -Id 'New-Users' -Path (Copy-FixtureWorkspace -Name 'RehearsalGates') | Out-Null

        @($global:MigrationStepRuns).Count | Should -Be 1
        @(@($global:MigrationStepRuns)[0].GateOverrides).Count | Should -Be 0
    }

    It 'asks for the Viva Learning secret and passes it only through the environment' {
        Set-ScriptedAnswer -Answer @('D', 'not-a-real-secret', 'y')
        Invoke-TestStep -Id 'VivaLearning-Import' -Path (Copy-FixtureWorkspace -Name 'VivaSecret') | Out-Null

        $run = @($global:MigrationStepRuns)[0]
        $run.Environment.M365MIGRATION_CLIENT_SECRET | Should -BeExactly 'not-a-real-secret'
        $driver = Get-Content -LiteralPath ([string]$run.Driver.DriverPath) -Raw
        $driver | Should -Match 'ConvertTo-SecureString \$env:M365MIGRATION_CLIENT_SECRET'
        $driver | Should -Not -Match 'not-a-real-secret'
        Get-ConsoleText | Should -Not -BeLike '*not-a-real-secret*'
    }

    It 'lists the mandatory parameters a run is still missing' {
        Set-ScriptedAnswer -Answer @('D', 'not-a-real-secret', 'y')
        Invoke-TestStep -Id 'VivaLearning-Import' -Path (Copy-FixtureWorkspace -Name 'Missing') | Out-Null

        Get-ConsoleText | Should -BeLike '*CsvPath*'
        Get-ConsoleText | Should -BeLike '*still needs*'
    }
}
