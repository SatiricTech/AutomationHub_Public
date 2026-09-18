<#
.SYNOPSIS
    Pester tests for Test-WindowsPowerShellCompat.ps1.

.DESCRIPTION
    Verifies that the Windows PowerShell 5.1 compatibility checker flags every PowerShell
    7-only construct listed in DESIGN.md section 4.1, leaves 5.1-safe scripts untouched,
    scans folders recursively, and exposes the documented -PassThru / exit-code contract.

    Two invocation styles are used deliberately:
      - `& $CheckerPath ... -PassThru` (in-process call operator) for every test that reads
        finding objects. In -PassThru mode the checker never calls `exit`, so this is safe
        to run inside the Pester process.
      - `pwsh -NoProfile -File $CheckerPath ...` (child process) for the handful of tests
        that assert the exit code. The checker calls `exit` in that mode, which would tear
        down the Pester run if invoked in-process without -PassThru.
#>

BeforeAll {
    $script:CheckerPath = Join-Path $PSScriptRoot 'Test-WindowsPowerShellCompat.ps1'
    $script:ScratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) "WPSCompatTests-$([guid]::NewGuid())"
    New-Item -Path $script:ScratchRoot -ItemType Directory -Force | Out-Null

    function New-CompatTestFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions',
            '',
            Justification = 'Test-only fixture writer scoped to an ephemeral scratch directory removed in AfterAll.'
        )]
        param (
            [Parameter(Mandatory)]
            [string]$Name,

            [Parameter(Mandatory)]
            [string]$Content
        )

        $filePath = Join-Path $script:ScratchRoot $Name
        Set-Content -LiteralPath $filePath -Value $Content -Encoding utf8
        return $filePath
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-WindowsPowerShellCompat' {

    Context 'PowerShell 7-only constructs are flagged' {

        It 'flags the ternary operator' {
            $file = New-CompatTestFile -Name 'ternary.ps1' -Content '$a = $true ? 1 : 2'
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'TernaryOperator'
        }

        It 'flags the null-coalescing operator' {
            $file = New-CompatTestFile -Name 'nullcoalesce.ps1' -Content "`$x = `$null ?? 'y'"
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'NullCoalescingOperator'
        }

        It 'flags the null-coalescing assignment operator' {
            $file = New-CompatTestFile -Name 'nullcoalesceassign.ps1' -Content "`$x = 1`n`$x ??= 2"
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'NullCoalescingOperator'
        }

        It 'flags null-conditional member access ($o?.Name, no braces)' {
            $file = New-CompatTestFile -Name 'nullcond.ps1' -Content "`$o = `$null`n`$o?.Name"
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'NullConditionalMember'
        }

        It 'flags null-conditional member access (${o}?.Name, braced)' {
            $file = New-CompatTestFile -Name 'nullcondbraced.ps1' -Content "`$o = @{ Name = 'x' }`n`${o}?.Name"
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'NullConditionalMember'
        }

        It 'flags null-conditional index access (${a}?[0])' {
            $file = New-CompatTestFile -Name 'nullcondindex.ps1' -Content "`$a = 1..10`n`${a}?[0]"
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'NullConditionalIndex'
        }

        It 'flags the pipeline chain operator' {
            $file = New-CompatTestFile -Name 'pipelinechain.ps1' -Content 'Get-Process && Get-Service'
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'PipelineChainOperator'
        }

        It 'flags ForEach-Object -Parallel' {
            $file = New-CompatTestFile -Name 'parallel.ps1' -Content '1..3 | ForEach-Object -Parallel { $_ }'
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'ForEachObjectParallel'
        }

        It 'flags Invoke-RestMethod -SslProtocol' {
            $content = "Invoke-RestMethod -Uri 'https://example.com' -SslProtocol Tls12"
            $file = New-CompatTestFile -Name 'restssl.ps1' -Content $content
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'WebCmdletSslProtocol'
        }

        It 'flags Invoke-WebRequest -MaximumRetryCount' {
            $content = "Invoke-WebRequest -Uri 'https://example.com' -MaximumRetryCount 2"
            $file = New-CompatTestFile -Name 'webretry.ps1' -Content $content
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'WebCmdletMaximumRetryCount'
        }

        It 'flags -RetryIntervalSec on a web cmdlet' {
            $content = "Invoke-WebRequest -Uri 'https://example.com' -RetryIntervalSec 5"
            $file = New-CompatTestFile -Name 'retryinterval.ps1' -Content $content
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'WebCmdletRetryIntervalSec'
        }

        It 'flags -SkipHttpErrorCheck on a web cmdlet' {
            $content = "Invoke-RestMethod -Uri 'https://example.com' -SkipHttpErrorCheck"
            $file = New-CompatTestFile -Name 'skiphttperror.ps1' -Content $content
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'WebCmdletSkipHttpErrorCheck'
        }

        It 'flags Join-Path with more than two positional arguments' {
            $file = New-CompatTestFile -Name 'joinpath.ps1' -Content "Join-Path 'a' 'b' 'c'"
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'JoinPathAdditionalChildPath'
        }

        It 'flags a #Requires -Version greater than 5.1' {
            $file = New-CompatTestFile -Name 'requires.ps1' -Content "#Requires -Version 7.0`nWrite-Output 'hi'"
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'RequiresVersion'
        }

        It 'flags the StartType property on a service object' {
            $file = New-CompatTestFile -Name 'starttype.ps1' -Content '(Get-Service Spooler).StartType'
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings.Rule | Should -Contain 'ServiceStartTypeProperty'
        }
    }

    Context '5.1-safe constructs are not flagged' {

        It 'returns no findings for a plain 5.1-safe file' {
            $content = "`$a = `$true`nif (`$a) { 1 } else { 2 }`nJoin-Path `$a 'b'"
            $file = New-CompatTestFile -Name 'safe.ps1' -Content $content
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings | Should -BeNullOrEmpty
        }

        It 'does not flag a #Requires -Version of exactly 5.1' {
            $file = New-CompatTestFile -Name 'requires51.ps1' -Content "#Requires -Version 5.1`nWrite-Output 'hi'"
            $findings = & $script:CheckerPath -Path $file -PassThru
            $findings | Should -BeNullOrEmpty
        }
    }

    Context 'Folder scanning' {

        It 'scans every .ps1 file under a folder and reports the offending file' {
            $subDir = Join-Path $script:ScratchRoot 'FolderScan'
            New-Item -Path $subDir -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $subDir 'one.ps1') -Value '$a = $true ? 1 : 2'
            Set-Content -LiteralPath (Join-Path $subDir 'two.ps1') -Value "Join-Path 'a' 'b'"

            $findings = & $script:CheckerPath -Path $subDir -PassThru

            $findings | Should -HaveCount 1
            $findings[0].Path | Should -Match ([regex]::Escape('one.ps1') + '$')
        }
    }

    Context 'Parameter validation' {

        It 'throws for a path that does not exist' {
            $missing = Join-Path $script:ScratchRoot 'does-not-exist.ps1'
            { & $script:CheckerPath -Path $missing -PassThru } | Should -Throw
        }

        It 'throws when -Path is an empty string' {
            { & $script:CheckerPath -Path '' -PassThru } | Should -Throw
        }

        It 'throws when -Verbosity is not one of Low, Medium, High' {
            $file = New-CompatTestFile -Name 'verbositycheck.ps1' -Content "Write-Output 'hi'"
            { & $script:CheckerPath -Path $file -PassThru -Verbosity 'Bogus' } | Should -Throw
        }
    }

    Context 'DryRun' {

        It 'produces the same findings whether or not -DryRun is specified' {
            $file = New-CompatTestFile -Name 'dryruncheck.ps1' -Content '$a = $true ? 1 : 2'
            $findings = & $script:CheckerPath -Path $file -PassThru -DryRun
            $findings.Rule | Should -Contain 'TernaryOperator'
        }
    }

    Context 'Logging' {

        It 'writes a log file at the path given by -LogPath' {
            $file = New-CompatTestFile -Name 'logcheck.ps1' -Content "Write-Output 'hi'"
            $logPath = Join-Path $script:ScratchRoot 'custom.log'
            $null = & $script:CheckerPath -Path $file -PassThru -LogPath $logPath
            Test-Path -LiteralPath $logPath | Should -BeTrue
            Get-Content -LiteralPath $logPath -Raw | Should -Match 'Scan complete'
        }
    }

    Context 'Exit codes (child-process invocation)' {

        It 'exits 0 and prints no findings for a safe file' {
            # stdout only (no 2>&1): Write-Log's operational messages go to stderr by design
            # (see the script's .NOTES), so stdout must be empty when there are no findings.
            $content = "`$a = `$true`nif (`$a) { 1 } else { 2 }`nJoin-Path `$a 'b'"
            $file = New-CompatTestFile -Name 'safe-exit.ps1' -Content $content
            $output = & pwsh -NoProfile -File $script:CheckerPath -Path $file 2>$null
            $LASTEXITCODE | Should -Be 0
            $output | Should -BeNullOrEmpty
        }

        It 'exits 1 and prints "file:line: reason" for a file with findings' {
            $file = New-CompatTestFile -Name 'bad-exit.ps1' -Content '$a = $true ? 1 : 2'
            $output = & pwsh -NoProfile -File $script:CheckerPath -Path $file 2>$null
            $LASTEXITCODE | Should -Be 1
            ($output -join "`n") | Should -Match ([regex]::Escape("${file}:1:"))
        }

        It 'exits 2 for a path that does not exist' {
            $missing = Join-Path $script:ScratchRoot 'still-does-not-exist.ps1'
            $null = & pwsh -NoProfile -File $script:CheckerPath -Path $missing 2>&1
            $LASTEXITCODE | Should -Be 2
        }
    }
}
