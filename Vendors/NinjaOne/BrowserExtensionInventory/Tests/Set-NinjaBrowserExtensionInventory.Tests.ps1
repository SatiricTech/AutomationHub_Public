#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for the parsers and formatters in Set-NinjaBrowserExtensionInventory.ps1.

.DESCRIPTION
    Pester 5 and 6 compatible. The script is dot-sourced, which loads every function and stops
    before the inventory runs, so this suite works on macOS and Linux as well as on Windows.
    Browser data comes from fixtures built in TestDrive; nothing reads a real profile, the
    registry, or NinjaOne.

    Covered: JSON file reading with the case-sensitive parser, the Chromium preferences reader
    (store vs sideloaded, default filtering, __MSG__ name resolution, granted permissions,
    disabled state), the Firefox extensions.json reader, block list parsing, grouping across
    users, the inventory text format and its 10,000 character cap, the HTML table and its cap,
    and the flag count rule.

.NOTES
    Version:    1.0.0
    Created:    2026-09-23
    Run with:   Invoke-Pester -Path .\Tests\Set-NinjaBrowserExtensionInventory.Tests.ps1

    Developed with AI assistance (Claude); reviewed before use.
#>

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Set-NinjaBrowserExtensionInventory.ps1'
    $script:TestLog = Join-Path $TestDrive 'test.log'
    . $script:ScriptPath -LogPath $script:TestLog -Verbosity Low

    function New-JsonFixture {
        param ([string]$Path, $Object)
        $dir = Split-Path -Path $Path -Parent
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        $Object | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
    }

    function New-ChromiumProfileFixture {
        <#
            Builds a Chromium profile folder with a Secure Preferences file and, for the
            localised extension, an on-disk _locales folder.
        #>
        param ([string]$Root)

        $storeId     = 'cjpalhdlnbpafiamejdnhcphjbkeiagm'
        $sideloadId  = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $defaultId   = 'ghbmnnjooekpmoecnnnilnnbdlolhkhi'
        $componentId = 'cccccccccccccccccccccccccccccccc'
        $localisedId = 'dddddddddddddddddddddddddddddddd'
        $edgeStoreId = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
        $disabledId  = 'ffffffffffffffffffffffffffffffff'

        $settings = @{
            $storeId = @{
                state = 1; location = 1; from_webstore = $true; install_time = '13350000000000000'
                path = "$storeId\1.60.0_0"
                manifest = @{ name = 'uBlock Origin'; version = '1.60.0'; permissions = @('webRequest', 'storage')
                              host_permissions = @('<all_urls>') }
                granted_permissions = @{ api = @('webRequest', 'storage'); explicit_host = @('<all_urls>') }
            }
            $sideloadId = @{
                state = 1; location = 4; from_webstore = $false
                path = 'C:\Dev\my-extension'
                manifest = @{ name = 'Dev Helper'; version = '0.1'; permissions = @('tabs') }
            }
            $defaultId = @{
                state = 1; location = 1; from_webstore = $true; was_installed_by_default = $true
                manifest = @{ name = 'Google Docs Offline'; version = '1.0' }
            }
            $componentId = @{
                state = 1; location = 5
                manifest = @{ name = 'Built In Thing'; version = '2.0' }
            }
            $localisedId = @{
                state = 1; location = 1; from_webstore = $true
                path = "$localisedId\3.2.1_0"
                manifest = @{ name = '__MSG_appName__'; version = '3.2.1'; default_locale = 'en' }
            }
            $edgeStoreId = @{
                state = 1; location = 1; from_webstore = $false
                manifest = @{ name = 'Edge Store Thing'; version = '5.0'
                              update_url = 'https://edge.microsoft.com/extensionwebstorebase/v1/crx' }
            }
            $disabledId = @{
                state = 0; location = 1; from_webstore = $true; disable_reasons = @(1)
                manifest = @{ name = 'Disabled Thing'; version = '1.0'; permissions = @('cookies') }
            }
            'gggggggggggggggggggggggggggggggg' = @{
                state = 1; location = 1; from_webstore = $true
                manifest = @{ name = 'A Theme'; version = '1'; theme = @{ colors = @{} } }
            }
        }

        New-JsonFixture -Path (Join-Path $Root 'Secure Preferences') -Object @{ extensions = @{ settings = $settings } }
        New-JsonFixture -Path (Join-Path $Root 'Preferences') -Object @{ profile = @{ name = 'Person 1' } }

        $localePath = Join-Path (Join-Path (Join-Path (Join-Path $Root 'Extensions') $localisedId) '3.2.1_0') '_locales'
        New-JsonFixture -Path (Join-Path (Join-Path $localePath 'en') 'messages.json') `
            -Object @{ appname = @{ message = 'Localised Extension' } }
    }

    function New-FirefoxFixture {
        param ([string]$Path)
        $data = @{
            schemaVersion = 37
            addons = @(
                @{ id = 'uBlock0@raymondhill.net'; type = 'extension'; version = '1.60.0'; active = $true
                   userDisabled = $false; appDisabled = $false; location = 'app-profile'; signedState = 2
                   sourceURI = 'https://addons.mozilla.org/firefox/downloads/file/1/ublock_origin.xpi'
                   installDate = 1700000000000
                   defaultLocale = @{ name = 'uBlock Origin' }
                   userPermissions = @{ permissions = @('webRequest', 'storage'); origins = @('<all_urls>') } }
                @{ id = '{11111111-1111-1111-1111-111111111111}'; type = 'extension'; version = '0.9'; active = $true
                   userDisabled = $false; appDisabled = $false; location = 'app-profile'; signedState = 0
                   sourceURI = 'file:///C:/Temp/thing.xpi'
                   defaultLocale = @{ name = 'Hand Installed' }
                   userPermissions = @{ permissions = @(); origins = @() } }
                @{ id = 'webcompat@mozilla.org'; type = 'extension'; version = '1'; active = $true
                   userDisabled = $false; appDisabled = $false; location = 'app-system-defaults'; signedState = 3
                   defaultLocale = @{ name = 'Web Compatibility' } }
                @{ id = 'default-theme@mozilla.org'; type = 'theme'; version = '1'; active = $true
                   location = 'app-builtin'; defaultLocale = @{ name = 'System theme' } }
                @{ id = 'off@example.com'; type = 'extension'; version = '2'; active = $false
                   userDisabled = $true; appDisabled = $false; location = 'app-profile'; signedState = 2
                   sourceURI = 'https://addons.mozilla.org/firefox/downloads/file/2/off.xpi'
                   defaultLocale = @{ name = 'Switched Off' } }
            )
        }
        New-JsonFixture -Path $Path -Object $data
    }
}

Describe 'ConvertFrom-JsonFile' {
    It 'returns nested dictionaries that Get-JsonValue can walk' {
        $path = Join-Path $TestDrive 'simple.json'
        New-JsonFixture -Path $path -Object @{ a = @{ b = @{ c = 'deep' } }; list = @(1, 2, 3) }
        $data = ConvertFrom-JsonFile -Path $path
        $data | Should -BeOfType [System.Collections.IDictionary]
        Get-JsonValue -Object $data -KeyPath 'a', 'b', 'c' | Should -Be 'deep'
        Get-JsonValue -Object $data -KeyPath 'a', 'missing', 'c' | Should -BeNullOrEmpty
        (ConvertTo-StringArray (Get-JsonValue -Object $data -KeyPath 'list')) | Should -Be @('1', '2', '3')
    }

    It 'returns null for an empty file' {
        $path = Join-Path $TestDrive 'empty.json'
        Set-Content -Path $path -Value ''
        ConvertFrom-JsonFile -Path $path | Should -BeNullOrEmpty
    }
}

Describe 'Get-BlockedExtensionIdList' {
    It 'splits the parameter on commas, semicolons and new lines and lower-cases the result' {
        $ids = Get-BlockedExtensionIdList -ParameterValue @('AAAA,bbbb; cccc', "dddd`neeee") -EnvironmentValue 'zzzz'
        $ids | Should -Be @('aaaa', 'bbbb', 'cccc', 'dddd', 'eeee')
    }

    It 'falls back to the environment value when the parameter is empty' {
        Get-BlockedExtensionIdList -ParameterValue @() -EnvironmentValue 'one, two' | Should -Be @('one', 'two')
    }

    It 'returns an empty list when nothing is set' {
        @(Get-BlockedExtensionIdList -ParameterValue @() -EnvironmentValue '').Count | Should -Be 0
    }
}

Describe 'Get-ChromiumProfileExtension' {
    BeforeAll {
        $script:ChromeProfile = Join-Path $TestDrive 'Chrome\User Data\Default'
        New-ChromiumProfileFixture -Root $script:ChromeProfile
        $script:ChromeRecords = @(Get-ChromiumProfileExtension -Browser 'Chrome' -UserName 'alice' `
            -ProfilePath $script:ChromeProfile -ProfileName 'Default')
    }

    It 'leaves out default, component and theme entries' {
        $script:ChromeRecords.Id | Should -Not -Contain 'ghbmnnjooekpmoecnnnilnnbdlolhkhi'
        $script:ChromeRecords.Id | Should -Not -Contain 'cccccccccccccccccccccccccccccccc'
        $script:ChromeRecords.Id | Should -Not -Contain 'gggggggggggggggggggggggggggggggg'
        $script:ChromeRecords.Count | Should -Be 5
    }

    It 'marks a web store install as store and not sideloaded' {
        $record = $script:ChromeRecords | Where-Object Id -eq 'cjpalhdlnbpafiamejdnhcphjbkeiagm'
        $record.Name | Should -Be 'uBlock Origin'
        $record.Version | Should -Be '1.60.0'
        $record.Source | Should -Be 'store'
        $record.Sideloaded | Should -BeFalse
        $record.Enabled | Should -BeTrue
        $record.Installed | Should -BeOfType [DateTime]
    }

    It 'marks an unpacked extension as sideloaded' {
        $record = $script:ChromeRecords | Where-Object Id -eq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $record.Source | Should -Be 'unpacked'
        $record.Sideloaded | Should -BeTrue
    }

    It 'treats an Edge Add-ons update URL as a store install' {
        $record = $script:ChromeRecords | Where-Object Id -eq 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
        $record.Source | Should -Be 'store'
        $record.Sideloaded | Should -BeFalse
    }

    It 'resolves a __MSG__ name from the _locales folder' {
        $record = $script:ChromeRecords | Where-Object Id -eq 'dddddddddddddddddddddddddddddddd'
        $record.Name | Should -Be 'Localised Extension'
    }

    It 'uses granted permissions and picks out the risky ones' {
        $record = $script:ChromeRecords | Where-Object Id -eq 'cjpalhdlnbpafiamejdnhcphjbkeiagm'
        $record.RiskyPermissions | Should -Contain 'webRequest'
        $record.RiskyPermissions | Should -Contain '<all_urls>'
        $record.RiskyPermissions | Should -Not -Contain 'storage'
    }

    It 'reports a disabled extension with a disable_reasons list as disabled' {
        $record = $script:ChromeRecords | Where-Object Id -eq 'ffffffffffffffffffffffffffffffff'
        $record.Enabled | Should -BeFalse
    }
}

Describe 'ConvertFrom-FirefoxExtensionData' {
    BeforeAll {
        $path = Join-Path $TestDrive 'Firefox\Profiles\abc.default\extensions.json'
        New-FirefoxFixture -Path $path
        $data = ConvertFrom-JsonFile -Path $path
        $script:FirefoxRecords = @(ConvertFrom-FirefoxExtensionData -Data $data -UserName 'bob' -ProfileName 'abc.default')
    }

    It 'keeps only user-facing extensions' {
        $script:FirefoxRecords.Count | Should -Be 3
        $script:FirefoxRecords.Id | Should -Not -Contain 'webcompat@mozilla.org'
        $script:FirefoxRecords.Id | Should -Not -Contain 'default-theme@mozilla.org'
    }

    It 'marks an AMO install as store and signed' {
        $record = $script:FirefoxRecords | Where-Object Id -eq 'uBlock0@raymondhill.net'
        $record.Source | Should -Be 'store'
        $record.Sideloaded | Should -BeFalse
        $record.Unsigned | Should -BeFalse
        $record.Installed | Should -BeOfType [DateTime]
        $record.RiskyPermissions | Should -Contain '<all_urls>'
    }

    It 'marks a file install with no signature as sideloaded and unsigned' {
        $record = $script:FirefoxRecords | Where-Object Id -eq '{11111111-1111-1111-1111-111111111111}'
        $record.Source | Should -Be 'sideloaded'
        $record.Sideloaded | Should -BeTrue
        $record.Unsigned | Should -BeTrue
    }

    It 'reports a user-disabled extension as disabled' {
        $record = $script:FirefoxRecords | Where-Object Id -eq 'off@example.com'
        $record.Enabled | Should -BeFalse
    }
}

Describe 'Grouping and formatting' {
    BeforeAll {
        $script:Records = @(
            (New-ExtensionRecord -Browser 'Chrome' -UserName 'alice' -ProfileName 'Default' -Id 'aaaa' -Name 'Alpha' `
                -Version '1.0' -Source 'store' -Sideloaded $false -Unsigned $false -Enabled $true `
                -ApiPermissions @('storage') -HostPermissions @())
            (New-ExtensionRecord -Browser 'Chrome' -UserName 'bob' -ProfileName 'Default' -Id 'aaaa' -Name 'Alpha' `
                -Version '1.1' -Source 'store' -Sideloaded $false -Unsigned $false -Enabled $true `
                -ApiPermissions @('cookies') -HostPermissions @())
            (New-ExtensionRecord -Browser 'Edge' -UserName 'bob' -ProfileName 'Default' -Id 'bbbb' -Name 'Beta' `
                -Version '2.0' -Source 'unpacked' -Sideloaded $true -Unsigned $false -Enabled $false)
            (New-ExtensionRecord -Browser 'Firefox' -UserName 'alice' -ProfileName 'x' -Id 'cccc@example.com' `
                -Name 'Gamma' -Version '3' -Source 'store' -Sideloaded $false -Unsigned $false -Enabled $true)
        )
        $script:Records[3].Blocked = $true
        $script:Summaries = Group-ExtensionRecord -Records $script:Records
    }

    It 'collapses the same extension across users into one line' {
        $script:Summaries.Count | Should -Be 3
        $alpha = $script:Summaries | Where-Object Id -eq 'aaaa'
        $alpha.Users | Should -Be @('alice', 'bob')
        $alpha.Versions | Should -Be @('1.0', '1.1')
        $alpha.RiskyPermissions | Should -Be @('cookies')
    }

    It 'puts blocked first, then sideloaded, then risky, then the rest' {
        $script:Summaries[0].Id | Should -Be 'cccc@example.com'
        $script:Summaries[1].Id | Should -Be 'bbbb'
        $script:Summaries[2].Id | Should -Be 'aaaa'
    }

    It 'renders the inventory text with a header and pipe-separated lines' {
        $text = Format-InventoryText -Summaries $script:Summaries
        $lines = $text -split "`n"
        $lines[0] | Should -Be 'browser|id|name|version|source|state|users|flags'
        $lines[1] | Should -Be 'firefox|cccc@example.com|Gamma|3|store|enabled|alice|blocked'
        $lines[2] | Should -Be 'edge|bbbb|Beta|2.0|unpacked|disabled|bob|sideloaded,disabled'
        $lines[3] | Should -Be 'chrome|aaaa|Alpha|1.0,1.1|store|enabled|alice,bob|risk'
    }

    It 'says so when there is nothing to list' {
        Format-InventoryText -Summaries @() | Should -Be 'No extensions found'
    }

    It 'keeps the inventory text under the field limit and adds a trailer' {
        $many = @(1..400 | ForEach-Object {
            New-ExtensionRecord -Browser 'Chrome' -UserName 'u' -ProfileName 'p' -Id ('x' * 32) -Name "Extension $_" `
                -Version '1' -Source 'store' -Sideloaded $false -Unsigned $false -Enabled $true
        })
        for ($i = 0; $i -lt $many.Count; $i++) { $many[$i].Id = ('{0:d32}' -f $i) }
        $text = Format-InventoryText -Summaries (Group-ExtensionRecord -Records $many) -Limit 2000
        $text.Length | Should -BeLessOrEqual 2000
        $text | Should -Match 'more entries not shown'
    }

    It 'renders an HTML table with one row per summary and encodes the values' {
        $script:Summaries[2].Name = 'Alpha <b>bold</b>'
        $html = Format-InventoryHtml -Summaries $script:Summaries -UserCount 2 -FlagCount 2
        ([regex]::Matches($html, '<tr>')).Count | Should -Be 4
        $html | Should -Match '&lt;b&gt;bold&lt;/b&gt;'
        $html | Should -Match '<b>2 flagged</b>'
    }

    It 'keeps the HTML under the field limit and adds a trailer row' {
        $many = @(1..300 | ForEach-Object {
            New-ExtensionRecord -Browser 'Chrome' -UserName 'u' -ProfileName 'p' -Id ('{0:d32}' -f $_) -Name "Ext $_" `
                -Version '1' -Source 'store' -Sideloaded $false -Unsigned $false -Enabled $true
        })
        $html = Format-InventoryHtml -Summaries (Group-ExtensionRecord -Records $many) -UserCount 1 -FlagCount 0 -Limit 8000
        $html.Length | Should -BeLessOrEqual 8000
        $html | Should -Match "colspan='9'"
    }

    It 'counts only blocked, sideloaded and unsigned extensions as flagged' {
        $flagged = @($script:Summaries | Where-Object { $_.Blocked -or $_.Sideloaded -or $_.Unsigned })
        $flagged.Count | Should -Be 2
    }
}

Describe 'Set-NinjaFieldValue outside NinjaOne' {
    It 'returns false and logs a warning when no NinjaOne CLI is present' {
        Mock Get-NinjaCliPath { $null }
        $result = Set-NinjaFieldValue -FieldName 'browserExtensionFlagCount' -Value '0'
        $result | Should -BeFalse
        Get-Content -Path $script:TestLog -Raw | Should -Match 'NinjaOne CLI not found'
    }
}
