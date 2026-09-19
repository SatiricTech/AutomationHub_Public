function Get-MigrationDefaultOutputRoot {
    <#
    .SYNOPSIS
        Returns the default root folder for migration output.

    .DESCRIPTION
        Windows runs use %LOCALAPPDATA%\Migration-Automations; every other platform
        (technicians run the offline planning phases from macOS and Linux) uses
        ~/Migration-Automations. The folder is not created here - Initialize-MigrationRun
        owns creation so that a caller can inspect the path without side effects.

        Exported so a caller can preview or validate where a run will land before
        Initialize-MigrationRun exists to ask - previously this was only reachable from
        inside the module.

    .EXAMPLE
        Get-MigrationDefaultOutputRoot

        Returns the platform-appropriate root path.

    .NOTES
        Author: AutomationHub
        Written with assistance from Claude (Anthropic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($IsWindows -and $env:LOCALAPPDATA) {
        return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Migration-Automations')
    }

    $profileRoot = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profileRoot)) { $profileRoot = $HOME }
    return (Join-Path -Path $profileRoot -ChildPath 'Migration-Automations')
}
