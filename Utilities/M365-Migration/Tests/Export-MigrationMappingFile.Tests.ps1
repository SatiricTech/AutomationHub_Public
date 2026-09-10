#Requires -Version 7.4

<#
    End-to-end tests for Export-MigrationMappingFile.ps1.

    The script is offline, so it runs for real against a checked-in identity plan
    (Fixtures/Export-MigrationMappingFile/IdentityPlan.csv) and writes into TestDrive.
    Every test passes -SkipExcel: the CSV twin carries the same rows and asserting on it
    keeps the suite green on machines without ImportExcel. One test covers the workbook
    path and is skipped when ImportExcel is not installed.

    Author: AutomationHub
#>

# Evaluated during Pester's discovery phase so that the workbook context's -Skip can see it;
# a variable set inside BeforeAll would still be $null when -Skip is evaluated.
$script:HasImportExcel = @(Get-Module -ListAvailable -Name ImportExcel -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]'7.1.0' }).Count -gt 0

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:MappingScript = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Export-MigrationMappingFile.ps1')).ProviderPath
    $script:PlanFixture = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'Export-MigrationMappingFile' 'IdentityPlan.csv')).ProviderPath

    function Invoke-MappingRun {
        <#
        .SYNOPSIS
            Runs the exporter into a fresh directory and returns what it wrote.
        .PARAMETER OutputPath
            Directory to write into; created if it does not exist.
        .PARAMETER Parameter
            Extra or overriding parameters for the script.
        .EXAMPLE
            Invoke-MappingRun -OutputPath $TestDrive/run1 -Parameter @{ UseInterim = $true }
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            [Parameter(Mandatory)]
            [ValidateNotNullOrEmpty()]
            [string]$OutputPath,

            [hashtable]$Parameter = @{}
        )

        if (-not (Test-Path -LiteralPath $OutputPath)) {
            $null = New-Item -Path $OutputPath -ItemType Directory -Force
        }

        $splat = @{
            PlanPath   = $script:PlanFixture
            OutputPath = $OutputPath
            SkipExcel  = $true
            Verbosity  = 'Low'
        }
        foreach ($name in $Parameter.Keys) { $splat[$name] = $Parameter[$name] }

        & $script:MappingScript @splat 6>$null
        $exitCode = $LASTEXITCODE

        $mappingFiles = @(Get-ChildItem -Path $OutputPath -Filter 'Fly_User_Mapping_*.csv' -Recurse -ErrorAction SilentlyContinue)
        $workbooks = @(Get-ChildItem -Path $OutputPath -Filter 'Fly_User_Mapping_*.xlsx' -Recurse -ErrorAction SilentlyContinue)
        $resultFiles = @(Get-ChildItem -Path $OutputPath -Filter 'MappingFile-*.csv' -Recurse -ErrorAction SilentlyContinue)

        [pscustomobject]@{
            ExitCode     = $exitCode
            MappingPath  = if ($mappingFiles.Count -gt 0) { $mappingFiles[0].FullName } else { '' }
            WorkbookPath = if ($workbooks.Count -gt 0) { $workbooks[0].FullName } else { '' }
            ResultPath   = if ($resultFiles.Count -gt 0) { $resultFiles[0].FullName } else { '' }
            Mappings     = if ($mappingFiles.Count -gt 0) { @(Import-Csv -LiteralPath $mappingFiles[0].FullName -Encoding utf8) } else { @() }
            Results      = if ($resultFiles.Count -gt 0) { @(Import-Csv -LiteralPath $resultFiles[0].FullName -Encoding utf8) } else { @() }
        }
    }
}

Describe 'Export-MigrationMappingFile' {

    Context 'The default AvePoint format over the plan fixture' {

        BeforeAll {
            $script:Default = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'default')
        }

        It 'Exits 0 and writes the CSV twin' {
            $script:Default.ExitCode | Should -Be 0
            $script:Default.MappingPath | Should -Not -BeNullOrEmpty
        }

        It "Uses AvePoint's own column headings" {
            @($script:Default.Mappings[0].PSObject.Properties.Name) |
                Should -Be @('Source user/group', 'Destination user/group')
        }

        It 'Maps every signed-off plan row that has both a source and a target address' {
            $script:Default.Mappings.Count | Should -Be 9
        }

        It 'Maps a user onto the target address the plan chose' {
            $row = @($script:Default.Mappings | Where-Object { $_.'Source user/group' -eq 'jsmith@contoso.com' })
            $row.Count | Should -Be 1
            $row[0].'Destination user/group' | Should -BeExactly 'john.smith@newco.com'
        }

        It 'Maps a ManualOverride row onto the address the operator set by hand' {
            $row = @($script:Default.Mappings | Where-Object { $_.'Source user/group' -eq 'mhand@contoso.com' })
            $row.Count | Should -Be 1
            $row[0].'Destination user/group' | Should -BeExactly 'maria.hand@newco.com'
        }

        It 'Leaves out rows the plan has not signed off, even when they still carry a target address' {
            $sources = @($script:Default.Mappings | ForEach-Object { $_.'Source user/group' })
            $sources | Should -Not -Contain 'jqsmith@contoso.com'    # Collision
            $sources | Should -Not -Contain 'aschmidt@contoso.com'   # Collision
            $sources | Should -Not -Contain 'tleaver@contoso.com'    # Excluded by hand after planning

            $excluded = @($script:Default.Results | Where-Object { $_.Source -eq 'tleaver@contoso.com' })[0]
            $excluded.Status | Should -BeExactly 'Skipped'
            $excluded.Detail | Should -BeLike "PlanStatus is 'Excluded'*"

            @($script:Default.Results | Where-Object { $_.Source -eq 'jqsmith@contoso.com' })[0].Detail |
                Should -BeLike "PlanStatus is 'Collision'*"
        }

        It 'Maps shared mailboxes, groups and contacts as well as users' {
            $sources = @($script:Default.Mappings | ForEach-Object { $_.'Source user/group' })
            $sources | Should -Contain 'accounts@contoso.com'
            $sources | Should -Contain 'boardroom@contoso.com'
            $sources | Should -Contain 'allstaff@contoso.com'
            $sources | Should -Contain 'secteam@contoso.com'
            $sources | Should -Contain 'marcus.vendor@contoso.com'
        }

        It 'Leaves out the object types the default -ObjectType list excludes' {
            $sources = @($script:Default.Mappings | ForEach-Object { $_.'Source user/group' })
            $sources | Should -Not -Contain 'projectx@contoso.com'
            $sources | Should -Not -Contain 'dana.lee@fabrikam.com'
        }

        It 'Reports every row it could not map as Skipped, with a reason' {
            $skipped = @($script:Default.Results | Where-Object { $_.Status -eq 'Skipped' })
            $skipped.Count | Should -Be 8
            @($skipped | Where-Object { $_.Source -eq 'prince@contoso.com' })[0].Detail |
                Should -BeLike "PlanStatus is 'NeedsReview'*"
        }

        It 'Records the mapped rows as Succeeded with the four standard columns first' {
            @($script:Default.Results[0].PSObject.Properties.Name | Select-Object -First 4) |
                Should -Be @('Identity', 'Action', 'Status', 'Detail')
            @($script:Default.Results | Where-Object { $_.Status -eq 'Succeeded' }).Count | Should -Be 9
        }

        It 'Writes no workbook when -SkipExcel is used' {
            $script:Default.WorkbookPath | Should -BeExactly ''
        }
    }

    Context '-UseInterim' {

        BeforeAll {
            $script:Interim = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'interim') -Parameter @{ UseInterim = $true }
        }

        It 'Maps onto the interim routing addresses instead of the vanity domain' {
            $row = @($script:Interim.Mappings | Where-Object { $_.'Source user/group' -eq 'jsmith@contoso.com' })[0]
            $row.'Destination user/group' | Should -BeExactly 'john.smith@newco.onmicrosoft.com'
        }

        It 'Names the interim address in the reason when a signed-off row has none' {
            $row = @($script:Interim.Results | Where-Object { $_.Source -eq 'mhand@contoso.com' })[0]
            $row.Status | Should -BeExactly 'Skipped'
            $row.Detail | Should -BeLike 'No interim address in the plan (PlanStatus ManualOverride)*'
            @($script:Interim.Mappings | Where-Object { $_.'Source user/group' -eq 'mhand@contoso.com' }).Count | Should -Be 0
        }
    }

    Context '-IncludeCollisions' {

        BeforeAll {
            $script:Collisions = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'collisions') -Parameter @{ IncludeCollisions = $true }
        }

        It 'Maps the Collision rows onto the suffixed addresses the planner assigned' {
            $script:Collisions.ExitCode | Should -Be 0
            $script:Collisions.Mappings.Count | Should -Be 11
            @($script:Collisions.Mappings | Where-Object { $_.'Source user/group' -eq 'jqsmith@contoso.com' })[0].'Destination user/group' |
                Should -BeExactly 'john.q.smith@newco.com'
            @($script:Collisions.Mappings | Where-Object { $_.'Source user/group' -eq 'aschmidt@contoso.com' })[0].'Destination user/group' |
                Should -BeExactly 'anna-maria.schmidt-braun2@newco.com'
        }

        It 'Still leaves out the rows with any other unsigned-off status' {
            $sources = @($script:Collisions.Mappings | ForEach-Object { $_.'Source user/group' })
            $sources | Should -Not -Contain 'tleaver@contoso.com'
            $sources | Should -Not -Contain 'prince@contoso.com'
            @($script:Collisions.Results | Where-Object { $_.Status -eq 'Skipped' }).Count | Should -Be 6
        }
    }

    Context '-Wave' {

        It 'Maps only the requested wave' {
            $result = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'wave2') -Parameter @{ Wave = '2' }
            $result.ExitCode | Should -Be 0
            $result.Mappings.Count | Should -Be 1
            $result.Mappings[0].'Source user/group' | Should -BeExactly 'jsmith@contoso.com'
        }
    }

    Context '-ObjectType' {

        It 'Maps only the requested object types' {
            $result = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'shared') -Parameter @{ ObjectType = @('Shared', 'Room') }
            $result.Mappings.Count | Should -Be 2
            @($result.Mappings | ForEach-Object { $_.'Destination user/group' }) |
                Should -Be @('accounts@newco.com', 'boardroom@newco.com')
        }
    }

    Context 'Duplicate source addresses' {

        BeforeAll {
            $planPath = Join-Path $TestDrive 'duplicate-plan.csv'
            $rows = @(Import-Csv -LiteralPath $script:PlanFixture -Encoding utf8)
            $duplicate = ($rows | Where-Object { $_.SourcePrimarySmtp -eq 'jsmith@contoso.com' })[0].PSObject.Copy()
            $duplicate.SourceObjectId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
            $duplicate.TargetUserPrincipalName = 'john.smith.duplicate@newco.com'
            $duplicate.TargetPrimarySmtp = 'john.smith.duplicate@newco.com'
            @($rows + $duplicate) | Export-Csv -LiteralPath $planPath -NoTypeInformation -Encoding utf8

            $script:Duplicated = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'duplicate') -Parameter @{ PlanPath = $planPath }
        }

        It 'Keeps the first occurrence only' {
            @($script:Duplicated.Mappings | Where-Object { $_.'Source user/group' -eq 'jsmith@contoso.com' }).Count | Should -Be 1
            @($script:Duplicated.Mappings | Where-Object { $_.'Destination user/group' -eq 'john.smith@newco.com' }).Count | Should -Be 1
        }

        It 'Reports the duplicate as Skipped' {
            @($script:Duplicated.Results | Where-Object { $_.Detail -like 'Duplicate source address*' }).Count | Should -Be 1
        }
    }

    Context 'DryRun' {

        It 'Writes the results file with Status Planned and no mapping file' {
            $outputPath = Join-Path $TestDrive 'dryrun'
            $result = Invoke-MappingRun -OutputPath $outputPath -Parameter @{ DryRun = $true }

            $result.ExitCode | Should -Be 0
            $result.MappingPath | Should -BeExactly ''
            $result.ResultPath | Should -BeLike '*MappingFile-DryRun_*'
            @($result.Results | Where-Object { $_.Status -eq 'Planned' }).Count | Should -Be 9
        }
    }

    Context '-WhatIf' {

        It 'Writes no mapping file and reports the mapped rows as declined, never Succeeded' {
            $result = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'whatif') -Parameter @{ WhatIf = $true }

            $result.ExitCode | Should -Be 0
            $result.MappingPath | Should -BeExactly ''
            $result.WorkbookPath | Should -BeExactly ''
            $result.ResultPath | Should -BeLike '*MappingFile-Results_*'
            @($result.Results | Where-Object { $_.Status -eq 'Succeeded' }).Count | Should -Be 0
            @($result.Results | Where-Object { $_.Status -eq 'Planned' }).Count | Should -Be 0

            $declined = @($result.Results | Where-Object { $_.Detail -eq 'Declined at the confirmation prompt.' })
            $declined.Count | Should -Be 9
            @($declined | Where-Object { $_.Status -ne 'Skipped' }).Count | Should -Be 0

            # The rows that could not be mapped anyway keep their own reason.
            @($result.Results | Where-Object { $_.Source -eq 'prince@contoso.com' })[0].Detail |
                Should -BeLike "PlanStatus is 'NeedsReview'*"
        }
    }

    Context 'The workbook path' -Skip:(-not $script:HasImportExcel) {

        It 'Writes the workbook alongside the CSV twin' {
            $result = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'workbook') -Parameter @{ SkipExcel = $false }
            $result.ExitCode | Should -Be 0
            $result.WorkbookPath | Should -Not -BeNullOrEmpty
            $result.MappingPath | Should -Not -BeNullOrEmpty
            (Get-Item -LiteralPath $result.WorkbookPath).Length | Should -BeGreaterThan 0
        }
    }

    Context 'A workbook write that fails' {

        BeforeAll {
            # Stubs defined here shadow the module's Initialize-MigrationModule and ImportExcel's
            # Export-Excel for the script, which runs in a child scope of this context. The first
            # keeps the test independent of whether ImportExcel is installed; the second stands
            # in for a locked file or a broken ImportExcel runtime dependency.
            function Initialize-MigrationModule { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub replaces the real command; parameters are accepted and ignored')] param($Name, $MinimumVersion) }
            function Export-Excel {
                [CmdletBinding()]
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub replaces the real command; parameters are accepted and ignored')]
                param(
                    [Parameter(ValueFromPipeline)]$InputObject,
                    [string]$Path,
                    [string]$WorksheetName
                )
                process { }
                end { throw "The process cannot access the file '$Path' because it is being used by another process." }
            }

            $script:BrokenWorkbook = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'brokenworkbook') -Parameter @{ SkipExcel = $false }
        }

        It 'Keeps the CSV twin, still writes the results file and exits 0' {
            $script:BrokenWorkbook.ExitCode | Should -Be 0
            $script:BrokenWorkbook.WorkbookPath | Should -BeExactly ''
            $script:BrokenWorkbook.MappingPath | Should -Not -BeNullOrEmpty
            $script:BrokenWorkbook.Mappings.Count | Should -Be 9
            $script:BrokenWorkbook.ResultPath | Should -Not -BeNullOrEmpty
            @($script:BrokenWorkbook.Results | Where-Object { $_.Status -eq 'Succeeded' }).Count | Should -Be 9
        }

        It 'Warns in the log and points at the CSV twin' {
            $log = @(Get-ChildItem -Path (Join-Path $TestDrive 'brokenworkbook') -Filter '*.log' -Recurse)[0]
            $log | Should -Not -BeNullOrEmpty
            (Get-Content -LiteralPath $log.FullName -Raw) | Should -BeLike '*The workbook could not be written:*The CSV twin at *holds the same mappings*'
        }
    }

    Context 'Bad input' {

        It 'Exits 1 and names the supported tools when -Tool is unknown' {
            $result = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'badtool') -Parameter @{ Tool = 'NotATool' }
            $result.ExitCode | Should -Be 1
            $result.MappingPath | Should -BeExactly ''
        }

        It 'Exits 1 when the plan file does not exist' {
            $result = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'noplan') -Parameter @{
                PlanPath = (Join-Path $TestDrive 'no-such-plan.csv')
            }
            $result.ExitCode | Should -Be 1
        }

        It 'Exits 1 but still reports every Skipped row when nothing in the selection can be mapped' {
            $result = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'nodestination') -Parameter @{
                ObjectType = @('Guest')
            }
            $result.ExitCode | Should -Be 1
            $result.MappingPath | Should -BeExactly ''
            $result.ResultPath | Should -Not -BeNullOrEmpty
            $result.Results.Count | Should -Be 1
            @($result.Results | Where-Object { $_.Status -ne 'Skipped' }).Count | Should -Be 0
            $result.Results[0].Detail | Should -BeLike "PlanStatus is 'Excluded'*"
        }
    }
}
