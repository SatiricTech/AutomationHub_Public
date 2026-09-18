#Requires -Version 5.1

<#
.SYNOPSIS
    Pester tests for New-ServiceWatchdogClientPackage.ps1, the client package builder.

.DESCRIPTION
    Pester 5 and 6 compatible, and cross-platform: the builder itself touches nothing
    Windows-specific, so every test here runs on macOS and Linux as well as on Windows.

    The script is run for real rather than dot-sourced, because its exit code and its console
    output are part of the contract: a refusal has to be exit 2 and the hand-over summary must
    never contain the function key. Every build goes into $TestDrive, which Pester removes
    afterwards, so no package holding a test key survives the run.

    Covered: the file set and folder shape, the settings file's content and shape, the two
    VERSION stamps, URL normalisation and its refusals, the Defaults override and its guards,
    the git-working-tree refusal, the existing-folder refusal, -DryRun, and the promise that
    the key never reaches the console.

.NOTES
    Version:    1.0.0
    Created:    2026-09-17
    Run with:   Invoke-Pester -Path .\Tests\New-ServiceWatchdogClientPackage.Tests.ps1

    Developed with AI assistance (Claude); reviewed before publication.
#>

BeforeAll {
    $script:PackageDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'Package'
    $script:Builder = Join-Path $script:PackageDir 'New-ServiceWatchdogClientPackage.ps1'

    # Obviously fake, but long enough to look like a real function key and to be searched for in
    # the console output. Nothing here is a credential.
    $script:TestKey = 'zzzzTESTKEYzzzz1111222233334444555566667777888899990000aaaabbbbcccc'

    $script:GoodUrl = 'https://func-example-a1b2c3.azurewebsites.net/api/servicewatchdog/alert'

    function Invoke-Builder {
        <#
        .SYNOPSIS
            Runs the builder with the test key, returning its exit code and merged output.
        #>
        [CmdletBinding()]
        param (
            [hashtable]$Parameter = @{},
            [switch]$NoKey
        )
        $arguments = @{
            ClientName  = 'Example Org'
            FunctionUrl = $script:GoodUrl
        }
        if (-not $NoKey) { $arguments['FunctionKeyPlainText'] = $script:TestKey }
        foreach ($key in $Parameter.Keys) { $arguments[$key] = $Parameter[$key] }

        $output = & $script:Builder @arguments *>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = (@($output) -join "`n")
        }
    }

    function New-BuildTarget {
        <#
        .SYNOPSIS
            Returns a fresh, empty output folder path under $TestDrive.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture creating a folder under TestDrive; -WhatIf would serve no purpose.')]
        [CmdletBinding()]
        param ()
        $path = Join-Path $TestDrive ('out-{0}' -f [guid]::NewGuid())
        New-Item -Path $path -ItemType Directory -Force | Out-Null
        return $path
    }
}

Describe 'New-ServiceWatchdogClientPackage: a normal build' {

    BeforeAll {
        $script:Target = New-BuildTarget
        $script:Result = Invoke-Builder -Parameter @{ OutputPath = $script:Target }
        $script:Root = Join-Path $script:Target 'ServiceWatchdog'
    }

    It 'exits 0' {
        $script:Result.ExitCode | Should -Be 0
    }

    It 'creates the ServiceWatchdog folder with an Endpoint subfolder' {
        Test-Path -LiteralPath $script:Root -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Root 'Endpoint') -PathType Container | Should -BeTrue
    }

    It 'writes exactly the expected files at the package root' {
        @(Get-ChildItem -LiteralPath $script:Root -File | ForEach-Object { $_.Name } | Sort-Object) |
            Should -Be @('Install-WinServiceWatchdogGui.ps1', 'PACKAGE-VERSION.txt',
                'Run-ServiceWatchdog.cmd', 'ServiceWatchdog.settings.example.json',
                'ServiceWatchdog.settings.json')
    }

    It 'pins the three endpoint scripts, the example config and a VERSION stamp' {
        @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'Endpoint') -File |
                ForEach-Object { $_.Name } | Sort-Object) |
            Should -Be @('Invoke-WinServiceWatchdog.ps1', 'Register-WinServiceWatchdogTask.ps1',
                'ServiceWatchdog.example.json', 'Unregister-WinServiceWatchdogTask.ps1', 'VERSION.txt')
    }

    It 'copies the endpoint scripts byte for byte' {
        $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'Endpoint'
        foreach ($name in @('Invoke-WinServiceWatchdog.ps1', 'Register-WinServiceWatchdogTask.ps1',
                'Unregister-WinServiceWatchdogTask.ps1')) {
            $copied = Get-FileHash -LiteralPath (Join-Path (Join-Path $script:Root 'Endpoint') $name)
            $original = Get-FileHash -LiteralPath (Join-Path $source $name)
            $copied.Hash | Should -Be $original.Hash
        }
    }
}

Describe 'New-ServiceWatchdogClientPackage: the settings file it writes' {

    BeforeAll {
        $script:Target = New-BuildTarget
        Invoke-Builder -Parameter @{ OutputPath = $script:Target } | Out-Null
        $script:SettingsPath = Join-Path (Join-Path $script:Target 'ServiceWatchdog') `
            'ServiceWatchdog.settings.json'
        $script:Settings = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
    }

    It 'carries the schema version, client name, URL and key' {
        $script:Settings.SchemaVersion | Should -Be 1
        $script:Settings.ClientName | Should -Be 'Example Org'
        $script:Settings.Webhook.Url | Should -Be $script:GoodUrl
        $script:Settings.Webhook.FunctionKey | Should -Be $script:TestKey
        $script:Settings.Webhook.TimeoutSeconds | Should -Be 30
    }

    It 'has the property order and shape the GUI validates' {
        @($script:Settings.PSObject.Properties.Name) |
            Should -Be @('SchemaVersion', 'ClientName', 'Webhook', 'Defaults')
        @($script:Settings.Webhook.PSObject.Properties.Name) |
            Should -Be @('Url', 'FunctionKey', 'TimeoutSeconds')
        @($script:Settings.Defaults.PSObject.Properties.Name) |
            Should -Be @('MaxStartAttempts', 'RetryDelaySeconds', 'PostStartVerifySeconds',
                'StartPendingWaitSeconds', 'MaxRunSeconds', 'Alerting', 'Logging')
    }

    It 'carries the shipped defaults when nothing overrides them' {
        $script:Settings.Defaults.MaxStartAttempts | Should -Be 5
        $script:Settings.Defaults.RetryDelaySeconds | Should -Be 30
        $script:Settings.Defaults.MaxRunSeconds | Should -Be 240
        $script:Settings.Defaults.Alerting.ReminderMinutes | Should -Be 240
        $script:Settings.Defaults.Alerting.NotifyOnRemediation | Should -BeFalse
        $script:Settings.Defaults.Logging.LogRetentionDays | Should -Be 30
    }

    It 'contains no REPLACE placeholder anywhere' {
        (Get-Content -LiteralPath $script:SettingsPath -Raw) | Should -Not -Match 'REPLACE'
    }

    It 'is accepted by the GUI it was built for' {
        # The real contract: the settings file has to satisfy the same validation the GUI runs at
        # startup, or the technician meets a refusal dialog instead of a service list.
        . (Join-Path $script:PackageDir 'Install-WinServiceWatchdogGui.ps1') -NoGui
        $result = Resolve-WatchdogGuiSettings -Path $script:SettingsPath
        $result.IsValid | Should -BeTrue
        @($result.Errors).Count | Should -Be 0
    }
}

Describe 'New-ServiceWatchdogClientPackage: the version stamps' {

    BeforeAll {
        $script:Target = New-BuildTarget
        Invoke-Builder -Parameter @{ OutputPath = $script:Target } | Out-Null
        $script:Root = Join-Path $script:Target 'ServiceWatchdog'
        $script:EndpointStamp = Get-Content -LiteralPath (Join-Path (Join-Path $script:Root 'Endpoint') `
                'VERSION.txt') -Raw
        $script:PackageStamp = Get-Content -LiteralPath (Join-Path $script:Root 'PACKAGE-VERSION.txt') -Raw
    }

    It 'records a source commit in both stamps' {
        $script:EndpointStamp | Should -Match 'Source commit:\s+\S+'
        $script:PackageStamp | Should -Match 'Source commit:\s+\S+'
    }

    It 'stamps the same source in both files' {
        $endpoint = [regex]::Match($script:EndpointStamp, 'Source commit:\s+(\S+)').Groups[1].Value
        $package = [regex]::Match($script:PackageStamp, 'Source commit:\s+(\S+)').Groups[1].Value
        $package | Should -Be $endpoint
    }

    It 'uses the git short SHA when the build runs inside the repository' {
        # The suite runs from a clone, so the stamp should be a SHA rather than the date fallback.
        # When git is genuinely unavailable the fallback form is asserted instead, because a
        # builder that failed without git would be worse than one that stamps a date.
        $stamped = [regex]::Match($script:PackageStamp, 'Source commit:\s+(\S+)').Groups[1].Value
        if (Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue) {
            $stamped | Should -Match '^[0-9a-f]{7,40}$'
        }
        else {
            $stamped | Should -Match '^no-git-\d{8}$'
        }
    }

    It 'names what it was built by and when' {
        $script:PackageStamp | Should -Match 'New-ServiceWatchdogClientPackage\.ps1'
        $script:PackageStamp | Should -Match 'Built:\s+\d{4}-\d{2}-\d{2}'
        $script:EndpointStamp | Should -Match 'Do not edit here'
    }
}

Describe 'New-ServiceWatchdogClientPackage: the key never reaches the console' {

    It 'prints a summary that names the key only by length' {
        $target = New-BuildTarget
        $result = Invoke-Builder -Parameter @{ OutputPath = $target; Verbosity = 'High' }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Not -Match ([regex]::Escape($script:TestKey))
        $result.Output | Should -Match "$($script:TestKey.Length) characters"
        $result.Output | Should -Match 'ServiceWatchdog package built'
    }

    It 'warns that a plain-text key is in the shell history' {
        $target = New-BuildTarget
        (Invoke-Builder -Parameter @{ OutputPath = $target }).Output |
            Should -Match 'passed as plain text'
    }

    It 'accepts a SecureString key without echoing it' {
        $target = New-BuildTarget
        $secure = ConvertTo-SecureString -String $script:TestKey -AsPlainText -Force
        $output = & $script:Builder -ClientName 'Example Org' -FunctionUrl $script:GoodUrl `
            -FunctionKey $secure -OutputPath $target *>&1
        $LASTEXITCODE | Should -Be 0
        (@($output) -join "`n") | Should -Not -Match ([regex]::Escape($script:TestKey))
        $settings = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $target 'ServiceWatchdog') `
                'ServiceWatchdog.settings.json') | ConvertFrom-Json
        $settings.Webhook.FunctionKey | Should -Be $script:TestKey
    }
}

Describe 'New-ServiceWatchdogClientPackage: URL handling' {

    It 'completes a bare host name into the full alert URL' {
        $target = New-BuildTarget
        $result = Invoke-Builder -Parameter @{
            OutputPath  = $target
            FunctionUrl = 'func-example-a1b2c3.azurewebsites.net'
        }
        $result.ExitCode | Should -Be 0
        $settings = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $target 'ServiceWatchdog') `
                'ServiceWatchdog.settings.json') | ConvertFrom-Json
        $settings.Webhook.Url | Should -Be $script:GoodUrl
    }

    It 'completes an https host with no path' {
        $target = New-BuildTarget
        Invoke-Builder -Parameter @{
            OutputPath  = $target
            FunctionUrl = 'https://func-example-a1b2c3.azurewebsites.net/'
        } | Out-Null
        $settings = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $target 'ServiceWatchdog') `
                'ServiceWatchdog.settings.json') | ConvertFrom-Json
        $settings.Webhook.Url | Should -Be $script:GoodUrl
    }

    It 'refuses http' {
        $target = New-BuildTarget
        $result = Invoke-Builder -Parameter @{
            OutputPath  = $target
            FunctionUrl = 'http://func-example.azurewebsites.net/api/servicewatchdog/alert'
        }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'must be https'
        Test-Path -LiteralPath (Join-Path $target 'ServiceWatchdog') | Should -BeFalse
    }

    It 'refuses the wrong path' {
        $target = New-BuildTarget
        $result = Invoke-Builder -Parameter @{
            OutputPath  = $target
            FunctionUrl = 'https://func-example.azurewebsites.net/api/alert'
        }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match '/api/servicewatchdog/alert'
    }

    It 'refuses a query string, because the key is a header not a code parameter' {
        $target = New-BuildTarget
        $result = Invoke-Builder -Parameter @{
            OutputPath  = $target
            FunctionUrl = 'https://func-example.azurewebsites.net/api/servicewatchdog/alert?code=abc'
        }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'x-functions-key'
    }
}

Describe 'New-ServiceWatchdogClientPackage: Defaults overrides' {

    It 'applies a Defaults override file' {
        $target = New-BuildTarget
        $defaults = Join-Path $TestDrive 'defaults.json'
        @{ MaxStartAttempts = 3; MaxRunSeconds = 180; Alerting = @{ HeartbeatHours = 6 } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $defaults -Encoding UTF8
        $result = Invoke-Builder -Parameter @{ OutputPath = $target; DefaultsPath = $defaults }
        $result.ExitCode | Should -Be 0
        $settings = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $target 'ServiceWatchdog') `
                'ServiceWatchdog.settings.json') | ConvertFrom-Json
        $settings.Defaults.MaxStartAttempts | Should -Be 3
        $settings.Defaults.MaxRunSeconds | Should -Be 180
        $settings.Defaults.Alerting.HeartbeatHours | Should -Be 6
        # Everything it did not mention keeps the shipped value.
        $settings.Defaults.RetryDelaySeconds | Should -Be 30
        $settings.Defaults.Alerting.ReminderMinutes | Should -Be 240
    }

    It 'accepts a whole settings file as the override source' {
        $target = New-BuildTarget
        $defaults = Join-Path $TestDrive 'whole.json'
        @{ SchemaVersion = 1; Defaults = @{ RetryDelaySeconds = 45 } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $defaults -Encoding UTF8
        Invoke-Builder -Parameter @{ OutputPath = $target; DefaultsPath = $defaults } | Out-Null
        $settings = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $target 'ServiceWatchdog') `
                'ServiceWatchdog.settings.json') | ConvertFrom-Json
        $settings.Defaults.RetryDelaySeconds | Should -Be 45
    }

    It 'refuses an unknown key rather than silently ignoring it' {
        $target = New-BuildTarget
        $defaults = Join-Path $TestDrive 'typo.json'
        @{ MaxStartAttemps = 3 } | ConvertTo-Json | Set-Content -LiteralPath $defaults -Encoding UTF8
        $result = Invoke-Builder -Parameter @{ OutputPath = $target; DefaultsPath = $defaults }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match "unknown key 'MaxStartAttemps'"
    }

    It 'refuses a MaxRunSeconds the scheduled task could not cover' {
        $target = New-BuildTarget
        $defaults = Join-Path $TestDrive 'toolong.json'
        @{ MaxRunSeconds = 400 } | ConvertTo-Json | Set-Content -LiteralPath $defaults -Encoding UTF8
        $result = Invoke-Builder -Parameter @{ OutputPath = $target; DefaultsPath = $defaults }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match '420 second execution limit'
        $result.Output | Should -Match 'Lower MaxRunSeconds to 275 or less'
    }

    It 'refuses a missing override file' {
        $target = New-BuildTarget
        $result = Invoke-Builder -Parameter @{
            OutputPath   = $target
            DefaultsPath = (Join-Path $TestDrive 'no-such-defaults.json')
        }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'DefaultsPath file not found'
    }
}

Describe 'New-ServiceWatchdogClientPackage: refusals that protect the key' {

    It 'refuses to build inside a git working tree without -Force' {
        $tree = Join-Path $TestDrive ('tree-{0}' -f [guid]::NewGuid())
        New-Item -Path (Join-Path $tree '.git') -ItemType Directory -Force | Out-Null
        $target = Join-Path $tree 'build'
        New-Item -Path $target -ItemType Directory -Force | Out-Null

        $result = Invoke-Builder -Parameter @{ OutputPath = $target }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'inside a git working tree'
        Test-Path -LiteralPath (Join-Path $target 'ServiceWatchdog') | Should -BeFalse
    }

    It 'builds inside a git working tree with -Force, but warns about the key' {
        $tree = Join-Path $TestDrive ('tree-{0}' -f [guid]::NewGuid())
        New-Item -Path (Join-Path $tree '.git') -ItemType Directory -Force | Out-Null
        $target = Join-Path $tree 'build'

        $result = Invoke-Builder -Parameter @{ OutputPath = $target; Force = $true }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'git-ignored'
        Test-Path -LiteralPath (Join-Path (Join-Path $target 'ServiceWatchdog') `
                'ServiceWatchdog.settings.json') | Should -BeTrue
    }

    It 'treats a .git file (a worktree or submodule) as a working tree too' {
        $tree = Join-Path $TestDrive ('wt-{0}' -f [guid]::NewGuid())
        New-Item -Path $tree -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tree '.git') -Value 'gitdir: /elsewhere/.git/worktrees/x'
        (Invoke-Builder -Parameter @{ OutputPath = $tree }).ExitCode | Should -Be 2
    }

    It 'refuses an existing package folder without -Force' {
        $target = New-BuildTarget
        (Invoke-Builder -Parameter @{ OutputPath = $target }).ExitCode | Should -Be 0
        $again = Invoke-Builder -Parameter @{ OutputPath = $target }
        $again.ExitCode | Should -Be 2
        $again.Output | Should -Match 'already exists'
    }

    It 'overwrites an existing package folder with -Force' {
        $target = New-BuildTarget
        Invoke-Builder -Parameter @{ OutputPath = $target } | Out-Null
        $result = Invoke-Builder -Parameter @{
            OutputPath = $target
            ClientName = 'Second Pass'
            Force      = $true
        }
        $result.ExitCode | Should -Be 0
        $settings = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $target 'ServiceWatchdog') `
                'ServiceWatchdog.settings.json') | ConvertFrom-Json
        $settings.ClientName | Should -Be 'Second Pass'
    }

    It 'refuses a ClientName that still contains REPLACE' {
        $target = New-BuildTarget
        $result = Invoke-Builder -Parameter @{ OutputPath = $target; ClientName = 'REPLACE_ME' }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'ClientName still contains REPLACE'
    }

    It 'refuses a key that still contains REPLACE' {
        $target = New-BuildTarget
        $result = Invoke-Builder -NoKey -Parameter @{
            OutputPath           = $target
            FunctionKeyPlainText = 'REPLACE_WITH_FUNCTION_KEY'
        }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'still contains REPLACE'
    }
}

Describe 'New-ServiceWatchdogClientPackage: -DryRun' {

    It 'writes nothing and still prints the plan' {
        $target = New-BuildTarget
        $result = Invoke-Builder -Parameter @{ OutputPath = $target; DryRun = $true; Verbosity = 'High' }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'NOT built'
        $result.Output | Should -Not -Match ([regex]::Escape($script:TestKey))
        @(Get-ChildItem -LiteralPath $target -Recurse -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
