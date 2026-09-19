#Requires -Version 7.4

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
}

Describe 'New-MigrationSettings' {

    It 'produces the spec document with defaults and the label applied' {
        $s = New-MigrationSettings -Label 'Contoso'
        $s.SchemaVersion | Should -Be 1
        $s.Label | Should -Be 'Contoso'
        $s.Scenario | Should -Be 'TenantToTenant'
        $s.Plan.UpnFormat | Should -Be 'First.Last'
        $s.Defaults.Verbosity | Should -Be 'Medium'
        $s.Domains.Smtp | Should -Be ''
        @($s.Keys) | Should -Be @(
            'SchemaVersion', 'Label', 'Scenario', 'Source', 'Destination', 'Domains', 'Plan', 'Defaults', 'Pinned',
            'VivaLearning')
    }
}

Describe 'Resolve-MigrationSettings' {

    It 'reports a missing file without throwing' {
        $r = Resolve-MigrationSettings -Path (Join-Path $TestDrive 'none.json')
        $r.Exists | Should -BeFalse
        $r.IsValid | Should -BeFalse
        $r.Settings | Should -BeNullOrEmpty
    }

    It 'round-trips the example file as valid' {
        $templatePath = Join-Path $PSScriptRoot '..' 'Templates' 'M365Migration.settings.example.json'
        $r = Resolve-MigrationSettings -Path $templatePath
        $r.IsValid | Should -BeTrue -Because ($r.Errors -join '; ')
        $r.Settings.Source.TenantId | Should -Be '00000000-0000-0000-0000-000000000000'
    }

    It 'rejects unknown keys naming the valid ones, and a bad GUID' {
        $s = New-MigrationSettings -Label 'X'
        $s['Bogus'] = 1
        $s.Source.TenantId = 'not-a-guid'
        $p = Join-Path $TestDrive 's.json'
        ($s | ConvertTo-Json -Depth 6) | Set-Content $p
        $r = Resolve-MigrationSettings -Path $p
        $r.IsValid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match "Unknown key 'Bogus'"
        ($r.Errors -join ' ') | Should -Match 'Source.TenantId'
    }

    It 'fills keys missing from an older file with defaults' {
        $p = Join-Path $TestDrive 'old.json'
        '{"SchemaVersion":1,"Label":"X","Scenario":"TenantToTenant"}' | Set-Content $p
        $r = Resolve-MigrationSettings -Path $p
        $r.IsValid | Should -BeTrue
        $r.Settings.Defaults.Verbosity | Should -Be 'Medium'
    }

    It 'refuses a key that looks like a secret' {
        $p = Join-Path $TestDrive 'bad.json'
        '{"SchemaVersion":1,"Label":"X","Scenario":"TenantToTenant","VivaLearning":{"ClientSecret":"x"}}' |
            Set-Content $p
        (Resolve-MigrationSettings -Path $p).Errors -join ' ' | Should -Match 'secret'
    }

    It 'rejects Plan.AliasDomainMap when it is an empty JSON array instead of an object' {
        $s = New-MigrationSettings -Label 'X'
        $s.Plan.AliasDomainMap = @()
        $p = Join-Path $TestDrive 'array-map.json'
        ($s | ConvertTo-Json -Depth 6) | Set-Content $p
        $r = Resolve-MigrationSettings -Path $p
        $r.IsValid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'Plan\.AliasDomainMap must be an object'
    }

    It 'rejects an entire section written as an empty JSON array' {
        $s = New-MigrationSettings -Label 'X'
        $s['Plan'] = @()
        $p = Join-Path $TestDrive 'array-section.json'
        ($s | ConvertTo-Json -Depth 6) | Set-Content $p
        $r = Resolve-MigrationSettings -Path $p
        $r.IsValid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'Plan must be an object'
    }

    It 'normalises a Domain value on load: trims, strips a leading @, lower-cases' {
        $s = New-MigrationSettings -Label 'X'
        $s.Domains.Target = ' @Contoso.COM '
        $p = Join-Path $TestDrive 'domain-load.json'
        ($s | ConvertTo-Json -Depth 6) | Set-Content $p
        $r = Resolve-MigrationSettings -Path $p
        $r.IsValid | Should -BeTrue -Because ($r.Errors -join '; ')
        $r.Settings.Domains.Target | Should -Be 'contoso.com'
    }
}

Describe 'Save-MigrationSettings' {

    It 'writes UTF-8 without BOM, preserves key order, keeps a .bak' {
        $p = Join-Path $TestDrive 'w.json'
        Save-MigrationSettings -Path $p -Settings (New-MigrationSettings -Label 'One') | Out-Null
        Save-MigrationSettings -Path $p -Settings (New-MigrationSettings -Label 'Two') | Out-Null

        $bytes = [System.IO.File]::ReadAllBytes($p)
        ($bytes[0..2] -join ',') | Should -Not -Be '239,187,191'
        (Get-Content $p -Raw) | Should -Match '"SchemaVersion": 1,\s*"Label": "Two"'
        (Resolve-MigrationSettings -Path "$p.bak").Settings.Label | Should -Be 'One'
    }

    It 'refuses to write an invalid document' {
        $s = New-MigrationSettings -Label ''
        { Save-MigrationSettings -Path (Join-Path $TestDrive 'x.json') -Settings $s } | Should -Throw '*Label*'
    }

    It 'refuses to write when the parent folder does not exist' {
        $p = Join-Path $TestDrive 'does-not-exist' 'settings.json'
        { Save-MigrationSettings -Path $p -Settings (New-MigrationSettings -Label 'X') } |
            Should -Throw '*folder*does not exist*'
        Test-Path -LiteralPath $p | Should -BeFalse
    }

    It 'normalises a Domain value on save' {
        $p = Join-Path $TestDrive 'domain-save.json'
        $s = New-MigrationSettings -Label 'X'
        $s.Domains.Target = '@Contoso.COM'
        Save-MigrationSettings -Path $p -Settings $s | Out-Null
        (Resolve-MigrationSettings -Path $p).Settings.Domains.Target | Should -Be 'contoso.com'
    }

    It 'leaves the original file and content intact, and cleans up the .tmp, when the final move fails' {
        $p = Join-Path $TestDrive 'atomic.json'
        Save-MigrationSettings -Path $p -Settings (New-MigrationSettings -Label 'Original') | Out-Null
        $originalContent = Get-Content -LiteralPath $p -Raw

        InModuleScope M365Migration -Parameters @{ SettingsPath = $p } {
            param($SettingsPath)

            Mock Move-Item { throw 'simulated move failure' }
            $threw = $false
            try {
                Save-MigrationSettings -Path $SettingsPath -Settings (New-MigrationSettings -Label 'Changed')
            }
            catch {
                $threw = $true
            }
            $threw | Should -BeTrue -Because 'the mocked Move-Item must make the save fail'
        }

        (Get-Content -LiteralPath $p -Raw) | Should -Be $originalContent
        Test-Path -LiteralPath "$p.tmp" | Should -BeFalse
    }
}
