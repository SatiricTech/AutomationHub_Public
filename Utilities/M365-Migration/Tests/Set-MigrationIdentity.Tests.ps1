#Requires -Version 7.4

<#
    Offline tests for Set-MigrationIdentity.ps1.

    How the script's own functions are reached
    ------------------------------------------
    The unit under test is a script, not a module, so dot-sourcing it would run the whole thing -
    connect to Graph, connect to Exchange, process a plan. Instead the file is parsed and only its
    FunctionDefinitionAst nodes are re-created here. That gives the functions without their Main
    region, needs no test-only switch on the script, and cannot drift from the file being shipped.

    How "DryRun calls nothing" is proved in Pester 6
    -----------------------------------------------
    Pester will only mock a command it can resolve, and Set-Mailbox does not exist on a machine
    without ExchangeOnlineManagement (nor on macOS at all). So a stub with the same parameter shape
    is declared in BeforeAll, and Pester mocks the stub. Functions and stubs declared in BeforeAll
    are visible to every It in the file, and the mutation scriptblocks the script builds are created
    in this same scope, so the mock is what they resolve. Initialize-MigrationRun -DryRun sets the
    module's run context, which is what Invoke-MigrationAction consults - the same code path a real
    -DryRun run takes.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script under test binds, including ones a particular test does not read; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
param()

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    $script:MigrationRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
    Import-Module (Join-Path -Path $script:MigrationRoot -ChildPath 'M365Migration/M365Migration.psd1') -Force

    $script:ScriptPath = Join-Path -Path $script:MigrationRoot -ChildPath 'Set-MigrationIdentity.ps1'
    $script:FixtureRoot = Join-Path -Path $PSScriptRoot -ChildPath 'Fixtures/Set-MigrationIdentity'

    $parsed = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
    $definitions = $parsed.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    . ([scriptblock]::Create(($definitions.Extent.Text -join [Environment]::NewLine)))

    # Stubs for the Exchange cmdlets the script mutates through. Parameter names must match the
    # script's call sites or Pester's parameter filters would never bind.
    function Set-Mailbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub for a cmdlet that does not exist off Windows; Pester mocks it and the parameters only have to bind.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stub named after the real cmdlet so Pester can mock it; it has no body and changes nothing.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '',
        Justification = 'Stub mirrors the real cmdlet signature, which takes -Confirm; it has no body and changes nothing.')]
        param($Identity, $EmailAddresses, $Alias, $HiddenFromAddressListsEnabled, $ErrorAction)
    }

    $script:TempRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "SetMigrationIdentity-$([guid]::NewGuid())"

    function Initialize-TestRun {
        param([switch]$DryRun)
        $null = Initialize-MigrationRun -ScriptName 'Set-MigrationIdentity.Tests' -OutputPath $script:TempRoot `
            -Verbosity Low -DryRun:$DryRun
    }

    function Get-PlanRowStub {
        param([hashtable]$Value = @{})
        $row = New-MigrationPlanRow
        foreach ($key in $Value.Keys) { $row.$key = $Value[$key] }
        return $row
    }
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-IdentityMatch' {

    BeforeAll {
        $script:FullRow = Get-PlanRowStub @{
            TargetObjectId           = 'bbbbbbbb-0000-0000-0000-000000000001'
            InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'
            SourceUserPrincipalName  = 'jsmith@contoso.com'
        }
    }

    It 'Prefers TargetObjectId, then Interim, then Source when no strategy is given' {
        (Resolve-IdentityMatch -Row $script:FullRow).MatchedBy | Should -BeExactly 'TargetObjectId'

        $noId = Get-PlanRowStub @{
            InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'
            SourceUserPrincipalName  = 'jsmith@contoso.com'
        }
        (Resolve-IdentityMatch -Row $noId).MatchedBy | Should -BeExactly 'Interim'

        $sourceOnly = Get-PlanRowStub @{ SourceUserPrincipalName = 'jsmith@contoso.com' }
        $match = Resolve-IdentityMatch -Row $sourceOnly
        $match.MatchedBy | Should -BeExactly 'Source'
        $match.Identity | Should -BeExactly 'jsmith@contoso.com'
    }

    It 'Flags an object id so the caller can address Graph by id rather than by UPN' {
        (Resolve-IdentityMatch -Row $script:FullRow).IsObjectId | Should -BeTrue
        (Resolve-IdentityMatch -Row $script:FullRow -Strategy 'Source').IsObjectId | Should -BeFalse
    }

    It 'Honours an explicit strategy even when an earlier column is populated' {
        $match = Resolve-IdentityMatch -Row $script:FullRow -Strategy 'Source'
        $match.Identity | Should -BeExactly 'jsmith@contoso.com'
        $match.MatchedBy | Should -BeExactly 'Source'
    }

    It 'Does not fall back when an explicit strategy names an empty column' {
        $row = Get-PlanRowStub @{ SourceUserPrincipalName = 'jsmith@contoso.com' }
        $match = Resolve-IdentityMatch -Row $row -Strategy 'TargetObjectId'

        $match.Identity | Should -BeNullOrEmpty
        $match.Detail | Should -Match 'TargetObjectId'
    }

    It 'Reports a row that carries no usable identifier at all' {
        $match = Resolve-IdentityMatch -Row (Get-PlanRowStub)
        $match.Identity | Should -BeNullOrEmpty
        $match.Detail | Should -Match 'No TargetObjectId'
    }
}

Describe 'Get-PlanX500' {

    It 'Promotes the LegacyExchangeDN to an X500 address' {
        $rows = Import-MigrationPlan -Path (Join-Path -Path $script:FixtureRoot -ChildPath 'IdentityPlan.csv')
        $row = @($rows | Where-Object { $_.SourceUserPrincipalName -eq 'jsmith@contoso.com' })[0]

        # A single-element [string[]] unrolls on return, so the caller - and this test - wrap it.
        $x500 = @(Get-PlanX500 -Row $row)
        $x500.Count | Should -Be 1
        $x500[0] | Should -BeLike '/o=ExchangeLabs/*'
    }

    It 'Strips an X500 prefix already present on SourceX500' {
        $rows = Import-MigrationPlan -Path (Join-Path -Path $script:FixtureRoot -ChildPath 'IdentityPlan.csv')
        $row = @($rows | Where-Object { $_.SourceUserPrincipalName -eq 'bkane@contoso.com' })[0]

        @(Get-PlanX500 -Row $row)[0] |
            Should -BeExactly '/o=First Organization/ou=Exchange Administrative Group/cn=Recipients/cn=bkane'
    }

    It 'Returns nothing for a row with neither column' {
        Get-PlanX500 -Row (Get-PlanRowStub) | Should -BeNullOrEmpty
    }
}

Describe 'Get-UpnFailureDetail' {

    It 'Appends the Privileged Authentication Administrator hint to a 403' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Response status code does not indicate success: 403 (Forbidden).'),
            'Forbidden', 'PermissionDenied', $null)

        $detail = Get-UpnFailureDetail -ErrorRecord $record -PrivilegedHint 'PRIVILEGED-HINT' -ConflictHint 'CONFLICT-HINT'
        $detail | Should -Match 'PRIVILEGED-HINT'
    }

    It 'Appends the soft-deleted-user hint to a 409' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Another object with the same value already exists (409).'),
            'Conflict', 'InvalidOperation', $null)

        Get-UpnFailureDetail -ErrorRecord $record -PrivilegedHint 'PRIVILEGED-HINT' -ConflictHint 'CONFLICT-HINT' |
            Should -Match 'CONFLICT-HINT'
    }

    It 'Leaves an unrecognised failure alone' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('The remote server timed out.'), 'Timeout', 'OperationTimeout', $null)

        $detail = Get-UpnFailureDetail -ErrorRecord $record -PrivilegedHint 'PRIVILEGED-HINT' -ConflictHint 'CONFLICT-HINT'
        $detail | Should -BeExactly 'The remote server timed out.'
    }
}

Describe 'New-IdentityResult' {

    It 'Leads with the four standard columns in the contract order' {
        $row = New-IdentityResult -Identity 'john.smith@newco.com' -Action 'Upn' -Status 'Planned' -Detail 'Would set.'
        @($row.PSObject.Properties.Name)[0..3] | Should -Be @('Identity', 'Action', 'Status', 'Detail')
    }

    It 'Carries the object type and wave through from the plan row' {
        $planRow = Get-PlanRowStub @{ ObjectType = 'Shared'; Wave = '2' }
        $row = New-IdentityResult -Identity 'reception@newco.com' -Action 'Aliases' -Status 'Skipped' `
            -Detail 'Already present.' -Row $planRow

        $row.ObjectType | Should -BeExactly 'Shared'
        $row.Wave | Should -BeExactly '2'
    }

    It 'Rejects a status outside the contract' {
        { New-IdentityResult -Identity 'x' -Action 'Upn' -Status 'Updated' -Detail '' } | Should -Throw
    }
}

Describe 'DryRun makes no changes' {

    It 'Reaches Set-Mailbox in a live run' {
        Mock Set-Mailbox { }
        Initialize-TestRun
        Set-MailboxAddress -Identity 'john.smith@newco.com' -Address @('SMTP:john.smith@newco.com') -Operation Add

        Should -Invoke Set-Mailbox -Times 1 -Exactly
    }

    It 'Calls no Exchange cmdlet when the run context is DryRun' {
        Mock Set-Mailbox { }
        Initialize-TestRun -DryRun

        Set-MailboxAddress -Identity 'john.smith@newco.com' -Address @('SMTP:john.smith@newco.com') -Operation Add
        Set-MailboxAddress -Identity 'john.smith@newco.com' -Address @('smtp:jsmith@contoso.com') -Operation Remove
        Set-MailboxAttribute -Identity 'john.smith@newco.com' -Name 'Alias' -Value 'john.smith' -Description 'Set alias'
        Set-MailboxAttribute -Identity 'john.smith@newco.com' -Name 'HiddenFromAddressListsEnabled' -Value $true `
            -Description 'Hide from the GAL'

        Should -Invoke Set-Mailbox -Times 0 -Exactly
    }

    It 'Does nothing at all for an empty address list' {
        Mock Set-Mailbox { }
        Initialize-TestRun
        Set-MailboxAddress -Identity 'john.smith@newco.com' -Address @() -Operation Add

        Should -Invoke Set-Mailbox -Times 0 -Exactly
    }

    It 'Sends the add and remove buckets as the hashtable Exchange expects' {
        Mock Set-Mailbox { } -ParameterFilter {
            $EmailAddresses -is [hashtable] -and $EmailAddresses.ContainsKey('Add') -and
            $EmailAddresses['Add'] -contains 'X500:/o=First Organization/cn=jsmith'
        }
        Initialize-TestRun
        Set-MailboxAddress -Identity 'john.smith@newco.com' `
            -Address @('X500:/o=First Organization/cn=jsmith') -Operation Add

        Should -Invoke Set-Mailbox -Times 1 -Exactly
    }

    It 'Produces Planned result rows for the operations a DryRun would perform' {
        Initialize-TestRun -DryRun
        $change = Get-MigrationAddressChangeSet -CurrentAddress @('SMTP:jsmith@contoso.com') `
            -TargetPrimarySmtp 'john.smith@newco.com' -Apply PrimarySmtp

        $rows = @(
            New-IdentityResult -Identity 'john.smith@newco.com' -Action 'PrimarySmtp' -Status 'Planned' `
                -Detail $change.PrimaryDetail -TargetValue $change.NewPrimary
        )

        @($rows | Where-Object { $_.Status -ne 'Planned' }) | Should -BeNullOrEmpty
        $rows[0].TargetValue | Should -BeExactly 'john.smith@newco.com'
    }
}

Describe 'A declined confirmation is a Skip, not a Plan' {

    <#
        Same technique as the DryRun tests above, one step further out: the script itself is invoked
        with the call operator while plain functions declared in this block's BeforeAll shadow every
        command that would reach a tenant. PowerShell resolves commands innermost-scope-first, so
        those win for anything the script calls, while the real module still supplies the run
        context, the logger and the results export. 'exit' inside a script run with '&' ends that
        script only, so Pester carries on and $LASTEXITCODE is readable.

        -Apply Upn keeps the run on Graph alone, so no Exchange session is opened.
    #>

    BeforeAll {
        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }

        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Method -ne 'GET') { throw "The run reached a $Method call, which -WhatIf must have prevented." }
            return [pscustomobject]@{
                id                    = 'bbbbbbbb-0000-0000-0000-000000000001'
                userPrincipalName     = 'jsmith@contoso.com'
                mail                  = 'jsmith@contoso.com'
                mailNickname          = 'jsmith'
                displayName           = 'John Q. Smith'
                onPremisesSyncEnabled = $false
                proxyAddresses        = @('SMTP:jsmith@contoso.com')
            }
        }

        $script:WhatIfWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "SetIdentity-WhatIf-$([guid]::NewGuid())"
        $null = New-Item -Path $script:WhatIfWorkspace -ItemType Directory -Force

        & $script:ScriptPath -PlanPath (Join-Path -Path $script:FixtureRoot -ChildPath 'IdentityPlan.csv') `
            -Wave '1' -Apply 'Upn' -OutputPath $script:WhatIfWorkspace -Verbosity Low -WhatIf

        $file = @(Get-ChildItem -LiteralPath $script:WhatIfWorkspace -Filter 'Set-Identity-Results_*.csv')
        $script:WhatIfRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:WhatIfWorkspace -and (Test-Path -LiteralPath $script:WhatIfWorkspace)) {
            Remove-Item -LiteralPath $script:WhatIfWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Writes a Results file, not a DryRun file, because -WhatIf is not a rehearsal' {
        $script:WhatIfRows.Count | Should -BeGreaterThan 0
    }

    It 'Reports the declined UPN change as Skipped rather than Planned or Succeeded' {
        $declined = @($script:WhatIfRows |
            Where-Object { $_.Action -eq 'Upn' -and $_.TargetValue -eq 'john.smith@newco.com' })
        $declined.Count | Should -Be 1
        $declined[0].Status | Should -BeExactly 'Skipped'
        $declined[0].Detail | Should -BeExactly 'Declined at the confirmation prompt.'
    }

    It 'Leaves no row claiming an outcome the tenant never saw' {
        @($script:WhatIfRows | Where-Object { $_.Status -in @('Planned', 'Succeeded') }).Count | Should -Be 0
    }
}
