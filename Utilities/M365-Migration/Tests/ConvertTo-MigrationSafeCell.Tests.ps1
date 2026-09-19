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
    It 'prefixes formula-looking strings' -ForEach @('=HYPERLINK("x")', '+cmd', '-cmd', '@SUM', "`tx", "`rx") {
        ConvertTo-MigrationSafeCell -Value $_ | Should -Be ("'" + $_)
    }

    It 'leaves ordinary strings, numbers, nulls and booleans alone' {
        ConvertTo-MigrationSafeCell -Value 'John Smith' | Should -Be 'John Smith'
        ConvertTo-MigrationSafeCell -Value 5 | Should -Be 5
        ConvertTo-MigrationSafeCell -Value $null | Should -BeNullOrEmpty
        ConvertTo-MigrationSafeCell -Value $true | Should -BeTrue
    }

    It 'leaves a pure signed number alone, even though it starts with + or -' -ForEach @(
        '+15551234567', '-42', '+3.14', '-3.14', '15551234567'
    ) {
        ConvertTo-MigrationSafeCell -Value $_ | Should -Be $_
    }

    It 'still prefixes a value that starts with + or - but is not a pure number' -ForEach @(
        # A space breaks the pure-number match: this toolkit always stores E.164 numbers
        # without spaces (Format-MigrationE164), so a spaced-out number reaching this
        # function is not the phone-number case the numeric carve-out exists for.
        '+1 555 123'
        # A non-digit payload after the sign is exactly the injection shape the sanitiser
        # exists to defuse.
        "-1+cmd|' /C calc'!A0"
        '=1+1'
    ) {
        ConvertTo-MigrationSafeCell -Value $_ | Should -Be ("'" + $_)
    }

    It 'sanitises every string property of a row and keeps property order' {
        $row = [pscustomobject]@{ Identity = '=x'; Count = 1; Detail = 'ok' }
        $safe = ConvertTo-MigrationSafeRow -Row $row
        @($safe.PSObject.Properties.Name) | Should -Be @('Identity', 'Count', 'Detail')
        $safe.Identity | Should -Be "'=x"
        $safe.Count | Should -Be 1
    }

    It 'round-trips a pure-number phone column unchanged through CSV, alongside a sanitised column' {
        $row = [pscustomobject]@{ PhoneNumber = '+15551234567'; DisplayName = '=x' }
        $safe = ConvertTo-MigrationSafeRow -Row $row

        $csvPath = Join-Path $TestDrive 'SafeRow.csv'
        $safe | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
        $written = Import-Csv -LiteralPath $csvPath

        $written.PhoneNumber | Should -Be '+15551234567'
        $written.DisplayName | Should -Be "'=x"
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
