#Requires -Version 7.4

<#
    Offline tests for New-MigrationUsers.ps1.

    Two techniques are used here, both chosen because they work in Pester 6 without
    modifying the script under test:

    1. The script's own functions are loaded by parsing it and dot-sourcing only its
       FunctionDefinitionAst nodes. Dot-sourcing the whole .ps1 would run its Main region
       (and its 'exit'); parsing it gives the same functions with none of the side effects.

    2. The end-to-end DryRun test invokes the script with the call operator and shadows the
       tenant-facing commands with plain functions defined in BeforeAll. PowerShell resolves
       a command from the innermost scope outwards, so a function defined here wins over the
       module's exported function of the same name for anything the script calls - including
       a scriptblock the script hands to Invoke-MigrationAction. That keeps the real module
       (logging, run context, results export, DryRun gating) in the test rather than mocking
       the thing being tested. 'exit' inside a script invoked with '&' ends that script only,
       so the run's exit code is readable from $LASTEXITCODE and Pester carries on.

    Call logs live in $global: because a function defined in BeforeAll does not share the
    $script: scope Pester gives the It blocks.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The call logs must be reachable from the stub functions defined in BeforeAll, and a function defined there does not share the $script: scope Pester gives the It blocks. $global: is the only scope both sides can see.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The stubs must accept every parameter the script passes, including ones a particular test does not assert on; dropping them would turn a real call into a parameter-binding error and hide the behaviour under test.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'These are stand-ins for Exchange Online cmdlets whose names the script under test calls. They exist to record that a call happened and change nothing, so ShouldProcess would be meaningless.')]
param()

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1'
    Import-Module $script:moduleRoot -Force

    $script:scriptPath = Join-Path $PSScriptRoot '..' 'New-MigrationUsers.ps1'
    $script:fixtureRoot = Join-Path $PSScriptRoot 'Fixtures' 'New-MigrationUsers'

    # --- Technique 1: load the script's functions without running its Main region ---------
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw "New-MigrationUsers.ps1 failed to parse: $($parseErrors[0].Message)" }
    $functionText = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
            ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine
    . ([scriptblock]::Create($functionText))

    # --- Technique 2: stubs for everything that would reach a tenant ----------------------
    $global:usersGraphCalls = [System.Collections.Generic.List[object]]::new()
    $global:usersMutations = [System.Collections.Generic.List[string]]::new()

    function Connect-MigrationGraph {
        param([string[]]$Scopes, [string]$TenantId, [switch]$Reconnect)
        return [pscustomobject]@{ TenantId = 'newco.onmicrosoft.com'; Account = 'tech@newco.onmicrosoft.com' }
    }

    function Invoke-MigrationGraphRequest {
        param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
        $global:usersGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
        if ($Method -ne 'GET') { $global:usersMutations.Add("$Method $Uri") }

        if ($Uri -like '*/domains*') {
            # Only the onmicrosoft domain is verified, so every target UPN on newco.com has
            # to fall back to the interim address. That is the interesting path.
            return @([pscustomobject]@{ id = 'newco.onmicrosoft.com'; isVerified = $true })
        }
        if ($Uri -like '*/users?*') { return @() }
        return $null
    }

    # The counter is what proves the catalogue is only read when -AssignLicenses asks for it.
    $global:usersSkuCatalogCalls = 0
    function Get-MigrationSkuCatalog {
        param([switch]$Refresh)
        $global:usersSkuCatalogCalls++
        return @([pscustomobject]@{ SkuId = '00000000-0000-0000-0000-0000000000e3'; SkuPartNumber = 'SPE_E3' })
    }

    function Invoke-MgGraphRequest {
        param([string]$Method, [string]$Uri, $Body, [string]$ContentType, [string]$ErrorAction)
        $global:usersMutations.Add("$Method $Uri")
    }

    function Save-MigrationPlan {
        param([string]$Path, [object[]]$Rows)
        $global:usersMutations.Add("Save-MigrationPlan $Path")
    }

    # --- Shared fixtures ------------------------------------------------------------------
    $script:planRow = [pscustomobject]@{
        ObjectType               = 'User'
        DisplayName              = 'John Q. Smith'
        FirstName                = 'John'
        MiddleName               = 'Quentin'
        LastName                 = 'Smith'
        JobTitle                 = 'Operations Manager'
        Department               = 'Operations'
        Office                   = 'Chicago'
        MobilePhone              = '+15550100'
        UsageLocation            = 'us'
        InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'
        TargetUserPrincipalName  = 'john.smith@newco.com'
        TargetMailNickname       = 'john.smith'
    }
}

AfterAll {
    Remove-Variable -Name usersGraphCalls, usersMutations, usersSkuCatalogCalls -Scope Global -ErrorAction SilentlyContinue
}

Describe 'New-MigrationUsers - Resolve-RowIdentity' {

    It 'Uses the target UPN when its domain is verified' {
        $result = Resolve-RowIdentity -Row $script:planRow -VerifiedDomain @('newco.com', 'newco.onmicrosoft.com')
        $result.UserPrincipalName | Should -BeExactly 'john.smith@newco.com'
        $result.AddressSource | Should -BeExactly 'Target'
        $result.Warning | Should -BeNullOrEmpty
    }

    It 'Falls back to the interim UPN and warns when the target domain is not verified' {
        $result = Resolve-RowIdentity -Row $script:planRow -VerifiedDomain @('newco.onmicrosoft.com')
        $result.UserPrincipalName | Should -BeExactly 'john.smith@newco.onmicrosoft.com'
        $result.AddressSource | Should -BeExactly 'Interim'
        $result.Warning | Should -Match 'not verified'
    }

    It 'Uses the interim UPN unconditionally with -UseInterim' {
        $result = Resolve-RowIdentity -Row $script:planRow -VerifiedDomain @('newco.com') -UseInterim
        $result.UserPrincipalName | Should -BeExactly 'john.smith@newco.onmicrosoft.com'
        $result.AddressSource | Should -BeExactly 'Interim'
    }

    It 'Applies no domain check when the verified-domain list is empty' {
        $result = Resolve-RowIdentity -Row $script:planRow -VerifiedDomain @()
        $result.UserPrincipalName | Should -BeExactly 'john.smith@newco.com'
    }

    It 'Falls back to the UPN local part when the row has no mail nickname' {
        $row = $script:planRow.PSObject.Copy()
        $row.TargetMailNickname = ''
        $result = Resolve-RowIdentity -Row $row -VerifiedDomain @('newco.com')
        $result.MailNickname | Should -BeExactly 'john.smith'
    }

    It 'Reports a row that has neither address instead of guessing one' {
        $row = [pscustomobject]@{ TargetUserPrincipalName = ''; InterimUserPrincipalName = ''; TargetMailNickname = '' }
        $result = Resolve-RowIdentity -Row $row -VerifiedDomain @('newco.com')
        $result.UserPrincipalName | Should -BeNullOrEmpty
        $result.Warning | Should -Match 'neither an interim nor a target'
    }
}

Describe 'New-MigrationUsers - ConvertTo-UserRequestBody' {

    BeforeAll {
        $script:body = ConvertTo-UserRequestBody -Row $script:planRow -UserPrincipalName 'john.smith@newco.com' `
            -MailNickname 'john.smith' -UsageLocation 'us' -Password 'Placeholder-1' -ForceChangePassword $true
    }

    It 'Always sends the properties Graph requires' {
        $script:body['accountEnabled'] | Should -BeTrue
        $script:body['displayName'] | Should -BeExactly 'John Q. Smith'
        $script:body['userPrincipalName'] | Should -BeExactly 'john.smith@newco.com'
        $script:body['mailNickname'] | Should -BeExactly 'john.smith'
        $script:body['passwordProfile'].forceChangePasswordNextSignIn | Should -BeTrue
    }

    It 'Maps the plan columns onto their Graph property names' {
        $script:body['givenName'] | Should -BeExactly 'John'
        $script:body['surname'] | Should -BeExactly 'Smith'
        $script:body['jobTitle'] | Should -BeExactly 'Operations Manager'
        $script:body['department'] | Should -BeExactly 'Operations'
        $script:body['officeLocation'] | Should -BeExactly 'Chicago'
        $script:body['mobilePhone'] | Should -BeExactly '+15550100'
    }

    It 'Uppercases the usage location Graph expects' {
        $script:body['usageLocation'] | Should -BeExactly 'US'
    }

    It 'Omits showInAddressList unless the account is being hidden' {
        $script:body.Contains('showInAddressList') | Should -BeFalse
    }

    It 'Sets showInAddressList to false with -HideFromAddressLists' {
        $hidden = ConvertTo-UserRequestBody -Row $script:planRow -UserPrincipalName 'john.smith@newco.com' `
            -MailNickname 'john.smith' -UsageLocation 'US' -Password 'Placeholder-1' -HideFromAddressLists
        $hidden['showInAddressList'] | Should -BeFalse
    }

    It 'Omits an optional attribute rather than sending it empty' {
        $row = $script:planRow.PSObject.Copy()
        $row.JobTitle = ''
        $row.MobilePhone = ''
        $body = ConvertTo-UserRequestBody -Row $row -UserPrincipalName 'john.smith@newco.com' `
            -MailNickname 'john.smith' -UsageLocation 'US' -Password 'Placeholder-1'
        $body.Contains('jobTitle') | Should -BeFalse
        $body.Contains('mobilePhone') | Should -BeFalse
    }

    It 'Omits usageLocation when the row and the default are both empty' {
        $body = ConvertTo-UserRequestBody -Row $script:planRow -UserPrincipalName 'john.smith@newco.com' `
            -MailNickname 'john.smith' -UsageLocation '' -Password 'Placeholder-1'
        $body.Contains('usageLocation') | Should -BeFalse
    }

    It 'Builds a display name from the first and last name when the plan has none' {
        $row = $script:planRow.PSObject.Copy()
        $row.DisplayName = ''
        $body = ConvertTo-UserRequestBody -Row $row -UserPrincipalName 'john.smith@newco.com' `
            -MailNickname 'john.smith' -UsageLocation 'US' -Password 'Placeholder-1'
        $body['displayName'] | Should -BeExactly 'John Smith'
    }

    It 'Throws when there is no name to build a display name from' {
        $row = [pscustomobject]@{ DisplayName = ''; FirstName = ''; LastName = '' }
        { ConvertTo-UserRequestBody -Row $row -UserPrincipalName 'x@newco.com' -MailNickname 'x' -Password 'p' } |
            Should -Throw -ExpectedMessage '*no DisplayName*'
    }
}

Describe 'New-MigrationUsers - ConvertTo-FailureDetail' {

    It 'Points a UPN conflict at the soft-deleted user that usually causes it' {
        $detail = ConvertTo-FailureDetail -Message 'Another object with the same value for property userPrincipalName already exists.' `
            -UserPrincipalName 'john.smith@newco.com'
        $detail | Should -Match 'deletedItems'
        $detail | Should -Match 'john.smith@newco.com'
    }

    It 'Names the role needed for an authorization failure' {
        $detail = ConvertTo-FailureDetail -Message 'Authorization_RequestDenied: Insufficient privileges to complete the operation.'
        $detail | Should -Match 'User Administrator'
    }

    It 'Suggests -UseInterim for an unverified domain' {
        $detail = ConvertTo-FailureDetail -Message 'Property userPrincipalName is invalid.' -UserPrincipalName 'a@newco.com'
        $detail | Should -Match '-UseInterim'
    }

    It 'Passes an unrecognised error through unchanged' {
        ConvertTo-FailureDetail -Message 'Service unavailable.' | Should -BeExactly 'Service unavailable.'
    }
}

Describe 'New-MigrationUsers - Invoke-LicenseAssignment' {

    BeforeAll {
        $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-Lic-$([guid]::NewGuid())"
        New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null
        # A DryRun run context makes Invoke-MigrationAction suppress the Graph call, so the
        # part-number resolution can be asserted without a tenant.
        $null = Initialize-MigrationRun -ScriptName 'New-MigrationUsers' -OutputPath $script:workspace -DryRun -Verbosity Low
        $script:catalog = @(
            [pscustomobject]@{ SkuId = '00000000-0000-0000-0000-0000000000e3'; SkuPartNumber = 'SPE_E3' }
            [pscustomobject]@{ SkuId = '00000000-0000-0000-0000-0000000000ev'; SkuPartNumber = 'MCOEV' }
        )
    }

    AfterAll {
        if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
            Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Resolves known part numbers to SKU ids' {
        $result = Invoke-LicenseAssignment -UserId 'abc' -SkuPartNumber @('SPE_E3', 'MCOEV') -Catalog $script:catalog -Identity 'a@newco.com'
        $result.Assigned | Should -Be @('SPE_E3', 'MCOEV')
        $result.Unknown | Should -BeNullOrEmpty
    }

    It 'Reports a part number the tenant does not own instead of failing the account' {
        $result = Invoke-LicenseAssignment -UserId 'abc' -SkuPartNumber @('SPE_E3', 'NOSUCHSKU') -Catalog $script:catalog -Identity 'a@newco.com'
        $result.Assigned | Should -Be @('SPE_E3')
        $result.Unknown | Should -Be @('NOSUCHSKU')
    }
}

Describe 'New-MigrationUsers - DryRun end to end' {

    BeforeAll {
        $script:runWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-Run-$([guid]::NewGuid())"
        New-Item -Path $script:runWorkspace -ItemType Directory -Force | Out-Null

        $script:planFile = Join-Path $script:runWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:planFile
        $script:planHashBefore = (Get-FileHash -LiteralPath $script:planFile -Algorithm SHA256).Hash

        $global:usersGraphCalls.Clear()
        $global:usersMutations.Clear()

        & $script:scriptPath -PlanPath $script:planFile -Wave '1' -AssignLicenses -SetManagers `
            -DefaultUsageLocation 'US' -OutputPath $script:runWorkspace -Verbosity Low -DryRun
        $script:runExitCode = $LASTEXITCODE

        $script:resultFile = @(Get-ChildItem -LiteralPath $script:runWorkspace -Filter 'New-Users-DryRun_*.csv')
        $script:rows = if ($script:resultFile.Count -eq 1) { @(Import-Csv -LiteralPath $script:resultFile[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:runWorkspace -and (Test-Path -LiteralPath $script:runWorkspace)) {
            Remove-Item -LiteralPath $script:runWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits successfully' {
        $script:runExitCode | Should -Be 0
    }

    It 'Writes exactly one DryRun results file' {
        $script:resultFile.Count | Should -Be 1
    }

    It 'Makes no write call of any kind' {
        $global:usersMutations | Should -BeNullOrEmpty
    }

    It 'Still performs the read-only lookups a real run would' {
        @($global:usersGraphCalls | Where-Object { $_.Uri -like '*/domains*' }).Count | Should -BeGreaterThan 0
        @($global:usersGraphCalls | Where-Object { $_.Uri -like '*/users?*' }).Count | Should -BeGreaterThan 0
    }

    It 'Leaves the plan file byte-for-byte unchanged and takes no backup' {
        (Get-FileHash -LiteralPath $script:planFile -Algorithm SHA256).Hash | Should -BeExactly $script:planHashBefore
        Test-Path -LiteralPath "$($script:planFile).bak" | Should -BeFalse
    }

    It 'Reports every row as Planned or Skipped, never Succeeded or Failed' {
        $script:rows.Count | Should -BeGreaterThan 0
        @($script:rows | Where-Object { $_.Status -notin @('Planned', 'Skipped') }).Count | Should -Be 0
    }

    It 'Plans a creation for each eligible user row' {
        $planned = @($script:rows | Where-Object { $_.Action -eq 'CreateUser' -and $_.Status -eq 'Planned' })
        $planned.Count | Should -Be 2
        $planned[0].Detail | Should -Match 'Would create'
    }

    It 'Never puts a generated password in a DryRun results file' {
        @($script:rows | Where-Object { $_.GeneratedPassword }).Count | Should -Be 0
    }

    It 'Falls back to the interim address because only the onmicrosoft domain is verified' {
        $row = @($script:rows | Where-Object { $_.Identity -eq 'jsmith@contoso.com' -and $_.Action -eq 'CreateUser' })[0]
        $row.TargetUserPrincipalName | Should -BeExactly 'john.smith@newco.onmicrosoft.com'
        $row.Detail | Should -Match 'not verified'
    }

    It 'Skips a guest row and says why' {
        $row = @($script:rows | Where-Object { $_.ObjectType -eq 'Guest' })[0]
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'Re-invite'
    }

    It 'Skips a recipient row and points at the recipients script' {
        $row = @($script:rows | Where-Object { $_.ObjectType -eq 'Shared' })[0]
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match 'New-MigrationRecipients'
    }

    It 'Skips an excluded row naming its plan status' {
        $row = @($script:rows | Where-Object { $_.Identity -eq 'breakglass@contoso.com' })[0]
        $row.Status | Should -BeExactly 'Skipped'
        $row.Detail | Should -Match "PlanStatus is 'Excluded'"
    }

    It 'Honours the wave filter' {
        @($script:rows | Where-Object { $_.Identity -eq 'later@contoso.com' }).Count | Should -Be 0
    }

    It 'Reports the planned licences without assigning them' {
        $row = @($script:rows | Where-Object { $_.Identity -eq 'jsmith@contoso.com' -and $_.Action -eq 'CreateUser' })[0]
        $row.Detail | Should -Match 'Would assign: SPE_E3'
        $row.LicensesAssigned | Should -BeNullOrEmpty
    }

    It 'Plans the manager pass without touching the directory' {
        $row = @($script:rows | Where-Object { $_.Action -eq 'SetManager' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -BeExactly 'Planned'
    }
}

Describe 'New-MigrationUsers - a declined confirmation is a Skip, not a Plan' {

    BeforeAll {
        $script:whatIfWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-WhatIf-$([guid]::NewGuid())"
        New-Item -Path $script:whatIfWorkspace -ItemType Directory -Force | Out-Null

        $script:whatIfPlan = Join-Path $script:whatIfWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:whatIfPlan

        $global:usersGraphCalls.Clear()
        $global:usersMutations.Clear()
        $global:usersSkuCatalogCalls = 0

        # No -AssignLicenses: the SKU catalogue must not be fetched when nothing will be licensed.
        & $script:scriptPath -PlanPath $script:whatIfPlan -Wave '1' -SetManagers `
            -DefaultUsageLocation 'US' -OutputPath $script:whatIfWorkspace -Verbosity Low -WhatIf
        $script:whatIfExitCode = $LASTEXITCODE

        $script:whatIfFile = @(Get-ChildItem -LiteralPath $script:whatIfWorkspace -Filter 'New-Users-Results_*.csv')
        $script:whatIfRows = if ($script:whatIfFile.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:whatIfFile[0].FullName)
        }
        else { @() }
    }

    AfterAll {
        if ($script:whatIfWorkspace -and (Test-Path -LiteralPath $script:whatIfWorkspace)) {
            Remove-Item -LiteralPath $script:whatIfWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Writes a Results file, not a DryRun file, because -WhatIf is not a rehearsal' {
        $script:whatIfFile.Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:whatIfWorkspace -Filter 'New-Users-DryRun_*.csv').Count | Should -Be 0
    }

    It 'Reports the declined creations as Skipped rather than Planned or Succeeded' {
        $declined = @($script:whatIfRows |
            Where-Object { $_.Action -eq 'CreateUser' -and $_.Detail -eq 'Declined at the confirmation prompt.' })
        $declined.Count | Should -Be 2
        @($declined | Where-Object { $_.Status -ne 'Skipped' }).Count | Should -Be 0
    }

    It 'Leaves no row claiming an outcome the tenant never saw' {
        $script:whatIfRows.Count | Should -BeGreaterThan 0
        @($script:whatIfRows | Where-Object { $_.Status -in @('Planned', 'Succeeded') }).Count | Should -Be 0
    }

    It 'Makes no write call of any kind' {
        $global:usersMutations | Should -BeNullOrEmpty
    }

    It 'Never reads the SKU catalogue without -AssignLicenses' {
        $global:usersSkuCatalogCalls | Should -Be 0
    }

    It 'Exits successfully' {
        $script:whatIfExitCode | Should -Be 0
    }
}

Describe 'New-MigrationUsers - an unreadable SKU catalogue is fatal, not a warning' {

    BeforeAll {
        # Shadowing inside this block keeps the failure local to it; the file-level stub still
        # answers for every other Describe.
        function Get-MigrationSkuCatalog {
            param([switch]$Refresh)
            throw 'Graph refused subscribedSkus.'
        }

        $script:skuWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-Sku-$([guid]::NewGuid())"
        New-Item -Path $script:skuWorkspace -ItemType Directory -Force | Out-Null

        $script:skuPlan = Join-Path $script:skuWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:skuPlan

        $global:usersMutations.Clear()

        & $script:scriptPath -PlanPath $script:skuPlan -Wave '1' -AssignLicenses `
            -DefaultUsageLocation 'US' -OutputPath $script:skuWorkspace -Verbosity Low -DryRun
        $script:skuExitCode = $LASTEXITCODE
    }

    AfterAll {
        if ($script:skuWorkspace -and (Test-Path -LiteralPath $script:skuWorkspace)) {
            Remove-Item -LiteralPath $script:skuWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Stops the run instead of blaming the plan for licences it could not resolve' {
        $script:skuExitCode | Should -Be 1
    }

    It 'Processes no row and writes no results file' {
        @(Get-ChildItem -LiteralPath $script:skuWorkspace -Filter 'New-Users-*.csv').Count | Should -Be 0
        $global:usersMutations | Should -BeNullOrEmpty
    }

    It 'Names the underlying failure in the log' {
        $log = @(Get-ChildItem -LiteralPath $script:skuWorkspace -Filter 'New-MigrationUsers_*.log')
        $log.Count | Should -Be 1
        (Get-Content -LiteralPath $log[0].FullName -Raw) | Should -Match 'Graph refused subscribedSkus'
    }
}

Describe 'New-MigrationUsers - a fatal error still leaves the plan and the results file' {

    BeforeAll {
        # Test-MigrationPlanRowActionable is called outside the per-row try, so throwing from it is
        # the cheapest way to reach the script's top-level catch. Shadowing it here keeps the
        # failure inside this Describe.
        function Test-MigrationPlanRowActionable {
            param($Row, [switch]$IncludeCollisions, [switch]$AllowSynced, [string[]]$SupportedObjectType, $IsSynced)
            if ((Get-MigrationCsvValue -Row $Row -Name 'SourceUserPrincipalName' -Default '') -eq 'adean@contoso.com') {
                throw 'The Graph session dropped between rows.'
            }
            return [pscustomobject]@{ Actionable = $true; Status = 'Planned'; Reason = '' }
        }

        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            $global:usersGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            if ($Method -ne 'GET') { $global:usersMutations.Add("$Method $Uri") }
            if ($Uri -like '*/domains*') { return @([pscustomobject]@{ id = 'newco.onmicrosoft.com'; isVerified = $true }) }
            if ($Uri -like '*/users?*') { return @() }
            if ($Method -eq 'POST' -and $Uri -eq '/v1.0/users') {
                return [pscustomobject]@{ id = '99999999-9999-9999-9999-999999999999' }
            }
            return $null
        }

        $script:fatalWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-Fatal-$([guid]::NewGuid())"
        New-Item -Path $script:fatalWorkspace -ItemType Directory -Force | Out-Null

        $script:fatalPlan = Join-Path $script:fatalWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:fatalPlan

        $global:usersGraphCalls.Clear()
        $global:usersMutations.Clear()

        & $script:scriptPath -PlanPath $script:fatalPlan -Wave '1' `
            -DefaultUsageLocation 'US' -OutputPath $script:fatalWorkspace -Verbosity Low
        $script:fatalExitCode = $LASTEXITCODE

        $script:fatalFile = @(Get-ChildItem -LiteralPath $script:fatalWorkspace -Filter 'New-Users-Results_*.csv')
        $script:fatalRows = if ($script:fatalFile.Count -eq 1) {
            @(Import-Csv -LiteralPath $script:fatalFile[0].FullName)
        }
        else { @() }
    }

    AfterAll {
        if ($script:fatalWorkspace -and (Test-Path -LiteralPath $script:fatalWorkspace)) {
            Remove-Item -LiteralPath $script:fatalWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Exits 1' {
        $script:fatalExitCode | Should -Be 1
    }

    It 'Logs the failure as an error' {
        $log = @(Get-ChildItem -LiteralPath $script:fatalWorkspace -Filter 'New-MigrationUsers_*.log')
        $log.Count | Should -Be 1
        $text = Get-Content -LiteralPath $log[0].FullName -Raw
        $text | Should -Match '\[ERROR\].*The Graph session dropped between rows'
    }

    It 'Writes exactly one results file, carrying the rows processed before the failure' {
        $script:fatalFile.Count | Should -Be 1
        @($script:fatalRows | Where-Object { $_.Identity -eq 'jsmith@contoso.com' -and $_.Status -eq 'Succeeded' }).Count |
            Should -Be 1
    }

    It 'Still writes the plan back so the object ID the run earned is not lost' {
        @($global:usersMutations | Where-Object { $_ -like 'Save-MigrationPlan*' }).Count | Should -Be 1
    }
}
