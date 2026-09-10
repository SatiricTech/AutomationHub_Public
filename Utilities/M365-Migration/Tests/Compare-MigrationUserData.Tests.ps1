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
    $script:sharedMailboxesCsv = Join-Path $script:fixtures 'Destination-SharedMailboxes.csv'
    $script:groupsCsv = Join-Path $script:fixtures 'Destination-Groups.csv'
    $script:noEmailCsv = Join-Path $script:fixtures 'Destination-NoEmail.csv'
    $script:noIdentityCsv = Join-Path $script:fixtures 'Source-NoIdentity.csv'
    $script:sourceLookalikeCsv = Join-Path $script:fixtures 'Source-Lookalike.csv'
    $script:targetLookalikeCsv = Join-Path $script:fixtures 'Target-Lookalike.csv'

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

    It 'Does not add SimilarName on top of an identical DisplayName' {
        # Identical names already score as DisplayName; the Levenshtein pass is for
        # names that differ. Its 1.0 score used to be appended as noise.
        $row = $script:csvRun.Rows | Where-Object Identity -EQ 'alan.turing@contoso.com'
        $row.MatchedOn | Should -Match 'DisplayName'
        $row.MatchedOn | Should -Not -Match 'SimilarName'
        [int]$row.MatchScore | Should -Be 105
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

    It 'Prefers an exact UPN hit over a look-alike that scores higher on name evidence' {
        # The fabrikam look-alike scores 105 (DisplayName + FirstName+LastName +
        # EmailLocalPart); the renamed exact counterpart scores only 100 on UPN.
        # Exactness must outrank the score or the row pairs with the wrong object.
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceLookalikeCsv
            '-DifferenceCsv', $script:targetLookalikeCsv
        ) -ResultPattern 'Compare-UserData-Results_*.csv'

        $run.Rows.Count | Should -Be 1
        $run.Rows[0].Status | Should -Be 'Exact Match'
        $run.Rows[0].MatchedOn | Should -Be 'UPN'
        $run.Rows[0].Target_UPN | Should -Be 'margaret.hamilton@contoso.com'
        [int]$run.Rows[0].MatchScore | Should -Be 100
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

    It 'Accepts an override naming the raw header that alias resolution folded away' {
        # Source-Users.csv's header is 'UPN', which Import-MigrationCsv renames to
        # UserPrincipalName. Naming the header the operator can see must be honoured
        # with an INFO line, not warned about as absent.
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-UpnColumn', 'UPN'
            '-Verbosity', 'High'
        ) -ResultPattern 'Compare-UserData-Results_*.csv'

        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match "Override column 'UPN' in the reference CSV was imported as 'UserPrincipalName'"
        $run.Output | Should -Not -Match "Override column 'UPN' is not a header of the reference CSV"
        ($run.Rows | Where-Object Identity -EQ 'ada.lovelace@contoso.com').Source_UPN |
            Should -Be 'ada.lovelace@contoso.com'
    }

    It 'Still warns when an override names a header the file never had' {
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-UpnColumn', 'LoginName'
        ) -ResultPattern 'Compare-UserData-Results_*.csv'

        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match "Override column 'LoginName' is not a header of the reference CSV"
    }

    It 'Exits 1 when a side has neither a UPN nor an email column' {
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:noIdentityCsv
            '-DifferenceCsv', $script:targetCsv
        ) -ResultPattern 'Compare-UserData-Results_*.csv'

        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'neither a UserPrincipalName nor a PrimarySmtpAddress column'
        $run.ResultFile | Should -BeNullOrEmpty
    }
}

Describe 'Compare-MigrationUserData - plan mode' {

    BeforeAll {
        $script:planRun = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:destinationCsv
        ) -ResultPattern 'Compare-UserData-Plan-Results_*.csv'
    }

    It 'Writes a plan results CSV and exits 2 because the comparison is not clean' {
        # The fixture deliberately holds Mismatch and Missing rows; a pipeline has to
        # see that in the exit code, not only in the CSV.
        $script:planRun.ResultFile | Should -Not -BeNullOrEmpty
        $script:planRun.ExitCode | Should -Be 2
        $script:planRun.Output | Should -Match 'Comparison is not clean: \d+ Missing and \d+ Mismatch'
    }

    It 'Reports one row per plan row plus one per unclaimed destination object' {
        # 9 plan rows + 1 destination object no plan row points at. The three
        # recipient rows (Shared, Room, Distribution) report Missing here because a
        # Users inventory does not hold them - they are checked against their own
        # inventory files below.
        $script:planRun.Rows.Count | Should -Be 10
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

    It 'Skips a plan row that has neither a target UPN nor a target SMTP yet' {
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'unmapped@contoso.com'
        $row.Status | Should -Be 'Skipped'
        $row.Detail | Should -Match 'no TargetUserPrincipalName or TargetPrimarySmtp'
    }

    It 'Identifies a recipient row by its planned address and carries its source address' {
        # A shared mailbox has no target UPN, so its Identity is the planned SMTP and
        # the SourcePrimarySmtp column keeps the row recognisable.
        $row = $script:planRun.Rows | Where-Object Identity -EQ 'accounts@newco.onmicrosoft.com'
        $row | Should -Not -BeNullOrEmpty
        $row.ObjectType | Should -Be 'Shared'
        $row.PlanTargetUserPrincipalName | Should -BeNullOrEmpty
        $row.SourcePrimarySmtp | Should -Be 'accounts@contoso.com'
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

    It 'Exits 1 when the destination inventory has no primary SMTP column' {
        # A Match that never checked the address would be hollow, so this is fatal
        # rather than a file full of Mismatch rows.
        $run = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:noEmailCsv
        ) -ResultPattern 'Compare-UserData-Plan-Results_*.csv'

        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'no PrimarySmtpAddress column'
        $run.ResultFile | Should -BeNullOrEmpty
    }
}

Describe 'Compare-MigrationUserData - plan mode, recipient classes' {

    # pwsh -File hands '-ObjectType Shared,Room' over as one literal string, so each
    # run below narrows to a single class; together they cover the SMTP-only paths.

    It 'Matches a shared mailbox on primary SMTP alone against the SharedMailboxes inventory' {
        $run = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:sharedMailboxesCsv
            '-ObjectType', 'Shared'
        ) -ResultPattern 'Compare-UserData-Plan-Results_*.csv'

        # 1 Shared plan row + the equipment mailbox nothing claims.
        $run.Rows.Count | Should -Be 2

        $shared = $run.Rows | Where-Object Identity -EQ 'accounts@newco.onmicrosoft.com'
        $shared.Status | Should -Be 'Match'
        $shared.Detail | Should -Match 'no target UPN'
        $shared.DestinationPrimarySmtp | Should -Be 'accounts@newco.onmicrosoft.com'
        $shared.DestinationUserPrincipalName | Should -Be 'accounts@newco.onmicrosoft.com'

        # The equipment mailbox is in the inventory but not in the compared object
        # type, so it surfaces as Extra - the same rule -Wave follows.
        ($run.Rows | Where-Object Identity -EQ 'projector@newco.onmicrosoft.com').Status | Should -Be 'Extra'

        # Nothing is Missing or Mismatch, so the run is clean.
        $run.ExitCode | Should -Be 0
    }

    It 'Reports a room whose planned address is absent as Missing and exits 2' {
        $run = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:sharedMailboxesCsv
            '-ObjectType', 'Room'
        ) -ResultPattern 'Compare-UserData-Plan-Results_*.csv'

        $room = $run.Rows | Where-Object Identity -EQ 'boardroom@newco.onmicrosoft.com'
        $room.Status | Should -Be 'Missing'
        $room.Detail | Should -Match "planned primary SMTP 'boardroom@newco\.onmicrosoft\.com'"
        $room.PlanTargetUserPrincipalName | Should -BeNullOrEmpty

        @($run.Rows | Where-Object Status -EQ 'Extra').Count | Should -Be 2
        $run.ExitCode | Should -Be 2
        $run.Output | Should -Match 'Comparison is not clean: 1 Missing and 0 Mismatch'
    }

    It 'Compares a distribution group against a Groups inventory that has no UPN column and exits 0 when clean' {
        $run = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:groupsCsv
            '-ObjectType', 'Distribution'
        ) -ResultPattern 'Compare-UserData-Plan-Results_*.csv'

        $run.ExitCode | Should -Be 0
        $run.Rows.Count | Should -Be 1
        $run.Rows[0].Identity | Should -Be 'allstaff@newco.onmicrosoft.com'
        $run.Rows[0].Status | Should -Be 'Match'
        $run.Output | Should -Not -Match 'Comparison is not clean'
    }

    It 'Exits 1 when user rows are compared against an inventory with no UPN column' {
        $run = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:groupsCsv
            '-ObjectType', 'User'
        ) -ResultPattern 'Compare-UserData-Plan-Results_*.csv'

        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'no UserPrincipalName column'
        $run.Output | Should -Match 'carry a TargetUserPrincipalName'
    }
}

Describe 'Compare-MigrationUserData - DryRun' {

    It 'Runs the full comparison and files it as a DryRun file in CSV mode' {
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-DryRun'
        ) -ResultPattern 'Compare-UserData-DryRun_*.csv'

        $run.ExitCode | Should -Be 0
        $run.ResultFile | Should -Not -BeNullOrEmpty
        $run.Rows.Count | Should -Be 5
        ($run.Rows | Where-Object Identity -EQ 'ada.lovelace@contoso.com').Status | Should -Be 'Exact Match'
        ($run.Rows | Where-Object Identity -EQ 'charles.babbage@contoso.com').Status | Should -Be 'No Match'
    }

    It 'Runs the full comparison, keeps the real statuses and the exit code in plan mode' {
        $run = Invoke-CompareScript -Arguments @(
            '-PlanPath', $script:planCsv
            '-DifferenceCsv', $script:destinationCsv
            '-DryRun'
        ) -ResultPattern 'Compare-UserData-Plan-DryRun_*.csv'

        $run.ResultFile | Should -Not -BeNullOrEmpty
        $run.Rows.Count | Should -Be 10
        @($run.Rows.Status | Sort-Object -Unique) | Should -Be @('Extra', 'Match', 'Mismatch', 'Missing', 'Skipped')
        $run.Rows.Status | Should -Not -Contain 'Planned'
        $run.ExitCode | Should -Be 2
    }

    It 'Writes no -Results_ file when DryRun is set' {
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-DryRun'
        ) -ResultPattern 'Compare-UserData-DryRun_*.csv'

        @(Get-ChildItem -LiteralPath $run.OutputDirectory -Filter 'Compare-UserData-Results_*.csv').Count |
            Should -Be 0
    }
}

Describe 'Compare-MigrationUserData - run plumbing' {

    It 'Honours -LogPath' {
        $logPath = Join-Path $script:workspace "custom-$([guid]::NewGuid().ToString('N')).log"
        $run = Invoke-CompareScript -Arguments @(
            '-ReferenceCsv', $script:sourceCsv
            '-DifferenceCsv', $script:targetCsv
            '-LogPath', $logPath
        ) -ResultPattern 'Compare-UserData-Results_*.csv'

        $run.ExitCode | Should -Be 0
        Test-Path -LiteralPath $logPath | Should -BeTrue
        Get-Content -LiteralPath $logPath -Raw | Should -Match 'Started Compare-MigrationUserData'
        @(Get-ChildItem -LiteralPath $run.OutputDirectory -Filter '*.log').Count | Should -Be 0
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
