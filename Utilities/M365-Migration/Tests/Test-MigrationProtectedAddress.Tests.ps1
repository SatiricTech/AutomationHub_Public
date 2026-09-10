#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
    Set-StrictMode -Version Latest
}

Describe 'Test-MigrationProtectedAddress' {

    It 'Protects <Address>' -ForEach @(
        @{ Address = 'smtp:john@contoso.mail.onmicrosoft.com' }
        @{ Address = 'SMTP:john@contoso.onmicrosoft.com' }
        @{ Address = 'john@CONTOSO.ONMICROSOFT.COM' }
        @{ Address = 'SIP:john@contoso.com' }
        @{ Address = 'sip:john@contoso.com' }
        @{ Address = 'SPO:SPO_1234@SPO_5678' }
        @{ Address = 'X500:/o=ExchangeLabs/cn=abc' }
        @{ Address = 'EUM:12345;phone-context=x' }
    ) {
        Test-MigrationProtectedAddress -Address $Address | Should -BeTrue
    }

    It 'Does not protect <Address>' -ForEach @(
        @{ Address = 'SMTP:john@contoso.com' }
        @{ Address = 'smtp:jsmith@contoso.com' }
        @{ Address = 'john@newco.com' }
        @{ Address = 'smtp:john@onmicrosoft.com.contoso.com' }
    ) {
        Test-MigrationProtectedAddress -Address $Address | Should -BeFalse
    }

    It 'Accepts an already-split entry' {
        $entry = Split-MigrationProxyAddress -Entry 'smtp:john@contoso.mail.onmicrosoft.com'
        Test-MigrationProtectedAddress -AddressEntry $entry | Should -BeTrue
    }

    It 'Accepts pipeline input' {
        $protected = @('smtp:a@contoso.com', 'SIP:a@contoso.com', 'X500:/o=x/cn=a') |
            Where-Object { Test-MigrationProtectedAddress -Address $_ }
        $protected | Should -HaveCount 2
    }
}
