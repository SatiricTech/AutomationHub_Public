#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Result-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null

    $script:sampleRows = @(
        [pscustomobject]@{ Identity = 'a@contoso.com'; Action = 'SetUpn'; Status = 'Succeeded'; Detail = ''; NewUpn = 'a@newco.com' }
        [pscustomobject]@{ Identity = 'b@contoso.com'; Action = 'SetUpn'; Status = 'Succeeded'; Detail = ''; NewUpn = 'b@newco.com' }
        [pscustomobject]@{ Identity = 'c@contoso.com'; Action = 'SetUpn'; Status = 'Skipped';   Detail = 'PlanStatus is Excluded' }
        [pscustomobject]@{ Identity = 'd@contoso.com'; Action = 'SetUpn'; Status = 'Failed';    Detail = 'Object not found' }
    )
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Export-MigrationResult' {

    Context 'File naming' {

        It 'Uses the Results marker for a real run' {
            $null = Initialize-MigrationRun -ScriptName 'Set-Identity' -OutputPath $script:workspace
            $path = Export-MigrationResult -Rows $script:sampleRows -Name 'Set-Identity'
            [System.IO.Path]::GetFileName($path) | Should -Match '^Set-Identity-Results_\d{8}-\d{6}\.csv$'
        }

        It 'Uses the DryRun marker for a dry run' {
            $null = Initialize-MigrationRun -ScriptName 'Set-Identity' -OutputPath $script:workspace -DryRun
            $path = Export-MigrationResult -Rows $script:sampleRows -Name 'Set-Identity'
            [System.IO.Path]::GetFileName($path) | Should -Match '^Set-Identity-DryRun_\d{8}-\d{6}\.csv$'
        }

        It 'Prefixes the filename and folder when the run has a prefix' {
            $null = Initialize-MigrationRun -ScriptName 'New-Users' -OutputPath $script:workspace -Prefix 'Contoso'
            $path = Export-MigrationResult -Rows $script:sampleRows -Name 'New-Users'
            [System.IO.Path]::GetFileName($path) | Should -Match '^Contoso_New-Users-Results_\d{8}-\d{6}\.csv$'
            (Split-Path -Path $path -Parent) | Should -BeExactly (Join-Path $script:workspace 'Contoso')
        }

        It 'Honours an explicit -DryRun over the run context' {
            $null = Initialize-MigrationRun -ScriptName 'Set-Identity' -OutputPath $script:workspace
            $path = Export-MigrationResult -Rows $script:sampleRows -Name 'Set-Identity' -DryRun
            [System.IO.Path]::GetFileName($path) | Should -Match 'DryRun'
        }
    }

    Context 'Row shape' {

        BeforeAll {
            $null = Initialize-MigrationRun -ScriptName 'Set-Identity' -OutputPath $script:workspace
            $script:exportPath = Export-MigrationResult -Rows $script:sampleRows -Name 'Shape'
            $script:written = @(Import-Csv -LiteralPath $script:exportPath)
        }

        It 'Puts the four standard columns first, in order' {
            @($script:written[0].PSObject.Properties.Name)[0..3] |
                Should -Be @('Identity', 'Action', 'Status', 'Detail')
        }

        It 'Appends script-specific columns after the standard four' {
            $script:written[0].PSObject.Properties.Name | Should -Be @('Identity', 'Action', 'Status', 'Detail', 'NewUpn')
        }

        It 'Writes an empty cell for a column a row does not carry' {
            ($script:written | Where-Object Identity -eq 'c@contoso.com').NewUpn | Should -BeExactly ''
        }

        It 'Writes every row' {
            $script:written | Should -HaveCount 4
        }

        It 'Does not add a bare Outcome column' {
            $script:written[0].PSObject.Properties.Name | Should -Not -Contain 'Outcome'
        }
    }

    Context 'Summary block' {

        It 'Logs a count for each status' {
            $null = Initialize-MigrationRun -ScriptName 'Summary' -OutputPath $script:workspace -Verbosity High
            $logPath = InModuleScope M365Migration { $script:MigrationRun.LogPath }

            $null = Export-MigrationResult -Rows $script:sampleRows -Name 'Summary'
            $log = Get-Content -LiteralPath $logPath -Raw

            $log | Should -Match 'Result summary'
            $log | Should -Match 'Succeeded\s+2'
            $log | Should -Match 'Skipped\s+1'
            $log | Should -Match 'Failed\s+1'
            $log | Should -Match 'Total\s+4'
        }

        It 'Reports an empty result set rather than failing' {
            $null = Initialize-MigrationRun -ScriptName 'Empty' -OutputPath $script:workspace -Verbosity High
            $logPath = InModuleScope M365Migration { $script:MigrationRun.LogPath }

            $path = Export-MigrationResult -Rows @() -Name 'Empty'
            Test-Path -LiteralPath $path | Should -BeTrue
            (Get-Content -LiteralPath $logPath -Raw) | Should -Match 'no rows processed'
        }
    }
}
