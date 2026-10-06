BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'Install-NinjaOneAgent.ps1')
    $script:GoodUrl = 'https://app.ninjarmm.com/agent/installer/0000/example-installer.msi'
}

Describe 'Test-AgentUrl' {
    It 'Rejects an empty URL' {
        Test-AgentUrl -Url '' | Should -BeLike '*not set*'
    }
    It 'Rejects an unedited placeholder' {
        Test-AgentUrl -Url 'https://app.ninjarmm.com/agent/installer/<INSTALLER-ID>/<name>.msi' | Should -BeLike '*not set*'
    }
    It 'Rejects http' {
        Test-AgentUrl -Url 'http://app.ninjarmm.com/agent/installer/abc/x.msi' | Should -BeLike '*https*'
    }
    It 'Rejects a non-msi path' {
        Test-AgentUrl -Url 'https://app.ninjarmm.com/agent/installer/abc/x.exe' | Should -BeLike '*.msi*'
    }
    It 'Accepts a valid URL on the default host' {
        Test-AgentUrl -Url $script:GoodUrl | Should -BeNullOrEmpty
    }
    It 'Accepts a regional host and ignores a query string' {
        Test-AgentUrl -Url 'https://eu.ninjarmm.com/agent/installer/abc/x.MSI?t=1' | Should -BeNullOrEmpty
    }
    It 'Rejects a non-NinjaOne host' {
        Test-AgentUrl -Url 'https://example.com/agent/installer/abc/x.msi' | Should -BeLike '*not a NinjaOne domain*'
    }
    It 'Rejects a lookalike host that only contains the NinjaOne domain' {
        Test-AgentUrl -Url 'https://app.ninjarmm.com.example.net/x.msi' | Should -BeLike '*not a NinjaOne domain*'
        Test-AgentUrl -Url 'https://evilninjarmm.com/x.msi' | Should -BeLike '*not a NinjaOne domain*'
    }
}

Describe 'Invoke-Main' {
    BeforeEach {
        Mock Write-Log { }
        Mock Get-AgentInstaller { }
        Mock Start-MsiInstall { 0 }
        Mock Wait-AgentService { $true }
        Mock Test-AgentInstalled { $false }
        Mock Test-ElevatedSession { $true }
        Mock Test-InstallerSignature { $null }
        Mock Remove-Item { }
        Mock Test-Path { $true }
    }

    Context 'Invalid URL' {
        It 'Returns 2 and does nothing' {
            Invoke-Main -Url '' -MsiLogPath 'x.log' | Should -Be 2
            Should -Invoke Get-AgentInstaller -Times 0 -Exactly
            Should -Invoke Start-MsiInstall -Times 0 -Exactly
        }
    }

    Context 'Already installed' {
        BeforeEach { Mock Test-AgentInstalled { $true } }

        It 'Skips with exit 0 and no download' {
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Should -Be 0
            Should -Invoke Get-AgentInstaller -Times 0 -Exactly
            Should -Invoke Start-MsiInstall -Times 0 -Exactly
        }
        It 'Reinstalls with -Force' {
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' -Force | Should -Be 0
            Should -Invoke Get-AgentInstaller -Times 1 -Exactly
            Should -Invoke Start-MsiInstall -Times 1 -Exactly
        }
    }

    Context 'DryRun' {
        It 'Makes no download or msiexec call' {
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' -DryRun | Should -Be 0
            Should -Invoke Get-AgentInstaller -Times 0 -Exactly
            Should -Invoke Start-MsiInstall -Times 0 -Exactly
            Should -Invoke Write-Log -ParameterFilter { $Message -like '*DRYRUN*' }
        }
    }

    Context 'Elevation' {
        BeforeEach { Mock Test-ElevatedSession { $false } }

        It 'Returns 3 and does not download when not elevated' {
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Should -Be 3
            Should -Invoke Get-AgentInstaller -Times 0 -Exactly
        }
        It 'Does not require elevation for -DryRun' {
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' -DryRun | Should -Be 0
        }
    }

    Context 'Signature check' {
        It 'Returns 20 and skips msiexec when the signature is bad' {
            Mock Test-InstallerSignature { 'bad signature' }
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Should -Be 20
            Should -Invoke Start-MsiInstall -Times 0 -Exactly
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*NinjaOneAgent-*.msi' }
        }
        It 'Proceeds to msiexec when the signature is good' {
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Should -Be 0
            Should -Invoke Start-MsiInstall -Times 1 -Exactly
        }
    }

    Context 'Install exit codes' {
        It 'Treats <Code> as success' -ForEach @(
            @{ Code = 0 }, @{ Code = 3010 }, @{ Code = 1641 }
        ) {
            $script:code = $Code
            Mock Start-MsiInstall { $script:code }
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Should -Be 0
            Should -Invoke Wait-AgentService -Times 1 -Exactly
        }
        It 'Returns 1 for msiexec failure code 1603' {
            Mock Start-MsiInstall { 1603 }
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Should -Be 1
            Should -Invoke Wait-AgentService -Times 0 -Exactly
        }
        It 'Returns 30 when the service never appears' {
            Mock Wait-AgentService { $false }
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Should -Be 30
        }
        It 'Returns 10 when the download fails and skips msiexec' {
            Mock Get-AgentInstaller { throw 'boom' }
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Should -Be 10
            Should -Invoke Start-MsiInstall -Times 0 -Exactly
        }
        It 'Removes the temp MSI even on failure' {
            Mock Start-MsiInstall { 1603 }
            Invoke-Main -Url $script:GoodUrl -MsiLogPath 'x.log' | Out-Null
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*NinjaOneAgent-*.msi' }
        }
    }
}

Describe 'Test-InstallerSignature' {
    BeforeAll {
        # Windows-only cmdlet; a stub lets Pester mock it on macOS/Linux.
        if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
            function Get-AuthenticodeSignature { param($LiteralPath) }
        }
    }
    It 'Accepts a valid Ninja signature' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN="NinjaOne, LLC", O="NinjaOne, LLC"' } }
        }
        Test-InstallerSignature -Path 'x.msi' | Should -BeNullOrEmpty
    }
    It 'Accepts the older NinjaRMM LLC signer' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN="NinjaRMM LLC"' } }
        }
        Test-InstallerSignature -Path 'x.msi' | Should -BeNullOrEmpty
    }
    It 'Rejects an unsigned file' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        Test-InstallerSignature -Path 'x.msi' | Should -BeLike '*NotSigned*'
    }
    It 'Rejects a valid signature from another publisher' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Someone Else' } }
        }
        Test-InstallerSignature -Path 'x.msi' | Should -BeLike '*not signed by NinjaOne*'
    }
    It 'Rejects a publisher whose name only contains Ninja' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Ninja Tools Inc, O=Ninja Tools Inc' } }
        }
        Test-InstallerSignature -Path 'x.msi' | Should -BeLike '*not signed by NinjaOne*'
    }
    It 'Rejects Ninja text in a field other than CN' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Someone Else, OU="NinjaOne, LLC"' } }
        }
        Test-InstallerSignature -Path 'x.msi' | Should -BeLike '*not signed by NinjaOne*'
    }
}

Describe 'Get-AgentInstaller' {
    It 'Sends a user agent the NinjaOne load balancer accepts' {
        Mock Invoke-WebRequest { }
        Get-AgentInstaller -Url $script:GoodUrl -OutFile 'x.msi'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $UserAgent -and $UserAgent -notmatch 'WindowsPowerShell'
        }
    }
}

Describe 'Start-MsiInstall' {
    BeforeEach {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 3010 } }
    }
    It 'Quotes paths containing spaces and returns the exit code' {
        Start-MsiInstall -MsiPath 'C:\Temp Dir b.msi' -MsiLogPath 'C:\Log Dir\m.log' | Should -Be 3010
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'msiexec.exe' -and
            $ArgumentList -contains '"C:\Temp Dir b.msi"' -and
            $ArgumentList -contains '"C:\Log Dir\m.log"' -and
            $ArgumentList -contains '/qn' -and $ArgumentList -contains '/norestart'
        }
    }
}

Describe 'Wait-AgentService' {
    BeforeEach { Mock Start-Sleep { } }

    It 'Returns true when the service appears' {
        $script:polls = 0
        Mock Test-AgentInstalled { $script:polls++; $script:polls -ge 3 }
        Wait-AgentService -TimeoutSeconds 60 -PollSeconds 1 | Should -BeTrue
    }
    It 'Returns false when the service never appears' {
        Mock Test-AgentInstalled { $false }
        Wait-AgentService -TimeoutSeconds 0 -PollSeconds 1 | Should -BeFalse
    }
}
