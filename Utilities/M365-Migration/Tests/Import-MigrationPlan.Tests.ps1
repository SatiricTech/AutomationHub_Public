#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Plan-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null

    $script:planColumns = InModuleScope M365Migration { $script:MigrationPlanColumns }
    $script:writebackColumns = InModuleScope M365Migration { $script:MigrationPlanWritebackColumns }

    function New-SamplePlanRow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds a fixture inside the test workspace.')]
        param(
            [string]$Id,
            [string]$Upn,
            [string]$ObjectType = 'User',
            [string]$Wave = '1',
            [string]$PlanStatus = 'Planned'
        )
        $row = New-MigrationPlanRow
        $row.SourceObjectId = $Id
        $row.SourceUserPrincipalName = $Upn
        $row.SourcePrimarySmtp = $Upn
        $row.ObjectType = $ObjectType
        $row.Wave = $Wave
        $row.PlanStatus = $PlanStatus
        $row.DisplayName = $Id
        return $row
    }

    function New-PlanFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds a fixture inside the test workspace.')]
        param([string]$Name, [object[]]$Rows, [string[]]$OmitColumns = @())
        $path = Join-Path $script:workspace $Name
        $columns = @($script:planColumns | Where-Object { $OmitColumns -notcontains $_ })
        $Rows | Select-Object -Property $columns | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8
        return $path
    }
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-MigrationPlanRow' {

    It 'Returns every plan column in canonical order' {
        (New-MigrationPlanRow).PSObject.Properties.Name | Should -Be $script:planColumns
    }

    It 'Leaves every column empty' {
        $row = New-MigrationPlanRow
        foreach ($column in $script:planColumns) {
            $row.$column | Should -BeExactly '' -Because "$column should start empty"
        }
    }
}

Describe 'Import-MigrationPlan' {

    Context 'Schema validation' {

        It 'Reads a complete plan' {
            $path = New-PlanFile -Name 'complete.csv' -Rows @(
                (New-SamplePlanRow -Id '1' -Upn 'john.smith@contoso.com')
                (New-SamplePlanRow -Id '2' -Upn 'jane.doe@contoso.com')
            )
            $plan = Import-MigrationPlan -Path $path
            $plan | Should -HaveCount 2
            $plan[0].PSObject.Properties.Name | Should -Be $script:planColumns
        }

        It 'Adds the writeback columns when the file omits them' {
            $path = New-PlanFile -Name 'no-writeback.csv' `
                -Rows @((New-SamplePlanRow -Id '1' -Upn 'john.smith@contoso.com')) `
                -OmitColumns $script:writebackColumns
            $plan = Import-MigrationPlan -Path $path
            foreach ($column in $script:writebackColumns) {
                $plan[0].PSObject.Properties.Name | Should -Contain $column
                $plan[0].$column | Should -BeExactly ''
            }
        }

        It 'Throws naming a missing required column' {
            $path = New-PlanFile -Name 'missing.csv' `
                -Rows @((New-SamplePlanRow -Id '1' -Upn 'john.smith@contoso.com')) `
                -OmitColumns @('TargetUserPrincipalName')
            { Import-MigrationPlan -Path $path } |
                Should -Throw -ExpectedMessage '*TargetUserPrincipalName*'
        }

        It 'Throws when the plan does not exist' {
            { Import-MigrationPlan -Path (Join-Path $script:workspace 'nope.csv') } |
                Should -Throw -ExpectedMessage '*not found*'
        }
    }

    Context 'Filters' {

        BeforeAll {
            $script:mixedPlan = New-PlanFile -Name 'mixed.csv' -Rows @(
                (New-SamplePlanRow -Id '1' -Upn 'a@contoso.com' -Wave '1' -ObjectType 'User' -PlanStatus 'Planned')
                (New-SamplePlanRow -Id '2' -Upn 'b@contoso.com' -Wave '2' -ObjectType 'User' -PlanStatus 'Planned')
                (New-SamplePlanRow -Id '3' -Upn 'c@contoso.com' -Wave '1' -ObjectType 'Shared' -PlanStatus 'NeedsReview')
                (New-SamplePlanRow -Id '4' -Upn 'd@contoso.com' -Wave '1' -ObjectType 'User' -PlanStatus 'Excluded')
            )
        }

        It 'Filters by wave' {
            $plan = Import-MigrationPlan -Path $script:mixedPlan -Wave '2'
            $plan | Should -HaveCount 1
            $plan[0].SourceObjectId | Should -BeExactly '2'
        }

        It 'Filters by object type' {
            $plan = Import-MigrationPlan -Path $script:mixedPlan -ObjectType 'Shared'
            $plan | Should -HaveCount 1
            $plan[0].SourceObjectId | Should -BeExactly '3'
        }

        It 'Filters by plan status' {
            $plan = Import-MigrationPlan -Path $script:mixedPlan -PlanStatus 'Planned'
            @($plan.SourceObjectId) | Should -Be @('1', '2')
        }

        It 'Combines filters with AND' {
            $plan = Import-MigrationPlan -Path $script:mixedPlan -Wave '1' -ObjectType 'User' -PlanStatus 'Planned'
            $plan | Should -HaveCount 1
            $plan[0].SourceObjectId | Should -BeExactly '1'
        }

        It 'Returns excluded rows so writers can record a Skipped result' {
            $plan = Import-MigrationPlan -Path $script:mixedPlan
            @($plan.SourceObjectId) | Should -Contain '4'
        }

        It 'Throws when the filters match nothing' {
            { Import-MigrationPlan -Path $script:mixedPlan -Wave '99' } |
                Should -Throw -ExpectedMessage '*no rows*'
        }
    }
}

Describe 'Select-MigrationPlanRows' {

    BeforeAll {
        $script:rows = @(
            (New-SamplePlanRow -Id '1' -Upn 'a@contoso.com' -Wave '1' -ObjectType 'User' -PlanStatus 'Planned')
            (New-SamplePlanRow -Id '2' -Upn 'b@contoso.com' -Wave '1' -ObjectType 'User' -PlanStatus 'Excluded')
            (New-SamplePlanRow -Id '3' -Upn 'c@contoso.com' -Wave '2' -ObjectType 'Shared' -PlanStatus 'Collision')
        )
    }

    It 'Drops excluded rows by default' {
        @(Select-MigrationPlanRows -Rows $script:rows).SourceObjectId | Should -Be @('1', '3')
    }

    It 'Keeps excluded rows with -IncludeExcluded' {
        @(Select-MigrationPlanRows -Rows $script:rows -IncludeExcluded) | Should -HaveCount 3
    }

    It 'Honours an explicit Excluded status filter' {
        $result = @(Select-MigrationPlanRows -Rows $script:rows -PlanStatus 'Excluded')
        $result | Should -HaveCount 1
        $result[0].SourceObjectId | Should -BeExactly '2'
    }

    It 'Accepts several values for one filter' {
        @(Select-MigrationPlanRows -Rows $script:rows -ObjectType 'User', 'Shared' -IncludeExcluded) |
            Should -HaveCount 3
    }

    It 'Returns nothing when nothing matches' {
        @(Select-MigrationPlanRows -Rows $script:rows -Wave '99') | Should -HaveCount 0
    }
}

Describe 'Save-MigrationPlan' {

    It 'Round-trips a plan without changing its content' {
        $rows = @(
            (New-SamplePlanRow -Id '1' -Upn 'john.smith@contoso.com')
            (New-SamplePlanRow -Id '2' -Upn 'jane.doe@contoso.com')
        )
        $path = New-PlanFile -Name 'roundtrip.csv' -Rows $rows
        $before = Import-MigrationPlan -Path $path

        Save-MigrationPlan -Path $path -Rows $before
        $after = Import-MigrationPlan -Path $path

        ($after | ConvertTo-Json -Depth 3) | Should -BeExactly ($before | ConvertTo-Json -Depth 3)
    }

    It 'Round-trips the extended source profile columns' {
        $row = New-SamplePlanRow -Id '1' -Upn 'john.smith@contoso.com'
        $row.City = 'Chicago'
        $row.State = 'IL'
        $row.Country = 'US'
        $row.PostalCode = '60601'
        $row.StreetAddress = '233 S Wacker Dr'
        $row.CompanyName = 'Contoso Ltd'
        $row.EmployeeId = 'E10045'
        $row.EmployeeType = 'Employee'
        $row.BusinessPhone = '+13125550100'
        $row.FaxNumber = '+13125550199'
        $row.PreferredLanguage = 'en-US'

        $path = New-PlanFile -Name 'roundtrip-attributes.csv' -Rows @($row)
        $before = Import-MigrationPlan -Path $path
        Save-MigrationPlan -Path $path -Rows $before
        $after = Import-MigrationPlan -Path $path

        $after[0].City | Should -BeExactly 'Chicago'
        $after[0].State | Should -BeExactly 'IL'
        $after[0].Country | Should -BeExactly 'US'
        $after[0].PostalCode | Should -BeExactly '60601'
        $after[0].StreetAddress | Should -BeExactly '233 S Wacker Dr'
        $after[0].CompanyName | Should -BeExactly 'Contoso Ltd'
        $after[0].EmployeeId | Should -BeExactly 'E10045'
        $after[0].EmployeeType | Should -BeExactly 'Employee'
        $after[0].BusinessPhone | Should -BeExactly '+13125550100'
        $after[0].FaxNumber | Should -BeExactly '+13125550199'
        $after[0].PreferredLanguage | Should -BeExactly 'en-US'
    }

    It 'Writes the full canonical column order even when the input omits columns' {
        $path = Join-Path $script:workspace 'restore-columns.csv'
        Save-MigrationPlan -Path $path -Rows @([pscustomobject]@{ SourceObjectId = '1'; PlanStatus = 'Planned' })
        $written = Import-Csv -LiteralPath $path
        $written[0].PSObject.Properties.Name | Should -Be $script:planColumns
    }

    It 'Persists a writeback edit' {
        $path = New-PlanFile -Name 'writeback.csv' -Rows @((New-SamplePlanRow -Id '1' -Upn 'john.smith@contoso.com'))
        $plan = Import-MigrationPlan -Path $path
        $plan[0].ProvisionStatus = 'Succeeded'
        $plan[0].TargetObjectId = '00000000-0000-0000-0000-000000000001'
        Save-MigrationPlan -Path $path -Rows $plan

        $reloaded = Import-MigrationPlan -Path $path
        $reloaded[0].ProvisionStatus | Should -BeExactly 'Succeeded'
        $reloaded[0].TargetObjectId | Should -BeExactly '00000000-0000-0000-0000-000000000001'
    }

    Context 'Backups' {

        BeforeEach {
            # Initialize-MigrationRun resets the once-per-run backup tracking.
            InModuleScope M365Migration {
                $script:MigrationPlanBackups =
                    [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }

        It 'Writes a .bak holding the state the run started from' {
            $path = New-PlanFile -Name 'backup.csv' -Rows @((New-SamplePlanRow -Id '1' -Upn 'first@contoso.com'))
            $backupPath = "$path.bak"
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }

            $plan = Import-MigrationPlan -Path $path
            $plan[0].SourceUserPrincipalName = 'second@contoso.com'
            Save-MigrationPlan -Path $path -Rows $plan

            Test-Path -LiteralPath $backupPath | Should -BeTrue
            (Import-Csv -LiteralPath $backupPath)[0].SourceUserPrincipalName | Should -BeExactly 'first@contoso.com'
        }

        It 'Does not overwrite the backup on a second save in the same run' {
            $path = New-PlanFile -Name 'backup-once.csv' -Rows @((New-SamplePlanRow -Id '1' -Upn 'first@contoso.com'))
            $backupPath = "$path.bak"
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }

            $plan = Import-MigrationPlan -Path $path
            $plan[0].SourceUserPrincipalName = 'second@contoso.com'
            Save-MigrationPlan -Path $path -Rows $plan

            $plan[0].SourceUserPrincipalName = 'third@contoso.com'
            Save-MigrationPlan -Path $path -Rows $plan

            (Import-Csv -LiteralPath $backupPath)[0].SourceUserPrincipalName | Should -BeExactly 'first@contoso.com'
            (Import-Csv -LiteralPath $path)[0].SourceUserPrincipalName | Should -BeExactly 'third@contoso.com'
        }

        It 'Writes nothing with -WhatIf' {
            $path = New-PlanFile -Name 'whatif.csv' -Rows @((New-SamplePlanRow -Id '1' -Upn 'first@contoso.com'))
            $plan = Import-MigrationPlan -Path $path
            $plan[0].SourceUserPrincipalName = 'changed@contoso.com'
            Save-MigrationPlan -Path $path -Rows $plan -WhatIf

            (Import-Csv -LiteralPath $path)[0].SourceUserPrincipalName | Should -BeExactly 'first@contoso.com'
        }
    }
}
