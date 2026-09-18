#Requires -Version 7.4

# Match the scripts, which run under Set-StrictMode -Version Latest.
Set-StrictMode -Version Latest

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Get-MigrationOutputPath' {
    It 'builds <Prefix>_<Name>-<Suffix>_<ts>.<ext> under the directory' {
        $ts = [datetime]'2026-09-18T10:15:00'
        $path = Get-MigrationOutputPath -Directory $TestDrive -Prefix 'Contoso' -Name 'Set-Identity' -Suffix 'Results' -Timestamp $ts
        Split-Path $path -Leaf | Should -Be 'Contoso_Set-Identity-Results_20260918-101500.csv'
        Split-Path $path -Parent | Should -Be $TestDrive
    }

    It 'omits the prefix leader and the suffix when absent, honours -Extension' {
        $ts = [datetime]'2026-09-18T10:15:00'
        $path = Get-MigrationOutputPath -Directory $TestDrive -Prefix '' -Name 'IdentityPlan' -Extension 'xlsx' -Timestamp $ts
        Split-Path $path -Leaf | Should -Be 'IdentityPlan_20260918-101500.xlsx'
    }

    It 'rejects a Name or Suffix containing an underscore' {
        { Get-MigrationOutputPath -Directory $TestDrive -Name 'Bad_Name' } | Should -Throw '*underscore*'
    }
}

Describe 'ConvertFrom-MigrationOutputPath' {
    It 'parses prefix, name, suffix, timestamp and extension' -ForEach @(
        @{ File = 'Contoso_Set-Identity-Results_20260918-101500.csv'; Prefix = 'Contoso'; Name = 'Set-Identity'; Suffix = 'Results'; Ext = 'csv' }
        @{ File = 'Contoso_Set-Identity-DryRun_20260918-101500.csv';  Prefix = 'Contoso'; Name = 'Set-Identity'; Suffix = 'DryRun';  Ext = 'csv' }
        @{ File = 'Source_Users_20260917-091200.csv';                 Prefix = 'Source';  Name = 'Users';        Suffix = '';       Ext = 'csv' }
        @{ File = 'Contoso_IdentityPlan_20260918-101500.csv';         Prefix = 'Contoso'; Name = 'IdentityPlan'; Suffix = '';       Ext = 'csv' }
        @{ File = 'Contoso_Migration-Inventory_20260917-091200.xlsx'; Prefix = 'Contoso'; Name = 'Migration-Inventory'; Suffix = ''; Ext = 'xlsx' }
        @{ File = 'Contoso_DomainBlockers-Recheck_20260918-101500.csv'; Prefix = 'Contoso'; Name = 'DomainBlockers-Recheck'; Suffix = ''; Ext = 'csv' }
        @{ File = 'Contoso_New-MigrationUsers_20260918-101500.log';   Prefix = 'Contoso'; Name = 'New-MigrationUsers'; Suffix = ''; Ext = 'log' }
        @{ File = 'IdentityPlan_20260918-101500.csv';                 Prefix = '';        Name = 'IdentityPlan'; Suffix = '';       Ext = 'csv' }
    ) {
        $parsed = ConvertFrom-MigrationOutputPath -Path (Join-Path $TestDrive $File)
        $parsed.Prefix | Should -Be $Prefix
        $parsed.Name | Should -Be $Name
        $parsed.Suffix | Should -Be $Suffix
        $parsed.Extension | Should -Be $Ext
        $parsed.Timestamp | Should -BeOfType [datetime]
    }

    It 'returns $null for .bak files and names without a timestamp' {
        ConvertFrom-MigrationOutputPath -Path 'Contoso_IdentityPlan_20260918-101500.csv.bak' | Should -BeNullOrEmpty
        ConvertFrom-MigrationOutputPath -Path 'SkuMap.csv' | Should -BeNullOrEmpty
    }

    It 'round-trips what Get-MigrationOutputPath builds for a results file' {
        $ts = [datetime]'2026-09-18T10:15:00'
        $path = Get-MigrationOutputPath -Directory $TestDrive -Prefix 'Contoso' -Name 'New-Users' -Suffix 'DryRun' -Timestamp $ts
        $parsed = ConvertFrom-MigrationOutputPath -Path $path
        $parsed.Name | Should -Be 'New-Users'; $parsed.Suffix | Should -Be 'DryRun'; $parsed.Timestamp | Should -Be $ts
    }
}
