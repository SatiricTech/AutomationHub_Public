#Requires -Version 7.4

<#
    Task 9 of the workbench: the console's two seams.

    Format-MigrationWorkbenchView turns a workspace scan into the lines of Docs/Workbench-
    Design.md section 8 - header, tenant banner, plan line, phase blocks with state glyphs,
    warnings and the footer keys - as data, so the rendering can be asserted without a console.

    Read-MigrationPrompt is the single prompt seam every console question goes through, and
    Set-MigrationPromptHandler is what lets the Pester suite answer those questions with a
    scripted queue on macOS. The queue throws when it runs dry, so a loop that asks one
    question too many fails the test rather than hanging the run.

    The committed fixture (Tests/Fixtures/Workbench/Workspace1) is a migration caught
    mid-flight: source and destination inventoried, the plan written at 10:15, provisioning
    rehearsed at 10:31 and licences half-assigned at 11:00.
#>

BeforeAll {
    # Match the scripts, which run under Set-StrictMode -Version Latest.
    Set-StrictMode -Version Latest

    Import-Module (Join-Path $PSScriptRoot '..' 'M365Migration' 'M365Migration.psd1') -Force

    $script:FixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot 'Fixtures' 'Workbench' 'Workspace1')).Path
    $script:ToolkitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    # One rendering of each view, shared by every assertion below: the scan and the help
    # lookups behind the tools view are the slowest thing in this file.
    $script:Workspace = Get-MigrationWorkspace -Path $script:FixtureRoot
    $script:PhaseLines = @(InModuleScope M365Migration -Parameters @{ Workspace = $script:Workspace } {
            param($Workspace)
            Format-MigrationWorkbenchView -Workspace $Workspace -Version '1.0.0'
        })
    $script:ToolLines = @(InModuleScope M365Migration -Parameters @{ Workspace = $script:Workspace } {
            param($Workspace)
            Format-MigrationWorkbenchView -Workspace $Workspace -View 'Tools' -Version '1.0.0'
        })
    $script:ResultLines = @(InModuleScope M365Migration -Parameters @{ Workspace = $script:Workspace } {
            param($Workspace)
            Format-MigrationWorkbenchView -Workspace $Workspace -View 'Results' -Version '1.0.0'
        })

    # The line for one step, found by its title rather than by index, so a step added to the
    # catalogue ahead of it does not silently move the assertion onto another row.
    function Get-StepLine {
        param([string[]]$Line, [string]$Title)
        $matched = @($Line | Where-Object { $_ -like "*$Title*" })
        if ($matched.Count -eq 0) { return '' }
        return $matched[0]
    }
}

Describe 'Format-MigrationWorkbenchView' {

    Context 'the header block' {

        It 'names the workbench, its version, the workspace and the scenario' {
            $script:PhaseLines[0] | Should -BeLike 'M365 Migration Workbench 1.0.0 *'
            $script:PhaseLines[0] | Should -BeLike "*$($script:FixtureRoot)*"
            $script:PhaseLines[0] | Should -BeLike '*TenantToTenant*'
        }

        It 'carries the label and both tenants, with the GUIDs shortened' {
            $script:PhaseLines[1] | Should -BeLike 'Contoso *'
            $script:PhaseLines[1] | Should -BeLike '*SOURCE*contoso.onmicrosoft.com*'
            $script:PhaseLines[1] | Should -BeLike '*DESTINATION*newco.onmicrosoft.com*'
            # First eight characters and an ellipsis - never the whole GUID.
            $script:PhaseLines[1] | Should -BeLike '*00000000-…*'
            $script:PhaseLines[1] | Should -Not -BeLike '*00000000-0000-0000-0000-000000000000*'
        }

        It 'states the plan, whether it is pinned, its rows, its waves and its non-planned statuses' {
            $planLine = Get-StepLine -Line $script:PhaseLines -Title 'Plan:'
            $planLine | Should -BeLike '*Contoso_IdentityPlan_20260918-101500.csv (newest)*'
            $planLine | Should -BeLike '*3 rows*'
            $planLine | Should -BeLike '*waves 1, 2*'
            $planLine | Should -BeLike '*1 Collision*'
            # Planned is the norm and is left out; only what needs attention is listed.
            $planLine | Should -Not -BeLike '*Planned*'
        }

        It 'says so plainly when the workspace holds no plan' {
            $empty = Join-Path $TestDrive 'NoPlan'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            $scan = Get-MigrationWorkspace -Path $empty
            $lines = @(InModuleScope M365Migration -Parameters @{ Workspace = $scan } {
                    param($Workspace)
                    Format-MigrationWorkbenchView -Workspace $Workspace -Version '1.0.0'
                })
            ($lines -join "`n") | Should -BeLike '*Plan: none yet*'
        }
    }

    Context 'the phase view' {

        It 'marks a completed step [x] and dates it from the file it left behind' {
            $line = Get-StepLine -Line $script:PhaseLines -Title 'Inventory - source tenant'
            $line | Should -Match '^\s+\[x\]\s'
            $line | Should -BeLike '*17 Sep 09:12*'
        }

        It 'marks a rehearsed step [~] and says what the rehearsal planned' {
            $line = Get-StepLine -Line $script:PhaseLines -Title 'Provision users'
            $line | Should -Match '^\s+\[~\]\s'
            $line | Should -BeLike '*dry run 18 Sep 10:31: 2 Planned, 1 Skipped*'
        }

        It 'marks a step with failed rows [!] and counts them' {
            $line = Get-StepLine -Line $script:PhaseLines -Title 'Assign licences'
            $line | Should -Match '^\s+\[!\]\s'
            $line | Should -BeLike '*18 Sep 11:00: 1 Succeeded, 1 Failed*'
        }

        It 'marks a step that has never run [ ] with no date' {
            $line = Get-StepLine -Line $script:PhaseLines -Title 'Create mail recipients'
            $line | Should -Match '^\s+\[ \]\s'
            $line | Should -Not -Match '\d\d:\d\d'
        }

        It 'points at the next step, and at that step only' {
            $marked = @($script:PhaseLines | Where-Object { $_ -like '*<- next*' })
            $marked.Count | Should -Be 1
            $marked[0] | Should -BeLike '*Provision users*'
        }

        It 'numbers the steps from 1 in the order the runbook runs them' {
            $numbered = @($script:PhaseLines | Where-Object { $_ -match '^\s{2}\[.\]\s+\d+\s' })
            $numbered.Count | Should -Be @($script:Workspace.Steps).Count
            $numbered[0] | Should -BeLike '*Inventory - source tenant*'
            # Step 6 is the one the console's own test drives.
            $numbered[5] | Should -BeLike '*Provision users*'
        }

        It 'heads each block with its phase, in runbook order' {
            $phases = @($script:PhaseLines | Where-Object { $_ -in @('Discover', 'Plan', 'Prepare', 'Cutover') })
            $phases | Should -Be @('Discover', 'Plan', 'Prepare', 'Cutover')
        }

        It 'ends with the keys the console accepts' {
            $script:PhaseLines[-1] | Should -Match '\[A\] all tools'
            $script:PhaseLines[-1] | Should -Match '\[S\] settings'
            $script:PhaseLines[-1] | Should -Match '\[R\] results'
            $script:PhaseLines[-1] | Should -Match '\[Q\] quit'
        }

        It 'renders every state glyph the scanner can produce' {
            # The fixture cannot hold all seven states at once, so the states the scanner can
            # return are fed through a scan-shaped object instead. The mapping is what the
            # operator reads the board by, so every branch of it is asserted.
            $states = @('NotRun', 'DryRun', 'Done', 'PartlyFailed', 'WorkRemains', 'Failed', 'Stale')
            $steps = @(Get-MigrationStep -Scenario 'TenantToTenant')
            $stepStates = @(for ($i = 0; $i -lt $steps.Count; $i++) {
                    [pscustomobject]@{
                        Id             = $steps[$i].Id
                        State          = $states[$i % $states.Count]
                        LastRun        = $null
                        LastDryRun     = $null
                        Files          = @()
                        Summary        = [pscustomobject]@{ Succeeded = 0; Failed = 0; Skipped = 0; Planned = 0 }
                        ExitCode       = $null
                        TenantVerified = $null
                    }
                })
            $scan = [pscustomobject]@{
                Path = $TestDrive; SettingsPath = ''; SettingsResult = $null; Settings = $null
                Label = 'Contoso'; Scenario = 'TenantToTenant'; Folders = [ordered]@{}; Artefacts = @()
                Plan = $null; Steps = $stepStates; Ledger = @(); NextStepId = $null; Warnings = @()
            }
            $lines = @(InModuleScope M365Migration -Parameters @{ Workspace = $scan } {
                    param($Workspace)
                    Format-MigrationWorkbenchView -Workspace $Workspace -Version '1.0.0'
                })

            $rendered = @($lines | Where-Object { $_ -match '^\s{2}(\[.\])\s+\d+\s' } |
                    ForEach-Object { $Matches[1] })
            $expected = @('[ ]', '[~]', '[x]', '[!]', '[?]', '[!]', '[s]')
            @($rendered | Select-Object -First 7) | Should -Be $expected
        }

        It 'dates the run its counts came from, not the newest file the step left behind' {
            <#
                A live run at 11:00 and a rehearsal at 12:00 that failed. The scanner's state
                and its counts are about the 12:00 rehearsal; dating that line from the newest
                non-rehearsal artefact would put the rehearsal's counts on the live run's
                timestamp, with nothing to say a rehearsal was involved at all.
            #>
            $path = Join-Path $TestDrive 'LaterRehearsal'
            Copy-Item -LiteralPath $script:FixtureRoot -Destination $path -Recurse -Force
            $folder = Join-Path $path 'Contoso'
            Set-Content -LiteralPath (Join-Path $folder 'Contoso_Set-Licenses-DryRun_20260918-120000.csv') `
                -Value @(
                '"Identity","Action","Status","Detail"'
                '"ada.lovelace@newco.com","Set-Licence","Failed","The SKU has no seats left"'
            ) -Encoding utf8
            Add-Content -LiteralPath (Join-Path $path 'Workbench' 'Runs.jsonl') -Encoding utf8 -Value (
                [ordered]@{
                    Started = '2026-09-18T12:00:00'; Ended = '2026-09-18T12:00:30'; StepId = 'Set-Licenses'
                    Script = 'Set-MigrationLicenses'; Side = 'Destination'; DryRun = $true; Wave = @()
                    ExitCode = 2; Meaning = 'Some rows failed'; Aborted = $false; Files = @()
                } | ConvertTo-Json -Depth 6 -Compress)

            $scan = Get-MigrationWorkspace -Path $path
            $state = @($scan.Steps | Where-Object { $_.Id -eq 'Set-Licenses' })[0]
            $state.StateSource | Should -BeExactly 'Artefact'
            $state.StateDryRun | Should -BeTrue
            $state.StateRun.Timestamp | Should -Be ([datetime]'2026-09-18T12:00:00')

            $lines = @(InModuleScope M365Migration -Parameters @{ Workspace = $scan } {
                    param($Workspace)
                    Format-MigrationWorkbenchView -Workspace $Workspace -Version '1.0.0'
                })
            $line = Get-StepLine -Line $lines -Title 'Assign licences'
            $line | Should -BeLike '*dry run 18 Sep 12:00: 1 Failed*'
            $line | Should -Not -BeLike '*11:00*'
        }

        It 'dates a run that left nothing behind from the ledger entry that recorded it' {
            $path = Join-Path $TestDrive 'LedgerOnly'
            Copy-Item -LiteralPath $script:FixtureRoot -Destination $path -Recurse -Force
            Add-Content -LiteralPath (Join-Path $path 'Workbench' 'Runs.jsonl') -Encoding utf8 -Value (
                [ordered]@{
                    Started = '2026-09-18T13:45:00'; Ended = '2026-09-18T13:45:10'
                    StepId = 'New-Recipients'; Script = 'New-MigrationRecipients'; Side = 'Destination'
                    DryRun = $false; Wave = @(); ExitCode = 1; Meaning = 'Failed'; Aborted = $false
                    Files = @(); Summary = @{ Succeeded = 0; Failed = 4; Skipped = 0; Planned = 0 }
                } | ConvertTo-Json -Depth 6 -Compress)

            $scan = Get-MigrationWorkspace -Path $path
            $state = @($scan.Steps | Where-Object { $_.Id -eq 'New-Recipients' })[0]
            $state.StateSource | Should -BeExactly 'Ledger'

            $lines = @(InModuleScope M365Migration -Parameters @{ Workspace = $scan } {
                    param($Workspace)
                    Format-MigrationWorkbenchView -Workspace $Workspace -Version '1.0.0'
                })
            $line = Get-StepLine -Line $lines -Title 'Create mail recipients'
            $line | Should -Match '^\s+\[!\]\s'
            $line | Should -BeLike '*18 Sep 13:45: 4 Failed*'
        }

        It 'says a step has never run when nothing on disk or in the ledger mentions it' {
            $state = @($script:Workspace.Steps | Where-Object { $_.Id -eq 'New-Recipients' })[0]
            $state.StateSource | Should -BeExactly 'None'
            $state.StateRun | Should -BeNullOrEmpty
        }

        It 'lists the scan warnings under their own heading' {
            $damaged = Join-Path $TestDrive 'Damaged'
            Copy-Item -LiteralPath $script:FixtureRoot -Destination $damaged -Recurse -Force
            Set-Content -LiteralPath (Join-Path $damaged 'Contoso' 'Contoso_Set-Licenses-Results_20260918-110000.csv') `
                -Value '"Identity","Action","Status","Detail"' -Encoding utf8
            $scan = Get-MigrationWorkspace -Path $damaged
            $lines = @(InModuleScope M365Migration -Parameters @{ Workspace = $scan } {
                    param($Workspace)
                    Format-MigrationWorkbenchView -Workspace $Workspace -Version '1.0.0'
                })
            ($lines -join "`n") | Should -BeLike '*Warnings:*header and no rows*'
        }
    }

    Context 'the tools view' {

        It 'lists all seventeen scripts, numbered, one line each' {
            $rows = @($script:ToolLines | Where-Object { $_ -match '^\s+\d+\s+\S+\.ps1' })
            $rows.Count | Should -Be 17
            $rows[0] | Should -BeLike '*1*Compare-MigrationUserData.ps1*'
        }

        It 'puts each script''s own synopsis beside it' {
            $row = @($script:ToolLines | Where-Object { $_ -like '*New-MigrationUsers.ps1*' })[0]
            $synopsis = (Get-Help -Name (Join-Path $script:ToolkitRoot 'New-MigrationUsers.ps1')).Synopsis
            # Flattened to one line, because a synopsis carries the source file's own wrapping.
            $flat = ($synopsis -replace '\s+', ' ').Trim()
            $row | Should -BeLike ('*' + $flat.Substring(0, 40) + '*')
        }

        It 'offers the way back to the phase view' {
            $script:ToolLines[-1] | Should -Match '\[P\] phases'
        }
    }

    Context 'the results view' {

        It 'lists the ledger newest first, with the exit code, its meaning and the tenant check' {
            $rows = @($script:ResultLines | Where-Object { $_ -match '^\d\d \w\w\w \d\d:\d\d\s' })
            $rows.Count | Should -Be 2
            $rows[0] | Should -BeLike '18 Sep 11:00*Set-Licenses*exit 2*Some rows failed*tenant ✓*'
            $rows[1] | Should -BeLike '18 Sep 10:20*Readiness-Pre*exit 0*Completed*'
        }

        It 'names the run folder under each entry' {
            ($script:ResultLines -join "`n") | Should -BeLike '*Workbench/Runs/20260918-110000_Set-Licenses*'
        }

        It 'renders the ledger the scan already read, not a second read of the file' {
            # The board and this screen must describe the same moment: a screen that re-read
            # the file could show a run the board it was drawn beside knows nothing about.
            $path = Join-Path $TestDrive 'LedgerFromScan'
            Copy-Item -LiteralPath $script:FixtureRoot -Destination $path -Recurse -Force
            $scan = Get-MigrationWorkspace -Path $path
            Remove-Item -LiteralPath (Join-Path $path 'Workbench' 'Runs.jsonl') -Force

            $lines = @(InModuleScope M365Migration -Parameters @{ Workspace = $scan } {
                    param($Workspace)
                    Format-MigrationWorkbenchView -Workspace $Workspace -View 'Results' -Version '1.0.0'
                })
            ($lines -join "`n") | Should -BeLike '*Set-Licenses*exit 2*'
        }

        It 'says so when the workspace has no runs on record' {
            $empty = Join-Path $TestDrive 'NoRuns'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            $scan = Get-MigrationWorkspace -Path $empty
            $lines = @(InModuleScope M365Migration -Parameters @{ Workspace = $scan } {
                    param($Workspace)
                    Format-MigrationWorkbenchView -Workspace $Workspace -View 'Results' -Version '1.0.0'
                })
            ($lines -join "`n") | Should -BeLike '*No runs recorded yet*'
        }
    }
}

Describe 'The prompt seam' {

    AfterEach {
        # A handler left behind would answer the next test's questions.
        Set-MigrationPromptHandler
    }

    It 'returns the scripted answers in order' {
        $asked = [System.Collections.Generic.List[string]]::new()
        $queue = [System.Collections.Generic.Queue[string]]::new([string[]]@('first', 'second'))
        # Only the two arguments this handler reads are declared; the seam passes four
        # positionally and PowerShell puts the rest in $args, which is what lets a scripted
        # handler stay as short as the answers it gives.
        Set-MigrationPromptHandler -Handler {
            param($Kind, $Message)
            $asked.Add("$Kind|$Message")
            if ($queue.Count -eq 0) { throw 'The scripted answers ran out.' }
            return $queue.Dequeue()
        }

        InModuleScope M365Migration {
            Read-MigrationPrompt -Kind 'Text' -Message 'One' | Should -BeExactly 'first'
            Read-MigrationPrompt -Kind 'Text' -Message 'Two' | Should -BeExactly 'second'
        }
        $asked | Should -Be @('Text|One', 'Text|Two')
    }

    It 'throws rather than hanging when a loop asks one question too many' {
        Set-MigrationPromptHandler -Handler { throw 'The scripted answers ran out.' }
        { InModuleScope M365Migration { Read-MigrationPrompt -Kind 'Text' -Message 'One' } } |
            Should -Throw '*ran out*'
    }

    It 'treats an empty text answer as the suggestion' {
        Set-MigrationPromptHandler -Handler { return '' }
        InModuleScope M365Migration {
            Read-MigrationPrompt -Kind 'Text' -Message 'Label' -Default 'Contoso' | Should -BeExactly 'Contoso'
        }
    }

    It 'returns the chosen label for a choice, whatever case it was typed in' {
        Set-MigrationPromptHandler -Handler { return 'inplaceredesign' }
        InModuleScope M365Migration {
            $answer = Read-MigrationPrompt -Kind 'Choice' -Message 'Scenario' `
                -Choices @('TenantToTenant', 'InPlaceRedesign')
            $answer | Should -BeExactly 'InPlaceRedesign'
        }
    }

    It 'turns a confirmation into a boolean' {
        Set-MigrationPromptHandler -Handler { return 'y' }
        InModuleScope M365Migration { Read-MigrationPrompt -Kind 'Confirm' -Message 'Run?' } | Should -BeTrue

        Set-MigrationPromptHandler -Handler { return 'n' }
        InModuleScope M365Migration { Read-MigrationPrompt -Kind 'Confirm' -Message 'Run?' } | Should -BeFalse
    }

    It 'turns a secret into a SecureString the caller never has to convert' {
        Set-MigrationPromptHandler -Handler { return 'not-a-real-secret' }
        $secure = InModuleScope M365Migration { Read-MigrationPrompt -Kind 'Secret' -Message 'Client secret' }
        $secure | Should -BeOfType [System.Security.SecureString]
        $secure.Length | Should -Be 17
    }

    It 'hands the handler the kind, the message, the choices and the suggestion' {
        # A list rather than a scalar: the handler runs in this scope (a scriptblock carries
        # its own session state through the '&' the seam invokes it with), so mutating a
        # reference type is how the call is read back without a closure copy.
        $seen = [System.Collections.Generic.List[object]]::new()
        Set-MigrationPromptHandler -Handler {
            param($Kind, $Message, $Choices, $Default)
            $seen.Add([pscustomobject]@{ Kind = $Kind; Message = $Message; Choices = $Choices; Default = $Default })
            return $Default
        }

        InModuleScope M365Migration {
            Read-MigrationPrompt -Kind 'Choice' -Message 'Verbosity' -Choices @('Low', 'Medium', 'High') `
                -Default 'Medium'
        } | Should -BeExactly 'Medium'

        $seen.Count | Should -Be 1
        $seen[0].Kind | Should -BeExactly 'Choice'
        $seen[0].Message | Should -BeExactly 'Verbosity'
        $seen[0].Choices | Should -Be @('Low', 'Medium', 'High')
        $seen[0].Default | Should -BeExactly 'Medium'
    }

    It 'restores the default handler when it is set to nothing' {
        Set-MigrationPromptHandler -Handler { return 'scripted' }
        InModuleScope M365Migration { $null -ne $script:MigrationPromptHandler } | Should -BeTrue
        Set-MigrationPromptHandler
        InModuleScope M365Migration { $null -eq $script:MigrationPromptHandler } | Should -BeTrue
    }
}
