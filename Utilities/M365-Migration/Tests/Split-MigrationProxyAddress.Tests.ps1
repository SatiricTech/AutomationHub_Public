#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
    Set-StrictMode -Version Latest
}

Describe 'Split-MigrationProxyAddress' {

    It 'Classifies <Entry> as <Kind> (primary: <Primary>)' -ForEach @(
        @{ Entry = 'SMTP:john@contoso.com';        Kind = 'Smtp'; Primary = $true;  Value = 'john@contoso.com' }
        @{ Entry = 'smtp:john@contoso.com';        Kind = 'Smtp'; Primary = $false; Value = 'john@contoso.com' }
        @{ Entry = 'SmTp:john@contoso.com';        Kind = 'Smtp'; Primary = $false; Value = 'john@contoso.com' }
        @{ Entry = 'john@contoso.com';             Kind = 'Smtp'; Primary = $false; Value = 'john@contoso.com' }
        @{ Entry = 'SIP:john@contoso.com';         Kind = 'Sip';  Primary = $false; Value = 'john@contoso.com' }
        @{ Entry = 'sip:john@contoso.com';         Kind = 'Sip';  Primary = $false; Value = 'john@contoso.com' }
        @{ Entry = 'SPO:SPO_1234@SPO_5678';        Kind = 'Spo';  Primary = $false; Value = 'SPO_1234@SPO_5678' }
        @{ Entry = 'X500:/o=ExchangeLabs/cn=abc';  Kind = 'X500'; Primary = $false; Value = '/o=ExchangeLabs/cn=abc' }
        @{ Entry = 'x500:/o=ExchangeLabs/cn=abc';  Kind = 'X500'; Primary = $false; Value = '/o=ExchangeLabs/cn=abc' }
        @{ Entry = 'EUM:12345;phone-context=x';    Kind = 'Other'; Primary = $false; Value = '12345;phone-context=x' }
    ) {
        $result = Split-MigrationProxyAddress -Entry $Entry
        $result.Kind | Should -BeExactly $Kind
        $result.IsPrimary | Should -Be $Primary
        $result.Address | Should -BeExactly $Value
    }

    It 'Only treats the first colon as the separator' {
        $entry = 'X500:/o=ExchangeLabs/ou=Exchange Administrative Group (FYDIBOHF23SPDLT)/cn=Recipients/cn=abc'
        $result = Split-MigrationProxyAddress -Entry $entry
        $result.Prefix | Should -BeExactly 'X500'
        $result.Address | Should -BeExactly '/o=ExchangeLabs/ou=Exchange Administrative Group (FYDIBOHF23SPDLT)/cn=Recipients/cn=abc'
    }

    It 'Trims surrounding whitespace and keeps the original entry' {
        $result = Split-MigrationProxyAddress -Entry '  SMTP:john@contoso.com  '
        $result.Entry | Should -BeExactly 'SMTP:john@contoso.com'
        $result.IsPrimary | Should -BeTrue
    }

    It 'Preserves the prefix casing it was given' {
        (Split-MigrationProxyAddress -Entry 'SMTP:john@contoso.com').Prefix | Should -BeExactly 'SMTP'
        (Split-MigrationProxyAddress -Entry 'smtp:john@contoso.com').Prefix | Should -BeExactly 'smtp'
    }

    It 'Returns an empty Smtp entry for an empty string' {
        $result = Split-MigrationProxyAddress -Entry ''
        $result.Kind | Should -BeExactly 'Smtp'
        $result.Address | Should -BeExactly ''
        $result.IsPrimary | Should -BeFalse
    }

    It 'Classifies a whole collection from the pipeline' {
        $result = @('SMTP:a@contoso.com', 'smtp:b@contoso.com', 'SIP:a@contoso.com') | Split-MigrationProxyAddress
        $result | Should -HaveCount 3
        ($result | Where-Object IsPrimary).Address | Should -BeExactly 'a@contoso.com'
    }
}
