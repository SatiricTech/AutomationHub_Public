#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    # MicrosoftTeams is not installed on a build agent, so the cmdlet the function pages
    # through is stubbed into the module scope for Mock to replace.
    InModuleScope M365Migration {
        if (-not (Get-Command -Name 'Get-CsPhoneNumberAssignment' -ErrorAction SilentlyContinue)) {
            function script:Get-CsPhoneNumberAssignment {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'A signature-only stub so Mock has a command to replace; the parameters exist to be matched by -ParameterFilter, not used.')]
                param([int]$Top, [int]$Skip, [string]$PstnAssignmentStatus, [string]$CapabilitiesContain)
                return @()
            }
        }
    }
}

Describe 'Get-MigrationPhoneNumberInventory' {

    It 'Returns a single short page without asking for another' {
        InModuleScope M365Migration {
            Mock Get-CsPhoneNumberAssignment {
                @(1..3 | ForEach-Object { [pscustomobject]@{ TelephoneNumber = "+155512340$_" } })
            }

            $numbers = Get-MigrationPhoneNumberInventory -PageSize 10
            $numbers | Should -HaveCount 3
            Should -Invoke Get-CsPhoneNumberAssignment -Times 1 -Exactly
        }
    }

    It 'Pages until a short page comes back' {
        InModuleScope M365Migration {
            Mock Get-CsPhoneNumberAssignment {
                switch ($Skip) {
                    0  { @(1..10 | ForEach-Object { [pscustomobject]@{ Index = $_ } }) }
                    10 { @(11..20 | ForEach-Object { [pscustomobject]@{ Index = $_ } }) }
                    default { @([pscustomobject]@{ Index = 21 }) }
                }
            }

            $numbers = Get-MigrationPhoneNumberInventory -PageSize 10
            $numbers | Should -HaveCount 21
            Should -Invoke Get-CsPhoneNumberAssignment -Times 3 -Exactly
        }
    }

    It 'Stops on an exactly-full final page followed by an empty one' {
        InModuleScope M365Migration {
            Mock Get-CsPhoneNumberAssignment {
                if ($Skip -eq 0) { @(1..10 | ForEach-Object { [pscustomobject]@{ Index = $_ } }) } else { @() }
            }

            (Get-MigrationPhoneNumberInventory -PageSize 10) | Should -HaveCount 10
            Should -Invoke Get-CsPhoneNumberAssignment -Times 2 -Exactly
        }
    }

    It 'Returns an empty array for an empty inventory' {
        InModuleScope M365Migration {
            Mock Get-CsPhoneNumberAssignment { @() }
            @(Get-MigrationPhoneNumberInventory) | Should -HaveCount 0
        }
    }

    It 'Splats the filter onto the cmdlet' {
        InModuleScope M365Migration {
            Mock Get-CsPhoneNumberAssignment { @() } -ParameterFilter {
                $PstnAssignmentStatus -eq 'Unassigned' -and $Top -eq 1000 -and $Skip -eq 0
            }

            $null = Get-MigrationPhoneNumberInventory -Filter @{ PstnAssignmentStatus = 'Unassigned' }
            Should -Invoke Get-CsPhoneNumberAssignment -Times 1 -Exactly
        }
    }

    It 'Wraps a cmdlet failure with the offset it happened at' {
        InModuleScope M365Migration {
            Mock Get-CsPhoneNumberAssignment { throw 'the service is unavailable' }

            { Get-MigrationPhoneNumberInventory } |
                Should -Throw -ExpectedMessage '*telephone number inventory at offset 0*'
        }
    }

    It 'Rejects a page size outside the range the cmdlet accepts' {
        { Get-MigrationPhoneNumberInventory -PageSize 0 } | Should -Throw
        { Get-MigrationPhoneNumberInventory -PageSize 1001 } | Should -Throw
    }
}
