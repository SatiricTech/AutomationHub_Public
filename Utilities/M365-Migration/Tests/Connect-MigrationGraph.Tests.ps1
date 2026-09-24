#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    # Mock needs a command to replace, and neither SDK is installed on a build agent, so every
    # Graph and Exchange cmdlet this file mocks is stubbed into the module scope first. Without
    # these the file only passes on a machine that happens to have Microsoft.Graph.Authentication
    # and ExchangeOnlineManagement installed. Each stub stands aside when the real cmdlet exists.
    #
    # Every stub body throws. A stub that returned $null would let an unmocked call sail past on a
    # machine without the SDKs while the same test reached the real cmdlet (and a real network
    # call) on a machine with them - the file would then behave differently in the two places,
    # which is exactly what stubbing was supposed to rule out. Throwing makes the gap loud.
    InModuleScope M365Migration {
        if (-not (Get-Command -Name 'Get-MgContext' -ErrorAction SilentlyContinue)) {
            function script:Get-MgContext {
                [CmdletBinding()]
                param()
                throw 'Unmocked SDK call: Get-MgContext'
            }
        }

        if (-not (Get-Command -Name 'Connect-MgGraph' -ErrorAction SilentlyContinue)) {
            function script:Connect-MgGraph {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Signature-only stub; the parameters exist to be bound, not read.')]
                param([string[]]$Scopes, [string]$TenantId, [switch]$NoWelcome)
                throw 'Unmocked SDK call: Connect-MgGraph'
            }
        }

        if (-not (Get-Command -Name 'Disconnect-MgGraph' -ErrorAction SilentlyContinue)) {
            function script:Disconnect-MgGraph {
                [CmdletBinding()]
                param()
                throw 'Unmocked SDK call: Disconnect-MgGraph'
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
                throw 'Unmocked SDK call: Invoke-MgGraphRequest'
            }
        }

        if (-not (Get-Command -Name 'Get-ConnectionInformation' -ErrorAction SilentlyContinue)) {
            function script:Get-ConnectionInformation {
                [CmdletBinding()]
                param()
                throw 'Unmocked SDK call: Get-ConnectionInformation'
            }
        }

        if (-not (Get-Command -Name 'Connect-ExchangeOnline' -ErrorAction SilentlyContinue)) {
            function script:Connect-ExchangeOnline {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Signature-only stub; the parameters exist to be bound, not read.')]
                param([string]$DelegatedOrganization, [switch]$ShowBanner)
                throw 'Unmocked SDK call: Connect-ExchangeOnline'
            }
        }

        if (-not (Get-Command -Name 'Get-CsTenant' -ErrorAction SilentlyContinue)) {
            function script:Get-CsTenant {
                [CmdletBinding()]
                param()
                throw 'Unmocked SDK call: Get-CsTenant'
            }
        }

        if (-not (Get-Command -Name 'Connect-MicrosoftTeams' -ErrorAction SilentlyContinue)) {
            function script:Connect-MicrosoftTeams {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Signature-only stub; the parameters exist to be bound, not read.')]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
                    Justification = 'The stub must carry the SDK cmdlet''s exact name for Mock to replace it.')]
                param([string]$TenantId)
                throw 'Unmocked SDK call: Connect-MicrosoftTeams'
            }
        }

        if (-not (Get-Command -Name 'Disconnect-MicrosoftTeams' -ErrorAction SilentlyContinue)) {
            function script:Disconnect-MicrosoftTeams {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
                    Justification = 'The stub must carry the SDK cmdlet''s exact name for Mock to replace it.')]
                param()
                throw 'Unmocked SDK call: Disconnect-MicrosoftTeams'
            }
        }

        if (-not (Get-Command -Name 'Disconnect-ExchangeOnline' -ErrorAction SilentlyContinue)) {
            # SupportsShouldProcess so the module's own '-Confirm:$false' still binds against the stub.
            function script:Disconnect-ExchangeOnline {
                [CmdletBinding(SupportsShouldProcess)]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
                    Justification = 'The attribute is here only so -Confirm binds; the stub never mutates.')]
                param()
                throw 'Unmocked SDK call: Disconnect-ExchangeOnline'
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
                    $tenant = if ($script:contextCalls -eq 1) {
                        'b0000000-0000-0000-0000-000000000002'
                    }
                    else { 'a0000000-0000-0000-0000-000000000001' }
                    return [pscustomobject]@{ Scopes = @('User.Read.All'); TenantId = $tenant; Account = 'a@contoso.com' }
                }

                $null = Connect-MigrationGraph -Scopes 'User.Read.All' -TenantId 'a0000000-0000-0000-0000-000000000001'
                Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
            }
        }

        It 'Reuses a cached session whose GUID matches a domain-form -TenantId' {
            InModuleScope M365Migration {
                # The README's own examples pass a domain. Comparing that domain to the
                # context's GUID judges a correct session "wrong tenant" and re-signs in on
                # every script of the run, so the domain is resolved before it is compared.
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Resolve-MigrationTenantId { 'a0000000-0000-0000-0000-000000000001' }
                Mock Get-MgContext { [pscustomobject]@{
                    Scopes   = @('User.Read.All')
                    TenantId = 'a0000000-0000-0000-0000-000000000001'; Account = 'a@contoso.com' } }

                $context = Connect-MigrationGraph -Scopes 'User.Read.All' -TenantId 'newco.onmicrosoft.com'
                $context.TenantId | Should -BeExactly 'a0000000-0000-0000-0000-000000000001'
                Should -Invoke Connect-MgGraph -Times 0 -Exactly
                Should -Invoke Disconnect-MgGraph -Times 0 -Exactly
            }
        }

        It 'Passes the resolved GUID to Connect-MgGraph rather than the domain it was given' {
            InModuleScope M365Migration {
                Mock Initialize-MigrationModule { }
                Mock Disconnect-MgGraph { }
                Mock Invoke-MgGraphRequest { throw 'Invoke-MgGraphRequest should not be reachable without a mock' }
                Mock Resolve-MigrationTenantId { 'a0000000-0000-0000-0000-000000000001' }
                Mock Connect-MgGraph { }
                $script:contextCalls = 0
                Mock Get-MgContext {
                    $script:contextCalls++
                    if ($script:contextCalls -eq 1) { return $null }
                    return [pscustomobject]@{
                        Scopes   = @('User.Read.All')
                        TenantId = 'a0000000-0000-0000-0000-000000000001'; Account = 'a@contoso.com' }
                }

                $null = Connect-MigrationGraph -Scopes 'User.Read.All' -TenantId 'newco.onmicrosoft.com'
                Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
                    $TenantId -eq 'a0000000-0000-0000-0000-000000000001'
                }
            }
        }

        It 'Throws and disconnects when a fresh sign-in lands in the wrong tenant' {
            InModuleScope M365Migration {
                # The account chooser can put a fresh sign-in in any tenant the technician
                # has an account in, so the session is checked again after connecting.
                Mock Initialize-MigrationModule { }
                Mock Connect-MgGraph { }
                Mock Disconnect-MgGraph { }
                Mock Invoke-MgGraphRequest { throw 'Invoke-MgGraphRequest should not be reachable without a mock' }
                $script:contextCalls = 0
                Mock Get-MgContext {
                    $script:contextCalls++
                    if ($script:contextCalls -eq 1) { return $null }
                    return [pscustomobject]@{
                        Scopes   = @('User.Read.All')
                        TenantId = 'b0000000-0000-0000-0000-000000000002'; Account = 'admin@wrong.com' }
                }

                { Connect-MigrationGraph -Scopes 'User.Read.All' -TenantId 'a0000000-0000-0000-0000-000000000001' } |
                    Should -Throw '*connected to tenant b0000000*'
                Should -Invoke Disconnect-MgGraph -Times 1
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

    It 'names the tenant GUID on the success line so the workbench can verify it' {
        # Invoke-MigrationStep scrapes the tenant out of the child's log to answer "which
        # tenant did this step actually write to". The organisation alone cannot answer it,
        # so the wording of this line is part of the contract, not cosmetics.
        InModuleScope M365Migration {
            $script:logged = [System.Collections.Generic.List[string]]::new()
            Mock Initialize-MigrationModule { }
            Mock Write-MigrationLog { $script:logged.Add($Message) }
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            $script:calls = 0
            Mock Get-ConnectionInformation {
                $script:calls++
                if ($script:calls -le 1) { @() }
                else {
                    [pscustomobject]@{
                        State = 'Connected'; Organization = 'contoso.onmicrosoft.com'; DelegatedOrganization = ''
                        TenantId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'a@contoso.com'
                    }
                }
            }

            $null = Connect-MigrationExchange
            @($script:logged) -join "`n" | Should -Match ([regex]::Escape(
                    'Connected to Exchange Online - organisation contoso.onmicrosoft.com ' +
                    '(tenant 11111111-1111-1111-1111-111111111111) as a@contoso.com.'))
        }
    }

    It 'names the tenant GUID when it reuses a cached session too' {
        InModuleScope M365Migration {
            $script:logged = [System.Collections.Generic.List[string]]::new()
            Mock Initialize-MigrationModule { }
            Mock Write-MigrationLog { $script:logged.Add($Message) }
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            Mock Get-ConnectionInformation { [pscustomobject]@{
                    State = 'Connected'; Organization = ''; DelegatedOrganization = 'contoso.onmicrosoft.com'
                    TenantId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'a@contoso.com'
                } }

            $null = Connect-MigrationExchange -DelegatedOrganization 'contoso.onmicrosoft.com'
            @($script:logged) -join "`n" | Should -Match (
                'Reusing the cached Exchange Online session for tenant 11111111-1111-1111-1111-111111111111 ' +
                'as a@contoso\.com\.')
        }
    }

    It 'leaves the tenant out of the success line when the session reports none' {
        InModuleScope M365Migration {
            $script:logged = [System.Collections.Generic.List[string]]::new()
            Mock Initialize-MigrationModule { }
            Mock Write-MigrationLog { $script:logged.Add($Message) }
            Mock Connect-ExchangeOnline { }
            Mock Disconnect-ExchangeOnline { }
            $script:calls = 0
            Mock Get-ConnectionInformation {
                $script:calls++
                if ($script:calls -le 1) { @() }
                else {
                    [pscustomobject]@{
                        State = 'Connected'; Organization = 'contoso.onmicrosoft.com'; DelegatedOrganization = ''
                        TenantId = ''; UserPrincipalName = 'a@contoso.com'
                    }
                }
            }

            $null = Connect-MigrationExchange
            @($script:logged) -join "`n" | Should -Match ([regex]::Escape(
                    'Connected to Exchange Online - organisation contoso.onmicrosoft.com as a@contoso.com.'))
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

Describe 'Connect-MigrationTeams' {

    It 'Reuses a cached session whose GUID matches a domain-form -TenantId' {
        InModuleScope M365Migration {
            # Same trap as the Graph connector: Get-CsTenant reports a GUID, the README's
            # examples pass a domain, and comparing the two directly throws away a perfectly
            # good session and re-signs in - the slowest sign-in of the three.
            Mock Initialize-MigrationModule { }
            Mock Connect-MicrosoftTeams { }
            Mock Disconnect-MicrosoftTeams { }
            Mock Resolve-MigrationTenantId { 'a0000000-0000-0000-0000-000000000001' }
            Mock Get-CsTenant { [pscustomobject]@{
                TenantId = 'a0000000-0000-0000-0000-000000000001'; DisplayName = 'Contoso' } }

            $tenant = Connect-MigrationTeams -TenantId 'newco.onmicrosoft.com'
            $tenant.TenantId | Should -BeExactly 'a0000000-0000-0000-0000-000000000001'
            Should -Invoke Connect-MicrosoftTeams -Times 0 -Exactly
            Should -Invoke Disconnect-MicrosoftTeams -Times 0 -Exactly
        }
    }

    It 'Passes the resolved GUID to Connect-MicrosoftTeams rather than the domain it was given' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Disconnect-MicrosoftTeams { }
            Mock Resolve-MigrationTenantId { 'a0000000-0000-0000-0000-000000000001' }
            Mock Connect-MicrosoftTeams { }
            $script:tenantCalls = 0
            Mock Get-CsTenant {
                $script:tenantCalls++
                if ($script:tenantCalls -eq 1) { throw 'no session' }
                [pscustomobject]@{ TenantId = 'a0000000-0000-0000-0000-000000000001'; DisplayName = 'Contoso' }
            }

            $null = Connect-MigrationTeams -TenantId 'newco.onmicrosoft.com'
            Should -Invoke Connect-MicrosoftTeams -Times 1 -Exactly -ParameterFilter {
                $TenantId -eq 'a0000000-0000-0000-0000-000000000001'
            }
        }
    }

    It 'Throws and disconnects when a fresh sign-in lands in the wrong tenant' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Connect-MicrosoftTeams { }
            Mock Disconnect-MicrosoftTeams { }
            $script:tenantCalls = 0
            Mock Get-CsTenant {
                $script:tenantCalls++
                if ($script:tenantCalls -eq 1) { throw 'no session' }
                [pscustomobject]@{ TenantId = 'b0000000-0000-0000-0000-000000000002'; DisplayName = 'Fabrikam' }
            }

            { Connect-MigrationTeams -TenantId 'a0000000-0000-0000-0000-000000000001' } |
                Should -Throw '*connected to tenant b0000000*'
            Should -Invoke Disconnect-MicrosoftTeams -Times 1
        }
    }

    It 'Drops a cached session that targets a different tenant' {
        InModuleScope M365Migration {
            Mock Initialize-MigrationModule { }
            Mock Connect-MicrosoftTeams { }
            Mock Disconnect-MicrosoftTeams { }
            $script:tenantCalls = 0
            Mock Get-CsTenant {
                $script:tenantCalls++
                $id = if ($script:tenantCalls -eq 1) {
                    'b0000000-0000-0000-0000-000000000002'
                }
                else { 'a0000000-0000-0000-0000-000000000001' }
                [pscustomobject]@{ TenantId = $id; DisplayName = 'Contoso' }
            }

            $null = Connect-MigrationTeams -TenantId 'a0000000-0000-0000-0000-000000000001'
            Should -Invoke Disconnect-MicrosoftTeams -Times 1 -Exactly
            Should -Invoke Connect-MicrosoftTeams -Times 1 -Exactly
        }
    }
}
