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

        The filename is `<Prefix>_<Name>_<timestamp>.csv`, with `-<Suffix>` appended to the
        name when one is given - `Contoso_TeamsPhoneNumbers-Unassigned_20260908-143000.csv`.
        The prefix and its underscore are omitted when the run has no prefix.

        Everything comes from the run context, so a caller only has to name the report.
        Without a run context the module's default output root is used, which is what lets
        these functions be exercised in tests without standing up a run.

        An empty report still produces a file with one informational row: the file is
        evidence that the enumeration ran and found nothing, and a downstream Import-Csv
        does not fall over on a zero-byte file.

        The file is written in a dry run as well. DryRun means 'change nothing in the
        tenant'; a report is a read, and suppressing it would leave the rehearsal with
        nothing to review.

    .PARAMETER Rows
        The report rows. May be empty.

    .PARAMETER Name
        The report name, for example 'DomainReferences' or 'Mailboxes'.

    .PARAMETER Suffix
        An optional qualifier appended to the name after a hyphen, for example 'Unassigned'
        or 'Blockers'.

    .EXAMPLE
        $path = Export-MigrationReport -Rows $references -Name 'DomainReferences'

        Writes <Prefix>_DomainReferences_<timestamp>.csv and returns its full path.

    .EXAMPLE
        Export-MigrationReport -Rows $spare -Name 'TeamsPhoneNumbers' -Suffix 'Unassigned'

        Writes <Prefix>_TeamsPhoneNumbers-Unassigned_<timestamp>.csv.

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
        [string]$Suffix
    )

    $run = Get-MigrationRunContext
    $directory = if ($run) { [string]$run.OutputDirectory } else { Get-MigrationDefaultOutputRoot }
    $prefix = if ($run) { [string]$run.Prefix } else { '' }

    if (-not (Test-Path -LiteralPath $directory)) {
        try {
            $null = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
        }
        catch {
            throw "Could not create the report directory '$directory': $($_.Exception.Message)"
        }
    }

    $leader = if ($prefix) { "${prefix}_" } else { '' }
    $qualifier = if ([string]::IsNullOrWhiteSpace($Suffix)) { '' } else { "-$($Suffix.Trim())" }
    $fileName = '{0}{1}{2}_{3}.csv' -f $leader, $Name, $qualifier, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $filePath = Join-Path -Path $directory -ChildPath $fileName

    $data = @($Rows)
    $count = $data.Count
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
