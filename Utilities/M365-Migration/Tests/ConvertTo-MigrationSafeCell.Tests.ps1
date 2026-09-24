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

    It 'leaves a phone-shaped value alone, even though it starts with + or -' -ForEach @(
        '+15551234567', '-42', '+3.14', '-3.14', '15551234567'
        # The extension-qualified line URI shape Split-MigrationTeamsLineUri produces.
        '+15551110000;ext=524'
        # The shapes a tenant actually stores in MobilePhone/BusinessPhone/FaxNumber. These
        # reach a destination tenant verbatim through the inventory -> plan -> New-Users
        # chain, so a quote prefix here would be written to the user's profile.
        '+1 (425) 555-0100', '(425) 555-0100', '425-555-0100', '+1.425.555.0100'
        '+1 425 555 0100', '+1 (425) 555-0100;ext=524'
        # The hyphen placeholder a source tenant uses for "no value".
        '-'
    ) {
        ConvertTo-MigrationSafeCell -Value $_ | Should -Be $_
    }

    It 'still prefixes a value that starts with + or - but is not phone-shaped' -ForEach @(
        # A non-digit extension is not the ';ext=<digits>' shape the carve-out allows.
        '+1555;ext=abc'
        # A non-digit payload after the sign is exactly the injection shape the sanitiser
        # exists to defuse.
        "-1+cmd|' /C calc'!A0"
        "-cmd|' /C calc'!A0"
        '=1+1'
        '@SUM(A1)'
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

    It 'copies an excluded property untouched while still sanitising the rest' {
        # A generated credential is minted by this toolkit, never read from a tenant, so it
        # cannot carry an injection - but it CAN legitimately start with '-' or '=', and a
        # quote prefix there would put a password in the file that the account does not have.
        $row = [pscustomobject]@{ Identity = '=x'; GeneratedPassword = '-abc=def'; Detail = 'ok' }
        $safe = ConvertTo-MigrationSafeRow -Row $row -ExcludeProperty 'GeneratedPassword'

        @($safe.PSObject.Properties.Name) | Should -Be @('Identity', 'GeneratedPassword', 'Detail')
        $safe.GeneratedPassword | Should -BeExactly '-abc=def'
        $safe.Identity | Should -BeExactly "'=x"
    }

    It 'sanitises every property when nothing is excluded' {
        $row = [pscustomobject]@{ GeneratedPassword = '-abc=def' }
        (ConvertTo-MigrationSafeRow -Row $row).GeneratedPassword | Should -BeExactly "'-abc=def"
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

Describe 'ConvertFrom-MigrationSafeCell' {

    It 'strips the apostrophe the sanitiser added' -ForEach @(
        '=SUM(A1)', '+cmd', '-cmd', '@SUM', "`tx", "`rx", "=HYPERLINK(""x"")"
    ) {
        ConvertFrom-MigrationSafeCell -Value (ConvertTo-MigrationSafeCell -Value $_) | Should -BeExactly $_
    }

    It 'leaves an apostrophe that is part of the data alone' -ForEach @(
        # A surname is the common case, and it is why the inverse checks the SECOND
        # character rather than just the leading apostrophe.
        "'Brien", "O'Brien", "'", "''", "'1", "' "
    ) {
        ConvertFrom-MigrationSafeCell -Value $_ | Should -BeExactly $_
    }

    It 'leaves a value the sanitiser never touched alone' -ForEach @(
        'John Smith', '+1 (425) 555-0100', '-', '+15551234567'
    ) {
        ConvertFrom-MigrationSafeCell -Value $_ | Should -BeExactly $_
    }

    It 'passes a non-string through unchanged' {
        ConvertFrom-MigrationSafeCell -Value 5 | Should -Be 5
        ConvertFrom-MigrationSafeCell -Value $null | Should -BeNullOrEmpty
        ConvertFrom-MigrationSafeCell -Value $true | Should -BeTrue
    }
}

Describe 'Export-MigrationReport round-trips through Import-MigrationCsv' {

    BeforeAll {
        $null = Initialize-MigrationRun -ScriptName 'Get-Inventory' -OutputPath $script:workspace -Prefix 'RoundTrip'

        # Exactly what an inventory Users tab carries into New-MigrationIdentityPlan: a
        # formatted phone number, a hyphen placeholder, a value that really is a formula,
        # and a surname that legitimately begins with an apostrophe.
        $script:roundTripRow = [pscustomobject]@{
            UserPrincipalName = 'a@contoso.com'
            MobilePhone       = '+1 (425) 555-0100'
            Department        = '-'
            Office            = '=SUM(A1)'
            LastName          = "'Brien"
        }

        $script:roundTripPath = Export-MigrationReport -Rows @($script:roundTripRow) -Name 'RoundTrip'
        $script:roundTripRead = @(Import-MigrationCsv -Path $script:roundTripPath)[0]
    }

    It 'gives back <Column> exactly as it went in' -ForEach @(
        @{ Column = 'MobilePhone' }, @{ Column = 'Department' }
        @{ Column = 'Office' },      @{ Column = 'LastName' }
    ) {
        $script:roundTripRead.$Column | Should -BeExactly $script:roundTripRow.$Column
    }

    It 'still writes the formula cell to disk defused' {
        $onDisk = @(Import-Csv -LiteralPath $script:roundTripPath)[0]
        $onDisk.Office | Should -BeExactly "'=SUM(A1)"
        # The phone, the placeholder and the surname are readable in Excel as they stand.
        $onDisk.MobilePhone | Should -BeExactly '+1 (425) 555-0100'
        $onDisk.Department | Should -BeExactly '-'
        $onDisk.LastName | Should -BeExactly "'Brien"
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

    It 'writes a generated credential exactly as minted, even when it leads with a sanitised character' {
        InModuleScope M365Migration {
            $script:MigrationRun = @{
                OutputDirectory = $TestDrive; Prefix = 'T'; DryRun = $false
                LogPath         = (Join-Path $TestDrive 'y.log'); Verbosity = 'Low'
                ScriptName      = 'y'; StartedAt = Get-Date
            }
            $path = Export-MigrationResult -Rows @(
                [pscustomobject]@{
                    Identity          = '=x'
                    Action            = 'CreateUser'
                    Status            = 'Succeeded'
                    Detail            = ''
                    GeneratedPassword = '-Pa55=fixed+word'
                }
            ) -Name 'Y'
            $written = (Import-Csv $path)[0]

            # The credential is the account's actual password and must round-trip byte for byte.
            $written.GeneratedPassword | Should -BeExactly '-Pa55=fixed+word'
            # The exemption is scoped to that one column - everything else is still sanitised.
            $written.Identity | Should -BeExactly "'=x"
            $script:MigrationRun = $null
        }
    }
}
