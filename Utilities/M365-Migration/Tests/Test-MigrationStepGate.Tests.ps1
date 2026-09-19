#Requires -Version 7.4

<#
    Test-MigrationStepGate returns the safety gates of Docs/Workbench-Design.md section 7.2 as
    data, so the console and the WinForms workbench can render the same checklist without
    either of them holding an opinion about when a live run is allowed.

    The gates are asserted against the committed fixture
    (Tests/Fixtures/Workbench/Workspace1), which is a migration caught mid-flight: the plan is
    stamped 10:15, the provisioning rehearsal 10:31, and licences have been half-assigned. The
    cases the fixture cannot show - a rehearsal older than the plan, a ledger that disagrees
    with the files, a destructive step on the destination - are built in $TestDrive.
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Workspace1'

    function Get-Gate {
        param($Gates, [string]$Kind)
        $matched = @($Gates | Where-Object { $null -ne $_ -and $_.Kind -eq $Kind })
        if ($matched.Count -eq 0) { return $null }
        return $matched[0]
    }

    function Test-HasGate {
        param($Gates, [string]$Kind)
        return (@($Gates | Where-Object { $null -ne $_ -and $_.Kind -eq $Kind }).Count -gt 0)
    }

    # Resolving and gating always happen together: the gates read the wave off the resolved
    # arguments, so a test that made one up could disagree with what would actually run.
    function Get-StepGate {
        param($Workspace, [string]$Id, [switch]$Live, [string[]]$Wave, [hashtable]$Override, $Step)
        if (-not $Step) { $Step = Get-MigrationStep -Id $Id }

        $resolveArgs = @{ Step = $Step; Workspace = $Workspace }
        if ($PSBoundParameters.ContainsKey('Wave')) { $resolveArgs['Wave'] = $Wave }
        if ($PSBoundParameters.ContainsKey('Override')) { $resolveArgs['Override'] = $Override }
        if (-not $Live) { $resolveArgs['DryRun'] = $true }
        $resolved = Resolve-MigrationStepArguments @resolveArgs

        # The comma keeps an empty list an empty list: a step with no gates at all is a normal
        # answer, and a bare return would flatten it to nothing.
        return , @(Test-MigrationStepGate -Step $Step -Arguments $resolved -Workspace $Workspace -Live:$Live)
    }

    # A fixture copy the test may edit; the committed one must stay exactly as scanned.
    function Copy-FixtureWorkspace {
        param([string]$Name)
        $destination = Join-Path $TestDrive $Name
        Copy-Item -LiteralPath $script:FixtureRoot -Destination $destination -Recurse -Force
        return $destination
    }

    function Add-LedgerEntry {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that appends to the ledger of a test workspace.')]
        param(
            [string]$WorkspacePath, [string]$StepId, [bool]$DryRun, [string[]]$Wave, [string]$Started,
            [int]$ExitCode = 0, [bool]$Aborted = $false
        )
        $entry = [ordered]@{
            Started  = $Started
            Ended    = $Started
            StepId   = $StepId
            Script   = 'New-MigrationUsers'
            Side     = 'Destination'
            DryRun   = $DryRun
            Wave     = @($Wave)
            ExitCode = $ExitCode
            Aborted  = $Aborted
            Files    = @()
        }
        $path = Join-Path $WorkspacePath 'Workbench' 'Runs.jsonl'
        Add-Content -LiteralPath $path -Value ($entry | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8
    }
}

Describe 'Test-MigrationStepGate against the committed fixture' {

    BeforeAll {
        $script:Workspace = Get-MigrationWorkspace -Path $script:FixtureRoot
    }

    Context 'the shape of the answer' {

        It 'returns every gate, satisfied ones included, so a UI can draw a checklist' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users' -Live
            @($gates).Count | Should -BeGreaterThan 1
            @($gates | Where-Object { $_.Satisfied }).Count | Should -BeGreaterThan 0
        }

        It 'gives every gate the five fields section 7.2 defines' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users' -Live
            foreach ($gate in $gates) {
                @($gate.PSObject.Properties.Name) |
                    Should -Be @('Kind', 'Severity', 'Satisfied', 'Message', 'RequiredInput')
                $gate.Message | Should -Not -BeNullOrEmpty
            }
        }

        It 'never produces TenantMismatch, which is judged after the run from the log' {
            foreach ($id in @('New-Users', 'DomainReferences-Remediate', 'Set-Licenses', 'Inventory-Source')) {
                $gates = Get-StepGate -Workspace $script:Workspace -Id $id -Live
                Test-HasGate $gates 'TenantMismatch' | Should -BeFalse -Because $id
            }
        }
    }

    Context 'DryRunFirst' {

        It 'is satisfied for a live run when the rehearsal is newer than the plan' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users' -Live
            $gate = Get-Gate $gates 'DryRunFirst'
            $gate.Severity | Should -BeExactly 'Soft'
            $gate.Satisfied | Should -BeTrue
        }

        It 'is not offered at all when the run itself is the rehearsal' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users'
            Test-HasGate $gates 'DryRunFirst' | Should -BeFalse
        }

        It 'is not offered for a step that only reads' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'Inventory-Source' -Live
            Test-HasGate $gates 'DryRunFirst' | Should -BeFalse
        }

        It 'is unsatisfied for a destructive step that has never been rehearsed' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'DomainReferences-Remediate' -Live
            (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeFalse
        }
    }

    Context 'TypedConfirmation' {

        It 'demands the source domain, typed, before a destructive source-side step' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'DomainReferences-Remediate' -Live
            $gate = Get-Gate $gates 'TypedConfirmation'
            $gate.Severity | Should -BeExactly 'Hard'
            $gate.Satisfied | Should -BeFalse
            $gate.RequiredInput | Should -BeExactly 'newco.com'
        }

        It 'leaves a source-side reader alone' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'DomainReferences-Report' -Live
            Test-HasGate $gates 'TypedConfirmation' | Should -BeFalse
        }

        It 'leaves an ordinary destination writer alone' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users' -Live
            Test-HasGate $gates 'TypedConfirmation' | Should -BeFalse
        }

        It 'applies to a source-side write even when it is not destructive' {
            $step = Get-MigrationStep -Id 'Set-Licenses'
            $step.Side = 'Source'
            $step.Impact = 'Write'
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'Set-Licenses' -Step $step -Live
            (Get-Gate $gates 'TypedConfirmation').RequiredInput | Should -BeExactly 'newco.com'
        }

        It 'asks for the word REMOVE when the destructive step is on the destination' {
            $step = Get-MigrationStep -Id 'Set-Licenses'
            $step.Impact = 'Destructive'
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'Set-Licenses' -Step $step -Live
            $gate = Get-Gate $gates 'TypedConfirmation'
            $gate.RequiredInput | Should -BeExactly 'REMOVE'
            $gate.Severity | Should -BeExactly 'Hard'
        }

        It 'is asked for on a rehearsal too, because the source tenant is still the source tenant' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'DomainReferences-Remediate'
            Test-HasGate $gates 'TypedConfirmation' | Should -BeTrue
        }
    }

    Context 'Prerequisite' {

        It 'names the step that is not done yet' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'Set-Licenses' -Live
            $gate = Get-Gate $gates 'Prerequisite'
            $gate.Severity | Should -BeExactly 'Soft'
            $gate.Satisfied | Should -BeFalse
            $gate.Message | Should -Match 'New-Users'
        }

        It 'is satisfied when every requirement is done' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users' -Live
            (Get-Gate $gates 'Prerequisite').Satisfied | Should -BeTrue
        }

        It 'counts an artefact kind as met when the artefact is simply there' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'Export-MappingFile' -Live
            $gate = Get-Gate $gates 'Prerequisite'
            $gate.Satisfied | Should -BeTrue
            $gate.Message | Should -Match 'Plan'
        }

        It 'is not offered for a step that requires nothing' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'TeamsPhone-Export' -Live
            Test-HasGate $gates 'Prerequisite' | Should -BeFalse
        }
    }

    Context 'WaveRequired' {

        It 'warns a live plan consumer that a blank wave means the whole plan' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users' -Live
            $gate = Get-Gate $gates 'WaveRequired'
            $gate.Severity | Should -BeExactly 'Soft'
            $gate.Satisfied | Should -BeFalse
            $gate.Message | Should -Match 'whole plan'
        }

        It 'is satisfied once a wave is named' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users' -Live -Wave @('1')
            (Get-Gate $gates 'WaveRequired').Satisfied | Should -BeTrue
        }

        It 'is not offered when the run is a rehearsal' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'New-Users'
            Test-HasGate $gates 'WaveRequired' | Should -BeFalse
        }

        It 'is not offered for a step that only reads the plan' {
            # Compare-Plan takes -Wave and consumes the plan, but reading all of it costs time
            # and nothing else. The gate is a writer's decision.
            $step = Get-MigrationStep -Id 'Compare-Plan'
            $step.Impact | Should -BeExactly 'Read'
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'Compare-Plan' -Live
            Test-HasGate $gates 'WaveRequired' | Should -BeFalse
        }

        It 'is not offered when the chosen parameter set has no wave to give' {
            $gates = Get-StepGate -Workspace $script:Workspace -Id 'Reset-CutoverPasswords' -Live `
                -Override @{ TestUser = 'ada.lovelace@newco.com' }
            Test-HasGate $gates 'WaveRequired' | Should -BeFalse
        }
    }
}

Describe 'Test-MigrationStepGate on workspaces the fixture cannot show' {

    It 'refuses a live run whose only rehearsal predates the plan' {
        $workspacePath = Copy-FixtureWorkspace -Name 'OldRehearsal'
        $folder = Join-Path $workspacePath 'Contoso'
        Move-Item -LiteralPath (Join-Path $folder 'Contoso_New-Users-DryRun_20260918-103100.csv') `
            -Destination (Join-Path $folder 'Contoso_New-Users-DryRun_20260918-100000.csv')
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeFalse
    }

    It 'accepts a recorded rehearsal whose waves match the ones asked for' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerWaveMatch'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @('1') `
            -Started '2026-09-18T10:31:00'
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live -Wave @('1')
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeTrue
    }

    It 'refuses when the recorded rehearsal covered a different wave' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerWaveMismatch'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @('1') `
            -Started '2026-09-18T10:31:00'
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live -Wave @('2')
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeFalse
    }

    It 'treats two empty wave lists as the same wave' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerNoWave'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @() `
            -Started '2026-09-18T10:31:00'
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeTrue
    }

    It 'ignores the wave order when comparing a rehearsal with the run about to happen' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerWaveOrder'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @('2', '1') `
            -Started '2026-09-18T10:31:00'
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live -Wave @('1', '2')
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeTrue
    }

    It 'refuses when the recorded rehearsal predates the plan, whatever the files say' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerOldRehearsal'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @() `
            -Started '2026-09-18T09:00:00'
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeFalse
    }

    It 'refuses a rehearsal that failed outright' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerFailedRehearsal'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @() `
            -Started '2026-09-18T10:31:00' -ExitCode 1
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live
        $gate = Get-Gate $gates 'DryRunFirst'
        $gate.Satisfied | Should -BeFalse
        $gate.Message | Should -Match 'exited 1'
    }

    It 'refuses a rehearsal that was cancelled part way through' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerAbortedRehearsal'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @() `
            -Started '2026-09-18T10:31:00' -ExitCode 0 -Aborted $true
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live
        $gate = Get-Gate $gates 'DryRunFirst'
        $gate.Satisfied | Should -BeFalse
        $gate.Message | Should -Match 'cancelled'
    }

    It 'accepts a rehearsal that exited 2, because finding failures is what a dry run is for' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerPartialRehearsal'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @() `
            -Started '2026-09-18T10:31:00' -ExitCode 2
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeTrue
    }

    It 'takes a later good rehearsal over an earlier failed one' {
        $workspacePath = Copy-FixtureWorkspace -Name 'LedgerFailedThenGood'
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @() `
            -Started '2026-09-18T10:31:00' -ExitCode 1
        Add-LedgerEntry -WorkspacePath $workspacePath -StepId 'New-Users' -DryRun $true -Wave @() `
            -Started '2026-09-18T10:45:00' -ExitCode 0
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeTrue
    }

    It 'makes the operator type the release domain when it is not the target domain' {
        $workspacePath = Copy-FixtureWorkspace -Name 'GateSeparateRelease'
        $settingsPath = Join-Path $workspacePath 'M365Migration.settings.json'
        $data = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        $data['Domains']['Release'] = 'contoso.com'
        ($data | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $settingsPath -Encoding utf8
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'DomainReferences-Remediate' -Live
        (Get-Gate $gates 'TypedConfirmation').RequiredInput | Should -BeExactly 'contoso.com'
    }

    It 'falls back to the word REMOVE when no source domain is configured' {
        $workspacePath = Copy-FixtureWorkspace -Name 'NoDomain'
        $settingsPath = Join-Path $workspacePath 'M365Migration.settings.json'
        $data = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
        # Both, because Release blank falls back to Target: "no domain" has to mean neither.
        $data['Domains']['Target'] = ''
        $data['Domains']['Release'] = ''
        ($data | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $settingsPath -Encoding utf8
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $gates = Get-StepGate -Workspace $workspace -Id 'DomainReferences-Remediate' -Live
        (Get-Gate $gates 'TypedConfirmation').RequiredInput | Should -BeExactly 'REMOVE'
    }

    It 'counts the artefact kinds a Requires entry may name' {
        # Inventory is the Users tab and Mapping is the export's results file - the mapping
        # workbook itself is named by the mover's contract, not the toolkit's.
        $workspace = Get-MigrationWorkspace -Path $script:FixtureRoot
        $bare = Join-Path $TestDrive 'NoArtefacts'
        $null = New-Item -Path $bare -ItemType Directory -Force
        $emptyWorkspace = Get-MigrationWorkspace -Path $bare

        InModuleScope M365Migration -Parameters @{ Full = $workspace; Empty = $emptyWorkspace } {
            param($Full, $Empty)
            Test-MigrationStepRequirement -Requirement 'Inventory' -Workspace $Full | Should -BeTrue
            Test-MigrationStepRequirement -Requirement 'Mapping' -Workspace $Full | Should -BeTrue
            Test-MigrationStepRequirement -Requirement 'Plan' -Workspace $Full | Should -BeTrue
            Test-MigrationStepRequirement -Requirement 'Log' -Workspace $Full | Should -BeTrue
            Test-MigrationStepRequirement -Requirement 'Report:TeamsPhoneAssignments' -Workspace $Full |
                Should -BeTrue

            Test-MigrationStepRequirement -Requirement 'Inventory' -Workspace $Empty | Should -BeFalse
            Test-MigrationStepRequirement -Requirement 'Mapping' -Workspace $Empty | Should -BeFalse
            Test-MigrationStepRequirement -Requirement 'NotAKind' -Workspace $Full | Should -BeFalse
        }
    }

    It 'takes any rehearsal at all when the workspace holds no plan to date it against' {
        $bare = Join-Path $TestDrive 'NoPlan'
        $null = New-Item -Path (Join-Path $bare 'Contoso') -ItemType Directory -Force
        Copy-Item -LiteralPath (Join-Path $script:FixtureRoot 'M365Migration.settings.json') `
            -Destination $bare
        Copy-Item -LiteralPath (Join-Path $script:FixtureRoot 'Contoso' `
                'Contoso_New-Users-DryRun_20260918-103100.csv') -Destination (Join-Path $bare 'Contoso')
        $workspace = Get-MigrationWorkspace -Path $bare

        $gates = Get-StepGate -Workspace $workspace -Id 'New-Users' -Live
        (Get-Gate $gates 'DryRunFirst').Satisfied | Should -BeTrue
    }
}
