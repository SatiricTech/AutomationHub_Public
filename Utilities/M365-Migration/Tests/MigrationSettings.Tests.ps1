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
}
