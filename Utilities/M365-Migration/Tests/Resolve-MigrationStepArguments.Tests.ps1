#Requires -Version 7.4

<#
    Resolve-MigrationStepArguments turns a step, a workspace and the operator's input into the
    exact parameter list a run would use (Docs/Workbench-Design.md sections 5.3 and 7.1).

    Every assertion below runs against the committed fixture
    (Tests/Fixtures/Workbench/Workspace1) or a $TestDrive copy of it, so the resolvers are
    exercised against real filenames rather than mocks: the point of a resolver is that it
    picks the right file out of a folder an operator has been working in.

    The precedence ladder - Fixed, Operator, Settings, Resolved, Default - is asserted rung by
    rung, because an argument that comes from the wrong rung is a run against the wrong data.
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Workspace1'
    $script:ToolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    function Get-Argument {
        param($Result, [string]$Name)
        $matched = @($Result.Arguments | Where-Object { $_.Name -eq $Name })
        if ($matched.Count -eq 0) { return $null }
        return $matched[0]
    }

    function Test-HasArgument {
        param($Result, [string]$Name)
        return (@($Result.Arguments | Where-Object { $_.Name -eq $Name }).Count -gt 0)
    }

    # A fixture copy the test may edit; the committed one must stay exactly as scanned.
    function Copy-FixtureWorkspace {
        param([string]$Name)
        $destination = Join-Path $TestDrive $Name
        Copy-Item -LiteralPath $script:FixtureRoot -Destination $destination -Recurse -Force
        return $destination
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

Describe 'Resolve-MigrationStepArguments against the committed fixture' {

    BeforeAll {
        $script:Workspace = Get-MigrationWorkspace -Path $script:FixtureRoot
        $script:PlanPath = $script:Workspace.Plan.Path
    }

    Context 'New-Users - the canonical plan consumer' {

        BeforeAll {
            $script:NewUsers = Get-MigrationStep -Id 'New-Users'
            $script:Result = Resolve-MigrationStepArguments -Step $script:NewUsers -Workspace $script:Workspace
        }

        It 'resolves -PlanPath to the workspace plan and marks it Resolved' {
            $argument = Get-Argument $script:Result 'PlanPath'
            $argument | Should -Not -BeNullOrEmpty
            $argument.Value | Should -BeExactly $script:PlanPath
            $argument.Source | Should -BeExactly 'Resolved'
        }

        It 'offers both plans as candidates, newest first' {
            $argument = Get-Argument $script:Result 'PlanPath'
            @($argument.Candidates).Count | Should -Be 2
            @($argument.Candidates)[0] | Should -BeExactly $script:PlanPath
            [System.IO.Path]::GetFileName(@($argument.Candidates)[1]) |
                Should -BeExactly 'Contoso_IdentityPlan_20260917-120000.csv'
        }

        It 'binds -TenantId to the destination tenant from settings' {
            $argument = Get-Argument $script:Result 'TenantId'
            $argument.Value | Should -BeExactly '00000000-0000-0000-0000-000000000000'
            $argument.Source | Should -BeExactly 'Settings'
        }

        It 'sets the common parameters from the workspace and the settings defaults' {
            (Get-Argument $script:Result 'OutputPath').Value | Should -BeExactly $script:Workspace.Path
            (Get-Argument $script:Result 'OutputPath').Source | Should -BeExactly 'Common'
            (Get-Argument $script:Result 'Prefix').Value | Should -BeExactly 'Contoso'
            (Get-Argument $script:Result 'Verbosity').Value | Should -BeExactly 'Medium'
        }

        It 'never passes -LogPath: each script derives it from -OutputPath' {
            Test-HasArgument $script:Result 'LogPath' | Should -BeFalse
        }

        It 'passes -Confirm:$false even though the script is not High impact' {
            # The catalogue's Confirm flag says "High impact", which this script is not, but the
            # child still runs -NonInteractive: a ShouldProcess prompt it cannot answer must not
            # depend on ConfirmImpact sitting below that process's $ConfirmPreference.
            $script:NewUsers.Confirm | Should -BeFalse
            $argument = Get-Argument $script:Result 'Confirm'
            $argument.Value | Should -BeFalse
            $argument.Source | Should -BeExactly 'Common'
        }

        It 'omits -Confirm for a script that does not support ShouldProcess' {
            $step = Get-MigrationStep -Id 'Inventory-Source'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace
            Test-HasArgument $result 'Confirm' | Should -BeFalse
        }

        It 'omits -DryRun unless it was asked for' {
            Test-HasArgument $script:Result 'DryRun' | Should -BeFalse
        }

        It 'adds -DryRun when the run is a rehearsal' {
            $dry = Resolve-MigrationStepArguments -Step $script:NewUsers -Workspace $script:Workspace -DryRun
            $argument = Get-Argument $dry 'DryRun'
            $argument.Value | Should -BeTrue
            $argument.Source | Should -BeExactly 'Common'
        }

        It 'adds -Wave only when a wave was requested' {
            $waved = Resolve-MigrationStepArguments -Step $script:NewUsers -Workspace $script:Workspace `
                -Wave @('1', '2')
            $argument = Get-Argument $waved 'Wave'
            (@($argument.Value) -join ',') | Should -BeExactly '1,2'
            $argument.Source | Should -BeExactly 'Common'
        }

        It 'records the script default for a parameter nothing else supplies, without emitting it' {
            $argument = Get-Argument $script:Result 'ForceChangePassword'
            $argument.Value | Should -BeTrue
            $argument.Source | Should -BeExactly 'Default'
        }

        It 'reports a satisfiable parameter set and nothing missing' {
            $script:Result.MissingMandatory | Should -BeNullOrEmpty
            $script:Result.Warnings | Should -BeNullOrEmpty
        }

        It 'emits every path as an absolute path' {
            $paths = @($script:Result.Arguments |
                    Where-Object { $_.Source -ne 'Default' -and $_.Value -is [string] -and $_.Name -like '*Path' })
            $paths.Count | Should -BeGreaterThan 0
            foreach ($argument in $paths) {
                [System.IO.Path]::IsPathRooted($argument.Value) | Should -BeTrue -Because $argument.Name
            }
        }
    }

    Context 'Inventory-Source - an instance that fixes its own prefix' {

        BeforeAll {
            $step = Get-MigrationStep -Id 'Inventory-Source'
            $script:Result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace
        }

        It 'takes -Prefix from the instance rather than the label' {
            $argument = Get-Argument $script:Result 'Prefix'
            $argument.Value | Should -BeExactly 'Source'
            $argument.Source | Should -BeExactly 'Fixed'
        }

        It 'binds -TenantId to the source tenant' {
            (Get-Argument $script:Result 'TenantId').Value |
                Should -BeExactly '00000000-0000-0000-0000-000000000000'
        }

        It 'leaves -DelegatedOrganization out while the settings value is empty' {
            Test-HasArgument $script:Result 'DelegatedOrganization' | Should -BeFalse
        }

        It 'leaves the operator-owned scope switches alone' {
            Test-HasArgument $script:Result 'IncludeOneDrive' | Should -BeFalse
            Test-HasArgument $script:Result 'SkipExcel' | Should -BeFalse
        }
    }

    Context 'Readiness-Provisioned - an instance that adds its own resolver' {

        BeforeAll {
            $step = Get-MigrationStep -Id 'Readiness-Provisioned'
            $script:Result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace
        }

        It 'resolves -SourceMailboxesCsv to the source inventory tab' {
            $argument = Get-Argument $script:Result 'SourceMailboxesCsv'
            [System.IO.Path]::GetFileName($argument.Value) |
                Should -BeExactly 'Source_UserMailboxes_20260917-091200.csv'
            $argument.Source | Should -BeExactly 'Resolved'
        }

        It 'fixes -Stage to this instance stage' {
            $argument = Get-Argument $script:Result 'Stage'
            $argument.Value | Should -BeExactly 'Provisioned'
            $argument.Source | Should -BeExactly 'Fixed'
        }
    }

    Context 'New-IdentityPlan - the offline planner' {

        BeforeAll {
            $step = Get-MigrationStep -Id 'New-IdentityPlan'
            $script:Result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace
        }

        It 'resolves -UsersCsv from the source inventory' {
            $argument = Get-Argument $script:Result 'UsersCsv'
            [System.IO.Path]::GetFileName($argument.Value) | Should -BeExactly 'Source_Users_20260917-091200.csv'
            $argument.Source | Should -BeExactly 'Resolved'
        }

        It 'resolves -ReservedAddressesPath from the destination inventory' {
            [System.IO.Path]::GetFileName((Get-Argument $script:Result 'ReservedAddressesPath').Value) |
                Should -BeExactly 'Destination_Users_20260917-094000.csv'
        }

        It 'binds -TargetDomain from Domains.Target' {
            $argument = Get-Argument $script:Result 'TargetDomain'
            $argument.Value | Should -BeExactly 'newco.com'
            $argument.Source | Should -BeExactly 'Settings'
        }

        It 'resolves -ExistingPlanPath to the workspace plan' {
            (Get-Argument $script:Result 'ExistingPlanPath').Value | Should -BeExactly $script:PlanPath
        }

        It 'omits -SmtpDomain and -InterimDomain while their settings values are empty' {
            Test-HasArgument $script:Result 'SmtpDomain' | Should -BeFalse
            Test-HasArgument $script:Result 'InterimDomain' | Should -BeFalse
        }

        It 'omits -AliasDomainMap while the settings map is empty' {
            Test-HasArgument $script:Result 'AliasDomainMap' | Should -BeFalse
        }

        It 'emits a bound boolean even when it is false' {
            $argument = Get-Argument $script:Result 'PreserveAliases'
            $argument.Value | Should -BeFalse
            $argument.Source | Should -BeExactly 'Settings'
        }

        It 'gives an offline step the label as its prefix' {
            (Get-Argument $script:Result 'Prefix').Value | Should -BeExactly 'Contoso'
        }

        It 'omits a path setting that is blank' {
            Test-HasArgument $script:Result 'SkuMapPath' | Should -BeFalse
        }
    }

    Context 'Reset-CutoverPasswords - four parameter sets' {

        BeforeAll {
            $script:Step = Get-MigrationStep -Id 'Reset-CutoverPasswords'
        }

        It 'falls to the Plan set when only the plan resolves' {
            $result = Resolve-MigrationStepArguments -Step $script:Step -Workspace $script:Workspace
            $result.ParameterSet | Should -BeExactly 'Plan'
            $result.MissingMandatory | Should -BeNullOrEmpty
            (Get-Argument $result 'PlanPath').Value | Should -BeExactly $script:PlanPath
        }

        It 'switches to the TestUser set when the operator names a test user' {
            $result = Resolve-MigrationStepArguments -Step $script:Step -Workspace $script:Workspace `
                -Override @{ TestUser = 'ada.lovelace@newco.com' }
            $result.ParameterSet | Should -BeExactly 'TestUser'
            $result.MissingMandatory | Should -BeNullOrEmpty
            (Get-Argument $result 'TestUser').Source | Should -BeExactly 'Operator'
        }

        It 'drops the resolved plan once the operator has chosen a different set' {
            $result = Resolve-MigrationStepArguments -Step $script:Step -Workspace $script:Workspace `
                -Override @{ TestUser = 'ada.lovelace@newco.com' }
            Test-HasArgument $result 'PlanPath' | Should -BeFalse
            Test-HasArgument $result 'IncludeCollisions' | Should -BeFalse
        }

        It 'passes -Confirm:$false, as every ShouldProcess script gets' {
            $result = Resolve-MigrationStepArguments -Step $script:Step -Workspace $script:Workspace
            $argument = Get-Argument $result 'Confirm'
            $argument.Value | Should -BeFalse
            $argument.Source | Should -BeExactly 'Common'
        }

        It 'keeps a parameter that belongs to every set' {
            $result = Resolve-MigrationStepArguments -Step $script:Step -Workspace $script:Workspace `
                -Override @{ TestUser = 'ada.lovelace@newco.com' }
            (Get-Argument $result 'WordCount').Value | Should -Be 3
            (Get-Argument $result 'TenantId').Source | Should -BeExactly 'Settings'
        }
    }

    Context 'the release domain' {

        It 'gives the domain-release step the target domain while Release is blank' {
            # Domains.Release blank means "the vanity domain moves with the users", so the
            # domain released from the source is the one the identities land on.
            $script:Workspace.Settings['Domains']['Release'] | Should -BeExactly ''
            $step = Get-MigrationStep -Id 'DomainReferences-Remediate'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace
            $argument = Get-Argument $result 'Domain'
            $argument.Value | Should -BeExactly 'newco.com'
            $argument.Source | Should -BeExactly 'Settings'
        }
    }

    Context 'the Export resolver' {

        It 'prefers the export report the consumer actually reads' {
            $step = Get-MigrationStep -Id 'TeamsPhone-Remove'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace
            $argument = Get-Argument $result 'CsvPath'
            [System.IO.Path]::GetFileName($argument.Value) |
                Should -BeExactly 'Source_TeamsPhoneAssignments_20260918-090000.csv'
            $argument.Source | Should -BeExactly 'Resolved'
        }

        It 'still offers the export results file as an alternative' {
            $step = Get-MigrationStep -Id 'TeamsPhone-Remove'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace
            $names = @((Get-Argument $result 'CsvPath').Candidates |
                    ForEach-Object { [System.IO.Path]::GetFileName($_) })
            $names | Should -Contain 'Source_Get-TeamsPhoneAssignments-Results_20260918-090000.csv'
        }

        It 'resolves nothing when the producing step has not run' {
            $step = Get-MigrationStep -Id 'VivaLearning-Import'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace
            Test-HasArgument $result 'CsvPath' | Should -BeFalse
        }
    }

    Context 'operator overrides' {

        It 'lets the operator replace a resolved value' {
            $step = Get-MigrationStep -Id 'New-Users'
            $other = Join-Path $script:FixtureRoot 'Contoso' 'Contoso_IdentityPlan_20260917-120000.csv'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace `
                -Override @{ PlanPath = $other }
            $argument = Get-Argument $result 'PlanPath'
            $argument.Value | Should -BeExactly $other
            $argument.Source | Should -BeExactly 'Operator'
        }

        It 'refuses an override that is not a parameter of the script, and says so' {
            $step = Get-MigrationStep -Id 'New-Users'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace `
                -Override @{ NotAParameter = 'x' }
            Test-HasArgument $result 'NotAParameter' | Should -BeFalse
            @($result.Warnings) -join ' ' | Should -Match 'NotAParameter'
        }

        It 'matches an override name case-insensitively and emits the declared spelling' {
            $step = Get-MigrationStep -Id 'New-Users'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace `
                -Override @{ planpath = 'C:\plan.csv' }
            (Get-Argument $result 'PlanPath').Value | Should -BeExactly 'C:\plan.csv'
            $result.Warnings | Should -BeNullOrEmpty
        }
    }

    Context 'the parameters the workbench owns' {

        <#
            An Operator rung that could set -DryRun, -Wave, -OutputPath or -TenantId is a second
            source of truth that outranks the first silently: the ledger would record the wave
            the run was told to use while the driver ran the wave that was typed, and the
            scanner would then read that line as a live run of a step nothing provisioned.
        #>

        It 'drops every parameter the engine says it owns, and names each one' {
            $step = Get-MigrationStep -Id 'New-Users'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace -Wave '1' `
                -Override @{ Wave = '3'; DryRun = $true; TenantId = '22222222-2222-2222-2222-222222222222' }

            (Get-Argument $result 'Wave').Value | Should -Be @('1')
            (Get-Argument $result 'Wave').Source | Should -BeExactly 'Common'
            Test-HasArgument $result 'DryRun' | Should -BeFalse
            (Get-Argument $result 'TenantId').Value |
                Should -BeExactly '00000000-0000-0000-0000-000000000000'

            $warnings = @($result.Warnings) -join ' '
            foreach ($name in @('Wave', 'DryRun', 'TenantId')) {
                $warnings | Should -Match "$name is set by the workbench, not by an override"
            }
        }

        It 'keeps a live run live even when the override asked for a rehearsal' {
            $step = Get-MigrationStep -Id 'New-Users'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace `
                -Override @{ DryRun = $true }
            Test-HasArgument $result 'DryRun' | Should -BeFalse
        }

        It 'refuses an owned name whatever case it was typed in' {
            $step = Get-MigrationStep -Id 'New-Users'
            $result = Resolve-MigrationStepArguments -Step $step -Workspace $script:Workspace `
                -Override @{ outputpath = '/tmp/elsewhere' }
            (Get-Argument $result 'OutputPath').Value | Should -BeExactly $script:Workspace.Path
            @($result.Warnings) -join ' ' | Should -Match 'OutputPath is set by the workbench'
        }
    }
}

Describe 'Resolve-MigrationStepArguments on workspaces that are not the happy path' {

    It 'reports the mandatory parameter that could not be resolved in an empty workspace' {
        $empty = Join-Path $TestDrive 'Empty'
        $null = New-Item -Path $empty -ItemType Directory -Force
        $workspace = Get-MigrationWorkspace -Path $empty
        $step = Get-MigrationStep -Id 'New-Users'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        @($result.MissingMandatory) | Should -Contain 'PlanPath'
        @($result.Warnings).Count | Should -BeGreaterThan 0
    }

    It 'picks the set with the fewest missing mandatory parameters when none is satisfiable' {
        $empty = Join-Path $TestDrive 'EmptySets'
        $null = New-Item -Path $empty -ItemType Directory -Force
        $workspace = Get-MigrationWorkspace -Path $empty
        $step = Get-MigrationStep -Id 'Reset-CutoverPasswords'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        $result.ParameterSet | Should -Not -BeNullOrEmpty
        @($result.MissingMandatory).Count | Should -Be 1
    }

    It 'honours a pinned plan over the newest one' {
        $workspacePath = Copy-FixtureWorkspace -Name 'Pinned'
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Pinned' -Key 'PlanPath' `
            -Value 'Contoso/Contoso_IdentityPlan_20260917-120000.csv'
        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $step = Get-MigrationStep -Id 'New-Users'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        [System.IO.Path]::GetFileName((Get-Argument $result 'PlanPath').Value) |
            Should -BeExactly 'Contoso_IdentityPlan_20260917-120000.csv'
    }

    It 'emits -DelegatedOrganization once settings hold one for that side' {
        $workspacePath = Copy-FixtureWorkspace -Name 'Delegated'
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Source' -Key 'DelegatedOrganization' `
            -Value 'contoso.onmicrosoft.com'
        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $step = Get-MigrationStep -Id 'Inventory-Source'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        (Get-Argument $result 'DelegatedOrganization').Value | Should -BeExactly 'contoso.onmicrosoft.com'
    }

    It 'makes a relative path from settings absolute against the workspace' {
        $workspacePath = Copy-FixtureWorkspace -Name 'RelativePath'
        $null = New-Item -Path (Join-Path $workspacePath 'SkuMap.csv') -ItemType File -Force
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Plan' -Key 'SkuMapPath' -Value 'SkuMap.csv'
        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $step = Get-MigrationStep -Id 'New-IdentityPlan'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        $argument = Get-Argument $result 'SkuMapPath'
        [System.IO.Path]::IsPathRooted($argument.Value) | Should -BeTrue
        $argument.Value | Should -BeExactly (Join-Path $workspace.Path 'SkuMap.csv')
    }

    It 'flags a settings path that is not on disk without dropping it' {
        $workspacePath = Copy-FixtureWorkspace -Name 'MissingPath'
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Plan' -Key 'SkuMapPath' -Value 'Nowhere.csv'
        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $step = Get-MigrationStep -Id 'New-IdentityPlan'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        $argument = Get-Argument $result 'SkuMapPath'
        $argument | Should -Not -BeNullOrEmpty
        $argument.Warning | Should -Not -BeNullOrEmpty
    }

    # Angle brackets are Pester's own -ForEach placeholders, so the resolver is spelled
    # without them in the test name.
    It 'resolves a Settings resolver to the stored path' {
        $workspacePath = Copy-FixtureWorkspace -Name 'SettingsResolver'
        $null = New-Item -Path (Join-Path $workspacePath 'Waves.csv') -ItemType File -Force
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Plan' -Key 'WaveMapPath' -Value 'Waves.csv'
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        # No catalogue entry uses Settings: today, so the resolver is exercised on a copy of a
        # real step with the binding swapped for the resolver that reads the same key.
        $step = Get-MigrationStep -Id 'New-IdentityPlan'
        $bind = @{}
        foreach ($bindKey in @($step.Bind.Keys)) {
            if ($step.Bind[$bindKey] -ne 'WaveMapPath') { $bind[$bindKey] = $step.Bind[$bindKey] }
        }
        $step.Bind = $bind
        $step.Resolve['WaveMapPath'] = 'Settings:Plan.WaveMapPath'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        $argument = Get-Argument $result 'WaveMapPath'
        $argument.Value | Should -BeExactly (Join-Path $workspace.Path 'Waves.csv')
        $argument.Source | Should -BeExactly 'Resolved'
    }

    It 'releases the domain Release names when it differs from the one identities land on' {
        $workspacePath = Copy-FixtureWorkspace -Name 'SeparateRelease'
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Domains' -Key 'Release' -Value 'contoso.com'
        $workspace = Get-MigrationWorkspace -Path $workspacePath
        $step = Get-MigrationStep -Id 'DomainReferences-Remediate'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        (Get-Argument $result 'Domain').Value | Should -BeExactly 'contoso.com'
        # The planner still lands identities on the target domain: the two are separate keys
        # precisely so a rebrand can release one and land on the other.
        $planner = Resolve-MigrationStepArguments -Step (Get-MigrationStep -Id 'New-IdentityPlan') `
            -Workspace $workspace
        (Get-Argument $planner 'TargetDomain').Value | Should -BeExactly 'newco.com'
    }

    It 'gives each side the tenant its own settings block names' {
        $workspacePath = Copy-FixtureWorkspace -Name 'TwoTenants'
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Source' -Key 'TenantId' `
            -Value '11111111-1111-1111-1111-111111111111'
        Set-SettingsValue -WorkspacePath $workspacePath -Section 'Destination' -Key 'TenantId' `
            -Value '22222222-2222-2222-2222-222222222222'
        $workspace = Get-MigrationWorkspace -Path $workspacePath

        $source = Resolve-MigrationStepArguments -Step (Get-MigrationStep -Id 'Inventory-Source') `
            -Workspace $workspace
        (Get-Argument $source 'TenantId').Value | Should -BeExactly '11111111-1111-1111-1111-111111111111'

        $destination = Resolve-MigrationStepArguments -Step (Get-MigrationStep -Id 'New-Users') `
            -Workspace $workspace
        (Get-Argument $destination 'TenantId').Value | Should -BeExactly '22222222-2222-2222-2222-222222222222'
    }

    It 'leaves a relative value alone unless the schema types its key as a path' {
        # 'newco.com' is relative and would join happily onto the workspace folder. Only the
        # schema's Type decides, never the shape of the value or the spelling of the key.
        $workspace = Get-MigrationWorkspace -Path $script:FixtureRoot
        $result = Resolve-MigrationStepArguments -Step (Get-MigrationStep -Id 'New-IdentityPlan') `
            -Workspace $workspace
        (Get-Argument $result 'TargetDomain').Value | Should -BeExactly 'newco.com'
    }

    It 'answers with nothing rather than throwing when the Export resolver has no catalogue' {
        $workspace = Get-MigrationWorkspace -Path $script:FixtureRoot
        InModuleScope M365Migration -Parameters @{ Workspace = $workspace } {
            param($Workspace)
            $resolved = Resolve-MigrationStepInput -Resolver 'Export:Get-TeamsPhoneAssignments' `
                -Workspace $Workspace -Catalog $null
            $resolved.Source | Should -BeExactly 'Export:Get-TeamsPhoneAssignments'
            $resolved.Value | Should -BeNullOrEmpty
            @($resolved.Candidates).Count | Should -Be 0
        }
    }

    It 'warns about a resolver name it does not know' {
        $workspace = Get-MigrationWorkspace -Path $script:FixtureRoot
        $step = Get-MigrationStep -Id 'New-Users'
        # An unbound parameter, because a resolver is only consulted when no higher rung of
        # the ladder has already answered for that parameter.
        $step.Resolve['HideFromAddressLists'] = 'NoSuchResolver'

        $result = Resolve-MigrationStepArguments -Step $step -Workspace $workspace
        @($result.Warnings) -join ' ' | Should -Match 'NoSuchResolver'
    }
}
