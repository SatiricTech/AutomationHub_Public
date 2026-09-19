#Requires -Version 7.4

<#
    Tests for Reset-MigrationCutoverPasswords.ps1.

    The script body connects to Graph and resets passwords, so it must never be dot-sourced
    by a test. The pure decision functions are lifted out of the file's AST and defined on
    their own, which exercises the real shipped text without executing anything around it.
    The end-to-end Describes invoke the script with the call operator under -DryRun, -WhatIf
    or -Confirm:$false while plain functions declared in their BeforeAll shadow
    Invoke-MigrationGraphRequest and the toolkit's connection helper, so nothing ever reaches
    a tenant.

    Author: AutomationHub
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The Connect-MigrationGraph stub runs inside the script under test, whose scope chain does not reach this file''s script scope, so the scopes it was asked for are captured in a global list and removed again in AfterAll.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script under test binds, including ones a particular test does not read; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Shadowing Export-Csv inside one Describe is the only way to make the temp-folder fallback fail without making the real temp folder unwritable. It is scoped to the test file, never shipped.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'These are stand-ins for the module functions whose names the script under test calls. They return a fixed value and change nothing, so ShouldProcess would be meaningless.')]
param()

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $scriptPath = Join-Path $PSScriptRoot '..' 'Reset-MigrationCutoverPasswords.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "Reset-MigrationCutoverPasswords.ps1 failed to parse: $($errors[0].Message)"
    }

    foreach ($name in 'Resolve-CutoverPlanIdentity', 'Resolve-CutoverUser') {
        $functionAst = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $name
            }, $true) | Select-Object -First 1

        if (-not $functionAst) {
            throw "$name was not found in Reset-MigrationCutoverPasswords.ps1."
        }

        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    # Resolve-CutoverUser reads these two from the script's Configuration region.
    $script:guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $script:graphUserSelect = 'id,userPrincipalName,displayName'

    $script:scriptPath = $scriptPath
    $script:fixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'Reset-MigrationCutoverPasswords'
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    # Builds the raw REST user a stub hands back for a lookup, echoing the identity that was
    # asked for so result rows can be told apart. A Uri carrying a $filter of
    # "userPrincipalName eq 'x'" or "mail eq 'x'" yields x; a by-id Uri (no $filter) yields a
    # fixed UPN. Properties are the lowerCamelCase names Graph itself returns, exactly as
    # Resolve-CutoverUser reads them via Get-MigrationProperty.
    function script:New-StubGraphUser {
        param([string]$Uri)
        $upn = if ($Uri -match "eq '([^']+)'") { $Matches[1] } else { 'by-id@newco.onmicrosoft.com' }
        $id = if ($Uri -notmatch '\$filter=' -and $Uri -match '/v1\.0/users/([^?]+)') { $Matches[1] } else { '11111111-1111-1111-1111-111111111111' }
        [pscustomobject]@{
            id                = $id
            userPrincipalName = $upn
            displayName       = 'Stub User'
        }
    }
}

Describe 'Resolve-CutoverUser' {

    Context 'when the lookup succeeds or simply misses' {

        BeforeAll {
            $script:userLookupCalls = [System.Collections.Generic.List[string]]::new()

            function Invoke-MigrationGraphRequest {
                param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
                $script:userLookupCalls.Add($Uri)
                if ($Uri -notmatch '\$filter=') { return New-StubGraphUser -Uri $Uri }
                # Only the mail filter matches, so the UPN-then-mail fallback is exercised.
                if ($Uri -like '*$filter=mail eq*') { return New-StubGraphUser -Uri $Uri }
                return @()
            }
        }

        It 'returns the user and no error for an object ID' {
            $result = Resolve-CutoverUser -Identity '22222222-2222-2222-2222-222222222222'

            $result.User.Id | Should -Be '22222222-2222-2222-2222-222222222222'
            $result.Error | Should -BeNullOrEmpty
        }

        It 'falls back from the UPN filter to the mail filter' {
            $script:userLookupCalls.Clear()
            $result = Resolve-CutoverUser -Identity 'john.smith@newco.com'

            $result.User.UserPrincipalName | Should -Be 'john.smith@newco.com'
            $result.Error | Should -BeNullOrEmpty
        }

        It 'looks the UPN up through a $select''d $filter query, not the whole directory' {
            $script:userLookupCalls.Clear()
            $null = Resolve-CutoverUser -Identity 'john.smith@newco.com'

            $script:userLookupCalls[0] | Should -Be (
                "/v1.0/users?`$filter=userPrincipalName eq 'john.smith@newco.com'&`$select=$script:graphUserSelect")
        }
    }

    Context 'when the identity does not exist' {

        BeforeAll {
            function Invoke-MigrationGraphRequest {
                param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
                if ($Uri -notmatch '\$filter=') {
                    throw "[Request_ResourceNotFound] : Resource '$Uri' does not exist or one of its queried reference-property objects are not present."
                }
                return @()
            }
        }

        It 'returns no user and no error for a filter miss' {
            $result = Resolve-CutoverUser -Identity 'nobody@newco.com'

            $result.User | Should -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }

        It 'treats the SDK not-found error on an object ID as a miss, not a failure' {
            $result = Resolve-CutoverUser -Identity '33333333-3333-3333-3333-333333333333'

            $result.User | Should -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }
    }

    Context 'when the lookup itself fails' {

        BeforeAll {
            function Invoke-MigrationGraphRequest {
                param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
                if ($Uri -like '*throttled*') { throw 'Too many requests (429). Retry after 30 seconds.' }
                throw '[Authorization_RequestDenied] : Insufficient privileges to complete the operation.'
            }
        }

        It 'reports throttling as an error instead of an unknown user' {
            $result = Resolve-CutoverUser -Identity 'throttled@newco.com'

            $result.User | Should -BeNullOrEmpty
            $result.Error | Should -Match '429'
            $result.Error | Should -Match 'throttled@newco.com'
        }

        It 'reports an access-denied lookup as an error' {
            $result = Resolve-CutoverUser -Identity 'denied@newco.com'

            $result.Error | Should -Match 'Authorization_RequestDenied'
        }
    }
}

Describe 'Plan rows that are not actionable are Skipped, not dropped' {

    <#
        A wave's results must reconcile against the plan row for row, so every User row in the
        wave gets a results row: the actionable statuses are Planned (under -DryRun) and the rest
        are Skipped with their PlanStatus named. Directory-synced rows are still processed - the
        IsSynced column describes the source object, not the fresh cloud user being reset.
    #>

    BeforeAll {
        $global:cutoverRequestedScopes = [System.Collections.Generic.List[string]]::new()

        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            foreach ($scope in @($Scopes)) { $global:cutoverRequestedScopes.Add($scope) }
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }
        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Method -eq 'PATCH') { throw 'Invoke-MigrationGraphRequest PATCH was reached, which -DryRun must have prevented.' }
            return New-StubGraphUser -Uri $Uri
        }

        $script:planRuns = @{}
        foreach ($case in @(
                @{ Name = 'wave1'; Wave = '1'; IncludeCollisions = $false }
                @{ Name = 'wave1Collisions'; Wave = '1'; IncludeCollisions = $true }
                @{ Name = 'wave3'; Wave = '3'; IncludeCollisions = $false }
            )) {
            $workspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-Plan-$($case.Name)-$([guid]::NewGuid())"
            $null = New-Item -Path $workspace -ItemType Directory -Force
            $planFile = Join-Path $workspace 'IdentityPlan.csv'
            Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $planFile
            $hashBefore = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash

            & $script:scriptPath -PlanPath $planFile -Wave $case.Wave -IncludeCollisions:$case.IncludeCollisions `
                -OutputPath $workspace -Verbosity Low -DryRun
            $exit = $LASTEXITCODE

            $file = @(Get-ChildItem -LiteralPath $workspace -Filter 'Reset-CutoverPasswords-DryRun_*.csv')
            $log = @(Get-ChildItem -LiteralPath $workspace -Filter '*.log')
            $script:planRuns[$case.Name] = [pscustomobject]@{
                Workspace   = $workspace
                ExitCode    = $exit
                Rows        = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
                LogText     = if ($log.Count -ge 1) { Get-Content -LiteralPath $log[0].FullName -Raw } else { '' }
                PlanChanged = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash -ne $hashBefore
            }
        }

        $script:wave1 = $script:planRuns['wave1']
        $script:rowFor = {
            param($Run, [string]$Identity)
            @($Run.Rows | Where-Object { $_.Identity -eq $Identity }) | Select-Object -First 1
        }
    }

    AfterAll {
        foreach ($run in $script:planRuns.Values) {
            if ($run.Workspace -and (Test-Path -LiteralPath $run.Workspace)) {
                Remove-Item -LiteralPath $run.Workspace -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Variable -Name cutoverRequestedScopes -Scope Global -ErrorAction SilentlyContinue
    }

    It 'writes one results row for every User row in the wave' {
        $script:wave1.Rows.Count | Should -Be 7
        $script:wave1.ExitCode | Should -Be 0
    }

    It 'plans the actionable rows' {
        (& $script:rowFor $script:wave1 'john.smith@newco.com').Status | Should -BeExactly 'Planned'
    }

    It 'skips a NeedsReview row and names the status' {
        $row = & $script:rowFor $script:wave1 'alice.dean@newco.com'
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'NeedsReview'
    }

    It 'skips a Collision row and says how to include it' {
        $row = & $script:rowFor $script:wave1 'bob.jones@newco.com'
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'Collision'
        $row.Detail | Should -Match '-IncludeCollisions'
    }

    It 'skips an Excluded row and names the status' {
        $row = & $script:rowFor $script:wave1 'breakglass@newco.com'
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'Excluded'
    }

    It 'still plans a directory-synced source row - the destination user carries no sync state' {
        (& $script:rowFor $script:wave1 'carol.white@newco.com').Status | Should -BeExactly 'Planned'
    }

    It 'plans an interim-UPN fallback row under the interim name' {
        (& $script:rowFor $script:wave1 'dave.brown@newco.onmicrosoft.com').Status | Should -BeExactly 'Planned'
    }

    It 'reports a skipped row that has no target under its source UPN' {
        $row = & $script:rowFor $script:wave1 'invalid@contoso.com'
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'Invalid'
    }

    It 'leaves other waves and non-User rows out of the results' {
        @($script:wave1.Rows | Where-Object { $_.Identity -in 'later@newco.com', 'accounts@newco.com' }).Count | Should -Be 0
    }

    It 'plans the Collision row when -IncludeCollisions is given' {
        (& $script:rowFor $script:planRuns['wave1Collisions'] 'bob.jones@newco.com').Status | Should -BeExactly 'Planned'
    }

    It 'treats a wave with rows but nothing actionable as a run of skips, not a fatal error' {
        $run = $script:planRuns['wave3']
        $run.ExitCode | Should -Be 0
        $run.Rows.Count | Should -Be 1
        $run.Rows[0].Status | Should -BeExactly 'Skipped'
        $run.Rows[0].Detail | Should -Match 'NeedsReview'
    }

    It 'puts no credential in a DryRun results file' {
        @($script:wave1.Rows | Where-Object { $_.GeneratedPassword }).Count | Should -Be 0
    }

    It 'keeps the results columns in the standard order' {
        @($script:wave1.Rows[0].PSObject.Properties.Name)[0..3] | Should -Be @('Identity', 'Action', 'Status', 'Detail')
    }

    It 'never writes the plan back' {
        $script:wave1.PlanChanged | Should -BeFalse
    }

    It 'logs the target tenant at a level every verbosity shows' {
        $script:wave1.LogText | Should -Match '\[SUCCESS\] Target tenant: newco\.onmicrosoft\.com as tech@newco\.onmicrosoft\.com'
    }

    It 'requests the password-profile scope and not Directory.ReadWrite.All' {
        $global:cutoverRequestedScopes | Should -Contain 'User-PasswordProfile.ReadWrite.All'
        $global:cutoverRequestedScopes | Should -Not -Contain 'Directory.ReadWrite.All'
    }
}

Describe 'A failed lookup is a Failed row, not a user that does not exist' {

    <#
        The CSV fixture has an Email column only, so it also proves that an email-only CSV is
        resolved through the mail attribute as the help says. The second identity makes the
        Graph stub throw a throttling error, which must surface as Failed with exit code 2 -
        not as a Skipped 'User not found' that leaves the wave looking clean.
    #>

    BeforeAll {
        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }
        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Method -eq 'PATCH') { throw 'Invoke-MigrationGraphRequest PATCH was reached, which -DryRun must have prevented.' }
            if ($Uri -like '*throttled@newco.com*') { throw 'Too many requests (429). Retry after 30 seconds.' }
            if ($Uri -like '*$filter=mail eq*') { return New-StubGraphUser -Uri $Uri }
            return @()
        }

        $script:lookupWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-Lookup-$([guid]::NewGuid())"
        $null = New-Item -Path $script:lookupWorkspace -ItemType Directory -Force

        & $script:scriptPath -CsvPath (Join-Path $script:fixtureRoot 'CutoverUsers.csv') `
            -OutputPath $script:lookupWorkspace -Verbosity Low -DryRun
        $script:lookupExitCode = $LASTEXITCODE

        $file = @(Get-ChildItem -LiteralPath $script:lookupWorkspace -Filter 'Reset-CutoverPasswords-DryRun_*.csv')
        $script:lookupRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:lookupWorkspace -and (Test-Path -LiteralPath $script:lookupWorkspace)) {
            Remove-Item -LiteralPath $script:lookupWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'resolves an email-only CSV through the mail attribute' {
        $row = @($script:lookupRows | Where-Object { $_.Identity -eq 'john.smith@newco.com' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -BeExactly 'Planned'
    }

    It 'records the broken lookup as Failed with the Graph message' {
        $row = @($script:lookupRows | Where-Object { $_.Identity -eq 'throttled@newco.com' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -BeExactly 'Failed'
        $row[0].Detail | Should -Match '429'
        $row[0].Detail | Should -Not -Match 'not found'
    }

    It 'exits 2 so the wave does not look clean' {
        $script:lookupExitCode | Should -Be 2
    }
}

Describe 'Resolve-CutoverPlanIdentity' {

    Context 'when the plan row carries a target UPN' {

        It 'uses TargetUserPrincipalName and reports no fallback' {
            $row = New-MigrationPlanRow
            $row.TargetUserPrincipalName = 'john.smith@contoso.com'
            $row.InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'

            $result = Resolve-CutoverPlanIdentity -Row $row

            $result.Identity | Should -Be 'john.smith@contoso.com'
            $result.Source | Should -Be 'Target'
            $result.Reason | Should -BeNullOrEmpty
        }

        It 'trims surrounding whitespace' {
            $row = New-MigrationPlanRow
            $row.TargetUserPrincipalName = '  jane.doe@contoso.com  '

            (Resolve-CutoverPlanIdentity -Row $row).Identity | Should -Be 'jane.doe@contoso.com'
        }
    }

    Context 'when the target UPN has not been assigned yet' {

        It 'falls back to InterimUserPrincipalName and says why' {
            $row = New-MigrationPlanRow
            $row.TargetUserPrincipalName = ''
            $row.InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'

            $result = Resolve-CutoverPlanIdentity -Row $row

            $result.Identity | Should -Be 'john.smith@newco.onmicrosoft.com'
            $result.Source | Should -Be 'Interim'
            $result.Reason | Should -Match 'InterimUserPrincipalName'
        }

        It 'treats a whitespace-only target as empty' {
            $row = New-MigrationPlanRow
            $row.TargetUserPrincipalName = '   '
            $row.InterimUserPrincipalName = 'jane.doe@newco.onmicrosoft.com'

            (Resolve-CutoverPlanIdentity -Row $row).Source | Should -Be 'Interim'
        }
    }

    Context 'when the row carries neither name' {

        It 'returns no identity rather than guessing' {
            $row = New-MigrationPlanRow
            $row.SourceUserPrincipalName = 'john.smith@fabrikam.com'

            $result = Resolve-CutoverPlanIdentity -Row $row

            $result.Identity | Should -BeNullOrEmpty
            $result.Source | Should -Be 'None'
            $result.Reason | Should -Match 'neither'
        }

        It 'never falls back to the source UPN' {
            $row = New-MigrationPlanRow
            $row.SourceUserPrincipalName = 'john.smith@fabrikam.com'

            (Resolve-CutoverPlanIdentity -Row $row).Identity | Should -Not -Be 'john.smith@fabrikam.com'
        }
    }

    Context 'when the row is missing the plan columns entirely' {

        It 'tolerates a sparse object without throwing' {
            $row = [pscustomobject]@{ SomethingElse = 'x' }

            $result = Resolve-CutoverPlanIdentity -Row $row

            $result.Source | Should -Be 'None'
        }
    }
}

Describe 'A declined confirmation is a Skip, not a Plan' {

    <#
        The only way to reach the ShouldProcess gate is to run the script, so it is invoked with the
        call operator while plain functions declared here shadow the Graph module cmdlets and the
        toolkit's connection helpers. PowerShell resolves commands innermost-scope-first, so these
        win for anything the script calls, while the real module still supplies the run context, the
        logger and the results export. 'exit' inside a script run with '&' ends that script only.
    #>

    BeforeAll {
        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }
        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Method -eq 'PATCH') { throw 'Invoke-MigrationGraphRequest PATCH was reached, which -WhatIf must have prevented.' }
            return [pscustomobject]@{
                id                = '11111111-1111-1111-1111-111111111111'
                userPrincipalName = 'john.smith@newco.com'
                displayName       = 'John Smith'
                accountEnabled    = $true
            }
        }

        $script:whatIfWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-WhatIf-$([guid]::NewGuid())"
        $null = New-Item -Path $script:whatIfWorkspace -ItemType Directory -Force

        & $script:scriptPath -TestUser 'john.smith@newco.com' -OutputPath $script:whatIfWorkspace `
            -Verbosity Low -WhatIf

        $file = @(Get-ChildItem -LiteralPath $script:whatIfWorkspace -Filter 'Reset-CutoverPasswords-Results_*.csv')
        $script:whatIfRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:whatIfWorkspace -and (Test-Path -LiteralPath $script:whatIfWorkspace)) {
            Remove-Item -LiteralPath $script:whatIfWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Reports the declined reset as Skipped rather than Planned or Succeeded' {
        $script:whatIfRows.Count | Should -Be 1
        $script:whatIfRows[0].Status | Should -BeExactly 'Skipped'
        $script:whatIfRows[0].Detail | Should -BeExactly 'Declined at the confirmation prompt.'
    }

    It 'Puts no credential in the results file for a reset that never happened' {
        $script:whatIfRows[0].GeneratedPassword | Should -BeNullOrEmpty
    }
}

Describe 'A live -Group run enumerates members over REST and PATCHes the password profile' {

    <#
        The only Describe in this file that lets a reset actually happen: -Confirm:$false
        stands in for an operator answering yes at the ShouldProcess prompt. It proves three
        things the REST conversion changed - group member paging, the @odata.type filter that
        drops non-user members (a nested group here), and the shape of the PATCH body - none of
        which the -DryRun and -WhatIf Describes above ever reach.
    #>

    BeforeAll {
        # $global:, not $script: - Invoke-MigrationGraphRequest below runs inside the call
        # stack of the invoked script under test, whose scope chain does not reach back to
        # this file's script scope (see the PSAvoidGlobalVars suppression at the top of this
        # file). The GUIDs are hardcoded directly in the stub and repeated verbatim in the
        # It blocks below, for the same reason.
        $global:cutoverLiveCalls = [System.Collections.Generic.List[object]]::new()

        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }

        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            $global:cutoverLiveCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })

            # The /members check must run first: -like's '?' is a single-character wildcard, so
            # a pattern ending '.../11111111-1111-1111-1111-111111111111?*' also matches the
            # members Uri (the '/' before 'members' satisfies that wildcard).
            if ($Uri -like '*/members*') {
                # A user member and a nested group, so the @odata.type filter has something to drop.
                return @(
                    [pscustomobject]@{
                        id                = '22222222-2222-2222-2222-222222222222'
                        userPrincipalName = 'john.smith@newco.com'
                        displayName       = 'John Smith'
                        '@odata.type'     = '#microsoft.graph.user'
                    }
                    [pscustomobject]@{
                        id            = '33333333-3333-3333-3333-333333333333'
                        displayName   = 'Nested Group'
                        '@odata.type' = '#microsoft.graph.group'
                    }
                )
            }
            if ($Uri -like '*/v1.0/groups/11111111-1111-1111-1111-111111111111?*') {
                return [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Cutover Group' }
            }
            return $null
        }

        $script:liveWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-Live-$([guid]::NewGuid())"
        $null = New-Item -Path $script:liveWorkspace -ItemType Directory -Force

        & $script:scriptPath -Group '11111111-1111-1111-1111-111111111111' -OutputPath $script:liveWorkspace `
            -Verbosity Low -Confirm:$false
        $script:liveExitCode = $LASTEXITCODE

        $file = @(Get-ChildItem -LiteralPath $script:liveWorkspace -Filter 'Reset-CutoverPasswords-Results_*.csv')
        $script:liveRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:liveWorkspace -and (Test-Path -LiteralPath $script:liveWorkspace)) {
            Remove-Item -LiteralPath $script:liveWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name cutoverLiveCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'exits 0' {
        $script:liveExitCode | Should -Be 0
    }

    It 'enumerates the group members with a single paged, $select''d GET' {
        $memberCalls = @($global:cutoverLiveCalls | Where-Object { $_.Uri -like '*/members*' })
        $memberCalls.Count | Should -Be 1
        $memberCalls[0].Method | Should -Be 'GET'
        $memberCalls[0].Uri | Should -Be "/v1.0/groups/11111111-1111-1111-1111-111111111111/members?`$select=id,userPrincipalName,displayName"
    }

    It 'resets only the user member, dropping the nested group' {
        $script:liveRows.Count | Should -Be 1
        $script:liveRows[0].Identity | Should -Be 'john.smith@newco.com'
        $script:liveRows[0].Status | Should -BeExactly 'Succeeded'
    }

    It 'PATCHes the user object with a passwordProfile body' {
        $patchCalls = @($global:cutoverLiveCalls | Where-Object { $_.Method -eq 'PATCH' })
        $patchCalls.Count | Should -Be 1
        $patchCalls[0].Uri | Should -Be '/v1.0/users/22222222-2222-2222-2222-222222222222'
        $patchCalls[0].Body.passwordProfile | Should -Not -BeNullOrEmpty
        $patchCalls[0].Body.passwordProfile.forceChangePasswordNextSignIn | Should -Be $true
        $patchCalls[0].Body.passwordProfile.password | Should -Not -BeNullOrEmpty
    }

    It 'records the generated password in the results file, never in the PATCH-carried detail alone' {
        $script:liveRows[0].GeneratedPassword | Should -Not -BeNullOrEmpty
    }
}

Describe 'The tenant guard runs once over the Graph session' {

    <#
        A password reset is the most destructive thing in the toolkit to aim at the wrong
        tenant, so the guard is checked here the same way as everywhere else: Assert-MigrationTenant
        is shadowed rather than mocked, so the call is recorded without the module's real resolver
        touching the network.
    #>

    BeforeAll {
        $script:guardTenantId = '00000000-0000-0000-0000-0000000000e1'

        function Assert-MigrationTenant {
            param($ExpectedTenantId, $GraphContext, $ExchangeConnection, $TeamsTenant, $Purpose)
            $global:AssertCalls += , $PSBoundParameters
            [pscustomobject]@{ Matches = $true; ExpectedTenantId = $ExpectedTenantId; Connected = @{}; Reason = '' }
        }
        # Echoes the tenant back so the test can tell the assert was handed the connection this
        # run established, not some other object.
        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = $TenantId; Account = 'tech@newco.onmicrosoft.com' }
        }
        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Method -eq 'PATCH') { throw 'A PATCH was reached, which -DryRun must have prevented.' }
            return New-StubGraphUser -Uri $Uri
        }

        $script:guardWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-Guard-$([guid]::NewGuid())"
        $null = New-Item -Path $script:guardWorkspace -ItemType Directory -Force
    }

    BeforeEach {
        $global:AssertCalls = @()
    }

    AfterAll {
        Remove-Variable -Name AssertCalls -Scope Global -ErrorAction SilentlyContinue
        if ($script:guardWorkspace -and (Test-Path -LiteralPath $script:guardWorkspace)) {
            Remove-Item -LiteralPath $script:guardWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Asserts the -TenantId it was given against the Graph context exactly once' {
        & $script:scriptPath -TestUser 'john.smith@newco.com' -TenantId $script:guardTenantId `
            -OutputPath $script:guardWorkspace -Verbosity Low -DryRun -Confirm:$false

        $global:AssertCalls.Count | Should -Be 1
        $global:AssertCalls[0].ExpectedTenantId | Should -BeExactly $script:guardTenantId
        $global:AssertCalls[0].Purpose | Should -BeExactly 'Cutover password reset'
        $global:AssertCalls[0].GraphContext.TenantId | Should -BeExactly $script:guardTenantId
    }
}

Describe 'A results export that fails still leaves the generated credentials on disk' {

    <#
        The passphrase this script mints exists in exactly two places: the account it was set
        on, and the results file. If the results file cannot be written the credential is gone
        and every account in the wave is locked out, so the export is retried into the temp
        folder rather than abandoned. Export-MigrationResult is shadowed to throw, standing in
        for a read-only or full run folder.
    #>

    BeforeAll {
        # Initialised before anything that can throw, so the AfterAll sweep below always has a
        # list to walk even if the run itself blows up half way through this block.
        $script:fbFiles = @()
        $global:cutoverFallbackExports = 0

        # Leads with '-', so the rescue copy has to carry the same credential exemption the
        # normal export does - a quote-prefixed copy is a passphrase the account does not have.
        function New-MigrationPassphrase {
            param([int]$WordCount)
            return '-silver-copper-Lantern74!'
        }

        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }

        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Uri -like '*/members*') {
                return @([pscustomobject]@{
                        id                = '22222222-2222-2222-2222-222222222222'
                        userPrincipalName = 'john.smith@newco.com'
                        # Leads with '=', so the rescue copy has to sanitise it the way
                        # Export-MigrationResult would before Excel reads it as a formula.
                        displayName       = '=cmd|test'
                        '@odata.type'     = '#microsoft.graph.user'
                    })
            }
            if ($Uri -like '*/v1.0/groups/11111111-1111-1111-1111-111111111111?*') {
                return [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Cutover Group' }
            }
            return $null
        }

        function Export-MigrationResult {
            param([object[]]$Rows, [string]$Name, [switch]$DryRun)
            $global:cutoverFallbackExports++
            throw 'Access to the path is denied.'
        }

        $script:fbWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-Fallback-$([guid]::NewGuid())"
        $null = New-Item -Path $script:fbWorkspace -ItemType Directory -Force

        # A -Prefix makes the temp fallback file's name unique to this test, which is the only
        # way to find and clean it up again; the GUID keeps a stray from an interrupted earlier
        # run from being counted as this run's output.
        $script:fbPrefix = "ResetFallback$([guid]::NewGuid().ToString('N'))"

        & $script:scriptPath -Group '11111111-1111-1111-1111-111111111111' -OutputPath $script:fbWorkspace `
            -Prefix $script:fbPrefix -Verbosity Low -Confirm:$false
        $script:fbExitCode = $LASTEXITCODE

        $script:fbFiles = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
                -Filter "$($script:fbPrefix)_Reset-CutoverPasswords-*.csv" -ErrorAction SilentlyContinue)
        $script:fbRows = if ($script:fbFiles.Count -ge 1) {
            @(Import-Csv -LiteralPath $script:fbFiles[0].FullName)
        }
        else { @() }

        $logFile = @(Get-ChildItem -LiteralPath $script:fbWorkspace -Recurse -Filter '*.log')
        $script:fbLog = if ($logFile.Count -ge 1) { Get-Content -LiteralPath $logFile[0].FullName -Raw } else { '' }
    }

    AfterAll {
        if (Get-Variable -Name fbFiles -Scope Script -ErrorAction SilentlyContinue) {
            foreach ($file in $script:fbFiles) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        if ($script:fbWorkspace -and (Test-Path -LiteralPath $script:fbWorkspace)) {
            Remove-Item -LiteralPath $script:fbWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name cutoverFallbackExports -Scope Global -ErrorAction SilentlyContinue
    }

    It 'tried the run folder first' {
        $global:cutoverFallbackExports | Should -Be 1
    }

    It 'writes exactly one fallback file into the temp folder' {
        $script:fbFiles.Count | Should -Be 1
    }

    It 'names the live-run copy -Results, the same as the file it stands in for' {
        $script:fbFiles[0].Name | Should -BeLike "$($script:fbPrefix)_Reset-CutoverPasswords-Results_*.csv"
    }

    It 'keeps the generated credential in the fallback file, byte for byte as it was minted' {
        $script:fbRows.Count | Should -Be 1
        $script:fbRows[0].Identity | Should -BeExactly 'john.smith@newco.com'
        $script:fbRows[0].Status | Should -BeExactly 'Succeeded'
        $script:fbRows[0].GeneratedPassword | Should -BeExactly '-silver-copper-Lantern74!'
    }

    It 'sanitises the rescue copy against formula injection, as the normal export would' {
        $script:fbRows[0].DisplayName | Should -BeExactly "'=cmd|test"
    }

    It 'tells the operator at ERROR where the copy landed and what to do with it' {
        $script:fbLog | Should -Match '\[ERROR\].*Results could not be written to'
        $script:fbLog | Should -Match "a copy was saved to .*$($script:fbPrefix)_Reset-CutoverPasswords-Results"
        $script:fbLog | Should -Match 'Move it into the run folder\.'
    }

    It 'never writes the credential itself into the log' {
        $script:fbLog | Should -Not -Match ([regex]::Escape($script:fbRows[0].GeneratedPassword))
    }

    It 'still exits 0 - the resets worked and the credentials survived' {
        $script:fbExitCode | Should -Be 0
    }
}

Describe 'A rehearsal that falls back to the temp folder still writes a DryRun file' {

    <#
        The workbench reads a step's state from the results filename's suffix, so a rescue copy
        of a rehearsal that landed as '-Results' would mark the reset done when nothing happened.
    #>

    BeforeAll {
        $script:dryFbFiles = @()

        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }

        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Method -eq 'PATCH') { throw 'A PATCH was reached, which -DryRun must have prevented.' }
            return New-StubGraphUser -Uri $Uri
        }

        function Export-MigrationResult {
            param([object[]]$Rows, [string]$Name, [switch]$DryRun)
            throw 'Access to the path is denied.'
        }

        $script:dryFbWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-DryFb-$([guid]::NewGuid())"
        $null = New-Item -Path $script:dryFbWorkspace -ItemType Directory -Force
        $script:dryFbPrefix = "ResetDryFallback$([guid]::NewGuid().ToString('N'))"

        & $script:scriptPath -TestUser 'john.smith@newco.com' -OutputPath $script:dryFbWorkspace `
            -Prefix $script:dryFbPrefix -Verbosity Low -DryRun -Confirm:$false

        $script:dryFbFiles = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
                -Filter "$($script:dryFbPrefix)_Reset-CutoverPasswords-*.csv" -ErrorAction SilentlyContinue)
    }

    AfterAll {
        if (Get-Variable -Name dryFbFiles -Scope Script -ErrorAction SilentlyContinue) {
            foreach ($file in $script:dryFbFiles) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        if ($script:dryFbWorkspace -and (Test-Path -LiteralPath $script:dryFbWorkspace)) {
            Remove-Item -LiteralPath $script:dryFbWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes the rescue copy as a DryRun file, never as Results' {
        $script:dryFbFiles.Count | Should -Be 1
        $script:dryFbFiles[0].Name | Should -BeLike "$($script:dryFbPrefix)_Reset-CutoverPasswords-DryRun_*.csv"
    }
}

Describe 'A PATCH that was sent and then failed keeps its passphrase on the Failed row' {

    <#
        Graph may have applied the password profile and simply failed to tell us - a timeout, a
        dropped socket. Clearing the passphrase there locks the user out of an account whose
        credential nobody holds. A failure BEFORE the PATCH is a different case: nothing was
        changed, so surfacing a credential would be a lie.
    #>

    BeforeAll {
        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }

        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Uri -like '*/members*') {
                return @(
                    [pscustomobject]@{
                        id                = '22222222-2222-2222-2222-222222222222'
                        userPrincipalName = 'patch.fails@newco.com'
                        displayName       = 'Patch Fails'
                        '@odata.type'     = '#microsoft.graph.user'
                    }
                    # No id, so the row throws before the PATCH is ever built.
                    [pscustomobject]@{
                        userPrincipalName = 'no.id@newco.com'
                        displayName       = 'No Object Id'
                        '@odata.type'     = '#microsoft.graph.user'
                    }
                )
            }
            if ($Uri -like '*/v1.0/groups/11111111-1111-1111-1111-111111111111?*') {
                return [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Cutover Group' }
            }
            if ($Method -eq 'PATCH') { throw 'The operation timed out waiting for a response.' }
            return $null
        }

        $script:patchWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-Patch-$([guid]::NewGuid())"
        $null = New-Item -Path $script:patchWorkspace -ItemType Directory -Force

        & $script:scriptPath -Group '11111111-1111-1111-1111-111111111111' -OutputPath $script:patchWorkspace `
            -Verbosity Low -Confirm:$false
        $script:patchExitCode = $LASTEXITCODE

        $file = @(Get-ChildItem -LiteralPath $script:patchWorkspace -Filter 'Reset-CutoverPasswords-Results_*.csv')
        $script:patchRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }

        $logFile = @(Get-ChildItem -LiteralPath $script:patchWorkspace -Recurse -Filter '*.log')
        $script:patchLog = if ($logFile.Count -ge 1) {
            Get-Content -LiteralPath $logFile[0].FullName -Raw
        }
        else { '' }
    }

    AfterAll {
        if ($script:patchWorkspace -and (Test-Path -LiteralPath $script:patchWorkspace)) {
            Remove-Item -LiteralPath $script:patchWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the passphrase on the row whose PATCH was sent' {
        $row = @($script:patchRows | Where-Object { $_.Identity -eq 'patch.fails@newco.com' })[0]
        $row.Status | Should -BeExactly 'Failed'
        $row.GeneratedPassword | Should -Not -BeNullOrEmpty
    }

    It 'tells the operator the reset may have applied' {
        $row = @($script:patchRows | Where-Object { $_.Identity -eq 'patch.fails@newco.com' })[0]
        $row.Detail |
            Should -BeLike '*The reset may have applied; verify sign-in with this passphrase before resetting again.*'
    }

    It 'surfaces no credential for a row that failed before the PATCH' {
        $row = @($script:patchRows | Where-Object { $_.Identity -eq 'no.id@newco.com' })[0]
        $row.Status | Should -BeExactly 'Failed'
        $row.GeneratedPassword | Should -BeNullOrEmpty
        $row.Detail | Should -Not -BeLike '*may have applied*'
    }

    It 'never writes the kept passphrase into the log' {
        $row = @($script:patchRows | Where-Object { $_.Identity -eq 'patch.fails@newco.com' })[0]
        $script:patchLog | Should -Not -Match ([regex]::Escape($row.GeneratedPassword))
    }

    It 'still warns that the results file is a password list' {
        $script:patchLog | Should -Match '\[WARNING\].*Generated passwords were written to the results file'
    }
}

Describe 'Credentials that cannot be written anywhere are reported as lost' {

    <#
        Both writes fail: the run folder through the shadowed Export-MigrationResult, the temp
        folder through a shadowed Export-Csv. The accounts have new passwords nobody holds, so
        the run has to end 1 and say so in words an operator can act on.
    #>

    BeforeAll {
        function Connect-MigrationGraph {
            param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
            return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
        }

        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            if ($Uri -like '*/members*') {
                return @([pscustomobject]@{
                        id                = '22222222-2222-2222-2222-222222222222'
                        userPrincipalName = 'john.smith@newco.com'
                        displayName       = 'John Smith'
                        '@odata.type'     = '#microsoft.graph.user'
                    })
            }
            if ($Uri -like '*/v1.0/groups/11111111-1111-1111-1111-111111111111?*') {
                return [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; displayName = 'Cutover Group' }
            }
            return $null
        }

        function Export-MigrationResult {
            param([object[]]$Rows, [string]$Name, [switch]$DryRun)
            throw 'Access to the path is denied.'
        }

        # Shadows the cmdlet for the script only: the module's own Export-MigrationResult runs
        # in the module session state, which this function is not part of. CmdletBinding is
        # what lets the script's explicit -ErrorAction Stop bind as a common parameter rather
        # than failing to bind and throwing for the wrong reason.
        function Export-Csv {
            [CmdletBinding()]
            param(
                [Parameter(ValueFromPipeline)]$InputObject, [string]$LiteralPath, [string]$Path,
                [switch]$NoTypeInformation, [string]$Encoding, [switch]$Force
            )
            process { throw 'The temp folder is not writable either.' }
        }

        $script:lostWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ResetCutover-Lost-$([guid]::NewGuid())"
        $null = New-Item -Path $script:lostWorkspace -ItemType Directory -Force
        $script:lostPrefix = "ResetLost$([guid]::NewGuid().ToString('N'))"

        & $script:scriptPath -Group '11111111-1111-1111-1111-111111111111' -OutputPath $script:lostWorkspace `
            -Prefix $script:lostPrefix -Verbosity Low -Confirm:$false
        $script:lostExitCode = $LASTEXITCODE

        $logFile = @(Get-ChildItem -LiteralPath $script:lostWorkspace -Recurse -Filter '*.log')
        $script:lostLog = if ($logFile.Count -ge 1) { Get-Content -LiteralPath $logFile[0].FullName -Raw } else { '' }
    }

    AfterAll {
        # Nothing should have been written, but the sweep proves it and cleans up if it was.
        if (Get-Variable -Name lostPrefix -Scope Script -ErrorAction SilentlyContinue) {
            foreach ($stray in @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) `
                        -Filter "$($script:lostPrefix)_Reset-CutoverPasswords-*.csv" -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $stray.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        if ($script:lostWorkspace -and (Test-Path -LiteralPath $script:lostWorkspace)) {
            Remove-Item -LiteralPath $script:lostWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exits 1' {
        $script:lostExitCode | Should -Be 1
    }

    It 'counts the lost credentials and says they are lost' {
        $script:lostLog |
            Should -Match '\[ERROR\].*1 generated credential\(s\) could not be persisted anywhere; they are lost'
        $script:lostLog | Should -Match 'Reset the affected accounts again\.'
    }
}
