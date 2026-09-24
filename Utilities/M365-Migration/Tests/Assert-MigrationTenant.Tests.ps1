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
                $tenantId = 'a0000000-0000-0000-0000-000000000001'
                $graph = [pscustomobject]@{ TenantId = $tenantId; Account = 'admin@contoso.com' }
                $exchange = [pscustomobject]@{ TenantID = $tenantId; UserPrincipalName = 'admin@contoso.com' }
                $teams = [pscustomobject]@{ TenantId = $tenantId }

                $result = Assert-MigrationTenant -ExpectedTenantId $tenantId `
                    -GraphContext $graph -ExchangeConnection $exchange -TeamsTenant $teams

                $result.Matches | Should -BeTrue
                $result.ExpectedTenantId | Should -Be $tenantId
                $result.Connected.Graph | Should -Be $tenantId
                $result.Connected.Exchange | Should -Be $tenantId
                $result.Connected.Teams | Should -Be $tenantId
                $result.Reason | Should -Be ''
            }
        }
    }

    Context 'Case-insensitive comparison' {

        It 'treats a differently-cased connected GUID as matching' {
            InModuleScope M365Migration {
                $expected = 'a0000000-0000-0000-0000-000000000001'
                $graph = [pscustomobject]@{ TenantId = 'A0000000-0000-0000-0000-000000000001' }

                $result = Assert-MigrationTenant -ExpectedTenantId $expected -GraphContext $graph

                $result.Matches | Should -BeTrue
                $result.Reason | Should -Be ''
            }
        }
    }

    Context 'A connection disagrees with -ExpectedTenantId' {

        It 'throws when the Graph tenant does not match' {
            InModuleScope M365Migration {
                $expected = 'a0000000-0000-0000-0000-000000000001'
                $wrong = 'b0000000-0000-0000-0000-000000000002'
                $graph = [pscustomobject]@{ TenantId = $wrong; Account = 'admin@wrong.com' }

                { Assert-MigrationTenant -ExpectedTenantId $expected -GraphContext $graph } |
                    Should -Throw '*Microsoft Graph is connected to tenant b0000000*'
            }
        }

        It 'throws when the Exchange tenant does not match' {
            InModuleScope M365Migration {
                $expected = 'a0000000-0000-0000-0000-000000000001'
                $wrong = 'b0000000-0000-0000-0000-000000000002'
                $exchange = [pscustomobject]@{ TenantID = $wrong; UserPrincipalName = 'admin@wrong.com' }

                { Assert-MigrationTenant -ExpectedTenantId $expected -ExchangeConnection $exchange } |
                    Should -Throw '*Exchange Online is connected to tenant b0000000*'
            }
        }

        It 'throws when the Teams tenant does not match' {
            InModuleScope M365Migration {
                $expected = 'a0000000-0000-0000-0000-000000000001'
                $wrong = 'b0000000-0000-0000-0000-000000000002'
                $teams = [pscustomobject]@{ TenantId = $wrong }

                { Assert-MigrationTenant -ExpectedTenantId $expected -TeamsTenant $teams } |
                    Should -Throw '*Microsoft Teams is connected to tenant b0000000*'
            }
        }

        It 'prefixes the throw message with the default Purpose' {
            InModuleScope M365Migration {
                $expected = 'a0000000-0000-0000-0000-000000000001'
                $graph = [pscustomobject]@{ TenantId = 'b0000000-0000-0000-0000-000000000002' }

                { Assert-MigrationTenant -ExpectedTenantId $expected -GraphContext $graph } |
                    Should -Throw 'This run:*'
            }
        }

        It 'prefixes the throw message with a custom -Purpose' {
            InModuleScope M365Migration {
                $expected = 'a0000000-0000-0000-0000-000000000001'
                $graph = [pscustomobject]@{ TenantId = 'b0000000-0000-0000-0000-000000000002' }

                { Assert-MigrationTenant -ExpectedTenantId $expected -GraphContext $graph `
                    -Purpose 'Cutover for contoso' } | Should -Throw 'Cutover for contoso:*'
            }
        }
    }

    Context 'A connection cannot report its tenant' {

        It 'warns and marks the connection Unverified without throwing' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $expected = 'a0000000-0000-0000-0000-000000000001'
                $exchange = [pscustomobject]@{ TenantID = ''; UserPrincipalName = 'admin@contoso.com' }

                $result = Assert-MigrationTenant -ExpectedTenantId $expected -ExchangeConnection $exchange

                $result.Matches | Should -BeTrue
                $result.Reason | Should -Be 'Unverified: Exchange'
                Should -Invoke Write-MigrationLog -Times 1 -Exactly -ParameterFilter {
                    $Level -eq 'WARNING' -and $Message -eq (
                        'Could not read the tenant ID from the Exchange connection; the tenant guard ' +
                        'cannot verify it.')
                }
            }
        }
    }

    Context 'No -ExpectedTenantId was given' {

        It 'returns Matches false with the no-tenant reason' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $tenantId = 'a0000000-0000-0000-0000-000000000001'
                $graph = [pscustomobject]@{ TenantId = $tenantId; Account = 'admin@contoso.com' }

                $result = Assert-MigrationTenant -ExpectedTenantId '' -GraphContext $graph

                $result.Matches | Should -BeFalse
                $result.Reason | Should -Be 'No tenant was specified'
            }
        }

        It 'writes one warning per supplied connection' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $tenantId = 'a0000000-0000-0000-0000-000000000001'
                $graph = [pscustomobject]@{ TenantId = $tenantId; Account = 'admin@contoso.com' }
                $exchange = [pscustomobject]@{ TenantID = $tenantId; UserPrincipalName = 'admin@contoso.com' }

                $null = Assert-MigrationTenant -ExpectedTenantId '' -GraphContext $graph -ExchangeConnection $exchange

                Should -Invoke Write-MigrationLog -ParameterFilter { $Level -eq 'WARNING' } -Times 2 -Exactly
            }
        }

        It 'includes the UPN in parentheses in the warning when one is available' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $tenantId = 'a0000000-0000-0000-0000-000000000001'
                $graph = [pscustomobject]@{ TenantId = $tenantId; Account = 'admin@contoso.com' }

                $null = Assert-MigrationTenant -ExpectedTenantId '' -GraphContext $graph

                Should -Invoke Write-MigrationLog -Times 1 -Exactly -ParameterFilter {
                    $Level -eq 'WARNING' -and $Message -eq (
                        "No -TenantId was given; this run acts on tenant $tenantId " +
                        '(admin@contoso.com). Pass -TenantId to guard against a cached session.')
                }
            }
        }

        It 'omits the parenthesis in the warning when no UPN is available' {
            InModuleScope M365Migration {
                Mock Write-MigrationLog { }
                $tenantId = 'a0000000-0000-0000-0000-000000000001'
                $teams = [pscustomobject]@{ TenantId = $tenantId }

                $null = Assert-MigrationTenant -ExpectedTenantId '' -TeamsTenant $teams

                Should -Invoke Write-MigrationLog -Times 1 -Exactly -ParameterFilter {
                    $Level -eq 'WARNING' -and $Message -eq (
                        "No -TenantId was given; this run acts on tenant $tenantId. " +
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
                $tenantId = 'a0000000-0000-0000-0000-000000000001'
                Mock Resolve-MigrationTenantId { $tenantId }
                $graph = [pscustomobject]@{ TenantId = $tenantId; Account = 'admin@contoso.com' }

                $result = Assert-MigrationTenant -ExpectedTenantId 'contoso.onmicrosoft.com' -GraphContext $graph

                $result.Matches | Should -BeTrue
                $result.ExpectedTenantId | Should -Be $tenantId
                Should -Invoke Resolve-MigrationTenantId -Times 1 -Exactly -ParameterFilter {
                    $Tenant -eq 'contoso.onmicrosoft.com'
                }
            }
        }
    }
}
