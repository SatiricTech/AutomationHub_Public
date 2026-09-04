#
# Module manifest for ServiceWatchdogAlert, the module bundled with the ServiceWatchdog
# Azure Function app (DESIGN.md section 6.3). Bundled under AzureFunction/Modules so the
# Functions worker loads it from PSModulePath without managed dependencies.
#
@{
    RootModule           = 'ServiceWatchdogAlert.psm1'
    ModuleVersion        = '1.0.0'
    CompatiblePSEditions = @('Core')
    GUID                 = '6e1f0d2c-5b7a-4c9e-8f3d-2a4b6c8d0e1f'
    Author               = 'AutomationHub contributors'
    CompanyName          = 'AutomationHub'
    Copyright            = '(c) 2026 AutomationHub contributors. Licensed under the GNU GPL v3.'
    Description          = 'Payload validation, email rendering, mail providers and Table storage for ServiceWatchdog.'
    PowerShellVersion    = '7.4'
    FunctionsToExport    = @(
        'Get-WatchdogConfig',
        'Test-WatchdogPayload',
        'ConvertTo-WatchdogEmail',
        'Send-WatchdogMail',
        'Test-WatchdogRateLimit',
        'Test-WatchdogGlobalRateLimit',
        'Get-WatchdogStorageToken',
        'Set-WatchdogHostEntity',
        'Test-WatchdogSentEvent',
        'Set-WatchdogSentEvent',
        'ConvertTo-WatchdogHostEntity',
        'Get-WatchdogStaleHosts',
        'ConvertTo-WatchdogKey',
        'Write-WatchdogLog'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('ServiceWatchdog', 'AzureFunctions', 'Monitoring')
            LicenseUri = 'https://www.gnu.org/licenses/gpl-3.0.html'
        }
    }
}
