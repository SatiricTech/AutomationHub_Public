#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Get-MigrationPlanSchema' {

    It 'exposes the 48 plan columns in canonical order with the writeback subset' {
        $schema = Get-MigrationPlanSchema
        $schema.Columns.Count | Should -Be 48
        $schema.Columns[0] | Should -Be 'ObjectType'; $schema.Columns[-1] | Should -Be 'ProvisionDetail'
        $schema.WritebackColumns | Should -Be @(
            'TargetObjectId', 'MailboxProvisioned', 'OneDriveProvisioned', 'ProvisionStatus', 'ProvisionDetail'
        )
        $schema.PlanStatuses | Should -Contain 'ManualOverride'
    }

    It 'matches the header of Templates/IdentityPlan.sample.csv' {
        $csvPath = Join-Path $PSScriptRoot '..' 'Templates' 'IdentityPlan.sample.csv'
        $header = (Get-Content $csvPath -First 1) -split ',' | ForEach-Object { $_.Trim('"') }
        $header | Should -Be (Get-MigrationPlanSchema).Columns
    }

    It 'Returns copies, not the module''s own arrays, so a caller cannot mutate the schema' {
        $schema = Get-MigrationPlanSchema
        $schema.Columns[0] = 'Tampered'
        (Get-MigrationPlanSchema).Columns[0] | Should -Be 'ObjectType'
    }

    It 'exports Get-MigrationDefaultOutputRoot' {
        Get-Command Get-MigrationDefaultOutputRoot -Module M365Migration | Should -Not -BeNullOrEmpty
    }
}
