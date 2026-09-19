#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
    Set-StrictMode -Version Latest

    # A mailbox mid-migration: a vanity primary, a vanity alias, the tenant routing
    # address, the Teams SIP address, the SharePoint address and an X500 from an earlier
    # move. Everything except the two vanity addresses is protected.
    $script:currentAddresses = @(
        'SMTP:jsmith@contoso.com'
        'smtp:j.smith@contoso.com'
        'smtp:jsmith@contoso.mail.onmicrosoft.com'
        'SIP:jsmith@contoso.com'
        'SPO:SPO_1111@SPO_2222'
        'X500:/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=old'
    )

    $script:protectedEntries = @(
        'smtp:jsmith@contoso.mail.onmicrosoft.com'
        'jsmith@contoso.mail.onmicrosoft.com'
        'SIP:jsmith@contoso.com'
        'sip:jsmith@contoso.com'
        'SPO:SPO_1111@SPO_2222'
        'X500:/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=old'
    )

    function Get-AllRemoval {
        param($ChangeSet)
        return @(@($ChangeSet.RemoveBeforeAdd) + @($ChangeSet.RemoveAfterAdd))
    }
}

Describe 'Get-MigrationAddressChangeSet' {

    Context 'Protected addresses are never removed' {

        It 'Removes nothing protected when the primary changes' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp
            $removals = Get-AllRemoval -ChangeSet $changeSet
            foreach ($entry in $script:protectedEntries) {
                $removals | Should -Not -Contain $entry
            }
        }

        It 'Removes nothing protected even with -RemoveOldPrimary' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' -TargetAlias @('jsmith@newco.com') `
                -TargetX500 @('/o=ExchangeLabs/cn=Recipients/cn=new') -RemoveOldPrimary
            $removals = Get-AllRemoval -ChangeSet $changeSet
            foreach ($entry in $script:protectedEntries) {
                $removals | Should -Not -Contain $entry
            }
        }

        It 'Keeps the tenant routing address when it is the current primary' {
            $changeSet = Get-MigrationAddressChangeSet `
                -CurrentAddress @('SMTP:jsmith@contoso.mail.onmicrosoft.com', 'SIP:jsmith@contoso.com') `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp -RemoveOldPrimary
            @($changeSet.RemoveAfterAdd) | Should -HaveCount 0
            $changeSet.PrimaryDetail | Should -BeLike '*protected address*'
        }

        It 'Never removes an existing X500 entry, even one the plan does not carry' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' `
                -TargetX500 @('/o=ExchangeLabs/cn=Recipients/cn=new') -RemoveOldPrimary
            $removals = Get-AllRemoval -ChangeSet $changeSet
            @($removals | Where-Object { $_ -imatch '^x500:' }) | Should -HaveCount 0
        }

        It 'Never removes a SIP or SPO entry, whatever is applied' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' `
                -TargetAlias @('j.smith@newco.com') -RemoveOldPrimary
            $removals = Get-AllRemoval -ChangeSet $changeSet
            @($removals | Where-Object { $_ -imatch '^(sip|spo):' }) | Should -HaveCount 0
        }

        It 'Keeps the routing address on the object when it is being promoted to primary' {
            # Promoting an address the object already carries removes nothing at all: the whole
            # address list is rewritten in one call, with the alias recased to the uppercase
            # primary prefix, so the address is never absent from the object.
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'jsmith@contoso.mail.onmicrosoft.com' -Apply PrimarySmtp
            $changeSet.PromoteInPlace | Should -BeTrue
            (Get-AllRemoval -ChangeSet $changeSet) | Should -HaveCount 0
            @($changeSet.Add) | Should -HaveCount 0
            @($changeSet.ReplaceWith) | Should -BeExactly @(
                'smtp:jsmith@contoso.com'
                'smtp:j.smith@contoso.com'
                'SMTP:jsmith@contoso.mail.onmicrosoft.com'
                'SIP:jsmith@contoso.com'
                'SPO:SPO_1111@SPO_2222'
                'X500:/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=old'
            )
        }
    }

    Context 'Demoting the old primary' {

        It 'Leaves the old primary in place by default' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp
            $changeSet.CurrentPrimary | Should -BeExactly 'jsmith@contoso.com'
            $changeSet.NewPrimary | Should -BeExactly 'john.smith@newco.com'
            $changeSet.PrimaryChanged | Should -BeTrue
            @($changeSet.RemoveAfterAdd) | Should -HaveCount 0
            (Get-AllRemoval -ChangeSet $changeSet) | Should -Not -Contain 'smtp:jsmith@contoso.com'
        }

        It 'Removes the demoted primary with -RemoveOldPrimary' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp -RemoveOldPrimary
            @($changeSet.RemoveAfterAdd) | Should -Be @('smtp:jsmith@contoso.com')
            $changeSet.PrimaryDetail | Should -BeLike '*Removed the demoted jsmith@contoso.com*'
        }

        It 'Removes the old primary only after the new one is added' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp -RemoveOldPrimary
            @($changeSet.RemoveBeforeAdd) | Should -Not -Contain 'smtp:jsmith@contoso.com'
        }

        It 'Changes nothing when the primary already matches' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'jsmith@contoso.com' -Apply PrimarySmtp -RemoveOldPrimary
            $changeSet.PrimaryChanged | Should -BeFalse
            @($changeSet.Add) | Should -HaveCount 0
            (Get-AllRemoval -ChangeSet $changeSet) | Should -HaveCount 0
            $changeSet.PrimaryDetail | Should -BeLike '*already jsmith@contoso.com*'
        }

        It 'Says so when the plan row carries no target primary' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp '' -Apply PrimarySmtp
            $changeSet.PrimaryChanged | Should -BeFalse
            $changeSet.PrimaryDetail | Should -BeLike '*no TargetPrimarySmtp*'
        }
    }

    Context 'Promoting an address the object already carries' {

        BeforeAll {
            # The mailbox already holds the vanity address as a lowercase alias - the case that
            # used to be applied as a Remove followed by an Add, leaving the address absent from
            # the mailbox if the Add failed.
            $script:heldAddresses = @('SMTP:old@c.com', 'smtp:new@n.com', 'X500:/o=x')
        }

        It 'Rewrites the whole list in one call rather than releasing the alias first' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:heldAddresses `
                -TargetPrimarySmtp 'new@n.com' -Apply PrimarySmtp
            $changeSet.PromoteInPlace | Should -BeTrue
            $changeSet.PrimaryChanged | Should -BeTrue
            @($changeSet.RemoveBeforeAdd) | Should -HaveCount 0
            @($changeSet.Add) | Should -HaveCount 0
            @($changeSet.RemoveAfterAdd) | Should -HaveCount 0
            @($changeSet.ReplaceWith) | Should -BeExactly @('smtp:old@c.com', 'SMTP:new@n.com', 'X500:/o=x')
        }

        It 'Drops the demoted old primary from the replacement list with -RemoveOldPrimary' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:heldAddresses `
                -TargetPrimarySmtp 'new@n.com' -Apply PrimarySmtp -RemoveOldPrimary
            @($changeSet.ReplaceWith) | Should -BeExactly @('SMTP:new@n.com', 'X500:/o=x')
            @($changeSet.RemoveAfterAdd) | Should -HaveCount 0
            $changeSet.PrimaryDetail | Should -BeLike '*Removed the demoted old@c.com*'
        }

        It 'Keeps a protected old primary in the replacement list even with -RemoveOldPrimary' {
            $changeSet = Get-MigrationAddressChangeSet `
                -CurrentAddress @('SMTP:jsmith@contoso.mail.onmicrosoft.com', 'smtp:new@n.com') `
                -TargetPrimarySmtp 'new@n.com' -Apply PrimarySmtp -RemoveOldPrimary
            @($changeSet.ReplaceWith) | Should -BeExactly @(
                'smtp:jsmith@contoso.mail.onmicrosoft.com'
                'SMTP:new@n.com'
            )
            $changeSet.PrimaryDetail | Should -BeLike '*protected address*'
        }

        It 'Leaves every entry it does not touch exactly as it found it' {
            # Exchange compares addresses case-insensitively, but the operator reads this list
            # back, so only the two SMTP entries the promotion touches are recased.
            $changeSet = Get-MigrationAddressChangeSet `
                -CurrentAddress @('SMTP:Old@C.com', 'smtp:New@N.com', 'SIP:Old@C.com', 'X500:/o=X/cn=ABC') `
                -TargetPrimarySmtp 'new@n.com' -Apply PrimarySmtp
            @($changeSet.ReplaceWith) | Should -BeExactly @(
                'smtp:Old@C.com'
                'SMTP:new@n.com'
                'SIP:Old@C.com'
                'X500:/o=X/cn=ABC'
            )
        }

        It 'Adds the primary the old way when the object does not already carry it' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @('SMTP:old@c.com', 'X500:/o=x') `
                -TargetPrimarySmtp 'new@n.com' -Apply PrimarySmtp
            $changeSet.PromoteInPlace | Should -BeFalse
            @($changeSet.Add) | Should -BeExactly @('SMTP:new@n.com')
            @($changeSet.ReplaceWith) | Should -HaveCount 0
        }

        It 'Promotes in place and still reports the aliases and X500 entries to add' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:heldAddresses `
                -TargetPrimarySmtp 'new@n.com' -TargetAlias @('spare@n.com') -TargetX500 @('/o=y')
            $changeSet.PromoteInPlace | Should -BeTrue
            @($changeSet.ReplaceWith) | Should -BeExactly @('smtp:old@c.com', 'SMTP:new@n.com', 'X500:/o=x')
            # The primary is carried by ReplaceWith, so only the later buckets remain in Add.
            @($changeSet.Add) | Should -BeExactly @('smtp:spare@n.com', 'X500:/o=y')
        }

        It 'Reports PromoteInPlace false when PrimarySmtp is not applied' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:heldAddresses `
                -TargetPrimarySmtp 'new@n.com' -TargetAlias @('spare@n.com') -Apply Aliases
            $changeSet.PromoteInPlace | Should -BeFalse
            @($changeSet.ReplaceWith) | Should -HaveCount 0
        }

        It 'Never emits RemoveBeforeAdd, whatever the change set' {
            # Kept on the output object for compatibility with callers written against the older
            # two-call shape; it is always empty now.
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'j.smith@contoso.com' -TargetAlias @('spare@newco.com') -RemoveOldPrimary
            @($changeSet.RemoveBeforeAdd) | Should -HaveCount 0
        }
    }

    Context 'Adding aliases and X500 entries' {

        It 'Adds only the aliases the object does not already carry' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetAlias @('j.smith@contoso.com', 'john.smith@newco.com', 'jsmith@newco.com') `
                -Apply Aliases
            @($changeSet.Add) | Should -Be @('smtp:john.smith@newco.com', 'smtp:jsmith@newco.com')
            @($changeSet.AliasAdded) | Should -Be @('john.smith@newco.com', 'jsmith@newco.com')
        }

        It 'Does not add the new primary again as an alias' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' -TargetAlias @('john.smith@newco.com', 'jsmith@newco.com')
            @($changeSet.AliasAdded) | Should -Be @('jsmith@newco.com')
        }

        It 'Deduplicates repeated aliases in the plan' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @() `
                -TargetAlias @('a@newco.com', 'A@NEWCO.COM') -Apply Aliases
            @($changeSet.Add) | Should -Be @('smtp:a@newco.com')
        }

        It 'Adds missing X500 entries and skips the ones already present' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetX500 @(
                    '/o=ExchangeLabs/ou=Exchange Administrative Group/cn=Recipients/cn=old'
                    'X500:/o=ExchangeLabs/cn=Recipients/cn=new'
                ) -Apply X500
            @($changeSet.Add) | Should -Be @('X500:/o=ExchangeLabs/cn=Recipients/cn=new')
            @($changeSet.X500Added) | Should -Be @('/o=ExchangeLabs/cn=Recipients/cn=new')
        }

        It 'Orders the change set primary, then aliases, then X500' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' -TargetAlias @('jsmith@newco.com') `
                -TargetX500 @('/o=ExchangeLabs/cn=Recipients/cn=new')
            @($changeSet.Add) | Should -Be @(
                'SMTP:john.smith@newco.com'
                'smtp:jsmith@newco.com'
                'X500:/o=ExchangeLabs/cn=Recipients/cn=new'
            )
        }

        It 'Honours -Apply, ignoring the parts it was not asked for' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress $script:currentAddresses `
                -TargetPrimarySmtp 'john.smith@newco.com' -TargetAlias @('jsmith@newco.com') `
                -TargetX500 @('/o=x/cn=new') -Apply @('Aliases')
            @($changeSet.Add) | Should -Be @('smtp:jsmith@newco.com')
            $changeSet.PrimaryChanged | Should -BeFalse
        }

        It 'Rejects an unknown -Apply value' {
            { Get-MigrationAddressChangeSet -CurrentAddress @() -Apply @('Nickname') } |
                Should -Throw -ExpectedMessage '*Unknown -Apply value*'
        }
    }

    Context 'Case handling' {

        It 'Treats the target primary as already set whatever its casing' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @('SMTP:JSmith@Contoso.com') `
                -TargetPrimarySmtp 'jsmith@contoso.COM' -Apply PrimarySmtp
            $changeSet.PrimaryChanged | Should -BeFalse
            @($changeSet.Add) | Should -HaveCount 0
        }

        It 'Does not re-add an alias that differs only by case' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @('smtp:J.Smith@Contoso.com') `
                -TargetAlias @('j.smith@contoso.com') -Apply Aliases
            @($changeSet.Add) | Should -HaveCount 0
        }

        It 'Does not re-add an X500 entry that differs only by case' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @('X500:/o=ExchangeLabs/cn=ABC') `
                -TargetX500 @('/o=exchangelabs/cn=abc') -Apply X500
            @($changeSet.Add) | Should -HaveCount 0
        }

        It 'Writes the new primary with an uppercase SMTP prefix and aliases lowercase' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @('SMTP:jsmith@contoso.com') `
                -TargetPrimarySmtp 'John.Smith@NewCo.com' -TargetAlias @('JSmith@NewCo.com')
            $changeSet.Add[0] | Should -BeExactly 'SMTP:John.Smith@NewCo.com'
            $changeSet.Add[1] | Should -BeExactly 'smtp:JSmith@NewCo.com'
        }

        It 'Accepts a target primary that already carries an smtp: prefix in any case' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @('SMTP:jsmith@contoso.com') `
                -TargetPrimarySmtp 'SmTp:john.smith@newco.com' -Apply PrimarySmtp
            @($changeSet.Add) | Should -Be @('SMTP:john.smith@newco.com')
        }

        It 'Recognises a lowercase smtp: entry holding the wanted address as an alias, not the primary' {
            $changeSet = Get-MigrationAddressChangeSet `
                -CurrentAddress @('SMTP:jsmith@contoso.com', 'smtp:John.Smith@NewCo.com') `
                -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp
            $changeSet.PromoteInPlace | Should -BeTrue
            # The promoted entry is written with the plan's casing, exactly as the add case does.
            @($changeSet.ReplaceWith) | Should -BeExactly @('smtp:jsmith@contoso.com', 'SMTP:john.smith@newco.com')
        }
    }

    Context 'Edge cases' {

        It 'Handles an object with no addresses at all' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @() -TargetPrimarySmtp 'john@newco.com'
            $changeSet.CurrentPrimary | Should -BeExactly ''
            @($changeSet.Add) | Should -Be @('SMTP:john@newco.com')
        }

        It 'Handles an object with no primary at all' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @('smtp:a@contoso.com') `
                -TargetPrimarySmtp 'john@newco.com' -Apply PrimarySmtp -RemoveOldPrimary
            $changeSet.CurrentPrimary | Should -BeExactly ''
            @($changeSet.RemoveAfterAdd) | Should -HaveCount 0
        }

        It 'Ignores blank entries in the current address list and the plan' {
            $changeSet = Get-MigrationAddressChangeSet -CurrentAddress @('', '   ', 'SMTP:a@contoso.com') `
                -TargetAlias @('', 'b@newco.com') -Apply Aliases
            @($changeSet.Add) | Should -Be @('smtp:b@newco.com')
        }
    }
}
