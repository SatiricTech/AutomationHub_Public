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
    Justification = 'These are stand-ins for the Graph-facing module functions whose names the script under test calls. They exist to record that a call happened and change nothing, so ShouldProcess would be meaningless.')]
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
        if ($Uri -like '*/users?$filter=*') { return @() }
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
        City                     = 'Chicago'
        State                    = 'IL'
        Country                  = 'US'
        PostalCode               = '60601'
        StreetAddress            = '233 S Wacker Dr'
        CompanyName              = 'Contoso Ltd'
        EmployeeId               = 'E10045'
        EmployeeType             = 'Employee'
        BusinessPhone            = '+13125550100'
        FaxNumber                = '+13125550199'
        PreferredLanguage        = 'en-US'
        UsageLocation            = 'us'
        InterimUserPrincipalName = 'john.smith@newco.onmicrosoft.com'
        TargetUserPrincipalName  = 'john.smith@newco.com'
        TargetMailNickname       = 'john.smith'
    }
}

AfterAll {
    Remove-Variable -Name usersGraphCalls, usersMutations, usersSkuCatalogCalls -Scope Global -ErrorAction SilentlyContinue
}

Describe 'New-MigrationUsers - comment-based help matches the parameter block' {

    BeforeAll {
        # The same parse the function loader used, kept separate so this block reads as a
        # self-contained check. GetHelpContent() is the parser's own view of the help block,
        # which is what Get-Help renders, so drift shows up here before a technician sees it.
        $helpAst = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$null, [ref]$null)
        $script:helpContent = $helpAst.GetHelpContent()
        $script:declaredParameters = @($helpAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $script:documentedParameters = @($script:helpContent.Parameters.Keys)
        $script:verbositySet = @(($helpAst.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'Verbosity' }).Attributes |
                Where-Object { $_.TypeName.Name -eq 'ValidateSet' } |
                ForEach-Object { $_.PositionalArguments.Value })
    }

    It 'Documents every declared parameter and nothing else' {
        $script:declaredParameters.Count | Should -BeGreaterThan 0
        $missing = @($script:declaredParameters | Where-Object { $script:documentedParameters -notcontains $_.ToUpperInvariant() })
        $missing | Should -BeNullOrEmpty
        $stale = @($script:documentedParameters | Where-Object { @($script:declaredParameters | ForEach-Object { $_.ToUpperInvariant() }) -notcontains $_ })
        $stale | Should -BeNullOrEmpty
    }

    It 'Names every Verbosity value the ValidateSet accepts' {
        $script:verbositySet | Should -Be @('Low', 'Medium', 'High')
        $text = [string]$script:helpContent.Parameters['VERBOSITY']
        foreach ($value in $script:verbositySet) { $text | Should -Match ([regex]::Escape($value)) }
    }

    It 'States the PasswordLength range the ValidateRange enforces' {
        $script:helpContent.Parameters['PASSWORDLENGTH'] | Should -Match '12 to 128'
    }

    It 'Uses only real parameters in every example' {
        $script:helpContent.Examples.Count | Should -BeGreaterThan 0
        $allowed = @($script:declaredParameters) + @('WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction')
        foreach ($example in $script:helpContent.Examples) {
            $commandLine = @(($example -split "`r?`n") | Where-Object { $_.Trim() })[0]
            $used = @([regex]::Matches($commandLine, '(?<=\s)-([A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value })
            $used.Count | Should -BeGreaterThan 0
            $unknown = @($used | Where-Object { $allowed -notcontains $_ })
            $unknown | Should -BeNullOrEmpty
        }
    }
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
        $script:body['city'] | Should -BeExactly 'Chicago'
        $script:body['state'] | Should -BeExactly 'IL'
        $script:body['country'] | Should -BeExactly 'US'
        $script:body['postalCode'] | Should -BeExactly '60601'
        $script:body['streetAddress'] | Should -BeExactly '233 S Wacker Dr'
        $script:body['companyName'] | Should -BeExactly 'Contoso Ltd'
        $script:body['employeeId'] | Should -BeExactly 'E10045'
        $script:body['employeeType'] | Should -BeExactly 'Employee'
        $script:body['faxNumber'] | Should -BeExactly '+13125550199'
        $script:body['preferredLanguage'] | Should -BeExactly 'en-US'
    }

    It 'Wraps BusinessPhone in a one-element businessPhones array' {
        # The comma keeps Pester from unwrapping a one-element array before the type check.
        , $script:body['businessPhones'] | Should -BeOfType [array]
        $script:body['businessPhones'] | Should -Be @('+13125550100')
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
        $row.City = ''
        $row.EmployeeId = ''
        $body = ConvertTo-UserRequestBody -Row $row -UserPrincipalName 'john.smith@newco.com' `
            -MailNickname 'john.smith' -UsageLocation 'US' -Password 'Placeholder-1'
        $body.Contains('jobTitle') | Should -BeFalse
        $body.Contains('mobilePhone') | Should -BeFalse
        $body.Contains('city') | Should -BeFalse
        $body.Contains('employeeId') | Should -BeFalse
    }

    It 'Omits businessPhones when BusinessPhone is empty' {
        $row = $script:planRow.PSObject.Copy()
        $row.BusinessPhone = ''
        $body = ConvertTo-UserRequestBody -Row $row -UserPrincipalName 'john.smith@newco.com' `
            -MailNickname 'john.smith' -UsageLocation 'US' -Password 'Placeholder-1'
        $body.Contains('businessPhones') | Should -BeFalse
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

Describe 'New-MigrationUsers - Resolve-LicenseRequest' {

    BeforeAll {
        $script:licenceCatalog = @([pscustomobject]@{ SkuId = '00000000-0000-0000-0000-0000000000e3'; SkuPartNumber = 'SPE_E3' })
    }

    It 'Skips a row with no TargetLicenses' {
        $result = Resolve-LicenseRequest -Row ([pscustomobject]@{ TargetLicenses = '' }) -UsageLocation 'US' -Catalog $script:licenceCatalog
        $result.SkipReason | Should -Match 'No TargetLicenses'
        $result.Planned | Should -BeNullOrEmpty
    }

    It 'Skips a row with no usage location and says what to set' {
        $result = Resolve-LicenseRequest -Row ([pscustomobject]@{ TargetLicenses = 'SPE_E3' }) -UsageLocation '' -Catalog $script:licenceCatalog
        $result.SkipReason | Should -Match 'usage location'
        $result.SkipReason | Should -Match '-DefaultUsageLocation'
    }

    It 'Separates the part numbers the tenant owns from the ones it does not' {
        $result = Resolve-LicenseRequest -Row ([pscustomobject]@{ TargetLicenses = 'SPE_E3;NOSUCHSKU' }) -UsageLocation 'US' -Catalog $script:licenceCatalog
        $result.SkipReason | Should -BeNullOrEmpty
        $result.Planned | Should -Be @('SPE_E3', 'NOSUCHSKU')
        $result.Unknown | Should -Be @('NOSUCHSKU')
    }

    It 'Reports nothing unknown when every planned part number is in the catalogue' {
        $result = Resolve-LicenseRequest -Row ([pscustomobject]@{ TargetLicenses = 'SPE_E3' }) -UsageLocation 'US' -Catalog $script:licenceCatalog
        $result.Unknown | Should -BeNullOrEmpty
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

    It 'Plans the licence assignment as its own AssignLicense row without assigning anything' {
        $row = @($script:rows | Where-Object { $_.Identity -eq 'jsmith@contoso.com' -and $_.Action -eq 'AssignLicense' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -BeExactly 'Planned'
        $row[0].Detail | Should -Match 'Would assign: SPE_E3'
        $row[0].LicensesAssigned | Should -BeNullOrEmpty
        $create = @($script:rows | Where-Object { $_.Identity -eq 'jsmith@contoso.com' -and $_.Action -eq 'CreateUser' })[0]
        $create.Detail | Should -Not -Match 'Would assign'
    }

    It 'Names a planned SKU the tenant does not own in the rehearsal, still as Planned' {
        $row = @($script:rows | Where-Object { $_.Identity -eq 'adean@contoso.com' -and $_.Action -eq 'AssignLicense' })[0]
        $row.Status | Should -BeExactly 'Planned'
        $row.Detail | Should -Match 'NOSUCHSKU'
        $row.Detail | Should -Match 'Failed'
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
            if ($Uri -like '*/users?$filter=*') { return @() }
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

Describe 'New-MigrationUsers - an account that already exists in the destination tenant' {

    BeforeAll {
        # The lookup finds john.smith already in the destination tenant; every other UPN is new.
        # That flips $planChanged without any row reaching its ShouldProcess gate, which is the
        # path where -WhatIf must still keep the plan file untouched.
        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            $global:usersGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            if ($Method -ne 'GET') { $global:usersMutations.Add("$Method $Uri") }
            if ($Uri -like '*/domains*') { return @([pscustomobject]@{ id = 'newco.onmicrosoft.com'; isVerified = $true }) }
            if ($Uri -like '*/users?*john.smith@newco.onmicrosoft.com*') {
                return @([pscustomobject]@{ id = '77777777-7777-7777-7777-777777777777'; userPrincipalName = 'john.smith@newco.onmicrosoft.com' })
            }
            if ($Uri -like '*/users?$filter=*') { return @() }
            return $null
        }
    }

    Context 'under -DryRun' {

        BeforeAll {
            $script:existsDryWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-ExistsDry-$([guid]::NewGuid())"
            New-Item -Path $script:existsDryWorkspace -ItemType Directory -Force | Out-Null

            $script:existsDryPlan = Join-Path $script:existsDryWorkspace 'IdentityPlan.csv'
            Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:existsDryPlan
            $script:existsDryHash = (Get-FileHash -LiteralPath $script:existsDryPlan -Algorithm SHA256).Hash

            $global:usersGraphCalls.Clear()
            $global:usersMutations.Clear()

            & $script:scriptPath -PlanPath $script:existsDryPlan -Wave '1' `
                -DefaultUsageLocation 'US' -OutputPath $script:existsDryWorkspace -Verbosity Low -DryRun
            $script:existsDryExit = $LASTEXITCODE

            $file = @(Get-ChildItem -LiteralPath $script:existsDryWorkspace -Filter 'New-Users-DryRun_*.csv')
            $script:existsDryRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
            $script:existsDryRow = @($script:existsDryRows |
                Where-Object { $_.Identity -eq 'jsmith@contoso.com' -and $_.Action -eq 'CreateUser' })
        }

        AfterAll {
            if ($script:existsDryWorkspace -and (Test-Path -LiteralPath $script:existsDryWorkspace)) {
                Remove-Item -LiteralPath $script:existsDryWorkspace -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Reports the row as Skipped with the object ID it found' {
            $script:existsDryRow.Count | Should -Be 1
            $script:existsDryRow[0].Status | Should -BeExactly 'Skipped'
            $script:existsDryRow[0].TargetObjectId | Should -BeExactly '77777777-7777-7777-7777-777777777777'
        }

        It 'Says the object ID would be recorded, not that it was' {
            $script:existsDryRow[0].Detail | Should -Match 'would record'
            $script:existsDryRow[0].Detail | Should -Not -Match 'recorded its'
        }

        It 'Writes nothing back to the plan' {
            @($global:usersMutations | Where-Object { $_ -like 'Save-MigrationPlan*' }).Count | Should -Be 0
            (Get-FileHash -LiteralPath $script:existsDryPlan -Algorithm SHA256).Hash | Should -BeExactly $script:existsDryHash
        }

        It 'Exits successfully' {
            $script:existsDryExit | Should -Be 0
        }
    }

    Context 'under -WhatIf' {

        BeforeAll {
            $script:existsWhatIfWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-ExistsWhatIf-$([guid]::NewGuid())"
            New-Item -Path $script:existsWhatIfWorkspace -ItemType Directory -Force | Out-Null

            $script:existsWhatIfPlan = Join-Path $script:existsWhatIfWorkspace 'IdentityPlan.csv'
            Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:existsWhatIfPlan
            $script:existsWhatIfHash = (Get-FileHash -LiteralPath $script:existsWhatIfPlan -Algorithm SHA256).Hash

            $global:usersGraphCalls.Clear()
            $global:usersMutations.Clear()

            & $script:scriptPath -PlanPath $script:existsWhatIfPlan -Wave '1' `
                -DefaultUsageLocation 'US' -OutputPath $script:existsWhatIfWorkspace -Verbosity Low -WhatIf
            $script:existsWhatIfExit = $LASTEXITCODE

            $file = @(Get-ChildItem -LiteralPath $script:existsWhatIfWorkspace -Filter 'New-Users-Results_*.csv')
            $script:existsWhatIfRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
        }

        AfterAll {
            if ($script:existsWhatIfWorkspace -and (Test-Path -LiteralPath $script:existsWhatIfWorkspace)) {
                Remove-Item -LiteralPath $script:existsWhatIfWorkspace -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Reports the row as Skipped because it already exists' {
            $row = @($script:existsWhatIfRows | Where-Object { $_.Identity -eq 'jsmith@contoso.com' -and $_.Action -eq 'CreateUser' })
            $row.Count | Should -Be 1
            $row[0].Status | Should -BeExactly 'Skipped'
            $row[0].Detail | Should -Match 'already exists'
        }

        It 'Does not write the plan back even though a row changed in memory' {
            @($global:usersMutations | Where-Object { $_ -like 'Save-MigrationPlan*' }).Count | Should -Be 0
            (Get-FileHash -LiteralPath $script:existsWhatIfPlan -Algorithm SHA256).Hash | Should -BeExactly $script:existsWhatIfHash
            Test-Path -LiteralPath "$($script:existsWhatIfPlan).bak" | Should -BeFalse
        }

        It 'Makes no write call of any kind' {
            $global:usersMutations | Should -BeNullOrEmpty
        }

        It 'Exits 0 because a declined write is not a failed one' {
            $script:existsWhatIfExit | Should -Be 0
        }
    }
}

Describe 'New-MigrationUsers - a rejected assignLicense call is a Failed row of its own' {

    BeforeAll {
        # The create succeeds and the licence call is refused, which is what a seat shortage or
        # replication lag on a just-created object looks like from the script's side.
        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            $global:usersGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            if ($Method -ne 'GET') { $global:usersMutations.Add("$Method $Uri") }
            if ($Uri -like '*/domains*') { return @([pscustomobject]@{ id = 'newco.onmicrosoft.com'; isVerified = $true }) }
            if ($Uri -like '*/users?$filter=*') { return @() }
            if ($Method -eq 'POST' -and $Uri -eq '/v1.0/users') {
                return [pscustomobject]@{ id = '99999999-9999-9999-9999-999999999999' }
            }
            if ($Uri -like '*/assignLicense') {
                throw 'Request_ResourceNotFound: Resource 99999999-9999-9999-9999-999999999999 does not exist or one of its queried reference-property objects are not present.'
            }
            return $null
        }

        $script:licFailWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-LicFail-$([guid]::NewGuid())"
        New-Item -Path $script:licFailWorkspace -ItemType Directory -Force | Out-Null

        $script:licFailPlan = Join-Path $script:licFailWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:licFailPlan

        $global:usersGraphCalls.Clear()
        $global:usersMutations.Clear()

        & $script:scriptPath -PlanPath $script:licFailPlan -Wave '1' -AssignLicenses `
            -DefaultUsageLocation 'US' -OutputPath $script:licFailWorkspace -Verbosity Low
        $script:licFailExit = $LASTEXITCODE

        $file = @(Get-ChildItem -LiteralPath $script:licFailWorkspace -Filter 'New-Users-Results_*.csv')
        $script:licFailRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:licFailWorkspace -and (Test-Path -LiteralPath $script:licFailWorkspace)) {
            Remove-Item -LiteralPath $script:licFailWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Still reports the account creations as Succeeded' {
        @($script:licFailRows | Where-Object { $_.Action -eq 'CreateUser' -and $_.Status -eq 'Succeeded' }).Count | Should -Be 2
    }

    It 'Reports each licence failure as a Failed AssignLicense row with nothing assigned' {
        $rows = @($script:licFailRows | Where-Object { $_.Action -eq 'AssignLicense' })
        $rows.Count | Should -Be 2
        @($rows | Where-Object { $_.Status -ne 'Failed' }).Count | Should -Be 0
        @($rows | Where-Object { $_.Detail -notmatch 'Licence assignment failed' }).Count | Should -Be 0
        @($rows | Where-Object { $_.LicensesAssigned }).Count | Should -Be 0
    }

    It 'Keeps the licence failure out of the CreateUser row' {
        @($script:licFailRows | Where-Object { $_.Action -eq 'CreateUser' -and $_.Detail -match 'assignment failed' }).Count | Should -Be 0
    }

    It 'Exits 2 so an every-row-Succeeded check cannot pass with unlicensed accounts' {
        $script:licFailExit | Should -Be 2
    }

    It 'Still writes the plan back with the object IDs the run earned' {
        @($global:usersMutations | Where-Object { $_ -like 'Save-MigrationPlan*' }).Count | Should -Be 1
    }

    It 'Logs the licence failure as an error' {
        $log = @(Get-ChildItem -LiteralPath $script:licFailWorkspace -Filter 'New-MigrationUsers_*.log')
        $log.Count | Should -Be 1
        (Get-Content -LiteralPath $log[0].FullName -Raw) | Should -Match '\[ERROR\].*Licence assignment failed'
    }
}

Describe 'New-MigrationUsers - a planned SKU the tenant does not own fails the licence row, not the account' {

    BeforeAll {
        # assignLicense accepts every call; the fixture's adean row plans SPE_E3;NOSUCHSKU while the
        # catalogue stub only owns SPE_E3.
        function Invoke-MigrationGraphRequest {
            param([string]$Method, [string]$Uri, $Body, [switch]$All, [int]$MaxRetry = 5)
            $global:usersGraphCalls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri })
            if ($Method -ne 'GET') { $global:usersMutations.Add("$Method $Uri") }
            if ($Uri -like '*/domains*') { return @([pscustomobject]@{ id = 'newco.onmicrosoft.com'; isVerified = $true }) }
            if ($Uri -like '*/users?$filter=*') { return @() }
            if ($Method -eq 'POST' -and $Uri -eq '/v1.0/users') {
                $upn = [string]$Body['userPrincipalName']
                $id = if ($upn -like 'john.smith@*') { '11111111-aaaa-aaaa-aaaa-111111111111' } else { '22222222-bbbb-bbbb-bbbb-222222222222' }
                return [pscustomobject]@{ id = $id }
            }
            return $null
        }

        $script:skuMissWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Users-SkuMiss-$([guid]::NewGuid())"
        New-Item -Path $script:skuMissWorkspace -ItemType Directory -Force | Out-Null

        $script:skuMissPlan = Join-Path $script:skuMissWorkspace 'IdentityPlan.csv'
        Copy-Item -LiteralPath (Join-Path $script:fixtureRoot 'IdentityPlan.csv') -Destination $script:skuMissPlan

        $global:usersGraphCalls.Clear()
        $global:usersMutations.Clear()

        & $script:scriptPath -PlanPath $script:skuMissPlan -Wave '1' -AssignLicenses `
            -DefaultUsageLocation 'US' -OutputPath $script:skuMissWorkspace -Verbosity Low
        $script:skuMissExit = $LASTEXITCODE

        $file = @(Get-ChildItem -LiteralPath $script:skuMissWorkspace -Filter 'New-Users-Results_*.csv')
        $script:skuMissRows = if ($file.Count -eq 1) { @(Import-Csv -LiteralPath $file[0].FullName) } else { @() }
    }

    AfterAll {
        if ($script:skuMissWorkspace -and (Test-Path -LiteralPath $script:skuMissWorkspace)) {
            Remove-Item -LiteralPath $script:skuMissWorkspace -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Reports a fully assigned row as Succeeded with the part numbers it assigned' {
        $row = @($script:skuMissRows | Where-Object { $_.Identity -eq 'jsmith@contoso.com' -and $_.Action -eq 'AssignLicense' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -BeExactly 'Succeeded'
        $row[0].LicensesAssigned | Should -BeExactly 'SPE_E3'
        $row[0].TargetObjectId | Should -BeExactly '11111111-aaaa-aaaa-aaaa-111111111111'
    }

    It 'Fails the row whose plan names a SKU the tenant does not own, keeping the part it could assign' {
        $row = @($script:skuMissRows | Where-Object { $_.Identity -eq 'adean@contoso.com' -and $_.Action -eq 'AssignLicense' })
        $row.Count | Should -Be 1
        $row[0].Status | Should -BeExactly 'Failed'
        $row[0].Detail | Should -Match 'NOSUCHSKU'
        $row[0].Detail | Should -Match 'Set-MigrationLicenses'
        $row[0].LicensesAssigned | Should -BeExactly 'SPE_E3'
    }

    It 'Leaves that account creation itself Succeeded' {
        $row = @($script:skuMissRows | Where-Object { $_.Identity -eq 'adean@contoso.com' -and $_.Action -eq 'CreateUser' })[0]
        $row.Status | Should -BeExactly 'Succeeded'
        $row.Detail | Should -Not -Match 'NOSUCHSKU'
    }

    It 'Makes the assignLicense call for both accounts' {
        @($global:usersGraphCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*/assignLicense' }).Count | Should -Be 2
    }

    It 'Exits 2' {
        $script:skuMissExit | Should -Be 2
    }
}
