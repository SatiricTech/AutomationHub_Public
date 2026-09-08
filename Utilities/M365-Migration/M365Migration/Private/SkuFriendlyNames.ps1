<#
    Friendly names for the SKU part numbers seen most often in SMB and mid-market
    tenants. Graph only returns skuPartNumber, which is unreadable on a licence
    report, so Get-MigrationSkuCatalog decorates each SKU with the name a technician
    would recognise. Unknown part numbers fall through unchanged rather than being
    dropped - a missing entry must never hide a licence.

    Author: AutomationHub
#>

$script:SkuFriendlyNames = @{
    'O365_BUSINESS_ESSENTIALS' = 'Microsoft 365 Business Basic'
    'O365_BUSINESS_PREMIUM'    = 'Microsoft 365 Business Standard'
    'SPB'                      = 'Microsoft 365 Business Premium'
    'SPE_E3'                   = 'Microsoft 365 E3'
    'SPE_E5'                   = 'Microsoft 365 E5'
    'ENTERPRISEPACK'           = 'Office 365 E3'
    'ENTERPRISEPREMIUM'        = 'Office 365 E5'
    'STANDARDPACK'             = 'Office 365 E1'
    'EXCHANGESTANDARD'         = 'Exchange Online (Plan 1)'
    'EXCHANGEENTERPRISE'       = 'Exchange Online (Plan 2)'
    'POWER_BI_STANDARD'        = 'Power BI (free)'
    'POWER_BI_PRO'             = 'Power BI Pro'
    'FLOW_FREE'                = 'Power Automate Free'
    'EMS'                      = 'Enterprise Mobility + Security E3'
    'EMSPREMIUM'               = 'Enterprise Mobility + Security E5'
    'AAD_PREMIUM'              = 'Entra ID P1'
    'AAD_PREMIUM_P2'           = 'Entra ID P2'
    'WINDOWS_STORE'            = 'Windows Store for Business'
    'TEAMS_EXPLORATORY'        = 'Teams Exploratory'
    'MCOMEETADV'               = 'Microsoft 365 Audio Conferencing'
    'MCOEV'                    = 'Microsoft Teams Phone Standard'
    'DESKLESSPACK'             = 'Office 365 F3'
    'SPE_F1'                   = 'Microsoft 365 F3'
}
