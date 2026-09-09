#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
    Set-StrictMode -Version Latest

    $script:planRows = @(
        [pscustomobject]@{
            SourceObjectId           = '11111111-1111-1111-1111-111111111111'
            SourceUserPrincipalName  = 'jsmith@contoso.com'
            SourcePrimarySmtp        = 'john.smith@contoso.com'
            SourceAliases            = 'smtp:js@contoso.com;smtp:j.smith@contoso.com'
            DisplayName              = 'John Smith'
            InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'
            InterimPrimarySmtp       = 'john.smith@newco.onmicrosoft.com'
            TargetUserPrincipalName  = 'john.smith@newco.com'
            TargetPrimarySmtp        = 'john.smith@newco.com'
        }
        [pscustomobject]@{
            SourceObjectId           = '22222222-2222-2222-2222-222222222222'
            SourceUserPrincipalName  = 'ajones@contoso.com'
            SourcePrimarySmtp        = ''
            SourceAliases            = ''
            DisplayName              = 'Anne Jones'
            InterimUserPrincipalName = ''
            InterimPrimarySmtp       = ''
            TargetUserPrincipalName  = 'anne.jones@newco.com'
            TargetPrimarySmtp        = ''
        }
    )
}

Describe 'Get-MigrationPlanAddressMap' {

    It 'Registers every source form as a key onto the target primary' {
        $map = Get-MigrationPlanAddressMap -Rows $script:planRows
        foreach ($key in @(
            '11111111-1111-1111-1111-111111111111'
            'jsmith@contoso.com'
            'john.smith@contoso.com'
            'js@contoso.com'
            'j.smith@contoso.com'
            'John Smith'
        )) {
            $map[$key] | Should -BeExactly 'john.smith@newco.com'
        }
    }

    It 'Strips the smtp: prefix from alias keys' {
        $map = Get-MigrationPlanAddressMap -Rows $script:planRows
        $map.ContainsKey('smtp:js@contoso.com') | Should -BeFalse
        $map.ContainsKey('js@contoso.com') | Should -BeTrue
    }

    It 'Matches keys case-insensitively' {
        $map = Get-MigrationPlanAddressMap -Rows $script:planRows
        $map['JSMITH@CONTOSO.COM'] | Should -BeExactly 'john.smith@newco.com'
    }

    It 'Falls back to TargetUserPrincipalName when TargetPrimarySmtp is empty' {
        $map = Get-MigrationPlanAddressMap -Rows $script:planRows
        $map['ajones@contoso.com'] | Should -BeExactly 'anne.jones@newco.com'
    }

    It 'Prefers the interim addresses with -UseInterim' {
        $map = Get-MigrationPlanAddressMap -Rows $script:planRows -UseInterim
        $map['jsmith@contoso.com'] | Should -BeExactly 'john.smith@newco.onmicrosoft.com'
    }

    It 'Falls back to the target addresses with -UseInterim when no interim exists' {
        $map = Get-MigrationPlanAddressMap -Rows $script:planRows -UseInterim
        $map['ajones@contoso.com'] | Should -BeExactly 'anne.jones@newco.com'
    }

    It 'Skips a row with no destination address at all' {
        $map = Get-MigrationPlanAddressMap -Rows @([pscustomobject]@{ SourceUserPrincipalName = 'x@contoso.com' })
        $map.ContainsKey('x@contoso.com') | Should -BeFalse
    }

    It 'Lets the first row keep a duplicate key rather than hiding the collision' {
        $rows = @(
            [pscustomobject]@{ SourceUserPrincipalName = 'dup@contoso.com'; TargetPrimarySmtp = 'first@newco.com' }
            [pscustomobject]@{ SourceUserPrincipalName = 'dup@contoso.com'; TargetPrimarySmtp = 'second@newco.com' }
        )
        (Get-MigrationPlanAddressMap -Rows $rows)['dup@contoso.com'] | Should -BeExactly 'first@newco.com'
    }

    It 'Returns an empty map for no rows' {
        (Get-MigrationPlanAddressMap -Rows @()).Count | Should -Be 0
    }

    It 'Tolerates rows missing every optional column under StrictMode' {
        { Get-MigrationPlanAddressMap -Rows @([pscustomobject]@{ TargetPrimarySmtp = 'a@newco.com' }) } |
            Should -Not -Throw
    }
}

Describe 'Resolve-MigrationPlanAddress' {

    BeforeAll {
        $script:map = Get-MigrationPlanAddressMap -Rows $script:planRows
    }

    It 'Maps a source address to its destination' {
        $result = Resolve-MigrationPlanAddress -Map $script:map -Address 'jsmith@contoso.com' -Role trustee
        $result.IsMapped | Should -BeTrue
        $result.Address | Should -BeExactly 'john.smith@newco.com'
        $result.Source | Should -BeExactly 'jsmith@contoso.com'
        $result.Detail | Should -BeExactly ''
    }

    It 'Strips an smtp: prefix before the lookup' {
        (Resolve-MigrationPlanAddress -Map $script:map -Address 'SMTP:jsmith@contoso.com').IsMapped | Should -BeTrue
    }

    It 'Reports an unmapped address rather than throwing, naming the role' {
        $result = Resolve-MigrationPlanAddress -Map $script:map -Address 'gone@contoso.com' -Role trustee
        $result.IsMapped | Should -BeFalse
        $result.Address | Should -BeExactly ''
        $result.Detail | Should -BeExactly "The plan has no destination address for the trustee 'gone@contoso.com'."
    }

    It 'Reports a blank address, naming the role' {
        $result = Resolve-MigrationPlanAddress -Map $script:map -Address '   ' -Role mailbox
        $result.IsMapped | Should -BeFalse
        $result.Detail | Should -BeExactly 'The row has no mailbox address.'
    }

    It 'Defaults the role to object' {
        (Resolve-MigrationPlanAddress -Map $script:map -Address '').Detail | Should -BeExactly 'The row has no object address.'
    }

    It 'Trims the address before the lookup' {
        (Resolve-MigrationPlanAddress -Map $script:map -Address '  jsmith@contoso.com  ').IsMapped | Should -BeTrue
    }
}
