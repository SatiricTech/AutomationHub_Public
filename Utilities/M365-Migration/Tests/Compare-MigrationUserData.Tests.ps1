#Requires -Version 7.4

<#
    Compare-MigrationUserData is fully offline, so these tests run the real script
    in a child pwsh against the fixtures in Fixtures/Compare-MigrationUserData and
    assert on the results CSV it writes. Nothing is mocked - the script's exit code,
    the results file name and every row are the things being verified.

    Author: AutomationHub
    Written with assistance from Claude (Anthropic).
#>

BeforeAll {
    $script:scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'Compare-MigrationUserData.ps1')).Path
    $script:fixtures = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'Compare-MigrationUserData')).Path

    $script:sourceCsv = Join-Path $script:fixtures 'Source-Users.csv'
    $script:targetCsv = Join-Path $script:fixtures 'Target-Users.csv'
    $script:planCsv = Join-Path $script:fixtures 'IdentityPlan.csv'
    $script:destinationCsv = Join-Path $script:fixtures 'Destination-Users.csv'

    $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) "Compare-MigrationUserData-$([guid]::NewGuid())"
    New-Item -Path $script:workspace -ItemType Directory -Force | Out-Null

    function Invoke-CompareScript {
        <# Runs the script in a child pwsh and returns its exit code plus the results rows. #>
        param([string[]]$Arguments, [string]$ResultPattern)

        $outputDirectory = Join-Path $script:workspace ([guid]::NewGuid().ToString('N'))
        $allArguments = @('-NoProfile', '-File', $script:scriptPath) + $Arguments + @('-OutputPath', $outputDirectory)
        $output = & pwsh @allArguments 2>&1
        $exitCode = $LASTEXITCODE

        $resultFile = Get-ChildItem -LiteralPath $outputDirectory -Filter $ResultPattern -ErrorAction SilentlyContinue |
            Select-Object -First 1

        return [pscustomobject]@{
            ExitCode        = $exitCode
            Output          = ($output -join [Environment]::NewLine)
            OutputDirectory = $outputDirectory
            ResultFile      = $resultFile
            Rows            = if ($resultFile) { @(Import-Csv -LiteralPath $resultFile.FullName) } else { @() }
        }
    }
}

AfterAll {
    if ($script:workspace -and (Test-Path -LiteralPath $script:workspace)) {
        Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Compare-MigrationUserData - CSV mode' {

    BeforeAll {
        $script:csvRun = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
        ) -ResultPattern 'Compare-UserData-Results_*.csv'
    }

    It 'Exits 0 and writes a results CSV' {
        $script:csvRun.ExitCode | Should -Be 0
        $script:csvRun.ResultFile | Should -Not -BeNullOrEmpty
    }

    It 'Writes one row per reference user' {
        $script:csvRun.Rows.Count | Should -Be 5
    }

    It 'Leads with the four standard result columns' {
        @($script:csvRun.Rows[0].PSObject.Properties.Name)[0..3] |
            Should -Be @('Identity', 'Action', 'Status', 'Detail')
    }

    It 'Resolves aliased headers on both sides (UPN/PrimaryEmail vs UserPrincipalName/Mail)' {
        # Neither CSV uses the canonical header names; if Import-MigrationCsv did not
        # resolve them the Source_/Target_ columns would all be blank.
        $row = $script:csvRun.Rows | Where-Object Identity -EQ 'ada.lovelace@contoso.com'
        $row.Source_Email | Should -Be 'ada.lovelace@contoso.com'
        $row.Target_Email | Should -Be 'ada.lovelace@newco.onmicrosoft.com'
    }

    It 'Calls an identical UPN an exact match' {
        $row = $script:csvRun.Rows | Where-Object Identity -EQ 'ada.lovelace@contoso.com'
        $row.Status | Should -Be 'Exact Match'
        $row.MatchedOn | Should -Match 'UPN'
        $row.Target_UPN | Should -Be 'ada.lovelace@contoso.com'
    }

    It 'Calls an identical primary address an exact match even when the UPN changed' {
        $row = $script:csvRun.Rows | Where-Object Identity -EQ 'grace.hopper@contoso.com'
        $row.Status | Should -Be 'Exact Match'
        $row.MatchedOn | Should -Match 'Email'
        $row.Target_UPN | Should -Be 'grace.hopper@newco.onmicrosoft.com'
    }

    It 'Falls back to name and local-part evidence for a partial match' {
        $row = $script:csvRun.Rows | Where-Object Identity -EQ 'alan.turing@contoso.com'
        $row.Status | Should -Be 'Partial Match'
        $row.MatchedOn | Should -Match 'FirstName\+LastName'
        $row.MatchedOn | Should -Match 'EmailLocalPart'
    }

    It 'Uses Levenshtein similarity to match a misspelt display name' {
        $row = $script:csvRun.Rows | Where-Object Identity -EQ 'katherine.johnson@contoso.com'
        $row.Status | Should -Be 'Partial Match'
        $row.MatchedOn | Should -Match '^SimilarName\(0\.94'
        $row.Target_UPN | Should -Be 'kj@newco.onmicrosoft.com'
    }

    It 'Reports a user with no counterpart as No Match' {
        $row = $script:csvRun.Rows | Where-Object Identity -EQ 'charles.babbage@contoso.com'
        $row.Status | Should -Be 'No Match'
        $row.MatchedOn | Should -BeNullOrEmpty
        $row.Target_UPN | Should -BeNullOrEmpty
    }

    It 'Drops the fuzzy match when the threshold is raised above its score' {
        $strict = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-SimilarityThreshold', '0.99'
        ) -ResultPattern 'Compare-UserData-Results_*.csv'

        $row = $strict.Rows | Where-Object Identity -EQ 'katherine.johnson@contoso.com'
        $row.Status | Should -Be 'No Match'
    }

    It 'Honours an explicit column override' {
        # 'Display Name' is an alias Import-MigrationCsv folds into DisplayName, so
        # naming it explicitly must still resolve to the same column.
        $overridden = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-DisplayNameColumn', 'DisplayName'
        ) -ResultPattern 'Compare-UserData-Results_*.csv'

        $row = $overridden.Rows | Where-Object Identity -EQ 'katherine.johnson@contoso.com'
        $row.Source_DisplayName | Should -Be 'Katherine Johnson'
    }
}

Describe 'Compare-MigrationUserData - plan mode' {

    BeforeAll {
        $script:planRun = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:destinationCsv
        ) -ResultPattern 'Compare-UserData-Plan-Results_*.csv'
    }

    It 'Exits 0 and writes a plan results CSV' {
        $script:planRun.ExitCode | Should -Be 0
        $script:planRun.ResultFile | Should -Not -BeNullOrEmpty
    }

    It 'Reports one row per plan row plus one per unclaimed destination object' {
        # 6 plan rows + 1 destination object no plan row points at.
        $script:planRun.Rows.Count | Should -Be 7
    }

    It 'Marks an exact UPN + primary SMTP agreement as Match' {
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'ada.lovelace@newco.onmicrosoft.com'
        $row.Status | Should -Be 'Match'
        $row.DestinationPrimarySmtp | Should -Be 'ada.lovelace@newco.onmicrosoft.com'
    }

    It 'Marks a wrong primary SMTP as Mismatch and names both addresses' {
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'grace.hopper@newco.onmicrosoft.com'
        $row.Status | Should -Be 'Mismatch'
        $row.Detail | Should -Match 'grace\.hopper@fabrikam\.com'
        $row.Detail | Should -Match 'grace\.hopper@newco\.onmicrosoft\.com'
    }

    It 'Marks a planned UPN held under a different UPN as Mismatch, not Missing' {
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'alan.m.turing@newco.onmicrosoft.com'
        $row.Status | Should -Be 'Mismatch'
        $row.DestinationUserPrincipalName | Should -Be 'alan.turing@newco.onmicrosoft.com'
    }

    It 'Marks an absent target as Missing' {
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'katherine.johnson@newco.onmicrosoft.com'
        $row.Status | Should -Be 'Missing'
        $row.DestinationUserPrincipalName | Should -BeNullOrEmpty
    }

    It 'Marks an unclaimed destination object as Extra' {
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'contractor@newco.onmicrosoft.com'
        $row.Status | Should -Be 'Extra'
        $row.PlanTargetUserPrincipalName | Should -BeNullOrEmpty
    }

    It 'Skips an Excluded plan row and says why' {
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'svc.scanner@contoso.com'
        $row.Status | Should -Be 'Skipped'
        $row.Detail | Should -Match 'Excluded'
    }

    It 'Skips a plan row that has no target UPN yet' {
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'unmapped@contoso.com'
        $row.Status | Should -Be 'Skipped'
        $row.Detail | Should -Match 'no TargetUserPrincipalName'
    }

    It 'Never uses fuzzy matching in plan mode' {
        # The plan mode statuses are a closed set; 'Partial Match' must never appear.
        @($script:planRun.Rows.Status | Sort-Object -Unique) |
            Should -Be @('Extra', 'Match', 'Mismatch', 'Missing', 'Skipped')
    }

    It 'Restricts the plan side with -Wave but still reports every extra' {
        $waved = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:destinationCsv
            '-Wave', '2'
        ) -ResultPattern 'Compare-UserData-Plan-Results_*.csv'

        # Only wave 2's two plan rows are compared: alan (Mismatch) and katherine (Missing).
        @($waved.Rows | Where-Object Status -EQ 'Missing').Count | Should -Be 1
        @($waved.Rows | Where-Object Status -EQ 'Mismatch').Count | Should -Be 1
        @($waved.Rows | Where-Object PlanTargetUserPrincipalName -EQ 'ada.lovelace@newco.onmicrosoft.com').Count |
            Should -Be 0
        # Wave 1's destination objects are no longer claimed by any compared plan row,
        # so they surface as Extra - a -Wave run reports on the whole destination CSV.
        ($waved.Rows | Where-Object Identity -EQ 'ada.lovelace@newco.onmicrosoft.com').Status | Should -Be 'Extra'
        @($waved.Rows | Where-Object Status -EQ 'Extra').Count | Should -Be 3
    }
}

Describe 'Compare-MigrationUserData - DryRun' {

    It 'Writes a DryRun file with a single Planned row in CSV mode' {
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-DryRun'
        ) -ResultPattern 'Compare-UserData-DryRun_*.csv'

        $run.ExitCode | Should -Be 0
        $run.ResultFile | Should -Not -BeNullOrEmpty
        $run.Rows.Count | Should -Be 1
        $run.Rows[0].Status | Should -Be 'Planned'
        $run.Rows[0].Detail | Should -Match 'Would compare 5 reference row\(s\) against 5 difference row\(s\)'
    }

    It 'Writes a DryRun file with a single Planned row in plan mode' {
        $run = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:destinationCsv
            '-DryRun'
        ) -ResultPattern 'Compare-UserData-Plan-DryRun_*.csv'

        $run.ExitCode | Should -Be 0
        $run.Rows.Count | Should -Be 1
        $run.Rows[0].Status | Should -Be 'Planned'
        $run.Rows[0].Detail | Should -Match 'Would compare 6 plan row\(s\) against 4 destination row\(s\)'
    }

    It 'Writes no comparison results file when DryRun is set' {
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-DryRun'
        ) -ResultPattern 'Compare-UserData-DryRun_*.csv'

        @(Get-ChildItem -LiteralPath $run.OutputDirectory -Filter 'Compare-UserData-Results_*.csv').Count |
            Should -Be 0
    }
}

Describe 'Compare-MigrationUserData - failure handling' {

    It 'Exits 1 with an actionable message when an input CSV is missing' {
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', (Join-Path $script:fixtures 'DoesNotExist.csv')
            '-DifferenceCsv', $script:targetCsv
        ) -ResultPattern 'Compare-UserData-Results_*.csv'

        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'CSV file not found'
    }
}
