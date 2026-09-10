function Get-MigrationPlanAddressMap {
    <#
    .SYNOPSIS
        Builds the source-to-destination address lookup used by every writer.

    .DESCRIPTION
        A row exported from the source tenant names its object by whatever address
        Exchange or Graph happened to return - the primary SMTP most of the time, but an
        alias, a UPN, an object ID or a display name often enough to matter. Every one of
        those is registered as a key pointing at the row's destination address, so a
        lookup succeeds regardless of which form the inventory captured.

        The destination address is the first non-empty of TargetPrimarySmtp,
        TargetUserPrincipalName, InterimPrimarySmtp and InterimUserPrincipalName, which
        lets a script run either side of the vanity-domain cutover. -UseInterim reverses
        that preference for the window in which the destination objects still hold their
        .onmicrosoft.com addresses.

        Keys are matched case-insensitively. The first row to claim a key keeps it: a
        duplicate means two source objects claim the same address, which the planning
        phase already flagged as a Collision - overwriting here would only hide it.

        Pure function - no tenant calls.

    .PARAMETER Rows
        Plan rows from Import-MigrationPlan.

    .PARAMETER UseInterim
        Prefers the interim (routing-domain) addresses over the final target addresses.

    .EXAMPLE
        $map = Get-MigrationPlanAddressMap -Rows $planRows
        $map['jsmith@contoso.com']

        Returns john.smith@newco.com for a plan row whose source primary was jsmith@contoso.com.

    .EXAMPLE
        $map = Get-MigrationPlanAddressMap -Rows $planRows -UseInterim

        Maps to the destination's routing address, for a run made before the cutover.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The parameter is a set of rows and the plural reads correctly.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows,

        [switch]$UseInterim
    )

    $map = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    $targetColumns = if ($UseInterim) {
        @('InterimPrimarySmtp', 'InterimUserPrincipalName', 'TargetPrimarySmtp', 'TargetUserPrincipalName')
    }
    else {
        @('TargetPrimarySmtp', 'TargetUserPrincipalName', 'InterimPrimarySmtp', 'InterimUserPrincipalName')
    }

    foreach ($row in @($Rows)) {
        $target = ''
        foreach ($column in $targetColumns) {
            $candidate = ([string](Get-MigrationCsvValue -Row $row -Name $column -Default '')).Trim()
            if ($candidate) { $target = $candidate -replace '^(?i)smtp:', ''; break }
        }
        if (-not $target) { continue }

        $keys = [System.Collections.Generic.List[string]]::new()
        foreach ($column in @('SourceObjectId', 'SourceUserPrincipalName', 'SourcePrimarySmtp', 'DisplayName')) {
            $value = ([string](Get-MigrationCsvValue -Row $row -Name $column -Default '')).Trim()
            if ($value) { $keys.Add($value) }
        }
        foreach ($alias in (Split-MigrationList -Value (Get-MigrationCsvValue -Row $row -Name 'SourceAliases' -Default ''))) {
            $value = ([string]$alias).Trim() -replace '^(?i)smtp:', ''
            if ($value) { $keys.Add($value) }
        }

        foreach ($key in $keys) {
            if (-not $map.ContainsKey($key)) { $map[$key] = $target }
        }
    }

    return $map
}
