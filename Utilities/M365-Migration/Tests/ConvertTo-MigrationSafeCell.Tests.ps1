#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-SafeCell-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertTo-MigrationSafeCell' {
    It 'prefixes formula-looking strings' -ForEach @('=HYPERLINK("x")', '+1', '-1', '@SUM', "`tx", "`rx") {
        ConvertTo-MigrationSafeCell -Value $_ | Should -Be ("'" + $_)
    }

    It 'leaves ordinary strings, numbers, nulls and booleans alone' {
        ConvertTo-MigrationSafeCell -Value 'John Smith' | Should -Be 'John Smith'
        ConvertTo-MigrationSafeCell -Value 5 | Should -Be 5
        ConvertTo-MigrationSafeCell -Value $null | Should -BeNullOrEmpty
        ConvertTo-MigrationSafeCell -Value $true | Should -BeTrue
    }

    It 'sanitises every string property of a row and keeps property order' {
        $row = [pscustomobject]@{ Identity = '=x'; Count = 1; Detail = 'ok' }
        $safe = ConvertTo-MigrationSafeRow -Row $row
        @($safe.PSObject.Properties.Name) | Should -Be @('Identity', 'Count', 'Detail')
        $safe.Identity | Should -Be "'=x"
        $safe.Count | Should -Be 1
    }
}

Describe 'Export-MigrationResult sanitises cells' {
    It 'writes a formula-looking Identity with a quote prefix' {
        InModuleScope M365Migration {
            $script:MigrationRun = @{
                OutputDirectory = $TestDrive; Prefix = 'T'; DryRun = $false
                LogPath         = (Join-Path $TestDrive 'x.log'); Verbosity = 'Low'
                ScriptName      = 'x'; StartedAt = Get-Date
            }
            $path = Export-MigrationResult -Rows @(
                [pscustomobject]@{ Identity = '=HYPERLINK("h")'; Action = 'A'; Status = 'Succeeded'; Detail = '' }
            ) -Name 'X'
            (Import-Csv $path)[0].Identity | Should -Be "'=HYPERLINK(""h"")"
            $script:MigrationRun = $null
        }
    }
}
