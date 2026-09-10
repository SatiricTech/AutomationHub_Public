#Requires -Version 7.4

<#
    Offline tests for Remove-MigrationDomainReferences.ps1.

    How a .ps1 gets unit tested without running it (the approach, for Pester 6):

    Dot-sourcing the script would execute its Main region, which connects to Graph and Exchange
    Online. Instead the file is parsed with the PowerShell AST and only its FunctionDefinitionAst
    nodes are dot-sourced into the Pester script scope. The functions under test are therefore the
    real ones from the shipping file - not copies - while none of the script body runs.

    Because the functions land in Pester's own session state (rather than inside a module), plain
    'Mock <name>' reaches them; no InModuleScope is needed. Exchange Online cmdlets do not exist on
    the test host, so empty stubs are declared first purely to give Mock something to replace - Pester
    refuses to mock a command it cannot resolve.

    The DryRun assertions deliberately use the real Invoke-MigrationAction from the module with a run
    context created by Initialize-MigrationRun -DryRun. Mocking the wrapper would only prove that the
    mock does nothing; using the real one proves the shipping dry-run gate stops the mutation.

    Two Pester 6 details worth knowing before editing these tests:
      - a mock body runs in its own scope, so a call log shared with the It block has to be a global;
        $script: does not reach it.
      - a mock body cannot use $PSBoundParameters to tell which parameters were supplied. It sees the
        declared parameters as variables, so the stubs above leave them untyped: an unbound [bool]
        would arrive as $false and be indistinguishable from an explicit -EmailAddressPolicyEnabled
        $false, which is exactly the call the ordering test has to recognise.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'The Set-* functions here are empty stubs that exist only so Pester has a command to mock; they change nothing.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stub parameters are never read by the stub itself - they exist so the mocked calls bind, and the mock bodies read them.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'A Pester 6 mock body runs in its own scope; a global is the only variable both it and the It block can reach. It is removed inside the test.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:scriptPath = Join-Path $PSScriptRoot '..' 'Remove-MigrationDomainReferences.ps1'
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:scriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        throw "Remove-MigrationDomainReferences.ps1 does not parse: $(@($parseErrors)[0].Message)"
    }

    $definitions = $scriptAst.FindAll(
        { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($definition in $definitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    # Stubs so Mock has a command to replace. They must accept every parameter the script binds.
    function Set-Mailbox {
        [CmdletBinding()]
        param([string]$Identity, $EmailAddresses, $PrimarySmtpAddress, $EmailAddressPolicyEnabled)
    }
    function Set-MailUser {
        [CmdletBinding()]
        param([string]$Identity, $EmailAddresses, $PrimarySmtpAddress, $EmailAddressPolicyEnabled)
    }
    function Set-MailContact {
        [CmdletBinding()]
        param([string]$Identity, $EmailAddresses, $PrimarySmtpAddress)
    }
    function Set-DistributionGroup {
        [CmdletBinding()]
        param([string]$Identity, $EmailAddresses, $PrimarySmtpAddress, $EmailAddressPolicyEnabled)
    }
    function Set-DynamicDistributionGroup {
        [CmdletBinding()]
        param([string]$Identity, $EmailAddresses, $PrimarySmtpAddress, $EmailAddressPolicyEnabled)
    }
    function Set-UnifiedGroup {
        [CmdletBinding()]
        param([string]$Identity, $EmailAddresses, $PrimarySmtpAddress)
    }

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-DomainRefs-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null

    $script:domain = 'contoso.com'
    $script:fallback = 'newco.onmicrosoft.com'
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Remove-MigrationDomainReferences' {

    Context 'Fallback UPN computation' {

        It 'Keeps the local part and moves the domain' {
            ConvertTo-FallbackUpn -UserPrincipalName 'sam.smith@contoso.com' -FallbackDomain $script:fallback |
                Should -BeExactly 'sam.smith@newco.onmicrosoft.com'
        }

        It 'Lowercases the result so comparisons are stable' {
            ConvertTo-FallbackUpn -UserPrincipalName 'Sam.Smith@Contoso.com' -FallbackDomain $script:fallback |
                Should -BeExactly 'sam.smith@newco.onmicrosoft.com'
        }

        It 'Refuses to rewrite a guest #EXT# UPN' {
            ConvertTo-FallbackUpn -UserPrincipalName 'sam_contoso.com#EXT#@newco.onmicrosoft.com' `
                -FallbackDomain $script:fallback | Should -BeExactly ''
        }

        It 'Returns nothing for a value that is not an address' {
            ConvertTo-FallbackUpn -UserPrincipalName 'sam.smith' -FallbackDomain $script:fallback |
                Should -BeExactly ''
        }
    }

    Context 'Address entry parsing' {

        It 'Marks an uppercase SMTP entry as the primary' {
            $parsed = Split-AddressEntry -Entry 'SMTP:sam@contoso.com'
            $parsed.IsPrimary | Should -BeTrue
            $parsed.Type | Should -BeExactly 'smtp'
            $parsed.Domain | Should -BeExactly 'contoso.com'
        }

        It 'Treats a lowercase smtp entry as an alias' {
            (Split-AddressEntry -Entry 'smtp:sam@contoso.com').IsPrimary | Should -BeFalse
        }

        It 'Keeps a non-SMTP prefix as its own type' {
            (Split-AddressEntry -Entry 'sip:sam@contoso.com').Type | Should -BeExactly 'sip'
        }

        It 'Handles a bare address with no prefix' {
            $parsed = Split-AddressEntry -Entry 'sam@contoso.com'
            $parsed.Prefix | Should -BeExactly ''
            $parsed.Domain | Should -BeExactly 'contoso.com'
        }

        It 'Reports no domain for an X500 address' {
            (Split-AddressEntry -Entry 'X500:/o=ExchangeLabs/ou=Exchange/cn=Recipients/cn=abc').Domain |
                Should -BeExactly ''
        }
    }

    Context 'Recipient cmdlet mapping' {

        It 'Maps <Type> to <Expected>' -ForEach @(
            @{ Type = 'UserMailbox'; Expected = 'Set-Mailbox'; Toggle = $true }
            @{ Type = 'SharedMailbox'; Expected = 'Set-Mailbox'; Toggle = $true }
            @{ Type = 'RoomMailbox'; Expected = 'Set-Mailbox'; Toggle = $true }
            @{ Type = 'MailUser'; Expected = 'Set-MailUser'; Toggle = $true }
            @{ Type = 'MailContact'; Expected = 'Set-MailContact'; Toggle = $false }
            @{ Type = 'MailUniversalDistributionGroup'; Expected = 'Set-DistributionGroup'; Toggle = $true }
            @{ Type = 'DynamicDistributionGroup'; Expected = 'Set-DynamicDistributionGroup'; Toggle = $true }
            @{ Type = 'GroupMailbox'; Expected = 'Set-UnifiedGroup'; Toggle = $false }
        ) {
            $resolved = Resolve-RecipientCmdlet -RecipientTypeDetails $Type
            $resolved.SetCmdlet | Should -BeExactly $Expected
            $resolved.SupportsPolicyToggle | Should -Be $Toggle
            $resolved.IsSupported | Should -BeTrue
        }

        It 'Reports an unknown recipient type as unsupported' {
            (Resolve-RecipientCmdlet -RecipientTypeDetails 'PublicFolder').IsSupported | Should -BeFalse
        }

        It 'Reports GuestMailUser as unsupported so a guest is never remediated' {
            (Resolve-RecipientCmdlet -RecipientTypeDetails 'GuestMailUser').IsSupported | Should -BeFalse
        }
    }

    Context 'Address plan computation' {

        It 'Promotes the fallback domain address and removes every vanity address' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sam@contoso.com'
                RecipientTypeDetails = 'UserMailbox'
                PrimarySmtpAddress   = 'sam@contoso.com'
                Addresses            = @(
                    'SMTP:sam@contoso.com'
                    'smtp:sam.smith@contoso.com'
                    'smtp:sam@newco.onmicrosoft.com'
                    'smtp:sam@newco.mail.onmicrosoft.com'
                    'X500:/o=ExchangeLabs/ou=Exchange/cn=Recipients/cn=abc'
                )
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback

            $plan.IsComplete | Should -BeTrue
            $plan.PrimaryIsVanity | Should -BeTrue
            $plan.PromoteAddress | Should -BeExactly 'sam@newco.onmicrosoft.com'
            $plan.RemoveAddresses | Should -HaveCount 2
            $plan.RemoveAddresses | Should -Contain 'sam@contoso.com'
            $plan.RemoveAddresses | Should -Contain 'sam.smith@contoso.com'
        }

        It 'Prefers the initial onmicrosoft address over the mail.onmicrosoft routing address' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'team@contoso.com'
                RecipientTypeDetails = 'UserMailbox'
                PrimarySmtpAddress   = 'team@contoso.com'
                Addresses            = @(
                    'SMTP:team@contoso.com'
                    'smtp:team@fabrikam.mail.onmicrosoft.com'
                    'smtp:team@fabrikam.onmicrosoft.com'
                )
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.PromoteAddress | Should -BeExactly 'team@fabrikam.onmicrosoft.com'
        }

        It 'Removes SMTP addresses bare and keeps the prefix on other address types' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sam@newco.onmicrosoft.com'
                RecipientTypeDetails = 'UserMailbox'
                PrimarySmtpAddress   = 'sam@newco.onmicrosoft.com'
                Addresses            = @(
                    'SMTP:sam@newco.onmicrosoft.com'
                    'smtp:sam@contoso.com'
                    'sip:sam@contoso.com'
                )
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.RemoveAddresses | Should -Contain 'sam@contoso.com'
            $plan.RemoveAddresses | Should -Contain 'sip:sam@contoso.com'
        }

        It 'Skips the promotion when the vanity address is only an alias' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sam@newco.onmicrosoft.com'
                RecipientTypeDetails = 'UserMailbox'
                PrimarySmtpAddress   = 'sam@newco.onmicrosoft.com'
                Addresses            = @('SMTP:sam@newco.onmicrosoft.com', 'smtp:sam@contoso.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.PrimaryIsVanity | Should -BeFalse
            $plan.PromoteAddress | Should -BeExactly ''
            $plan.Steps | Should -Be @('RemoveAddresses')
        }

        It 'Reports an incomplete plan when there is nothing to promote' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sales@contoso.com'
                RecipientTypeDetails = 'MailUniversalDistributionGroup'
                PrimarySmtpAddress   = 'sales@contoso.com'
                Addresses            = @('SMTP:sales@contoso.com', 'smtp:sales.team@contoso.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.IsComplete | Should -BeFalse
            $plan.Reason | Should -Match 'no other address to promote'
        }

        It 'Refuses to repoint a contact whose external address is on the domain' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'partner@newco.onmicrosoft.com'
                RecipientTypeDetails = 'MailContact'
                PrimarySmtpAddress   = 'partner@contoso.com'
                ExternalEmailAddress = 'SMTP:partner@contoso.com'
                Addresses            = @('SMTP:partner@contoso.com', 'smtp:partner@newco.onmicrosoft.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.IsComplete | Should -BeFalse
            $plan.Reason | Should -Match 'external address'
        }

        It 'Returns an empty plan when the recipient has no address on the domain' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sam@newco.onmicrosoft.com'
                RecipientTypeDetails = 'UserMailbox'
                PrimarySmtpAddress   = 'sam@newco.onmicrosoft.com'
                Addresses            = @('SMTP:sam@newco.onmicrosoft.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.IsComplete | Should -BeTrue
            $plan.Steps | Should -HaveCount 0
        }

        It 'Reports an unsupported recipient type as incomplete' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'archive@contoso.com'
                RecipientTypeDetails = 'PublicFolderMailbox'
                PrimarySmtpAddress   = 'archive@contoso.com'
                Addresses            = @('SMTP:archive@contoso.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.IsComplete | Should -BeFalse
            $plan.Reason | Should -Match 'No Exchange Online cmdlet'
        }

        It 'Reports a guest recipient as incomplete with a guest-specific reason, never Set-MailUser' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sam_fabrikam.com#EXT#@newco.onmicrosoft.com'
                RecipientTypeDetails = 'GuestMailUser'
                PrimarySmtpAddress   = 'sam@contoso.com'
                Addresses            = @('SMTP:sam@contoso.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.IsComplete | Should -BeFalse
            $plan.Reason | Should -Match 'Guest recipients are not remediated'
        }
    }

    Context 'Primary promotion ordering' {

        BeforeAll {
            $script:groupRecord = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                      = 'RecipientAddress'
                Identity                  = 'sales@contoso.com'
                ObjectId                  = '11111111-1111-1111-1111-111111111111'
                RecipientTypeDetails      = 'MailUniversalDistributionGroup'
                PrimarySmtpAddress        = 'sales@contoso.com'
                EmailAddressPolicyEnabled = $true
                Addresses                 = @(
                    'SMTP:sales@contoso.com'
                    'smtp:sales@newco.onmicrosoft.com'
                )
            }
        }

        It 'Disables the email address policy, then promotes, then removes' {
            $plan = Resolve-DomainAddressPlan -Reference $script:groupRecord -Domain $script:domain `
                -FallbackDomain $script:fallback
            $plan.Steps | Should -Be @('DisableEmailAddressPolicy', 'PromotePrimary', 'RemoveAddresses')
            $plan.RequiresPolicyDisable | Should -BeTrue
        }

        It 'Omits the policy step when the recipient type has no such toggle' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'project@contoso.com'
                RecipientTypeDetails = 'GroupMailbox'
                PrimarySmtpAddress   = 'project@contoso.com'
                Addresses            = @('SMTP:project@contoso.com', 'smtp:project@newco.onmicrosoft.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.Steps | Should -Be @('PromotePrimary', 'RemoveAddresses')
        }

        It 'Omits the policy step when the policy is already disabled' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                      = 'RecipientAddress'
                Identity                  = 'sales@contoso.com'
                RecipientTypeDetails      = 'MailUniversalDistributionGroup'
                PrimarySmtpAddress        = 'sales@contoso.com'
                EmailAddressPolicyEnabled = $false
                Addresses                 = @('SMTP:sales@contoso.com', 'smtp:sales@newco.onmicrosoft.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $plan.Steps | Should -Be @('PromotePrimary', 'RemoveAddresses')
        }

        It 'Calls Set-DistributionGroup in that order during a real run' {
            $null = Initialize-MigrationRun -ScriptName 'DomainRefs-Real' -OutputPath $script:workspace -Verbosity Low

            # Pester runs a mock body in its own scope, so the call log has to live somewhere both
            # scopes can reach. A global holding a mutable list is the least surprising option; it is
            # removed again at the end of the test.
            $global:domainRefCallLog = [System.Collections.Generic.List[string]]::new()
            Mock Set-DistributionGroup {
                if ($null -ne $EmailAddressPolicyEnabled) { $global:domainRefCallLog.Add('policy') }
                elseif ($null -ne $PrimarySmtpAddress) { $global:domainRefCallLog.Add('promote') }
                elseif ($null -ne $EmailAddresses) { $global:domainRefCallLog.Add('remove') }
                else { $global:domainRefCallLog.Add('unrecognised') }
            }

            $plan = Resolve-DomainAddressPlan -Reference $script:groupRecord -Domain $script:domain `
                -FallbackDomain $script:fallback
            $classification = Resolve-DomainReferenceClass -Reference $script:groupRecord -Domain $script:domain `
                -FallbackDomain $script:fallback -AddressPlan $plan

            $row = Repair-DomainReference -Reference $script:groupRecord -Classification $classification `
                -AddressPlan $plan -Confirm:$false

            $row.Status | Should -BeExactly 'Succeeded'
            $order = @($global:domainRefCallLog)
            Remove-Variable -Name domainRefCallLog -Scope Global -ErrorAction SilentlyContinue
            $order | Should -Be @('policy', 'promote', 'remove')
            Should -Invoke Set-DistributionGroup -Times 3 -Exactly
        }

        It 'Treats an EXO refusal of the policy toggle as best-effort and still promotes and removes' {
            $null = Initialize-MigrationRun -ScriptName 'DomainRefs-Real' -OutputPath $script:workspace -Verbosity Low

            $global:domainRefCallLog = [System.Collections.Generic.List[string]]::new()
            Mock Set-DistributionGroup {
                if ($null -ne $EmailAddressPolicyEnabled) {
                    throw 'This parameter is available only in on-premises Exchange.'
                }
                elseif ($null -ne $PrimarySmtpAddress) { $global:domainRefCallLog.Add('promote') }
                elseif ($null -ne $EmailAddresses) { $global:domainRefCallLog.Add('remove') }
            }

            $plan = Resolve-DomainAddressPlan -Reference $script:groupRecord -Domain $script:domain `
                -FallbackDomain $script:fallback
            $classification = Resolve-DomainReferenceClass -Reference $script:groupRecord -Domain $script:domain `
                -FallbackDomain $script:fallback -AddressPlan $plan

            $row = Repair-DomainReference -Reference $script:groupRecord -Classification $classification `
                -AddressPlan $plan -Confirm:$false

            $row.Status | Should -BeExactly 'Succeeded'
            $row.Detail | Should -Match 'policy toggle was refused'
            $order = @($global:domainRefCallLog)
            Remove-Variable -Name domainRefCallLog -Scope Global -ErrorAction SilentlyContinue
            $order | Should -Be @('promote', 'remove')
        }
    }

    Context 'Reference classification' {

        It 'Treats a cloud user whose UPN is on the domain as fixable' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = 'sam@contoso.com'
                UserPrincipalName = 'sam@contoso.com'
                ObjectType        = 'User'
                ReferenceKinds    = @('Upn')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Fixable'
            $class.Action | Should -BeExactly 'SetUpn'
            $class.NewUserPrincipalName | Should -BeExactly 'sam@newco.onmicrosoft.com'
        }

        It 'Blocks a directory-synced user' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = 'sam@contoso.com'
                UserPrincipalName = 'sam@contoso.com'
                ObjectType        = 'User'
                IsSynced          = $true
                ReferenceKinds    = @('Upn')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'DirectorySynced'
            $class.Action | Should -BeExactly 'None'
        }

        It 'Blocks a recipient whose sync state could not be read rather than assuming it is not synced' {
            # This is the shape Get-DomainReferenceSet produces when the extended-property scan
            # failed and the default property set came back without IsDirSynced.
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sales@contoso.com'
                ObjectId             = '66666666-6666-6666-6666-666666666666'
                RecipientTypeDetails = 'MailUniversalDistributionGroup'
                PrimarySmtpAddress   = 'sales@contoso.com'
                Addresses            = @('SMTP:sales@contoso.com', 'smtp:sales@newco.onmicrosoft.com')
                IsSynced             = $false
                SyncStateKnown       = $false
                ReferenceKinds       = @('Address')
            }
            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback -AddressPlan $plan

            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'SyncStateUnknown'
            $class.Detail | Should -BeExactly 'Sync state unknown (property set unavailable); verify manually'
            $class.Action | Should -BeExactly 'None'
        }

        It 'Still classifies a recipient as fixable when the sync state is known' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sales@contoso.com'
                ObjectId             = '66666666-6666-6666-6666-666666666666'
                RecipientTypeDetails = 'MailUniversalDistributionGroup'
                PrimarySmtpAddress   = 'sales@contoso.com'
                Addresses            = @('SMTP:sales@contoso.com', 'smtp:sales@newco.onmicrosoft.com')
                ReferenceKinds       = @('Address')
            }
            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback -AddressPlan $plan

            $class.Class | Should -BeExactly 'Fixable'
        }

        It 'Blocks a soft-deleted user still holding the domain' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'DeletedUser'
                Identity          = 'old@contoso.com'
                UserPrincipalName = 'old@contoso.com'
                ObjectType        = 'DeletedUser'
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'SoftDeletedUser'
        }

        It 'Reports a guest whose #EXT# UPN merely embeds the domain as informational' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'GuestReference'
                Identity          = 'sam_contoso.com#EXT#@newco.onmicrosoft.com'
                UserPrincipalName = 'sam_contoso.com#EXT#@newco.onmicrosoft.com'
                ObjectType        = 'Guest'
                IsGuest           = $true
                ReferenceKinds    = @('GuestUpnEmbed')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Informational'
            $class.Reason | Should -BeExactly 'GuestExternalUpn'
            $class.Action | Should -BeExactly 'None'
        }

        It 'Blocks a guest that actually carries an address on the domain' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'GuestReference'
                Identity          = 'sam_fabrikam.com#EXT#@newco.onmicrosoft.com'
                UserPrincipalName = 'sam_fabrikam.com#EXT#@newco.onmicrosoft.com'
                ObjectType        = 'Guest'
                IsGuest           = $true
                Addresses         = @('smtp:sam@contoso.com')
                ReferenceKinds    = @('Address')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'GuestDomainAddress'
        }

        It 'Blocks a guest whose userPrincipalName is really on the domain, not just #EXT#-embedded' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'GuestReference'
                Identity          = 'sam@contoso.com'
                UserPrincipalName = 'sam@contoso.com'
                ObjectType        = 'Guest'
                IsGuest           = $true
                ReferenceKinds    = @('Upn')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'GuestUpnOnDomain'
        }

        It 'Blocks an object the run was scoped away from, rather than silently ignoring it' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sales@contoso.com'
                RecipientTypeDetails = 'MailUniversalDistributionGroup'
                PrimarySmtpAddress   = 'sales@contoso.com'
                Addresses            = @('SMTP:sales@contoso.com', 'smtp:sales@newco.onmicrosoft.com')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback -Scope @('Users')
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'OutOfScope'
            $class.Detail | Should -Match 'Groups'
        }

        It 'Blocks a user holding the domain in proxyAddresses with no Exchange recipient' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserProxy'
                Identity          = 'sam@newco.onmicrosoft.com'
                UserPrincipalName = 'sam@newco.onmicrosoft.com'
                ObjectType        = 'User'
                Addresses         = @('smtp:sam@contoso.com')
                ReferenceKinds    = @('Address')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'ProxyAddressWithoutRecipient'
        }

        It 'Blocks anything Graph reports that the enumeration could not explain' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind       = 'UnresolvedReference'
                Identity   = '22222222-2222-2222-2222-222222222222'
                ObjectType = '#microsoft.graph.application'
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'UnresolvedReference'
        }

        It 'Marks a recipient with a workable plan as fixable' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sam@contoso.com'
                RecipientTypeDetails = 'SharedMailbox'
                PrimarySmtpAddress   = 'sam@contoso.com'
                Addresses            = @('SMTP:sam@contoso.com', 'smtp:sam@newco.onmicrosoft.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback -AddressPlan $plan
            $class.Class | Should -BeExactly 'Fixable'
            $class.Action | Should -BeExactly 'UpdateAddresses'
        }

        It 'Turns an incomplete address plan into a blocker' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                 = 'RecipientAddress'
                Identity             = 'sales@contoso.com'
                RecipientTypeDetails = 'MailUniversalDistributionGroup'
                PrimarySmtpAddress   = 'sales@contoso.com'
                Addresses            = @('SMTP:sales@contoso.com')
            }

            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback -AddressPlan $plan
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'AddressPlanIncomplete'
        }

        It 'Reports a user already on the fallback domain as informational' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = 'sam@newco.onmicrosoft.com'
                UserPrincipalName = 'sam@newco.onmicrosoft.com'
                ObjectType        = 'User'
                ReferenceKinds    = @('Upn')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Informational'
            $class.Reason | Should -BeExactly 'AlreadyOffDomain'
        }

        It 'Blocks a UPN that cannot be rewritten into a valid address' {
            $longLocal = 'a' * 70
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = "$longLocal@contoso.com"
                UserPrincipalName = "$longLocal@contoso.com"
                ObjectType        = 'User'
                ReferenceKinds    = @('Upn')
            }

            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback
            $class.Class | Should -BeExactly 'Blocker'
            $class.Reason | Should -BeExactly 'InvalidTargetUpn'
        }
    }

    Context 'DryRun and ReportOnly produce Planned rows and change nothing' {

        BeforeEach {
            # -ReportOnly, -DryRun and a missing -AcknowledgeSourceTenant all reach Invoke-MigrationAction
            # as one flag on the run context, so exercising the dry run covers all three paths.
            $null = Initialize-MigrationRun -ScriptName 'DomainRefs-DryRun' -OutputPath $script:workspace `
                -DryRun -Verbosity Low
            Mock Set-Mailbox { }
            Mock Set-DistributionGroup { }
            Mock Invoke-MigrationGraphRequest { }
        }

        It 'Plans a UPN change without calling Graph' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = 'sam@contoso.com'
                ObjectId          = '33333333-3333-3333-3333-333333333333'
                UserPrincipalName = 'sam@contoso.com'
                ObjectType        = 'User'
                ReferenceKinds    = @('Upn')
            }
            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback

            $row = Repair-DomainReference -Reference $record -Classification $class -AsPlanned -Confirm:$false

            $row.Status | Should -BeExactly 'Planned'
            $row.Action | Should -BeExactly 'SetUpn'
            $row.Target | Should -BeExactly 'sam@newco.onmicrosoft.com'
            Should -Invoke Invoke-MigrationGraphRequest -Times 0 -Exactly
        }

        It 'Plans an address change without calling Exchange Online' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind                      = 'RecipientAddress'
                Identity                  = 'sales@contoso.com'
                ObjectId                  = '44444444-4444-4444-4444-444444444444'
                RecipientTypeDetails      = 'MailUniversalDistributionGroup'
                PrimarySmtpAddress        = 'sales@contoso.com'
                EmailAddressPolicyEnabled = $true
                Addresses                 = @('SMTP:sales@contoso.com', 'smtp:sales@newco.onmicrosoft.com')
            }
            $plan = Resolve-DomainAddressPlan -Reference $record -Domain $script:domain -FallbackDomain $script:fallback
            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback -AddressPlan $plan

            $row = Repair-DomainReference -Reference $record -Classification $class -AddressPlan $plan `
                -AsPlanned -Confirm:$false

            $row.Status | Should -BeExactly 'Planned'
            $row.Steps | Should -BeExactly 'DisableEmailAddressPolicy;PromotePrimary;RemoveAddresses'
            Should -Invoke Set-DistributionGroup -Times 0 -Exactly
        }

        It 'Skips the row and changes nothing under -WhatIf' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = 'sam@contoso.com'
                ObjectId          = '55555555-5555-5555-5555-555555555555'
                UserPrincipalName = 'sam@contoso.com'
                ObjectType        = 'User'
                ReferenceKinds    = @('Upn')
            }
            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback

            $row = Repair-DomainReference -Reference $record -Classification $class -WhatIf

            $row.Status | Should -BeExactly 'Skipped'
            $row.Detail | Should -BeExactly 'Declined at the confirmation prompt.'
            Should -Invoke Invoke-MigrationGraphRequest -Times 0 -Exactly
        }

        It 'Does not report a declined row as Planned, which is reserved for -DryRun' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = 'sam@contoso.com'
                ObjectId          = '55555555-5555-5555-5555-555555555555'
                UserPrincipalName = 'sam@contoso.com'
                ObjectType        = 'User'
                ReferenceKinds    = @('Upn')
            }
            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback

            $row = Repair-DomainReference -Reference $record -Classification $class -WhatIf

            $row.Status | Should -Not -BeExactly 'Planned'
            $row.Status | Should -Not -BeExactly 'Succeeded'
        }
    }

    Context 'Real runs do mutate' {

        BeforeEach {
            $null = Initialize-MigrationRun -ScriptName 'DomainRefs-Apply' -OutputPath $script:workspace -Verbosity Low
            Mock Invoke-MigrationGraphRequest { }
        }

        It 'PATCHes the user when the run is not a dry run' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = 'sam@contoso.com'
                ObjectId          = '66666666-6666-6666-6666-666666666666'
                UserPrincipalName = 'sam@contoso.com'
                ObjectType        = 'User'
                ReferenceKinds    = @('Upn')
            }
            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback

            $row = Repair-DomainReference -Reference $record -Classification $class -Confirm:$false

            $row.Status | Should -BeExactly 'Succeeded'
            Should -Invoke Invoke-MigrationGraphRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'PATCH' -and
                $Uri -eq '/v1.0/users/66666666-6666-6666-6666-666666666666' -and
                $Body.userPrincipalName -eq 'sam@newco.onmicrosoft.com'
            }
        }

        It 'Records a failure with an actionable hint rather than throwing' {
            Mock Invoke-MigrationGraphRequest { throw 'Authorization_RequestDenied: Insufficient privileges' }
            $record = ConvertTo-DomainReferenceRecord -Properties @{
                Kind              = 'UserUpn'
                Identity          = 'admin@contoso.com'
                ObjectId          = '77777777-7777-7777-7777-777777777777'
                UserPrincipalName = 'admin@contoso.com'
                ObjectType        = 'User'
                ReferenceKinds    = @('Upn')
            }
            $class = Resolve-DomainReferenceClass -Reference $record -Domain $script:domain `
                -FallbackDomain $script:fallback

            $row = Repair-DomainReference -Reference $record -Classification $class -Confirm:$false

            $row.Status | Should -BeExactly 'Failed'
            $row.Detail | Should -Match 'Privileged Authentication Administrator'
        }
    }

    Context 'Error detail mapping' {

        It 'Explains an Exchange write-scope refusal as a directory sync problem' {
            Get-DomainReferenceErrorDetail -Message "The object isn't within your current write scope." `
                -Action 'UpdateAddresses' | Should -Match 'directory-synced'
        }

        It 'Explains a conflict as a possible soft-deleted holder' {
            Get-DomainReferenceErrorDetail -Message 'Another object with the same value already exists.' `
                -Action 'SetUpn' | Should -Match 'soft-deleted'
        }

        It 'Passes an unrecognised message through unchanged' {
            Get-DomainReferenceErrorDetail -Message 'Service unavailable' -Action 'SetUpn' |
                Should -BeExactly 'Service unavailable'
        }
    }

    Context 'Reference record factory' {

        It 'Fills every schema property with a default' {
            $record = ConvertTo-DomainReferenceRecord -Properties @{ Kind = 'UserUpn' }
            $record.Addresses | Should -HaveCount 0
            $record.IsSynced | Should -BeFalse
            $record.EmailAddressPolicyEnabled | Should -BeFalse
        }

        It 'Rejects a property name that is not part of the schema' {
            { ConvertTo-DomainReferenceRecord -Properties @{ Nonsense = 'x' } } | Should -Throw '*Unknown domain reference property*'
        }
    }

    Context 'Exchange Online session tenant pinning' {

        It 'Passes when the session tenant matches Graph and there is no delegation' {
            $exo = [pscustomobject]@{ TenantID = 'tenant-a'; DelegatedOrganization = '' }
            Get-DomainExchangeSessionMismatch -ExchangeContext $exo -GraphTenantId 'tenant-a' `
                -DelegatedOrganization '' | Should -BeExactly ''
        }

        It 'Flags a session whose tenant does not match Graph' {
            $exo = [pscustomobject]@{ TenantID = 'tenant-b'; DelegatedOrganization = '' }
            $result = Get-DomainExchangeSessionMismatch -ExchangeContext $exo -GraphTenantId 'tenant-a' `
                -DelegatedOrganization ''
            $result | Should -Match 'tenant-b'
        }

        It 'Flags a GDAP session delegated to the wrong customer' {
            $exo = [pscustomobject]@{ TenantID = 'tenant-a'; DelegatedOrganization = 'wrong.onmicrosoft.com' }
            $result = Get-DomainExchangeSessionMismatch -ExchangeContext $exo -GraphTenantId 'tenant-a' `
                -DelegatedOrganization 'contoso.onmicrosoft.com'
            $result | Should -Match 'wrong.onmicrosoft.com'
        }

        It 'Reports no session at all as a mismatch' {
            Get-DomainExchangeSessionMismatch -ExchangeContext $null -GraphTenantId 'tenant-a' `
                -DelegatedOrganization '' | Should -Match 'No Exchange Online session'
        }
    }

    Context 'Remaining references before and after remediation' {

        It 'Counts fixable references as remaining when nothing has succeeded yet' {
            $fixable = [pscustomobject]@{
                Reference      = [pscustomobject]@{ Kind = 'RecipientAddress'; ObjectId = 'obj-1'; Identity = 'sam@contoso.com' }
                Classification = [pscustomobject]@{ Class = 'Fixable' }
            }
            $blocker = [pscustomobject]@{
                Reference      = [pscustomobject]@{ Kind = 'RecipientAddress'; ObjectId = 'obj-2'; Identity = 'sales@contoso.com' }
                Classification = [pscustomobject]@{ Class = 'Blocker' }
            }

            $remaining = @(Get-DomainRemainingReferenceSet -Assessed @($fixable, $blocker) -Results @())
            $remaining | Should -HaveCount 2
        }

        It 'Drops a fixable reference once its result row reports Succeeded' {
            $fixable = [pscustomobject]@{
                Reference      = [pscustomobject]@{ Kind = 'RecipientAddress'; ObjectId = 'obj-1'; Identity = 'sam@contoso.com' }
                Classification = [pscustomobject]@{ Class = 'Fixable' }
            }
            $result = [pscustomobject]@{ ReferenceKind = 'RecipientAddress'; ObjectId = 'obj-1'; Status = 'Succeeded' }

            $remaining = @(Get-DomainRemainingReferenceSet -Assessed @($fixable) -Results @($result))
            $remaining | Should -HaveCount 0
        }

        It 'Never drops a Blocker even if a result row matches it' {
            $blocker = [pscustomobject]@{
                Reference      = [pscustomobject]@{ Kind = 'RecipientAddress'; ObjectId = 'obj-2'; Identity = 'sales@contoso.com' }
                Classification = [pscustomobject]@{ Class = 'Blocker' }
            }
            $result = [pscustomobject]@{ ReferenceKind = 'RecipientAddress'; ObjectId = 'obj-2'; Status = 'Succeeded' }

            $remaining = @(Get-DomainRemainingReferenceSet -Assessed @($blocker) -Results @($result))
            $remaining | Should -HaveCount 1
        }
    }
}
