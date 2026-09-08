#Requires -Version 7.4

<#
    Get-MigrationInventory is tenant-bound: every collector needs a live Graph or Exchange
    session, so there is nothing honest to assert about them offline. What can be tested - and
    what actually breaks the toolkit when it regresses - is the row shaping. The column names
    below are the contract New-MigrationIdentityPlan reads by name, so these tests exist mainly
    to fail loudly if a column is renamed or dropped.

    The functions under test are lifted out of the script with the PowerShell parser rather than
    by dot-sourcing it, because dot-sourcing would run the script and try to sign in.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $inventoryScript = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Get-MigrationInventory.ps1')).Path

    $offlineFunctions = @(
        'Get-InventoryValue'
        'ConvertTo-InventoryByteCount'
        'ConvertTo-InventoryGigabyte'
        'ConvertTo-InventoryDomainList'
        'Test-InventoryDomainMatch'
        'Select-InventoryAddress'
        'Add-InventoryRecipientIndexEntry'
        'Resolve-InventoryRecipient'
        'Join-InventoryRecipientList'
        'ConvertTo-InventoryMailboxRow'
        'ConvertTo-InventoryUserRow'
        'ConvertTo-InventoryContactRow'
        'ConvertTo-InventoryPermissionRow'
        'Get-InventoryGroupType'
        'Test-InventoryTrustee'
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($inventoryScript, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) { throw "Get-MigrationInventory.ps1 does not parse: $($parseErrors[0].Message)" }

    $predicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    foreach ($definition in $ast.FindAll($predicate, $true)) {
        if ($offlineFunctions -contains $definition.Name) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }

    $script:RecipientIndex = @{}
}

Describe 'Get-InventoryValue' {

    It 'Returns the value when the property exists' {
        Get-InventoryValue ([pscustomobject]@{ Alias = 'jsmith' }) 'Alias' '' | Should -BeExactly 'jsmith'
    }

    It 'Returns the default when the property is absent' {
        Get-InventoryValue ([pscustomobject]@{ Alias = 'jsmith' }) 'Missing' 'fallback' |
            Should -BeExactly 'fallback'
    }

    It 'Returns the default for a null or whitespace value' {
        Get-InventoryValue ([pscustomobject]@{ Alias = $null }) 'Alias' 'fallback' | Should -BeExactly 'fallback'
        Get-InventoryValue ([pscustomobject]@{ Alias = '   ' }) 'Alias' 'fallback' | Should -BeExactly 'fallback'
    }

    It 'Returns the default for a null object' {
        Get-InventoryValue $null 'Alias' 'fallback' | Should -BeExactly 'fallback'
    }

    It 'Preserves a false boolean rather than treating it as empty' {
        Get-InventoryValue ([pscustomobject]@{ Hidden = $false }) 'Hidden' $true | Should -BeFalse
    }
}

Describe 'ConvertTo-InventoryByteCount and ConvertTo-InventoryGigabyte' {

    It 'Reads the exact byte count out of an Exchange size string' {
        ConvertTo-InventoryByteCount -Size '1.5 GB (1,610,612,736 bytes)' | Should -Be 1610612736
    }

    It 'Converts an Exchange size to GB rounded to two decimals' {
        ConvertTo-InventoryGigabyte -Size '1.5 GB (1,610,612,736 bytes)' | Should -Be 1.5
    }

    It 'Accepts a bare byte count' {
        ConvertTo-InventoryGigabyte -Size 1073741824 | Should -Be 1
    }

    It 'Returns null for a null size so the CSV cell stays blank' {
        ConvertTo-InventoryByteCount -Size $null | Should -BeNullOrEmpty
        ConvertTo-InventoryGigabyte -Size $null | Should -BeNullOrEmpty
    }

    It 'Returns null for an unparseable size rather than guessing' {
        ConvertTo-InventoryGigabyte -Size 'Unlimited' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-InventoryDomainList' {

    It 'Strips a leading @ and lower-cases' {
        ConvertTo-InventoryDomainList -Domain @('@Contoso.com') | Should -Be @('contoso.com')
    }

    It 'De-duplicates and sorts' {
        ConvertTo-InventoryDomainList -Domain @('fabrikam.com', 'contoso.com', '@FABRIKAM.com') |
            Should -Be @('contoso.com', 'fabrikam.com')
    }

    It 'Returns an empty array when no filter was supplied' {
        @(ConvertTo-InventoryDomainList -Domain @()).Count | Should -Be 0
        @(ConvertTo-InventoryDomainList -Domain $null).Count | Should -Be 0
    }
}

Describe 'Test-InventoryDomainMatch' {

    It 'Matches everything when no filter is set' {
        Test-InventoryDomainMatch -Address @('jane@contoso.com') -Domain @() | Should -BeTrue
    }

    It 'Matches on the UPN domain' {
        Test-InventoryDomainMatch -Address @('jane@contoso.com') -Domain @('contoso.com') | Should -BeTrue
    }

    It 'Is case-insensitive' {
        Test-InventoryDomainMatch -Address @('Jane@CONTOSO.com') -Domain @('contoso.com') | Should -BeTrue
    }

    It 'Rejects an address on another domain' {
        Test-InventoryDomainMatch -Address @('jane@fabrikam.com') -Domain @('contoso.com') | Should -BeFalse
    }

    It 'Matches when any one of the supplied addresses is on a filtered domain' {
        $addresses = @('jane_fabrikam.com#EXT#@contoso.onmicrosoft.com', 'jane@contoso.com')
        Test-InventoryDomainMatch -Address $addresses -Domain @('contoso.com') | Should -BeTrue
    }

    It 'Rejects an empty address list once a filter is set' {
        Test-InventoryDomainMatch -Address @() -Domain @('contoso.com') | Should -BeFalse
        Test-InventoryDomainMatch -Address @('', $null) -Domain @('contoso.com') | Should -BeFalse
    }

    It 'Matches any one of several filtered domains' {
        Test-InventoryDomainMatch -Address @('jane@fabrikam.com') -Domain @('contoso.com', 'fabrikam.com') |
            Should -BeTrue
    }
}

Describe 'Select-InventoryAddress' {

    BeforeAll {
        $script:sampleAddresses = @(
            'SMTP:jane.smith@contoso.com'
            'smtp:j.smith@contoso.com'
            'smtp:jsmith@fabrikam.com'
            'X500:/o=ExchangeLabs/ou=Exchange Administrative Group (FYDIBOHF23SPDLT)/cn=Recipients/cn=abc123'
            'sip:jane.smith@contoso.com'
        )
    }

    It 'Picks the upper-case SMTP entry as the primary' {
        (Select-InventoryAddress -EmailAddress $script:sampleAddresses).PrimarySmtp |
            Should -BeExactly 'jane.smith@contoso.com'
    }

    It 'Returns the lower-case smtp entries as aliases without their prefix' {
        (Select-InventoryAddress -EmailAddress $script:sampleAddresses).SmtpAliases |
            Should -Be @('j.smith@contoso.com', 'jsmith@fabrikam.com')
    }

    It 'Extracts X500 addresses and keeps the X500: prefix the destination needs' {
        $x500 = (Select-InventoryAddress -EmailAddress $script:sampleAddresses).X500Addresses
        @($x500).Count | Should -Be 1
        $x500[0] | Should -BeLike 'X500:/o=ExchangeLabs/*'
    }

    It 'Keeps every entry verbatim in All, including sip:' {
        (Select-InventoryAddress -EmailAddress $script:sampleAddresses).All.Count | Should -Be 5
    }

    It 'Handles an empty collection' {
        $result = Select-InventoryAddress -EmailAddress @()
        $result.PrimarySmtp | Should -BeExactly ''
        @($result.X500Addresses).Count | Should -Be 0
    }
}

Describe 'Resolve-InventoryRecipient' {

    BeforeAll {
        $script:RecipientIndex = @{}
        Add-InventoryRecipientIndexEntry -PrimarySmtpAddress 'jane.smith@contoso.com' `
            -Key @('jane.smith@contoso.com', 'jsmith', 'Jane Smith')
    }

    It 'Resolves an alias to the primary SMTP address' {
        Resolve-InventoryRecipient -Identity 'jsmith' | Should -BeExactly 'jane.smith@contoso.com'
    }

    It 'Resolves a canonical name by its leaf segment' {
        Resolve-InventoryRecipient -Identity 'contoso.com/Users/Jane Smith' |
            Should -BeExactly 'jane.smith@contoso.com'
    }

    It 'Returns an unknown identity verbatim rather than blanking it' {
        Resolve-InventoryRecipient -Identity 'Unknown Person' | Should -BeExactly 'Unknown Person'
    }

    It 'Returns an empty string for null' {
        Resolve-InventoryRecipient -Identity $null | Should -BeExactly ''
    }

    It 'Joins a multi-valued property into a delimited list' {
        Join-InventoryRecipientList -Value @('jsmith', 'Unknown Person') |
            Should -BeExactly 'jane.smith@contoso.com;Unknown Person'
    }
}

Describe 'ConvertTo-InventoryMailboxRow' {

    BeforeAll {
        $script:RecipientIndex = @{}
        Add-InventoryRecipientIndexEntry -PrimarySmtpAddress 'bob@contoso.com' -Key @('Bob Jones')

        $script:mailbox = [pscustomobject]@{
            UserPrincipalName             = 'jane.smith@contoso.com'
            DisplayName                   = 'Jane Smith'
            PrimarySmtpAddress            = 'jane.smith@contoso.com'
            Alias                         = 'jsmith'
            RecipientTypeDetails          = 'UserMailbox'
            EmailAddresses                = @(
                'SMTP:jane.smith@contoso.com'
                'smtp:jsmith@contoso.com'
                'X500:/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=abc123'
            )
            LegacyExchangeDN              = '/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=abc123'
            ArchiveStatus                 = 'Active'
            LitigationHoldEnabled         = $true
            InPlaceHolds                  = @('mbx1', 'mbx2')
            RetentionPolicy               = 'Default MRM Policy'
            HiddenFromAddressListsEnabled = $false
            ForwardingAddress             = 'Bob Jones'
            ForwardingSmtpAddress         = 'smtp:jane@fabrikam.com'
            DeliverToMailboxAndForward    = $true
            EmailAddressPolicyEnabled     = $false
            ProhibitSendReceiveQuota      = '50 GB (53,687,091,200 bytes)'
            GrantSendOnBehalfTo           = @('Bob Jones')
        }

        $script:statistics = [pscustomobject]@{
            TotalItemSize = '2.5 GB (2,684,354,560 bytes)'
            ItemCount     = 41234
            LastLogonTime = [datetime]'2026-09-01T08:15:00'
        }

        $script:archiveStatistics = [pscustomobject]@{ TotalItemSize = '1 GB (1,073,741,824 bytes)' }

        $script:row = ConvertTo-InventoryMailboxRow -Mailbox $script:mailbox `
            -Statistics $script:statistics -ArchiveStatistics $script:archiveStatistics
    }

    It 'Emits exactly the columns the identity planner reads, in order' {
        $expected = @(
            'UserPrincipalName', 'DisplayName', 'PrimarySmtpAddress', 'Alias', 'RecipientTypeDetails',
            'EmailAddresses', 'LegacyExchangeDN', 'X500Addresses', 'ArchiveStatus', 'LitigationHoldEnabled',
            'InPlaceHolds', 'RetentionPolicy', 'HiddenFromAddressListsEnabled', 'ForwardingAddress',
            'ForwardingSmtpAddress', 'DeliverToMailboxAndForward', 'EmailAddressPolicyEnabled',
            'TotalItemSizeGB', 'ItemCount', 'ArchiveSizeGB', 'LastLogonTime', 'ProhibitSendReceiveQuota',
            'GrantSendOnBehalfTo'
        )
        @($script:row.PSObject.Properties.Name) | Should -Be $expected
    }

    It 'Joins the email addresses with the plan delimiter' {
        $script:row.EmailAddresses | Should -BeLike 'SMTP:jane.smith@contoso.com;smtp:jsmith@contoso.com;X500:*'
    }

    It 'Extracts the X500 address separately' {
        $script:row.X500Addresses | Should -BeLike 'X500:/o=ExchangeLabs/*'
    }

    It 'Counts in-place holds rather than listing them' {
        $script:row.InPlaceHolds | Should -Be 2
    }

    It 'Converts sizes to GB' {
        $script:row.TotalItemSizeGB | Should -Be 2.5
        $script:row.ArchiveSizeGB | Should -Be 1
    }

    It 'Resolves delegate and forwarding identities to addresses' {
        $script:row.ForwardingAddress | Should -BeExactly 'bob@contoso.com'
        $script:row.GrantSendOnBehalfTo | Should -BeExactly 'bob@contoso.com'
    }

    It 'Leaves size columns empty when statistics were skipped' {
        $skipped = ConvertTo-InventoryMailboxRow -Mailbox $script:mailbox -Statistics $null -ArchiveStatistics $null
        $skipped.TotalItemSizeGB | Should -BeNullOrEmpty
        $skipped.ItemCount | Should -BeNullOrEmpty
        $skipped.LastLogonTime | Should -BeNullOrEmpty
    }

    It 'Survives a mailbox returned with a narrower property set' {
        $sparse = [pscustomobject]@{
            UserPrincipalName    = 'sparse@contoso.com'
            PrimarySmtpAddress   = 'sparse@contoso.com'
            RecipientTypeDetails = 'SharedMailbox'
        }
        $sparseRow = ConvertTo-InventoryMailboxRow -Mailbox $sparse -Statistics $null -ArchiveStatistics $null
        $sparseRow.LitigationHoldEnabled | Should -BeFalse
        $sparseRow.InPlaceHolds | Should -Be 0
        $sparseRow.EmailAddresses | Should -BeExactly ''
    }
}

Describe 'ConvertTo-InventoryUserRow' {

    BeforeAll {
        $script:skuNameById = @{
            '11111111-1111-1111-1111-111111111111' = 'SPE_E3'
            '22222222-2222-2222-2222-222222222222' = 'MCOEV'
        }

        $script:user = [pscustomobject]@{
            id                      = '33333333-3333-3333-3333-333333333333'
            userPrincipalName       = 'jane.smith@contoso.com'
            displayName             = 'Jane Smith'
            givenName               = 'Jane'
            surname                 = 'Smith'
            mail                    = 'jane.smith@contoso.com'
            jobTitle                = 'Analyst'
            department              = 'Finance'
            officeLocation          = 'HQ'
            mobilePhone             = '+1 555 0100'
            usageLocation           = 'US'
            accountEnabled          = $true
            userType                = 'Member'
            onPremisesSyncEnabled   = $true
            onPremisesImmutableId   = 'abcdef=='
            createdDateTime         = '2020-01-01T00:00:00Z'
            proxyAddresses          = @('SMTP:jane.smith@contoso.com', 'smtp:jsmith@contoso.com')
            assignedLicenses        = @(
                [pscustomobject]@{ skuId = '11111111-1111-1111-1111-111111111111'; disabledPlans = @() }
                [pscustomobject]@{ skuId = '22222222-2222-2222-2222-222222222222'; disabledPlans = @() }
            )
            licenseAssignmentStates = @(
                [pscustomobject]@{ skuId = '11111111-1111-1111-1111-111111111111'; assignedByGroup = $null }
                [pscustomobject]@{ skuId = '22222222-2222-2222-2222-222222222222'
                                   assignedByGroup = '44444444-4444-4444-4444-444444444444' }
            )
            manager                 = [pscustomobject]@{ userPrincipalName = 'boss@contoso.com' }
            signInActivity          = [pscustomobject]@{ lastSignInDateTime = '2026-09-01T08:00:00Z' }
        }

        $script:userRow = ConvertTo-InventoryUserRow -User $script:user -SkuNameById $script:skuNameById `
            -DirectoryRole @('Global Reader', 'User Administrator')
    }

    It 'Emits the base column set in order and ends with DirectoryRoles' {
        $expected = @(
            'ObjectId', 'UserPrincipalName', 'DisplayName', 'FirstName', 'MiddleName', 'LastName', 'Mail',
            'JobTitle', 'Department', 'Office', 'MobilePhone', 'UsageLocation', 'AccountEnabled', 'UserType',
            'IsSynced', 'ImmutableId', 'ManagerUpn', 'Licenses', 'LicenseSkuIds', 'LicenseAssignedByGroup',
            'ProxyAddresses', 'LastSignIn', 'CreatedDateTime', 'DirectoryRoles'
        )
        @($script:userRow.PSObject.Properties.Name) | Should -Be $expected
    }

    It 'Maps licence GUIDs to part numbers and keeps the GUIDs too' {
        $script:userRow.Licenses | Should -BeExactly 'MCOEV;SPE_E3'
        $script:userRow.LicenseSkuIds | Should -BeLike '11111111*;22222222*'
    }

    It 'Flags group-based licensing' {
        $script:userRow.LicenseAssignedByGroup | Should -BeTrue
    }

    It 'Reads the manager from the expanded property' {
        $script:userRow.ManagerUpn | Should -BeExactly 'boss@contoso.com'
    }

    It 'Joins the directory roles' {
        $script:userRow.DirectoryRoles | Should -BeExactly 'Global Reader;User Administrator'
    }

    It 'Leaves MiddleName blank because Graph does not expose it' {
        $script:userRow.MiddleName | Should -BeExactly ''
    }

    It 'Adds the MFA columns only when asked' {
        $registration = [pscustomobject]@{ isMfaRegistered = $true; methodsRegistered = @('microsoftAuthenticatorPush') }
        $withMfa = ConvertTo-InventoryUserRow -User $script:user -SkuNameById $script:skuNameById `
            -DirectoryRole @() -Registration $registration -IncludeAuthMethodColumn
        $withMfa.MfaRegistered | Should -BeTrue
        $withMfa.MfaMethods | Should -BeExactly 'microsoftAuthenticatorPush'
        $script:userRow.PSObject.Properties.Name | Should -Not -Contain 'MfaRegistered'
    }

    It 'Adds the OneDrive columns only when asked' {
        $drive = [pscustomobject]@{
            webUrl = 'https://contoso-my.sharepoint.com/personal/jane_smith_contoso_com'
            quota  = [pscustomobject]@{ used = 5368709120 }
        }
        $withDrive = ConvertTo-InventoryUserRow -User $script:user -SkuNameById $script:skuNameById `
            -DirectoryRole @() -Drive $drive -IncludeOneDriveColumn
        $withDrive.OneDriveUsedGB | Should -Be 5
        $script:userRow.PSObject.Properties.Name | Should -Not -Contain 'OneDriveUrl'
    }

    It 'Handles a user with no licences, manager or sign-in activity' {
        $bare = [pscustomobject]@{ id = '55555555-5555-5555-5555-555555555555'
                                   userPrincipalName = 'bare@contoso.com' }
        $bareRow = ConvertTo-InventoryUserRow -User $bare -SkuNameById $script:skuNameById -DirectoryRole @()
        $bareRow.Licenses | Should -BeExactly ''
        $bareRow.ManagerUpn | Should -BeExactly ''
        $bareRow.LastSignIn | Should -BeExactly ''
        $bareRow.LicenseAssignedByGroup | Should -BeFalse
    }
}

Describe 'ConvertTo-InventoryContactRow' {

    It 'Joins the mail contact and the directory contact' {
        $mailContact = [pscustomobject]@{
            DisplayName                   = 'Ada Lovelace'
            ExternalEmailAddress          = 'SMTP:ada@fabrikam.com'
            PrimarySmtpAddress            = 'ada.lovelace@contoso.com'
            Alias                         = 'ada'
            HiddenFromAddressListsEnabled = $true
            EmailAddresses                = @('SMTP:ada.lovelace@contoso.com')
        }
        $contact = [pscustomobject]@{ FirstName = 'Ada'; LastName = 'Lovelace' }

        $row = ConvertTo-InventoryContactRow -MailContact $mailContact -Contact $contact
        $row.ExternalEmailAddress | Should -BeExactly 'ada@fabrikam.com'
        $row.FirstName | Should -BeExactly 'Ada'
        $row.LastName | Should -BeExactly 'Lovelace'
        $row.HiddenFromAddressListsEnabled | Should -BeTrue
    }

    It 'Leaves the name parts blank when no directory contact matched' {
        $mailContact = [pscustomobject]@{
            DisplayName          = 'Ada Lovelace'
            ExternalEmailAddress = 'ada@fabrikam.com'
            PrimarySmtpAddress   = 'ada.lovelace@contoso.com'
        }
        $row = ConvertTo-InventoryContactRow -MailContact $mailContact -Contact $null
        $row.FirstName | Should -BeExactly ''
        $row.ExternalEmailAddress | Should -BeExactly 'ada@fabrikam.com'
    }
}

Describe 'Get-InventoryGroupType' {

    It 'Classifies a distribution list from its Exchange recipient type' {
        Get-InventoryGroupType -RecipientTypeDetails 'MailUniversalDistributionGroup' |
            Should -BeExactly 'Distribution'
    }

    It 'Distinguishes a mail-enabled security group' {
        Get-InventoryGroupType -RecipientTypeDetails 'MailUniversalSecurityGroup' |
            Should -BeExactly 'MailEnabledSecurity'
    }

    It 'Classifies a dynamic distribution group' {
        Get-InventoryGroupType -RecipientTypeDetails 'DynamicDistributionGroup' |
            Should -BeExactly 'DynamicDistribution'
    }

    It 'Separates a Team from a plain Microsoft 365 group' {
        Get-InventoryGroupType -RecipientTypeDetails '' -GroupType @('Unified') -IsTeam $true |
            Should -BeExactly 'Team'
        Get-InventoryGroupType -RecipientTypeDetails '' -GroupType @('Unified') -IsTeam $false |
            Should -BeExactly 'M365Group'
    }

    It 'Falls back to the Graph flags for a group Exchange never sees' {
        Get-InventoryGroupType -RecipientTypeDetails '' -GroupType @() -MailEnabled $false -SecurityEnabled $true |
            Should -BeExactly 'SecurityGroup'
        Get-InventoryGroupType -RecipientTypeDetails '' -GroupType @() -MailEnabled $true -SecurityEnabled $true |
            Should -BeExactly 'MailEnabledSecurity'
    }
}

Describe 'Test-InventoryTrustee and ConvertTo-InventoryPermissionRow' {

    BeforeAll {
        $script:exclusion = '^(NT AUTHORITY\\SELF|S-1-5-)'
        $script:RecipientIndex = @{}
        Add-InventoryRecipientIndexEntry -PrimarySmtpAddress 'bob@contoso.com' -Key @('bob@contoso.com', 'Bob Jones')
    }

    It 'Excludes the mailbox SELF ACE' {
        Test-InventoryTrustee -Trustee 'NT AUTHORITY\SELF' -Pattern $script:exclusion | Should -BeFalse
    }

    It 'Excludes orphaned SIDs' {
        Test-InventoryTrustee -Trustee 'S-1-5-21-1234567890-1234567890-1234567890-1001' -Pattern $script:exclusion |
            Should -BeFalse
    }

    It 'Keeps a real trustee' {
        Test-InventoryTrustee -Trustee 'bob@contoso.com' -Pattern $script:exclusion | Should -BeTrue
    }

    It 'Excludes an empty trustee' {
        Test-InventoryTrustee -Trustee '' -Pattern $script:exclusion | Should -BeFalse
    }

    It 'Shapes a permission row with the documented columns' {
        $row = ConvertTo-InventoryPermissionRow -MailboxPrimarySmtp 'jane@contoso.com' -MailboxType 'UserMailbox' `
            -Trustee 'Bob Jones' -Permission 'FullAccess' -IsInherited $false
        @($row.PSObject.Properties.Name) | Should -Be @(
            'MailboxPrimarySmtp', 'MailboxType', 'Trustee', 'TrusteeType', 'Permission', 'AutoMapping', 'IsInherited'
        )
        $row.Trustee | Should -BeExactly 'bob@contoso.com'
        $row.TrusteeType | Should -BeExactly 'Recipient'
        $row.AutoMapping | Should -BeExactly ''
    }

    It 'Marks a trustee it could not resolve' {
        $row = ConvertTo-InventoryPermissionRow -MailboxPrimarySmtp 'jane@contoso.com' -MailboxType 'UserMailbox' `
            -Trustee 'CONTOSO\deleted-account' -Permission 'FullAccess' -IsInherited $false
        $row.TrusteeType | Should -BeExactly 'Unresolved'
    }
}
