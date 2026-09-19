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
    $moduleRoot = Join-Path $toolkitRoot 'M365Migration'
    $topLevelScripts = @(Get-ChildItem -LiteralPath $toolkitRoot -Filter '*.ps1' -File)
    $moduleScripts = @(Get-ChildItem -LiteralPath $moduleRoot -Filter '*.ps1' -File -Recurse)

    $scannedFiles = @(($topLevelScripts + $moduleScripts) | ForEach-Object {
            @{ Path = $_.FullName; Name = $_.Name }
        })

    BeforeAll {
        # Shared by the per-file check below and by the detector's own self-check, so the two
        # can never quietly drift apart.
        function script:Get-InteractivePromptSurvey {
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param([Parameter(Mandatory)][string]$Path)

            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
            if ($parseErrors -and @($parseErrors).Count -gt 0) {
                throw "$Path does not parse: $(@($parseErrors)[0].Message)"
            }

            # A module-qualified call such as Microsoft.PowerShell.Utility\Read-Host comes back
            # from GetCommandName() with the module prefix still attached, so only the text after
            # the last '\' is compared against the bare command name.
            $readHostCalls = @($ast.FindAll(
                    {
                        if ($args[0] -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                        $name = $args[0].GetCommandName()
                        $name -and (($name -split '\\')[-1] -ieq 'Read-Host')
                    }, $true))

            $hostUiPrompts = @($ast.FindAll(
                    {
                        $args[0] -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                        $args[0].Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $args[0].Member.Value -in @('PromptForChoice', 'Prompt') -and
                        $args[0].Expression.Extent.Text -ieq '$Host.UI'
                    }, $true))

            return [pscustomobject]@{ ReadHostCalls = $readHostCalls; HostUiPrompts = $hostUiPrompts }
        }
    }

    It 'Never prompts interactively in <Name>' -ForEach $scannedFiles {
        $survey = Get-InteractivePromptSurvey -Path $Path
        $survey.ReadHostCalls | Should -BeNullOrEmpty -Because "$Name must not call Read-Host"
        $survey.HostUiPrompts | Should -BeNullOrEmpty -Because "$Name must not call `$Host.UI.Prompt or PromptForChoice"
    }

    It 'Flags a module-qualified Read-Host call, so the guard is proven against qualification, not assumed' {
        $sample = Join-Path $TestDrive 'Sample-QualifiedPrompt.ps1'
        Set-Content -LiteralPath $sample -Value @'
function Get-Sample {
    $answer = Microsoft.PowerShell.Utility\Read-Host -Prompt 'Enter a value'
    return $answer
}
'@
        (Get-InteractivePromptSurvey -Path $sample).ReadHostCalls | Should -Not -BeNullOrEmpty
    }
}

Describe 'Script versions' {

    <#
        Every top-level script's .NOTES block must carry a 'Version:' line. Get-Help -Full on a
        script path (verified interactively - it works for a .ps1 with proper comment-based help,
        unlike a bare AST walk, which would have to reimplement the parser's own tag recognition)
        surfaces that block as .alertSet.alert[].Text. The 'Version' label is aligned to whatever
        column that file's own 'Author:' line uses, so the colon may or may not be preceded by
        spaces - the regex tolerates either.

        Built here, at Describe scope rather than inside BeforeAll, because -ForEach needs it
        during Pester's discovery pass; a BeforeAll only runs later, during Run.
    #>

    $toolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $topLevelScripts = @(Get-ChildItem -LiteralPath $toolkitRoot -Filter '*.ps1' -File | ForEach-Object {
            @{ Path = $_.FullName; Name = $_.Name }
        })

    It 'Stamps <Name> with a Version line in .NOTES' -ForEach $topLevelScripts {
        $help = Get-Help -Name $Path -Full -ErrorAction Stop
        $notesText = ($help.alertSet.alert.Text -join "`n")
        $notesText | Should -Match 'Version\s*:\s+\d+\.\d+\.\d+' -Because "$Name needs a Version: line in .NOTES"
    }

    $nonStandardExitCodeScripts = @(
        'Remove-MigrationDomainReferences.ps1', 'Compare-MigrationUserData.ps1', 'Test-MigrationReadiness.ps1'
    ) | ForEach-Object { @{ Name = $_; Path = (Join-Path $toolkitRoot $_) } }

    It 'Documents non-standard exit codes for <Name>' -ForEach $nonStandardExitCodeScripts {
        $help = Get-Help -Name $Path -Full -ErrorAction Stop
        $notesText = ($help.alertSet.alert.Text -join "`n")
        $notesText | Should -Match 'Exit codes\s*:' -Because "$Name has non-standard exit codes to document"
    }
}
