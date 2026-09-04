// ServiceWatchdog Azure infrastructure.
//
// Deploys the email relay for the ServiceWatchdog endpoint scripts: a Windows Consumption
// Function App (PowerShell) with a system-assigned identity, its storage account and the
// two watchdog tables, a Key Vault that holds the mail provider secrets, workspace-based
// Application Insights, and the least-privilege role assignments. Secrets are not created
// here; Install-AzureServiceWatchdogFunction.ps1 seeds them after deployment.
//
// Validate locally: bicep build main.bicep && bicep lint main.bicep
// Deploy by hand:   az deployment group create -g <rg> -f main.bicep -p main.parameters.json
//
// Developed with AI assistance (Claude); reviewed before publication.

targetScope = 'resourceGroup'

metadata name = 'ServiceWatchdog'
metadata version = '1.0.0'
metadata description = 'ServiceWatchdog alert relay: Function App, storage tables, Key Vault, Application Insights.'

// ---------------------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------------------

@description('Prefix for every resource name. Lowercase letters, digits and hyphens; 3 to 14 characters.')
@minLength(3)
@maxLength(14)
param baseName string

@description('Azure region for every resource. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('PowerShell worker version. Sets FUNCTIONS_WORKER_RUNTIME_VERSION and siteConfig.powerShellVersion.')
@allowed([
  '7.4'
  '7.6'
])
param powerShellVersion string = '7.4'

@description('Mail provider: Smtp2GoApi calls the SMTP2GO REST API; Smtp uses an authenticated relay with STARTTLS.')
@allowed([
  'Smtp2GoApi'
  'Smtp'
])
param mailProvider string = 'Smtp2GoApi'

@description('Sender for every alert, e.g. "Service Watchdog <alerts@example.com>"; must be verified at the provider.')
@minLength(1)
param mailFrom string

@description('Semicolon-separated list of recipient addresses.')
@minLength(1)
param mailTo string

@description('Text prepended to every alert subject.')
param mailSubjectPrefix string = '[Service Watchdog]'

@description('Timeout in seconds for each call to the mail provider.')
@minValue(5)
@maxValue(120)
param mailTimeoutSeconds int = 20

@description('SMTP2GO send endpoint. Override only for a regional SMTP2GO endpoint.')
param smtp2GoApiUrl string = 'https://api.smtp2go.com/v3/email/send'

@description('SMTP relay host name, used only when mailProvider is Smtp.')
param smtpHost string = ''

@description('SMTP relay port. Use 587 or 2525; port 25 is blocked on most Azure subscriptions.')
@minValue(1)
@maxValue(65535)
param smtpPort int = 587

@description('SMTP relay user name, used only when mailProvider is Smtp.')
param smtpUsername string = ''

@description('Upgrade the SMTP session with STARTTLS. Implicit TLS on port 465 is not supported.')
param smtpUseStartTls bool = true

@description('Maximum alert emails per reporting host per hour. Recovered and heartbeat events are exempt.')
@minValue(1)
@maxValue(1000)
param maxAlertsPerHostPerHour int = 6

@description('Hours without a report after which the daily digest lists a host as stale.')
@minValue(1)
@maxValue(8760)
param staleHours int = 26

@description('NCRONTAB schedule for the stale-host digest, evaluated in UTC.')
@minLength(1)
param digestSchedule string = '0 0 7 * * *'

@description('Send an all-clear digest every day even when no host is stale.')
param digestAlwaysSend bool = false

@description('Optional semicolon-separated list of SiteName values the function accepts. Empty allows any site.')
param allowedSites string = ''

@description('Object ID of the deploying identity. Receives Key Vault Secrets Officer so it can seed the secrets.')
@minLength(36)
@maxLength(36)
param deployerObjectId string

@description('Principal type of deployerObjectId.')
@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param deployerPrincipalType string = 'User'

@description('Tags applied to every resource.')
param tags object = {}

// ---------------------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------------------

var uniqueSuffix = take(uniqueString(resourceGroup().id), 6)
var normalizedBaseName = toLower(baseName)

var logAnalyticsName = 'log-${normalizedBaseName}'
var applicationInsightsName = 'appi-${normalizedBaseName}'
var storageAccountName = 'st${replace(normalizedBaseName, '-', '')}${uniqueSuffix}'
var appServicePlanName = 'asp-${normalizedBaseName}'
var functionAppName = 'func-${normalizedBaseName}-${uniqueSuffix}'
var keyVaultName = 'kv-${normalizedBaseName}-${uniqueSuffix}'

var hostsTableName = 'WatchdogHosts'
var sentEventsTableName = 'WatchdogSentEvents'

// Built-in role definition IDs.
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var roleDefinitionPrefix = 'Microsoft.Authorization/roleDefinitions'
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId(roleDefinitionPrefix, keyVaultSecretsUserRoleId)
var keyVaultSecretsOfficerRoleDefinitionId = subscriptionResourceId(roleDefinitionPrefix, keyVaultSecretsOfficerRoleId)
var storageTableDataContributorRoleDefinitionId = subscriptionResourceId(
  roleDefinitionPrefix,
  storageTableDataContributorRoleId
)

var storageAccountKey = storageAccount.listKeys().keys[0].value
var storageEndpointSuffix = environment().suffixes.storage
var storageConnectionString = join([
  'DefaultEndpointsProtocol=https'
  'AccountName=${storageAccount.name}'
  'AccountKey=${storageAccountKey}'
  'EndpointSuffix=${storageEndpointSuffix}'
], ';')

// ---------------------------------------------------------------------------------------
// Monitoring
// ---------------------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------------------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }

  resource tableService 'tableServices' = {
    name: 'default'

    resource hostsTable 'tables' = {
      name: hostsTableName
    }

    resource sentEventsTable 'tables' = {
      name: sentEventsTableName
    }
  }
}

// ---------------------------------------------------------------------------------------
// Key Vault (secrets are seeded by the install script, not by this template)
// ---------------------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// ---------------------------------------------------------------------------------------
// Function App (Windows Consumption)
// ---------------------------------------------------------------------------------------

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
    size: 'Y1'
    family: 'Y'
  }
  properties: {
    reserved: false
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    // Isolates the /admin and /runtime endpoints from the function keys. The property is
    // documented under the Functions app settings reference
    // (https://learn.microsoft.com/azure/azure-functions/functions-app-settings) but is
    // missing from the ARM template schema, hence the suppressed warning. The install
    // script verifies it after deployment.
    #disable-next-line BCP037
    functionsRuntimeAdminIsolationEnabled: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      powerShellVersion: powerShellVersion
      appSettings: [
        // Functions host settings. Inline so a Consumption app never starts without them.
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: storageConnectionString
        }
        {
          // Must never change after the first deployment.
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'
          value: powerShellVersion
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        // Watchdog settings (DESIGN.md section 6.2). Secrets are Key Vault references that
        // resolve once the install script has seeded the secrets and restarted the app.
        {
          name: 'WATCHDOG_MAIL_PROVIDER'
          value: mailProvider
        }
        {
          name: 'WATCHDOG_MAIL_FROM'
          value: mailFrom
        }
        {
          name: 'WATCHDOG_MAIL_TO'
          value: mailTo
        }
        {
          name: 'WATCHDOG_MAIL_SUBJECT_PREFIX'
          value: mailSubjectPrefix
        }
        {
          name: 'WATCHDOG_MAIL_TIMEOUT_SECONDS'
          value: string(mailTimeoutSeconds)
        }
        {
          name: 'WATCHDOG_SMTP2GO_API_URL'
          value: smtp2GoApiUrl
        }
        {
          name: 'WATCHDOG_SMTP2GO_API_KEY'
          value: '@Microsoft.KeyVault(SecretUri=${keyVault.properties.vaultUri}secrets/Smtp2GoApiKey)'
        }
        {
          name: 'WATCHDOG_SMTP_HOST'
          value: smtpHost
        }
        {
          name: 'WATCHDOG_SMTP_PORT'
          value: string(smtpPort)
        }
        {
          name: 'WATCHDOG_SMTP_USERNAME'
          value: smtpUsername
        }
        {
          name: 'WATCHDOG_SMTP_PASSWORD'
          value: '@Microsoft.KeyVault(SecretUri=${keyVault.properties.vaultUri}secrets/SmtpPassword)'
        }
        {
          name: 'WATCHDOG_SMTP_USE_STARTTLS'
          value: toLower(string(smtpUseStartTls))
        }
        {
          name: 'WATCHDOG_TABLE_ENDPOINT'
          value: storageAccount.properties.primaryEndpoints.table
        }
        {
          name: 'WATCHDOG_MAX_ALERTS_PER_HOST_PER_HOUR'
          value: string(maxAlertsPerHostPerHour)
        }
        {
          name: 'WATCHDOG_ALLOWED_SITES'
          value: allowedSites
        }
        {
          name: 'WATCHDOG_STALE_HOURS'
          value: string(staleHours)
        }
        {
          name: 'WATCHDOG_DIGEST_SCHEDULE'
          value: digestSchedule
        }
        {
          name: 'WATCHDOG_DIGEST_ALWAYS_SEND'
          value: toLower(string(digestAlwaysSend))
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------------------
// Role assignments (deterministic names so redeployments are idempotent)
// ---------------------------------------------------------------------------------------

resource functionKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deployerKeyVaultSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployerObjectId, keyVaultSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficerRoleDefinitionId
    principalId: deployerObjectId
    principalType: deployerPrincipalType
  }
}

resource functionStorageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageTableDataContributorRoleDefinitionId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------------------
// Outputs (consumed by Install-AzureServiceWatchdogFunction.ps1)
// ---------------------------------------------------------------------------------------

@description('Name of the Function App.')
output functionAppName string = functionApp.name

@description('Default host name of the Function App.')
output functionAppHostName string = functionApp.properties.defaultHostName

@description('URL the endpoint scripts POST alerts to. The function key is created separately.')
output alertUrl string = 'https://${functionApp.properties.defaultHostName}/api/servicewatchdog/alert'

@description('Name of the Key Vault that holds the mail provider secrets.')
output keyVaultName string = keyVault.name

@description('Name of the storage account that holds the watchdog tables.')
output storageAccountName string = storageAccount.name

@description('Name of the Application Insights resource.')
output applicationInsightsName string = applicationInsights.name
