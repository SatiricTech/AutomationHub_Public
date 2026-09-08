#Requires -Version 7.4

<#
.SYNOPSIS
    Turns an identity plan into the source-to-destination mapping file a migration tool reads.

.DESCRIPTION
    Third-party movers - AvePoint Fly today - do not care how a destination address was
    decided; they want a two-column list saying "this source object becomes that destination
    object". This script produces that list from the identity plan, so the mapping the mover
    consumes and the plan the operator signed off can never drift apart.

    Tool formats live in one registry ($script:ToolFormats) near the top of the script. Each
    entry declares the output file name, whether it is a workbook or a CSV, the worksheet
    name, and a scriptblock turning one source/destination pair into one output row - the
    row object's property names become the header. Supporting another tool means adding one
    entry; -Tool is validated against the registry at runtime, so nothing else changes.

    A CSV twin is always written alongside a workbook. Workbooks are convenient for the
    person uploading them and useless for everything else: diffing two runs, grepping for an
    address, or feeding the mapping into another script all want the CSV. When ImportExcel is
    unavailable and cannot be installed, the script warns and the CSV alone is written rather
    than failing the run.

    Rows that have no destination address - anything excluded, needing review, or not yet
    named - are reported as Skipped in the results file rather than silently dropped, because
    a mapping file that is quietly short by four rows is how mailboxes get left behind.

    This script never connects to a tenant.

.PARAMETER PlanPath
    The IdentityPlan.csv to read.

.PARAMETER Tool
    Which tool's mapping format to write. Default 'AvePoint'. Valid values are the keys of
    the format registry inside the script.

.PARAMETER Wave
    Only map rows in these waves. Omit to map every wave.

.PARAMETER ObjectType
    Plan object types to map. Defaults to the types a mover handles: User, Shared, Room,
    Equipment, Distribution, MailEnabledSecurity and Contact. Guests, dynamic distribution
    groups and Microsoft 365 groups are excluded by default.

.PARAMETER UseInterim
    Map to the interim addresses (InterimPrimarySmtp / InterimUserPrincipalName) instead of
    the final target addresses. Use this for the first pass, when the vanity domain has not
    yet been moved to the destination tenant.

.PARAMETER SkipExcel
    Write only the CSV twin, never the workbook. Also stops the script trying to install
    ImportExcel.

.PARAMETER OutputPath
    Directory for the mapping file, the results CSV and the log. Defaults to the toolkit
    output root.

.PARAMETER Prefix
    Client or run name. When supplied, output lands in <OutputPath>\<Prefix>\ and file names
    start with '<Prefix>_'.

.PARAMETER LogPath
    Override for the log file path.

.PARAMETER DryRun
    Resolve every mapping and write the results file with Status Planned, without writing the
    mapping file itself.

.PARAMETER Verbosity
    Console noise level: Low (errors and successes), Medium (adds warnings, the default) or
    High (everything). The log file always receives everything.

.EXAMPLE
    .\Export-MigrationMappingFile.ps1 -PlanPath .\Contoso_IdentityPlan_20260908-101500.csv -Prefix Contoso

    Writes Contoso_Fly_User_Mapping_<timestamp>.xlsx and its CSV twin for every wave.

.EXAMPLE
    .\Export-MigrationMappingFile.ps1 -PlanPath .\IdentityPlan.csv -Wave 1 -UseInterim -SkipExcel

    Wave 1 only, mapped onto the interim newco.onmicrosoft.com addresses, CSV only - the
    shape you want on a machine where ImportExcel is not installed.

.EXAMPLE
    .\Export-MigrationMappingFile.ps1 -PlanPath .\IdentityPlan.csv `
        -ObjectType User, Shared -DryRun -Verbosity High

    Dress rehearsal for the user and shared mailbox mappings: every row resolved and reported,
    no mapping file written.

.NOTES
    Author      : AutomationHub
    Requires    : PowerShell 7.4+ and the bundled M365Migration module. ImportExcel 7.1.0 or
                  later is needed only for the workbook. No tenant connection is made and no
                  Graph scope or Exchange Online role is required, so GDAP does not apply.
    Exit codes  : 0 success, 1 fatal error, 2 completed with row failures.
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
#   Description   : shown in errors and in the run log.
#   FileName      : output file name; '{timestamp}' is replaced at runtime.
#   FileType      : 'Csv' or 'Xlsx'. Xlsx needs ImportExcel and always gets a CSV twin.
#   WorksheetName : Xlsx only - the sheet name the tool expects.
#   NewRow        : scriptblock turning one (Source, Destination) pair into one output row;
#                   the object's property names become the header row, so match the tool's
#                   own template exactly.
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
    # To add another tool, copy the shape above, for example:
    # BitTitan = @{
    #     Description = 'BitTitan MigrationWiz recipient mapping CSV'
    #     FileName    = 'BitTitan-RecipientMapping_{timestamp}.csv'
    #     FileType    = 'Csv'
    #     NewRow      = {
    #         param($Source, $Destination)
    #         [pscustomobject][ordered]@{ 'Source Email Address' = $Source; 'Destination Email Address' = $Destination }
    #     }
    # }
}

$script:ExcelMinimumVersion = '7.1.0'

#endregion -----------------------------------------------------------------------------

#region Functions ----------------------------------------------------------------------

function Resolve-MappingToolFormat {
    <#
    .SYNOPSIS
        Returns the registry entry for the requested tool.
    .PARAMETER Name
        The -Tool value to look up, matched case-insensitively.
    .EXAMPLE
        Resolve-MappingToolFormat -Name AvePoint
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $key = @($script:ToolFormats.Keys | Where-Object { $_ -ieq $Name } | Select-Object -First 1)
    if ($key.Count -eq 0) {
        throw ("'$Name' is not a known mapping tool. Supported tools: " +
            (($script:ToolFormats.Keys | Sort-Object) -join ', ') + '.')
    }
    return $script:ToolFormats[$key[0]]
}

function Test-MappingExcelSupport {
    <#
    .SYNOPSIS
        Reports whether the workbook can be written, installing ImportExcel if needed.
    .DESCRIPTION
        The workbook is a convenience, not the deliverable - the CSV twin carries the same
        rows - so a missing or unusable ImportExcel is a warning rather than a failed run.
    .PARAMETER MinimumVersion
        The lowest ImportExcel version that loads cleanly on PowerShell 7.
    .EXAMPLE
        if (Test-MappingExcelSupport -MinimumVersion '7.1.0') { $rows | Export-Excel -Path $path }
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MinimumVersion
    )

    try {
        Initialize-MigrationModule -Name 'ImportExcel' -MinimumVersion $MinimumVersion
        return $true
    }
    catch {
        Write-MigrationLog -Message ("The workbook cannot be written: $($_.Exception.Message) " +
            'The CSV twin holds the same mappings - use it, or re-run with -SkipExcel to silence this.') -Level WARNING
        return $false
    }
}

#endregion -----------------------------------------------------------------------------

#region Main ---------------------------------------------------------------------------

$exitCode = 0

try {
    $run = Initialize-MigrationRun -ScriptName 'Export-MigrationMappingFile' -OutputPath $OutputPath `
        -Prefix $Prefix -LogPath $LogPath -DryRun:$DryRun -Verbosity $Verbosity `
        -BoundParameters $PSBoundParameters

    $format = Resolve-MappingToolFormat -Name $Tool
    Write-MigrationLog -Message "Mapping format: $($format.Description)" -Level INFO

    $planRows = @(Import-MigrationPlan -Path $PlanPath -Wave $Wave -ObjectType $ObjectType)

    $sourceColumn = 'SourcePrimarySmtp'
    $destinationColumns = if ($UseInterim) {
        @('InterimPrimarySmtp', 'InterimUserPrincipalName')
    }
    else {
        @('TargetPrimarySmtp', 'TargetUserPrincipalName')
    }
    Write-MigrationLog -Message ("Destination addresses come from " + ($destinationColumns -join ', then ')) -Level INFO

    $results = [System.Collections.Generic.List[object]]::new()
    $mappings = [System.Collections.Generic.List[object]]::new()
    $seenSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $duplicateCount = 0

    foreach ($row in $planRows) {
        $planStatus = Get-MigrationCsvValue -Row $row -Name 'PlanStatus' -Default ''
        $rowObjectType = Get-MigrationCsvValue -Row $row -Name 'ObjectType' -Default ''
        $rowWave = Get-MigrationCsvValue -Row $row -Name 'Wave' -Default ''

        $source = Get-MigrationCsvValue -Row $row -Name $sourceColumn -Default ''
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

        if (-not $source) {
            $result.Detail = 'The plan row has neither a source primary SMTP address nor a source user principal name.'
            $results.Add($result)
            continue
        }

        if (-not $destination) {
            $addressKind = if ($UseInterim) { 'interim' } else { 'target' }
            $result.Detail = "No $addressKind address in the plan (PlanStatus $planStatus); resolve the row before mapping it."
            $results.Add($result)
            continue
        }

        if (-not $seenSources.Add($source)) {
            $duplicateCount++
            $result.Detail = 'Duplicate source address; the first occurrence was kept.'
            $results.Add($result)
            continue
        }

        $mappings.Add((& $format.NewRow $source $destination))
        $result.Status = if ($DryRun) { 'Planned' } else { 'Succeeded' }
        $result.Detail = "$source maps to $destination"
        $results.Add($result)
    }

    if ($mappings.Count -eq 0) {
        throw ("None of the $($planRows.Count) selected plan row(s) has both a source and a destination address. " +
            'Resolve the NeedsReview, Collision and Invalid rows, or widen -Wave / -ObjectType.')
    }

    # --- Write the mapping file(s) ------------------------------------------------------
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leader = if ($run.Prefix) { "$($run.Prefix)_" } else { '' }
    $fileName = $leader + ($format.FileName -replace '\{timestamp\}', $timestamp)
    $mappingPath = Join-Path -Path $run.OutputDirectory -ChildPath $fileName
    $csvPath = [System.IO.Path]::ChangeExtension($mappingPath, '.csv')

    if ($PSCmdlet.ShouldProcess($csvPath, "Write $($mappings.Count) mapping row(s)")) {
        Invoke-MigrationAction -Description "Write $($mappings.Count) mapping row(s) to $csvPath" -Action {
            $mappings | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
        }
    }

    if ($format.FileType -eq 'Xlsx') {
        if ($SkipExcel) {
            Write-MigrationLog -Message '-SkipExcel was supplied; the workbook was not written. The CSV twin holds the same mappings.' -Level WARNING
        }
        elseif ($PSCmdlet.ShouldProcess($mappingPath, "Write $($mappings.Count) mapping row(s)")) {
            if (Test-MappingExcelSupport -MinimumVersion $script:ExcelMinimumVersion) {
                Invoke-MigrationAction -Description "Write the $Tool workbook to $mappingPath" -Action {
                    if (Test-Path -LiteralPath $mappingPath) { Remove-Item -LiteralPath $mappingPath -Force -ErrorAction Stop }
                    $mappings | Export-Excel -Path $mappingPath -WorksheetName $format.WorksheetName -ErrorAction Stop
                }
            }
        }
    }

    if ($duplicateCount -gt 0) {
        Write-MigrationLog -Message "$duplicateCount duplicate source address(es) were ignored; the first occurrence of each was kept." -Level WARNING
    }

    $null = Export-MigrationResult -Rows $results.ToArray() -Name 'MappingFile'

    if (@($results | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0) { $exitCode = 2 }
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
