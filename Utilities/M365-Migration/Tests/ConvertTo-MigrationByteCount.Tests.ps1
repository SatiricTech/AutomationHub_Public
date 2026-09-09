#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'ConvertTo-MigrationByteCount' {

    It 'Reads the parenthesised byte count rather than the rounded leading value' {
        InModuleScope M365Migration {
            ConvertTo-MigrationByteCount -Size '1.5 GB (1,610,612,736 bytes)' | Should -Be 1610612736
        }
    }

    It 'Handles a size with no thousands separators' {
        InModuleScope M365Migration {
            ConvertTo-MigrationByteCount -Size '512 KB (524288 bytes)' | Should -Be 524288
        }
    }

    It 'Accepts a bare digit string, as a re-imported CSV column holds' {
        InModuleScope M365Migration {
            ConvertTo-MigrationByteCount -Size '1048576' | Should -Be 1048576
        }
    }

    It 'Falls back to the object ToBytes() method' {
        InModuleScope M365Migration {
            $size = [pscustomobject]@{ Value = 'unparseable' }
            Add-Member -InputObject $size -MemberType ScriptMethod -Name 'ToBytes' -Value { 4096 }
            ConvertTo-MigrationByteCount -Size $size | Should -Be 4096
        }
    }

    It 'Returns $null for an unparseable size rather than 0' {
        InModuleScope M365Migration {
            ConvertTo-MigrationByteCount -Size 'Unlimited' | Should -BeNullOrEmpty
        }
    }

    It 'Returns $null for a null size' {
        InModuleScope M365Migration {
            ConvertTo-MigrationByteCount -Size $null | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-MigrationGigabyte' {

    It 'Converts an Exchange size to GB, rounded to two decimals' {
        InModuleScope M365Migration {
            ConvertTo-MigrationGigabyte -Size '1.5 GB (1,610,612,736 bytes)' | Should -Be 1.5
        }
    }

    It 'Keeps a small mailbox distinguishable from an empty one' {
        InModuleScope M365Migration {
            ConvertTo-MigrationGigabyte -Size '41943040' | Should -Be 0.04
            ConvertTo-MigrationGigabyte -Size '0' | Should -Be 0
        }
    }

    It 'Returns $null when the size cannot be parsed' {
        InModuleScope M365Migration {
            ConvertTo-MigrationGigabyte -Size 'Unlimited' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-MigrationFlatDateTime' {

    It 'Adds the missing Z, treating an offset-less value as UTC' {
        InModuleScope M365Migration {
            ConvertTo-MigrationFlatDateTime -Value '2026-09-08T14:30:00.1234567' |
                Should -BeExactly '2026-09-08T14:30:00Z'
        }
    }

    It 'Normalises a value that already carries an offset to UTC' {
        InModuleScope M365Migration {
            ConvertTo-MigrationFlatDateTime -Value '2026-09-08T16:30:00+02:00' |
                Should -BeExactly '2026-09-08T14:30:00Z'
        }
    }

    It 'Leaves an already-flat value alone' {
        InModuleScope M365Migration {
            ConvertTo-MigrationFlatDateTime -Value '2026-09-08T14:30:00Z' |
                Should -BeExactly '2026-09-08T14:30:00Z'
        }
    }

    It 'Accepts a DateTime object' {
        InModuleScope M365Migration {
            ConvertTo-MigrationFlatDateTime -Value ([datetime]::new(2026, 9, 8, 14, 30, 0, [DateTimeKind]::Utc)) |
                Should -BeExactly '2026-09-08T14:30:00Z'
        }
    }

    It 'Passes an unparseable value through rather than losing it' {
        InModuleScope M365Migration {
            ConvertTo-MigrationFlatDateTime -Value 'not a date' | Should -BeExactly 'not a date'
        }
    }

    It 'Returns $null for a null or blank value' {
        InModuleScope M365Migration {
            ConvertTo-MigrationFlatDateTime -Value $null | Should -BeNullOrEmpty
            ConvertTo-MigrationFlatDateTime -Value '   ' | Should -BeNullOrEmpty
        }
    }
}
