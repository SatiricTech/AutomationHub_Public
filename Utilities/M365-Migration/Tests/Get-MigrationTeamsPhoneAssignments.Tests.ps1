#Requires -Version 7.4

<#
    Offline tests for Get-MigrationTeamsPhoneAssignments.ps1.

    The script is read-only against the tenant but it still signs in, so it is never run
    against a real session here. It is invoked with the call operator while plain functions
    defined in BeforeAll shadow the Teams cmdlet and the toolkit's connection and inventory
    helpers. PowerShell resolves a command from the innermost scope outwards, so a function
    defined here wins over the module's exported function of the same name for anything the
    script calls, while the real module still supplies the run context, the logger and the
    results export. 'exit' inside a script invoked with '&' ends that script only, so the
    run's exit code is readable from $LASTEXITCODE and Pester carries on.

    Fixtures live in $global: because a function defined in BeforeAll does not share the
    $script: scope Pester gives the It blocks - $script: inside a stub called from the script
    under test resolves to that script's scope, not this file's.

    Author: AutomationHub
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The fixtures must be reachable from the stub functions defined in BeforeAll, and a function defined there does not share the $script: scope Pester gives the It blocks. $global: is the only scope both sides can see.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script under test binds, including ones a particular test does not read; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
    Justification = 'Connect-MigrationTeams is a stand-in that must carry the module function''s exact name for the script under test to resolve it; Teams is the product name.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'The workspace helpers only create and delete a throwaway temp directory for one test run; a confirmation prompt inside a test would be meaningless.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force
    $script:scriptPath = Join-Path $PSScriptRoot '..' 'Get-MigrationTeamsPhoneAssignments.ps1'

    function New-TeamsPhoneTestWorkspace {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "GetTeamsPhone-$([guid]::NewGuid())"
        $null = New-Item -Path $path -ItemType Directory -Force
        return $path
    }

    function Remove-TeamsPhoneTestWorkspace {
        param([string]$Path)
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Get-TeamsPhoneTestFile {
        param([string]$Workspace, [string]$Pattern)
        $files = @(Get-ChildItem -LiteralPath $Workspace -Filter $Pattern)
        if ($files.Count -ne 1) { return $null }
        return $files[0].FullName
    }

    # --- Stubs for everything that would reach a tenant -------------------------------------
    function Connect-MigrationTeams {
        [CmdletBinding()]
        param([string]$TenantId, [switch]$Reconnect)
        return [pscustomobject]@{
            TenantId    = '11111111-1111-1111-1111-111111111111'
            DisplayName = 'Contoso'
        }
    }

    function Get-MigrationPhoneNumberInventory {
        [CmdletBinding()]
        param([hashtable]$Filter, [int]$PageSize)
        return $global:teamsPhoneTestInventory
    }

    function Get-CsOnlineUser {
        [CmdletBinding()]
        param([string]$Filter, [string]$Identity)
        if ($PSBoundParameters.ContainsKey('Filter')) {
            return @($global:teamsPhoneTestUsers | Where-Object { -not [string]::IsNullOrWhiteSpace($_.LineUri) })
        }
        return $global:teamsPhoneTestUsers
    }

    # --- Fixtures -----------------------------------------------------------------------------
    $aliceId = '00000000-0000-0000-0000-000000000001'
    $bobId = '00000000-0000-0000-0000-000000000002'
    $carolId = '00000000-0000-0000-0000-000000000003'
    $daveId = '00000000-0000-0000-0000-000000000004'
    $erinId = '00000000-0000-0000-0000-000000000005'
    $deletedId = '00000000-0000-0000-0000-000000000006'
    $attendantId = '00000000-0000-0000-0000-000000000007'

    $newUser = {
        param([string]$Upn, [string]$Id, [string]$LineUri, [string]$AccountType = 'User', $SoftDeleted = $null)
        [pscustomobject]@{
            UserPrincipalName        = $Upn
            DisplayName              = ($Upn -split '@')[0]
            Identity                 = $Id
            LineUri                  = $LineUri
            EnterpriseVoiceEnabled   = [bool]$LineUri
            OnlineVoiceRoutingPolicy = if ($LineUri) { [pscustomobject]@{ Name = 'Global-Routing' } } else { $null }
            TenantDialPlan           = $null
            TeamsCallingPolicy       = 'AllowCalling'
            UsageLocation            = 'US'
            AccountEnabled           = $true
            AccountType              = $AccountType
            SoftDeletionTimestamp    = $SoftDeleted
        }
    }

    $global:teamsPhoneTestUsers = @(
        # Holds a Primary plus a Private line: the type and location must follow the LineUri.
        (& $newUser 'alice@contoso.com' $aliceId 'tel:+15550100001'),
        # LineUri with an extension that matches the inventory's '+E164;ext=NNN' form.
        (& $newUser 'bob@contoso.com' $bobId 'tel:+15550100003;ext=300'),
        # Direct Routing number that was never uploaded to the inventory.
        (& $newUser 'carol@contoso.com' $carolId 'tel:+15550100004'),
        # Blank LineUri but an inventory row assigned to the user - the fallback path.
        (& $newUser 'dave@contoso.com' $daveId ''),
        # Nothing at all.
        (& $newUser 'erin@contoso.com' $erinId ''),
        # Soft-deleted, still carrying a number - must not reach the export.
        (& $newUser 'gone@contoso.com' $deletedId 'tel:+15550100006' 'User' (Get-Date '2026-01-15')),
        # Auto attendant resource account with a number.
        (& $newUser 'aa-main@contoso.com' $attendantId 'tel:+15550100007' 'ResourceAccount')
    )

    $newNumber = {
        param([string]$Number, [string]$TargetId, [string]$Category, [string]$Type, [string]$Location)
        [pscustomobject]@{
            TelephoneNumber      = $Number
            AssignedPstnTargetId = $TargetId
            AssignmentCategory   = $Category
            NumberType           = $Type
            LocationId           = $Location
            PstnAssignmentStatus = if ($TargetId) { 'UserAssigned' } else { 'Unassigned' }
            Capability           = @('UserAssignment')
            IsoCountryCode       = 'US'
            ActivationState      = 'Activated'
        }
    }

    # Sorted by TelephoneNumber ascending, as the real cmdlet returns them, so Alice's Private
    # line comes after her Primary one - the order that used to win.
    $global:teamsPhoneTestInventory = @(
        (& $newNumber '+15550100001' $aliceId 'Primary' 'CallingPlan' 'loc-primary'),
        (& $newNumber '+15550100002' $aliceId 'Private' 'OperatorConnect' 'loc-private'),
        (& $newNumber '+15550100003;ext=300' $bobId 'Primary' 'DirectRouting' 'loc-dr'),
        (& $newNumber '+15550100005' $daveId 'Primary' 'CallingPlan' 'loc-dave'),
        (& $newNumber '+15550100006' $deletedId 'Primary' 'CallingPlan' 'loc-gone'),
        (& $newNumber '+15550100007' $attendantId 'Primary' 'CallingPlan' 'loc-aa'),
        (& $newNumber '+15550100009' '' '' 'OCMobile' 'loc-free')
    )
}

AfterAll {
    Remove-Variable -Name teamsPhoneTestUsers, teamsPhoneTestInventory -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Get-MigrationTeamsPhoneAssignments - real run' {

    BeforeAll {
        $script:workspace = New-TeamsPhoneTestWorkspace
        & $script:scriptPath -OutputPath $script:workspace -Verbosity Low -IncludeUnassignedNumbers
        $script:exitCode = $LASTEXITCODE

        $exportFile = Get-TeamsPhoneTestFile -Workspace $script:workspace -Pattern 'TeamsPhoneAssignments_*.csv'
        $script:exportHeaders = if ($exportFile) { @((Get-Content -LiteralPath $exportFile -TotalCount 1) -replace '"', '' -split ',') } else { @() }
        $script:export = if ($exportFile) { @(Import-Csv -LiteralPath $exportFile) } else { @() }

        $resultsFile = Get-TeamsPhoneTestFile -Workspace $script:workspace -Pattern 'Get-TeamsPhoneAssignments-Results_*.csv'
        $script:resultHeaders = if ($resultsFile) { @((Get-Content -LiteralPath $resultsFile -TotalCount 1) -replace '"', '' -split ',') } else { @() }
        $script:results = if ($resultsFile) { @(Import-Csv -LiteralPath $resultsFile) } else { @() }

        $unassignedFile = Get-TeamsPhoneTestFile -Workspace $script:workspace -Pattern 'TeamsPhoneNumbers-Unassigned_*.csv'
        $script:unassigned = if ($unassignedFile) { @(Import-Csv -LiteralPath $unassignedFile) } else { @() }

        $logFile = Get-TeamsPhoneTestFile -Workspace $script:workspace -Pattern 'Get-MigrationTeamsPhoneAssignments_*.log'
        $script:log = if ($logFile) { Get-Content -LiteralPath $logFile -Raw } else { '' }

        $script:byUpn = @{}
        foreach ($row in $script:export) { $script:byUpn[$row.UserPrincipalName] = $row }
    }

    AfterAll {
        Remove-TeamsPhoneTestWorkspace -Path $script:workspace
    }

    It 'Exits 0 and writes the assignments, results and unassigned-number files' {
        $script:exitCode | Should -Be 0
        $script:export.Count | Should -BeGreaterThan 0
        $script:results.Count | Should -BeGreaterThan 0
    }

    It 'Keeps the round-trip columns first and appends AccountType and AdditionalNumbers' {
        $script:exportHeaders | Should -Be @(
            'UserPrincipalName', 'DisplayName', 'PhoneNumber', 'Extension', 'PhoneNumberType',
            'EnterpriseVoiceEnabled', 'OnlineVoiceRoutingPolicy', 'TenantDialPlan', 'TeamsCallingPolicy',
            'LocationId', 'UsageLocation', 'AccountEnabled', 'LineUri',
            'AccountType', 'AdditionalNumbers'
        )
    }

    It 'Names the tenant it read at SUCCESS before writing anything' {
        $script:log | Should -Match '\[SUCCESS\] Reading tenant 11111111-1111-1111-1111-111111111111 \(Contoso\)'
        $script:log.IndexOf('Reading tenant') | Should -BeLessThan $script:log.IndexOf('Assignments CSV')
    }

    Context 'A user holding a Primary and a Private line' {

        It 'Takes the type and location from the number in the LineUri, not the line that sorted last' {
            $row = $script:byUpn['alice@contoso.com']
            $row.PhoneNumber | Should -BeExactly '+15550100001'
            $row.PhoneNumberType | Should -BeExactly 'CallingPlan'
            $row.LocationId | Should -BeExactly 'loc-primary'
        }

        It 'Lists the other line in AdditionalNumbers as number:category' {
            $script:byUpn['alice@contoso.com'].AdditionalNumbers | Should -BeExactly '+15550100002:Private'
        }

        It 'Still exports exactly one row for the user' {
            @($script:export | Where-Object UserPrincipalName -eq 'alice@contoso.com').Count | Should -Be 1
        }

        It 'Warns that the extra lines will not be carried by the Set- script' {
            $script:log | Should -Match '\[WARNING\] 1 user\(s\) hold Alternate/Private numbers'
        }
    }

    Context 'Number resolution for the other shapes' {

        It 'Matches a LineUri with an extension to the inventory''s +E164;ext=NNN row' {
            $row = $script:byUpn['bob@contoso.com']
            $row.PhoneNumber | Should -BeExactly '+15550100003'
            $row.Extension | Should -BeExactly '300'
            $row.PhoneNumberType | Should -BeExactly 'DirectRouting'
            $row.LocationId | Should -BeExactly 'loc-dr'
            $row.AdditionalNumbers | Should -BeNullOrEmpty
        }

        It 'Defaults a number absent from the inventory to DirectRouting with no location' {
            $row = $script:byUpn['carol@contoso.com']
            $row.PhoneNumber | Should -BeExactly '+15550100004'
            $row.PhoneNumberType | Should -BeExactly 'DirectRouting'
            $row.LocationId | Should -BeNullOrEmpty
        }

        It 'Falls back to the inventory row assigned to the user when the LineUri is blank' {
            $row = $script:byUpn['dave@contoso.com']
            $row.PhoneNumber | Should -BeExactly '+15550100005'
            $row.PhoneNumberType | Should -BeExactly 'CallingPlan'
            $row.LocationId | Should -BeExactly 'loc-dave'
            $row.AdditionalNumbers | Should -BeNullOrEmpty
        }

        It 'Leaves the phone columns blank for a user with no number' {
            $row = $script:byUpn['erin@contoso.com']
            $row.PhoneNumber | Should -BeNullOrEmpty
            $row.PhoneNumberType | Should -BeNullOrEmpty
            $row.AdditionalNumbers | Should -BeNullOrEmpty
            $row.AccountType | Should -BeExactly 'User'
        }
    }

    Context 'Accounts that are not ordinary users' {

        It 'Excludes soft-deleted accounts from the export and the results' {
            $script:byUpn.ContainsKey('gone@contoso.com') | Should -BeFalse
            @($script:results | Where-Object Identity -eq 'gone@contoso.com').Count | Should -Be 0
            $script:log | Should -Match '\[WARNING\] Excluded 1 soft-deleted account\(s\)'
        }

        It 'Keeps a resource account but marks it in AccountType' {
            $row = $script:byUpn['aa-main@contoso.com']
            $row.PhoneNumber | Should -BeExactly '+15550100007'
            $row.AccountType | Should -BeExactly 'ResourceAccount'
        }

        It 'Counts the non-user accounts in a warning' {
            $script:log | Should -Match '\[WARNING\] Export includes non-user accounts \(1 ResourceAccount\)'
        }

        It 'Shows the account type in the results row Detail' {
            $row = $script:results | Where-Object Identity -eq 'aa-main@contoso.com' | Select-Object -First 1
            $row.Detail | Should -Match 'Account type ResourceAccount'
        }
    }

    Context 'Results file' {

        It 'Starts every row with Identity, Action, Status, Detail' {
            $script:resultHeaders[0..3] | Should -Be @('Identity', 'Action', 'Status', 'Detail')
        }

        It 'Reports every exported user as Succeeded' {
            $script:results.Count | Should -Be 6
            @($script:results | Where-Object Status -ne 'Succeeded').Count | Should -Be 0
        }
    }

    Context 'Unassigned numbers' {

        It 'Writes only the numbers nobody holds' {
            $script:unassigned.Count | Should -Be 1
            $script:unassigned[0].PhoneNumber | Should -BeExactly '+15550100009'
            $script:unassigned[0].PhoneNumberType | Should -BeExactly 'OCMobile'
        }
    }
}

Describe 'Get-MigrationTeamsPhoneAssignments - dry run' {

    BeforeAll {
        $script:dryWorkspace = New-TeamsPhoneTestWorkspace
        & $script:scriptPath -OutputPath $script:dryWorkspace -Verbosity Low -IncludeUnassignedNumbers -DryRun
        $script:dryExitCode = $LASTEXITCODE

        $resultsFile = Get-TeamsPhoneTestFile -Workspace $script:dryWorkspace -Pattern 'Get-TeamsPhoneAssignments-DryRun_*.csv'
        $script:dryResults = if ($resultsFile) { @(Import-Csv -LiteralPath $resultsFile) } else { @() }
    }

    AfterAll {
        Remove-TeamsPhoneTestWorkspace -Path $script:dryWorkspace
    }

    It 'Writes no assignments or unassigned-numbers CSV' {
        @(Get-ChildItem -LiteralPath $script:dryWorkspace -Filter 'TeamsPhone*.csv').Count | Should -Be 0
    }

    It 'Writes a -DryRun_ results file whose rows are Planned' {
        $script:dryExitCode | Should -Be 0
        $script:dryResults.Count | Should -Be 6
        @($script:dryResults | Where-Object Status -ne 'Planned').Count | Should -Be 0
    }
}

Describe 'Get-MigrationTeamsPhoneAssignments - server-side filter fallback' {

    BeforeAll {
        # Shadows the Describe-level stub: the filtered pull fails the way a module that rejects
        # the syntax (or a throttled call) would, and the plain pull returns everything.
        function Get-CsOnlineUser {
            [CmdletBinding()]
            param([string]$Filter, [string]$Identity)
            if ($PSBoundParameters.ContainsKey('Filter')) {
                throw 'Filter syntax rejected by the test stub'
            }
            return $global:teamsPhoneTestUsers
        }

        $script:filterWorkspace = New-TeamsPhoneTestWorkspace
        & $script:scriptPath -OutputPath $script:filterWorkspace -Verbosity Low -OnlyUsersWithNumbers
        $script:filterExitCode = $LASTEXITCODE

        $exportFile = Get-TeamsPhoneTestFile -Workspace $script:filterWorkspace -Pattern 'TeamsPhoneAssignments_*.csv'
        $script:filterExport = if ($exportFile) { @(Import-Csv -LiteralPath $exportFile) } else { @() }

        $logFile = Get-TeamsPhoneTestFile -Workspace $script:filterWorkspace -Pattern 'Get-MigrationTeamsPhoneAssignments_*.log'
        $script:filterLog = if ($logFile) { Get-Content -LiteralPath $logFile -Raw } else { '' }
    }

    AfterAll {
        Remove-TeamsPhoneTestWorkspace -Path $script:filterWorkspace
    }

    It 'Falls back to a full pull filtered locally and still completes' {
        $script:filterExitCode | Should -Be 0
        @($script:filterExport.UserPrincipalName) | Sort-Object | Should -Be @('aa-main@contoso.com', 'alice@contoso.com', 'bob@contoso.com', 'carol@contoso.com')
    }

    It 'Records the real exception message in the warning rather than a fixed diagnosis' {
        $script:filterLog | Should -Match '\[WARNING\] Server-side LineUri filter failed \(Filter syntax rejected by the test stub\)'
    }
}

Describe 'Get-MigrationTeamsPhoneAssignments - tenant pin' {

    BeforeAll {
        # Shadows the file-level stub to record what the script hands to Connect-MigrationTeams.
        # A domain-form -TenantId is the documented pin. Whether a cached session can be reused
        # is the module's decision, so the script's contract is to pass the value through
        # untouched and then name the tenant the connection actually returned - not the pin -
        # before anything is written.
        function Connect-MigrationTeams {
            [CmdletBinding()]
            param([string]$TenantId, [switch]$Reconnect)
            $global:teamsPhoneTestTenantIdSeen = $TenantId
            return [pscustomobject]@{
                TenantId    = '22222222-2222-2222-2222-222222222222'
                DisplayName = 'Contoso Source'
            }
        }

        $script:pinWorkspace = New-TeamsPhoneTestWorkspace
        & $script:scriptPath -OutputPath $script:pinWorkspace -Verbosity Low -TenantId 'contoso.onmicrosoft.com'
        $script:pinExitCode = $LASTEXITCODE

        $logFile = Get-TeamsPhoneTestFile -Workspace $script:pinWorkspace -Pattern 'Get-MigrationTeamsPhoneAssignments_*.log'
        $script:pinLog = if ($logFile) { Get-Content -LiteralPath $logFile -Raw } else { '' }
    }

    AfterAll {
        Remove-TeamsPhoneTestWorkspace -Path $script:pinWorkspace
        Remove-Variable -Name teamsPhoneTestTenantIdSeen -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Passes a domain-form -TenantId to Connect-MigrationTeams unchanged' {
        $script:pinExitCode | Should -Be 0
        $global:teamsPhoneTestTenantIdSeen | Should -BeExactly 'contoso.onmicrosoft.com'
    }

    It 'Names the tenant the connection returned, not the pin, at SUCCESS' {
        $script:pinLog | Should -Match '\[SUCCESS\] Reading tenant 22222222-2222-2222-2222-222222222222 \(Contoso Source\)'
    }
}
