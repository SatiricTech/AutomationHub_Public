#Requires -Version 7.4

<#
.SYNOPSIS
    Compares user data between two tenants - either fuzzily between two CSV
    exports, or exactly between a destination inventory and the identity plan.

.DESCRIPTION
    The script has two modes.

    CSV mode (default) reads a reference CSV and a difference CSV and, for every
    user in the reference CSV, finds the best-matching user in the difference
    CSV. It writes one row per reference user with:

      - Status   : 'Exact Match', 'Partial Match' or 'No Match'
      - MatchedOn: the criteria that matched (UPN, Email, DisplayName,
                   FirstName+LastName, EmailLocalPart, SimilarName)
      - the matched target user's identity columns alongside the source's

    Column handling is delegated to Import-MigrationCsv, so the toolkit's alias
    vocabulary (UPN / UserPrincipalName, Email / PrimaryEmail / Mail,
    GivenName / FirstName, Surname / LastName, Name / DisplayName ...) is
    resolved for you. Any column can still be named explicitly with the
    -*Column parameters.

    Match logic (unchanged from earlier versions of this script):
      - Exact Match  : UPN equal OR primary email equal.
      - Partial Match: display name equal, first+last equal, email local-part
                       equal, or a close (Levenshtein) display-name similarity.
      - No Match     : nothing above the similarity threshold.

    Plan mode (-PlanPath) is the post-cutover verification pass: it compares a
    destination Users inventory CSV against the identity plan's
    TargetUserPrincipalName / TargetPrimarySmtp columns *exactly* - no fuzzy
    matching - and reports:

      - Match    : the plan's target UPN exists and its primary SMTP agrees
      - Mismatch : the object exists but its primary SMTP differs from the plan
                   (or the expected SMTP is held by a different UPN)
      - Missing  : the plan expects a target object that the destination has not
      - Extra    : the destination holds an object no plan row points at
      - Skipped  : a plan row that carries no target UPN, or is marked Excluded

    Both modes are fully local - the script reads and writes CSVs only and never
    connects to Microsoft 365.

.PARAMETER ReferenceCsv
    CSV mode. Path to the first CSV (the "source" / left side).

.PARAMETER DifferenceCsv
    Path to the second CSV to match against. In CSV mode this is the "target" /
    right side; in plan mode it is the destination tenant's Users inventory.

.PARAMETER PlanPath
    Plan mode. Path to IdentityPlan.csv. Its TargetUserPrincipalName and
    TargetPrimarySmtp columns become the expected destination state.

.PARAMETER Wave
    Plan mode. Only compare plan rows in these waves. The whole destination CSV
    is still read, so objects belonging to other waves are reported as Extra -
    filter the inventory too if you want a wave-only picture.

.PARAMETER ObjectType
    Plan mode. Only compare plan rows of these object types (User, Shared,
    Room ...).

.PARAMETER SimilarityThreshold
    CSV mode. Display-name similarity (0.0 - 1.0) at/above which two
    non-identical names are treated as a "SimilarName" partial match.
    Default 0.85.

.PARAMETER OutputPath
    Root directory for the log and the comparison CSV. Defaults to
    %LOCALAPPDATA%\Migration-Automations on Windows, ~/Migration-Automations
    elsewhere.

.PARAMETER Prefix
    Client/run label. When given, files land in <root>\<Prefix>\ and file names
    start with <Prefix>_.

.PARAMETER UpnColumn
    Explicit header name for the user principal name column, used when
    Import-MigrationCsv's alias resolution picks the wrong header (or the header
    is not in the alias vocabulary at all).

.PARAMETER EmailColumn
    Explicit header name for the primary SMTP / email column.

.PARAMETER FirstNameColumn
    CSV mode. Explicit header name for the first name column.

.PARAMETER LastNameColumn
    CSV mode. Explicit header name for the last name column.

.PARAMETER DisplayNameColumn
    CSV mode. Explicit header name for the display name column.

.PARAMETER DryRun
    Preview only - load the inputs, report the resolved columns and row counts,
    and write a -DryRun_ results file holding a single Planned row instead of
    the comparison.

.PARAMETER Verbosity
    Console detail: Low (errors and successes), Medium (adds warnings) or High
    (everything). The log file always receives everything.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -ReferenceCsv .\Source-Users.csv -DifferenceCsv .\Target-Users.csv

    Fuzzy-matches every source user against the destination export and writes
    Compare-UserData-Results_<timestamp>.csv to the standard output root.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -ReferenceCsv .\Source-Users.csv -DifferenceCsv .\Target-Users.csv `
        -SimilarityThreshold 0.92 -Prefix Contoso -Verbosity High

    Tightens the fuzzy display-name threshold and files the output under the
    Contoso folder.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -PlanPath .\IdentityPlan.csv -DifferenceCsv .\Destination-Users.csv -Wave 1

    Post-cutover check for wave 1: every plan target UPN and primary SMTP is
    compared exactly against the destination inventory, and anything the
    destination holds that the plan does not is reported as Extra.

.EXAMPLE
    .\Compare-MigrationUserData.ps1 -PlanPath .\IdentityPlan.csv -DifferenceCsv .\Destination-Users.csv `
        -UpnColumn 'Primary Email Address' -DryRun

    Confirms which columns would be read from a non-standard export before
    running the comparison for real.

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

# Canonical property names Import-MigrationCsv produces for the fields this
# script matches on. The -*Column parameters override them per field.
$script:CanonicalUpn = 'UserPrincipalName'
$script:CanonicalEmail = 'PrimarySmtpAddress'
$script:CanonicalFirst = 'FirstName'
$script:CanonicalLast = 'LastName'
$script:CanonicalName = 'DisplayName'

# This script is entirely offline: no Graph scopes and no Exchange roles are
# required, and no connection is ever opened.

#endregion ---------------------------------------------------------------------

#region Functions --------------------------------------------------------------

function Resolve-CompareColumn {
    <#
        Picks the property name to read for one field. An operator override wins
        when the imported rows actually carry it; otherwise the canonical name
        Import-MigrationCsv resolved the header to is used. Returns $null when
        the field is absent altogether, which every caller treats as "no value".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Available,
        [Parameter(Mandatory)][string]$Canonical,
        [AllowNull()][AllowEmptyString()][string]$Override,
        [Parameter(Mandatory)][string]$Side
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $hit = @($Available | Where-Object { $_ -ieq $Override.Trim() }) | Select-Object -First 1
        if ($hit) { return $hit }
        Write-MigrationLog -Message ("Override column '$Override' is not present in the $Side CSV after alias " +
            "resolution - falling back to '$Canonical'.") -Level WARNING
    }

    $hit = @($Available | Where-Object { $_ -ieq $Canonical }) | Select-Object -First 1
    if ($hit) { return $hit }
    return $null
}

function Get-NormalizedValue {
    <# Lower-cased, trimmed read of one column; missing column or value gives ''. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Record,
        [AllowNull()][AllowEmptyString()][string]$Column
    )

    if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Column)) { return '' }
    $property = $Record.PSObject.Properties[$Column]
    if (-not $property -or $null -eq $property.Value) { return '' }
    return ([string]$property.Value).Trim().ToLowerInvariant()
}

function Get-RawValue {
    <# Trimmed read of one column preserving case, for the output columns. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Record,
        [AllowNull()][AllowEmptyString()][string]$Column
    )

    if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Column)) { return '' }
    $property = $Record.PSObject.Properties[$Column]
    if (-not $property -or $null -eq $property.Value) { return '' }
    return ([string]$property.Value).Trim()
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

    if ([string]::IsNullOrEmpty($A) -and [string]::IsNullOrEmpty($B)) { return 0.0 }
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return 0.0 }
    if ($A -eq $B) { return 1.0 }

    $lenA = $A.Length
    $lenB = $B.Length
    $d = [int[,]]::new(($lenA + 1), ($lenB + 1))
    for ($i = 0; $i -le $lenA; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $lenB; $j++) { $d[0, $j] = $j }

    for ($i = 1; $i -le $lenA; $i++) {
        for ($j = 1; $j -le $lenB; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $d[$i, $j] = [math]::Min([math]::Min($d[($i - 1), $j] + 1, $d[$i, ($j - 1)] + 1), $d[($i - 1), ($j - 1)] + $cost)
        }
    }
    $distance = $d[$lenA, $lenB]
    $maxLen = [math]::Max($lenA, $lenB)
    return [math]::Round(1.0 - ($distance / $maxLen), 4)
}

function Get-EmailLocalPart {
    <# The part before the '@' - the last thing left to match on after a rebrand. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Email)

    if ([string]::IsNullOrWhiteSpace($Email)) { return '' }
    return ($Email -split '@')[0]
}

#endregion ---------------------------------------------------------------------

#region Main -------------------------------------------------------------------

$exitCode = 0
$run = Initialize-MigrationRun -ScriptName 'Compare-MigrationUserData' -OutputPath $OutputPath `
    -Prefix $Prefix -DryRun:$DryRun -Verbosity $Verbosity -BoundParameters $PSBoundParameters
$null = $run

try {
    $isPlanMode = $PSCmdlet.ParameterSetName -eq 'Plan'
    $resultName = if ($isPlanMode) { 'Compare-UserData-Plan' } else { 'Compare-UserData' }
    $results = [System.Collections.Generic.List[object]]::new()

    # ---- Difference side (both modes) ----------------------------------------
    $difference = @(Import-MigrationCsv -Path $DifferenceCsv)
    $difHeaders = @($difference[0].PSObject.Properties.Name)
    $difUpn = Resolve-CompareColumn -Available $difHeaders -Canonical $script:CanonicalUpn -Override $UpnColumn -Side 'difference'
    $difEmail = Resolve-CompareColumn -Available $difHeaders -Canonical $script:CanonicalEmail -Override $EmailColumn -Side 'difference'

    if ($isPlanMode) {
        # -------------------------------------------------------------------
        # Plan mode: exact comparison against the plan's Target* columns.
        # -------------------------------------------------------------------
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
                $key = Get-NormalizedValue -Record $difference[$i] -Column $difUpn
                if ($key -and -not $destByUpn.ContainsKey($key)) { $destByUpn[$key] = $i }
                $mail = Get-NormalizedValue -Record $difference[$i] -Column $difEmail
                if ($mail -and -not $destByEmail.ContainsKey($mail)) { $destByEmail[$mail] = $i }
            }

            foreach ($planRow in $planRows) {
                $targetUpn = Get-MigrationCsvValue -Row $planRow -Name 'TargetUserPrincipalName' -Default ''
                $targetSmtp = Get-MigrationCsvValue -Row $planRow -Name 'TargetPrimarySmtp' -Default ''
                $sourceUpn = Get-MigrationCsvValue -Row $planRow -Name 'SourceUserPrincipalName' -Default ''
                $planStatus = Get-MigrationCsvValue -Row $planRow -Name 'PlanStatus' -Default ''
                $planWave = Get-MigrationCsvValue -Row $planRow -Name 'Wave' -Default ''
                $planType = Get-MigrationCsvValue -Row $planRow -Name 'ObjectType' -Default ''

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
                    if ($destByUpn.ContainsKey($upnKey)) {
                        $index = $destByUpn[$upnKey]
                        [void]$seen.Add($index)
                        $destUpn = Get-RawValue -Record $difference[$index] -Column $difUpn
                        $destSmtp = Get-RawValue -Record $difference[$index] -Column $difEmail

                        if (-not $targetSmtp) {
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
                    elseif ($targetSmtp -and $destByEmail.ContainsKey($targetSmtp.ToLowerInvariant())) {
                        $index = $destByEmail[$targetSmtp.ToLowerInvariant()]
                        [void]$seen.Add($index)
                        $destUpn = Get-RawValue -Record $difference[$index] -Column $difUpn
                        $destSmtp = Get-RawValue -Record $difference[$index] -Column $difEmail
                        $status = 'Mismatch'
                        $detail = "No destination object has UPN '$targetUpn'; '$destUpn' holds the expected primary SMTP '$targetSmtp'."
                    }
                    else {
                        $status = 'Missing'
                        $detail = "No destination object matches the planned UPN '$targetUpn'" +
                        $(if ($targetSmtp) { " or primary SMTP '$targetSmtp'." } else { '.' })
                    }
                }

                $results.Add([pscustomobject][ordered]@{
                        Identity                    = if ($targetUpn) { $targetUpn } else { $sourceUpn }
                        Action                      = 'CompareToPlan'
                        Status                      = $status
                        Detail                      = $detail
                        PlanTargetUserPrincipalName = $targetUpn
                        PlanTargetPrimarySmtp       = $targetSmtp
                        DestinationUserPrincipalName = $destUpn
                        DestinationPrimarySmtp      = $destSmtp
                        SourceUserPrincipalName     = $sourceUpn
                        Wave                        = $planWave
                        ObjectType                  = $planType
                        PlanStatus                  = $planStatus
                    })
            }

            # Anything the destination holds that no plan row claimed. These are the
            # rows that turn "the migration is complete" into "what are these?".
            for ($i = 0; $i -lt $difference.Count; $i++) {
                if ($seen.Contains($i)) { continue }
                $extraUpn = Get-RawValue -Record $difference[$i] -Column $difUpn
                $extraSmtp = Get-RawValue -Record $difference[$i] -Column $difEmail
                $results.Add([pscustomobject][ordered]@{
                        Identity                    = if ($extraUpn) { $extraUpn } else { $extraSmtp }
                        Action                      = 'CompareToPlan'
                        Status                      = 'Extra'
                        Detail                      = 'Present in the destination inventory but not referenced by any plan target.'
                        PlanTargetUserPrincipalName = ''
                        PlanTargetPrimarySmtp       = ''
                        DestinationUserPrincipalName = $extraUpn
                        DestinationPrimarySmtp      = $extraSmtp
                        SourceUserPrincipalName     = ''
                        Wave                        = ''
                        ObjectType                  = ''
                        PlanStatus                  = ''
                    })
            }
        }
    }
    else {
        # -------------------------------------------------------------------
        # CSV mode: best-match search with the fuzzy display-name fallback.
        # -------------------------------------------------------------------
        $reference = @(Import-MigrationCsv -Path $ReferenceCsv)
        $refHeaders = @($reference[0].PSObject.Properties.Name)

        $cols = @{
            RefUpn   = Resolve-CompareColumn -Available $refHeaders -Canonical $script:CanonicalUpn -Override $UpnColumn -Side 'reference'
            RefEmail = Resolve-CompareColumn -Available $refHeaders -Canonical $script:CanonicalEmail -Override $EmailColumn -Side 'reference'
            RefFirst = Resolve-CompareColumn -Available $refHeaders -Canonical $script:CanonicalFirst -Override $FirstNameColumn -Side 'reference'
            RefLast  = Resolve-CompareColumn -Available $refHeaders -Canonical $script:CanonicalLast -Override $LastNameColumn -Side 'reference'
            RefName  = Resolve-CompareColumn -Available $refHeaders -Canonical $script:CanonicalName -Override $DisplayNameColumn -Side 'reference'
            DifUpn   = $difUpn
            DifEmail = $difEmail
            DifFirst = Resolve-CompareColumn -Available $difHeaders -Canonical $script:CanonicalFirst -Override $FirstNameColumn -Side 'difference'
            DifLast  = Resolve-CompareColumn -Available $difHeaders -Canonical $script:CanonicalLast -Override $LastNameColumn -Side 'difference'
            DifName  = Resolve-CompareColumn -Available $difHeaders -Canonical $script:CanonicalName -Override $DisplayNameColumn -Side 'difference'
        }

        Write-MigrationLog -Message 'Resolved columns:' -Level INFO
        Write-MigrationLog -Message ('  Reference  -> UPN:{0} Email:{1} First:{2} Last:{3} Name:{4}' -f
            $cols.RefUpn, $cols.RefEmail, $cols.RefFirst, $cols.RefLast, $cols.RefName) -Level INFO
        Write-MigrationLog -Message ('  Difference -> UPN:{0} Email:{1} First:{2} Last:{3} Name:{4}' -f
            $cols.DifUpn, $cols.DifEmail, $cols.DifFirst, $cols.DifLast, $cols.DifName) -Level INFO

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
            $difIndex = foreach ($d in $difference) {
                [pscustomobject]@{
                    Record   = $d
                    Upn      = Get-NormalizedValue -Record $d -Column $cols.DifUpn
                    Email    = Get-NormalizedValue -Record $d -Column $cols.DifEmail
                    First    = Get-NormalizedValue -Record $d -Column $cols.DifFirst
                    LastName = Get-NormalizedValue -Record $d -Column $cols.DifLast
                    Name     = Get-NormalizedValue -Record $d -Column $cols.DifName
                }
            }
            $difIndex = @($difIndex)

            $index = 0
            foreach ($ref in $reference) {
                $index++
                Write-Progress -Activity 'Comparing users' `
                    -Status "$index of $($reference.Count)" `
                    -PercentComplete (($index / [math]::Max($reference.Count, 1)) * 100)

                $rUpn = Get-NormalizedValue -Record $ref -Column $cols.RefUpn
                $rEmail = Get-NormalizedValue -Record $ref -Column $cols.RefEmail
                $rFirst = Get-NormalizedValue -Record $ref -Column $cols.RefFirst
                $rLast = Get-NormalizedValue -Record $ref -Column $cols.RefLast
                $rName = Get-NormalizedValue -Record $ref -Column $cols.RefName
                $rLocal = Get-EmailLocalPart -Email $rEmail

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
                    if ($rLocal -and (Get-EmailLocalPart -Email $dif.Email) -and
                        $rLocal -eq (Get-EmailLocalPart -Email $dif.Email)) {
                        $criteria.Add('EmailLocalPart'); $score += 25
                    }

                    # Fuzzy display-name similarity (only worth checking if not already exact).
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
                $sourceUpn = Get-RawValue -Record $ref -Column $cols.RefUpn
                $sourceEmail = Get-RawValue -Record $ref -Column $cols.RefEmail

                $results.Add([pscustomobject][ordered]@{
                        Identity           = if ($sourceUpn) { $sourceUpn } else { $sourceEmail }
                        Action             = 'CompareUsers'
                        Status             = $bestStatus
                        Detail             = if ($matchedOn) { "Matched on $matchedOn." } else { 'No candidate met any match criterion.' }
                        MatchedOn          = $matchedOn
                        MatchScore         = if ($bestScore -lt 0) { 0 } else { $bestScore }
                        Source_DisplayName = Get-RawValue -Record $ref -Column $cols.RefName
                        Source_UPN         = $sourceUpn
                        Source_Email       = $sourceEmail
                        Source_FirstName   = Get-RawValue -Record $ref -Column $cols.RefFirst
                        Source_LastName    = Get-RawValue -Record $ref -Column $cols.RefLast
                        Target_DisplayName = Get-RawValue -Record $bestMatch -Column $cols.DifName
                        Target_UPN         = Get-RawValue -Record $bestMatch -Column $cols.DifUpn
                        Target_Email       = Get-RawValue -Record $bestMatch -Column $cols.DifEmail
                        Target_FirstName   = Get-RawValue -Record $bestMatch -Column $cols.DifFirst
                        Target_LastName    = Get-RawValue -Record $bestMatch -Column $cols.DifLast
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
