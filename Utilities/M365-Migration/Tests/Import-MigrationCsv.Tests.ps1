#Requires -Version 7.4

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Csv-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null

    function New-TestCsv {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds a fixture inside the test workspace.')]
        param([string]$Name, [string]$Content)
        $path = Join-Path $script:workspace $Name
        Set-Content -LiteralPath $path -Value $Content -Encoding utf8
        return $path
    }
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Import-MigrationCsv' {

    Context 'Alias resolution' {

        It 'Maps <Alias> to <Canonical>' -ForEach @(
            @{ Alias = 'UPN';                 Canonical = 'UserPrincipalName' }
            @{ Alias = 'User Principal Name'; Canonical = 'UserPrincipalName' }
            @{ Alias = 'Login';               Canonical = 'UserPrincipalName' }
            @{ Alias = 'PrimaryEmail';        Canonical = 'PrimarySmtpAddress' }
            @{ Alias = 'WindowsEmailAddress'; Canonical = 'PrimarySmtpAddress' }
            @{ Alias = 'GivenName';           Canonical = 'FirstName' }
            @{ Alias = 'Surname';             Canonical = 'LastName' }
            @{ Alias = 'MiddleInitial';       Canonical = 'MiddleName' }
            @{ Alias = 'Display Name';        Canonical = 'DisplayName' }
            @{ Alias = 'Title';               Canonical = 'JobTitle' }
            @{ Alias = 'OfficeLocation';      Canonical = 'Office' }
            @{ Alias = 'Mobile';              Canonical = 'MobilePhone' }
            @{ Alias = 'Country Code';        Canonical = 'UsageLocation' }
            @{ Alias = 'AssignedLicenses';    Canonical = 'Licenses' }
            @{ Alias = 'Manager';             Canonical = 'ManagerUpn' }
            @{ Alias = 'NewUPN';              Canonical = 'TargetUserPrincipalName' }
            @{ Alias = 'TargetEmail';         Canonical = 'TargetPrimarySmtp' }
            @{ Alias = 'RecipientType';       Canonical = 'ObjectType' }
            @{ Alias = 'LineUri';             Canonical = 'PhoneNumber' }
            @{ Alias = 'Number';              Canonical = 'PhoneNumber' }
            @{ Alias = 'NumberType';          Canonical = 'PhoneNumberType' }
            @{ Alias = 'EmergencyLocationId'; Canonical = 'LocationId' }
            @{ Alias = 'VoiceRoutingPolicy';  Canonical = 'OnlineVoiceRoutingPolicy' }
        ) {
            $path = New-TestCsv -Name "alias-$($Alias -replace '\W', '').csv" -Content "$Alias`nvalue"
            $rows = Import-MigrationCsv -Path $path
            $rows[0].PSObject.Properties.Name | Should -Contain $Canonical
            $rows[0].$Canonical | Should -BeExactly 'value'
        }

        It 'Matches an alias case-insensitively and trims the header' {
            $path = New-TestCsv -Name 'case.csv' -Content "` upn `njohn@contoso.com"
            $rows = Import-MigrationCsv -Path $path
            $rows[0].UserPrincipalName | Should -BeExactly 'john@contoso.com'
        }

        It 'Leaves a canonical header untouched' {
            $path = New-TestCsv -Name 'canonical.csv' -Content "UserPrincipalName`njohn@contoso.com"
            (Import-MigrationCsv -Path $path)[0].UserPrincipalName | Should -BeExactly 'john@contoso.com'
        }

        It 'Keeps an unrecognised header under its own name' {
            $path = New-TestCsv -Name 'unknown.csv' -Content "UPN,CostCentre`njohn@contoso.com,4100"
            $row = (Import-MigrationCsv -Path $path)[0]
            $row.UserPrincipalName | Should -BeExactly 'john@contoso.com'
            $row.CostCentre | Should -BeExactly '4100'
        }

        It 'Keeps a bare Type header under its own name instead of mapping it to ObjectType' {
            # 'Type' collided with the Teams Phone PhoneNumberType and the Viva ActivityType
            # columns, so it is deliberately not part of the vocabulary any more.
            $path = New-TestCsv -Name 'bare-type.csv' -Content "UPN,Type`njohn@contoso.com,DirectRouting"
            $row = (Import-MigrationCsv -Path $path)[0]
            $row.PSObject.Properties.Name | Should -Not -Contain 'ObjectType'
            $row.Type | Should -BeExactly 'DirectRouting'
        }

        It 'Throws when ObjectType is required and only a bare Type header is present' {
            $path = New-TestCsv -Name 'bare-type-required.csv' -Content "UPN,Type`njohn@contoso.com,User"
            { Import-MigrationCsv -Path $path -RequiredColumns 'ObjectType' } |
                Should -Throw -ExpectedMessage '*ObjectType*'
        }

        It 'Still maps RecipientType to ObjectType' {
            $path = New-TestCsv -Name 'recipient-type.csv' -Content "UPN,RecipientType`njohn@contoso.com,SharedMailbox"
            (Import-MigrationCsv -Path $path)[0].ObjectType | Should -BeExactly 'SharedMailbox'
        }

        It 'Keeps a canonical Extension header' {
            $path = New-TestCsv -Name 'extension.csv' -Content "UPN,Extension`njohn@contoso.com,4210"
            (Import-MigrationCsv -Path $path)[0].Extension | Should -BeExactly '4210'
        }

        It 'Resolves a whole Teams Phone assignment file' {
            $path = New-TestCsv -Name 'teams-phone.csv' `
                -Content ("UPN,LineUri,NumberType,EmergencyLocationId,VoiceRoutingPolicy,Extension`n" +
                    'john@contoso.com,tel:+15551234567,CallingPlan,11111111-1111-1111-1111-111111111111,AU-Routing,123')
            $row = (Import-MigrationCsv -Path $path -RequiredColumns 'UserPrincipalName', 'PhoneNumber')[0]
            $row.PhoneNumber | Should -BeExactly 'tel:+15551234567'
            $row.PhoneNumberType | Should -BeExactly 'CallingPlan'
            $row.LocationId | Should -BeExactly '11111111-1111-1111-1111-111111111111'
            $row.OnlineVoiceRoutingPolicy | Should -BeExactly 'AU-Routing'
            $row.Extension | Should -BeExactly '123'
        }

        It 'Does not let PhoneNumber aliases evict a canonical PhoneNumber column' {
            $path = New-TestCsv -Name 'phone-collide.csv' `
                -Content "PhoneNumber,LineUri`n+15551234567,tel:+15551234567"
            $row = (Import-MigrationCsv -Path $path)[0]
            $row.PhoneNumber | Should -BeExactly '+15551234567'
            $row.LineUri | Should -BeExactly 'tel:+15551234567'
        }

        It 'Does not let an alias evict a canonical column of the same meaning' {
            $path = New-TestCsv -Name 'collide.csv' -Content "DisplayName,Name`nJohn Smith,JSMITH"
            $row = (Import-MigrationCsv -Path $path)[0]
            $row.DisplayName | Should -BeExactly 'John Smith'
            $row.Name | Should -BeExactly 'JSMITH'
        }
    }

    Context 'Required columns' {

        It 'Returns rows when every required column is present after aliasing' {
            $path = New-TestCsv -Name 'required-ok.csv' -Content "UPN,GivenName,Surname`njohn@contoso.com,John,Smith"
            $rows = Import-MigrationCsv -Path $path -RequiredColumns 'UserPrincipalName', 'FirstName', 'LastName'
            $rows | Should -HaveCount 1
        }

        It 'Throws listing every missing column at once' {
            $path = New-TestCsv -Name 'required-missing.csv' -Content "UPN`njohn@contoso.com"
            { Import-MigrationCsv -Path $path -RequiredColumns 'UserPrincipalName', 'FirstName', 'LastName' } |
                Should -Throw -ExpectedMessage '*FirstName, LastName*'
        }

        It 'Throws when the file does not exist' {
            { Import-MigrationCsv -Path (Join-Path $script:workspace 'nope.csv') } |
                Should -Throw -ExpectedMessage '*not found*'
        }

        It 'Throws when the file has headers but no rows' {
            $path = New-TestCsv -Name 'empty.csv' -Content 'UPN'
            { Import-MigrationCsv -Path $path } | Should -Throw -ExpectedMessage '*no data rows*'
        }
    }
}

Describe 'Get-MigrationCsvValue' {

    It 'Returns the trimmed value' {
        Get-MigrationCsvValue -Row ([pscustomobject]@{ Wave = ' 2 ' }) -Name 'Wave' | Should -BeExactly '2'
    }

    It 'Returns the default when the property is absent' {
        Get-MigrationCsvValue -Row ([pscustomobject]@{ Wave = '2' }) -Name 'ObjectType' -Default 'User' |
            Should -BeExactly 'User'
    }

    It 'Returns the default when the value is whitespace' {
        Get-MigrationCsvValue -Row ([pscustomobject]@{ Wave = '   ' }) -Name 'Wave' -Default '1' |
            Should -BeExactly '1'
    }

    It 'Returns the default when the row is null' {
        Get-MigrationCsvValue -Row $null -Name 'Wave' -Default '1' | Should -BeExactly '1'
    }

    It 'Returns $null by default' {
        Get-MigrationCsvValue -Row ([pscustomobject]@{ Wave = '' }) -Name 'Wave' | Should -BeNullOrEmpty
    }
}
