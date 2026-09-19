function Import-MigrationStepCatalog {
    <#
    .SYNOPSIS
        Reads StepCatalog.psd1, cached for the session.

    .DESCRIPTION
        Get-MigrationStep is called repeatedly while a workbench screen is drawn - once per
        step form, once per refresh - and re-parsing the catalogue each time is wasted work on
        a file that only changes when the toolkit is edited. The cache is keyed by path and
        LastWriteTimeUtc, the same rule Get-MigrationScriptParameter uses, so editing the
        overlay during a session is picked up on the next call.

        Import-PowerShellDataFile is what makes the overlay data rather than code: the file is
        parsed, never executed, so a catalogue cannot run anything when the workbench starts.

    .PARAMETER Path
        Path to StepCatalog.psd1.

    .EXAMPLE
        Import-MigrationStepCatalog -Path ./M365Migration/StepCatalog.psd1

        Returns the catalogue as a hashtable keyed by script basename.

    .NOTES
        Author: AutomationHub
        Private module helper - not exported.
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $cacheKey = '{0}|{1:o}' -f $file.FullName, $file.LastWriteTimeUtc
    if ($script:MigrationStepCatalogCache.ContainsKey($cacheKey)) {
        return $script:MigrationStepCatalogCache[$cacheKey]
    }

    $catalog = Import-PowerShellDataFile -LiteralPath $file.FullName -ErrorAction Stop
    $script:MigrationStepCatalogCache[$cacheKey] = $catalog
    return $catalog
}
