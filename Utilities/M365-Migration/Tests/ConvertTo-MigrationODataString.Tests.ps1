#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'ConvertTo-MigrationODataString' {

    It 'Doubles a single quote' {
        ConvertTo-MigrationODataString -Value "O'Brien" | Should -BeExactly "O''Brien"
    }

    It 'Doubles every quote in a value' {
        ConvertTo-MigrationODataString -Value "O'B'rien" | Should -BeExactly "O''B''rien"
    }

    It 'Leaves a value without quotes untouched' {
        ConvertTo-MigrationODataString -Value 'john.smith@contoso.com' |
            Should -BeExactly 'john.smith@contoso.com'
    }

    It 'Returns an empty string for empty input' {
        ConvertTo-MigrationODataString -Value '' | Should -BeExactly ''
    }

    It 'Returns an empty string for null input' {
        ConvertTo-MigrationODataString -Value $null | Should -BeExactly ''
    }

    It 'Produces a filter that cannot be broken out of' {
        $safe = ConvertTo-MigrationODataString -Value "x' or startsWith(userPrincipalName,'a"
        $filter = "userPrincipalName eq '$safe'"
        # Every quote inside the literal is doubled, so the literal has exactly two
        # unescaped quotes: the ones the caller wrote.
        ($filter -replace "''", '') | Should -BeExactly "userPrincipalName eq 'x or startsWith(userPrincipalName,a'"
    }
}
