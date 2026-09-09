#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
    Set-StrictMode -Version Latest
}

Describe 'ConvertTo-MigrationX500' {

    It 'Adds the X500 prefix to a bare legacy DN' {
        ConvertTo-MigrationX500 -Value '/o=ExchangeLabs/cn=Recipients/cn=abc' |
            Should -BeExactly 'X500:/o=ExchangeLabs/cn=Recipients/cn=abc'
    }

    It 'Normalises an existing prefix to uppercase X500' {
        ConvertTo-MigrationX500 -Value 'x500:/o=ExchangeLabs/cn=abc' |
            Should -BeExactly 'X500:/o=ExchangeLabs/cn=abc'
    }

    It 'Leaves the distinguished name itself untouched' {
        $dn = '/o=ExchangeLabs/ou=Exchange Administrative Group (FYDIBOHF23SPDLT)/cn=Recipients/cn=AbC123'
        ConvertTo-MigrationX500 -Value $dn | Should -BeExactly "X500:$dn"
    }

    It 'Expands a semicolon separated list' {
        $result = ConvertTo-MigrationX500 -Value '/o=x/cn=a;X500:/o=x/cn=b'
        $result | Should -HaveCount 2
        $result | Should -Contain 'X500:/o=x/cn=a'
        $result | Should -Contain 'X500:/o=x/cn=b'
    }

    It 'Collapses duplicates case-insensitively, keeping the first spelling' {
        $result = @(ConvertTo-MigrationX500 -Value @('/o=x/cn=AbC', 'X500:/o=X/CN=abc'))
        $result | Should -HaveCount 1
        $result[0] | Should -BeExactly 'X500:/o=x/cn=AbC'
    }

    It 'Drops blank and whitespace-only entries' {
        $result = ConvertTo-MigrationX500 -Value @('', '   ', '/o=x/cn=a')
        $result | Should -HaveCount 1
    }

    It 'Returns an empty array for no input' {
        $result = ConvertTo-MigrationX500 -Value @()
        @($result) | Should -HaveCount 0
    }

    It 'Returns bare distinguished names with -NoPrefix' {
        ConvertTo-MigrationX500 -Value 'X500:/o=x/cn=a' -NoPrefix | Should -BeExactly '/o=x/cn=a'
    }

    It 'Accepts pipeline input and deduplicates across it' {
        $result = @('/o=x/cn=a', '/o=x/cn=a', '/o=x/cn=b') | ConvertTo-MigrationX500
        $result | Should -HaveCount 2
    }
}
