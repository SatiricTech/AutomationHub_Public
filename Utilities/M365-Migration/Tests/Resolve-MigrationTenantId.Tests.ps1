#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Resolve-MigrationTenantId' {

    It 'returns a GUID unchanged without calling the network' {
        InModuleScope M365Migration {
            Mock Invoke-RestMethod { throw 'must not be called' }
            Resolve-MigrationTenantId -Tenant '{A1B2C3D4-0000-0000-0000-000000000001}' |
                Should -Be 'a1b2c3d4-0000-0000-0000-000000000001'
        }
    }

    It 'resolves a domain through the OIDC discovery document' {
        InModuleScope M365Migration {
            $issuer = 'https://login.microsoftonline.com/a1b2c3d4-0000-0000-0000-000000000001/v2.0'
            $discoveryUri = 'https://login.microsoftonline.com/contoso.onmicrosoft.com/v2.0/' +
                '.well-known/openid-configuration'
            Mock Invoke-RestMethod {
                [pscustomobject]@{ issuer = $issuer }
            } -ParameterFilter { $Uri -like $discoveryUri }

            Resolve-MigrationTenantId -Tenant 'contoso.onmicrosoft.com' |
                Should -Be 'a1b2c3d4-0000-0000-0000-000000000001'
        }
    }

    It 'throws a named error when the domain is unknown' {
        InModuleScope M365Migration {
            Mock Invoke-RestMethod { throw 'AADSTS90002: Tenant not found' }
            { Resolve-MigrationTenantId -Tenant 'nope.example' } |
                Should -Throw "*'nope.example' could not be resolved*"
        }
    }

    It 'throws a named error when the issuer has no GUID segment' {
        InModuleScope M365Migration {
            Mock Invoke-RestMethod { [pscustomobject]@{ issuer = 'https://login.microsoftonline.com/common/v2.0' } }
            { Resolve-MigrationTenantId -Tenant 'contoso.onmicrosoft.com' } |
                Should -Throw '*could not be resolved*'
        }
    }

    It 'throws a named error on a non-JSON response' {
        InModuleScope M365Migration {
            Mock Invoke-RestMethod { '<html>' }
            { Resolve-MigrationTenantId -Tenant 'contoso.onmicrosoft.com' } |
                Should -Throw '*could not be resolved*'
        }
    }

    It 'calls Invoke-RestMethod with a 15-second timeout' {
        InModuleScope M365Migration {
            $issuer = 'https://login.microsoftonline.com/a1b2c3d4-0000-0000-0000-000000000001/v2.0'
            Mock Invoke-RestMethod {
                [pscustomobject]@{ issuer = $issuer }
            } -ParameterFilter { $TimeoutSec -eq 15 }

            Resolve-MigrationTenantId -Tenant 'contoso.onmicrosoft.com' | Should -Not -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 15 }
        }
    }
}
