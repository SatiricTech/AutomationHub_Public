#Requires -Version 7.4

<#
    New-MigrationStepDriver turns a resolved argument list into the one artefact that actually
    runs: Workbench/Runs/<ts>_<StepId>/driver.ps1 (Docs/Workbench-Design.md, section 7.3).

    The driver exists because 'pwsh -File' flattens every argument to a string - an array
    arrives as '1 2', a [bool] as the string 'False', a hashtable as its type name - while a
    splat inside a file binds properly. So the assertions below do not stop at the text of the
    generated file: the decisive ones run the driver in a real child pwsh and read back the
    JSON the fixture echoes, because that round trip is the only proof the rendering is right.

    Tests/Fixtures/Workbench/Echo-Parameters.ps1 stands in for the 17 toolkit scripts.
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:EchoPath = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Echo-Parameters.ps1')).Path
    $script:FixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Workspace1'
    $script:Stamp = [datetime]::new(2026, 9, 18, 14, 30, 5)

    # A step of the real shape, built by the real builder, pointed at the echo fixture: the
    # driver writer must work against what Get-MigrationStep hands it, not a hand-rolled bag
    # of properties that happens to carry the four fields it reads today.
    $script:EchoStep = InModuleScope M365Migration -Parameters @{ Path = $script:EchoPath } {
        param($Path)
        $introspection = Get-MigrationScriptParameter -ScriptPath $Path
        $entry = @{
            Title     = 'Echo the parameters'
            Phase     = 'Prepare'
            Side      = 'Destination'
            Impact    = 'Write'
            ExitCodes = @{ 0 = 'Completed'; 1 = 'Failed'; 2 = 'Some rows failed'; 3 = 'Work remains' }
        }
        New-MigrationStepObject -Entry $entry -Instance @{ Id = 'Echo-Step' } -Id 'Echo-Step' `
            -Script 'Echo-Parameters' -ScriptPath $Path -Introspection $introspection
    }

    function Get-TestArgument {
        param([string]$Name, $Value, [string]$Source = 'Operator')
        return [pscustomobject]@{
            Name       = $Name
            Value      = $Value
            Source     = $Source
            Warning    = $null
            Candidates = @()
        }
    }

    # The shape Resolve-MigrationStepArguments returns.
    function Get-TestArgumentSet {
        param([object[]]$Argument, [string]$ParameterSet = 'Plan')
        return [pscustomobject]@{
            Arguments        = @($Argument)
            ParameterSet     = $ParameterSet
            MissingMandatory = @()
            Warnings         = @()
        }
    }

    function New-TestWorkspace {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pester helper that creates an empty workspace folder under TestDrive.')]
        param([string]$Name = 'Workspace')
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        return [pscustomobject]@{ Path = $path; Label = 'Contoso' }
    }

    # The canonical argument list: a path with an embedded quote, an array, a switch, a [bool]
    # that must not become $true, a hashtable, and a Default that must not be emitted at all.
    function Get-TestCanonicalArgumentSet {
        return Get-TestArgumentSet -Argument @(
            (Get-TestArgument -Name 'PlanPath' -Value "C:\it's here\p.csv" -Source 'Resolved')
            (Get-TestArgument -Name 'Wave' -Value @('1', '2') -Source 'Operator')
            (Get-TestArgument -Name 'DryRun' -Value $true -Source 'Common')
            (Get-TestArgument -Name 'ForceChangePassword' -Value $false -Source 'Settings')
            (Get-TestArgument -Name 'AliasDomainMap' -Value @{ 'contoso.com' = 'newco.com' } -Source 'Settings')
            (Get-TestArgument -Name 'Prefix' -Value 'Contoso' -Source 'Settings')
            (Get-TestArgument -Name 'Verbosity' -Value 'Medium' -Source 'Default')
            (Get-TestArgument -Name 'TenantId' -Value $null -Source 'Settings')
        )
    }

    function Test-DriverParse {
        param([string]$Path)
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        return (@($errors).Count -eq 0)
    }
}

Describe 'New-MigrationStepDriver' {

    Context 'the run folder and the returned object' {

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'DriverShape'
            $script:Result = New-MigrationStepDriver -Step $script:EchoStep `
                -Arguments (Get-TestCanonicalArgumentSet) -Workspace $script:Workspace `
                -Timestamp $script:Stamp -Version '1.2.0'
        }

        It 'names the run with the timestamp and the step id' {
            $script:Result.RunId | Should -BeExactly '20260918-143005_Echo-Step'
        }

        It 'puts the run folder under Workbench/Runs, never in the repo' {
            $expected = Join-Path $script:Workspace.Path 'Workbench' 'Runs' '20260918-143005_Echo-Step'
            $script:Result.RunFolder | Should -BeExactly $expected
            Test-Path -LiteralPath $script:Result.RunFolder -PathType Container | Should -BeTrue
        }

        It 'writes driver.ps1 into the run folder' {
            $script:Result.DriverPath | Should -BeExactly (Join-Path $script:Result.RunFolder 'driver.ps1')
            Test-Path -LiteralPath $script:Result.DriverPath -PathType Leaf | Should -BeTrue
        }

        It 'returns the pwsh the workbench is running and the command line that starts it' {
            $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $script:Result.PwshPath | Should -BeExactly $pwshPath
            $script:Result.CommandLine | Should -BeExactly ("& '$pwshPath' -NoProfile -NonInteractive " +
                "-ExecutionPolicy Bypass -File '$($script:Result.DriverPath)'")
        }
    }

    Context 'paths that hold a quote or a space' {

        It 'returns a command line that still parses when both are awkward' {
            # 'C:\Program Files\PowerShell\7\pwsh.exe' holds a space and a workspace can hold an
            # apostrophe. A command line the operator cannot paste back is worse than none.
            $workspace = New-TestWorkspace -Name "Ren's Workspace"
            $result = New-MigrationStepDriver -Step $script:EchoStep -Arguments (Get-TestCanonicalArgumentSet) `
                -Workspace $workspace -Timestamp $script:Stamp `
                -PwshPath 'C:\Program Files\PowerShell\7\pwsh.exe'

            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($result.CommandLine,
                [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0

            $result.CommandLine | Should -Match ([regex]::Escape("& 'C:\Program Files\PowerShell\7\pwsh.exe'"))
            $result.CommandLine | Should -Match ([regex]::Escape("Ren''s Workspace"))
            $result.PwshPath | Should -BeExactly 'C:\Program Files\PowerShell\7\pwsh.exe'
        }

        It 'still parses the driver it wrote into that folder' {
            $workspace = New-TestWorkspace -Name "Ren's Second Workspace"
            $result = New-MigrationStepDriver -Step $script:EchoStep -Arguments (Get-TestCanonicalArgumentSet) `
                -Workspace $workspace -Timestamp $script:Stamp
            Test-DriverParse -Path $result.DriverPath | Should -BeTrue
        }
    }

    Context 'two runs of one step in the same second' {

        It 'gives the second run a folder of its own' {
            $workspace = New-TestWorkspace -Name 'DriverSameSecond'
            $first = New-MigrationStepDriver -Step $script:EchoStep -Arguments (Get-TestCanonicalArgumentSet) `
                -Workspace $workspace -Timestamp $script:Stamp
            $second = New-MigrationStepDriver -Step $script:EchoStep -Arguments (Get-TestCanonicalArgumentSet) `
                -Workspace $workspace -Timestamp $script:Stamp
            $third = New-MigrationStepDriver -Step $script:EchoStep -Arguments (Get-TestCanonicalArgumentSet) `
                -Workspace $workspace -Timestamp $script:Stamp

            $first.RunId | Should -BeExactly '20260918-143005_Echo-Step'
            $second.RunId | Should -BeExactly '20260918-143005_Echo-Step-2'
            $third.RunId | Should -BeExactly '20260918-143005_Echo-Step-3'
            $second.DriverPath | Should -Not -BeExactly $first.DriverPath
            Test-Path -LiteralPath $first.DriverPath | Should -BeTrue
            Test-Path -LiteralPath $second.DriverPath | Should -BeTrue
        }
    }

    Context 'the generated driver file' {

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'DriverText'
            $script:Result = New-MigrationStepDriver -Step $script:EchoStep `
                -Arguments (Get-TestCanonicalArgumentSet) -Workspace $script:Workspace `
                -Timestamp $script:Stamp -Version '1.2.0'
            $script:Driver = Get-Content -LiteralPath $script:Result.DriverPath -Raw
            $script:DriverLines = @(Get-Content -LiteralPath $script:Result.DriverPath)
        }

        It 'parses with no errors' {
            Test-DriverParse -Path $script:Result.DriverPath | Should -BeTrue
        }

        It 'opens with the version requirement and the generated-by header' {
            $header = '# Generated by Start-MigrationWorkbench 1.2.0 on 2026-09-18 14:30:05 for ' +
            "$($script:Workspace.Path)."
            $script:DriverLines[0] | Should -BeExactly '#Requires -Version 7.4'
            $script:Driver | Should -Match ([regex]::Escape($header))
        }

        It 'tells the operator how to re-run it by hand' {
            $script:Driver | Should -Match ([regex]::Escape(
                    "# Re-run by hand: pwsh -NoProfile -File `"$($script:Result.DriverPath)`""))
        }

        It 'pins UTF-8 on both the console and the output encoding' {
            $script:Driver | Should -Match ([regex]::Escape('[Console]::OutputEncoding = [System.Text.Encoding]::UTF8'))
            $script:Driver | Should -Match ([regex]::Escape('$OutputEncoding = [System.Text.Encoding]::UTF8'))
        }

        It 'doubles the single quote inside a path rather than breaking the literal' {
            $script:Driver | Should -Match ([regex]::Escape("'C:\it''s here\p.csv'"))
        }

        It 'keeps an array an array' {
            $script:Driver | Should -Match "Wave\s+= @\('1', '2'\)"
        }

        It 'renders a switch as $true' {
            $script:Driver | Should -Match 'DryRun\s+= \$true'
        }

        It 'renders a [bool] $false as $false, not as a truthy string' {
            $script:Driver | Should -Match 'ForceChangePassword\s+= \$false'
        }

        It 'renders a hashtable as a hashtable literal' {
            $script:Driver | Should -Match ([regex]::Escape("@{ 'contoso.com' = 'newco.com' }"))
        }

        It 'omits an argument whose value the script itself would have chosen' {
            # Source 'Default' is recorded so a form can show it and deliberately not passed:
            # re-stating it here would freeze today's default into a file that outlives the script.
            $script:Driver | Should -Not -Match 'Verbosity'
        }

        It 'omits an argument with no value' {
            $script:Driver | Should -Not -Match 'TenantId'
        }

        It 'splats into the script by full path and propagates its exit code' {
            $script:Driver | Should -Match ([regex]::Escape("    & '$($script:EchoPath)' @parameters"))
            $script:DriverLines[-1] | Should -BeExactly 'exit ([int]$LASTEXITCODE)'
        }

        It 'guards the call so a splat that never binds cannot exit 0' {
            # An unset $LASTEXITCODE exits 0, which would have the workbench record 'Completed'
            # for a step that never ran.
            $script:Driver | Should -Match ([regex]::Escape('$ErrorActionPreference = ''Stop'''))
            $script:DriverLines | Should -Contain 'try {'
            $script:DriverLines | Should -Contain 'catch {'
            $script:DriverLines | Should -Contain '    Write-Error $_'
            $script:DriverLines | Should -Contain '    exit 1'
        }
    }

    Context 'the driver in a real child pwsh' {

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'DriverRun'
            $script:Result = New-MigrationStepDriver -Step $script:EchoStep `
                -Arguments (Get-TestCanonicalArgumentSet) -Workspace $script:Workspace `
                -Timestamp $script:Stamp
            $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $script:Output = @(& $pwshPath -NoProfile -NonInteractive -File $script:Result.DriverPath)
            $script:Echoed = $script:Output[0] | ConvertFrom-Json
        }

        It 'binds -Wave as an array of two strings, not as one flattened string' {
            @($script:Echoed.Wave).Count | Should -Be 2
            @($script:Echoed.Wave)[0] | Should -BeExactly '1'
            @($script:Echoed.Wave)[1] | Should -BeExactly '2'
        }

        It 'binds a [bool] $false as false' {
            $script:Echoed.ForceChangePassword | Should -BeFalse
        }

        It 'binds the quoted path back to exactly what was resolved' {
            $script:Echoed.PlanPath | Should -BeExactly "C:\it's here\p.csv"
        }

        It 'binds the hashtable as a hashtable' {
            $script:Echoed.AliasDomainMap.'contoso.com' | Should -BeExactly 'newco.com'
        }
    }

    Context 'the display line' {

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'DriverDisplay'
            $script:Result = New-MigrationStepDriver -Step $script:EchoStep `
                -Arguments (Get-TestCanonicalArgumentSet) -Workspace $script:Workspace `
                -Timestamp $script:Stamp
        }

        It 'names the script by its leaf name' {
            $script:Result.DisplayLine | Should -Match '^Echo-Parameters\.ps1 '
        }

        It 'quotes a path and leaves a simple token bare' {
            $script:Result.DisplayLine | Should -Match ([regex]::Escape("-PlanPath 'C:\it''s here\p.csv'"))
            $script:Result.DisplayLine | Should -Match '-Prefix Contoso'
        }

        It 'joins an array with commas' {
            $script:Result.DisplayLine | Should -Match '-Wave 1,2'
        }

        It 'shows a switch bare and a [bool] with its value' {
            $script:Result.DisplayLine | Should -Match '-DryRun(\s|$)'
            $script:Result.DisplayLine | Should -Match ([regex]::Escape('-ForceChangePassword $false'))
        }

        It 'shows a hashtable as a hashtable literal' {
            $expected = "-AliasDomainMap @{ 'contoso.com' = 'newco.com' }"
            $script:Result.DisplayLine | Should -Match ([regex]::Escape($expected))
        }
    }

    Context 'secrets' {

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'DriverSecrets'
        }

        It 'refuses to write a driver that would hold a secret' {
            # The Viva Learning client secret reaches the child through -Environment
            # (Invoke-MigrationStep), never through a file that stays in the workspace.
            $arguments = Get-TestArgumentSet -Argument @(
                (Get-TestArgument -Name 'Prefix' -Value 'Contoso')
                (Get-TestArgument -Name 'ClientSecret' -Value 'not-a-real-secret')
            )
            { New-MigrationStepDriver -Step $script:EchoStep -Arguments $arguments `
                    -Workspace $script:Workspace -Timestamp $script:Stamp } |
                Should -Throw '*ClientSecret*'
        }

        It 'writes nothing at all when it refuses' {
            $arguments = Get-TestArgumentSet -Argument @(
                (Get-TestArgument -Name 'ApiKey' -Value 'not-a-real-key')
            )
            $folder = Join-Path $script:Workspace.Path 'Workbench' 'Runs' '20260918-143005_Echo-Step'
            { New-MigrationStepDriver -Step $script:EchoStep -Arguments $arguments `
                    -Workspace $script:Workspace -Timestamp $script:Stamp } | Should -Throw
            Test-Path -LiteralPath (Join-Path $folder 'driver.ps1') | Should -BeFalse
        }

        It 'still passes a locator or a length whose name only reads like a secret' {
            # The same carve-out the settings validator makes: CertificateThumbprint is a
            # locator and PasswordLength is a number, and both are real bound parameters.
            $arguments = Get-TestArgumentSet -Argument @(
                (Get-TestArgument -Name 'Prefix' -Value 'Contoso')
                (Get-TestArgument -Name 'CertificateThumbprint' -Value '0000000000000000000000000000000000000000')
                (Get-TestArgument -Name 'PasswordLength' -Value 16)
            )
            $result = New-MigrationStepDriver -Step $script:EchoStep -Arguments $arguments `
                -Workspace $script:Workspace -Timestamp $script:Stamp
            $driver = Get-Content -LiteralPath $result.DriverPath -Raw
            $driver | Should -Match 'PasswordLength\s+= 16'
        }
    }

    Context 'a secret the child reads from its own environment' {

        <#
            The one secret the toolkit takes - the Viva Learning client secret - cannot be
            written into the driver, and the child cannot be handed a SecureString across a
            process boundary either. -SecretEnvironmentVariable is the join: the driver reads
            the environment variable Invoke-MigrationStep sets on the child alone, turns it
            into a SecureString in the child's own memory, and the value never touches disk.
        #>

        BeforeAll {
            $script:Workspace = New-TestWorkspace -Name 'DriverSecretEnvironment'
            $script:SecretResult = New-MigrationStepDriver -Step $script:EchoStep `
                -Arguments (Get-TestArgumentSet -Argument @(
                    (Get-TestArgument -Name 'Prefix' -Value 'Contoso')
                )) -Workspace $script:Workspace -Timestamp $script:Stamp `
                -SecretEnvironmentVariable 'ClientSecret=M365MIGRATION_CLIENT_SECRET'
            $script:SecretDriver = Get-Content -LiteralPath $script:SecretResult.DriverPath -Raw
        }

        It 'converts the environment variable into a SecureString before the call' {
            $expected = '\$parameters\.ClientSecret = ConvertTo-SecureString ' +
            '\$env:M365MIGRATION_CLIENT_SECRET -AsPlainText -Force'
            $script:SecretDriver | Should -Match $expected
        }

        It 'never writes the secret itself into the driver' {
            $script:SecretDriver | Should -Not -Match 'not-a-real-secret'
            $script:SecretDriver | Should -Not -Match "ClientSecret\s+= '"
        }

        It 'still parses as PowerShell' {
            Test-DriverParse -Path $script:SecretResult.DriverPath | Should -BeTrue
        }

        It 'says on the display line where the secret comes from' {
            $script:SecretResult.DisplayLine | Should -Match '-ClientSecret \$env:M365MIGRATION_CLIENT_SECRET'
        }

        It 'refuses a mapping for a parameter the script does not declare' {
            { New-MigrationStepDriver -Step $script:EchoStep -Arguments (Get-TestArgumentSet -Argument @()) `
                    -Workspace $script:Workspace -Timestamp $script:Stamp `
                    -SecretEnvironmentVariable 'NoSuchParameter=M365MIGRATION_CLIENT_SECRET' } |
                Should -Throw '*NoSuchParameter*'
        }

        It 'binds the secret in a real child pwsh, as a SecureString, without it reaching disk' {
            $pwshPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $previous = $env:M365MIGRATION_CLIENT_SECRET
            try {
                $env:M365MIGRATION_CLIENT_SECRET = 'not-a-real-secret'
                $output = @(& $pwshPath -NoProfile -NonInteractive -File $script:SecretResult.DriverPath)
            }
            finally {
                $env:M365MIGRATION_CLIENT_SECRET = $previous
            }

            ($output -join "`n") | Should -Match 'ClientSecretType=SecureString'
            ($output -join "`n") | Should -Match 'ClientSecretLength=17'
            # The echo fixture must not print the secret back, and nothing may have been
            # written beside the driver either.
            ($output -join "`n") | Should -Not -Match 'not-a-real-secret'
            (Get-Content -LiteralPath $script:SecretResult.DriverPath -Raw) |
                Should -Not -Match 'not-a-real-secret'
        }
    }

    Context 'against a real workspace scan' {

        It 'accepts the object Get-MigrationWorkspace returns' {
            $copy = Join-Path $TestDrive 'ScannedWorkspace'
            Copy-Item -LiteralPath $script:FixtureRoot -Destination $copy -Recurse -Force
            $workspace = Get-MigrationWorkspace -Path $copy
            $result = New-MigrationStepDriver -Step $script:EchoStep -Arguments (Get-TestCanonicalArgumentSet) `
                -Workspace $workspace -Timestamp $script:Stamp
            Test-DriverParse -Path $result.DriverPath | Should -BeTrue
            $result.RunFolder | Should -BeLike (Join-Path $copy 'Workbench' 'Runs' '*')
        }
    }
}

Describe 'ConvertTo-MigrationPowerShellLiteral' {

    It 'single-quotes a string and doubles an embedded quote' {
        InModuleScope M365Migration {
            ConvertTo-MigrationPowerShellLiteral -Value "it's" | Should -BeExactly "'it''s'"
        }
    }

    It 'renders booleans and switches as $true / $false' {
        InModuleScope M365Migration {
            ConvertTo-MigrationPowerShellLiteral -Value $true | Should -BeExactly '$true'
            ConvertTo-MigrationPowerShellLiteral -Value $false | Should -BeExactly '$false'
            ConvertTo-MigrationPowerShellLiteral -Value ([switch]$true) | Should -BeExactly '$true'
        }
    }

    It 'renders a number bare and in the invariant culture' {
        InModuleScope M365Migration {
            ConvertTo-MigrationPowerShellLiteral -Value 16 | Should -BeExactly '16'
            ConvertTo-MigrationPowerShellLiteral -Value 2.5 | Should -BeExactly '2.5'
        }
    }

    It 'keeps a one-element array an array' {
        InModuleScope M365Migration {
            ConvertTo-MigrationPowerShellLiteral -Value ([string[]]@('1')) | Should -BeExactly "@('1')"
            ConvertTo-MigrationPowerShellLiteral -Value @() | Should -BeExactly '@()'
        }
    }

    It 'renders a hashtable with its keys in order' {
        InModuleScope M365Migration {
            $literal = ConvertTo-MigrationPowerShellLiteral -Value @{ 'b.com' = 'two'; 'a.com' = 'one' }
            $literal | Should -BeExactly "@{ 'a.com' = 'one'; 'b.com' = 'two' }"
        }
    }

    It 'renders $null as $null so a caller can decide to drop it' {
        InModuleScope M365Migration {
            ConvertTo-MigrationPowerShellLiteral -Value $null | Should -BeExactly '$null'
        }
    }

    It 'refuses a value that has no literal form rather than writing its type name' {
        InModuleScope M365Migration {
            # Stringifying this would put 'System.Management.Automation.PSCustomObject' in a
            # driver and the child would bind that as a value.
            { ConvertTo-MigrationPowerShellLiteral -Value ([pscustomobject]@{ Wave = '1' }) } |
                Should -Throw '*no PowerShell literal form*'
            { ConvertTo-MigrationPowerShellLiteral -Value { 'a scriptblock' } } |
                Should -Throw '*no PowerShell literal form*'
        }
    }

    It 'renders a GUID as a quoted string' {
        InModuleScope M365Migration {
            $guid = [guid]'00000000-0000-0000-0000-000000000000'
            ConvertTo-MigrationPowerShellLiteral -Value $guid |
                Should -BeExactly "'00000000-0000-0000-0000-000000000000'"
        }
    }
}
