#Requires -Version 7.4

<#
    Offline tests for Set-MigrationIdentity.ps1.

    How the script's own functions are reached
    ------------------------------------------
    The unit under test is a script, not a module, so dot-sourcing it would run the whole thing -
    connect to Graph, connect to Exchange, process a plan. Instead the file is parsed and only its
    FunctionDefinitionAst nodes are re-created here. That gives the functions without their Main
    region, needs no test-only switch on the script, and cannot drift from the file being shipped.

    How "DryRun calls nothing" is proved in Pester 6
    -----------------------------------------------
    Pester will only mock a command it can resolve, and Set-Mailbox does not exist on a machine
    without ExchangeOnlineManagement (nor on macOS at all). So a stub with the same parameter shape
    is declared in BeforeAll, and Pester mocks the stub. Functions and stubs declared in BeforeAll
    are visible to every It in the file, and the mutation scriptblocks the script builds are created
    in this same scope, so the mock is what they resolve. Initialize-MigrationRun -DryRun sets the
    module's run context, which is what Invoke-MigrationAction consults - the same code path a real
    -DryRun run takes.
#>

BeforeAll {
    $script:MigrationRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    Import-Module (Join-Path -Path $script:MigrationRoot -ChildPath 'M365Migration/M365Migration.psd1') -Force

    $script:ScriptPath = Join-Path -Path $script:MigrationRoot -ChildPath 'Set-MigrationIdentity.ps1'
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures/Set-MigrationIdentity'

    $parsed = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
    $definitions = $parsed.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    . ([scriptblock]::Create(($definitions.Extent.Text -join [Environment]::NewLine)))

    # Stubs for the Exchange cmdlets the script mutates through. Parameter names must match the
    # script's call sites or Pester's parameter filters would never bind.
    function Set-Mailbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub for a cmdlet that does not exist off Windows; Pester mocks it and the parameters only have to bind.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stub named after the real cmdlet so Pester can mock it; it has no body and changes nothing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
        Justification = 'Stub mirrors the real cmdlet signature, which takes -Confirm; it has no body and changes nothing.')]
        param($Identity, $EmailAddresses, $Alias, $HiddenFromAddressListsEnabled,
            $EmailAddressPolicyEnabled, $ErrorAction)
    }

    $script:TempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "SetMigrationIdentity-$([guid]::NewGuid())"

    function Initialize-TestRun {
        param([switch]$DryRun)
        $null = Initialize-MigrationRun -ScriptName 'Set-MigrationIdentity.Tests' -OutputPath $script:TempRoot `
            -Verbosity Low -DryRun:$DryRun
    }

    function Get-PlanRowStub {
        param([hashtable]$Value = @{})
        $row = New-MigrationPlanRow
        foreach ($key in $Value.Keys) { $row.$key = $Value[$key] }
        return $row
    }
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Split-AddressEntry and Test-ProtectedAddress' {

    It 'Treats an uppercase SMTP prefix as the primary and a lowercase one as an alias' {
        (Split-AddressEntry -Entry 'SMTP:john@contoso.com').IsPrimary | Should -BeTrue
        (Split-AddressEntry -Entry 'smtp:john@contoso.com').IsPrimary | Should -BeFalse
    }

    It 'Classifies SIP and X500 entries by their prefix' {
        (Split-AddressEntry -Entry 'SIP:john@contoso.com').Kind | Should -BeExactly 'Sip'
        (Split-AddressEntry -Entry 'X500:/o=ExchangeLabs/cn=x').Kind | Should -BeExactly 'X500'
        (Split-AddressEntry -Entry 'X500:/o=ExchangeLabs/cn=x').Address | Should -BeExactly '/o=ExchangeLabs/cn=x'
    }

    It 'Treats a bare address as an SMTP alias' {
        $entry = Split-AddressEntry -Entry 'john@contoso.com'
        $entry.Kind | Should -BeExactly 'Smtp'
        $entry.IsPrimary | Should -BeFalse
        $entry.Address | Should -BeExactly 'john@contoso.com'
    }

    It 'Protects the tenant routing address, SIP and X500' {
        foreach ($entry in @('smtp:john@newco.mail.onmicrosoft.com', 'SIP:john@contoso.com', 'X500:/o=x/cn=y')) {
            Test-ProtectedAddress -AddressEntry (Split-AddressEntry -Entry $entry) | Should -BeTrue -Because $entry
        }
    }

    It 'Does not protect an ordinary vanity address' {
        Test-ProtectedAddress -AddressEntry (Split-AddressEntry -Entry 'SMTP:john@contoso.com') | Should -BeFalse
    }
}

Describe 'Get-AddressChangeSet' {

    BeforeAll {
        $script:Current = @(
            'SMTP:jsmith@contoso.com'
            'smtp:john.smith@contoso.com'
            'smtp:jsmith@contoso.mail.onmicrosoft.com'
            'SIP:jsmith@contoso.com'
            'X500:/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=jsmith'
        )
    }

    Context 'Primary SMTP' {

        It 'Adds the new primary with an uppercase prefix and removes nothing' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp

            $change.Add | Should -Be @('SMTP:john.smith@newco.com')
            $change.RemoveBeforeAdd | Should -BeNullOrEmpty
            $change.RemoveAfterAdd | Should -BeNullOrEmpty
            $change.PrimaryChanged | Should -BeTrue
            $change.CurrentPrimary | Should -BeExactly 'jsmith@contoso.com'
        }

        It 'Reports no change when the primary already matches, whatever the casing' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetPrimarySmtp 'JSmith@Contoso.com' -Apply PrimarySmtp

            $change.PrimaryChanged | Should -BeFalse
            $change.Add | Should -BeNullOrEmpty
            $change.PrimaryDetail | Should -Match 'already'
        }

        It 'Releases an existing lowercase alias before promoting it to primary' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetPrimarySmtp 'john.smith@contoso.com' -Apply PrimarySmtp

            $change.RemoveBeforeAdd | Should -Be @('smtp:john.smith@contoso.com')
            $change.Add | Should -Be @('SMTP:john.smith@contoso.com')
        }

        It 'Removes the demoted old primary only when asked, and only after the add' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp -RemoveOldPrimaryAlias

            $change.RemoveAfterAdd | Should -Be @('smtp:jsmith@contoso.com')
            $change.RemoveBeforeAdd | Should -BeNullOrEmpty
        }

        It 'Never removes a tenant routing address even when it is the current primary' {
            $current = @('SMTP:jsmith@contoso.mail.onmicrosoft.com', 'smtp:jsmith@contoso.com')
            $change = Get-AddressChangeSet -CurrentAddress $current `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp -RemoveOldPrimaryAlias

            $change.RemoveAfterAdd | Should -BeNullOrEmpty
            $change.PrimaryDetail | Should -Match 'protected'
        }

        It 'Never emits a removal for a SIP or X500 address under any combination of switches' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetPrimarySmtp 'john.smith@newco.com' `
                -TargetAlias @('jsmith@newco.com') `
                -TargetX500 @('/o=First Organization/cn=Recipients/cn=jsmith') `
                -Apply PrimarySmtp, Aliases, X500 -RemoveOldPrimaryAlias

            $removals = @($change.RemoveBeforeAdd) + @($change.RemoveAfterAdd)
            @($removals | Where-Object { $_ -imatch '^(sip|x500):' }) | Should -BeNullOrEmpty
            @($removals | Where-Object { $_ -imatch 'onmicrosoft\.com$' }) | Should -BeNullOrEmpty
        }

        It 'Says so when the plan row carries no target primary' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current -Apply PrimarySmtp
            $change.PrimaryChanged | Should -BeFalse
            $change.PrimaryDetail | Should -Match 'no TargetPrimarySmtp'
        }
    }

    Context 'Aliases' {

        It 'Adds only the aliases that are missing' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetAlias @('john.smith@contoso.com', 'jsmith@newco.com', 'sales@newco.com') -Apply Aliases

            $change.AliasAdded | Should -Be @('jsmith@newco.com', 'sales@newco.com')
            $change.Add | Should -Be @('smtp:jsmith@newco.com', 'smtp:sales@newco.com')
        }

        It 'Accepts aliases with or without an smtp: prefix and ignores casing' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetAlias @('SMTP:JSmith@Contoso.com', 'smtp:sales@newco.com') -Apply Aliases

            $change.AliasAdded | Should -Be @('sales@newco.com')
        }

        It 'Does not add an alias that is about to become the primary' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetPrimarySmtp 'john.smith@newco.com' -TargetAlias @('john.smith@newco.com') `
                -Apply PrimarySmtp, Aliases

            $change.AliasAdded | Should -BeNullOrEmpty
            $change.Add | Should -Be @('SMTP:john.smith@newco.com')
        }
    }

    Context 'X500' {

        It 'Adds a missing X500 address and normalises the prefix' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetX500 @('X500:/o=First Organization/cn=Recipients/cn=jsmith') -Apply X500

            $change.Add | Should -Be @('X500:/o=First Organization/cn=Recipients/cn=jsmith')
            $change.X500Added.Count | Should -Be 1
        }

        It 'Skips an X500 address the object already carries' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetX500 @('/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=jsmith') -Apply X500

            $change.Add | Should -BeNullOrEmpty
            $change.X500Added | Should -BeNullOrEmpty
        }
    }

    Context 'Apply gating' {

        It 'Computes nothing for an operation that was not requested' {
            $change = Get-AddressChangeSet -CurrentAddress $script:Current `
                -TargetPrimarySmtp 'john.smith@newco.com' -TargetAlias @('sales@newco.com') `
                -TargetX500 @('/o=First Organization/cn=jsmith') -Apply PrimarySmtp

            $change.Add | Should -Be @('SMTP:john.smith@newco.com')
            $change.AliasAdded | Should -BeNullOrEmpty
            $change.X500Added | Should -BeNullOrEmpty
        }
    }
}

Describe 'Resolve-IdentityMatch' {

    BeforeAll {
        $script:FullRow = Get-PlanRowStub @{
            TargetObjectId           = 'bbbbbbbb-0000-0000-0000-000000000001'
            InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'
            SourceUserPrincipalName  = 'jsmith@contoso.com'
        }
    }

    It 'Prefers TargetObjectId, then Interim, then Source when no strategy is given' {
        (Resolve-IdentityMatch -Row $script:FullRow).MatchedBy | Should -BeExactly 'TargetObjectId'

        $noId = Get-PlanRowStub @{
            InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'
            SourceUserPrincipalName  = 'jsmith@contoso.com'
        }
        (Resolve-IdentityMatch -Row $noId).MatchedBy | Should -BeExactly 'Interim'

        $sourceOnly = Get-PlanRowStub @{ SourceUserPrincipalName = 'jsmith@contoso.com' }
        $match = Resolve-IdentityMatch -Row $sourceOnly
        $match.MatchedBy | Should -BeExactly 'Source'
        $match.Identity | Should -BeExactly 'jsmith@contoso.com'
    }

    It 'Flags an object id so the caller can address Graph by id rather than by UPN' {
        (Resolve-IdentityMatch -Row $script:FullRow).IsObjectId | Should -BeTrue
        (Resolve-IdentityMatch -Row $script:FullRow -Strategy 'Source').IsObjectId | Should -BeFalse
    }

    It 'Honours an explicit strategy even when an earlier column is populated' {
        $match = Resolve-IdentityMatch -Row $script:FullRow -Strategy 'Source'
        $match.Identity | Should -BeExactly 'jsmith@contoso.com'
        $match.MatchedBy | Should -BeExactly 'Source'
    }

    It 'Does not fall back when an explicit strategy names an empty column' {
        $row = Get-PlanRowStub @{ SourceUserPrincipalName = 'jsmith@contoso.com' }
        $match = Resolve-IdentityMatch -Row $row -Strategy 'TargetObjectId'

        $match.Identity | Should -BeNullOrEmpty
        $match.Detail | Should -Match 'TargetObjectId'
    }

    It 'Reports a row that carries no usable identifier at all' {
        $match = Resolve-IdentityMatch -Row (Get-PlanRowStub)
        $match.Identity | Should -BeNullOrEmpty
        $match.Detail | Should -Match 'No TargetObjectId'
    }
}

Describe 'Get-PlanX500' {

    It 'Promotes the LegacyExchangeDN to an X500 address' {
        $rows = Import-MigrationPlan -Path (Join-Path -Path $script:FixtureRoot -ChildPath 'IdentityPlan.csv')
        $row = @($rows | Where-Object { $_.SourceUserPrincipalName -eq 'jsmith@contoso.com' })[0]

        # A single-element [string[]] unrolls on return, so the caller - and this test - wrap it.
        $x500 = @(Get-PlanX500 -Row $row)
        $x500.Count | Should -Be 1
        $x500[0] | Should -BeLike '/o=ExchangeLabs/*'
    }

    It 'Strips an X500 prefix already present on SourceX500' {
        $rows = Import-MigrationPlan -Path (Join-Path -Path $script:FixtureRoot -ChildPath 'IdentityPlan.csv')
        $row = @($rows | Where-Object { $_.SourceUserPrincipalName -eq 'bkane@contoso.com' })[0]

        @(Get-PlanX500 -Row $row)[0] |
            Should -BeExactly '/o=First Organization/ou=Exchange Administrative Group/cn=Recipients/cn=bkane'
    }

    It 'Returns nothing for a row with neither column' {
        Get-PlanX500 -Row (Get-PlanRowStub) | Should -BeNullOrEmpty
    }
}

Describe 'Get-RowBlock' {

    BeforeAll {
        $script:Actionable = @('Planned', 'ManualOverride', 'UpnSmtpDiverge')
        $script:Supported = @('User', 'Shared', 'Room', 'Equipment')
    }

    It 'Lets an actionable mailbox row through' {
        $block = Get-RowBlock -PlanStatus 'Planned' -ObjectType 'User' `
            -ActionableStatus $script:Actionable -SupportedObjectType $script:Supported
        $block.IsBlocked | Should -BeFalse
    }

    It 'Skips a plan status the run is not acting on and names it' {
        $block = Get-RowBlock -PlanStatus 'NeedsReview' -ObjectType 'User' `
            -ActionableStatus $script:Actionable -SupportedObjectType $script:Supported

        $block.IsBlocked | Should -BeTrue
        $block.Status | Should -BeExactly 'Skipped'
        $block.Detail | Should -Match 'NeedsReview'
    }

    It 'Skips a group or contact and points at New-MigrationRecipients' {
        $block = Get-RowBlock -PlanStatus 'Planned' -ObjectType 'Distribution' `
            -ActionableStatus $script:Actionable -SupportedObjectType $script:Supported

        $block.Status | Should -BeExactly 'Skipped'
        $block.Detail | Should -Match 'New-MigrationRecipients'
    }

    It 'Fails rather than skips a row nothing could identify' {
        $block = Get-RowBlock -PlanStatus 'Planned' -ObjectType 'User' `
            -ActionableStatus $script:Actionable -SupportedObjectType $script:Supported `
            -MatchDetail 'No TargetObjectId, InterimUserPrincipalName or SourceUserPrincipalName.'

        $block.Status | Should -BeExactly 'Failed'
    }

    It 'Hard-stops a directory-synced object with an actionable explanation' {
        $block = Get-RowBlock -PlanStatus 'Planned' -ObjectType 'User' `
            -ActionableStatus $script:Actionable -SupportedObjectType $script:Supported -IsSynced $true

        $block.IsBlocked | Should -BeTrue
        $block.Status | Should -BeExactly 'Failed'
        $block.Detail | Should -Match 'onPremisesSyncEnabled'
        $block.Detail | Should -Match 'on-premises'
    }

    It 'Reports the plan status before the sync state, so the more specific reason wins' {
        $block = Get-RowBlock -PlanStatus 'Excluded' -ObjectType 'User' `
            -ActionableStatus $script:Actionable -SupportedObjectType $script:Supported -IsSynced $true
        $block.Status | Should -BeExactly 'Skipped'
    }

    It 'Hard-stops the synced row in the plan fixture' {
        $rows = Import-MigrationPlan -Path (Join-Path -Path $script:FixtureRoot -ChildPath 'IdentityPlan.csv')
        $row = @($rows | Where-Object { $_.SourceUserPrincipalName -eq 'csynced@contoso.com' })[0]

        $row.IsSynced | Should -BeExactly 'True'
        $block = Get-RowBlock -PlanStatus $row.PlanStatus -ObjectType $row.ObjectType `
            -ActionableStatus $script:Actionable -SupportedObjectType $script:Supported `
            -IsSynced ([bool]::Parse($row.IsSynced))
        $block.Status | Should -BeExactly 'Failed'
    }
}

Describe 'Get-UpnFailureDetail' {

    It 'Appends the Privileged Authentication Administrator hint to a 403' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).'),
            'Forbidden', 'PermissionDenied', $null)

        $detail = Get-UpnFailureDetail -ErrorRecord $record -PrivilegedHint 'PRIVILEGED-HINT' -ConflictHint 'CONFLICT-HINT'
        $detail | Should -Match 'PRIVILEGED-HINT'
    }

    It 'Appends the soft-deleted-user hint to a 409' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Another object with the same value already exists (409).'),
            'Conflict', 'InvalidOperation', $null)

        Get-UpnFailureDetail -ErrorRecord $record -PrivilegedHint 'PRIVILEGED-HINT' -ConflictHint 'CONFLICT-HINT' |
            Should -Match 'CONFLICT-HINT'
    }

    It 'Leaves an unrecognised failure alone' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('The remote server timed out.'), 'Timeout', 'OperationTimeout', $null)

        $detail = Get-UpnFailureDetail -ErrorRecord $record -PrivilegedHint 'PRIVILEGED-HINT' -ConflictHint 'CONFLICT-HINT'
        $detail | Should -BeExactly 'The remote server timed out.'
    }
}

Describe 'New-IdentityResult' {

    It 'Leads with the four standard columns in the contract order' {
        $row = New-IdentityResult -Identity 'john.smith@newco.com' -Action 'Upn' -Status 'Planned' -Detail 'Would set.'
        @($row.PSObject.Properties.Name)[0..3] | Should -Be @('Identity', 'Action', 'Status', 'Detail')
    }

    It 'Carries the object type and wave through from the plan row' {
        $planRow = Get-PlanRowStub @{ ObjectType = 'Shared'; Wave = '2' }
        $row = New-IdentityResult -Identity 'reception@newco.com' -Action 'Aliases' -Status 'Skipped' `
            -Detail 'Already present.' -Row $planRow

        $row.ObjectType | Should -BeExactly 'Shared'
        $row.Wave | Should -BeExactly '2'
    }

    It 'Rejects a status outside the contract' {
        { New-IdentityResult -Identity 'x' -Action 'Upn' -Status 'Updated' -Detail '' } | Should -Throw
    }
}

Describe 'DryRun makes no changes' {

    It 'Reaches Set-Mailbox in a live run' {
        Mock Set-Mailbox { }
        Initialize-TestRun
        Set-MailboxAddress -Identity 'john.smith@newco.com' -Address @('SMTP:john.smith@newco.com') -Operation Add

        Should -Invoke Set-Mailbox -Times 1 -Exactly
    }

    It 'Calls no Exchange cmdlet when the run context is DryRun' {
        Mock Set-Mailbox { }
        Initialize-TestRun -DryRun

        Set-MailboxAddress -Identity 'john.smith@newco.com' -Address @('SMTP:john.smith@newco.com') -Operation Add
        Set-MailboxAddress -Identity 'john.smith@newco.com' -Address @('smtp:jsmith@contoso.com') -Operation Remove
        Set-MailboxAttribute -Identity 'john.smith@newco.com' -Name 'Alias' -Value 'john.smith' -Description 'Set alias'
        Set-MailboxAttribute -Identity 'john.smith@newco.com' -Name 'HiddenFromAddressListsEnabled' -Value $true `
            -Description 'Hide from the GAL'

        Should -Invoke Set-Mailbox -Times 0 -Exactly
    }

    It 'Does nothing at all for an empty address list' {
        Mock Set-Mailbox { }
        Initialize-TestRun
        Set-MailboxAddress -Identity 'john.smith@newco.com' -Address @() -Operation Add

        Should -Invoke Set-Mailbox -Times 0 -Exactly
    }

    It 'Sends the add and remove buckets as the hashtable Exchange expects' {
        Mock Set-Mailbox { } -ParameterFilter {
            $EmailAddresses -is [hashtable] -and $EmailAddresses.ContainsKey('Add') -and
            $EmailAddresses['Add'] -contains 'X500:/o=First Organization/cn=jsmith'
        }
        Initialize-TestRun
        Set-MailboxAddress -Identity 'john.smith@newco.com' `
            -Address @('X500:/o=First Organization/cn=jsmith') -Operation Add

        Should -Invoke Set-Mailbox -Times 1 -Exactly
    }

    It 'Produces Planned result rows for the operations a DryRun would perform' {
        Initialize-TestRun -DryRun
        $change = Get-AddressChangeSet -CurrentAddress @('SMTP:jsmith@contoso.com') `
            -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp

        $rows = @(
            New-IdentityResult -Identity 'john.smith@newco.com' -Action 'PrimarySmtp' -Status 'Planned' `
                -Detail $change.PrimaryDetail -TargetValue $change.NewPrimary
        )

        @($rows | Where-Object { $_.Status -ne 'Planned' }) | Should -BeNullOrEmpty
        $rows[0].TargetValue | Should -BeExactly 'john.smith@newco.com'
    }
}
