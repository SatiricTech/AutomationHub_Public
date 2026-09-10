#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    function New-Candidate {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that builds an in-memory fixture object.')]
        param([string]$Key, [string]$LocalPart, [string]$MiddleInitial = '', [string]$Domain = 'contoso.com')
        [pscustomobject]@{ Key = $Key; LocalPart = $LocalPart; MiddleInitial = $MiddleInitial; Domain = $Domain }
    }
}

Describe 'Resolve-MigrationCollision' {

    Context 'Three John Smiths, none with a middle initial' {

        BeforeAll {
            # Deliberately supplied out of order: the resolver must sort by Key first.
            $script:noMiddle = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'c' -LocalPart 'john.smith')
                (New-Candidate -Key 'a' -LocalPart 'john.smith')
                (New-Candidate -Key 'b' -LocalPart 'john.smith')
            )
        }

        It 'Gives the lowest key the unsuffixed local part' {
            $row = $script:noMiddle | Where-Object Key -eq 'a'
            $row.ResolvedLocalPart | Should -BeExactly 'john.smith'
            $row.Collided | Should -BeFalse
            $row.Resolution | Should -BeExactly 'None'
        }

        It 'Suffixes the second key when it has no middle initial' {
            $row = $script:noMiddle | Where-Object Key -eq 'b'
            $row.ResolvedLocalPart | Should -BeExactly 'john.smith2'
            $row.Collided | Should -BeTrue
            $row.Resolution | Should -BeExactly 'Suffix'
        }

        It 'Gives the third key the next suffix' {
            $row = $script:noMiddle | Where-Object Key -eq 'c'
            $row.ResolvedLocalPart | Should -BeExactly 'john.smith3'
            $row.Resolution | Should -BeExactly 'Suffix'
        }
    }

    Context 'Three John Smiths, the second with a middle initial' {

        BeforeAll {
            $script:withMiddle = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'c' -LocalPart 'john.smith')
                (New-Candidate -Key 'a' -LocalPart 'john.smith')
                (New-Candidate -Key 'b' -LocalPart 'john.smith' -MiddleInitial 'Q')
            )
        }

        It 'Keeps the first key unchanged' {
            ($script:withMiddle | Where-Object Key -eq 'a').ResolvedLocalPart | Should -BeExactly 'john.smith'
        }

        It 'Prefers the middle initial over a digit for the second key' {
            $row = $script:withMiddle | Where-Object Key -eq 'b'
            $row.ResolvedLocalPart | Should -BeExactly 'john.q.smith'
            $row.Collided | Should -BeTrue
            $row.Resolution | Should -BeExactly 'MiddleInitial'
        }

        It 'Falls back to the first free suffix for the third key' {
            $row = $script:withMiddle | Where-Object Key -eq 'c'
            $row.ResolvedLocalPart | Should -BeExactly 'john.smith2'
            $row.Resolution | Should -BeExactly 'Suffix'
        }
    }

    Context 'Determinism' {

        It 'Produces identical output when re-run on the same input' {
            $candidates = @(
                (New-Candidate -Key 'c' -LocalPart 'john.smith')
                (New-Candidate -Key 'a' -LocalPart 'john.smith')
                (New-Candidate -Key 'b' -LocalPart 'john.smith' -MiddleInitial 'Q')
                (New-Candidate -Key 'd' -LocalPart 'jane.doe')
            )

            $first = Resolve-MigrationCollision -Candidates $candidates |
                ForEach-Object { "$($_.Key)=$($_.ResolvedLocalPart):$($_.Resolution)" }
            $second = Resolve-MigrationCollision -Candidates ($candidates | Sort-Object -Property Key -Descending) |
                ForEach-Object { "$($_.Key)=$($_.ResolvedLocalPart):$($_.Resolution)" }

            $second | Should -Be $first
        }
    }

    Context 'Reserved addresses' {

        It 'Skips a local part already reserved in that domain' {
            $result = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'a' -LocalPart 'john.smith')
            ) -Reserved @('john.smith@contoso.com')

            $result.ResolvedLocalPart | Should -BeExactly 'john.smith2'
            $result.Collided | Should -BeTrue
            $result.Resolution | Should -BeExactly 'Suffix'
        }

        It 'Ignores a reservation held in a different domain' {
            $result = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'a' -LocalPart 'john.smith' -Domain 'contoso.com')
            ) -Reserved @('john.smith@fabrikam.com')

            $result.ResolvedLocalPart | Should -BeExactly 'john.smith'
            $result.Resolution | Should -BeExactly 'None'
        }

        It 'Treats a bare reserved local part as reserved in every domain' {
            $result = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'a' -LocalPart 'admin' -Domain 'fabrikam.com')
            ) -Reserved @('admin')

            $result.ResolvedLocalPart | Should -BeExactly 'admin2'
            $result.Resolution | Should -BeExactly 'Suffix'
        }

        It 'Does not reuse an address it has already handed out' {
            $result = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'a' -LocalPart 'john.smith')
                (New-Candidate -Key 'b' -LocalPart 'john.smith')
            ) -Reserved @('john.smith2@contoso.com')

            ($result | Where-Object Key -eq 'b').ResolvedLocalPart | Should -BeExactly 'john.smith3'
        }
    }

    Context 'Unresolvable candidates' {

        It 'Reports Unresolved when the suffixed form would exceed 64 characters' {
            $long = 'a' * 64
            $result = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'a' -LocalPart $long)
            ) -Reserved @("$long@contoso.com")

            $result.Resolution | Should -BeExactly 'Unresolved'
            $result.Collided | Should -BeTrue
            $result.ResolvedLocalPart | Should -BeExactly $long
        }

        It 'Reports Unresolved for an empty local part' {
            $result = Resolve-MigrationCollision -Candidates @((New-Candidate -Key 'a' -LocalPart ''))
            $result.Resolution | Should -BeExactly 'Unresolved'
        }

        It 'Falls back to a suffix when the middle-initial form would breach 64 characters' {
            # 63 characters: the middle-initial form reaches 65 and is rejected, but a
            # single-digit suffix still fits inside the limit.
            $base = ('a' * 60) + '.bb'
            $result = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'a' -LocalPart $base -MiddleInitial 'Q')
            ) -Reserved @("$base@contoso.com")

            $result.Resolution | Should -BeExactly 'Suffix'
            $result.ResolvedLocalPart | Should -BeExactly "${base}2"
            $result.ResolvedLocalPart.Length | Should -Be 64
        }
    }

    Context 'Pass-through' {

        It 'Carries extra properties through to the output' {
            $candidate = [pscustomobject]@{
                Key = 'a'; LocalPart = 'jane.doe'; MiddleInitial = ''; Domain = 'contoso.com'
                SourceUserPrincipalName = 'jane.doe@fabrikam.com'
            }
            $result = Resolve-MigrationCollision -Candidates @($candidate)
            $result.SourceUserPrincipalName | Should -BeExactly 'jane.doe@fabrikam.com'
        }

        It 'Returns one row per candidate' {
            $result = Resolve-MigrationCollision -Candidates @(
                (New-Candidate -Key 'a' -LocalPart 'a.one')
                (New-Candidate -Key 'b' -LocalPart 'b.two')
            )
            $result | Should -HaveCount 2
        }
    }
}
