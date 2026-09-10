#Requires -Version 7.4

<#
    Offline tests for Test-MigrationReadiness.ps1.

    How the script's functions get into the test session: the script is a script, not a module, and
    dot-sourcing it would run Main and try to reach Microsoft Graph and Exchange Online. So the file
    is parsed and only its FunctionDefinitionAst nodes are re-created as script blocks and
    dot-sourced. That gives the real function bodies with no side effects and no edits to the script
    to make it testable.

    Because the functions then live in the test session state rather than inside a module, plain
    `Mock Invoke-MigrationGraphRequest` intercepts them - `Mock -ModuleName` is not needed.

    The check functions themselves are pure: they take plan rows plus plain objects standing in for
    Graph users, Exchange mailboxes and destination recipients, so no mocking is needed for most of
    what matters here.

    Author: AutomationHub
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Test-MigrationReadiness.ps1')).Path
    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Test-MigrationReadiness.ps1 does not parse: $($parseErrors[0].Message)"
    }
    foreach ($definition in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    # Deliberately obvious placeholder GUIDs - no real tenant identifiers in this repo.
    $script:targetId = '00000000-0000-0000-0000-000000000001'
    $script:otherId = '00000000-0000-0000-0000-000000000002'

    $script:catalog = @(
        [pscustomobject]@{ SkuId = '00000000-0000-0000-0000-000000000e30'; SkuPartNumber = 'SPE_E3'; Available = 2 }
        [pscustomobject]@{ SkuId = '00000000-0000-0000-0000-000000000e51'; SkuPartNumber = 'MCOEV'; Available = 10 }
    )

    function New-TestPlanRow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds an in-memory fixture; it changes no state.')]
        param([hashtable]$Property = @{})
        $row = New-MigrationPlanRow
        foreach ($key in $Property.Keys) { $row.$key = $Property[$key] }
        return $row
    }

    function New-ExistingObject {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds an in-memory fixture; it changes no state.')]
        param(
            [string]$Id = '',
            [string]$Kind = 'User',
            [string]$DisplayName = '',
            [string]$MailNickname = '',
            [string[]]$Address = @()
        )
        return [pscustomobject]@{
            Id = $Id; Kind = $Kind; DisplayName = $DisplayName
            MailNickname = $MailNickname; Address = @($Address)
        }
    }

    # ExchangeOnlineManagement is not loaded in the test session, so Get-EXORecipient does not
    # exist and Pester cannot Mock a command that is not defined. This stub stands in for it.
    function Get-EXORecipient { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub stands in for the ExchangeOnlineManagement cmdlet so Pester can mock it')] param($Filter, $ResultSize, $Properties, $ErrorAction) }
}

Describe 'ConvertTo-BareAddress' {

    It 'Strips the smtp prefix in either case' {
        ConvertTo-BareAddress -Value 'SMTP:John.Smith@newco.com' | Should -Be 'john.smith@newco.com'
        ConvertTo-BareAddress -Value 'smtp:jsmith@newco.com' | Should -Be 'jsmith@newco.com'
    }

    It 'Returns nothing for a non-SMTP proxy address' {
        ConvertTo-BareAddress -Value 'X500:/o=ExchangeLabs/ou=Exchange/cn=Recipients/cn=abc' | Should -Be ''
        ConvertTo-BareAddress -Value 'sip:john@newco.com' | Should -Be ''
    }

    It 'Passes a bare address through, lower-cased' {
        ConvertTo-BareAddress -Value ' John.Smith@Newco.com ' | Should -Be 'john.smith@newco.com'
    }

    It 'Returns an empty string for empty input' {
        ConvertTo-BareAddress -Value '' | Should -Be ''
    }
}

Describe 'Get-AddressDomain' {

    It 'Returns the lower-cased domain' {
        Get-AddressDomain -Value 'John.Smith@Newco.COM' | Should -Be 'newco.com'
    }

    It 'Handles a guest UPN whose local part contains an @' {
        Get-AddressDomain -Value 'jsmith_contoso.com#EXT#@newco.onmicrosoft.com' | Should -Be 'newco.onmicrosoft.com'
    }

    It 'Returns nothing when there is no domain' {
        Get-AddressDomain -Value 'jsmith' | Should -Be ''
        Get-AddressDomain -Value 'jsmith@' | Should -Be ''
    }
}

Describe 'Get-PlanAddressCandidate' {

    It 'Collects the target and interim UPNs, addresses, aliases and mail nickname' {
        $row = New-TestPlanRow -Property @{
            TargetUserPrincipalName  = 'John.Smith@newco.com'
            InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'
            TargetPrimarySmtp        = 'john.smith@newco.com'
            InterimPrimarySmtp       = 'john.smith@newco.onmicrosoft.com'
            TargetAliases            = 'smtp:jsmith@newco.com;X500:/o=ExchangeLabs/cn=abc'
            TargetMailNickname       = 'john.smith'
        }
        $candidate = @(Get-PlanAddressCandidate -Row $row)

        @($candidate | Where-Object Kind -EQ 'Upn').Value | Should -Be @('john.smith@newco.com', 'john.smith@newco.onmicrosoft.com')
        @($candidate | Where-Object Kind -EQ 'MailNickname').Value | Should -Be @('john.smith')
        @($candidate | Where-Object Kind -EQ 'Smtp').Value | Should -Contain 'jsmith@newco.com'
    }

    It 'Leaves X500 entries out - they are routing history, not an address claim' {
        $row = New-TestPlanRow -Property @{ TargetAliases = 'X500:/o=ExchangeLabs/cn=abc' }
        @(Get-PlanAddressCandidate -Row $row) | Should -HaveCount 0
    }
}

Describe 'Test-AddressClash' {

    It 'Reports a target UPN that an existing destination user already holds' {
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; Wave = '1'; ObjectType = 'User' }
        $existing = @(New-ExistingObject -Id $script:otherId -Kind 'User' -DisplayName 'Another Smith' `
            -Address @('john.smith@newco.com'))

        $clash = @(Test-AddressClash -Row @($row) -ExistingObject $existing)
        $clash | Should -HaveCount 1
        $clash[0].Status | Should -Be 'Failed'
        $clash[0].Action | Should -Be 'AddressClash'
        $clash[0].Detail | Should -BeLike "*Another Smith*"
        $clash[0].Wave | Should -Be '1'
    }

    It 'Does not treat the row own already-provisioned object as a clash' {
        $row = New-TestPlanRow -Property @{
            TargetUserPrincipalName = 'john.smith@newco.com'
            TargetObjectId          = $script:targetId
        }
        $existing = @(New-ExistingObject -Id $script:targetId -Kind 'User' -Address @('john.smith@newco.com'))
        @(Test-AddressClash -Row @($row) -ExistingObject $existing) | Should -HaveCount 0
    }

    It 'Detects a mail nickname clash separately from an address clash' {
        $row = New-TestPlanRow -Property @{ TargetMailNickname = 'john.smith' }
        $existing = @(New-ExistingObject -Id $script:otherId -Kind 'Group' -DisplayName 'Smiths' -MailNickname 'john.smith')

        $clash = @(Test-AddressClash -Row @($row) -ExistingObject $existing)
        $clash | Should -HaveCount 1
        $clash[0].Detail | Should -BeLike '*MailNickname*'
    }

    It 'Detects a clash with an Exchange recipient supplied as a fake recipient list' {
        $row = New-TestPlanRow -Property @{ TargetPrimarySmtp = 'accounts@newco.com' }
        $existing = @(
            New-ExistingObject -Id '' -Kind 'MailUniversalDistributionGroup' -DisplayName 'Accounts' `
                -Address @('accounts@newco.com', 'ap@newco.com')
        )

        $clash = @(Test-AddressClash -Row @($row) -ExistingObject $existing)
        $clash | Should -HaveCount 1
        $clash[0].Detail | Should -BeLike '*MailUniversalDistributionGroup*'
    }

    It 'Detects a soft-deleted user still holding the target UPN' {
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com' }
        $existing = @(New-ExistingObject -Id $script:otherId -Kind 'SoftDeletedUser' -DisplayName 'John Smith' `
            -Address @('john.smith@newco.com'))

        $clash = @(Test-AddressClash -Row @($row) -ExistingObject $existing)
        $clash | Should -HaveCount 1
        $clash[0].Detail | Should -BeLike '*SoftDeletedUser*'
    }

    It 'Reports one row per distinct holder rather than one per index hit' {
        $row = New-TestPlanRow -Property @{
            TargetUserPrincipalName = 'john.smith@newco.com'
            TargetPrimarySmtp       = 'john.smith@newco.com'
        }
        $existing = @(New-ExistingObject -Id $script:otherId -Kind 'User' -Address @('john.smith@newco.com'))
        @(Test-AddressClash -Row @($row) -ExistingObject $existing) | Should -HaveCount 1
    }

    It 'Returns nothing when the destination is empty' {
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com' }
        @(Test-AddressClash -Row @($row) -ExistingObject @()) | Should -HaveCount 0
    }

    It 'Reports one row, not two, when the same holder is found once by Graph and once by Exchange' {
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetPrimarySmtp = 'john.smith@newco.com' }
        $existing = @(
            New-ExistingObject -Id $script:otherId -Kind 'User' -DisplayName 'John Smith' -Address @('john.smith@newco.com')
            New-ExistingObject -Id $script:otherId -Kind 'UserMailbox' -DisplayName 'John Smith' -Address @('john.smith@newco.com')
        )
        @(Test-AddressClash -Row @($row) -ExistingObject $existing) | Should -HaveCount 1
    }

    It 'Still dedupes id-less recipients found under the same kind' {
        $row = New-TestPlanRow -Property @{ TargetPrimarySmtp = 'accounts@newco.com' }
        $existing = @(
            New-ExistingObject -Id '' -Kind 'MailContact' -DisplayName 'Accounts' -Address @('accounts@newco.com')
        )
        @(Test-AddressClash -Row @($row) -ExistingObject $existing) | Should -HaveCount 1
    }
}

Describe 'Measure-SeatRequirement' {

    It 'Totals one seat per licensed plan row' {
        $rows = @(
            New-TestPlanRow -Property @{ TargetLicenses = 'SPE_E3' }
            New-TestPlanRow -Property @{ TargetLicenses = 'SPE_E3;MCOEV' }
        )
        $seat = @(Measure-SeatRequirement -Row $rows -Catalog $script:catalog)
        ($seat | Where-Object SkuPartNumber -EQ 'SPE_E3').Needed | Should -Be 2
        ($seat | Where-Object SkuPartNumber -EQ 'MCOEV').Needed | Should -Be 1
    }

    It 'Reports Sufficient when demand exactly matches the spare seats' {
        $rows = @(1..2 | ForEach-Object { New-TestPlanRow -Property @{ TargetLicenses = 'SPE_E3' } })
        $seat = @(Measure-SeatRequirement -Row $rows -Catalog $script:catalog)
        $seat[0].Shortfall | Should -Be 0
        $seat[0].Status | Should -Be 'Sufficient'
    }

    It 'Reports the exact shortfall when demand exceeds the spare seats' {
        $rows = @(1..5 | ForEach-Object { New-TestPlanRow -Property @{ TargetLicenses = 'SPE_E3' } })
        $seat = @(Measure-SeatRequirement -Row $rows -Catalog $script:catalog)
        $seat[0].Needed | Should -Be 5
        $seat[0].Available | Should -Be 2
        $seat[0].Shortfall | Should -Be 3
        $seat[0].Status | Should -Be 'Shortfall'
    }

    It 'Flags a part number the destination tenant does not subscribe to' {
        $rows = @(New-TestPlanRow -Property @{ TargetLicenses = 'ENTERPRISEPACK' })
        $seat = @(Measure-SeatRequirement -Row $rows -Catalog $script:catalog)
        $seat[0].Status | Should -Be 'Unknown'
        $seat[0].Available | Should -Be 0
    }

    It 'Returns nothing when no row asks for a licence' {
        @(Measure-SeatRequirement -Row @(New-TestPlanRow) -Catalog $script:catalog) | Should -HaveCount 0
    }
}

Describe 'ConvertTo-QuotaGigabyte' {

    It 'Prefers the parenthesised byte count' {
        ConvertTo-QuotaGigabyte -Value '100 GB (107,374,182,400 bytes)' | Should -Be 100
    }

    It 'Falls back to the unit string when there is no byte count' {
        ConvertTo-QuotaGigabyte -Value '50 GB' | Should -Be 50
        ConvertTo-QuotaGigabyte -Value '2 TB' | Should -Be 2048
    }

    It 'Treats Unlimited as larger than any source mailbox' {
        ConvertTo-QuotaGigabyte -Value 'Unlimited' | Should -Be ([double]::MaxValue)
    }

    It 'Returns zero for an empty or unparseable value' {
        ConvertTo-QuotaGigabyte -Value '' | Should -Be 0
        ConvertTo-QuotaGigabyte -Value 'not a quota' | Should -Be 0
    }
}

Describe 'Test-ProvisionedRow' {

    It 'Fails immediately and records both writeback flags as False when the user is gone' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId; TargetUserPrincipalName = 'john.smith@newco.com' }
        $graded = Test-ProvisionedRow -Row $row -User $null -Mailbox $null

        @($graded.Row) | Should -HaveCount 1
        @($graded.Row)[0].Action | Should -Be 'UserExists'
        @($graded.Row)[0].Status | Should -Be 'Failed'
        $graded.MailboxProvisioned | Should -Be 'False'
        $graded.OneDriveProvisioned | Should -Be 'False'
    }

    It 'Records MailboxProvisioned and OneDriveProvisioned as True when both exist' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId; TargetUserPrincipalName = 'john.smith@newco.com' }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'john.smith@newco.com' }
        $mailbox = [pscustomobject]@{ PrimarySmtpAddress = 'john.smith@newco.com'; LitigationHoldEnabled = $false }

        $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox -DriveState Present
        $graded.MailboxProvisioned | Should -Be 'True'
        $graded.OneDriveProvisioned | Should -Be 'True'
        (@($graded.Row) | Where-Object Action -EQ 'OneDriveExists').Status | Should -Be 'Succeeded'
    }

    It 'Fails the OneDrive check when the drive lookup returned 404' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'john.smith@newco.com' }
        $mailbox = [pscustomobject]@{ PrimarySmtpAddress = 'john.smith@newco.com'; LitigationHoldEnabled = $false }

        $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox
        $graded.OneDriveProvisioned | Should -Be 'False'
        (@($graded.Row) | Where-Object Action -EQ 'OneDriveExists').Detail | Should -BeLike '*Request-SPOPersonalSite*'
    }

    It 'Fails the litigation hold check when the hold is on' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'john.smith@newco.com' }
        $mailbox = [pscustomobject]@{ PrimarySmtpAddress = 'john.smith@newco.com'; LitigationHoldEnabled = $true }

        $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox -DriveState Present
        (@($graded.Row) | Where-Object Action -EQ 'LitigationHoldOff').Status | Should -Be 'Failed'
    }

    It 'Skips the archive and quota checks when no source mailbox inventory was supplied' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'john.smith@newco.com' }
        $mailbox = [pscustomobject]@{ PrimarySmtpAddress = 'john.smith@newco.com'; LitigationHoldEnabled = $false }

        $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox -DriveState Present
        (@($graded.Row) | Where-Object Action -EQ 'ArchiveEnabled').Status | Should -Be 'Skipped'
        (@($graded.Row) | Where-Object Action -EQ 'MailboxQuota').Status | Should -Be 'Skipped'
    }

    It 'Fails the archive check when the source had one and the destination does not' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'john.smith@newco.com' }
        $mailbox = [pscustomobject]@{
            PrimarySmtpAddress = 'john.smith@newco.com'; LitigationHoldEnabled = $false
            ArchiveStatus = 'None'; ArchiveGuid = '00000000-0000-0000-0000-000000000000'
        }
        $source = [pscustomobject]@{ PrimarySmtpAddress = 'jsmith@contoso.com'; ArchiveStatus = 'Active' }

        $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox -DriveState Present -SourceMailbox $source
        (@($graded.Row) | Where-Object Action -EQ 'ArchiveEnabled').Status | Should -Be 'Failed'
    }

    It 'Fails the quota check when the destination is smaller than the source mailbox' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'john.smith@newco.com' }
        $mailbox = [pscustomobject]@{
            PrimarySmtpAddress = 'john.smith@newco.com'; LitigationHoldEnabled = $false
            ProhibitSendReceiveQuota = '50 GB (53,687,091,200 bytes)'
        }
        $source = [pscustomobject]@{ PrimarySmtpAddress = 'jsmith@contoso.com'; TotalItemSizeGB = '73.5' }

        $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox -DriveState Present -SourceMailbox $source
        $quota = @($graded.Row) | Where-Object Action -EQ 'MailboxQuota'
        $quota.Status | Should -Be 'Failed'
        $quota.Detail | Should -BeLike '*73.5 GB*'
    }

    It 'Skips OneDriveExists and leaves the plan value alone when the drive read did not run' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId; OneDriveProvisioned = 'True' }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'john.smith@newco.com' }
        $mailbox = [pscustomobject]@{ PrimarySmtpAddress = 'john.smith@newco.com'; LitigationHoldEnabled = $false }

        $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox -DriveState NotChecked
        $graded.OneDriveProvisioned | Should -Be 'True'
        (@($graded.Row) | Where-Object Action -EQ 'OneDriveExists').Status | Should -Be 'Skipped'
    }

    It 'Skips OneDriveExists for a shared mailbox and leaves the plan value alone' {
        $row = New-TestPlanRow -Property @{ TargetObjectId = $script:targetId; ObjectType = 'Shared'; OneDriveProvisioned = 'False' }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'sales@newco.com' }
        $mailbox = [pscustomobject]@{ PrimarySmtpAddress = 'sales@newco.com'; LitigationHoldEnabled = $false }

        $graded = Test-ProvisionedRow -Row $row -User $user -Mailbox $mailbox -DriveState Present
        $graded.OneDriveProvisioned | Should -Be 'False'
        (@($graded.Row) | Where-Object Action -EQ 'OneDriveExists').Status | Should -Be 'Skipped'
    }
}

Describe 'Test-PostRow' {

    BeforeAll {
        $script:postRow = New-TestPlanRow -Property @{
            TargetObjectId          = $script:targetId
            TargetUserPrincipalName = 'john.smith@newco.com'
            TargetPrimarySmtp       = 'john.smith@newco.com'
            TargetAliases           = 'smtp:jsmith@newco.com'
            SourceX500              = 'X500:/o=ExchangeLabs/cn=Recipients/cn=abc'
        }
        $script:goodUser = [pscustomobject]@{
            id = $script:targetId; userPrincipalName = 'john.smith@newco.com'; accountEnabled = $true
        }
        $script:goodMailbox = [pscustomobject]@{
            PrimarySmtpAddress = 'john.smith@newco.com'
            HiddenFromAddressListsEnabled = $false
            EmailAddresses = @('SMTP:john.smith@newco.com', 'smtp:jsmith@newco.com',
                'X500:/o=ExchangeLabs/cn=Recipients/cn=abc')
        }
    }

    It 'Passes every check for a correctly cut-over mailbox' {
        $results = @(Test-PostRow -Row $script:postRow -User $script:goodUser -Mailbox $script:goodMailbox)
        @($results | Where-Object Status -EQ 'Failed') | Should -HaveCount 0
        @($results | Where-Object Action -EQ 'AliasesPresent').Status | Should -Be 'Succeeded'
    }

    It 'Fails when the UPN is not the planned one' {
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'jsmith@newco.onmicrosoft.com'; accountEnabled = $true }
        $results = @(Test-PostRow -Row $script:postRow -User $user -Mailbox $script:goodMailbox)
        $upn = $results | Where-Object Action -EQ 'UpnMatchesPlan'
        $upn.Status | Should -Be 'Failed'
        $upn.Detail | Should -BeLike "*Expected 'john.smith@newco.com'*"
    }

    It 'Fails when the primary SMTP address is not the planned one' {
        $mailbox = [pscustomobject]@{
            PrimarySmtpAddress = 'jsmith@newco.onmicrosoft.com'; HiddenFromAddressListsEnabled = $false
            EmailAddresses = @('SMTP:jsmith@newco.onmicrosoft.com')
        }
        $results = @(Test-PostRow -Row $script:postRow -User $script:goodUser -Mailbox $mailbox)
        (@($results | Where-Object Action -EQ 'PrimarySmtpMatchesPlan')).Status | Should -Be 'Failed'
    }

    It 'Fails when the X500 address is missing' {
        $mailbox = [pscustomobject]@{
            PrimarySmtpAddress = 'john.smith@newco.com'; HiddenFromAddressListsEnabled = $false
            EmailAddresses = @('SMTP:john.smith@newco.com', 'smtp:jsmith@newco.com')
        }
        $results = @(Test-PostRow -Row $script:postRow -User $script:goodUser -Mailbox $mailbox)
        $alias = $results | Where-Object Action -EQ 'AliasesPresent'
        $alias.Status | Should -Be 'Failed'
        $alias.Detail | Should -BeLike '*X500*'
    }

    It 'Fails when the mailbox is still hidden from address lists' {
        $mailbox = [pscustomobject]@{
            PrimarySmtpAddress = 'john.smith@newco.com'; HiddenFromAddressListsEnabled = $true
            EmailAddresses = $script:goodMailbox.EmailAddresses
        }
        $results = @(Test-PostRow -Row $script:postRow -User $script:goodUser -Mailbox $mailbox)
        (@($results | Where-Object Action -EQ 'VisibleInAddressList')).Status | Should -Be 'Failed'
    }

    It 'Fails when the account is disabled' {
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'john.smith@newco.com'; accountEnabled = $false }
        $results = @(Test-PostRow -Row $script:postRow -User $user -Mailbox $script:goodMailbox)
        (@($results | Where-Object Action -EQ 'AccountEnabled')).Status | Should -Be 'Failed'
    }

    It 'Reports a single failure and stops when the user is gone' {
        $results = @(Test-PostRow -Row $script:postRow -User $null -Mailbox $null)
        $results | Should -HaveCount 1
        $results[0].Action | Should -Be 'UserExists'
    }

    It 'Skips AccountEnabled for a disabled-by-design shared mailbox' {
        $row = New-TestPlanRow -Property @{
            TargetObjectId = $script:targetId; TargetUserPrincipalName = 'sales@newco.com'
            TargetPrimarySmtp = 'sales@newco.com'; ObjectType = 'Shared'
        }
        $user = [pscustomobject]@{ id = $script:targetId; userPrincipalName = 'sales@newco.com'; accountEnabled = $false }
        $mailbox = [pscustomobject]@{
            PrimarySmtpAddress = 'sales@newco.com'; HiddenFromAddressListsEnabled = $false
            EmailAddresses = @('SMTP:sales@newco.com')
        }
        $results = @(Test-PostRow -Row $row -User $user -Mailbox $mailbox)
        (@($results | Where-Object Action -EQ 'AccountEnabled')).Status | Should -Be 'Skipped'
    }
}

Describe 'Test-GraphNotFound' {

    It 'Recognises a 404 from the Graph error body' {
        $record = $null
        try { throw 'boom' } catch { $record = $_ }
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"itemNotFound"}}')
        Test-GraphNotFound -ErrorRecord $record | Should -BeTrue
    }

    It 'Does not mistake an unrelated failure for a 404' {
        $record = $null
        try { throw 'Insufficient privileges to complete the operation' } catch { $record = $_ }
        Test-GraphNotFound -ErrorRecord $record | Should -BeFalse
    }
}

Describe 'Get-RecipientClashObject' {

    It 'Requests the properties the address and mail nickname clash checks read' {
        Mock Get-EXORecipient { return @() }

        $null = Get-RecipientClashObject -EmailAddress @('accounts@newco.com')

        Should -Invoke Get-EXORecipient -Times 1 -ParameterFilter {
            $Properties -contains 'EmailAddresses' -and $Properties -contains 'PrimarySmtpAddress' -and
            $Properties -contains 'DisplayName' -and $Properties -contains 'Alias'
        }
    }

    It 'Builds an Address array from EmailAddresses and PrimarySmtpAddress' {
        Mock Get-EXORecipient {
            return @([pscustomobject]@{
                    ExternalDirectoryObjectId = $script:otherId
                    RecipientType             = 'MailUniversalDistributionGroup'
                    DisplayName               = 'Accounts'
                    Alias                     = 'accounts'
                    PrimarySmtpAddress        = 'accounts@newco.com'
                    EmailAddresses            = @('SMTP:accounts@newco.com', 'smtp:ap@newco.com')
                })
        }

        $found = @(Get-RecipientClashObject -EmailAddress @('accounts@newco.com'))
        $found | Should -HaveCount 1
        $found[0].Address | Should -Contain 'accounts@newco.com'
        $found[0].Address | Should -Contain 'ap@newco.com'
        $found[0].MailNickname | Should -Be 'accounts'
    }
}

Describe 'Get-VerifiedDomain' {

    It 'Returns only the verified domains, lower-cased' {
        Mock Invoke-MigrationGraphRequest {
            return @(
                [pscustomobject]@{ id = 'NewCo.com'; isVerified = $true }
                [pscustomobject]@{ id = 'pending.newco.com'; isVerified = $false }
                [pscustomobject]@{ id = 'newco.onmicrosoft.com'; isVerified = $true }
            )
        }

        $domains = @(Get-VerifiedDomain)
        $domains | Should -Be @('newco.com', 'newco.onmicrosoft.com')
    }
}
