#Requires -Version 7.4

<#
    Get-MigrationWorkspace reads a migration folder and says what has already happened in it.
    The committed fixture (Tests/Fixtures/Workbench/Workspace1) is a migration caught
    mid-flight: inventories taken, a plan pinned, readiness passed, users only rehearsed,
    licences half-assigned. Every state rule in Docs/Workbench-Design.md section 6 is
    asserted against it or against a variant built in $TestDrive.

    The scanner's contract is that it never throws on a folder an operator has been working
    in by hand, so the messy-folder cases below are as load-bearing as the happy path.
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Workspace1'
    $script:PlanColumns = @((Get-MigrationPlanSchema).Columns)

    function Get-WorkspaceStep {
        param($Workspace, [string]$Id)
        return @($Workspace.Steps | Where-Object { $_.Id -eq $Id })[0]
    }

    # A fixture copy the test may edit; the committed one must stay exactly as scanned.
    function Copy-FixtureWorkspace {
        param([string]$Name)
        $destination = Join-Path $TestDrive $Name
        Copy-Item -LiteralPath $script:FixtureRoot -Destination $destination -Recurse -Force
        return $destination
    }

    function New-PlanFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that builds a fixture inside the test workspace.')]
        param([string]$Path, [object[]]$Rows)
        $shaped = foreach ($values in $Rows) {
            $row = [ordered]@{}
            foreach ($column in $script:PlanColumns) { $row[$column] = '' }
            foreach ($key in $values.Keys) { $row[$key] = $values[$key] }
            [pscustomobject]$row
        }
        $null = New-Item -Path (Split-Path -Path $Path -Parent) -ItemType Directory -Force
        $shaped | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
    }

    function New-ResultFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that builds a fixture inside the test workspace.')]
        param([string]$Path, [string[]]$Status)
        $null = New-Item -Path (Split-Path -Path $Path -Parent) -ItemType Directory -Force
        $rows = foreach ($value in $Status) {
            [pscustomobject]@{ Identity = 'ada.lovelace@newco.com'; Action = 'Act'; Status = $value; Detail = '' }
        }
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
    }

    function Set-SettingsValue {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that edits the settings file of a test workspace.')]
        param([string]$WorkspacePath, [string]$Section, [string]$Key, $Value)
        $path = Join-Path $WorkspacePath 'M365Migration.settings.json'
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ($Section) { $data[$Section][$Key] = $Value } else { $data[$Key] = $Value }
        ($data | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding utf8
    }
}

Describe 'Get-MigrationWorkspace against the committed fixture' {

    BeforeAll {
        $script:Workspace = Get-MigrationWorkspace -Path $script:FixtureRoot
    }

    It 'keeps the fixture settings file valid under the settings validator' {
        $result = Resolve-MigrationSettings -Path (Join-Path $script:FixtureRoot 'M365Migration.settings.json')
        $result.IsValid | Should -BeTrue -Because ($result.Errors -join '; ')
    }

    It 'reads the label and the scenario from settings' {
        $script:Workspace.Label | Should -BeExactly 'Contoso'
        $script:Workspace.Scenario | Should -BeExactly 'TenantToTenant'
        $script:Workspace.Settings | Should -Not -BeNullOrEmpty
        $script:Workspace.SettingsResult.IsValid | Should -BeTrue
    }

    It 'reports the four prefix folders in runbook order, with Post absent' {
        @($script:Workspace.Folders.Keys) | Should -Be @('Source', 'Destination', 'Post', 'Label')
        $script:Workspace.Folders['Source'] | Should -Not -BeNullOrEmpty
        $script:Workspace.Folders['Destination'] | Should -Not -BeNullOrEmpty
        $script:Workspace.Folders['Post'] | Should -BeNullOrEmpty
        (Split-Path -Path $script:Workspace.Folders['Label'] -Leaf) | Should -BeExactly 'Contoso'
    }

    It 'chooses the newest plan and reads its facts' {
        $script:Workspace.Plan | Should -Not -BeNullOrEmpty
        $script:Workspace.Plan.Path | Should -BeLike '*20260918-101500.csv'
        $script:Workspace.Plan.Pinned | Should -BeFalse
        $script:Workspace.Plan.Timestamp | Should -Be ([datetime]'2026-09-18T10:15:00')
        $script:Workspace.Plan.RowCount | Should -Be 3
        $script:Workspace.Plan.Waves['1'] | Should -Be 2
        $script:Workspace.Plan.Waves['2'] | Should -Be 1
        @($script:Workspace.Plan.Waves.Keys) | Should -Be @('1', '2')
        $script:Workspace.Plan.Statuses['Planned'] | Should -Be 2
        $script:Workspace.Plan.Statuses['Collision'] | Should -Be 1
        $script:Workspace.Plan.DivergentRows | Should -Be 0
    }

    It 'skips the plan backup, the settings file and the ledger when parsing artefacts' {
        @($script:Workspace.Artefacts | Where-Object { $_.Path -like '*.bak' }) | Should -BeNullOrEmpty
        @($script:Workspace.Artefacts | Where-Object { $_.Path -like '*settings.json' }) | Should -BeNullOrEmpty
        @($script:Workspace.Artefacts | Where-Object { $_.Path -like '*Runs.jsonl' }) | Should -BeNullOrEmpty
    }

    It 'parses the inventory log into the artefacts with its prefix folder' {
        $log = @($script:Workspace.Artefacts | Where-Object { $_.Extension -eq 'log' })[0]
        $log.Folder | Should -BeExactly 'Source'
        $log.Prefix | Should -BeExactly 'Source'
        $log.Name | Should -BeExactly 'Get-MigrationInventory'
        $log.Suffix | Should -BeExactly ''
    }

    It 'calls the source inventory Done, dated by the name in the file' {
        $step = Get-WorkspaceStep -Workspace $script:Workspace -Id 'Inventory-Source'
        $step.State | Should -BeExactly 'Done'
        $step.LastRun.Timestamp | Should -Be ([datetime]'2026-09-17T09:12:00')
    }

    It 'calls the post-cutover inventory NotRun' {
        $step = Get-WorkspaceStep -Workspace $script:Workspace -Id 'Inventory-Post'
        $step.State | Should -BeExactly 'NotRun'
        $step.LastRun | Should -BeNullOrEmpty
        $step.ExitCode | Should -BeNullOrEmpty
    }

    It 'calls the identity plan step Done because the plan artefact exists' {
        (Get-WorkspaceStep -Workspace $script:Workspace -Id 'New-IdentityPlan').State | Should -BeExactly 'Done'
    }

    It 'calls provisioning DryRun and counts the rehearsal' {
        $step = Get-WorkspaceStep -Workspace $script:Workspace -Id 'New-Users'
        $step.State | Should -BeExactly 'DryRun'
        $step.Summary.Planned | Should -Be 2
        $step.Summary.Skipped | Should -Be 1
        $step.Summary.Failed | Should -Be 0
        $step.LastDryRun.Timestamp | Should -Be ([datetime]'2026-09-18T10:31:00')
        $step.LastRun | Should -BeNullOrEmpty
    }

    It 'calls licensing PartlyFailed and carries the ledger exit code' {
        $step = Get-WorkspaceStep -Workspace $script:Workspace -Id 'Set-Licenses'
        $step.State | Should -BeExactly 'PartlyFailed'
        $step.Summary.Failed | Should -Be 1
        $step.Summary.Succeeded | Should -Be 1
        $step.ExitCode | Should -Be 2
    }

    It 'calls pre-provisioning readiness Done and carries TenantVerified from the ledger' {
        $step = Get-WorkspaceStep -Workspace $script:Workspace -Id 'Readiness-Pre'
        $step.State | Should -BeExactly 'Done'
        $step.TenantVerified | Should -BeTrue
        $step.ExitCode | Should -Be 0
        @($step.Files | ForEach-Object { Split-Path -Path $_.Path -Leaf }) |
            Should -Contain 'Contoso_Test-Readiness-Results_20260918-102000.csv'
    }

    It 'gives the readiness file to the instance the ledger names, not to its siblings' {
        (Get-WorkspaceStep -Workspace $script:Workspace -Id 'Readiness-Provisioned').State |
            Should -BeExactly 'NotRun'
        (Get-WorkspaceStep -Workspace $script:Workspace -Id 'Readiness-Post').State | Should -BeExactly 'NotRun'
    }

    It 'finds the Teams Phone export in Source, where the Export resolver looks' {
        $step = Get-WorkspaceStep -Workspace $script:Workspace -Id 'TeamsPhone-Export'
        $step.State | Should -BeExactly 'Done'
        @($step.Files | ForEach-Object { $_.Folder }) | Should -Contain 'Source'
    }

    It 'names the next step as the lowest-ordered one still to do' {
        $script:Workspace.NextStepId | Should -BeExactly 'New-Users'
    }

    It 'reads the ledger without losing a line' {
        @($script:Workspace.Ledger).Count | Should -Be 2
        @($script:Workspace.Ledger | ForEach-Object { $_.StepId }) | Should -Be @('Readiness-Pre', 'Set-Licenses')
        $script:Workspace.Ledger[0].Started | Should -Be ([datetime]'2026-09-18T10:20:00')
    }

    It 'scans a clean workspace without warnings' {
        @($script:Workspace.Warnings) | Should -BeNullOrEmpty
    }

    It 'never reads the generated-password column' {
        ($script:Workspace | ConvertTo-Json -Depth 8 -WarningAction SilentlyContinue) |
            Should -Not -Match 'NotARealPassword'
    }

    It 'shows only the steps of the workspace scenario' {
        @($script:Workspace.Steps | ForEach-Object { $_.Id }) | Should -Contain 'Set-Identity'
        @($script:Workspace.Steps | ForEach-Object { $_.Id }) | Should -Not -Contain 'Set-Identity-InPlace'
    }
}

Describe 'Get-MigrationWorkspace and the pinned plan' {

    It 'honours Pinned.PlanPath and warns that a newer plan exists' {
        $workspacePath = Copy-FixtureWorkspace -Name 'pinned-old'
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Pinned' -Key 'PlanPath' `
            -Value 'Contoso/Contoso_IdentityPlan_20260917-120000.csv'

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $workspace.Plan.Path | Should -BeLike '*20260917-120000.csv'
        $workspace.Plan.Pinned | Should -BeTrue
        $workspace.Plan.RowCount | Should -Be 2
        $workspace.Plan.DivergentRows | Should -Be 1
        ($workspace.Warnings -join ' ') | Should -Match 'Contoso_IdentityPlan_20260917-120000\.csv'
        ($workspace.Warnings -join ' ') | Should -Match 'Contoso_IdentityPlan_20260918-101500\.csv'
    }

    It 'warns and falls back to the newest plan when the pinned path is gone' {
        $workspacePath = Copy-FixtureWorkspace -Name 'pinned-missing'
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Pinned' -Key 'PlanPath' `
            -Value 'Contoso/Contoso_IdentityPlan_20250101-000000.csv'

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $workspace.Plan.Path | Should -BeLike '*20260918-101500.csv'
        $workspace.Plan.Pinned | Should -BeFalse
        ($workspace.Warnings -join ' ') | Should -Match '20250101-000000'
    }

    It 'calls a plan consumer Stale when its last run predates the pinned plan' {
        $workspacePath = Copy-FixtureWorkspace -Name 'stale'
        New-PlanFile -Path (Join-Path $workspacePath 'Contoso' 'Contoso_IdentityPlan_20260919-080000.csv') -Rows @(
            @{ ObjectType = 'User'; Wave = '1'; SourceUserPrincipalName = 'ada.lovelace@contoso.com'
                TargetUserPrincipalName = 'ada.lovelace@newco.com'; PlanStatus = 'Planned'
            })

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $workspace.Plan.Path | Should -BeLike '*20260919-080000.csv'
        (Get-WorkspaceStep -Workspace $workspace -Id 'Readiness-Pre').State | Should -BeExactly 'Stale'
        # The source inventory reads no plan, so a newer plan cannot make it stale.
        (Get-WorkspaceStep -Workspace $workspace -Id 'Inventory-Source').State | Should -BeExactly 'Done'
    }

    It 'warns and reports no plan when the plan file fails the schema' {
        $workspacePath = Join-Path $TestDrive 'broken-plan'
        $null = New-Item -Path (Join-Path $workspacePath 'Contoso') -ItemType Directory -Force
        'Wave,PlanStatus' | Set-Content -LiteralPath (Join-Path $workspacePath 'Contoso' `
                'Contoso_IdentityPlan_20260918-101500.csv') -Encoding utf8
        Add-Content -LiteralPath (Join-Path $workspacePath 'Contoso' `
                'Contoso_IdentityPlan_20260918-101500.csv') -Value '1,Planned' -Encoding utf8

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $workspace.Plan | Should -BeNullOrEmpty
        ($workspace.Warnings -join ' ') | Should -Match 'Contoso_IdentityPlan_20260918-101500\.csv'
    }
}

Describe 'Get-MigrationWorkspace without settings' {

    It 'infers the label from the one prefix folder that is not Source, Destination or Post' {
        $workspacePath = Copy-FixtureWorkspace -Name 'no-settings'
        Remove-Item -LiteralPath (Join-Path $workspacePath 'M365Migration.settings.json') -Force

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $workspace.Label | Should -BeExactly 'Contoso'
        $workspace.Scenario | Should -BeExactly 'TenantToTenant'
        $workspace.Settings | Should -BeNullOrEmpty
        $workspace.SettingsResult.Exists | Should -BeFalse
        $workspace.Plan | Should -Not -BeNullOrEmpty
    }

    It 'leaves the label blank and warns when two folders could be it' {
        $workspacePath = Copy-FixtureWorkspace -Name 'ambiguous'
        Remove-Item -LiteralPath (Join-Path $workspacePath 'M365Migration.settings.json') -Force
        New-ResultFile -Path (Join-Path $workspacePath 'Fabrikam' 'Fabrikam_Set-Identity-Results_20260918-120000.csv') `
            -Status @('Succeeded')

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $workspace.Label | Should -BeExactly ''
        ($workspace.Warnings -join ' ') | Should -Match 'Contoso'
        ($workspace.Warnings -join ' ') | Should -Match 'Fabrikam'
    }

    It 'leaves the label blank and warns when no folder could be it' {
        $workspacePath = Join-Path $TestDrive 'bare'
        $null = New-Item -Path (Join-Path $workspacePath 'Source') -ItemType Directory -Force

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $workspace.Label | Should -BeExactly ''
        $workspace.Folders['Label'] | Should -BeNullOrEmpty
        @($workspace.Warnings).Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-MigrationWorkspace on a messy folder' {

    It 'returns an empty scan and a warning for a folder that is not there' {
        $workspace = Get-MigrationWorkspace -Path (Join-Path $TestDrive 'never-created')
        $workspace.Label | Should -BeExactly ''
        @($workspace.Artefacts) | Should -BeNullOrEmpty
        @($workspace.Warnings).Count | Should -BeGreaterThan 0
        @($workspace.Steps | Where-Object { $_.State -ne 'NotRun' }) | Should -BeNullOrEmpty
        $workspace.NextStepId | Should -BeExactly 'Inventory-Source'
    }

    It 'skips files that are not part of the filename contract without a word' {
        $workspacePath = Copy-FixtureWorkspace -Name 'junk'
        'notes' | Set-Content -LiteralPath (Join-Path $workspacePath 'Contoso' 'notes.txt') -Encoding utf8
        'x' | Set-Content -LiteralPath (Join-Path $workspacePath 'Contoso' `
                'Contoso_Set-Identity-Results_20261399-000000.csv') -Encoding utf8

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        @($workspace.Artefacts | Where-Object { $_.Path -like '*notes.txt' }) | Should -BeNullOrEmpty
        @($workspace.Artefacts | Where-Object { $_.Path -like '*20261399*' }) | Should -BeNullOrEmpty
        @($workspace.Warnings) | Should -BeNullOrEmpty
    }

    It 'warns by name about a results file that has only a header' {
        $workspacePath = Copy-FixtureWorkspace -Name 'header-only'
        '"Identity","Action","Status","Detail"' | Set-Content -LiteralPath (Join-Path $workspacePath 'Contoso' `
                'Contoso_New-Recipients-Results_20260918-120000.csv') -Encoding utf8

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        ($workspace.Warnings -join ' ') | Should -Match 'Contoso_New-Recipients-Results_20260918-120000\.csv'
    }

    It 'warns about a malformed ledger line and still reads the good ones' {
        $workspacePath = Copy-FixtureWorkspace -Name 'bad-ledger'
        $ledgerPath = Join-Path $workspacePath 'Workbench' 'Runs.jsonl'
        Add-Content -LiteralPath $ledgerPath -Value '{ this is not json' -Encoding utf8
        Add-Content -LiteralPath $ledgerPath -Value '' -Encoding utf8

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        @($workspace.Ledger).Count | Should -Be 2
        ($workspace.Warnings -join ' ') | Should -Match 'Runs\.jsonl'
        (Get-WorkspaceStep -Workspace $workspace -Id 'Readiness-Pre').State | Should -BeExactly 'Done'
    }
}

Describe 'Get-MigrationWorkspace state rules driven by the ledger' {

    It 'calls a step Failed on ledger exit 1' {
        $workspacePath = Copy-FixtureWorkspace -Name 'exit-1'
        Add-Content -LiteralPath (Join-Path $workspacePath 'Workbench' 'Runs.jsonl') -Encoding utf8 -Value (
            '{"Started":"2026-09-18T12:00:00","Ended":"2026-09-18T12:00:20","StepId":"New-Recipients",' +
            '"ExitCode":1,"Meaning":"Failed","TenantVerified":true,"Files":[]}')

        (Get-WorkspaceStep -Workspace (Get-MigrationWorkspace -Path $workspacePath) -Id 'New-Recipients').State |
            Should -BeExactly 'Failed'
    }

    It 'calls the domain remediation WorkRemains on ledger exit 3' {
        $workspacePath = Copy-FixtureWorkspace -Name 'exit-3'
        New-ResultFile -Status @('Succeeded', 'Succeeded') -Path (Join-Path $workspacePath 'Contoso' `
                'Contoso_Remove-DomainReferences-Results_20260918-130000.csv')
        Add-Content -LiteralPath (Join-Path $workspacePath 'Workbench' 'Runs.jsonl') -Encoding utf8 -Value (
            '{"Started":"2026-09-18T13:00:00","Ended":"2026-09-18T13:02:00",' +
            '"StepId":"DomainReferences-Remediate","ExitCode":3,"Meaning":"References remain",' +
            '"TenantVerified":true,"Files":["Contoso_Remove-DomainReferences-Results_20260918-130000.csv"]}')

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        (Get-WorkspaceStep -Workspace $workspace -Id 'DomainReferences-Remediate').State |
            Should -BeExactly 'WorkRemains'
        # The ledger named the remediation, so the report instance keeps its hands off that file.
        (Get-WorkspaceStep -Workspace $workspace -Id 'DomainReferences-Report').State | Should -BeExactly 'NotRun'
    }

    It 'gives a shared results token to the lowest-ordered instance when no ledger entry claims it' {
        $workspacePath = Copy-FixtureWorkspace -Name 'shared-no-ledger'
        Remove-Item -LiteralPath (Join-Path $workspacePath 'Workbench' 'Runs.jsonl') -Force
        New-ResultFile -Status @('Succeeded') -Path (Join-Path $workspacePath 'Contoso' `
                'Contoso_Remove-DomainReferences-Results_20260918-130000.csv')

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        (Get-WorkspaceStep -Workspace $workspace -Id 'DomainReferences-Report').State | Should -BeExactly 'Done'
        (Get-WorkspaceStep -Workspace $workspace -Id 'DomainReferences-Remediate').State |
            Should -BeExactly 'NotRun'
    }

    It 'attributes a shared results file by the ledger run window when no file list names it' {
        $workspacePath = Copy-FixtureWorkspace -Name 'shared-by-window'
        New-ResultFile -Status @('Succeeded') -Path (Join-Path $workspacePath 'Contoso' `
                'Contoso_Test-Readiness-Results_20260918-140000.csv')
        Add-Content -LiteralPath (Join-Path $workspacePath 'Workbench' 'Runs.jsonl') -Encoding utf8 -Value (
            '{"Started":"2026-09-18T13:59:50","Ended":"2026-09-18T14:00:30","StepId":"Readiness-Provisioned",' +
            '"ExitCode":0,"Meaning":"Completed","TenantVerified":true,"Files":[]}')

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $step = Get-WorkspaceStep -Workspace $workspace -Id 'Readiness-Provisioned'
        $step.State | Should -BeExactly 'Done'
        $step.LastRun.Timestamp | Should -Be ([datetime]'2026-09-18T14:00:00')
    }

    It 'attributes a hyphenated report name whole, to the instance that produces it' {
        $workspacePath = Copy-FixtureWorkspace -Name 'reports'
        New-ResultFile -Status @('Succeeded') -Path (Join-Path $workspacePath 'Contoso' `
                'Contoso_DomainBlockers-Recheck_20260918-150000.csv')

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $files = @((Get-WorkspaceStep -Workspace $workspace -Id 'DomainReferences-Report').Files |
                ForEach-Object { Split-Path -Path $_.Path -Leaf })
        $files | Should -Contain 'Contoso_DomainBlockers-Recheck_20260918-150000.csv'
    }
}

Describe 'Get-MigrationWorkspace and the next step' {

    It 'satisfies an artefact requirement from the artefact, not from the step that writes it' {
        $workspacePath = Copy-FixtureWorkspace -Name 'plan-only'
        Remove-Item -LiteralPath (Join-Path $workspacePath 'Workbench' 'Runs.jsonl') -Force
        Get-ChildItem -LiteralPath (Join-Path $workspacePath 'Contoso') -Filter '*-Results_*.csv' |
            Remove-Item -Force
        Get-ChildItem -LiteralPath (Join-Path $workspacePath 'Contoso') -Filter '*-DryRun_*.csv' |
            Remove-Item -Force

        # Export-MappingFile requires only 'Plan', an artefact kind, so it is offered on the
        # strength of the plan file alone - no step in this folder recorded producing it.
        (Get-MigrationWorkspace -Path $workspacePath).NextStepId | Should -BeExactly 'Export-MappingFile'
    }

    It 'returns $null when every step is done or blocked' {
        $workspacePath = Join-Path $TestDrive 'in-place-finished'
        $null = New-Item -Path $workspacePath -ItemType Directory -Force
        Copy-Item -LiteralPath (Join-Path $script:FixtureRoot 'M365Migration.settings.json') `
            -Destination $workspacePath
        Set-SettingsValue -WorkspacePath $workspacePath -Section '' -Key 'Scenario' -Value 'InPlaceRedesign'

        New-PlanFile -Path (Join-Path $workspacePath 'Contoso' 'Contoso_IdentityPlan_20260918-101500.csv') -Rows @(
            @{ ObjectType = 'User'; Wave = '1'; SourceUserPrincipalName = 'ada.lovelace@contoso.com'
                TargetUserPrincipalName = 'ada.lovelace@newco.com'; PlanStatus = 'Planned'
            })
        foreach ($folder in @('Source', 'Post')) {
            $null = New-Item -Path (Join-Path $workspacePath $folder) -ItemType Directory -Force
        }
        'ObjectId,UserPrincipalName' | Set-Content -Encoding utf8 -LiteralPath (
            Join-Path $workspacePath 'Source' 'Source_Users_20260918-110000.csv')
        Add-Content -Encoding utf8 -Value '"x","ada.lovelace@contoso.com"' -LiteralPath (
            Join-Path $workspacePath 'Source' 'Source_Users_20260918-110000.csv')
        Copy-Item -LiteralPath (Join-Path $workspacePath 'Source' 'Source_Users_20260918-110000.csv') `
            -Destination (Join-Path $workspacePath 'Post' 'Post_Users_20260918-120000.csv') -Force

        # The three readiness stages share one results token, so each needs a ledger entry
        # naming its own file before the scanner can call all three Done.
        $ledgerPath = Join-Path $workspacePath 'Workbench' 'Runs.jsonl'
        $null = New-Item -Path (Split-Path -Path $ledgerPath -Parent) -ItemType Directory -Force
        $stamp = 0
        foreach ($stage in @('Readiness-Pre', 'Readiness-Provisioned', 'Readiness-Post')) {
            $stamp++
            $file = "Contoso_Test-Readiness-Results_20260918-13000$stamp.csv"
            New-ResultFile -Status @('Succeeded') -Path (Join-Path $workspacePath 'Contoso' $file)
            Add-Content -LiteralPath $ledgerPath -Encoding utf8 -Value (
                '{"Started":"2026-09-18T13:00:0' + $stamp + '","Ended":"2026-09-18T13:00:0' + $stamp +
                '","StepId":"' + $stage + '","ExitCode":0,"TenantVerified":true,"Files":["' + $file + '"]}')
        }
        foreach ($token in @('Set-Identity', 'Set-MailboxPermissions', 'Compare-UserData-Plan')) {
            New-ResultFile -Status @('Succeeded') -Path (Join-Path $workspacePath 'Contoso' `
                    "Contoso_$token-Results_20260918-140000.csv")
        }

        $workspace = Get-MigrationWorkspace -Path $workspacePath
        @($workspace.Steps | Where-Object { $_.State -ne 'Done' } | ForEach-Object { $_.Id }) |
            Should -BeNullOrEmpty
        $workspace.NextStepId | Should -BeNullOrEmpty
    }
}

Describe 'Private workspace helpers' {

    It 'Get-MigrationPlanFacts counts rows, waves, statuses and divergence' {
        InModuleScope M365Migration -Parameters @{ Path = (Join-Path $script:FixtureRoot 'Contoso' `
                    'Contoso_IdentityPlan_20260918-101500.csv')
        } {
            param($Path)
            $facts = Get-MigrationPlanFacts -Path $Path
            $facts.RowCount | Should -Be 3
            $facts.Waves['1'] | Should -Be 2
            $facts.Statuses['Collision'] | Should -Be 1
            $facts.DivergentRows | Should -Be 0
            $facts.Timestamp | Should -Be ([datetime]'2026-09-18T10:15:00')
        }
    }

    It 'Get-MigrationResultSummary counts only the Status column' {
        InModuleScope M365Migration -Parameters @{ Path = (Join-Path $script:FixtureRoot 'Contoso' `
                    'Contoso_New-Users-DryRun_20260918-103100.csv')
        } {
            param($Path)
            $summary = Get-MigrationResultSummary -Path $Path
            $summary.Planned | Should -Be 2
            $summary.Skipped | Should -Be 1
            $summary.Succeeded | Should -Be 0
            $summary.Failed | Should -Be 0
            $summary.RowCount | Should -Be 3
        }
    }

    It 'Get-MigrationRunLedgerEntry returns entries and warnings without throwing' {
        InModuleScope M365Migration -Parameters @{ Path = (Join-Path $script:FixtureRoot 'Workbench' 'Runs.jsonl') } {
            param($Path)
            $ledger = Get-MigrationRunLedgerEntry -Path $Path
            @($ledger.Entries).Count | Should -Be 2
            @($ledger.Warnings) | Should -BeNullOrEmpty
            $ledger.Entries[1].ExitCode | Should -Be 2
        }
    }

    It 'Get-MigrationRunLedgerEntry reports a missing ledger as empty, not as an error' {
        InModuleScope M365Migration -Parameters @{ Path = (Join-Path $TestDrive 'no-such-ledger.jsonl') } {
            param($Path)
            $ledger = Get-MigrationRunLedgerEntry -Path $Path
            @($ledger.Entries) | Should -BeNullOrEmpty
            @($ledger.Warnings) | Should -BeNullOrEmpty
        }
    }
}
