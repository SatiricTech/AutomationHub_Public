#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Assert-MigrationTenant' {

    Context 'Every connection matches' {

        It 'returns Matches true and reports every connected tenant' {
            InModuleScope M365Migration {
                $graph = [pscustomobject]@{ TenantId = 'a0000000-0000-0000-0000-000000000001'; Account = 'admin@contoso.com' }
                $exchange = [pscustomobject]@{
                    TenantID = 'a0000000-0000-0000-0000-000000000001'; UserPrincipalName = 'admin@contoso.com' }
                $teams = [pscustomobject]@{ TenantId = 'a0000000-0000-0000-0000-000000000001' }

                $result = Assert-MigrationTenant -ExpectedTenantId 'a0000000-0000-0000-0000-000000000001' `
                    -GraphContext $graph -ExchangeConnection $exchange -TeamsTenant $teams

                $result.Matches | Should -BeTrue
                $result.ExpectedTenantId | Should -Be 'a0000000-0000-0000-0000-000000000001'
                $result.Connected.Graph | Should -Be 'a0000000-0000-0000-0000-000000000001'
                $result.Connected.Exchange | Should -Be 'a0000000-0000-0000-0000-000000000001'
                $result.Connected.Teams | Should -Be 'a0000000-0000-0000-0000-000000000001'
            }
        }
    }

    Context 'A connection disagrees with -ExpectedTenantId' {

        It 'throws when the Graph tenant does not match' {
            InModuleScope M365Migration {
                $graph = [pscustomobject]@{ TenantId = 'b0000000-0000-0000-0000-000000000002'; Account = 'admin@wrong.com' }

                { Assert-MigrationTenant -ExpectedTenantId 'a0000000-0000-0000-0000-000000000001' -GraphContext $graph } |
                    Should -Throw '*Microsoft Graph is connected to tenant b0000000*'
            }
        }

        It 'throws when the Exchange tenant does not match' {
            InModuleScope M365Migration {
                $exchange = [pscustomobject]@{
                    TenantID = 'b0000000-0000-0000-0000-000000000002'; UserPrincipalName = 'admin@wrong.com' }

                { Assert-MigrationTenant -ExpectedTenantId 'a0000000-0000-0000-0000-000000000001' `
                    -ExchangeConnection $exchange } | Should -Throw '*Exchange Online is connected to tenant b0000000*'
            }
        }

        It 'throws when the Teams tenant does not match' {
            InModuleScope M365Migration {
                $teams = [pscustomobject]@{ TenantId = 'b0000000-0000-0000-0000-000000000002' }

                { Assert-MigrationTenant -ExpectedTenantId 'a0000000-0000-0000-0000-000000000001' -TeamsTenant $teams } |
                    Should -Throw '*Microsoft Teams is connected to tenant b0000000*'
            }
        }

        It 'prefixes the throw message with the default Purpose' {
            InModuleScope M365Migration {
                $graph = [pscustomobject]@{ TenantId = 'b0000000-0000-0000-0000-000000000002' }

                { Assert-MigrationTenant -ExpectedTenantId 'a0000000-0000-0000-0000-000000000001' -GraphContext $graph } |
                    Should -Throw 'This run:*'
            }
        }

        It 'prefixes the throw message with a custom -Purpose' {
            InModuleScope M365Migration {
                $graph = [pscustomobject]@{ TenantId = 'b0000000-0000-0000-0000-000000000002' }

                { Assert-MigrationTenant -ExpectedTenantId 'a0000000-0000-0000-0000-000000000001' -GraphContext $graph `
                    -Purpose 'Cutover for contoso' } | Should -Throw 'Cutover for contoso:*'
            }
        }
    }

    Context 'No -ExpectedTenantId was given' {

        It 'returns Matches false with the no-tenant reason' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $graph = [pscustomobject]@{ TenantId = 'a0000000-0000-0000-0000-000000000001'; Account = 'admin@contoso.com' }

                $result = Assert-MigrationTenant -ExpectedTenantId '' -GraphContext $graph

                $result.Matches | Should -BeFalse
                $result.Reason | Should -Be 'No tenant was specified'
            }
        }

        It 'writes one warning per supplied connection' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $graph = [pscustomobject]@{ TenantId = 'a0000000-0000-0000-0000-000000000001'; Account = 'admin@contoso.com' }
                $exchange = [pscustomobject]@{
                    TenantID = 'a0000000-0000-0000-0000-000000000001'; UserPrincipalName = 'admin@contoso.com' }

                $null = Assert-MigrationTenant -ExpectedTenantId '' -GraphContext $graph -ExchangeConnection $exchange

                Should -Invoke Write-MigrationLog -ParameterFilter { $Level -eq 'WARNING' } -Times 2 -Exactly
            }
        }

        It 'includes the UPN in parentheses in the warning when one is available' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $graph = [pscustomobject]@{ TenantId = 'a0000000-0000-0000-0000-000000000001'; Account = 'admin@contoso.com' }

                $null = Assert-MigrationTenant -ExpectedTenantId '' -GraphContext $graph

                Should -Invoke Write-MigrationLog -Times 1 -Exactly -ParameterFilter {
                    $Level -eq 'WARNING' -and $Message -eq (
                        'No -TenantId was given; this run acts on tenant a0000000-0000-0000-0000-000000000001 ' +
                        '(admin@contoso.com). Pass -TenantId to guard against a cached session.')
                }
            }
        }

        It 'omits the parenthesis in the warning when no UPN is available' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $teams = [pscustomobject]@{ TenantId = 'a0000000-0000-0000-0000-000000000001' }

                $null = Assert-MigrationTenant -ExpectedTenantId '' -TeamsTenant $teams

                Should -Invoke Write-MigrationLog -Times 1 -Exactly -ParameterFilter {
                    $Level -eq 'WARNING' -and $Message -eq (
                        'No -TenantId was given; this run acts on tenant a0000000-0000-0000-0000-000000000001. ' +
                        'Pass -TenantId to guard against a cached session.')
                }
            }
        }

        It 'returns Matches false without warning when no connections are supplied' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }

                $result = Assert-MigrationTenant -ExpectedTenantId ''

                $result.Matches | Should -BeFalse
                Should -Invoke Write-MigrationLog -Times 0 -Exactly
            }
        }
    }

    Context 'Domain-form -ExpectedTenantId' {

        It 'resolves a domain-form -ExpectedTenantId before comparing' {
            InModuleScope M365Migration {
                Mock Resolve-MigrationTenantId { 'a0000000-0000-0000-0000-000000000001' }
                $graph = [pscustomobject]@{ TenantId = 'a0000000-0000-0000-0000-000000000001'; Account = 'admin@contoso.com' }

                $result = Assert-MigrationTenant -ExpectedTenantId 'contoso.onmicrosoft.com' -GraphContext $graph

                $result.Matches | Should -BeTrue
                $result.ExpectedTenantId | Should -Be 'a0000000-0000-0000-0000-000000000001'
                Should -Invoke Resolve-MigrationTenantId -Times 1 -Exactly -ParameterFilter {
                    $Tenant -eq 'contoso.onmicrosoft.com'
                }
            }
        }
    }
}
