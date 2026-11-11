#Requires -Modules Pester

<#
    Offline tests for the Exchange Online archive scripts. Every Exchange cmdlet is mocked,
    so no tenant connection is made. The scripts are run with & so their exit codes can be
    checked through $LASTEXITCODE.
#>

BeforeAll {
    $script:root       = Split-Path -Parent $PSScriptRoot
    $script:autoExpand = Join-Path $script:root 'Enable-M365ArchiveAutoExpand.ps1'
    $script:mfa        = Join-Path $script:root 'Start-M365ManagedFolderAssistant.ps1'
    $script:outDir     = Join-Path ([System.IO.Path]::GetTempPath()) "exo-archive-tests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:outDir | Out-Null

    # Only the connection cmdlets ship in ExchangeOnlineManagement. The rest exist only after
    # Connect-ExchangeOnline, so declare stubs with real parameter names to mock against.
    function global:Get-OrganizationConfig { [CmdletBinding()] param() }
    # Script-internal function, declared here only so Pester can mock it.
    function global:Confirm-IrreversibleChange { param($Summary) }
    function global:Set-OrganizationConfig { [CmdletBinding()] param([switch]$AutoExpandingArchive) }
    function global:Enable-Mailbox {
        [CmdletBinding()] param($Identity, [switch]$Archive, [switch]$AutoExpandingArchive)
    }
    function global:Start-ManagedFolderAssistant {
        [CmdletBinding()] param($Identity, [switch]$HoldCleanup)
    }
    foreach ($name in 'Get-ConnectionInformation', 'Connect-ExchangeOnline', 'Disconnect-ExchangeOnline') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            New-Item -Path "function:global:$name" -Value { [CmdletBinding()] param() } | Out-Null
        }
    }
    if (-not (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)) {
        function global:Get-EXOMailbox {
            [CmdletBinding()] param($Identity, $ResultSize, $RecipientTypeDetails, $Properties)
        }
    }

    function New-TestMailbox {
        # ExchangeGuid is off by default: it is not in Get-EXOMailbox's default property set, so
        # the scripts must work (via the UPN fallback) when it is missing.
        param ([string]$Upn, [string]$ArchiveStatus = 'Active', [bool]$AutoExpand = $false,
            [string]$Type = 'UserMailbox', [switch]$WithGuid)
        [pscustomobject]@{
            UserPrincipalName           = $Upn
            ExchangeGuid                = $WithGuid ? [guid]::NewGuid() : $null
            RecipientTypeDetails        = $Type
            ArchiveStatus               = $ArchiveStatus
            AutoExpandingArchiveEnabled = $AutoExpand
        }
    }

    function Invoke-TestScript {
        param ([string]$Path, [hashtable]$Arguments)
        $Arguments.LogPath    = Join-Path $script:outDir "$([guid]::NewGuid()).log"
        $Arguments.OutputPath = Join-Path $script:outDir "$([guid]::NewGuid()).csv"
        & $Path @Arguments 6>$null
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Rows     = if (Test-Path $Arguments.OutputPath) { @(Import-Csv -Path $Arguments.OutputPath) } else { @() }
        }
    }
}

AfterAll {
    Remove-Item -Path $script:outDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Enable-M365ArchiveAutoExpand' {
    BeforeEach {
        Mock Import-Module { }
        Mock Get-Module { [pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.10.1' } }
        Mock Get-ConnectionInformation {
            [pscustomobject]@{
                State = 'Connected'; TokenStatus = 'Active'; UserPrincipalName = 'admin'; TenantID = 't'
            }
        }
        Mock Connect-ExchangeOnline { }
        Mock Disconnect-ExchangeOnline { }
        Mock Get-OrganizationConfig { [pscustomobject]@{ AutoExpandingArchiveEnabled = $false } }
        Mock Set-OrganizationConfig { }
        Mock Enable-Mailbox { }
        Mock Get-EXOMailbox {
            @(
                New-TestMailbox -Upn 'a@contoso.com'
                New-TestMailbox -Upn 'b@contoso.com' -ArchiveStatus 'None'
                New-TestMailbox -Upn 'c@contoso.com' -AutoExpand $true
            )
        }
    }

    It 'DryRun calls no mutation cmdlet and exits 0' {
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ DryRun = $true; EnableArchive = $true }
        $r.ExitCode | Should -Be 0
        Should -Invoke Set-OrganizationConfig -Times 0 -Exactly
        Should -Invoke Enable-Mailbox -Times 0 -Exactly
        $r.Rows.Result | Should -Contain 'WouldChange'
    }

    It 'DryRun in Mailbox scope calls no mutation cmdlet' {
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ DryRun = $true; Scope = 'Mailbox' }
        $r.ExitCode | Should -Be 0
        Should -Invoke Enable-Mailbox -Times 0 -Exactly
    }

    It 'Organization scope calls Set-OrganizationConfig once with -Force' {
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true }
        $r.ExitCode | Should -Be 0
        Should -Invoke Set-OrganizationConfig -Times 1 -Exactly
        Should -Invoke Enable-Mailbox -Times 0 -Exactly
        ($r.Rows | Where-Object Identity -eq 'b@contoso.com').Result | Should -Be 'SkippedNoArchive'
    }

    It 'Organization scope makes no change when org-wide is already on' {
        Mock Get-OrganizationConfig { [pscustomobject]@{ AutoExpandingArchiveEnabled = $true } }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true }
        $r.ExitCode | Should -Be 0
        Should -Invoke Set-OrganizationConfig -Times 0 -Exactly
    }

    It 'Mailbox scope skips mailboxes already enabled and with no archive' {
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true; Scope = 'Mailbox' }
        $r.ExitCode | Should -Be 0
        Should -Invoke Enable-Mailbox -Times 1 -Exactly -ParameterFilter { $AutoExpandingArchive }
        ($r.Rows | Where-Object Identity -eq 'c@contoso.com').Result | Should -Be 'NoChange'
    }

    It 'Mailbox scope with -EnableArchive enables the archive before auto-expansion' {
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{
            Force = $true; Scope = 'Mailbox'; EnableArchive = $true
        }
        $r.ExitCode | Should -Be 0
        Should -Invoke Enable-Mailbox -Times 1 -Exactly -ParameterFilter { $Archive }
        Should -Invoke Enable-Mailbox -Times 2 -Exactly -ParameterFilter { $AutoExpandingArchive }
    }

    It 'Treats "already enabled" as BufferAdded when org-wide is on' {
        Mock Get-OrganizationConfig { [pscustomobject]@{ AutoExpandingArchiveEnabled = $true } }
        Mock Enable-Mailbox { throw 'Auto-expanding archive is already enabled for the organization.' }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true; Scope = 'Mailbox' }
        $r.ExitCode | Should -Be 0
        ($r.Rows | Where-Object Identity -eq 'a@contoso.com').Result | Should -Be 'BufferAdded'
    }

    It 'Exits 50 when one mailbox fails' {
        Mock Enable-Mailbox { throw 'License does not include archiving.' }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true; Scope = 'Mailbox' }
        $r.ExitCode | Should -Be 50
        ($r.Rows | Where-Object Identity -eq 'a@contoso.com').Result | Should -Be 'Failed'
    }

    It 'Refuses -UserPrincipalName with Organization scope, exit 2, no change' {
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{
            UserPrincipalName = 'a@contoso.com'; Force = $true
        }
        $r.ExitCode | Should -Be 2
        Should -Invoke Set-OrganizationConfig -Times 0 -Exactly
        Should -Invoke Get-EXOMailbox -Times 0 -Exactly
    }

    It 'Uses the UPN as identity when ExchangeGuid is missing' {
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true; Scope = 'Mailbox' }
        $r.ExitCode | Should -Be 0
        Should -Invoke Enable-Mailbox -Times 1 -Exactly -ParameterFilter { $Identity -eq 'a@contoso.com' }
    }

    It 'Uses ExchangeGuid as identity when it is present' {
        Mock Get-EXOMailbox { New-TestMailbox -Upn 'g@contoso.com' -WithGuid }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true; Scope = 'Mailbox' }
        $r.ExitCode | Should -Be 0
        Should -Invoke Enable-Mailbox -Times 1 -Exactly -ParameterFilter { $Identity -match "^[0-9a-f-]{36}$" }
    }

    It 'Ignores a Security & Compliance session and connects to Exchange' {
        Mock Get-ConnectionInformation {
            [pscustomobject]@{ State = 'Connected'; TokenStatus = 'Active'; IsEopSession = $true }
        }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ DryRun = $true }
        $r.ExitCode | Should -Be 0
        Should -Invoke Connect-ExchangeOnline -Times 1 -Exactly
    }

    It 'Treats the string "False" as not enabled' {
        Mock Get-OrganizationConfig { [pscustomobject]@{ AutoExpandingArchiveEnabled = 'False' } }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true }
        $r.ExitCode | Should -Be 0
        Should -Invoke Set-OrganizationConfig -Times 1 -Exactly
    }

    It 'Shows the tenant on the console at Low verbosity' {
        Mock Get-ConnectionInformation {
            [pscustomobject]@{
                State = 'Connected'; TokenStatus = 'Active'; UserPrincipalName = 'admin'
                Organization = 'contoso.onmicrosoft.com'; TenantID = 't'
            }
        }
        $out = & $script:autoExpand -DryRun -Verbosity Low -LogPath (Join-Path $script:outDir 'v.log') `
            -OutputPath (Join-Path $script:outDir 'v.csv') 6>&1 | Out-String
        $out | Should -Match 'contoso\.onmicrosoft\.com'
    }

    It 'Exits 2 and changes nothing when two Exchange sessions are open' {
        Mock Get-ConnectionInformation {
            [pscustomobject]@{ State = 'Connected'; TokenStatus = 'Active'; Organization = 'a'; TenantID = '1' }
            [pscustomobject]@{ State = 'Connected'; TokenStatus = 'Active'; Organization = 'b'; TenantID = '2' }
        }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ Force = $true }
        $r.ExitCode | Should -Be 2
        Should -Invoke Get-OrganizationConfig -Times 0 -Exactly
        Should -Invoke Set-OrganizationConfig -Times 0 -Exactly
    }

    It 'Exits 2 and changes nothing when the confirmation is declined' {
        Mock Confirm-IrreversibleChange { $false }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ EnableArchive = $true; Scope = 'Mailbox' }
        $r.ExitCode | Should -Be 2
        Should -Invoke Confirm-IrreversibleChange -Times 1 -Exactly
        Should -Invoke Set-OrganizationConfig -Times 0 -Exactly
        Should -Invoke Enable-Mailbox -Times 0 -Exactly
    }

    It 'Exits 20 when the connection fails' {
        Mock Get-ConnectionInformation { }
        Mock Connect-ExchangeOnline { throw 'AADSTS50076' }
        $r = Invoke-TestScript -Path $script:autoExpand -Arguments @{ DryRun = $true }
        $r.ExitCode | Should -Be 20
    }
}

Describe 'Start-M365ManagedFolderAssistant' {
    BeforeEach {
        Mock Import-Module { }
        Mock Get-Module { [pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.10.1' } }
        Mock Get-ConnectionInformation {
            [pscustomobject]@{
                State = 'Connected'; TokenStatus = 'Active'; UserPrincipalName = 'admin'; TenantID = 't'
            }
        }
        Mock Connect-ExchangeOnline { }
        Mock Disconnect-ExchangeOnline { }
        Mock Start-ManagedFolderAssistant { }
        Mock Get-EXOMailbox {
            @(
                New-TestMailbox -Upn 'a@contoso.com'
                New-TestMailbox -Upn 'b@contoso.com' -ArchiveStatus 'None'
            )
        }
    }

    It 'DryRun starts nothing and exits 0' {
        $r = Invoke-TestScript -Path $script:mfa -Arguments @{ DryRun = $true }
        $r.ExitCode | Should -Be 0
        Should -Invoke Start-ManagedFolderAssistant -Times 0 -Exactly
        $r.Rows.Result | Should -Contain 'WouldStart'
    }

    It 'Starts the assistant on every mailbox' {
        $r = Invoke-TestScript -Path $script:mfa -Arguments @{}
        $r.ExitCode | Should -Be 0
        Should -Invoke Start-ManagedFolderAssistant -Times 2 -Exactly
    }

    It '-ArchiveEnabledOnly skips mailboxes with no archive' {
        $r = Invoke-TestScript -Path $script:mfa -Arguments @{ ArchiveEnabledOnly = $true }
        $r.ExitCode | Should -Be 0
        Should -Invoke Start-ManagedFolderAssistant -Times 1 -Exactly
        ($r.Rows | Where-Object Identity -eq 'b@contoso.com').Result | Should -Be 'SkippedNoArchive'
    }

    It '-HoldCleanup passes the switch through' {
        Invoke-TestScript -Path $script:mfa -Arguments @{ HoldCleanup = $true } | Out-Null
        Should -Invoke Start-ManagedFolderAssistant -Times 2 -Exactly -ParameterFilter { $HoldCleanup }
    }

    It 'Continues after one failure and exits 50' {
        Mock Get-EXOMailbox {
            @(
                New-TestMailbox -Upn 'a@contoso.com'
                New-TestMailbox -Upn 'fail@contoso.com'
            )
        }
        $state = @{ Calls = 0 }
        Mock Start-ManagedFolderAssistant { $state.Calls++; if ($state.Calls -eq 2) { throw 'Access denied' } }
        $r = Invoke-TestScript -Path $script:mfa -Arguments @{}
        $r.ExitCode | Should -Be 50
        Should -Invoke Start-ManagedFolderAssistant -Times 2 -Exactly
    }

    It 'Exits 1 when every mailbox fails' {
        Mock Start-ManagedFolderAssistant { throw 'Access denied' }
        $r = Invoke-TestScript -Path $script:mfa -Arguments @{}
        $r.ExitCode | Should -Be 1
    }

    It 'Retries a throttling error and then succeeds' {
        Mock Start-Sleep { }
        Mock Get-EXOMailbox { New-TestMailbox -Upn 'a@contoso.com' }
        $state = @{ Attempts = 0 }
        Mock Start-ManagedFolderAssistant {
            $state.Attempts++
            if ($state.Attempts -eq 1) { throw 'Server busy (429)' }
        }
        $r = Invoke-TestScript -Path $script:mfa -Arguments @{ UserPrincipalName = 'a@contoso.com' }
        $r.ExitCode | Should -Be 0
        Should -Invoke Start-ManagedFolderAssistant -Times 2 -Exactly
    }
}
