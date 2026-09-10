function Resolve-MigrationSkuMap {
    <#
    .SYNOPSIS
        Reads a source-to-target SKU mapping CSV into a lookup table.

    .DESCRIPTION
        Source and destination tenants rarely licence identically, so the plan needs an
        explicit statement of what each source SKU becomes. The file has two columns,
        SourceSkuPartNumber and TargetSkuPartNumber.

        A target of several SKUs is written semicolon-separated, so one source licence can
        fan out into a base plan plus an add-on. A blank target means "drop this licence"
        and maps to an empty array - an explicit decision recorded in the file, which is
        the point: an unmapped SKU is a question, a blank target is an answer.

        Duplicate source rows are an error rather than a last-one-wins merge, because a
        duplicate is almost always two people editing the same file with different intent.

    .PARAMETER Path
        The SKU map CSV.

    .EXAMPLE
        $map = Resolve-MigrationSkuMap -Path .\SkuMap.csv
        $map['ENTERPRISEPACK']

        Returns the target SKU part numbers for Office 365 E3.

    .EXAMPLE
        $map = Resolve-MigrationSkuMap -Path .\SkuMap.csv
        $map.Keys | Where-Object { $map[$_].Count -eq 0 }

        Lists the source SKUs that are deliberately dropped.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "SKU map not found: $Path"
    }

    try {
        $rows = @(Import-Csv -LiteralPath $Path -Encoding utf8 -ErrorAction Stop)
    }
    catch {
        throw "Could not read the SKU map '$Path': $($_.Exception.Message)"
    }

    if ($rows.Count -eq 0) {
        throw "The SKU map '$Path' contains no data rows."
    }

    $headers = @($rows[0].PSObject.Properties.Name | ForEach-Object { $_.Trim() })
    foreach ($required in @('SourceSkuPartNumber', 'TargetSkuPartNumber')) {
        if ($headers -notcontains $required) {
            throw "The SKU map '$Path' is missing the required column '$required'."
        }
    }

    $map = @{}
    $lineNumber = 1
    foreach ($row in $rows) {
        $lineNumber++
        $source = Get-MigrationCsvValue -Row $row -Name 'SourceSkuPartNumber' -Default ''
        if ([string]::IsNullOrWhiteSpace($source)) {
            throw "The SKU map '$Path' has an empty SourceSkuPartNumber on line $lineNumber."
        }
        if ($map.ContainsKey($source)) {
            throw "The SKU map '$Path' maps '$source' more than once (line $lineNumber). Remove the duplicate row."
        }

        $target = Get-MigrationCsvValue -Row $row -Name 'TargetSkuPartNumber' -Default ''
        $map[$source] = @(Split-MigrationList -Value $target)
    }

    $dropped = @($map.Keys | Where-Object { @($map[$_]).Count -eq 0 }).Count
    Write-MigrationLog -Message "Loaded $($map.Count) SKU mapping(s) from $Path ($dropped marked to drop)." -Level INFO
    return $map
}
