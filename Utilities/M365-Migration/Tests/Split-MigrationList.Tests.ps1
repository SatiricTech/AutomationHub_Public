#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Split-MigrationList' {

    It 'Splits on the default separator and trims each item' {
        $result = Split-MigrationList -Value 'SPE_E3; MCOEV ;EMS'
        $result | Should -Be @('SPE_E3', 'MCOEV', 'EMS')
    }

    It 'Drops empty entries left by a trailing separator' {
        Split-MigrationList -Value 'SPE_E3;;MCOEV;' | Should -Be @('SPE_E3', 'MCOEV')
    }

    It 'Returns an empty array for an empty value' {
        $result = Split-MigrationList -Value ''
        $result | Should -BeNullOrEmpty
        @($result).Count | Should -Be 0
    }

    It 'Returns an empty array for whitespace only' {
        @(Split-MigrationList -Value '   ').Count | Should -Be 0
    }

    It 'Honours a custom separator' {
        Split-MigrationList -Value 'a,b,c' -Separator ',' | Should -Be @('a', 'b', 'c')
    }
}

Describe 'Join-MigrationList' {

    It 'Joins values with the default separator' {
        Join-MigrationList -Values @('SPE_E3', 'MCOEV') | Should -BeExactly 'SPE_E3;MCOEV'
    }

    It 'Drops null and empty entries' {
        Join-MigrationList -Values @('SPE_E3', '', $null, '  ', 'EMS') | Should -BeExactly 'SPE_E3;EMS'
    }

    It 'Returns an empty string for an empty collection' {
        Join-MigrationList -Values @() | Should -BeExactly ''
    }

    It 'Round-trips through Split-MigrationList' {
        $original = 'smtp:j.smith@contoso.com;smtp:js@contoso.com'
        Join-MigrationList -Values (Split-MigrationList -Value $original) | Should -BeExactly $original
    }
}
