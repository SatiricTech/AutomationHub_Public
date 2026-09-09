#Requires -Version 7.4

<#
    Offline tests for Set-MigrationMailboxPermissions.ps1.

    How the script's own functions are reached
    ------------------------------------------
    The unit under test is a script, not a module, so dot-sourcing it would run the whole thing -
    connect to Exchange, read a tenant, write permissions. Instead the file is parsed and only its
    FunctionDefinitionAst nodes are re-created here. That gives the functions without their Main
    region, needs no test-only switch on the script, and cannot drift from the file being shipped.

    How "DryRun calls nothing" is proved in Pester 6
    -----------------------------------------------
    Pester will only mock a command it can resolve, and none of the Exchange cmdlets exist on a
    machine without ExchangeOnlineManagement (nor on macOS at all). So stubs with the same parameter
    shapes are declared in BeforeAll and Pester mocks the stubs. Functions and stubs declared in
    BeforeAll are visible to every It in the file, and the mutation scriptblocks the script builds
    are created in this same scope, so the mock is what they resolve. Initialize-MigrationRun
    -DryRun sets the module's run context, which is what Invoke-MigrationAction consults - the same
    code path a real -DryRun run takes.
#>

BeforeAll {
    $script:MigrationRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    Import-Module (Join-Path -Path $script:MigrationRoot -ChildPath 'M365Migration/M365Migration.psd1') -Force

    $script:ScriptPath = Join-Path -Path $script:MigrationRoot -ChildPath 'Set-MigrationMailboxPermissions.ps1'
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures/Set-MigrationMailboxPermissions'
    $script:PlanFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'IdentityPlan.csv'
    $script:PermissionFixture = Join-Path -Path $script:FixtureRoot -ChildPath 'MailboxPermissions.csv'

    $parsed = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
    $definitions = $parsed.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    . ([scriptblock]::Create(($definitions.Extent.Text -join [Environment]::NewLine)))

    # Stubs for the Exchange cmdlets the script mutates through. Parameter names must match the
    # script's call sites or Pester's parameter filters would never bind.
    function Add-MailboxPermission {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub for a cmdlet that does not exist off Windows; Pester mocks it and the parameters only have to bind.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stub named after the real cmdlet so Pester can mock it; it has no body and changes nothing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
        Justification = 'Stub mirrors the real cmdlet signature, which takes -Confirm; it has no body and changes nothing.')]
        param($Identity, $User, $AccessRights, $AutoMapping, $Confirm, $ErrorAction)
    }
    function Add-RecipientPermission {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub for a cmdlet that does not exist off Windows; Pester mocks it and the parameters only have to bind.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stub named after the real cmdlet so Pester can mock it; it has no body and changes nothing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
        Justification = 'Stub mirrors the real cmdlet signature, which takes -Confirm; it has no body and changes nothing.')]
        param($Identity, $Trustee, $AccessRights, $Confirm, $ErrorAction)
    }
    function Add-MailboxFolderPermission {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub for a cmdlet that does not exist off Windows; Pester mocks it and the parameters only have to bind.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stub named after the real cmdlet so Pester can mock it; it has no body and changes nothing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
        Justification = 'Stub mirrors the real cmdlet signature, which takes -Confirm; it has no body and changes nothing.')]
        param($Identity, $User, $AccessRights, $ErrorAction)
    }
    function Set-MailboxFolderPermission {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub for a cmdlet that does not exist off Windows; Pester mocks it and the parameters only have to bind.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stub named after the real cmdlet so Pester can mock it; it has no body and changes nothing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
        Justification = 'Stub mirrors the real cmdlet signature, which takes -Confirm; it has no body and changes nothing.')]
        param($Identity, $User, $AccessRights, $ErrorAction)
    }
    function Set-Mailbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub for a cmdlet that does not exist off Windows; Pester mocks it and the parameters only have to bind.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stub named after the real cmdlet so Pester can mock it; it has no body and changes nothing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
        Justification = 'Stub mirrors the real cmdlet signature, which takes -Confirm; it has no body and changes nothing.')]
        param($Identity, $GrantSendOnBehalfTo, $ForwardingAddress, $ForwardingSmtpAddress,
            $DeliverToMailboxAndForward, $ErrorAction)
    }

    $script:TempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath "SetMigrationMailboxPermissions-$([guid]::NewGuid())"

    function Initialize-TestRun {
        param([switch]$DryRun)
        $null = Initialize-MigrationRun -ScriptName 'Set-MigrationMailboxPermissions.Tests' `
            -OutputPath $script:TempRoot -Verbosity Low -DryRun:$DryRun
    }

    # Stand-ins for what the destination tenant returns, in the shapes each cmdlet actually uses:
    # Get-EXOMailboxPermission puts a UPN string in User, Get-EXORecipientPermission puts an address
    # in Trustee, and Get-MailboxFolderPermission nests a display name and a recipient object.
    $script:ExistingFullAccess = @(
        [pscustomobject]@{ User = 'john.smith@newco.com'; AccessRights = @('FullAccess'); IsInherited = $false }
        [pscustomobject]@{ User = 'audit@newco.com'; AccessRights = @('ReadPermission'); IsInherited = $false }
    )
    $script:ExistingSendAs = @(
        [pscustomobject]@{ Trustee = 'john.smith@newco.com'; AccessRights = @('SendAs') }
    )
    $script:ExistingCalendar = @(
        [pscustomobject]@{
            User = [pscustomobject]@{
                DisplayName = 'Alice Dean'
                ADRecipient = [pscustomobject]@{ PrimarySmtpAddress = 'alice.dean@newco.com' }
            }
            AccessRights = @('Reviewer')
        }
    )
    $script:ExistingSendOnBehalf = @('newco.com/Users/Bea Kane')
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-MigrationPlanAddressMap - permissions plan fixture' {

    BeforeAll {
        $script:PlanRows = @(Import-MigrationPlan -Path $script:PlanFixture)
        $script:Map = Get-MigrationPlanAddressMap -Rows $script:PlanRows
    }

    It 'Maps the source UPN, primary SMTP and every alias onto the same destination address' {
        $script:Map['jsmith@contoso.com'] | Should -BeExactly 'john.smith@newco.com'
        $script:Map['john.smith@contoso.com'] | Should -BeExactly 'john.smith@newco.com'
        $script:Map['aaaaaaaa-0000-0000-0000-000000000001'] | Should -BeExactly 'john.smith@newco.com'
    }

    It 'Maps a display name, which is how calendar trustees are usually reported' {
        $script:Map['John Q. Smith'] | Should -BeExactly 'john.smith@newco.com'
    }

    It 'Is case-insensitive, because inventories disagree about casing' {
        $script:Map['JSmith@Contoso.COM'] | Should -BeExactly 'john.smith@newco.com'
    }

    It 'Maps a shared mailbox that has no source UPN' {
        $script:Map['reception@contoso.com'] | Should -BeExactly 'reception@newco.com'
        $script:Map['frontdesk@contoso.com'] | Should -BeExactly 'reception@newco.com'
    }

    It 'Falls back to the interim identity when the vanity domain is not cut over yet' {
        $script:Map['bkane@contoso.com'] | Should -BeExactly 'bea.kane@newco.onmicrosoft.com'
    }

    It 'Spans every wave, so a trustee from another wave still resolves' {
        # alice.dean is wave 2; the permission that needs her is on a wave 1 mailbox.
        $script:Map['adean@contoso.com'] | Should -BeExactly 'alice.dean@newco.com'
    }

    It 'Ignores a row with no destination address at all' {
        $row = New-MigrationPlanRow
        $row.SourceUserPrincipalName = 'nobody@contoso.com'
        (Get-MigrationPlanAddressMap -Rows @($row)).Count | Should -Be 0
    }
}

Describe 'Resolve-MigrationPlanAddress - permissions plan fixture' {

    BeforeAll {
        $script:Map2 = Get-MigrationPlanAddressMap -Rows @(Import-MigrationPlan -Path $script:PlanFixture)
    }

    It 'Translates a mapped address' {
        $resolved = Resolve-MigrationPlanAddress -Map $script:Map2 -Address 'jsmith@contoso.com' -Role 'trustee'
        $resolved.IsMapped | Should -BeTrue
        $resolved.Address | Should -BeExactly 'john.smith@newco.com'
    }

    It 'Strips an smtp: prefix before looking up' {
        (Resolve-MigrationPlanAddress -Map $script:Map2 -Address 'smtp:jsmith@contoso.com').Address |
            Should -BeExactly 'john.smith@newco.com'
    }

    It 'Reports an unmapped trustee by name rather than guessing' {
        $resolved = Resolve-MigrationPlanAddress -Map $script:Map2 -Address 'departed@contoso.com' -Role 'trustee'
        $resolved.IsMapped | Should -BeFalse
        $resolved.Address | Should -BeNullOrEmpty
        $resolved.Detail | Should -Match 'departed@contoso.com'
        $resolved.Detail | Should -Match 'trustee'
    }

    It 'Reports an empty address' {
        $resolved = Resolve-MigrationPlanAddress -Map $script:Map2 -Address '' -Role 'mailbox'
        $resolved.IsMapped | Should -BeFalse
        $resolved.Detail | Should -Match 'no mailbox address'
    }

    It 'Produces a Skipped result row when the trustee cannot be mapped' {
        $resolved = Resolve-MigrationPlanAddress -Map $script:Map2 -Address 'departed@contoso.com' -Role 'trustee'
        $row = New-PermissionResult -Identity 'reception@newco.com' -Action 'FullAccess' -Status 'Skipped' `
            -Detail $resolved.Detail -SourceMailbox 'reception@contoso.com' -SourceTrustee 'departed@contoso.com'

        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'departed@contoso.com'
        $row.Trustee | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-PermissionEntry' {

    It 'Recognises the mailbox-level kinds' {
        (ConvertFrom-PermissionEntry -Permission 'FullAccess').Kind | Should -BeExactly 'FullAccess'
        (ConvertFrom-PermissionEntry -Permission 'sendas').Kind | Should -BeExactly 'SendAs'
        (ConvertFrom-PermissionEntry -Permission 'SendOnBehalf').Kind | Should -BeExactly 'SendOnBehalf'
    }

    It 'Splits a calendar entry into its kind and access rights' {
        $parsed = ConvertFrom-PermissionEntry -Permission 'Calendar:LimitedDetails'
        $parsed.Kind | Should -BeExactly 'Calendar'
        $parsed.AccessRights | Should -BeExactly 'LimitedDetails'
    }

    It 'Reports an unknown or empty permission rather than inventing one' {
        (ConvertFrom-PermissionEntry -Permission 'ExternalAccount').IsKnown | Should -BeFalse
        (ConvertFrom-PermissionEntry -Permission '').IsKnown | Should -BeFalse
    }
}

Describe 'ConvertTo-PermissionPrincipal' {

    It 'Passes a plain string through' {
        ConvertTo-PermissionPrincipal -Entry 'john.smith@newco.com' | Should -Be @('john.smith@newco.com')
    }

    It 'Reads the User property of a mailbox permission' {
        ConvertTo-PermissionPrincipal -Entry $script:ExistingFullAccess[0] | Should -Contain 'john.smith@newco.com'
    }

    It 'Reads the Trustee property of a recipient permission' {
        ConvertTo-PermissionPrincipal -Entry $script:ExistingSendAs[0] | Should -Contain 'john.smith@newco.com'
    }

    It 'Flattens the nested display name and address of a folder permission' {
        $principals = ConvertTo-PermissionPrincipal -Entry $script:ExistingCalendar[0]
        $principals | Should -Contain 'Alice Dean'
        $principals | Should -Contain 'alice.dean@newco.com'
    }
}

Describe 'Get-PermissionDiff' {

    It 'Skips a FullAccess grant the delegate already holds' {
        $diff = Get-PermissionDiff -Existing $script:ExistingFullAccess `
            -TrusteeIdentifier @('john.smith@newco.com') -Kind FullAccess

        $diff.Action | Should -BeExactly 'Skip'
        $diff.Detail | Should -Match 'already present'
    }

    It 'Adds a FullAccess grant for a delegate who is not on the mailbox' {
        (Get-PermissionDiff -Existing $script:ExistingFullAccess `
            -TrusteeIdentifier @('bea.kane@newco.com') -Kind FullAccess).Action | Should -BeExactly 'Add'
    }

    It 'Does not treat an unrelated right on the same trustee as the wanted one' {
        (Get-PermissionDiff -Existing $script:ExistingFullAccess `
            -TrusteeIdentifier @('audit@newco.com') -Kind FullAccess).Action | Should -BeExactly 'Add'
    }

    It 'Skips a SendAs grant that already exists' {
        (Get-PermissionDiff -Existing $script:ExistingSendAs `
            -TrusteeIdentifier @('john.smith@newco.com') -Kind SendAs).Action | Should -BeExactly 'Skip'
    }

    It 'Matches a trustee by display name when that is all Exchange reported' {
        (Get-PermissionDiff -Existing $script:ExistingCalendar `
            -TrusteeIdentifier @('alice.dean@newco.com', 'Alice Dean') -Kind Calendar `
            -AccessRights 'Reviewer').Action | Should -BeExactly 'Skip'
    }

    It 'Updates rather than adds a calendar right that exists at the wrong level' {
        $diff = Get-PermissionDiff -Existing $script:ExistingCalendar `
            -TrusteeIdentifier @('alice.dean@newco.com') -Kind Calendar -AccessRights 'Editor'

        $diff.Action | Should -BeExactly 'Update'
        $diff.Detail | Should -Match 'Reviewer'
        $diff.Detail | Should -Match 'Editor'
    }

    It 'Adds a calendar right for a trustee with nothing on the folder' {
        (Get-PermissionDiff -Existing $script:ExistingCalendar `
            -TrusteeIdentifier @('bea.kane@newco.com') -Kind Calendar -AccessRights 'Editor').Action |
            Should -BeExactly 'Add'
    }

    It 'Skips a SendOnBehalf entry already in GrantSendOnBehalfTo' {
        (Get-PermissionDiff -Existing $script:ExistingSendOnBehalf `
            -TrusteeIdentifier @('newco.com/Users/Bea Kane') -Kind SendOnBehalf).Action | Should -BeExactly 'Skip'
    }

    It 'Adds against an empty existing set' {
        (Get-PermissionDiff -Existing @() -TrusteeIdentifier @('john.smith@newco.com') -Kind FullAccess).Action |
            Should -BeExactly 'Add'
    }
}

Describe 'The permissions inventory maps end to end' {

    It 'Resolves both sides of every mappable row and reports the one it cannot' {
        $map = Get-MigrationPlanAddressMap -Rows @(Import-MigrationPlan -Path $script:PlanFixture)
        $rows = @(Import-MigrationCsv -Path $script:PermissionFixture `
            -RequiredColumns @('MailboxPrimarySmtp', 'Trustee', 'Permission'))

        $usable = @($rows | Where-Object {
            $_.IsInherited -ine 'True' -and $_.Trustee -notmatch '^(NT AUTHORITY\\|S-1-5-)' -and
            (ConvertFrom-PermissionEntry -Permission $_.Permission).IsKnown
        })
        $usable.Count | Should -Be 5

        $unmapped = @($usable | Where-Object {
            -not (Resolve-MigrationPlanAddress -Map $map -Address $_.Trustee -Role 'trustee').IsMapped
        })
        $unmapped.Count | Should -Be 1
        $unmapped[0].Trustee | Should -BeExactly 'departed@contoso.com'
    }
}

Describe 'New-PermissionResult' {

    It 'Leads with the four standard columns in the contract order' {
        $row = New-PermissionResult -Identity 'reception@newco.com' -Action 'FullAccess' -Status 'Planned' `
            -Detail 'Would grant.'
        @($row.PSObject.Properties.Name)[0..3] | Should -Be @('Identity', 'Action', 'Status', 'Detail')
    }

    It 'Rejects a status outside the contract' {
        { New-PermissionResult -Identity 'x' -Action 'SendAs' -Status 'Granted' -Detail '' } | Should -Throw
    }
}

Describe 'DryRun makes no changes' {

    It 'Reaches the Exchange cmdlets in a live run' {
        Mock Add-MailboxPermission { }
        Mock Add-RecipientPermission { }
        Mock Set-Mailbox { }
        Mock Add-MailboxFolderPermission { }
        Mock Set-MailboxFolderPermission { }
        Initialize-TestRun

        Add-MailboxAccessRight -Mailbox 'reception@newco.com' -Trustee 'john.smith@newco.com' -Kind FullAccess
        Add-MailboxAccessRight -Mailbox 'reception@newco.com' -Trustee 'john.smith@newco.com' -Kind SendAs
        Add-MailboxAccessRight -Mailbox 'reception@newco.com' -Trustee 'bea.kane@newco.com' -Kind SendOnBehalf
        Set-MailboxCalendarPermission -Mailbox 'john.smith@newco.com' -Trustee 'alice.dean@newco.com' `
            -AccessRights 'Editor' -Mode Add
        Set-MailboxCalendarPermission -Mailbox 'john.smith@newco.com' -Trustee 'alice.dean@newco.com' `
            -AccessRights 'Editor' -Mode Update
        Set-MailboxForwarding -Mailbox 'john.smith@newco.com' -ForwardingSmtpAddress 'team@fabrikam.com' `
            -DeliverToMailboxAndForward $true

        Should -Invoke Add-MailboxPermission -Times 1 -Exactly
        Should -Invoke Add-RecipientPermission -Times 1 -Exactly
        Should -Invoke Add-MailboxFolderPermission -Times 1 -Exactly
        Should -Invoke Set-MailboxFolderPermission -Times 1 -Exactly
        Should -Invoke Set-Mailbox -Times 2 -Exactly
    }

    It 'Calls no Exchange cmdlet when the run context is DryRun' {
        Mock Add-MailboxPermission { }
        Mock Add-RecipientPermission { }
        Mock Set-Mailbox { }
        Mock Add-MailboxFolderPermission { }
        Mock Set-MailboxFolderPermission { }
        Initialize-TestRun -DryRun

        Add-MailboxAccessRight -Mailbox 'reception@newco.com' -Trustee 'john.smith@newco.com' -Kind FullAccess
        Add-MailboxAccessRight -Mailbox 'reception@newco.com' -Trustee 'john.smith@newco.com' -Kind SendAs
        Add-MailboxAccessRight -Mailbox 'reception@newco.com' -Trustee 'bea.kane@newco.com' -Kind SendOnBehalf
        Set-MailboxCalendarPermission -Mailbox 'john.smith@newco.com' -Trustee 'alice.dean@newco.com' `
            -AccessRights 'Editor' -Mode Add
        Set-MailboxCalendarPermission -Mailbox 'john.smith@newco.com' -Trustee 'alice.dean@newco.com' `
            -AccessRights 'Editor' -Mode Update
        Set-MailboxForwarding -Mailbox 'john.smith@newco.com' -ForwardingSmtpAddress 'team@fabrikam.com' `
            -DeliverToMailboxAndForward $true

        Should -Invoke Add-MailboxPermission -Times 0 -Exactly
        Should -Invoke Add-RecipientPermission -Times 0 -Exactly
        Should -Invoke Add-MailboxFolderPermission -Times 0 -Exactly
        Should -Invoke Set-MailboxFolderPermission -Times 0 -Exactly
        Should -Invoke Set-Mailbox -Times 0 -Exactly
    }

    It 'Honours -AutoMapping $false on the FullAccess grant' {
        Mock Add-MailboxPermission { } -ParameterFilter { $AutoMapping -eq $false }
        Initialize-TestRun
        Add-MailboxAccessRight -Mailbox 'reception@newco.com' -Trustee 'john.smith@newco.com' `
            -Kind FullAccess -AutoMapping $false

        Should -Invoke Add-MailboxPermission -Times 1 -Exactly
    }

    It 'Does nothing when a forwarding call carries no destination' {
        Mock Set-Mailbox { }
        Initialize-TestRun
        Set-MailboxForwarding -Mailbox 'john.smith@newco.com'

        Should -Invoke Set-Mailbox -Times 0 -Exactly
    }

    It 'Produces Planned result rows for the permissions a DryRun would grant' {
        Initialize-TestRun -DryRun
        $diff = Get-PermissionDiff -Existing $script:ExistingFullAccess `
            -TrusteeIdentifier @('bea.kane@newco.com') -Kind FullAccess

        $rows = @(
            New-PermissionResult -Identity 'reception@newco.com' -Action 'FullAccess' -Status 'Planned' `
                -Detail 'Would grant FullAccess to bea.kane@newco.com.' -Trustee 'bea.kane@newco.com'
        )

        $diff.Action | Should -BeExactly 'Add'
        @($rows | Where-Object { $_.Status -ne 'Planned' }) | Should -BeNullOrEmpty
    }
}
