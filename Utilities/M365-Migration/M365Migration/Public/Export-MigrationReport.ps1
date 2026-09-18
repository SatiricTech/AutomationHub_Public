function Export-MigrationReport {
    <#
    .SYNOPSIS
        Writes a supporting CSV - an inventory tab, a blockers list, a reference report -
        into the run's output folder.

    .DESCRIPTION
        The sibling of Export-MigrationResult, for the files that describe the tenant
        rather than what the script did to it. They share the folder, the prefix and the
        timestamp convention so a migration folder reads as one set, but a report has no
        fixed column shape and no Status column, so there is no summary block to print.

        The filename comes from Get-MigrationOutputPath, the single owner of the output
        filename contract: `<Prefix>_<Name>_<timestamp>.csv`, with `-<Suffix>` appended to
        the name when one is given - `Contoso_TeamsPhoneNumbers-Unassigned_20260908-143000.csv`.
        The prefix and its underscore are omitted when the run has no prefix.

        Everything comes from the run context, so a caller only has to name the report.
        Without a run context the module's default output root is used, which is what lets
        these functions be exercised in tests without standing up a run.

        An empty report still produces a file with one informational row: the file is
        evidence that the enumeration ran and found nothing, and a downstream Import-Csv
        does not fall over on a zero-byte file.

        The file is written in a dry run as well, because DryRun means 'change nothing in
        the tenant' and a report is a read: suppressing it would leave the rehearsal with
        nothing to review. -SuppressInDryRun opts a specific report out of that rule for the
        rarer case where the report only describes a state the tenant does not have yet in
        a dry run - a rehearsal has nothing real to write, so nothing is written, and the
        directory it would have landed in is never created.

    .PARAMETER Rows
        The report rows. May be empty.

    .PARAMETER Name
        The report name, for example 'DomainReferences' or 'Mailboxes'.

    .PARAMETER Suffix
        An optional qualifier appended to the name after a hyphen, for example 'Unassigned'
        or 'Blockers'.

    .PARAMETER SuppressInDryRun
        Writes nothing and returns an empty string when the active run is a dry run. Use
        this for a report that is only useful once the tenant has actually changed - a
        rehearsal has nothing yet to report on, so the file would be an empty placeholder.

    .PARAMETER Timestamp
        The moment to encode in the filename. Defaults to the current time; pass the same
        value to several calls so their filenames share one stamp.

    .EXAMPLE
        $path = Export-MigrationReport -Rows $references -Name 'DomainReferences'

        Writes <Prefix>_DomainReferences_<timestamp>.csv and returns its full path.

    .EXAMPLE
        Export-MigrationReport -Rows $spare -Name 'TeamsPhoneNumbers' -Suffix 'Unassigned'

        Writes <Prefix>_TeamsPhoneNumbers-Unassigned_<timestamp>.csv.

    .EXAMPLE
        Export-MigrationReport -Rows $postMoveOnly -Name 'PostMove' -SuppressInDryRun

        In a dry run, writes nothing, logs a WARNING and returns ''. In a real run, writes
        the report as usual.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Suffix,

        [switch]$SuppressInDryRun,

        [datetime]$Timestamp
    )

    $run = Get-MigrationRunContext
    $data = @($Rows)
    $count = $data.Count

    # Checked, and returned from, before the output directory is created: a dry run that
    # suppresses this report must not leave behind a folder it never wrote into.
    if ($SuppressInDryRun -and $run -and $run.DryRun) {
        Write-MigrationLog -Message "[DRYRUN] Would write $Name report ($count row(s))" -Level WARNING
        return ''
    }

    $pathParams = @{ Name = $Name; Suffix = $Suffix }
    if ($PSBoundParameters.ContainsKey('Timestamp')) { $pathParams['Timestamp'] = $Timestamp }
    $filePath = Get-MigrationOutputPath @pathParams

    $directory = Split-Path -Path $filePath -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        try {
            $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
        }
        catch {
            throw "Could not create the report directory '$directory': $($_.Exception.Message)"
        }
    }

    if ($count -eq 0) {
        $data = @([pscustomobject]@{ Info = "No $Name records found." })
    }

    try {
        $data | Export-Csv -LiteralPath $filePath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
    }
    catch {
        throw "Could not write the report '$filePath': $($_.Exception.Message)"
    }

    Write-MigrationLog -Message "$Name report written to $filePath ($count row(s))" -Level SUCCESS
    return $filePath
}
