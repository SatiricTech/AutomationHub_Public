#Requires -Version 7.4

<#
.SYNOPSIS
    Turns an identity plan into the source-to-destination mapping file a migration tool reads.

.DESCRIPTION
    Third-party movers - AvePoint Fly today - do not care how a destination address was
    decided; they want a two-column list saying "this source object becomes that destination
    object". This script produces that list from the identity plan, so the mapping the mover
    consumes and the plan the operator signed off can never drift apart. It never connects to
    a tenant.

    Tool formats live in one registry ($script:ToolFormats) near the top of the script, so
    supporting another tool means adding one entry and nothing else.

    A CSV twin is always written alongside a workbook: workbooks suit the person uploading
    them and nothing else - diffing two runs, grepping for an address or feeding the mapping
    into another script all want the CSV. When ImportExcel is unavailable and cannot be
    installed, the script warns and writes the CSV alone rather than failing the run.

    Only rows the plan has signed off are mapped: PlanStatus Planned, ManualOverride and
    UpnSmtpDiverge, plus Collision when -IncludeCollisions is given. Every other row -
    excluded, needing review, invalid, already in the destination - is reported as Skipped
    with the status named, as is any signed-off row that has no destination address. The
    results file is written even when nothing could be mapped, because a mapping file that
    is quietly short by four rows is how mailboxes get left behind.

.PARAMETER PlanPath
    The IdentityPlan.csv to read.

.PARAMETER Tool
    Which tool's mapping format to write. Default 'AvePoint'. Valid values are the keys of
    the format registry inside the script.

.PARAMETER Wave
    Only map rows in these waves. Omit to map every wave.

.PARAMETER ObjectType
    Plan object types to map. Defaults to the types a mover handles: User, Shared, Room,
    Equipment, Distribution, MailEnabledSecurity and Contact.

.PARAMETER UseInterim
    Map to the interim addresses (InterimPrimarySmtp / InterimUserPrincipalName) instead of
    the final target addresses - the first pass, before the vanity domain moves tenants.

.PARAMETER IncludeCollisions
    Also map rows whose PlanStatus is Collision. Off by default: a collision means the
    planned address is contested and the row usually needs an operator decision first.

.PARAMETER SkipExcel
    Write only the CSV twin, never the workbook. Also stops the script trying to install
    ImportExcel.

.PARAMETER OutputPath
    Directory for the mapping file, the results CSV and the log. Defaults to the toolkit
    output root (%LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations
    elsewhere).

.PARAMETER Prefix
    Client or run name. Output lands in <OutputPath>\<Prefix>\ and file names start '<Prefix>_'.

.PARAMETER LogPath
    Override for the log file path.

.PARAMETER DryRun
    Resolve every mapping and write the results file with Status Planned, without writing the
    mapping file itself.

.PARAMETER Verbosity
    Console noise level: Low, Medium (default) or High. The log file always gets everything.

.EXAMPLE
    .\Export-MigrationMappingFile.ps1 -PlanPath .\Contoso_IdentityPlan_20260908-101500.csv -Prefix Contoso

    Writes Contoso_Fly_User_Mapping_<timestamp>.xlsx and its CSV twin for every wave.

.EXAMPLE
    .\Export-MigrationMappingFile.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -UseInterim -SkipExcel

    Wave 1 only, mapped onto the interim newco.onmicrosoft.com addresses, CSV only - the
    shape you want on a machine where ImportExcel is not installed.

.EXAMPLE
    .\Export-MigrationMappingFile.ps1 -PlanPath .\IdentityPlan.csv `
        -ObjectType User, Shared -IncludeCollisions -DryRun -Verbosity High

    Dress rehearsal for the user and shared mailbox mappings, Collision rows included: every
    row resolved and reported, no mapping file written.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4+ and the bundled M365Migration module. ImportExcel 7.1.0 or
                  later is needed only for the workbook. No tenant connection is made and no
                  Graph scope or Exchange Online role is required, so GDAP does not apply.
    Exit codes  : 0 success, 1 fatal error (including a selection in which no row could be
                  mapped). This script never exits 2: rows it cannot map are reported
                  Skipped, not Failed.
    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [ValidateNotNullOrEmpty()]
    [string]$Tool = 'AvePoint',

    [ValidateNotNullOrEmpty()]
    [string[]]$Wave,

    [ValidateNotNullOrEmpty()]
    [string[]]$ObjectType = @('User', 'Shared', 'Room', 'Equipment', 'Distribution', 'MailEnabledSecurity', 'Contact'),

    [switch]$UseInterim,
    [switch]$IncludeCollisions,
    [switch]$SkipExcel,

    [string]$OutputPath,
    [string]$Prefix,
    [string]$LogPath,
    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

#region Configuration ------------------------------------------------------------------

# One entry per migration tool. Adding a tool here is the only change needed to support it:
# the key becomes a valid -Tool value automatically.
#   FileName      : '{timestamp}' is replaced at runtime.
#   FileType      : 'Csv' or 'Xlsx'. Xlsx needs ImportExcel and always gets a CSV twin.
#   WorksheetName : Xlsx only.
#   NewRow        : turns one (Source, Destination) pair into one output row; the object's
#                   property names become the header, so match the tool's template exactly.
$script:ToolFormats = [ordered]@{
    # Matches AvePoint's Fly_User_Mapping.xlsx template: one sheet named 'Migration mappings'
    # with the columns 'Source user/group' and 'Destination user/group'.
    AvePoint = @{
        Description   = "AvePoint Fly user mapping workbook ('Source user/group' to 'Destination user/group')"
        FileName      = 'Fly_User_Mapping_{timestamp}.xlsx'
        FileType      = 'Xlsx'
        WorksheetName = 'Migration mappings'
        NewRow        = {
            param($Source, $Destination)
            [pscustomobject][ordered]@{
                'Source user/group'      = $Source
                'Destination user/group' = $Destination
            }
        }
    }
    # Another tool is one more entry of the same shape; FileType 'Csv' omits WorksheetName.
}

$script:ExcelMinimumVersion = '7.1.0'

#endregion -----------------------------------------------------------------------------

#region Main ---------------------------------------------------------------------------

$exitCode = 0

try {
    $run = Initialize-MigrationRun -ScriptName 'Export-MigrationMappingFile' -OutputPath $OutputPath `
        -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity `
        -BoundParameters $PSBoundParameters

    $formatKey = @($script:ToolFormats.Keys | Where-Object { $_ -ieq $Tool } | Select-Object -First 1)
    if ($formatKey.Count -eq 0) {
        throw ("'$Tool' is not a known mapping tool. Supported tools: " +
            (($script:ToolFormats.Keys | Sort-Object) -join ', ') + '.')
    }
    $format = $script:ToolFormats[$formatKey[0]]
    Write-MigrationLog -Message "Mapping format: $($format.Description)" -Level INFO

    $planRows = @(Import-MigrationPlan -Path $PlanPath -Wave $Wave -ObjectType $ObjectType)

    $destinationColumns = if ($UseInterim) { @('InterimPrimarySmtp', 'InterimUserPrincipalName') }
    else { @('TargetPrimarySmtp', 'TargetUserPrincipalName') }
    Write-MigrationLog -Message ('Destination addresses come from ' + ($destinationColumns -join ', then ')) -Level INFO

    $results = [System.Collections.Generic.List[object]]::new()
    $mappings = [System.Collections.Generic.List[object]]::new()
    # The result rows behind $mappings, so a declined write can be reflected on exactly those rows.
    $mappedResults = [System.Collections.Generic.List[object]]::new()
    $seenSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $duplicateCount = 0

    foreach ($row in $planRows) {
        $planStatus = Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default ''
        $rowObjectType = Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default ''
        $rowWave = Get-MigrationCsvValue -Row $row -Name 'Wave' -Default ''

        $source = Get-MigrationCsvValue -Row $row -Name 'SourcePrimarySmtp' -Default ''
        if (-not $source) { $source = Get-MigrationCsvValue -Row $row -Name 'SourceUserPrincipalName' -Default '' }

        $destination = ''
        foreach ($column in $destinationColumns) {
            $destination = Get-MigrationCsvValue -Row $row -Name $column -Default ''
            if ($destination) { break }
        }

        $identity = @($source, (Get-MigrationCsvValue -Row $row -Name 'DisplayName' -Default '')) |
            Where-Object { $_ } | Select-Object -First 1
        if (-not $identity) { $identity = '(unnamed plan row)' }

        $result = [pscustomobject][ordered]@{
            Identity    = $identity
            Action      = 'Map source to destination'
            Status      = 'Skipped'
            Detail      = ''
            Source      = $source
            Destination = $destination
            ObjectType  = $rowObjectType
            Wave        = $rowWave
            PlanStatus  = $planStatus
        }
        $results.Add($result)

        # The plan is the signed-off artefact, so only rows it has approved may reach the mover.
        # Collision, NeedsReview, Invalid and hand-Excluded rows often still carry the address
        # the planner assigned before it changed its mind - an address alone is not consent.
        # -AllowSynced because nothing is written to a tenant here; the mover treats a synced
        # object like any other. Import-MigrationPlan has already applied -ObjectType.
        $gate = Test-MigrationPlanRowActionable -Row $row -IncludeCollisions:$IncludeCollisions -AllowSynced
        if (-not $gate.Actionable) {
            $result.Status = $gate.Status
            $result.Detail = $gate.Reason
            continue
        }

        # A row that cannot be mapped is reported, not dropped: a mapping file quietly short by
        # four rows is how mailboxes get left behind.
        if (-not $source) {
            $result.Detail = 'The plan row has neither a source primary SMTP address nor a source user principal name.'
            continue
        }
        if (-not $destination) {
            $addressKind = if ($UseInterim) { 'interim' } else { 'target' }
            $result.Detail = "No $addressKind address in the plan (PlanStatus $planStatus); resolve the row before mapping it."
            continue
        }
        if (-not $seenSources.Add($source)) {
            $duplicateCount++
            $result.Detail = 'Duplicate source address; the first occurrence was kept.'
            continue
        }

        $mappings.Add((& $format.NewRow $source $destination))
        $mappedResults.Add($result)
        $result.Status = if ($DryRun) { 'Planned' } else { 'Succeeded' }
        $result.Detail = "$source maps to $destination"
    }

    if ($duplicateCount -gt 0) {
        Write-MigrationLog -Message "$duplicateCount duplicate source address(es) were ignored; the first occurrence of each was kept." -Level WARNING
    }

    if ($mappings.Count -eq 0) {
        # Every selected row was Skipped. The results file is the whole point in that case - it
        # names why each row was left out - so it is written before the run is failed.
        $null = Export-MigrationResult -Rows $results.ToArray() -Name 'MappingFile'
        throw ("None of the $($planRows.Count) selected plan row(s) could be mapped - see the results file. " +
            'Resolve the NeedsReview and Invalid rows, pass -IncludeCollisions to map Collision rows, ' +
            'or widen -Wave / -ObjectType.')
    }

    $leader = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
    $mappingPath = Join-Path -Path $run.OutputDirectory -ChildPath (
        $leader + ($format.FileName -replace '\{timestamp\}', (Get-Date -Format 'yyyyMMdd-HHmmss')))
    $csvPath = [System.IO.Path]::ChangeExtension($mappingPath, '.csv')

    # The CSV twin is the deliverable, so its ShouldProcess decision is the one the result rows
    # follow. -WhatIf, or No at the prompt, means nothing was written and the rows must not read
    # as Succeeded. 'Planned' stays reserved for -DryRun, whose rows are left alone here:
    # Invoke-MigrationAction already turns that write into a '[DRYRUN] Would:' log line.
    $csvApproved = $PSCmdlet.ShouldProcess($csvPath, "Write $($mappings.Count) mapping row(s)")
    if ($csvApproved) {
        Invoke-MigrationAction -Description "Write $($mappings.Count) mapping row(s) to $csvPath" -Action {
            $mappings | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
        }
    }
    elseif (-not $DryRun) {
        foreach ($mapped in $mappedResults) {
            $mapped.Status = 'Skipped'
            $mapped.Detail = 'Declined at the confirmation prompt.'
        }
    }

    # The results file is the operator's check that nothing was left behind, so it is written
    # as soon as the deliverable is settled: whatever the workbook step does next cannot take
    # the report with it.
    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'MappingFile'

    if ($format.FileType -eq 'Xlsx') {
        if ($SkipExcel) {
            Write-MigrationLog -Message '-SkipExcel was supplied; the workbook was not written. The CSV twin holds the same mappings.' -Level WARNING
        }
        elseif (-not $csvApproved) {
            # No CSV twin means nothing to twin: a workbook on its own would contradict the
            # Skipped rows the results file has just recorded.
            Write-MigrationLog -Message 'The mapping write was declined; the workbook was not written either.' -Level INFO
        }
        elseif ($PSCmdlet.ShouldProcess($mappingPath, "Write $($mappings.Count) mapping row(s)")) {
            # The workbook is a convenience, not the deliverable - the CSV twin carries the same
            # rows - so a missing ImportExcel, or a workbook write that fails (a locked file, a
            # broken ImportExcel runtime dependency), is a warning rather than a failed run.
            $excelReady = $true
            try { Initialize-MigrationModule -Name 'ImportExcel' -MinimumVersion $script:ExcelMinimumVersion }
            catch {
                Write-MigrationLog -Message ("The workbook cannot be written: $($_.Exception.Message) " +
                    'The CSV twin holds the same mappings - use it, or re-run with -SkipExcel to silence this.') -Level WARNING
                $excelReady = $false
            }

            if ($excelReady) {
                try {
                    Invoke-MigrationAction -Description "Write the $Tool workbook to $mappingPath" -Action {
                        if (Test-Path -LiteralPath $mappingPath) { Remove-Item -LiteralPath $mappingPath -Force -ErrorAction Stop }
                        $mappings | Export-Excel -Path $mappingPath -WorksheetName $format.WorksheetName -ErrorAction Stop
                    }
                }
                catch {
                    Write-MigrationLog -Message ("The workbook could not be written: $($_.Exception.Message) " +
                        "The CSV twin at $csvPath holds the same mappings - use it, or re-run with -SkipExcel to silence this.") -Level WARNING
                }
            }
        }
    }
}
catch {
    Write-MigrationLog -Message "Fatal error: $($_.Exception.Message)" -Level ERROR
    Write-MigrationLog -Message "At: $($_.ScriptStackTrace)" -Level DEBUG
    $exitCode = 1
}

#endregion -----------------------------------------------------------------------------

#region Cleanup ------------------------------------------------------------------------

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion -----------------------------------------------------------------------------
