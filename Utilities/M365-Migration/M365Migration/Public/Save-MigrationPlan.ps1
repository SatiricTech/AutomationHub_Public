function Save-MigrationPlan {
    <#
    .SYNOPSIS
        Writes identity-plan rows back to the plan file in canonical column order.

    .DESCRIPTION
        Writers update the plan in place - TargetObjectId, MailboxProvisioned,
        ProvisionStatus - so that the file stays the single record of where the migration
        has got to. Writing the full canonical column set every time means an operator
        who deleted a column in Excel gets it back rather than breaking the next phase.

        A backup is written to '<Path>.bak' before the first save of each run and not
        again afterwards, so the .bak holds the state the run started from rather than
        the state one row ago. Initialize-MigrationRun resets that tracking.

        This is a writer, so it honours -WhatIf and -Confirm.

    .PARAMETER Path
        The plan file to overwrite.

    .PARAMETER Rows
        The rows to write. Missing columns are written as empty cells.

    .EXAMPLE
        Save-MigrationPlan -Path .\IdentityPlan.csv -Rows $plan

        Writes the plan back, taking a .bak first if this is the run's first save.

    .EXAMPLE
        Save-MigrationPlan -Path .\IdentityPlan.csv -Rows $plan -WhatIf

        Reports what would be written without touching the file.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Rows
    )

    $fullPath = $Path
    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        $fullPath = $resolved.ProviderPath
    }
    catch {
        # The plan may not exist yet on a first write; the literal path is then correct.
        Write-MigrationLog -Message "Plan file '$Path' does not exist yet; it will be created." -Level DEBUG
    }

    if ($null -eq $script:MigrationPlanBackups) {
        $script:MigrationPlanBackups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }

    if ((Test-Path -LiteralPath $fullPath -PathType Leaf) -and -not $script:MigrationPlanBackups.Contains($fullPath)) {
        $backupPath = "$fullPath.bak"
        if ($PSCmdlet.ShouldProcess($backupPath, 'Write plan backup')) {
            try {
                Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force -ErrorAction Stop
                [void]$script:MigrationPlanBackups.Add($fullPath)
                Write-MigrationLog -Message "Plan backup written to $backupPath" -Level INFO
            }
            catch {
                throw "Could not back up the identity plan to '$backupPath': $($_.Exception.Message)"
            }
        }
    }

    $normalised = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Rows)) {
        $ordered = [ordered]@{}
        foreach ($column in $script:MigrationPlanColumns) {
            $value = Get-MigrationCsvValue -Row $row -Name $column -Default ''
            $ordered[$column] = $value
        }
        $normalised.Add([pscustomobject]$ordered)
    }

    if ($PSCmdlet.ShouldProcess($fullPath, "Write $($normalised.Count) plan row(s)")) {
        try {
            $normalised | Export-Csv -LiteralPath $fullPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop
        }
        catch {
            throw "Could not write the identity plan '$fullPath': $($_.Exception.Message)"
        }
        Write-MigrationLog -Message "Saved $($normalised.Count) plan row(s) to $fullPath" -Level SUCCESS
    }
}
