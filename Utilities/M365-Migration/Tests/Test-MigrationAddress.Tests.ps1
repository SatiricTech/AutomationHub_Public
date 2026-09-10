#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Test-MigrationAddress' {

    Context 'Valid UPNs' {

        It 'Accepts <Address>' -ForEach @(
            @{ Address = 'john.smith@contoso.com' }
            @{ Address = 'JOHN.SMITH@CONTOSO.COM' }
            @{ Address = "o'brien@contoso.com" }
            @{ Address = 'jane-doe@contoso.co.uk' }
            @{ Address = 'j_smith@contoso.com' -replace '_', '.' }
            @{ Address = 'jane_fabrikam.com#EXT#@newco.onmicrosoft.com' }
        ) {
            $result = Test-MigrationAddress -Address $Address -Kind Upn
            $result.IsValid | Should -BeTrue -Because "'$Address' is a legal UPN"
            $result.Reason | Should -BeExactly ''
        }
    }

    Context 'Invalid UPNs' {

        It 'Rejects an empty address' {
            (Test-MigrationAddress -Address '' -Kind Upn).IsValid | Should -BeFalse
        }

        It 'Rejects an address with no @' {
            $result = Test-MigrationAddress -Address 'john.smith' -Kind Upn
            $result.IsValid | Should -BeFalse
            $result.Reason | Should -Match "exactly one '@'"
        }

        It 'Rejects an address with two @ characters' {
            (Test-MigrationAddress -Address 'a@b@contoso.com' -Kind Upn).IsValid | Should -BeFalse
        }

        It 'Rejects consecutive dots in the local part' {
            $result = Test-MigrationAddress -Address 'john..smith@contoso.com' -Kind Upn
            $result.IsValid | Should -BeFalse
            $result.Reason | Should -Match 'consecutive dots'
        }

        It 'Rejects a leading dot in the local part' {
            (Test-MigrationAddress -Address '.john@contoso.com' -Kind Upn).IsValid | Should -BeFalse
        }

        It 'Rejects a trailing dot in the local part' {
            (Test-MigrationAddress -Address 'john.@contoso.com' -Kind Upn).IsValid | Should -BeFalse
        }

        It 'Rejects a domain with no dot' {
            $result = Test-MigrationAddress -Address 'john@contoso' -Kind Upn
            $result.IsValid | Should -BeFalse
            $result.Reason | Should -Match 'must contain a dot'
        }

        It 'Rejects a disallowed character in the local part' {
            (Test-MigrationAddress -Address 'john smith@contoso.com' -Kind Upn).IsValid | Should -BeFalse
        }

        It 'Accepts a 64-character local part but rejects 65' {
            (Test-MigrationAddress -Address ('a' * 64 + '@contoso.com') -Kind Upn).IsValid | Should -BeTrue
            $result = Test-MigrationAddress -Address ('a' * 65 + '@contoso.com') -Kind Upn
            $result.IsValid | Should -BeFalse
            $result.Reason | Should -Match 'maximum is 64'
        }

        It 'Rejects a UPN domain longer than 48 characters' {
            $domain = ('d' * 45) + '.com'
            $result = Test-MigrationAddress -Address "john@$domain" -Kind Upn
            $result.IsValid | Should -BeFalse
            $result.Reason | Should -Match 'maximum for a UPN is 48'
        }

        It 'Accepts a UPN at the 113-character total limit' {
            # 64 + 1 + 48 is exactly 113, so the total limit is the sum of the component
            # limits: an address that clears both parts can never breach it.
            $local = 'a' * 64
            $domain = ('d' * 44) + '.com'
            $address = "$local@$domain"
            $address.Length | Should -Be 113
            (Test-MigrationAddress -Address $address -Kind Upn).IsValid | Should -BeTrue
        }

        It 'Rejects a UPN over 113 characters in total' {
            $local = 'a' * 64
            $domain = ('d' * 45) + '.com'
            $result = Test-MigrationAddress -Address "$local@$domain" -Kind Upn
            $result.IsValid | Should -BeFalse
            $result.Reason | Should -Match 'maximum for Upn is 113'
        }

        It 'Rejects a UPN whose domain exceeds 48 characters' {
            $domain = ('d' * 45) + '.com'
            $result = Test-MigrationAddress -Address "john@$domain" -Kind Upn
            $result.IsValid | Should -BeFalse
            $result.Reason | Should -Match 'maximum for a UPN is 48'
        }
    }

    Context 'SMTP addresses' {

        It 'Accepts an RFC-safe local part that a UPN would reject' {
            (Test-MigrationAddress -Address 'sales+eu@contoso.com' -Kind Smtp).IsValid | Should -BeTrue
            (Test-MigrationAddress -Address 'sales+eu@contoso.com' -Kind Upn).IsValid | Should -BeFalse
        }

        It 'Allows a total length above the UPN limit' {
            $local = 'a' * 60
            $domain = ('d' * 60) + '.com'
            (Test-MigrationAddress -Address "$local@$domain" -Kind Smtp).IsValid | Should -BeTrue
        }

        It 'Rejects a total length over 254 characters' {
            $local = 'a' * 64
            $domain = ('d' * 240) + '.com'
            $result = Test-MigrationAddress -Address "$local@$domain" -Kind Smtp
            $result.IsValid | Should -BeFalse
            $result.Reason | Should -Match 'maximum for Smtp is 254'
        }
    }

    Context 'Mail nicknames' {

        It 'Accepts a plain nickname' {
            (Test-MigrationAddress -Address 'john.smith' -Kind MailNickname).IsValid | Should -BeTrue
        }

        It 'Rejects an @ sign' {
            (Test-MigrationAddress -Address 'john@contoso.com' -Kind MailNickname).IsValid | Should -BeFalse
        }

        It 'Rejects a leading or trailing dot' {
            (Test-MigrationAddress -Address '.john' -Kind MailNickname).IsValid | Should -BeFalse
            (Test-MigrationAddress -Address 'john.' -Kind MailNickname).IsValid | Should -BeFalse
        }

        It 'Rejects an apostrophe' {
            (Test-MigrationAddress -Address "o'brien" -Kind MailNickname).IsValid | Should -BeFalse
        }

        It 'Accepts 64 characters but rejects 65' {
            (Test-MigrationAddress -Address ('a' * 64) -Kind MailNickname).IsValid | Should -BeTrue
            (Test-MigrationAddress -Address ('a' * 65) -Kind MailNickname).IsValid | Should -BeFalse
        }
    }
}
