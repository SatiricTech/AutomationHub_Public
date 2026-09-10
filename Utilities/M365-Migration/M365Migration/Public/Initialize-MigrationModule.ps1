function Initialize-MigrationModule {
    <#
    .SYNOPSIS
        Ensures the required PowerShell modules are installed and imported.

    .DESCRIPTION
        Installs a missing dependency to the CurrentUser scope and imports it. The
        install is announced through the logger before it happens, because a script that
        silently pulls megabytes off the gallery onto a technician's laptop is a script
        nobody trusts twice. Module installation is allowed even under -DryRun: it is a
        prerequisite of the run, not a change to the tenant, and blocking it would make
        a rehearsal impossible on a fresh machine.

        Modules already present are imported without touching the gallery, so an air-
        gapped or version-pinned machine keeps whatever it has.

    .PARAMETER Name
        One or more module names.

    .PARAMETER MinimumVersion
        The minimum acceptable version, applied to every named module.

    .EXAMPLE
        Initialize-MigrationModule -Name 'Microsoft.Graph.Authentication'

        Installs the module if missing, then imports it.

    .EXAMPLE
        Initialize-MigrationModule -Name 'ExchangeOnlineManagement' -MinimumVersion '3.4.0'

        Requires at least version 3.4.0.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$MinimumVersion
    )

    foreach ($moduleName in $Name) {
        $available = @(Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue)
        if ($MinimumVersion) {
            $available = @($available | Where-Object { $_.Version -ge [version]$MinimumVersion })
        }

        if ($available.Count -eq 0) {
            $versionText = if ($MinimumVersion) { " (minimum version $MinimumVersion)" } else { '' }
            Write-MigrationLog -Message "Module '$moduleName'$versionText is not installed. Installing it for the current user from the PowerShell Gallery." -Level WARNING
            try {
                $installParameters = @{
                    Name          = $moduleName
                    Scope         = 'CurrentUser'
                    Force         = $true
                    AllowClobber  = $true
                    ErrorAction   = 'Stop'
                }
                if ($MinimumVersion) { $installParameters['MinimumVersion'] = $MinimumVersion }
                Install-Module @installParameters
                Write-MigrationLog -Message "Installed module '$moduleName'." -Level SUCCESS
            }
            catch {
                throw ("Module '$moduleName'$versionText is required but could not be installed: $($_.Exception.Message). " +
                    "Install it manually with: Install-Module -Name $moduleName -Scope CurrentUser")
            }
        }

        try {
            $importParameters = @{ Name = $moduleName; ErrorAction = 'Stop' }
            if ($MinimumVersion) { $importParameters['MinimumVersion'] = $MinimumVersion }
            Import-Module @importParameters
        }
        catch {
            throw ("Module '$moduleName' is installed but could not be imported: $($_.Exception.Message). " +
                'Close other PowerShell sessions holding an older version and try again.')
        }
    }
}
