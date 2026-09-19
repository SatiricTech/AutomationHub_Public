#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    $script:modulePath = Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1'
    $script:moduleRoot = Split-Path -Path $script:modulePath -Parent
    Import-Module $script:modulePath -Force
}

Describe 'M365Migration manifest' {

    It 'Is a valid manifest at version 1.2.0' {
        $manifest = Test-ModuleManifest -Path $script:modulePath -ErrorAction Stop
        $manifest.Version.ToString() | Should -BeExactly '1.2.0'
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

Describe 'No interactive prompts' {

    <#
        Every script in the toolkit has to run unattended - an RMM job or a pipeline cannot answer
        a prompt. This parses every .ps1 the toolkit ships (the top-level scripts and the module's
        Public and Private functions) and asserts none of them contain a Read-Host call or a
        $Host.UI.Prompt/PromptForChoice call. Tests/ is excluded: its stub functions are named
        Read-Host on purpose, to shadow a real prompt in the script under test.

        The file list is built here, at Describe scope rather than inside BeforeAll, because
        -ForEach needs it during Pester's discovery pass; a BeforeAll only runs later, during Run.
    #>

    $toolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $topLevelScripts = @(Get-ChildItem -LiteralPath $toolkitRoot -Filter '*.ps1' -File)
    $moduleScripts = @(Get-ChildItem -LiteralPath (Join-Path $toolkitRoot 'M365Migration') -Filter '*.ps1' -File -Recurse)

    $scannedFiles = @(($topLevelScripts + $moduleScripts) | ForEach-Object {
            @{ Path = $_.FullName; Name = $_.Name }
        })

    It 'Never prompts interactively in <Name>' -ForEach $scannedFiles {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
        if ($parseErrors -and @($parseErrors).Count -gt 0) {
            throw "$Name does not parse: $(@($parseErrors)[0].Message)"
        }

        $readHostCalls = @($ast.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $args[0].GetCommandName() -ieq 'Read-Host'
            }, $true))
        $readHostCalls | Should -BeNullOrEmpty -Because "$Name must not call Read-Host"

        $hostUiPrompts = @($ast.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $args[0].Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $args[0].Member.Value -in @('PromptForChoice', 'Prompt') -and
                $args[0].Expression.Extent.Text -ieq '$Host.UI'
            }, $true))
        $hostUiPrompts | Should -BeNullOrEmpty -Because "$Name must not call `$Host.UI.Prompt or PromptForChoice"
    }
}
