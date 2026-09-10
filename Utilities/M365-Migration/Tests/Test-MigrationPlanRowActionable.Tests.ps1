#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
    Set-StrictMode -Version Latest

    function New-Row {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that builds an in-memory plan row.')]
        param([hashtable]$Property = @{})
        $base = @{ PlanStatus = 'Planned'; ObjectType = 'User'; IsSynced = 'False' }
        foreach ($key in $Property.Keys) { $base[$key] = $Property[$key] }
        return [pscustomobject]$base
    }
}

Describe 'Test-MigrationPlanRowActionable' {

    Context 'PlanStatus gate' {

        It 'Acts on <Status>' -ForEach @(
            @{ Status = 'Planned' }
            @{ Status = 'ManualOverride' }
            @{ Status = 'UpnSmtpDiverge' }
        ) {
            $result = Test-MigrationPlanRowActionable -Row (New-Row @{ PlanStatus = $Status })
            $result.Actionable | Should -BeTrue
            $result.Status | Should -BeExactly ''
            $result.Reason | Should -BeExactly ''
        }

        It 'Skips <Status>, naming it in the reason' -ForEach @(
            @{ Status = 'Excluded' }
            @{ Status = 'Invalid' }
            @{ Status = 'NeedsReview' }
            @{ Status = 'ExistsInDestination' }
            @{ Status = 'Collision' }
        ) {
            $result = Test-MigrationPlanRowActionable -Row (New-Row @{ PlanStatus = $Status })
            $result.Actionable | Should -BeFalse
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -BeLike "*'$Status'*"
        }

        It 'Acts on Collision with -IncludeCollisions' {
            (Test-MigrationPlanRowActionable -Row (New-Row @{ PlanStatus = 'Collision' }) -IncludeCollisions).Actionable |
                Should -BeTrue
        }

        It 'Skips an empty PlanStatus and says so readably' {
            $result = Test-MigrationPlanRowActionable -Row (New-Row @{ PlanStatus = '' })
            $result.Actionable | Should -BeFalse
            $result.Reason | Should -BeLike "*'(empty)'*"
        }

        It 'Honours an explicit -ActionableStatus set' {
            (Test-MigrationPlanRowActionable -Row (New-Row @{ PlanStatus = 'NeedsReview' }) `
                -ActionableStatus 'NeedsReview').Actionable | Should -BeTrue
            (Test-MigrationPlanRowActionable -Row (New-Row) -ActionableStatus 'NeedsReview').Actionable |
                Should -BeFalse
        }
    }

    Context 'ObjectType gate' {

        It 'Accepts any object type when none is specified' {
            (Test-MigrationPlanRowActionable -Row (New-Row @{ ObjectType = 'Distribution' })).Actionable |
                Should -BeTrue
        }

        It 'Skips an unsupported object type, naming it' {
            $result = Test-MigrationPlanRowActionable -Row (New-Row @{ ObjectType = 'Distribution' }) `
                -SupportedObjectType 'User', 'Shared'
            $result.Actionable | Should -BeFalse
            $result.Status | Should -BeExactly 'Skipped'
            $result.Reason | Should -BeLike "*'Distribution'*"
            $result.Reason | Should -BeLike '*User, Shared*'
        }

        It 'Accepts a supported object type' {
            (Test-MigrationPlanRowActionable -Row (New-Row @{ ObjectType = 'Shared' }) `
                -SupportedObjectType 'User', 'Shared').Actionable | Should -BeTrue
        }

        It 'Checks PlanStatus before ObjectType' {
            $result = Test-MigrationPlanRowActionable -Row (New-Row @{ PlanStatus = 'Excluded'; ObjectType = 'Contact' }) `
                -SupportedObjectType 'User'
            $result.Reason | Should -BeLike '*PlanStatus*'
        }
    }

    Context 'IsSynced gate' {

        It 'Fails a directory-synced row rather than skipping it' {
            $result = Test-MigrationPlanRowActionable -Row (New-Row @{ IsSynced = 'True' })
            $result.Actionable | Should -BeFalse
            $result.Status | Should -BeExactly 'Failed'
            $result.Reason | Should -BeLike '*directory-synced*'
        }

        It 'Reads the row IsSynced column case-insensitively' {
            (Test-MigrationPlanRowActionable -Row (New-Row @{ IsSynced = 'true' })).Actionable | Should -BeFalse
        }

        It 'Treats an empty or missing IsSynced as not synced' {
            (Test-MigrationPlanRowActionable -Row (New-Row @{ IsSynced = '' })).Actionable | Should -BeTrue
            (Test-MigrationPlanRowActionable -Row ([pscustomobject]@{ PlanStatus = 'Planned' })).Actionable |
                Should -BeTrue
        }

        It 'Lets a tenant-read -IsSynced override the row column' {
            (Test-MigrationPlanRowActionable -Row (New-Row @{ IsSynced = 'False' }) -IsSynced $true).Actionable |
                Should -BeFalse
            (Test-MigrationPlanRowActionable -Row (New-Row @{ IsSynced = 'True' }) -IsSynced $false).Actionable |
                Should -BeTrue
        }

        It 'Acts on a synced row with -AllowSynced' {
            (Test-MigrationPlanRowActionable -Row (New-Row @{ IsSynced = 'True' }) -AllowSynced).Actionable |
                Should -BeTrue
        }

        It 'Checks ObjectType before IsSynced' {
            $result = Test-MigrationPlanRowActionable -Row (New-Row @{ ObjectType = 'Contact'; IsSynced = 'True' }) `
                -SupportedObjectType 'User'
            $result.Status | Should -BeExactly 'Skipped'
        }
    }

    Context 'Tolerance' {

        It 'Does not throw on a row missing every column under StrictMode' {
            { Test-MigrationPlanRowActionable -Row ([pscustomobject]@{}) } | Should -Not -Throw
        }

        It 'Skips a null row rather than throwing' {
            $result = Test-MigrationPlanRowActionable -Row $null
            $result.Actionable | Should -BeFalse
            $result.Status | Should -BeExactly 'Skipped'
        }
    }
}
