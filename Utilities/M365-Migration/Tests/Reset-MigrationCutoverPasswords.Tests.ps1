#Requires -Version 7.4

<#
    Tests for the pure decision function inside Reset-MigrationCutoverPasswords.ps1.

    The script body connects to Graph and resets passwords, so it must never be dot-sourced
    by a test. Instead the function is lifted out of the file's AST and defined on its own,
    which exercises the real shipped text without executing anything around it.

    Author: AutomationHub
#>

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
