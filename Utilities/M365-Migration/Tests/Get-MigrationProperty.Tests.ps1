#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
    Set-StrictMode -Version Latest
}

Describe 'Get-MigrationProperty' {

    Context 'PSCustomObject input' {

        It 'Returns the value of a present property' {
            Get-MigrationProperty -InputObject ([pscustomobject]@{ id = 'abc' }) -Name 'id' |
                Should -BeExactly 'abc'
        }

        It 'Returns the default for an absent property under StrictMode' {
            Get-MigrationProperty -InputObject ([pscustomobject]@{ id = 'abc' }) -Name 'mail' -Default 'none' |
                Should -BeExactly 'none'
        }

        It 'Returns the default when the property is null' {
            Get-MigrationProperty -InputObject ([pscustomobject]@{ mail = $null }) -Name 'mail' -Default 'none' |
                Should -BeExactly 'none'
        }

        It 'Returns $null when no default is supplied' {
            Get-MigrationProperty -InputObject ([pscustomobject]@{ id = 'abc' }) -Name 'mail' |
                Should -BeNullOrEmpty
        }

        It 'Reads a note property added with Add-Member' {
            $object = [pscustomobject]@{ id = '1' }
            Add-Member -InputObject $object -NotePropertyName 'extra' -NotePropertyValue 'yes'
            Get-MigrationProperty -InputObject $object -Name 'extra' | Should -BeExactly 'yes'
        }

        It 'Matches the property name case-insensitively' {
            Get-MigrationProperty -InputObject ([pscustomobject]@{ userPrincipalName = 'a@contoso.com' }) `
                -Name 'UserPrincipalName' | Should -BeExactly 'a@contoso.com'
        }
    }

    Context 'Hashtable and dictionary input' {

        It 'Reads a hashtable key' {
            Get-MigrationProperty -InputObject @{ id = 'abc' } -Name 'id' | Should -BeExactly 'abc'
        }

        It 'Reads a hashtable key case-insensitively' {
            Get-MigrationProperty -InputObject @{ userPrincipalName = 'a@contoso.com' } -Name 'UserPrincipalName' |
                Should -BeExactly 'a@contoso.com'
        }

        It 'Returns the default for an absent hashtable key' {
            Get-MigrationProperty -InputObject @{ id = 'abc' } -Name 'mail' -Default 'none' |
                Should -BeExactly 'none'
        }

        It 'Reads an ordered dictionary' {
            Get-MigrationProperty -InputObject ([ordered]@{ id = 'abc' }) -Name 'id' | Should -BeExactly 'abc'
        }

        It 'Reads a generic Dictionary without binding to an explicit interface method' {
            $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new()
            $dictionary['id'] = 'abc'
            Get-MigrationProperty -InputObject $dictionary -Name 'id' | Should -BeExactly 'abc'
            Get-MigrationProperty -InputObject $dictionary -Name 'mail' -Default 'none' | Should -BeExactly 'none'
        }

        It 'Prefers an exact-case key when the dictionary holds both spellings' {
            $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new()
            $dictionary['Id'] = 'upper'
            $dictionary['id'] = 'lower'
            Get-MigrationProperty -InputObject $dictionary -Name 'id' | Should -BeExactly 'lower'
            Get-MigrationProperty -InputObject $dictionary -Name 'Id' | Should -BeExactly 'upper'
        }

        It 'Does not mistake a hashtable member for a key' {
            Get-MigrationProperty -InputObject @{ id = 'abc' } -Name 'Count' -Default 'none' |
                Should -BeExactly 'none'
        }
    }

    Context 'Raw values' {

        It 'Returns an array as an array' {
            $result = Get-MigrationProperty -InputObject ([pscustomobject]@{ addresses = @('a', 'b') }) -Name 'addresses'
            $result -is [System.Array] | Should -BeTrue
            $result | Should -HaveCount 2
        }

        It 'Returns an empty collection rather than the default' {
            # An empty array is a real value - the object has no addresses - and must not be
            # mistaken for an absent property. Ordinary PowerShell output semantics apply, so
            # a caller expecting a collection wraps the call in @(...).
            @(Get-MigrationProperty -InputObject ([pscustomobject]@{ addresses = @() }) -Name 'addresses' -Default 'none') |
                Should -HaveCount 0
        }

        It 'Returns $false rather than the default' {
            $result = Get-MigrationProperty -InputObject ([pscustomobject]@{ enabled = $false }) -Name 'enabled' -Default $true
            $result | Should -BeOfType [bool]
            $result | Should -BeFalse
        }

        It 'Returns an empty string rather than the default' {
            Get-MigrationProperty -InputObject ([pscustomobject]@{ mail = '' }) -Name 'mail' -Default 'none' |
                Should -BeExactly ''
        }

        It 'Returns a number without stringifying it' {
            $result = Get-MigrationProperty -InputObject @{ consumedUnits = 20 } -Name 'consumedUnits'
            $result | Should -BeOfType [int]
            $result | Should -Be 20
        }

        It 'Enumerates a single-element array as one item under @()' {
            @(Get-MigrationProperty -InputObject @{ addresses = @('only') } -Name 'addresses') |
                Should -HaveCount 1
        }

        It 'Enumerates an empty-array default as no items' {
            @(Get-MigrationProperty -InputObject ([pscustomobject]@{ id = '1' }) -Name 'addresses' -Default @()) |
                Should -HaveCount 0
        }

        It 'Returns a nested object intact' {
            $result = Get-MigrationProperty -InputObject ([pscustomobject]@{
                prepaidUnits = [pscustomobject]@{ enabled = 25 } }) -Name 'prepaidUnits'
            $result.enabled | Should -Be 25
        }
    }

    Context 'Never throws' {

        It 'Returns the default for a null input object' {
            Get-MigrationProperty -InputObject $null -Name 'id' -Default 'none' | Should -BeExactly 'none'
        }

        It 'Returns the default for a name no shape carries' {
            { Get-MigrationProperty -InputObject 'a plain string' -Name 'id' -Default 'none' } | Should -Not -Throw
            Get-MigrationProperty -InputObject 'a plain string' -Name 'id' -Default 'none' | Should -BeExactly 'none'
        }

        It 'Returns the default when the property getter itself throws' {
            $object = [pscustomobject]@{ id = '1' }
            Add-Member -InputObject $object -MemberType ScriptProperty -Name 'broken' -Value { throw 'no' }
            Get-MigrationProperty -InputObject $object -Name 'broken' -Default 'none' | Should -BeExactly 'none'
        }
    }
}
