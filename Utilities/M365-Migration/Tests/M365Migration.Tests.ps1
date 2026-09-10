#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    $script:modulePath = Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1'
    $script:moduleRoot = Split-Path -Path $script:modulePath -Parent
    Import-Module $script:modulePath -Force
}

Describe 'M365Migration manifest' {

    It 'Is a valid manifest at version 1.1.1' {
        $manifest = Test-ModuleManifest -Path $script:modulePath -ErrorAction Stop
        $manifest.Version.ToString() | Should -BeExactly '1.1.1'
        $manifest.PowerShellVersion.ToString() | Should -BeExactly '7.4'
    }

    It 'Exports exactly the functions in Public, and nothing from Private' {
        $public = @(Get-ChildItem -Path (Join-Path $script:moduleRoot 'Public') -Filter '*.ps1' | ForEach-Object BaseName)
        $exported = @((Get-Module M365Migration).ExportedFunctions.Keys)
        $exported | Sort-Object | Should -Be ($public | Sort-Object)

        $private = @(Get-ChildItem -Path (Join-Path $script:moduleRoot 'Private') -Filter '*.ps1' | ForEach-Object BaseName)
        foreach ($name in $private) { $exported | Should -Not -Contain $name }
    }

    It 'Lists every exported function in FunctionsToExport' {
        $manifest = Import-PowerShellDataFile -Path $script:modulePath
        $exported = @((Get-Module M365Migration).ExportedFunctions.Keys)
        @($manifest.FunctionsToExport) | Sort-Object | Should -Be ($exported | Sort-Object)
    }

    It 'Exports <Name>, promoted from Private in 1.1.0' -ForEach @(
        @{ Name = 'New-MigrationPassphrase' }
        @{ Name = 'New-MigrationRandomPassword' }
        @{ Name = 'Get-MigrationTeamsPolicyName' }
        @{ Name = 'Split-MigrationTeamsLineUri' }
        @{ Name = 'Format-MigrationE164' }
        @{ Name = 'Resolve-MigrationTeamsUser' }
        @{ Name = 'Get-MigrationGraphErrorStatusCode' }
    ) {
        Get-Command -Module M365Migration -Name $Name -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    It 'Exports <Name>, new in 1.1.0' -ForEach @(
        @{ Name = 'ConvertTo-MigrationX500' }
        @{ Name = 'Export-MigrationReport' }
        @{ Name = 'Get-MigrationAddressChangeSet' }
        @{ Name = 'Get-MigrationPhoneNumberInventory' }
        @{ Name = 'Get-MigrationPlanAddressMap' }
        @{ Name = 'Get-MigrationProperty' }
        @{ Name = 'Get-MigrationRunContext' }
        @{ Name = 'Resolve-MigrationPlanAddress' }
        @{ Name = 'Split-MigrationProxyAddress' }
        @{ Name = 'Test-MigrationPlanRowActionable' }
        @{ Name = 'Test-MigrationProtectedAddress' }
    ) {
        Get-Command -Module M365Migration -Name $Name -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    It 'Gives every exported function comment-based help with a synopsis and an example' {
        foreach ($command in (Get-Command -Module M365Migration)) {
            $help = Get-Help -Name $command.Name -ErrorAction Stop
            $help.Synopsis | Should -Not -BeNullOrEmpty -Because "$($command.Name) needs a SYNOPSIS"
            @($help.Examples.Example).Count | Should -BeGreaterThan 0 -Because "$($command.Name) needs an EXAMPLE"
        }
    }
}

Describe 'Promoted helpers behave the same as exported functions' {

    It 'Splits a Teams LineUri into number and extension' {
        $result = Split-MigrationTeamsLineUri -LineUri 'tel:+15551234567;ext=123'
        $result.Number | Should -BeExactly '+15551234567'
        $result.Extension | Should -BeExactly '123'
    }

    It 'Normalises a typed phone number to E.164, keeping the extension' {
        Format-MigrationE164 -Value 'tel:(555) 123-4567;ext=88' | Should -BeExactly '+5551234567;ext=88'
    }

    It 'Returns $null for a phone number it cannot normalise' {
        Format-MigrationE164 -Value 'switchboard' | Should -BeNullOrEmpty
    }

    It 'Collapses a Teams policy object to its name' {
        Get-MigrationTeamsPolicyName -Policy ([pscustomobject]@{ Name = 'AU-Routing' }) | Should -BeExactly 'AU-Routing'
        Get-MigrationTeamsPolicyName -Policy 'AU-Routing' | Should -BeExactly 'AU-Routing'
        Get-MigrationTeamsPolicyName -Policy $null | Should -BeNullOrEmpty
    }

    It 'Generates a passphrase and a random password without logging them' {
        (New-MigrationPassphrase).Length | Should -BeGreaterThan 8
        (New-MigrationRandomPassword).Length | Should -BeGreaterThan 8
        New-MigrationRandomPassword | Should -Not -BeExactly (New-MigrationRandomPassword)
    }

    It 'Reads the status code off a Graph HTTP failure' {
        $exception = [System.Exception]::new('Response status code does not indicate success: 429.')
        Add-Member -InputObject $exception -NotePropertyName 'Response' `
            -NotePropertyValue ([pscustomobject]@{ StatusCode = 429; Headers = @{} })
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'GraphError', 'InvalidResult', $null)
        Get-MigrationGraphErrorStatusCode -ErrorRecord $record | Should -Be 429
    }

    It 'Reads 404 off the SDK cmdlet not-found message shape (no numeric status in the text)' {
        $exception = [System.Exception]::new(
            "[Request_ResourceNotFound] : Resource '11111111-1111-1111-1111-111111111111' does not exist " +
            'or one of its queried reference-property objects are not present.')
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'GraphError', 'InvalidResult', $null)
        Get-MigrationGraphErrorStatusCode -ErrorRecord $record | Should -Be 404
    }
}
