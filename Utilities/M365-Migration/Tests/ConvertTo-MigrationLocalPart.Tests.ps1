#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'ConvertTo-MigrationLocalPart' {

    Context 'Transliteration and sanitising' {

        It 'Strips diacritics and keeps the hyphen in a double-barrelled surname' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName 'José' -LastName 'Müller-Østergaard'
            $result.LocalPart | Should -BeExactly 'jose.muller-ostergaard'
            $result.IsComplete | Should -BeTrue
            $result.MissingTokens | Should -BeNullOrEmpty
        }

        It 'Removes spaces and apostrophes' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName 'Mary Anne' -LastName "O'Brien"
            $result.LocalPart | Should -BeExactly 'maryanne.obrien'
            $result.IsComplete | Should -BeTrue
        }

        It 'Joins a multi-word surname particle' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName 'Anna' -LastName 'van der Berg'
            $result.LocalPart | Should -BeExactly 'anna.vanderberg'
        }

        It 'Drops characters outside a-z 0-9 and hyphen' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName 'J@ne!' -LastName 'Sm/th'
            $result.LocalPart | Should -BeExactly 'jne.smth'
        }
    }

    Context 'Incomplete input' {

        It 'Reports a missing last name rather than guessing' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName 'John' -LastName ''
            $result.IsComplete | Should -BeFalse
            $result.MissingTokens | Should -Be @('last')
        }

        It 'Reports every empty token for a CJK-only name' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName '张' -LastName '伟'
            $result.IsComplete | Should -BeFalse
            $result.MissingTokens | Should -Be @('first', 'last')
            $result.LocalPart | Should -BeExactly ''
        }
    }

    Context 'Optional middle-name tokens' {

        It 'Includes the middle initial when a middle name exists' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{m}.{last}' -FirstName 'John' -MiddleName 'Michael' -LastName 'Smith'
            $result.LocalPart | Should -BeExactly 'john.m.smith'
            $result.IsComplete | Should -BeTrue
        }

        It 'Drops the middle token and its separator when there is no middle name' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{m}.{last}' -FirstName 'John' -LastName 'Smith'
            $result.LocalPart | Should -BeExactly 'john.smith'
            $result.IsComplete | Should -BeTrue
            $result.MissingTokens | Should -BeNullOrEmpty
        }

        It 'Drops a full middle-name token when there is no middle name' {
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{middle}.{last}' -FirstName 'John' -LastName 'Smith'
            $result.LocalPart | Should -BeExactly 'john.smith'
            $result.IsComplete | Should -BeTrue
        }
    }

    Context 'Truncation, source and display tokens' {

        It 'Truncates a token to the requested length' {
            $result = ConvertTo-MigrationLocalPart -Template '{f}{last:5}' -FirstName 'John' -LastName 'Ostergaard'
            $result.LocalPart | Should -BeExactly 'joster'
        }

        It 'Leaves a token shorter than the truncation length intact' {
            $result = ConvertTo-MigrationLocalPart -Template '{last:5}' -LastName 'Fox'
            $result.LocalPart | Should -BeExactly 'fox'
        }

        It 'Passes the source local part through unchanged apart from case' {
            $result = ConvertTo-MigrationLocalPart -Template '{source}' -SourceLocalPart 'John.M.Smith'
            $result.LocalPart | Should -BeExactly 'john.m.smith'
            $result.IsComplete | Should -BeTrue
        }

        It 'Passes a guest #EXT# local part through untouched' {
            $result = ConvertTo-MigrationLocalPart -Template 'Keep' -SourceLocalPart 'jane_fabrikam.com#EXT#'
            $result.LocalPart | Should -BeExactly 'jane_fabrikam.com#EXT#'
            $result.IsComplete | Should -BeTrue
        }

        It 'Sanitises the display-name token' {
            $result = ConvertTo-MigrationLocalPart -Template '{display}' -DisplayName "Mary Anne O'Brien"
            $result.LocalPart | Should -BeExactly 'maryanneobrien'
        }

        It 'Flags a missing source token' {
            $result = ConvertTo-MigrationLocalPart -Template '{source}' -SourceLocalPart ''
            $result.IsComplete | Should -BeFalse
            $result.MissingTokens | Should -Be @('source')
        }
    }

    Context 'Assembly rules' {

        It 'Collapses repeated separators and trims the ends' {
            $result = ConvertTo-MigrationLocalPart -Template '.{first}..{last}-' -FirstName 'John' -LastName 'Smith'
            $result.LocalPart | Should -BeExactly 'john.smith'
        }

        It 'Passes literal characters through' {
            $result = ConvertTo-MigrationLocalPart -Template 'svc-{first}' -FirstName 'Backup'
            $result.LocalPart | Should -BeExactly 'svc-backup'
        }
    }

    Context '64-character boundary' {

        It 'Returns a 64-character local part intact' {
            $first = 'a' * 32
            $last = 'b' * 31
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName $first -LastName $last
            $result.LocalPart.Length | Should -Be 64
            $result.IsComplete | Should -BeTrue
            (Test-MigrationAddress -Address "$($result.LocalPart)@contoso.com" -Kind Upn).IsValid | Should -BeTrue
        }

        It 'Does not silently truncate a local part over 64 characters' {
            $first = 'a' * 33
            $last = 'b' * 31
            $result = ConvertTo-MigrationLocalPart -Template '{first}.{last}' -FirstName $first -LastName $last
            $result.LocalPart.Length | Should -Be 65
            (Test-MigrationAddress -Address "$($result.LocalPart)@contoso.com" -Kind Upn).IsValid | Should -BeFalse
        }
    }

    Context 'Named presets' {

        It 'Resolves preset <Name> to <Expected>' -ForEach @(
            @{ Name = 'First.Last';   Expected = 'john.smith' }
            @{ Name = 'FLast';        Expected = 'jsmith' }
            @{ Name = 'F.Last';       Expected = 'j.smith' }
            @{ Name = 'FirstLast';    Expected = 'johnsmith' }
            @{ Name = 'First';        Expected = 'john' }
            @{ Name = 'First.L';      Expected = 'john.s' }
            @{ Name = 'FirstL';       Expected = 'johns' }
            @{ Name = 'First.M.Last'; Expected = 'john.m.smith' }
            @{ Name = 'FMLast';       Expected = 'jmsmith' }
            @{ Name = 'Last.First';   Expected = 'smith.john' }
            @{ Name = 'Keep';         Expected = 'jsmith' }
        ) {
            $result = ConvertTo-MigrationLocalPart -Template $Name -FirstName 'John' -MiddleName 'Michael' `
                -LastName 'Smith' -SourceLocalPart 'jsmith'
            $result.LocalPart | Should -BeExactly $Expected
            $result.IsComplete | Should -BeTrue
        }

        It 'Matches a preset name case-insensitively' {
            (ConvertTo-MigrationLocalPart -Template 'first.last' -FirstName 'John' -LastName 'Smith').LocalPart |
                Should -BeExactly 'john.smith'
        }
    }
}
