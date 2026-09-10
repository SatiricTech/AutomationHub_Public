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
