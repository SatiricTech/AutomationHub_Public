#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Connect-MigrationGraph' {

    Context 'Scope verification' {

        It 'Connects and returns the context when every scope is granted' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Get-MgContext { [pscustomobject]@{
                    Scopes = @('User.ReadWrite.All', 'Directory.ReadWrite.All')
                    TenantId = '00000000-0000-0000-0000-000000000001'
                    Account = 'admin@contoso.onmicrosoft.com' } }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }

                $context = Connect-MigrationGraph -Scopes 'User.ReadWrite.All', 'Directory.ReadWrite.All'
                $context.Account | Should -BeExactly 'admin@contoso.onmicrosoft.com'
            }
        }

        It 'Throws listing every scope that was not granted' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                $script:contextCalls = 0
                Mock Get-MgContext {
                    $script:contextCalls++
                    # No cached session on the first look; after connecting, a session that
                    # was granted only one of the three requested scopes.
                    if ($script:contextCalls -eq 1) { return $null }
                    return [pscustomobject]@{
                        Scopes   = @('User.Read.All')
                        TenantId = '00000000-0000-0000-0000-000000000001'
                        Account  = 'admin@contoso.onmicrosoft.com'
                    }
                }

                { Connect-MigrationGraph -Scopes 'User.Read.All', 'User.ReadWrite.All', 'User-PasswordProfile.ReadWrite.All' } |
                    Should -Throw -ExpectedMessage '*User.ReadWrite.All, User-PasswordProfile.ReadWrite.All*'
            }
        }

        It 'Disconnects when consent falls short, so the next run re-prompts' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                $script:contextCalls = 0
                Mock Get-MgContext {
                    $script:contextCalls++
                    if ($script:contextCalls -eq 1) { return $null }
                    return [pscustomobject]@{ Scopes = @(); TenantId = 'x'; Account = 'a@contoso.com' }
                }

                { Connect-MigrationGraph -Scopes 'User.ReadWrite.All' } | Should -Throw
                Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
            }
        }
    }

    Context 'Cached session handling' {

        It 'Reuses a cached session that already holds every scope' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Get-MgContext { [pscustomobject]@{
                    Scopes = @('User.Read.All'); TenantId = 'tenant-1'; Account = 'a@contoso.com' } }

                $null = Connect-MigrationGraph -Scopes 'User.Read.All'
                Should -Invoke Connect-MgGraph -Times 0 -Exactly
            }
        }

        It 'Drops a cached session that lacks a requested scope' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Invoke-MgGraphRequest { throw 'Invoke-MgGraphRequest should not be reachable without a mock' }
                $script:contextCalls = 0
                Mock Get-MgContext {
                    $script:contextCalls++
                    if ($script:contextCalls -eq 1) {
                        return [pscustomobject]@{ Scopes = @('User.Read.All'); TenantId = 'tenant-1'; Account = 'a@contoso.com' }
                    }
                    return [pscustomobject]@{
                        Scopes = @('User.Read.All', 'User.ReadWrite.All'); TenantId = 'tenant-1'; Account = 'a@contoso.com' }
                }

                $null = Connect-MigrationGraph -Scopes 'User.Read.All', 'User.ReadWrite.All'
                Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
                Should -Invoke Connect-MgGraph -Times 1 -Exactly
            }
        }

        It 'Drops a cached session that targets a different tenant' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Invoke-MgGraphRequest { throw 'Invoke-MgGraphRequest should not be reachable without a mock' }
                $script:contextCalls = 0
                Mock Get-MgContext {
                    $script:contextCalls++
                    $tenant = if ($script:contextCalls -eq 1) { 'tenant-other' } else { 'tenant-wanted' }
                    return [pscustomobject]@{ Scopes = @('User.Read.All'); TenantId = $tenant; Account = 'a@contoso.com' }
                }

                $null = Connect-MigrationGraph -Scopes 'User.Read.All' -TenantId 'tenant-wanted'
                Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
            }
        }

        It 'Reuses a cached session whose granted ReadWrite scope satisfies a requested read-only sibling' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Get-MgContext { [pscustomobject]@{
                    Scopes = @('User.ReadWrite.All', 'Directory.ReadWrite.All')
                    TenantId = 'tenant-1'; Account = 'a@contoso.com' } }

                $null = Connect-MigrationGraph -Scopes 'User.Read.All', 'Directory.Read.All'
                Should -Invoke Connect-MgGraph -Times 0 -Exactly
            }
        }

        It 'Does not let a granted read-only scope satisfy a requested ReadWrite scope' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Get-MgContext { [pscustomobject]@{
                    Scopes = @('User.Read.All'); TenantId = 'tenant-1'; Account = 'a@contoso.com' } }

                # Still only User.Read.All after the reconnect, so the missing-scope throw
                # fires - the point of this test is the drop (the first Disconnect-MgGraph
                # call); the second is the module's own consent-shortfall cleanup.
                { Connect-MigrationGraph -Scopes 'User.ReadWrite.All' } | Should -Throw
                Should -Invoke Disconnect-MgGraph -Times 2 -Exactly
            }
        }

        It 'Reconnects on demand even when the cached session would qualify' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Invoke-MgGraphRequest { throw 'Invoke-MgGraphRequest should not be reachable without a mock' }
                Mock Get-MgContext { [pscustomobject]@{
                    Scopes = @('User.Read.All'); TenantId = 'tenant-1'; Account = 'a@contoso.com' } }

                $null = Connect-MigrationGraph -Scopes 'User.Read.All' -Reconnect
                Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
                Should -Invoke Connect-MgGraph -Times 1 -Exactly
            }
        }
    }

    Context 'Organisation display name' {

        It 'Still returns the context when the organisation lookup fails' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Invoke-MgGraphRequest { throw 'no permission' }
                $script:contextCalls = 0
                Mock Get-MgContext {
                    $script:contextCalls++
                    if ($script:contextCalls -eq 1) { return $null }
                    return [pscustomobject]@{
                        Scopes = @('User.Read.All'); TenantId = 'tenant-1'; Account = 'a@contoso.com' }
                }

                $context = Connect-MigrationGraph -Scopes 'User.Read.All'
                $context.Account | Should -BeExactly 'a@contoso.com'
            }
        }

        It 'Requests the organisation display name after a fresh connect' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Contoso Ltd' }) } }
                $script:contextCalls = 0
                Mock Get-MgContext {
                    $script:contextCalls++
                    if ($script:contextCalls -eq 1) { return $null }
                    return [pscustomobject]@{
                        Scopes = @('User.Read.All'); TenantId = 'tenant-1'; Account = 'a@contoso.com' }
                }

                $null = Connect-MigrationGraph -Scopes 'User.Read.All'
                Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*organization*' }
            }
        }
    }

    Context 'Connection failure' {

        It 'Throws when no session is established' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Get-MgContext { $null }

                { Connect-MigrationGraph -Scopes 'User.Read.All' } |
                    Should -Throw -ExpectedMessage '*without establishing a session*'
            }
        }

        It 'Wraps a Connect-MgGraph failure with context' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Get-MgContext { $null }
                Mock Disconnect-MgGraph { }
                Mock Connect-MgGraph { throw 'user cancelled the sign-in' }

                { Connect-MigrationGraph -Scopes 'User.Read.All' } |
                    Should -Throw -ExpectedMessage '*Could not connect to Microsoft Graph*'
            }
        }
    }
}

Describe 'Connect-MigrationExchange' {

    It 'Reuses a live session for the same delegated organisation' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            Mock Get-ConnectionInformation { [pscustomobject]@{
                State = 'Connected'; Organization = ''; DelegatedOrganization = 'contoso.onmicrosoft.com'
                TenantId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'a@contoso.com' } }

            $null = Connect-MigrationExchange -DelegatedOrganization 'contoso.onmicrosoft.com'
            Should -Invoke Connect-ExchangeOnline -Times 0 -Exactly
        }
    }

    It 'Replaces a session pointed at a different delegated organisation' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            $script:calls = 0
            Mock Get-ConnectionInformation {
                $script:calls++
                $delegated = if ($script:calls -eq 1) { 'fabrikam.onmicrosoft.com' } else { 'contoso.onmicrosoft.com' }
                [pscustomobject]@{ State = 'Connected'; Organization = ''; DelegatedOrganization = $delegated
                    TenantId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'a@contoso.com' }
            }

            $null = Connect-MigrationExchange -DelegatedOrganization 'contoso.onmicrosoft.com'
            Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly
            Should -Invoke Connect-ExchangeOnline -Times 1 -Exactly
        }
    }

    It 'Replaces a session pointed at a different tenant when -TenantId is given' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            $script:calls = 0
            Mock Get-ConnectionInformation {
                $script:calls++
                $tenantId = if ($script:calls -eq 1) { '22222222-2222-2222-2222-222222222222' } else { '11111111-1111-1111-1111-111111111111' }
                [pscustomobject]@{ State = 'Connected'; Organization = ''; DelegatedOrganization = ''
                    TenantId = $tenantId; UserPrincipalName = 'a@contoso.com' }
            }

            $null = Connect-MigrationExchange -TenantId '11111111-1111-1111-1111-111111111111'
            Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly
            Should -Invoke Connect-ExchangeOnline -Times 1 -Exactly
        }
    }

    It 'Does not reuse a session when neither property is populated (CBA-less, undetermined tenant)' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            Mock Get-ConnectionInformation { [pscustomobject]@{
                State = 'Connected'; Organization = ''; DelegatedOrganization = ''
                TenantId = ''; UserPrincipalName = 'a@contoso.com' } }

            # Nothing to compare against, so the cached session is reused rather than forced
            # through a needless reconnect.
            $null = Connect-MigrationExchange
            Should -Invoke Connect-ExchangeOnline -Times 0 -Exactly
        }
    }

    It 'Throws when no session is established' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            Mock Get-ConnectionInformation { $null }

            { Connect-MigrationExchange } | Should -Throw -ExpectedMessage '*without establishing a session*'
        }
    }
}
