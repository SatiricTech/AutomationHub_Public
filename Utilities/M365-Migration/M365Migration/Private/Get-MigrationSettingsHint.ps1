function Get-MigrationSettingsHint {
    <#
    .SYNOPSIS
        Explains what leaving one settings key blank will mean, in a few words.

    .DESCRIPTION
        Three of the domain keys are blank far more often than not, and in each case the blank
        means something specific rather than "not filled in yet" (Docs/Workbench-Design.md,
        section 4). A form that does not say so invites an operator to type the target domain
        into all three, which is how a migration ends up releasing a domain it meant to keep.

          Domains.Release  blank = the same domain as Target, i.e. the vanity domain moves
                           with the users. That is the common case, not the rule, which is
                           exactly why it is worth saying out loud.
          Domains.Smtp     blank = the same domain as Target.
          Domains.Interim  blank = not needed. Where the destination inventory already lists
                           the target domain as verified, the hint says so, because that is
                           the fact the operator would otherwise have to go and look up
                           (KnownDocGaps #6).

        The hint is read from the destination domain inventory the workspace already holds, so
        it costs nothing and cannot be out of date in a way the rest of the board is not.

    .PARAMETER Workspace
        The scan from Get-MigrationWorkspace.

    .PARAMETER Key
        The dotted settings key.

    .PARAMETER Document
        The settings document being edited, when there is one part-filled in memory. Its
        Domains.Target is what the Interim hint is judged against; without it the value on
        disk is used.

    .EXAMPLE
        Get-MigrationSettingsHint -Workspace $ws -Key 'Domains.Interim'

        Returns 'blank - newco.com is already verified in the destination' where it is.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject]$Workspace,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [AllowNull()]
        $Document
    )

    if ($Key -in @('Domains.Release', 'Domains.Smtp')) { return 'blank = same as Target' }
    if ($Key -ne 'Domains.Interim') { return '' }

    $target = ''
    if ($null -ne $Document) {
        $domains = Get-MigrationProperty -InputObject $Document -Name 'Domains' -Default $null
        $target = [string](Get-MigrationProperty -InputObject $domains -Name 'Target' -Default '')
    }
    if (-not $target) {
        $target = [string](Get-MigrationSettingsLeaf -Workspace $Workspace -Key 'Domains.Target')
    }
    if (-not $target) { return 'blank = not needed' }

    $inventory = @(@($Workspace.Artefacts) |
            Where-Object { $_.Prefix -eq 'Destination' -and $_.Name -eq 'Domains' -and $_.Extension -eq 'csv' } |
            Sort-Object -Property Timestamp -Descending)
    if ($inventory.Count -eq 0) { return 'blank = not needed' }

    try { $rows = @(Import-Csv -LiteralPath ([string]$inventory[0].Path) -ErrorAction Stop) }
    catch {
        Write-Debug "The destination domain inventory could not be read: $($_.Exception.Message)"
        return 'blank = not needed'
    }

    foreach ($row in $rows) {
        $name = [string](Get-MigrationCsvValue -Row $row -Name 'DomainName' -Default '')
        if ($name -ine $target) { continue }
        $verified = [string](Get-MigrationCsvValue -Row $row -Name 'IsVerified' -Default '')
        if ($verified -imatch '^(true|yes|1)$') {
            return "blank - $target is already verified in the destination"
        }
        return "blank = not needed; $target is NOT yet verified in the destination"
    }

    return "blank = not needed; $target is not in the destination's domain list"
}
