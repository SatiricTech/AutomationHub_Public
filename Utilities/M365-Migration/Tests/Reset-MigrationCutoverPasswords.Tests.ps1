#Requires -Version 7.4

<#
    Tests for the pure decision function inside Reset-MigrationCutoverPasswords.ps1.

    The script body connects to Graph and resets passwords, so it must never be dot-sourced
    by a test. Instead the function is lifted out of the file's AST and defined on its own,
    which exercises the real shipped text without executing anything around it.

    Author: AutomationHub
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script under test binds, including ones a particular test does not read; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Update-MgUser here is a stand-in named after the real cmdlet so the script under test resolves it. It changes nothing, so ShouldProcess would be meaningless.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'PasswordProfile is a parameter name the stub has to accept for the call to bind. The stub reads nothing and holds no credential.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $scriptPath = Join-Path $PSScriptRoot '..' 'Reset-MigrationCutoverPasswords.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "Reset-MigrationCutoverPasswords.ps1 failed to parse: $($errors[0].Message)"
    }

    $functionAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Resolve-CutoverPlanIdentity'
        }, $true) | Select-Object -First 1

    if (-not $functionAst) {
        throw 'Resolve-CutoverPlanIdentity was not found in Reset-MigrationCutoverPasswords.ps1.'
    }

    . ([scriptblock]::Create($functionAst.Extent.Text))

    $script:scriptPath = $scriptPath
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'Resolve-CutoverPlanIdentity' {

    Context 'when the plan row carries a target UPN' {

        It 'uses TargetUserPrincipalName and reports no fallback' {
            $row = New-MigrationPlanRow
            $row.TargetUserPrincipalName = 'john.smith@contoso.com'
            $row.InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'

            $result = Resolve-CutoverPlanIdentity -Row $row

            $result.Identity | Should -Be 'john.smith@contoso.com'
            $result.Source | Should -Be 'Target'
            $result.Reason | Should -BeNullOrEmpty
        }

        It 'trims surrounding whitespace' {
            $row = New-MigrationPlanRow
            $row.TargetUserPrincipalName = '  jane.doe@contoso.com  '

            (Resolve-CutoverPlanIdentity -Row $row).Identity | Should -Be 'jane.doe@contoso.com'
        }
    }

    Context 'when the target UPN has not been assigned yet' {

        It 'falls back to InterimUserPrincipalName and says why' {
            $row = New-MigrationPlanRow
            $row.TargetUserPrincipalName = ''
            $row.InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'

            $result = Resolve-CutoverPlanIdentity -Row $row

            $result.Identity | Should -Be 'john.smith@newco.onmicrosoft.com'
            $result.Source | Should -Be 'Interim'
            $result.Reason | Should -Match 'InterimUserPrincipalName'
        }

        It 'treats a whitespace-only target as empty' {
            $row = New-MigrationPlanRow
            $row.TargetUserPrincipalName = '   '
            $row.InterimUserPrincipalName = 'jane.doe@newco.onmicrosoft.com'

            (Resolve-CutoverPlanIdentity -Row $row).Source | Should -Be 'Interim'
        }
    }

    Context 'when the row carries neither name' {

        It 'returns no identity rather than guessing' {
            $row = New-MigrationPlanRow
            $row.SourceUserPrincipalName = 'john.smith@fabrikam.com'

            $result = Resolve-CutoverPlanIdentity -Row $row

            $result.Identity | Should -BeNullOrEmpty
            $result.Source | Should -Be 'None'
            $result.Reason | Should -Match 'neither'
        }

        It 'never falls back to the source UPN' {
            $row = New-MigrationPlanRow
            $row.SourceUserPrincipalName = 'john.smith@fabrikam.com'

            (Resolve-CutoverPlanIdentity -Row $row).Identity | Should -Not -Be 'john.smith@fabrikam.com'
        }
    }

    Context 'when the row is missing the plan columns entirely' {

        It 'tolerates a sparse object without throwing' {
            $row = [pscustomobject]@{ SomethingElse = 'x' }

            $result = Resolve-CutoverPlanIdentity -Row $row

            $result.Source | Should -Be 'None'
        }
    }
}

Describe 'A declined confirmation is a Skip, not a Plan' {

    <#
        The only way to reach the ShouldProcess gate is to run the script, so it is invoked with the
        call operator while plain functions declared here shadow the Graph module cmdlets and the
        toolkit's connection helpers. PowerShell resolves commands innermost-scope-first, so these
        win for anything the script calls, while the real module still supplies the run context, the
        logger and the results export. 'exit' inside a script run with '&' ends that script only.
    #>

    BeforeAll {
        function Initialize-MigrationModule {
            param([string[]]$Name, [string]$MinimumVersion)
        }
        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }
        function Get-MgUser {
            param($UserId, $Filter, $Property, $ErrorAction)
            return [pscustomobject]@{
                Id                = '11111111-1111-1111-1111-111111111111'
                UserPrincipalName = 'john.smith@newco.com'
                DisplayName       = 'John Smith'
                AccountEnabled    = $true
            }
        }
        function Update-MgUser {
            param($UserId, $PasswordProfile, $ErrorAction)
            throw 'Update-MgUser was reached, which -WhatIf must have prevented.'
        }

        $script:whatIfWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-WhatIf-$([guid]::NewGuid())"
        $null = New-Item -Path $script:whatIfWorkspace -ItemType Directory -Force

        & $script:scriptPath -TestUser 'john.smith@newco.com' -OutputPath $script:whatIfWorkspace `
            -Verbosity Low -WhatIf

        $file = @(Get-ChildItem -LiteralPath $script:whatIfWorkspace -Filter 'Reset-CutoverPasswords-Results_*.csv')
        $script:whatIfRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:whatIfWorkspace -and (Test-Path -LiteralPath $script:whatIfWorkspace)) {
            Remove-Item -LiteralPath $script:whatIfWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Reports the declined reset as Skipped rather than Planned or Succeeded' {
        $script:whatIfRows.Count | Should -Be 1
        $script:whatIfRows[0].Status | Should -BeExactly 'Skipped'
        $script:whatIfRows[0].Detail | Should -BeExactly 'Declined at the confirmation prompt.'
    }

    It 'Puts no credential in the results file for a reset that never happened' {
        $script:whatIfRows[0].GeneratedPassword | Should -BeNullOrEmpty
    }
}
