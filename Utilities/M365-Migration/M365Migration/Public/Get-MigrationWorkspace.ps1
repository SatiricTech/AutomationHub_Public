function Get-MigrationWorkspace {
    <#
    .SYNOPSIS
        Scans a migration workspace folder and reports what has already happened in it.

    .DESCRIPTION
        The workbench never asks the operator where things are: it reads the folder. This is
        that read (Docs/Workbench-Design.md, sections 3 and 6). It loads the settings file,
        works out the label folder, parses every filename that follows the toolkit's output
        contract, picks the identity plan, reads the run ledger, and derives one detected
        state per step instance of the workspace's scenario - plus the step the operator
        should do next.

        It never throws on a folder someone has been working in by hand. A missing folder, a
        broken settings file, a plan that is not a plan, a results file with a header and no
        rows, a half-written ledger line: each becomes a line in Warnings and the scan
        carries on. Files that do not match the naming contract are skipped in silence,
        because notes, exports and screenshots living beside the artefacts are normal.

        How a file is matched to a step instance:

          Results   Suffix 'Results' or 'DryRun', Name one of the step's result tokens, in
                    the folder the instance writes to (its fixed -Prefix, else the label).
          Inventory Prefix equal to the instance's fixed -Prefix and Name 'Users' - the tab
                    that proves the inventory ran.
          Plan      Name 'IdentityPlan' in the label folder.
          Report    Name equal to a 'Report:<name>' the instance produces, taken whole, so
                    'DomainBlockers-Recheck' is one name and not a name plus a suffix.

        Where two instances of one script write the same token into the same folder - the
        three readiness stages, the domain-release report and remediation - the file belongs
        to the instance the ledger says produced it, matched on the file names the run
        recorded or on its start-to-end window. With no ledger to go on it belongs to the
        lowest-ordered instance, which is the catalogue's stated rule for a file copied in or
        a run made from the command line.

        Newest always means the timestamp in the filename, never the file's mtime: sync
        clients rewrite mtimes. Reading a results file reads only its Status column, so the
        GeneratedPassword column a provisioning run writes is never touched.

    .PARAMETER Path
        The workspace folder - the same folder every step is given as -OutputPath.

    .EXAMPLE
        Get-MigrationWorkspace -Path ~/Migration-Automations/Contoso

        Returns the whole scan: settings, folders, artefacts, plan, per-step state and the
        next step to run.

    .EXAMPLE
        (Get-MigrationWorkspace -Path $workspace).Steps | Format-Table Id, State, ExitCode

        Shows the detected state of every step in the runbook.

    .EXAMPLE
        $scan = Get-MigrationWorkspace -Path $workspace
        $scan.Warnings | ForEach-Object { Write-Warning $_ }

        The standard "scan and report what looks wrong" pattern; the scan itself never throws.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    # The newest of a set of ledger entries: by start time, and by position in the file when
    # two runs share one (or when a line carries no readable Started).
    function Select-MigrationNewestEntry {
        param([object[]]$Entry)

        return @($Entry | Sort-Object -Property @{
                Expression = { if ($null -ne $_.Started) { $_.Started } else { [datetime]::MinValue } }
                Descending = $true
            }, @{ Expression = 'LineNumber'; Descending = $true }) | Select-Object -First 1
    }

    # Did this run produce a file stamped at this moment? Filename stamps are whole seconds,
    # so a run that started at .500 would otherwise appear to start after the file it wrote
    # in that same second.
    function Test-MigrationRunWindow {
        param($Entry, [datetime]$Timestamp)

        if ($null -eq $Entry.Started) { return $false }
        $from = $Entry.Started.AddTicks( - ($Entry.Started.Ticks % [timespan]::TicksPerSecond))
        $to = if ($null -ne $Entry.Ended) { $Entry.Ended } else { $from }
        return ($Timestamp -ge $from -and $Timestamp -le $to)
    }

    $warnings = [System.Collections.Generic.List[string]]::new()

    $workspacePath = $Path
    try { $workspacePath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { $workspacePath = $Path }

    $workspaceExists = Test-Path -LiteralPath $workspacePath -PathType Container
    if (-not $workspaceExists) {
        $warnings.Add("The workspace folder '$Path' does not exist; nothing was scanned.")
    }

    # --- settings -------------------------------------------------------------------------

    $settingsPath = Join-Path $workspacePath 'M365Migration.settings.json'
    $settingsResult = Resolve-MigrationSettings -Path $settingsPath
    $settings = $settingsResult.Settings
    if ($settingsResult.Exists -and -not $settingsResult.IsValid) {
        $warnings.Add("The settings file 'M365Migration.settings.json' is not valid: " +
            (@($settingsResult.Errors) -join ' '))
    }

    $label = ''
    $scenario = 'TenantToTenant'
    if ($settings) {
        $label = [string]$settings['Label']
        $scenario = [string]$settings['Scenario']
    }

    # --- folders and artefacts --------------------------------------------------------------

    $reservedPrefixes = @('Source', 'Destination', 'Post')
    $directories = @()
    if ($workspaceExists) {
        # Workbench/ holds the ledger and the per-run driver folders, never artefacts.
        $directories = @(Get-ChildItem -LiteralPath $workspacePath -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'Workbench' })
    }

    $artefacts = [System.Collections.Generic.List[object]]::new()
    foreach ($directory in $directories) {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory.FullName -File -ErrorAction SilentlyContinue)) {
            $parsed = ConvertFrom-MigrationOutputPath -Path $file.FullName
            if (-not $parsed) { continue }
            $artefacts.Add([pscustomobject]@{
                    Path      = $file.FullName
                    Folder    = $directory.Name
                    Prefix    = $parsed.Prefix
                    Name      = $parsed.Name
                    Suffix    = $parsed.Suffix
                    Timestamp = $parsed.Timestamp
                    Extension = $parsed.Extension
                })
        }
    }

    if (-not $label -and $workspaceExists) {
        # No settings to read the label off: the label folder is the one prefix folder that is
        # not an inventory folder and actually holds artefacts. Anything else is a guess, and
        # a guessed label would attribute files to the wrong step.
        $candidates = @($directories | Where-Object {
                $folderName = $_.Name
                $reservedPrefixes -notcontains $folderName -and
                @($artefacts | Where-Object { $_.Folder -eq $folderName }).Count -gt 0
            })

        if ($candidates.Count -eq 1) {
            $label = $candidates[0].Name
        }
        elseif ($candidates.Count -gt 1) {
            $warnings.Add('More than one folder could be the migration label: ' +
                ((@($candidates | ForEach-Object { $_.Name }) | Sort-Object) -join ', ') +
                ". Set 'Label' in M365Migration.settings.json.")
        }
        else {
            $warnings.Add('No label folder was found in the workspace. Run a step, or set ' +
                "'Label' in M365Migration.settings.json.")
        }
    }

    $folders = [ordered]@{ Source = $null; Destination = $null; Post = $null; Label = $null }
    foreach ($directory in $directories) {
        if ($reservedPrefixes -contains $directory.Name) { $folders[$directory.Name] = $directory.FullName }
        if ($label -and $directory.Name -eq $label) { $folders['Label'] = $directory.FullName }
    }

    # --- the plan ---------------------------------------------------------------------------

    $planArtefacts = @()
    if ($label) {
        $planArtefacts = @($artefacts |
                Where-Object { $_.Folder -eq $label -and $_.Name -eq 'IdentityPlan' -and $_.Suffix -eq '' } |
                Sort-Object -Property Timestamp -Descending)
    }

    $planPath = $null
    $planPinned = $false
    $pinnedSetting = if ($settings) { [string]$settings['Pinned']['PlanPath'] } else { '' }

    if ($pinnedSetting) {
        $pinnedCandidate = $pinnedSetting
        if (-not [System.IO.Path]::IsPathRooted($pinnedCandidate)) {
            $pinnedCandidate = Join-Path $workspacePath $pinnedCandidate
        }
        if (Test-Path -LiteralPath $pinnedCandidate -PathType Leaf) {
            $planPath = $pinnedCandidate
            $planPinned = $true
        }
        else {
            $warnings.Add("The pinned identity plan '$pinnedSetting' is not in the workspace; " +
                'the newest plan was used instead.')
        }
    }

    if (-not $planPath -and $planArtefacts.Count -gt 0) {
        $planPath = @($planArtefacts | Select-Object -First 1).Path
    }

    if ($planPinned) {
        # Pinning is deliberate, so a newer plan is not an error - but the operator has to be
        # told, because every plan consumer is about to run against the older document.
        $pinnedParsed = ConvertFrom-MigrationOutputPath -Path $planPath
        $newerPlan = $null
        if ($pinnedParsed) {
            $newerPlan = @($planArtefacts | Where-Object { $_.Timestamp -gt $pinnedParsed.Timestamp }) |
                Select-Object -First 1
        }
        if ($newerPlan) {
            $warnings.Add("The pinned identity plan '$([System.IO.Path]::GetFileName($planPath))' is not the " +
                "newest: '$([System.IO.Path]::GetFileName($newerPlan.Path))' is newer.")
        }
    }

    $plan = $null
    if ($planPath) {
        try {
            $facts = Get-MigrationPlanFacts -Path $planPath
            $plan = [pscustomobject]@{
                Path          = $facts.Path
                Pinned        = $planPinned
                Timestamp     = $facts.Timestamp
                RowCount      = $facts.RowCount
                Waves         = $facts.Waves
                Statuses      = $facts.Statuses
                DivergentRows = $facts.DivergentRows
            }
        }
        catch {
            $warnings.Add("The identity plan '$([System.IO.Path]::GetFileName($planPath))' could not be read: " +
                $_.Exception.Message)
        }
    }

    # --- the run ledger ---------------------------------------------------------------------

    $ledgerResult = Get-MigrationRunLedgerEntry -Path (Join-Path $workspacePath 'Workbench' 'Runs.jsonl')
    $ledger = @($ledgerResult.Entries)
    foreach ($warning in @($ledgerResult.Warnings)) { $warnings.Add($warning) }

    $ledgerByFile = @{}
    foreach ($entry in $ledger) {
        foreach ($file in @($entry.Files)) {
            if (-not $file) { continue }
            $leafName = [System.IO.Path]::GetFileName([string]$file)
            if (-not $ledgerByFile.ContainsKey($leafName)) {
                $ledgerByFile[$leafName] = [System.Collections.Generic.List[object]]::new()
            }
            $ledgerByFile[$leafName].Add($entry)
        }
    }

    $entriesByStep = @{}
    foreach ($entry in $ledger) {
        $entryStepId = [string]$entry.StepId
        if (-not $entryStepId) { continue }
        if (-not $entriesByStep.ContainsKey($entryStepId)) {
            $entriesByStep[$entryStepId] = [System.Collections.Generic.List[object]]::new()
        }
        $entriesByStep[$entryStepId].Add($entry)
    }

    # --- attribute every artefact to a step instance ------------------------------------------

    $steps = @(Get-MigrationStep -Scenario $scenario)

    $matchers = [System.Collections.Generic.List[object]]::new()
    foreach ($step in $steps) {
        $fixedPrefix = [string](Get-MigrationDictionaryValue -Dictionary $step.Fixed -Key 'Prefix' -Default '')
        $resultIds = @(@($step.ResultId) +
            @(Get-MigrationProperty -InputObject $step -Name 'ResultIds' -Default @()) |
                Where-Object { $_ } | Select-Object -Unique)

        $matchers.Add([pscustomobject]@{
                Id              = $step.Id
                Order           = $step.Order
                Folder          = if ($fixedPrefix) { $fixedPrefix } else { $label }
                InventoryPrefix = if ($step.Produces -contains 'Inventory') { $fixedPrefix } else { '' }
                ResultIds       = $resultIds
                ReportNames     = @($step.Produces | Where-Object { $_ -like 'Report:*' } |
                        ForEach-Object { $_.Substring('Report:'.Length) })
                ProducesPlan    = ($step.Produces -contains 'Plan')
            })
    }

    $claims = @{}
    foreach ($artefact in $artefacts) {
        $candidates = [System.Collections.Generic.List[object]]::new()
        foreach ($matcher in $matchers) {
            $isResult = ($artefact.Suffix -in @('Results', 'DryRun')) -and $matcher.Folder -and
                ($artefact.Folder -eq $matcher.Folder) -and ($matcher.ResultIds -contains $artefact.Name)
            $isInventory = $matcher.InventoryPrefix -and ($artefact.Suffix -eq '') -and
                ($artefact.Prefix -eq $matcher.InventoryPrefix) -and ($artefact.Name -eq 'Users')
            $isPlan = $matcher.ProducesPlan -and ($artefact.Suffix -eq '') -and
                ($artefact.Name -eq 'IdentityPlan') -and $label -and ($artefact.Folder -eq $label)
            $isReport = ($artefact.Suffix -eq '') -and $matcher.Folder -and
                ($artefact.Folder -eq $matcher.Folder) -and ($matcher.ReportNames -contains $artefact.Name)

            if ($isResult -or $isInventory -or $isPlan -or $isReport) { $candidates.Add($matcher) }
        }

        $candidateIds = @($candidates | ForEach-Object { $_.Id })
        $leafName = [System.IO.Path]::GetFileName($artefact.Path)
        $namedEntries = @()
        if ($ledgerByFile.ContainsKey($leafName)) { $namedEntries = @($ledgerByFile[$leafName]) }

        $ownerId = $null
        $namedCandidates = @($namedEntries | Where-Object { $candidateIds -contains $_.StepId })
        if ($namedCandidates.Count -gt 0) {
            $ownerId = (Select-MigrationNewestEntry -Entry $namedCandidates).StepId
        }
        elseif ($candidateIds.Count -eq 1) {
            $ownerId = $candidateIds[0]
        }
        elseif ($candidateIds.Count -gt 1) {
            $stamp = $artefact.Timestamp
            $windowed = @($ledger | Where-Object {
                    $candidateIds -contains $_.StepId -and (Test-MigrationRunWindow -Entry $_ -Timestamp $stamp)
                })
            $ownerId = if ($windowed.Count -gt 0) {
                (Select-MigrationNewestEntry -Entry $windowed).StepId
            }
            else {
                @($candidates | Sort-Object -Property Order, Id | Select-Object -First 1).Id
            }
        }
        elseif ($namedEntries.Count -gt 0) {
            # No naming rule claims it, but a run says it wrote it - a log, or a report a
            # future script adds. The ledger is the record of what happened, so it wins.
            $ownerId = (Select-MigrationNewestEntry -Entry $namedEntries).StepId
        }

        if (-not $ownerId) { continue }
        if (-not $claims.ContainsKey($ownerId)) {
            $claims[$ownerId] = [System.Collections.Generic.List[object]]::new()
        }
        $claims[$ownerId].Add($artefact)
    }

    # --- detected state, per step instance ------------------------------------------------------

    $stateById = [ordered]@{}
    $stepStates = [System.Collections.Generic.List[object]]::new()

    foreach ($step in $steps) {
        $files = @()
        if ($claims.ContainsKey($step.Id)) {
            $files = @($claims[$step.Id] | Sort-Object -Property Timestamp -Descending)
        }

        $entries = @()
        if ($entriesByStep.ContainsKey($step.Id)) { $entries = @($entriesByStep[$step.Id]) }
        $newestEntry = if ($entries.Count -gt 0) { Select-MigrationNewestEntry -Entry $entries } else { $null }

        $lastRun = @($files | Where-Object { $_.Suffix -ne 'DryRun' }) | Select-Object -First 1
        $lastDryRun = @($files | Where-Object { $_.Suffix -eq 'DryRun' }) | Select-Object -First 1
        $summarySource = @($files |
                Where-Object { $_.Suffix -in @('Results', 'DryRun') -and $_.Extension -eq 'csv' }) |
            Select-Object -First 1

        $summary = [pscustomobject]@{ Succeeded = 0; Failed = 0; Skipped = 0; Planned = 0 }
        if ($summarySource) {
            $summaryLeaf = [System.IO.Path]::GetFileName($summarySource.Path)
            try {
                $counted = Get-MigrationResultSummary -Path $summarySource.Path
                $summary = [pscustomobject]@{
                    Succeeded = $counted.Succeeded
                    Failed    = $counted.Failed
                    Skipped   = $counted.Skipped
                    Planned   = $counted.Planned
                }
                if ($counted.RowCount -eq 0) {
                    $warnings.Add("The results file '$summaryLeaf' has a header and no rows.")
                }
            }
            catch {
                $warnings.Add("The results file '$summaryLeaf' could not be read: $($_.Exception.Message)")
            }
        }

        $exitCode = if ($newestEntry) { $newestEntry.ExitCode } else { $null }
        $tenantVerified = if ($newestEntry) { $newestEntry.TenantVerified } else { $null }

        $state = 'NotRun'
        if ($files.Count -gt 0 -or $entries.Count -gt 0) {
            $newestIsDryRun = $lastDryRun -and (-not $lastRun -or $lastDryRun.Timestamp -gt $lastRun.Timestamp)
            $state = if ($exitCode -eq 1) { 'Failed' }
            elseif ($exitCode -eq 3) { 'WorkRemains' }
            elseif ($newestIsDryRun) { 'DryRun' }
            elseif ($summary.Failed -gt 0 -or $exitCode -eq 2) { 'PartlyFailed' }
            elseif ($files.Count -gt 0 -or $exitCode -eq 0) { 'Done' }
            # A run was recorded, it left nothing behind and its exit code says nothing the
            # catalogue knows - an abort, or a child that died. It is certainly not done.
            else { 'Failed' }
        }

        # Only a step that reads the plan can be stale against it: it was run against a
        # document that has since been replaced.
        $readsPlan = ($step.Requires -contains 'Plan') -or (@($step.Resolve.Values) -contains 'Plan')
        if ($state -eq 'Done' -and $readsPlan -and $plan -and $lastRun -and
            $null -ne $plan.Timestamp -and $lastRun.Timestamp -lt $plan.Timestamp) {
            $state = 'Stale'
        }

        $stateById[$step.Id] = $state
        $stepStates.Add([pscustomobject]@{
                Id             = $step.Id
                State          = $state
                LastRun        = $lastRun
                LastDryRun     = $lastDryRun
                Files          = @($files)
                Summary        = $summary
                ExitCode       = $exitCode
                TenantVerified = $tenantVerified
            })
    }

    # --- the next step --------------------------------------------------------------------------

    # A Requires entry that names an artefact kind rather than a step is satisfied by the
    # artefact being there, whoever put it there - an operator who ran the planner by hand,
    # or a plan carried in from another machine.
    $declaredReports = @($steps | ForEach-Object { $_.Produces } | Where-Object { $_ -like 'Report:*' })
    $artefactKinds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($plan) { $null = $artefactKinds.Add('Plan') }
    foreach ($artefact in $artefacts) {
        if ($artefact.Extension -eq 'log') { $null = $artefactKinds.Add('Log') }
        if ($artefact.Suffix -eq 'Results') {
            $null = $artefactKinds.Add('Results')
            if ($artefact.Name -eq 'Export-MappingFile') { $null = $artefactKinds.Add('Mapping') }
        }
        if ($artefact.Suffix -eq '') {
            if ($artefact.Name -eq 'Users') { $null = $artefactKinds.Add('Inventory') }
            if ($declaredReports -contains "Report:$($artefact.Name)") {
                $null = $artefactKinds.Add("Report:$($artefact.Name)")
            }
        }
    }

    $nextStepId = $null
    foreach ($step in $steps) {
        if ($stateById[$step.Id] -eq 'Done') { continue }

        $ready = $true
        foreach ($requirement in @($step.Requires)) {
            $satisfied = if ($stateById.Contains($requirement)) {
                $stateById[$requirement] -eq 'Done'
            }
            else {
                $artefactKinds.Contains([string]$requirement)
            }
            if (-not $satisfied) {
                $ready = $false
                break
            }
        }

        if ($ready) {
            $nextStepId = $step.Id
            break
        }
    }

    return [pscustomobject]@{
        Path           = $workspacePath
        SettingsPath   = $settingsPath
        SettingsResult = $settingsResult
        Settings       = $settings
        Label          = $label
        Scenario       = $scenario
        Folders        = $folders
        Artefacts      = @($artefacts | Sort-Object -Property Folder, Timestamp, Name)
        Plan           = $plan
        Steps          = @($stepStates)
        Ledger         = $ledger
        NextStepId     = $nextStepId
        Warnings       = $warnings.ToArray()
    }
}
