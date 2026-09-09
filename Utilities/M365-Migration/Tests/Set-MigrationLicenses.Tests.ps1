#Requires -Version 7.4

<#
    Offline tests for Set-MigrationLicenses.ps1.

    How the script's functions get into the test session: the script is a script, not a module, and
    dot-sourcing it would run Main and try to reach Microsoft Graph. So the file is parsed and only
    its FunctionDefinitionAst nodes are re-created as script blocks and dot-sourced. That gives the
    real function bodies with no side effects and no edits to the script to make it testable.

    Because the functions then live in the test session state rather than inside a module, plain
    `Mock Invoke-MigrationGraphRequest` intercepts them - `Mock -ModuleName` is not needed. The
    scriptblocks the script hands to Invoke-MigrationAction keep their defining session state, so the
    Graph calls inside them are mocked too.

    Author: AutomationHub
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Set-MigrationLicenses.ps1')).Path
    $parseErrors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Set-MigrationLicenses.ps1 does not parse: $($parseErrors[0].Message)"
    }
    foreach ($definition in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "M365Migration-Licenses-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null

    # Deliberately obvious placeholder GUIDs - no real tenant identifiers in this repo.
    $script:e3Id = '00000000-0000-0000-0000-000000000e30'
    $script:evId = '00000000-0000-0000-0000-000000000e51'
    $script:emsId = '00000000-0000-0000-0000-000000000e70'

    $script:catalog = @(
        [pscustomobject]@{ SkuId = $script:e3Id;  SkuPartNumber = 'SPE_E3'; Available = 5 }
        [pscustomobject]@{ SkuId = $script:evId;  SkuPartNumber = 'MCOEV';  Available = 0 }
        [pscustomobject]@{ SkuId = $script:emsId; SkuPartNumber = 'EMS';    Available = 10 }
    )

    function New-TestPlanRow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds an in-memory fixture; it changes no state.')]
        param([hashtable]$Property = @{})
        $row = New-MigrationPlanRow
        foreach ($key in $Property.Keys) { $row.$key = $Property[$key] }
        return $row
    }

    function New-TestUser {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that builds an in-memory fixture; it changes no state.')]
        param(
            [string]$Id = '00000000-0000-0000-0000-000000000001',
            [string]$UserPrincipalName = 'john.smith@newco.onmicrosoft.com',
            [string]$UsageLocation = '',
            [object[]]$AssignmentState = @()
        )
        return [pscustomobject]@{
            id                      = $Id
            userPrincipalName       = $UserPrincipalName
            displayName             = 'John Smith'
            usageLocation           = $UsageLocation
            licenseAssignmentStates = @($AssignmentState)
        }
    }

    function New-TestRun {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pester helper that opens a toolkit run context in the temporary test workspace.')]
        param([switch]$DryRun)
        $null = Initialize-MigrationRun -ScriptName 'PesterLicenses' -OutputPath $script:workspace `
            -Verbosity Low -DryRun:$DryRun
    }
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-DesiredSku' {

    It 'Reads TargetLicenses verbatim when no SKU map is supplied' {
        $row = New-TestPlanRow -Property @{ TargetLicenses = 'SPE_E3;EMS'; SourceLicenses = 'ENTERPRISEPACK' }
        $desired = Get-DesiredSku -Row $row -SkuMap $null
        $desired.Sku | Should -Be @('SPE_E3', 'EMS')
        $desired.Unmapped | Should -BeNullOrEmpty
    }

    It 'Recomputes the target SKUs from SourceLicenses when a map is supplied' {
        $row = New-TestPlanRow -Property @{ TargetLicenses = 'SPE_E3'; SourceLicenses = 'ENTERPRISEPACK;MCOEV' }
        $map = @{ ENTERPRISEPACK = @('EMS'); MCOEV = @('MCOEV') }
        (Get-DesiredSku -Row $row -SkuMap $map).Sku | Should -Be @('EMS', 'MCOEV')
    }

    It 'Carries an unmapped source SKU through and reports it' {
        $row = New-TestPlanRow -Property @{ SourceLicenses = 'ENTERPRISEPACK;POWER_BI_STANDARD' }
        $desired = Get-DesiredSku -Row $row -SkuMap @{ ENTERPRISEPACK = @('SPE_E3') }
        $desired.Sku | Should -Be @('SPE_E3', 'POWER_BI_STANDARD')
        $desired.Unmapped | Should -Be @('POWER_BI_STANDARD')
    }

    It 'Drops a source SKU the map maps to nothing' {
        $row = New-TestPlanRow -Property @{ SourceLicenses = 'POWER_BI_STANDARD' }
        (Get-DesiredSku -Row $row -SkuMap @{ POWER_BI_STANDARD = @() }).Sku | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-LicenseChange' {

    It 'Adds a SKU the user does not hold' {
        $change = Resolve-LicenseChange -DesiredSkuPartNumber @('SPE_E3') -Catalog $script:catalog -AssignmentState @()
        $change.AddSkuId | Should -Be @($script:e3Id)
        $change.AddSkuPartNumber | Should -Be @('SPE_E3')
        $change.RemoveSkuId | Should -BeNullOrEmpty
    }

    It 'Does not re-add a SKU the user already holds directly' {
        $state = @([pscustomobject]@{ skuId = $script:e3Id; assignedByGroup = $null })
        $change = Resolve-LicenseChange -DesiredSkuPartNumber @('SPE_E3') -Catalog $script:catalog -AssignmentState $state
        $change.AddSkuId | Should -BeNullOrEmpty
        $change.AlreadyAssigned | Should -Be @('SPE_E3')
    }

    It 'Refuses to add a SKU the user inherits from a group' {
        $state = @([pscustomobject]@{ skuId = $script:e3Id; assignedByGroup = '00000000-0000-0000-0000-000000000abc' })
        $change = Resolve-LicenseChange -DesiredSkuPartNumber @('SPE_E3') -Catalog $script:catalog -AssignmentState $state
        $change.AddSkuId | Should -BeNullOrEmpty
        $change.GroupAssigned | Should -Be @('SPE_E3')
    }

    It 'Refuses to remove a group-inherited SKU even with -RemoveUnplanned' {
        $state = @([pscustomobject]@{ skuId = $script:emsId; assignedByGroup = '00000000-0000-0000-0000-000000000abc' })
        $change = Resolve-LicenseChange -DesiredSkuPartNumber @('SPE_E3') -Catalog $script:catalog `
            -AssignmentState $state -RemoveUnplanned
        $change.RemoveSkuId | Should -BeNullOrEmpty
        $change.GroupAssigned | Should -Be @('EMS')
        $change.AddSkuId | Should -Be @($script:e3Id)
    }

    It 'Removes a directly assigned SKU the plan does not ask for, only with -RemoveUnplanned' {
        $state = @([pscustomobject]@{ skuId = $script:emsId; assignedByGroup = '' })

        $without = Resolve-LicenseChange -DesiredSkuPartNumber @('SPE_E3') -Catalog $script:catalog -AssignmentState $state
        $without.RemoveSkuId | Should -BeNullOrEmpty

        $with = Resolve-LicenseChange -DesiredSkuPartNumber @('SPE_E3') -Catalog $script:catalog `
            -AssignmentState $state -RemoveUnplanned
        $with.RemoveSkuId | Should -Be @($script:emsId)
        $with.RemoveSkuPartNumber | Should -Be @('EMS')
    }

    It 'Keeps an unknown part number out of the add set and reports it' {
        $change = Resolve-LicenseChange -DesiredSkuPartNumber @('SPE_E3', 'NOT_A_SKU') -Catalog $script:catalog -AssignmentState @()
        $change.AddSkuPartNumber | Should -Be @('SPE_E3')
        $change.UnknownSku | Should -Be @('NOT_A_SKU')
    }

    It 'Treats a SKU held both directly and by a group as already assigned' {
        $state = @(
            [pscustomobject]@{ skuId = $script:e3Id; assignedByGroup = $null }
            [pscustomobject]@{ skuId = $script:e3Id; assignedByGroup = '00000000-0000-0000-0000-000000000abc' }
        )
        $change = Resolve-LicenseChange -DesiredSkuPartNumber @('SPE_E3') -Catalog $script:catalog -AssignmentState $state
        $change.AddSkuId | Should -BeNullOrEmpty
        $change.AlreadyAssigned | Should -Be @('SPE_E3')
    }
}

Describe 'Measure-LicenseSeat' {

    It 'Counts one seat per user that gains the SKU' {
        $change = @(
            [pscustomobject]@{ AddSkuPartNumber = @('SPE_E3'); UnknownSku = @() }
            [pscustomobject]@{ AddSkuPartNumber = @('SPE_E3', 'EMS'); UnknownSku = @() }
        )
        $seat = @(Measure-LicenseSeat -Change $change -Catalog $script:catalog)
        ($seat | Where-Object SkuPartNumber -EQ 'SPE_E3').Needed | Should -Be 2
        ($seat | Where-Object SkuPartNumber -EQ 'EMS').Needed | Should -Be 1
    }

    It 'Reports a shortfall when demand exceeds the spare seats' {
        $change = @(1..6 | ForEach-Object { [pscustomobject]@{ AddSkuPartNumber = @('SPE_E3'); UnknownSku = @() } })
        $seat = @(Measure-LicenseSeat -Change $change -Catalog $script:catalog)
        $seat[0].Needed | Should -Be 6
        $seat[0].Available | Should -Be 5
        $seat[0].Shortfall | Should -Be 1
        $seat[0].Status | Should -Be 'Shortfall'
    }

    It 'Reports Sufficient when demand exactly matches the spare seats' {
        $change = @(1..5 | ForEach-Object { [pscustomobject]@{ AddSkuPartNumber = @('SPE_E3'); UnknownSku = @() } })
        $seat = @(Measure-LicenseSeat -Change $change -Catalog $script:catalog)
        $seat[0].Shortfall | Should -Be 0
        $seat[0].Status | Should -Be 'Sufficient'
    }

    It 'Flags a SKU the destination tenant does not subscribe to' {
        $change = @([pscustomobject]@{ AddSkuPartNumber = @(); UnknownSku = @('NOT_A_SKU') })
        $seat = @(Measure-LicenseSeat -Change $change -Catalog $script:catalog)
        $seat[0].Status | Should -Be 'Unknown'
        $seat[0].Shortfall | Should -Be 1
    }

    It 'Returns nothing when no row needs a new licence' {
        @(Measure-LicenseSeat -Change @() -Catalog $script:catalog) | Should -HaveCount 0
    }
}

Describe 'Get-DestinationUserMap' {

    BeforeEach {
        $script:graphUri = [System.Collections.Generic.List[string]]::new()
    }

    It 'Batches the lookup instead of making one call per identifier' {
        Mock Invoke-MigrationGraphRequest {
            $script:graphUri.Add($Uri)
            return @()
        }

        $upn = 1..31 | ForEach-Object { "user$_@newco.onmicrosoft.com" }
        $null = Get-DestinationUserMap -UserPrincipalName $upn -ObjectId @() -BatchSize 15

        Should -Invoke Invoke-MigrationGraphRequest -Times 3 -Exactly
    }

    It 'Indexes the results by object id and by lower-cased UPN' {
        Mock Invoke-MigrationGraphRequest {
            return @([pscustomobject]@{ id = 'abc'; userPrincipalName = 'John.Smith@newco.onmicrosoft.com' })
        }

        $map = Get-DestinationUserMap -UserPrincipalName @('John.Smith@newco.onmicrosoft.com') -ObjectId @()
        $map.ById['abc'].userPrincipalName | Should -Be 'John.Smith@newco.onmicrosoft.com'
        $map.ByUpn['john.smith@newco.onmicrosoft.com'].id | Should -Be 'abc'
    }

    It 'Makes no call at all when there is nothing to look up' {
        Mock Invoke-MigrationGraphRequest { return @() }
        $map = Get-DestinationUserMap -UserPrincipalName @() -ObjectId @()
        $map.ById.Count | Should -Be 0
        Should -Invoke Invoke-MigrationGraphRequest -Times 0 -Exactly
    }
}

Describe 'Set-PlanRowLicense' {

    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-MigrationGraphRequest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
            return $null
        }
    }

    It 'Sets usageLocation before it posts assignLicense' {
        New-TestRun
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3'; UsageLocation = 'US' }
        $result = Set-PlanRowLicense -Row $row -User (New-TestUser) -Catalog $script:catalog -SkuMap $null

        $result.Status | Should -Be 'Succeeded'
        $script:calls | Should -HaveCount 2
        $script:calls[0].Method | Should -Be 'PATCH'
        $script:calls[0].Body.usageLocation | Should -Be 'US'
        $script:calls[1].Method | Should -Be 'POST'
        $script:calls[1].Uri | Should -BeLike '*/assignLicense'
    }

    It 'Skips the usageLocation PATCH when the user already has the planned location' {
        New-TestRun
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3'; UsageLocation = 'US' }
        $null = Set-PlanRowLicense -Row $row -User (New-TestUser -UsageLocation 'US') -Catalog $script:catalog -SkuMap $null

        $script:calls | Should -HaveCount 1
        $script:calls[0].Method | Should -Be 'POST'
    }

    It 'Falls back to -DefaultUsageLocation when the plan row has none' {
        New-TestRun
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3' }
        $result = Set-PlanRowLicense -Row $row -User (New-TestUser) -Catalog $script:catalog -SkuMap $null -DefaultUsageLocation 'GB'

        $result.UsageLocation | Should -Be 'GB'
        $script:calls[0].Body.usageLocation | Should -Be 'GB'
    }

    It 'Fails the row rather than guessing when no usage location is available anywhere' {
        New-TestRun
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3' }
        $result = Set-PlanRowLicense -Row $row -User (New-TestUser) -Catalog $script:catalog -SkuMap $null

        $result.Status | Should -Be 'Failed'
        $result.Detail | Should -BeLike '*usage location*'
        Should -Invoke Invoke-MigrationGraphRequest -Times 0 -Exactly
    }

    It 'Produces a Planned row and calls nothing in DryRun' {
        New-TestRun -DryRun
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3'; UsageLocation = 'US' }
        $result = Set-PlanRowLicense -Row $row -User (New-TestUser) -Catalog $script:catalog -SkuMap $null -DryRun

        $result.Status | Should -Be 'Planned'
        $result.Added | Should -Be 'SPE_E3'
        Should -Invoke Invoke-MigrationGraphRequest -Times 0 -Exactly
    }

    It 'Sends no assignLicense call for a SKU the user inherits from a group' {
        New-TestRun
        $state = @([pscustomobject]@{ skuId = $script:e3Id; assignedByGroup = '00000000-0000-0000-0000-000000000abc' })
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3'; UsageLocation = 'US' }
        $result = Set-PlanRowLicense -Row $row -User (New-TestUser -UsageLocation 'US' -AssignmentState $state) `
            -Catalog $script:catalog -SkuMap $null

        $result.Status | Should -Be 'Skipped'
        $result.GroupAssigned | Should -Be 'SPE_E3'
        Should -Invoke Invoke-MigrationGraphRequest -Times 0 -Exactly
    }

    It 'Fails the row when no destination user was found' {
        New-TestRun
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3' }
        $result = Set-PlanRowLicense -Row $row -User $null -Catalog $script:catalog -SkuMap $null

        $result.Status | Should -Be 'Failed'
        $result.Detail | Should -BeLike '*No destination user*'
    }

    It 'Reports a Graph failure as a Failed row rather than throwing' {
        New-TestRun
        Mock Invoke-MigrationGraphRequest { throw 'Graph said no' }
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3'; UsageLocation = 'US' }
        $result = Set-PlanRowLicense -Row $row -User (New-TestUser -UsageLocation 'US') -Catalog $script:catalog -SkuMap $null

        $result.Status | Should -Be 'Failed'
        $result.Detail | Should -BeLike '*Graph said no*'
    }

    It 'Honours -WhatIf by making no Graph call' {
        New-TestRun
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3'; UsageLocation = 'US' }
        $null = Set-PlanRowLicense -Row $row -User (New-TestUser) -Catalog $script:catalog -SkuMap $null -WhatIf

        Should -Invoke Invoke-MigrationGraphRequest -Times 0 -Exactly
    }

    It 'Reports a declined row as Skipped, not Planned or Succeeded' {
        # -WhatIf is not a rehearsal: nothing was sent, so the row must not read as a change the
        # tenant saw. 'Planned' belongs to -DryRun alone.
        New-TestRun
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3'; UsageLocation = 'US' }
        $result = Set-PlanRowLicense -Row $row -User (New-TestUser) -Catalog $script:catalog -SkuMap $null -WhatIf

        $result.Status | Should -Be 'Skipped'
        $result.Detail | Should -BeLike '*declined at the confirmation prompt*'
    }

    It 'Includes the removals in the assignLicense body when -RemoveUnplanned is set' {
        New-TestRun
        $state = @([pscustomobject]@{ skuId = $script:emsId; assignedByGroup = $null })
        $row = New-TestPlanRow -Property @{ TargetUserPrincipalName = 'john.smith@newco.com'; TargetLicenses = 'SPE_E3'; UsageLocation = 'US' }
        $result = Set-PlanRowLicense -Row $row -User (New-TestUser -UsageLocation 'US' -AssignmentState $state) `
            -Catalog $script:catalog -SkuMap $null -RemoveUnplanned

        $result.Removed | Should -Be 'EMS'
        $post = $script:calls | Where-Object { $_.Method -eq 'POST' }
        @($post.Body.removeLicenses) | Should -Be @($script:emsId)
        @($post.Body.addLicenses)[0].skuId | Should -Be $script:e3Id
    }
}
