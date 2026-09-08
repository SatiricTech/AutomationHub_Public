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

        It 'Maps every plan row that has both a source and a target address' {
            $script:Default.Mappings.Count | Should -Be 10
        }

        It 'Maps a user onto the target address the plan chose' {
            $row = @($script:Default.Mappings | Where-Object { $_.'Source user/group' -eq 'jsmith@contoso.com' })
            $row.Count | Should -Be 1
            $row[0].'Destination user/group' | Should -BeExactly 'john.smith@newco.com'
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
            $skipped.Count | Should -Be 5
            @($skipped | Where-Object { $_.Source -eq 'prince@contoso.com' })[0].Detail |
                Should -BeLike 'No target address in the plan (PlanStatus NeedsReview)*'
        }

        It 'Records the mapped rows as Succeeded with the four standard columns first' {
            @($script:Default.Results[0].PSObject.Properties.Name | Select-Object -First 4) |
                Should -Be @('Identity', 'Action', 'Status', 'Detail')
            @($script:Default.Results | Where-Object { $_.Status -eq 'Succeeded' }).Count | Should -Be 10
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

        It 'Names the interim address in the reason when a row has none' {
            @($script:Interim.Results | Where-Object { $_.Source -eq 'prince@contoso.com' })[0].Detail |
                Should -BeLike 'No interim address in the plan*'
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
            @($result.Results | Where-Object { $_.Status -eq 'Planned' }).Count | Should -Be 10
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

        It 'Exits 1 when no selected row has a destination address' {
            $result = Invoke-MappingRun -OutputPath (Join-Path $TestDrive 'nodestination') -Parameter @{
                ObjectType = @('Guest')
            }
            $result.ExitCode | Should -Be 1
            $result.MappingPath | Should -BeExactly ''
        }
    }
}
