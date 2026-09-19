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

        An empty report still produces a file: with -Columns, a header-only CSV carrying
        exactly those columns (nothing under the header) - so a caller whose header names
        are a contract with a downstream reader (New-MigrationIdentityPlan's optional-CSV
        columns, say) never sees the shape of that contract change just because the tenant
        had nothing of that kind. Without -Columns the file gets one informational row
        instead: evidence that the enumeration ran and found nothing, so a downstream
        Import-Csv does not fall over on a zero-byte file either way.

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

    .PARAMETER Columns
        The column names to use when -Rows is empty. When given, an empty report is a
        header-only CSV with exactly these columns instead of the single Info row - use
        this when the file's header is itself a contract a downstream reader checks. Ignored
        when -Rows has at least one row: the row's own properties are the header then.

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
        Export-MigrationReport -Rows @() -Name 'SharedMailboxes' -Columns @('PrimarySmtpAddress', 'DisplayName')

        Writes a header-only CSV ("PrimarySmtpAddress","DisplayName" and nothing under it)
        instead of a single Info row.

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

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Columns,

        [switch]$SuppressInDryRun,

        [datetime]$Timestamp
    )

    $run = Get-MigrationRunContext
    $data = @($Rows)
    $count = $data.Count
    $headerColumns = @($Columns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $headerOnly = ($count -eq 0 -and $headerColumns.Count -gt 0)

    # Checked, and returned from, before the output directory is created: a dry run that
    # suppresses this report must not leave behind a folder it never wrote into.
    if ($SuppressInDryRun -and $run -and $run.DryRun) {
        $shape = if ($headerOnly) { "$count row(s), header only" } else { "$count row(s)" }
        Write-MigrationLog -Message "[DRYRUN] Would write $Name report ($shape)" -Level WARNING
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

    if ($headerOnly) {
        # The header line Export-Csv would have written for a typed, empty collection whose
        # columns were $headerColumns - so a populated and an empty run of the same report
        # are one Import-Csv contract, never two. A literal quote in a column name is escaped
        # the same way Export-Csv escapes one, even though every caller today passes plain
        # identifiers with no quotes to escape.
        $quotedColumns = @($headerColumns | ForEach-Object { $_ -replace '"', '""' })
        $headerLine = '"' + ($quotedColumns -join '","') + '"'
        try {
            Set-Content -LiteralPath $filePath -Value $headerLine -Encoding utf8 -ErrorAction Stop
        }
        catch {
            throw "Could not write the report '$filePath': $($_.Exception.Message)"
        }
        Write-MigrationLog -Message "$Name report written to $filePath ($count row(s), header only)" -Level SUCCESS
        return $filePath
    }

    if ($count -eq 0) {
        $data = @([pscustomobject]@{ Info = "No $Name records found." })
    }

    # Sanitised once, here, so a source value that happens to start with a formula-triggering
    # character never reaches a spreadsheet as a live formula.
    $data = @($data | ForEach-Object { ConvertTo-MigrationSafeRow -Row $_ })

    try {
        $data | Export-Csv -LiteralPath $filePath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
    }
    catch {
        throw "Could not write the report '$filePath': $($_.Exception.Message)"
    }

    Write-MigrationLog -Message "$Name report written to $filePath ($count row(s))" -Level SUCCESS
    return $filePath
}
