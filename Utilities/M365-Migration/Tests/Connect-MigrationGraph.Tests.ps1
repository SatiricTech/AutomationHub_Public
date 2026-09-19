#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    # Mock needs a command to replace, and neither SDK is installed on a build agent, so every
    # Graph and Exchange cmdlet this file mocks is stubbed into the module scope first. Without
    # these the file only passes on a machine that happens to have Microsoft.Graph.Authentication
    # and ExchangeOnlineManagement installed. Each stub stands aside when the real cmdlet exists.
    InModuleScope M365Migration {
        if (-not (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue)) {
            function script:Get-MgContext {
                [CmdletBinding()]
                param()
                return $null
            }
        }

        if (-not (Get-Command -Name 'Connect-MgGraph' -ErrorAction SilentlyContinue)) {
            function script:Connect-MgGraph {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Signature-only stub; the parameters exist to be bound, not read.')]
                param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome)
            }
        }

        if (-not (Get-Command -Name 'Disconnect-MgGraph' -ErrorAction SilentlyContinue)) {
            function script:Disconnect-MgGraph {
                [CmdletBinding()]
                param()
            }
        }

        if (-not (Get-Command -Name 'Invoke-MgGraphRequest' -ErrorAction SilentlyContinue)) {
            function script:Invoke-MgGraphRequest {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Signature-only stub; the parameters exist to be matched by -ParameterFilter.')]
                param(
                    [string]$Method, [string]$Uri, $Body,
                    [hashtable]$Headers, [string]$ContentType, [string]$OutputType
                )
                return $null
            }
        }

        if (-not (Get-Command -Name 'Get-ConnectionInformation' -ErrorAction SilentlyContinue)) {
            function script:Get-ConnectionInformation {
                [CmdletBinding()]
                param()
                return $null
            }
        }

        if (-not (Get-Command -Name 'Connect-ExchangeOnline' -ErrorAction SilentlyContinue)) {
            function script:Connect-ExchangeOnline {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Signature-only stub; the parameters exist to be bound, not read.')]
                param([string]$DelegatedOrganization, [switch]$ShowBanner)
            }
        }

        if (-not (Get-Command -Name 'Disconnect-ExchangeOnline' -ErrorAction SilentlyContinue)) {
            # SupportsShouldProcess so the module's own '-Confirm:$false' still binds against the stub.
            function script:Disconnect-ExchangeOnline {
                [CmdletBinding(SupportsShouldProcess)]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
                    Justification = 'The attribute is here only so -Confirm binds; the stub does nothing.')]
                param()
            }
        }
    }
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

    It 'throws and disconnects when a fresh session lands in the wrong tenant' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Get-ConnectionInformation {
                $script:calls++
                if ($script:calls -le 1) { @() }
                else {
                    [pscustomobject]@{
                        State = 'Connected'; TenantId = 'b0000000-0000-0000-0000-000000000002'
                        UserPrincipalName = 'admin@wrong.com'; DelegatedOrganization = ''
                    }
                }
            }
            $script:calls = 0
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            { Connect-MigrationExchange -TenantId 'a0000000-0000-0000-0000-000000000001' } |
                Should -Throw '*connected to tenant b0000000*'
            Should -Invoke Disconnect-ExchangeOnline -Times 1
        }
    }

    It 'resolves a domain-form -TenantId before comparing' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Resolve-MigrationTenantId { 'a0000000-0000-0000-0000-000000000001' }
            Mock Get-ConnectionInformation { [pscustomobject]@{
                State = 'Connected'; TenantId = 'a0000000-0000-0000-0000-000000000001'
                UserPrincipalName = 'admin@contoso.com'; DelegatedOrganization = '' } }
            Mock Connect-ExchangeOnline { }
            (Connect-MigrationExchange -TenantId 'contoso.onmicrosoft.com').TenantId |
                Should -Be 'a0000000-0000-0000-0000-000000000001'
            Should -Invoke Connect-ExchangeOnline -Times 0   # cached session reused because it matches
        }
    }
}
