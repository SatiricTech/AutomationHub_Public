#Requires -Version 7.4

<#
    Static checks on Start-MigrationWorkbench.cmd, the Windows double-click launcher.
    This is a batch file, not a PowerShell script, so the tests read it as raw bytes
    and text rather than parsing or executing it (Pester 6 on macOS, no network, no
    display). See Docs/Workbench-Design.md section 10 for the launcher's contract.
#>

BeforeAll {
    Set-StrictMode -Version Latest

    $script:LauncherPath = Join-Path $PSScriptRoot '..' 'Start-MigrationWorkbench.cmd'
    $script:LauncherPath = [System.IO.Path]::GetFullPath($script:LauncherPath)
}

Describe 'Start-MigrationWorkbench.cmd' {

    It 'Exists next to the entry script' {
        Test-Path -LiteralPath $script:LauncherPath -PathType Leaf | Should -BeTrue
    }

    Context 'Once the file exists' {

        BeforeAll {
            $script:Bytes = [System.IO.File]::ReadAllBytes($script:LauncherPath)
            $script:Content = [System.Text.Encoding]::ASCII.GetString($script:Bytes)
            $script:Lines = $script:Content -split "`r`n"
        }

        It 'Uses CRLF line endings throughout, with no bare LF' {
            $bareLineFeedIndex = -1
            for ($i = 0; $i -lt $script:Bytes.Length; $i++) {
                if ($script:Bytes[$i] -eq 0x0A -and ($i -eq 0 -or $script:Bytes[$i - 1] -ne 0x0D)) {
                    $bareLineFeedIndex = $i
                    break
                }
            }
            $bareLineFeedIndex | Should -Be -1
        }

        It 'Launches pwsh with -NoProfile -ExecutionPolicy Bypass -File' {
            $script:Content | Should -Match ([regex]::Escape('-NoProfile -ExecutionPolicy Bypass -File'))
        }

        It 'Resolves its own folder with %~dp0' {
            $script:Content | Should -Match ([regex]::Escape('%~dp0'))
        }

        It 'Never launches Windows PowerShell (powershell.exe)' {
            $script:Content | Should -Not -Match ([regex]::Escape('powershell.exe'))
        }

        It 'Never elevates with -Verb RunAs' {
            $script:Content | Should -Not -Match ([regex]::Escape('-Verb RunAs'))
        }

        It 'Never probes elevation with fltmc' {
            $script:Content | Should -Not -Match 'fltmc'
        }

        It 'Names the PowerShell 7 install link when pwsh cannot be found' {
            $script:Content | Should -Match ([regex]::Escape('aka.ms/install-powershell'))
        }

        It 'Passes command-line arguments through with %*' {
            $script:Content | Should -Match ([regex]::Escape('%*'))
        }

        It 'Ends with endlocal & exit /b %RC% on one line, as the last non-empty line' {
            $lastNonEmptyLine = ($script:Lines | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 1)
            $lastNonEmptyLine | Should -BeExactly 'endlocal & exit /b %RC%'
        }

        It 'Keeps every line at 120 characters or fewer' {
            $tooLong = $script:Lines | Where-Object { $_.Length -gt 120 }
            $tooLong | Should -BeNullOrEmpty
        }
    }
}
