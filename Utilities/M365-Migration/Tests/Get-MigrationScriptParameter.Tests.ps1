#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:toolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    # The scripts themselves are the fixture: this helper reads the real param block, which is
    # the whole point of the function under test. A synthetic script would only prove the AST
    # walk, not that the toolkit's own 17 scripts are readable by it.
    function script:Get-ToolkitScriptParameter {
        param([Parameter(Mandatory)][string]$Name)

        InModuleScope M365Migration -Parameters @{ Path = (Join-Path $script:toolkitRoot "$Name.ps1") } {
            param($Path)
            Get-MigrationScriptParameter -ScriptPath $Path
        }
    }

    function script:Get-ToolkitParameter {
        param(
            [Parameter(Mandatory)][string]$Script,
            [Parameter(Mandatory)][string]$Parameter
        )

        $introspection = Get-ToolkitScriptParameter -Name $Script
        return @($introspection.Parameters | Where-Object Name -eq $Parameter)[0]
    }
}

Describe 'Get-MigrationScriptParameter parameter sets' {

    It 'reads Reset-MigrationCutoverPasswords'' four parameter sets, Csv the default' {
        $introspection = Get-ToolkitScriptParameter -Name 'Reset-MigrationCutoverPasswords'
        @($introspection.ParameterSets.Names) | Sort-Object | Should -Be @('Csv', 'Group', 'Plan', 'TestUser')
        $introspection.ParameterSets.Default | Should -BeExactly 'Csv'
    }

    It 'marks Reset-MigrationCutoverPasswords -PlanPath mandatory only in the Plan set' {
        $planPath = Get-ToolkitParameter -Script 'Reset-MigrationCutoverPasswords' -Parameter 'PlanPath'
        $planPath.Mandatory | Should -BeTrue
        @($planPath.MandatoryIn) | Should -Be @('Plan')
        @($planPath.ParameterSets) | Should -Be @('Plan')
    }

    It 'spreads a Reset-MigrationCutoverPasswords all-sets parameter across every named set' {
        $tenantId = Get-ToolkitParameter -Script 'Reset-MigrationCutoverPasswords' -Parameter 'TenantId'
        @($tenantId.ParameterSets) | Sort-Object | Should -Be @('Csv', 'Group', 'Plan', 'TestUser')
        $tenantId.Mandatory | Should -BeFalse
        @($tenantId.MandatoryIn) | Should -BeNullOrEmpty
    }

    It 'reports no named sets for a script that declares none, and still sees a mandatory parameter' {
        $introspection = Get-ToolkitScriptParameter -Name 'New-MigrationUsers'
        @($introspection.ParameterSets.Names) | Should -BeNullOrEmpty
        $introspection.ParameterSets.Default | Should -BeExactly ''

        $planPath = @($introspection.Parameters | Where-Object Name -eq 'PlanPath')[0]
        $planPath.Mandatory | Should -BeTrue
    }
}

Describe 'Get-MigrationScriptParameter types and defaults' {

    It 'reads New-MigrationUsers -ForceChangePassword as a [bool] defaulting to $true' {
        $force = Get-ToolkitParameter -Script 'New-MigrationUsers' -Parameter 'ForceChangePassword'
        $force.IsBool | Should -BeTrue
        $force.IsSwitch | Should -BeFalse
        $force.Default | Should -BeOfType [bool]
        $force.Default | Should -BeTrue
    }

    It 'reads New-MigrationIdentityPlan -AliasDomainMap as a hashtable and -UpnFormat''s default' {
        $map = Get-ToolkitParameter -Script 'New-MigrationIdentityPlan' -Parameter 'AliasDomainMap'
        $map.IsHashtable | Should -BeTrue
        $map.Default | Should -BeNullOrEmpty

        $upnFormat = Get-ToolkitParameter -Script 'New-MigrationIdentityPlan' -Parameter 'UpnFormat'
        $upnFormat.Default | Should -BeExactly 'First.Last'
    }

    It 'reads Set-MigrationIdentity -Apply''s ValidateSet and its array default' {
        $apply = Get-ToolkitParameter -Script 'Set-MigrationIdentity' -Parameter 'Apply'
        $apply.IsArray | Should -BeTrue
        @($apply.ValidValues) | Should -Contain 'Upn'
        @($apply.Default) | Should -Be @('Upn', 'PrimarySmtp', 'Aliases', 'X500')
    }

    It 'reads Test-MigrationReadiness -Stage''s ValidateSet exactly' {
        $stage = Get-ToolkitParameter -Script 'Test-MigrationReadiness' -Parameter 'Stage'
        @($stage.ValidValues) | Should -Be @('Pre', 'Provisioned', 'Post')
        $stage.Default | Should -BeExactly 'Pre'
    }

    It 'reads a switch parameter as a switch with no default' {
        $reportOnly = Get-ToolkitParameter -Script 'Remove-MigrationDomainReferences' -Parameter 'ReportOnly'
        $reportOnly.IsSwitch | Should -BeTrue
        $reportOnly.IsBool | Should -BeFalse
        $reportOnly.Default | Should -BeNullOrEmpty
    }

    It 'reads the ValidateRange bounds off Compare-MigrationUserData -SimilarityThreshold' {
        $threshold = Get-ToolkitParameter -Script 'Compare-MigrationUserData' -Parameter 'SimilarityThreshold'
        $threshold.Range | Should -Not -BeNullOrEmpty
        $threshold.Range.Min | Should -Be 0.0
        $threshold.Range.Max | Should -Be 1.0
        $threshold.Default | Should -Be 0.85
    }

    It 'reads the ValidatePattern off Get-MigrationInventory -DomainFilter' {
        $domainFilter = Get-ToolkitParameter -Script 'Get-MigrationInventory' -Parameter 'DomainFilter'
        $domainFilter.Pattern | Should -Not -BeNullOrEmpty
        'contoso.com' | Should -Match $domainFilter.Pattern
    }

    It 'reads the alias off Get-MigrationInventory -DelegatedOrganization' {
        $delegated = Get-ToolkitParameter -Script 'Get-MigrationInventory' -Parameter 'DelegatedOrganization'
        @($delegated.Aliases) | Should -Contain 'Tenant'
    }

    It 'leaves Range, Pattern and ValidValues empty for an unconstrained parameter' {
        $planPath = Get-ToolkitParameter -Script 'New-MigrationUsers' -Parameter 'PlanPath'
        $planPath.Range | Should -BeNullOrEmpty
        $planPath.Pattern | Should -BeNullOrEmpty
        @($planPath.ValidValues) | Should -BeNullOrEmpty
    }
}

Describe 'Get-MigrationScriptParameter common parameters' {

    It 'marks <Name> common' -ForEach @(
        @{ Name = 'OutputPath' }
        @{ Name = 'Prefix' }
        @{ Name = 'LogPath' }
        @{ Name = 'Verbosity' }
        @{ Name = 'DryRun' }
        @{ Name = 'WhatIf' }
        @{ Name = 'Confirm' }
        @{ Name = 'Verbose' }
        @{ Name = 'Debug' }
        @{ Name = 'ErrorAction' }
    ) {
        $parameter = Get-ToolkitParameter -Script 'Set-MigrationIdentity' -Parameter $Name
        $parameter | Should -Not -BeNullOrEmpty -Because "Set-MigrationIdentity should expose -$Name"
        $parameter.Common | Should -BeTrue
    }

    It 'does not mark a script''s own parameter common' {
        (Get-ToolkitParameter -Script 'Set-MigrationIdentity' -Parameter 'PlanPath').Common | Should -BeFalse
        (Get-ToolkitParameter -Script 'Set-MigrationIdentity' -Parameter 'TenantId').Common | Should -BeFalse
    }
}

Describe 'Get-MigrationScriptParameter help text' {

    It 'returns the comment-based help description for -PlanPath' {
        $planPath = Get-ToolkitParameter -Script 'Reset-MigrationCutoverPasswords' -Parameter 'PlanPath'
        $planPath.Help | Should -Not -BeNullOrEmpty
        $planPath.Help | Should -Match 'plan'
    }

    It 'returns help for every non-common parameter of every toolkit script' {
        $scripts = @(Get-ChildItem -LiteralPath $script:toolkitRoot -Filter '*-Migration*.ps1' -File)
        foreach ($file in $scripts) {
            $introspection = InModuleScope M365Migration -Parameters @{ Path = $file.FullName } {
                param($Path)
                Get-MigrationScriptParameter -ScriptPath $Path
            }
            foreach ($parameter in @($introspection.Parameters | Where-Object { -not $_.Common })) {
                $parameter.Help | Should -Not -BeNullOrEmpty `
                    -Because "$($file.BaseName) -$($parameter.Name) needs a .PARAMETER block"
            }
        }
    }
}

Describe 'Get-MigrationScriptParameter caching' {

    It 'caches by path and LastWriteTimeUtc, and re-reads an edited file' {
        $probe = Join-Path $TestDrive 'Probe-MigrationSample.ps1'
        Set-Content -LiteralPath $probe -Value @'
<#
.SYNOPSIS
    Sample.
.PARAMETER Mode
    The mode to run in.
.EXAMPLE
    ./Probe-MigrationSample.ps1 -Mode Fast
#>
[CmdletBinding()]
param(
    [ValidateSet('Fast', 'Slow')]
    [string]$Mode = 'Fast'
)
'@

        InModuleScope M365Migration -Parameters @{ Path = $probe } {
            param($Path)

            $script:MigrationScriptParameterCache.Clear()
            $first = Get-MigrationScriptParameter -ScriptPath $Path
            $script:MigrationScriptParameterCache.Count | Should -Be 1

            # A second call must hand back the very same object, not an equal one - that is
            # what makes the cache observable rather than merely plausible.
            $second = Get-MigrationScriptParameter -ScriptPath $Path
            [object]::ReferenceEquals($first, $second) | Should -BeTrue
            $script:MigrationScriptParameterCache.Count | Should -Be 1

            @(@($first.Parameters | Where-Object Name -eq 'Mode')[0].ValidValues) | Should -Be @('Fast', 'Slow')
        }

        Set-Content -LiteralPath $probe -Value @'
<#
.SYNOPSIS
    Sample.
.PARAMETER Mode
    The mode to run in.
.EXAMPLE
    ./Probe-MigrationSample.ps1 -Mode Rapid
#>
[CmdletBinding()]
param(
    [ValidateSet('Rapid', 'Steady')]
    [string]$Mode = 'Rapid'
)
'@
        # Set-Content stamps a new LastWriteTimeUtc, which is the cache key's second half.
        InModuleScope M365Migration -Parameters @{ Path = $probe } {
            param($Path)

            $third = Get-MigrationScriptParameter -ScriptPath $Path
            @(@($third.Parameters | Where-Object Name -eq 'Mode')[0].ValidValues) | Should -Be @('Rapid', 'Steady')
            $script:MigrationScriptParameterCache.Count | Should -Be 2
        }
    }

    It 'throws a clear error for a path that does not exist' {
        InModuleScope M365Migration -Parameters @{ Path = (Join-Path $TestDrive 'NoSuch-Migration.ps1') } {
            param($Path)

            # Called straight rather than through a { } | Should -Throw scriptblock: the
            # analyzer cannot see a parameter that is only used inside a nested scriptblock.
            $caught = $null
            try { $null = Get-MigrationScriptParameter -ScriptPath $Path }
            catch { $caught = $_ }

            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Message | Should -BeLike '*NoSuch-Migration.ps1*'
        }
    }
}
