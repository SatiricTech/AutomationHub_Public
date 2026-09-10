#Requires -Version 7.4

<#
    M365Migration - shared engine for the AutomationHub Microsoft 365 tenant-to-tenant
    migration toolkit.

    Public/*.ps1 holds one exported function per file; Private/*.ps1 holds the helpers
    and data tables they lean on. Both sets are dot-sourced into the module scope so
    that module-scoped state ($script:MigrationRun, $script:SkuCatalog) is shared by
    every function without being visible to the caller.

    Author: AutomationHub
    Written with assistance from Claude (Anthropic).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-scoped state. MigrationRun is set by Initialize-MigrationRun and read by the
# logger and the DryRun wrapper; the rest are caches cleared on demand.
$script:MigrationRun = $null
$script:SkuCatalog = $null
$script:MigrationPlanBackups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

$privateFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)
$publicFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)

foreach ($file in @($privateFiles + $publicFiles)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to load module component '$($file.Name)': $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function $publicFiles.BaseName
