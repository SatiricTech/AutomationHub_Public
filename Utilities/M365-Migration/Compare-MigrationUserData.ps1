#Requires -Version 7.4

<#
.SYNOPSIS
    Compares user data between two tenants - fuzzily between two CSV exports, or
    exactly between a destination inventory and the identity plan.

.DESCRIPTION
    CSV mode (default) matches every reference row against the difference CSV and
    reports 'Exact Match' (UPN or primary address equal), 'Partial Match' (display
    name, first+last, email local part, or a Levenshtein display-name similarity at
    or above -SimilarityThreshold) or 'No Match'. MatchedOn names the criteria that
    fired and the Source_/Target_ columns carry both sides of the pairing.

    Plan mode (-PlanPath) is the post-cutover check. The plan's
    TargetUserPrincipalName and TargetPrimarySmtp are compared exactly - never
    fuzzily - against a destination Users inventory, giving Match, Mismatch (the
    object exists but its address disagrees, or the expected address is held by a
    different UPN), Missing, Extra (a destination object no plan row claims) or
    Skipped (an Excluded row, or one with no target UPN yet).

    Headers are resolved through Import-MigrationCsv's alias vocabulary; each
    -*Column parameter overrides one field. Both modes are entirely offline.

.PARAMETER ReferenceCsv
    CSV mode. Path to the first CSV (the "source" / left side).

.PARAMETER DifferenceCsv
    Path to the CSV to match against - the "target" side in CSV mode, the
    destination tenant's Users inventory in plan mode.

.PARAMETER PlanPath
    Plan mode. Path to IdentityPlan.csv, whose TargetUserPrincipalName and
    TargetPrimarySmtp columns become the expected destination state.

.PARAMETER Wave
    Plan mode. Only compare plan rows in these waves. The whole destination CSV is
    still read, so out-of-wave objects are reported as Extra.

.PARAMETER ObjectType
    Plan mode. Only compare plan rows of these object types (User, Shared, Room ...).

.PARAMETER SimilarityThreshold
    CSV mode. Display-name similarity (0.0 - 1.0) at/above which two non-identical
    names count as a "SimilarName" partial match. Default 0.85.

.PARAMETER OutputPath
    Root directory for the log and the comparison CSV. Defaults to
    %LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations elsewhere.

.PARAMETER Prefix
    Client/run label. Files land in <root>\<Prefix>\ and names start with <Prefix>_.

.PARAMETER UpnColumn
    Explicit header for the user principal name column, for when alias resolution
    picks the wrong header or the header is not in the alias vocabulary.

.PARAMETER EmailColumn
    Explicit header for the primary SMTP / email column.

.PARAMETER FirstNameColumn
    CSV mode. Explicit header for the first name column.

.PARAMETER LastNameColumn
    CSV mode. Explicit header for the last name column.

.PARAMETER DisplayNameColumn
    CSV mode. Explicit header for the display name column.

.PARAMETER DryRun
    Preview only - load the inputs, log the resolved columns and row counts, and
    write a -DryRun_ file holding a single Planned row instead of the comparison.

.PARAMETER Verbosity
    Console detail: Low (errors and successes), Medium (adds warnings) or High
    (everything). The log file always receives everything.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -ReferenceCsv .\Source-Users.csv -DifferenceCsv .\Target-Users.csv

    Fuzzy-matches every source user against the destination export.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -ReferenceCsv .\Source-Users.csv -DifferenceCsv .\Target-Users.csv `
        -SimilarityThreshold 0.92 -Prefix Contoso -Verbosity High

    Tightens the fuzzy display-name threshold and files output under the Contoso folder.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -PlanPath .\IdentityPlan.csv -DifferenceCsv .\Destination-Users.csv -Wave 1

    Post-cutover check for wave 1, reporting anything the destination holds that the
    plan does not as Extra.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -PlanPath .\IdentityPlan.csv -DifferenceCsv .\Destination-Users.csv `
        -UpnColumn 'Primary Email Address' -DryRun

    Confirms which columns a non-standard export would be read through.

.NOTES
    Author       : AutomationHub
    Requires     : PowerShell 7.4, the M365Migration module beside this script
    Graph scopes : none - this script is entirely offline
    EXO roles    : none
    GDAP         : not applicable (no tenant connection is made)
    Written with assistance from Claude (Anthropic).
#>

[CmdletBinding(DefaultParameterSetName = 'Csv')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Csv')]
    [ValidateNotNullOrEmpty()]
    [string]$ReferenceCsv,

    [Parameter(Mandatory = $true, ParameterSetName = 'Plan')]
    [ValidateNotNullOrEmpty()]
    [string]$PlanPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DifferenceCsv,

    [Parameter(ParameterSetName = 'Plan')]
    [string[]]$Wave,

    [Parameter(ParameterSetName = 'Plan')]
    [string[]]$ObjectType,

    [Parameter(ParameterSetName = 'Csv')]
    [ValidateRange(0.0, 1.0)]
    [double]$SimilarityThreshold = 0.85,

    [string]$OutputPath,

    [string]$Prefix,

    [string]$UpnColumn,

    [string]$EmailColumn,

    [Parameter(ParameterSetName = 'Csv')]
    [string]$FirstNameColumn,

    [Parameter(ParameterSetName = 'Csv')]
    [string]$LastNameColumn,

    [Parameter(ParameterSetName = 'Csv')]
    [string]$DisplayNameColumn,

    [switch]$DryRun,

    [ValidateSet('Low', 'Medium', 'High')]
    [string]$Verbosity = 'Medium'
)

Import-Module (Join-Path $PSScriptRoot 'M365Migration' 'M365Migration.psd1') -Force -ErrorAction Stop

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Configuration ----------------------------------------------------------

# Every field the script matches on: the canonical property name Import-MigrationCsv
# resolves headers to, and the operator override that outranks it.
$script:CompareFields = [ordered]@{
    Upn   = @{ Canonical = 'UserPrincipalName'; Override = $UpnColumn }
    Email = @{ Canonical = 'PrimarySmtpAddress'; Override = $EmailColumn }
    First = @{ Canonical = 'FirstName'; Override = $FirstNameColumn }
    Last  = @{ Canonical = 'LastName'; Override = $LastNameColumn }
    Name  = @{ Canonical = 'DisplayName'; Override = $DisplayNameColumn }
}

#endregion ---------------------------------------------------------------------

#region Functions --------------------------------------------------------------

function Resolve-CompareColumnSet {
    <#
        Names the property to read for each matched field on one side of the
        comparison. An operator override wins when the imported rows actually
        carry it; otherwise the canonical name Import-MigrationCsv resolved the
        header to is used. A field the CSV lacks maps to $null, which every
        caller treats as "no value".
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Available,
        [Parameter(Mandatory)][string]$Side
    )

    $resolved = @{}
    foreach ($field in $script:CompareFields.Keys) {
        $canonical = $script:CompareFields[$field].Canonical
        $override = $script:CompareFields[$field].Override
        $hit = $null

        if (-not [string]::IsNullOrWhiteSpace($override)) {
            $hit = @($Available | Where-Object { $_ -ieq $override.Trim() }) | Select-Object -First 1
            if (-not $hit) {
                Write-MigrationLog -Message ("Override column '$override' is not present in the $Side CSV after " +
                    "alias resolution - falling back to '$canonical'.") -Level WARNING
            }
        }
        if (-not $hit) { $hit = @($Available | Where-Object { $_ -ieq $canonical }) | Select-Object -First 1 }

        $resolved[$field] = $hit
    }

    return $resolved
}

function Get-CompareValue {
    <#
        Trimmed read of one resolved column. -Normalize lower-cases it for
        matching; without the switch the value keeps its case for the output
        columns. A missing record or an unresolved column gives ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Record,
        [AllowNull()][AllowEmptyString()][string]$Column,
        [switch]$Normalize
    )

    if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Column)) { return '' }
    $value = ([string](Get-MigrationProperty -InputObject $Record -Name $Column -Default '')).Trim()
    if ($Normalize) { return $value.ToLowerInvariant() }
    return $value
}

function Get-StringSimilarity {
    <#
        Returns 0.0 - 1.0 similarity based on Levenshtein edit distance. Used
        only for display names: it is what catches 'Jon Smith' against
        'John Smith' when neither UPN nor address survived the migration.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [AllowNull()][AllowEmptyString()][string]$A,
        [AllowNull()][AllowEmptyString()][string]$B
    )

    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return 0.0 }
    if ($A -eq $B) { return 1.0 }

    $lenA = $A.Length
    $lenB = $B.Length
    $d = [int[, ]]::new(($lenA + 1), ($lenB + 1))
    for ($i = 0; $i -le $lenA; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $lenB; $j++) { $d[0, $j] = $j }

    for ($i = 1; $i -le $lenA; $i++) {
        for ($j = 1; $j -le $lenB; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $d[$i, $j] = [math]::Min([math]::Min($d[($i - 1), $j] + 1, $d[$i, ($j - 1)] + 1), $d[($i - 1), ($j - 1)] + $cost)
        }
    }

    return [math]::Round(1.0 - ($d[$lenA, $lenB] / [math]::Max($lenA, $lenB)), 4)
}

function New-ComparePlanRow {
    <# One plan-mode result row, so every branch emits the same columns in the same order. #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory result row; it changes no state.')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Values)

    $row = [ordered]@{
        Identity                     = ''
        Action                       = 'CompareToPlan'
        Status                       = ''
        Detail                       = ''
        PlanTargetUserPrincipalName  = ''
        PlanTargetPrimarySmtp        = ''
        DestinationUserPrincipalName = ''
        DestinationPrimarySmtp       = ''
        SourceUserPrincipalName      = ''
        Wave                         = ''
        ObjectType                   = ''
        PlanStatus                   = ''
    }
    foreach ($key in $Values.Keys) { $row[$key] = $Values[$key] }
    return [pscustomobject]$row
}

#endregion ---------------------------------------------------------------------

#region Main -------------------------------------------------------------------

$exitCode = 0
$null = Initialize-MigrationRun -ScriptName 'Compare-MigrationUserData' -OutputPath $OutputPath `
    -Prefix $Prefix -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters

try {
    $isPlanMode = $PSCmdlet.ParameterSetName -eq 'Plan'
    $resultName = if ($isPlanMode) { 'Compare-UserData-Plan' } else { 'Compare-UserData' }
    $results = [System.Collections.Generic.List[object]]::new()

    $difference = @(Import-MigrationCsv -Path $DifferenceCsv)
    $difColumns = Resolve-CompareColumnSet -Available @($difference[0].PSObject.Properties.Name) -Side 'difference'
    $difUpn = $difColumns.Upn
    $difEmail = $difColumns.Email

    if ($isPlanMode) {
        $planParameters = @{ Path = $PlanPath }
        if ($Wave) { $planParameters['Wave'] = $Wave }
        if ($ObjectType) { $planParameters['ObjectType'] = $ObjectType }
        $planRows = @(Import-MigrationPlan @planParameters)

        Write-MigrationLog -Message "Destination inventory columns - UPN: $difUpn  Email: $difEmail" -Level INFO
        Write-MigrationLog -Message "Comparing $($planRows.Count) plan row(s) against $($difference.Count) destination row(s)." -Level INFO

        if (-not $difUpn) {
            throw ("The destination inventory '$DifferenceCsv' has no UserPrincipalName column (and none of its " +
                'aliases). Name it explicitly with -UpnColumn.')
        }

        if ($DryRun) {
            $results.Add([pscustomobject][ordered]@{
                    Identity = $PlanPath
                    Action   = 'CompareToPlan'
                    Status   = 'Planned'
                    Detail   = ("Would compare $($planRows.Count) plan row(s) against $($difference.Count) " +
                        "destination row(s) using UPN column '$difUpn' and email column '$difEmail'.")
                })
        }
        else {
            # Index the destination once. Both indexes point at the same records so a
            # plan row that lost its UPN can still be found by its expected address.
            $destByUpn = @{}
            $destByEmail = @{}
            $seen = [System.Collections.Generic.HashSet[int]]::new()
            for ($i = 0; $i -lt $difference.Count; $i++) {
                $key = Get-CompareValue -Record $difference[$i] -Column $difUpn -Normalize
                if ($key -and -not $destByUpn.ContainsKey($key)) { $destByUpn[$key] = $i }
                $mail = Get-CompareValue -Record $difference[$i] -Column $difEmail -Normalize
                if ($mail -and -not $destByEmail.ContainsKey($mail)) { $destByEmail[$mail] = $i }
            }

            foreach ($planRow in $planRows) {
                $targetUpn = Get-MigrationCsvValue -Row $planRow -Name 'TargetUserPrincipalName' -Default ''
                $targetSmtp = Get-MigrationCsvValue -Row $planRow -Name 'TargetPrimarySmtp' -Default ''
                $sourceUpn = Get-MigrationCsvValue -Row $planRow -Name 'SourceUserPrincipalName' -Default ''
                $planStatus = Get-MigrationCsvValue -Row $planRow -Name 'PlanStatus' -Default ''

                $status = ''
                $detail = ''
                $destUpn = ''
                $destSmtp = ''

                if ($planStatus -eq 'Excluded') {
                    $reason = Get-MigrationCsvValue -Row $planRow -Name 'ExcludeReason' -Default 'no reason recorded'
                    $status = 'Skipped'
                    $detail = "Plan row is Excluded ($reason) - nothing is expected in the destination."
                }
                elseif (-not $targetUpn) {
                    $status = 'Skipped'
                    $detail = "Plan row has no TargetUserPrincipalName (PlanStatus $planStatus) - nothing to compare."
                }
                else {
                    $upnKey = $targetUpn.ToLowerInvariant()
                    $smtpKey = if ($targetSmtp) { $targetSmtp.ToLowerInvariant() } else { '' }
                    $index = -1

                    if ($destByUpn.ContainsKey($upnKey)) { $index = $destByUpn[$upnKey] }
                    elseif ($smtpKey -and $destByEmail.ContainsKey($smtpKey)) { $index = $destByEmail[$smtpKey] }

                    if ($index -ge 0) {
                        [void]$seen.Add($index)
                        $destUpn = Get-CompareValue -Record $difference[$index] -Column $difUpn
                        $destSmtp = Get-CompareValue -Record $difference[$index] -Column $difEmail
                    }

                    if ($index -lt 0) {
                        $status = 'Missing'
                        $detail = "No destination object matches the planned UPN '$targetUpn'" +
                        $(if ($targetSmtp) { " or primary SMTP '$targetSmtp'." } else { '.' })
                    }
                    elseif (-not $destByUpn.ContainsKey($upnKey)) {
                        $status = 'Mismatch'
                        $detail = "No destination object has UPN '$targetUpn'; '$destUpn' holds the expected primary SMTP '$targetSmtp'."
                    }
                    elseif (-not $targetSmtp) {
                        $status = 'Match'
                        $detail = 'Target UPN is present; the plan carries no TargetPrimarySmtp to check.'
                    }
                    elseif (-not $destSmtp) {
                        $status = 'Mismatch'
                        $detail = "Target UPN is present but the destination row has no primary SMTP; the plan expects '$targetSmtp'."
                    }
                    elseif ($destSmtp -ieq $targetSmtp) {
                        $status = 'Match'
                        $detail = 'Target UPN and primary SMTP both match the plan.'
                    }
                    else {
                        $status = 'Mismatch'
                        $detail = "Primary SMTP is '$destSmtp'; the plan expects '$targetSmtp'."
                    }
                }

                $results.Add((New-ComparePlanRow -Values @{
                            Identity                     = if ($targetUpn) { $targetUpn } else { $sourceUpn }
                            Status                       = $status
                            Detail                       = $detail
                            PlanTargetUserPrincipalName  = $targetUpn
                            PlanTargetPrimarySmtp        = $targetSmtp
                            DestinationUserPrincipalName = $destUpn
                            DestinationPrimarySmtp       = $destSmtp
                            SourceUserPrincipalName      = $sourceUpn
                            Wave                         = Get-MigrationCsvValue -Row $planRow -Name 'Wave' -Default ''
                            ObjectType                   = Get-MigrationCsvValue -Row $planRow -Name 'ObjectType' -Default ''
                            PlanStatus                   = $planStatus
                        }))
            }

            # Anything the destination holds that no plan row claimed. These are the
            # rows that turn "the migration is complete" into "what are these?".
            for ($i = 0; $i -lt $difference.Count; $i++) {
                if ($seen.Contains($i)) { continue }
                $extraUpn = Get-CompareValue -Record $difference[$i] -Column $difUpn
                $extraSmtp = Get-CompareValue -Record $difference[$i] -Column $difEmail
                $results.Add((New-ComparePlanRow -Values @{
                            Identity                     = if ($extraUpn) { $extraUpn } else { $extraSmtp }
                            Status                       = 'Extra'
                            Detail                       = 'Present in the destination inventory but not referenced by any plan target.'
                            DestinationUserPrincipalName = $extraUpn
                            DestinationPrimarySmtp       = $extraSmtp
                        }))
            }
        }
    }
    else {
        $reference = @(Import-MigrationCsv -Path $ReferenceCsv)
        $refColumns = Resolve-CompareColumnSet -Available @($reference[0].PSObject.Properties.Name) -Side 'reference'

        Write-MigrationLog -Message 'Resolved columns:' -Level INFO
        foreach ($side in @(@{ Label = 'Reference '; Set = $refColumns }, @{ Label = 'Difference'; Set = $difColumns })) {
            Write-MigrationLog -Message ('  {0} -> UPN:{1} Email:{2} First:{3} Last:{4} Name:{5}' -f
                $side.Label, $side.Set.Upn, $side.Set.Email, $side.Set.First, $side.Set.Last, $side.Set.Name) -Level INFO
        }

        if ($DryRun) {
            $results.Add([pscustomobject][ordered]@{
                    Identity = $ReferenceCsv
                    Action   = 'CompareUsers'
                    Status   = 'Planned'
                    Detail   = ("Would compare $($reference.Count) reference row(s) against $($difference.Count) " +
                        "difference row(s) at a similarity threshold of $SimilarityThreshold.")
                })
        }
        else {
            # Pre-normalise the difference set once - the inner loop runs
            # reference x difference times and re-lowering strings there is the
            # difference between seconds and minutes on a real tenant export.
            $difIndex = @(foreach ($d in $difference) {
                    $email = Get-CompareValue -Record $d -Column $difColumns.Email -Normalize
                    [pscustomobject]@{
                        Record    = $d
                        Upn       = Get-CompareValue -Record $d -Column $difColumns.Upn -Normalize
                        Email     = $email
                        LocalPart = ($email -split '@')[0]
                        First     = Get-CompareValue -Record $d -Column $difColumns.First -Normalize
                        LastName  = Get-CompareValue -Record $d -Column $difColumns.Last -Normalize
                        Name      = Get-CompareValue -Record $d -Column $difColumns.Name -Normalize
                    }
                })

            $index = 0
            foreach ($ref in $reference) {
                $index++
                Write-Progress -Activity 'Comparing users' `
                    -Status "$index of $($reference.Count)" `
                    -PercentComplete (($index / [math]::Max($reference.Count, 1)) * 100)

                $rUpn = Get-CompareValue -Record $ref -Column $refColumns.Upn -Normalize
                $rEmail = Get-CompareValue -Record $ref -Column $refColumns.Email -Normalize
                $rFirst = Get-CompareValue -Record $ref -Column $refColumns.First -Normalize
                $rLast = Get-CompareValue -Record $ref -Column $refColumns.Last -Normalize
                $rName = Get-CompareValue -Record $ref -Column $refColumns.Name -Normalize
                $rLocal = ($rEmail -split '@')[0]

                $bestScore = -1
                $bestMatch = $null
                $bestCriteria = @()
                $bestStatus = 'No Match'

                foreach ($dif in $difIndex) {
                    $criteria = [System.Collections.Generic.List[string]]::new()
                    $score = 0
                    $isExact = $false

                    if ($rUpn -and $dif.Upn -and $rUpn -eq $dif.Upn) {
                        $criteria.Add('UPN'); $score += 100; $isExact = $true
                    }
                    if ($rEmail -and $dif.Email -and $rEmail -eq $dif.Email) {
                        $criteria.Add('Email'); $score += 100; $isExact = $true
                    }
                    if ($rName -and $dif.Name -and $rName -eq $dif.Name) {
                        $criteria.Add('DisplayName'); $score += 40
                    }
                    if ($rFirst -and $rLast -and $dif.First -and $dif.LastName -and
                        $rFirst -eq $dif.First -and $rLast -eq $dif.LastName) {
                        $criteria.Add('FirstName+LastName'); $score += 40
                    }
                    if ($rLocal -and $dif.LocalPart -and $rLocal -eq $dif.LocalPart) {
                        $criteria.Add('EmailLocalPart'); $score += 25
                    }

                    # Fuzzy display-name similarity, only worth checking if not already exact.
                    if (-not $isExact -and $rName -and $dif.Name) {
                        $sim = Get-StringSimilarity -A $rName -B $dif.Name
                        if ($sim -ge $SimilarityThreshold) {
                            $criteria.Add("SimilarName($sim)"); $score += [int]($sim * 20)
                        }
                    }

                    if ($score -gt $bestScore -and $criteria.Count -gt 0) {
                        $bestScore = $score
                        $bestMatch = $dif.Record
                        $bestCriteria = $criteria.ToArray()
                        $bestStatus = if ($isExact) { 'Exact Match' } else { 'Partial Match' }
                    }
                }

                $matchedOn = ($bestCriteria -join '; ')
                $sourceUpn = Get-CompareValue -Record $ref -Column $refColumns.Upn
                $sourceEmail = Get-CompareValue -Record $ref -Column $refColumns.Email

                $results.Add([pscustomobject][ordered]@{
                        Identity           = if ($sourceUpn) { $sourceUpn } else { $sourceEmail }
                        Action             = 'CompareUsers'
                        Status             = $bestStatus
                        Detail             = if ($matchedOn) { "Matched on $matchedOn." } else { 'No candidate met any match criterion.' }
                        MatchedOn          = $matchedOn
                        MatchScore         = if ($bestScore -lt 0) { 0 } else { $bestScore }
                        Source_DisplayName = Get-CompareValue -Record $ref -Column $refColumns.Name
                        Source_UPN         = $sourceUpn
                        Source_Email       = $sourceEmail
                        Source_FirstName   = Get-CompareValue -Record $ref -Column $refColumns.First
                        Source_LastName    = Get-CompareValue -Record $ref -Column $refColumns.Last
                        Target_DisplayName = Get-CompareValue -Record $bestMatch -Column $difColumns.Name
                        Target_UPN         = Get-CompareValue -Record $bestMatch -Column $difColumns.Upn
                        Target_Email       = Get-CompareValue -Record $bestMatch -Column $difColumns.Email
                        Target_FirstName   = Get-CompareValue -Record $bestMatch -Column $difColumns.First
                        Target_LastName    = Get-CompareValue -Record $bestMatch -Column $difColumns.Last
                    })
            }

            Write-Progress -Activity 'Comparing users' -Completed
        }
    }

    $null = Export-MigrationResult -Rows $results.ToArray() -Name $resultName
}
catch {
    Write-MigrationLog -Message "Fatal: $($_.Exception.Message)" -Level ERROR
    $exitCode = 1
}

#endregion ---------------------------------------------------------------------

#region Cleanup ----------------------------------------------------------------

exit (Complete-MigrationRun -ExitCode $exitCode)

#endregion ---------------------------------------------------------------------
