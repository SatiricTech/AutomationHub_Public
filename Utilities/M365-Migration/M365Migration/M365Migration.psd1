@{
    RootModule           = 'M365Migration.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = 'b3f4a1c2-6d58-4c7e-9a31-5e8d2f0b7c44'
    Author               = 'AutomationHub'
    CompanyName          = 'AutomationHub'
    Copyright            = 'Licensed under GPLv3.'
    Description          = 'Shared engine for the AutomationHub Microsoft 365 tenant-to-tenant migration toolkit: run context and logging, DryRun-aware mutations, Graph/Exchange/Teams connections, CSV and identity-plan handling, and the naming, collision and address-validation engines.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')

    FunctionsToExport    = @(
        'Complete-MigrationRun'
        'Connect-MigrationExchange'
        'Connect-MigrationGraph'
        'Connect-MigrationTeams'
        'ConvertTo-MigrationLocalPart'
        'ConvertTo-MigrationODataString'
        'ConvertTo-MigrationX500'
        'Export-MigrationReport'
        'Export-MigrationResult'
        'Format-MigrationE164'
        'Get-MigrationAddressChangeSet'
        'Get-MigrationCsvValue'
        'Get-MigrationGraphErrorStatusCode'
        'Get-MigrationPhoneNumberInventory'
        'Get-MigrationPlanAddressMap'
        'Get-MigrationProperty'
        'Get-MigrationRunContext'
        'Get-MigrationSkuCatalog'
        'Get-MigrationTargetDomain'
        'Get-MigrationTeamsPolicyName'
        'Import-MigrationCsv'
        'Import-MigrationPlan'
        'Initialize-MigrationModule'
        'Initialize-MigrationRun'
        'Invoke-MigrationAction'
        'Invoke-MigrationGraphRequest'
        'Join-MigrationList'
        'New-MigrationPassphrase'
        'New-MigrationPlanRow'
        'New-MigrationRandomPassword'
        'Resolve-MigrationCollision'
        'Resolve-MigrationPlanAddress'
        'Resolve-MigrationSkuMap'
        'Resolve-MigrationTeamsUser'
        'Save-MigrationPlan'
        'Select-MigrationPlanRows'
        'Split-MigrationList'
        'Split-MigrationProxyAddress'
        'Split-MigrationTeamsLineUri'
        'Test-MigrationAddress'
        'Test-MigrationPlanRowActionable'
        'Test-MigrationProtectedAddress'
        'Write-MigrationLog'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags       = @('Microsoft365', 'Migration', 'Graph', 'ExchangeOnline', 'Teams', 'AutomationHub')
            LicenseUri = 'https://www.gnu.org/licenses/gpl-3.0.en.html'
            ProjectUri = 'https://github.com/AutomationHub'
        }
    }
}
