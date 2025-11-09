targetScope = 'subscription'

@description('Azure region for resources')
param location string = 'canadacentral'

@description('Resource group name to create and deploy into')
param rgName string = 'jmd-discogs'

@description('Prefix for resource names (use short, lowercase, hyphenated)')
param namePrefix string = 'jmd-discogs'

@description('Deploy and use Key Vault for secrets (recommended)')
param enableKeyVault bool = true

@description('Use Flex Consumption plan for Function App instead of classic Linux Consumption')
param useFlexConsumption bool = false

@description('Python version for Azure Functions runtime')
@allowed([
  '3.10'
  '3.11'
])
param pythonVersion string = '3.10'

@description('Log Analytics workspace retention in days')
param logAnalyticsRetentionDays int = 30

// Secret names to use in Key Vault

@description('Optional AAD objectId for an admin user to grant full secret permissions in Key Vault')
param adminObjectId string = ''

@description('Optional AAD objectId of the current user to grant temporary RBAC for setting secrets')
param userObjectId string = ''

@description('Optional role definition ID to grant the user for secret write (e.g., Key Vault Secrets Officer). Will be used if userObjectId is provided.')
param userRoleDefinitionId string = ''

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: {
    project: 'DiscogsAgent'
  }
}

// Storage Account (for Functions runtime)
module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    namePrefix: namePrefix
    location: location
  }
}

// Monitoring: Log Analytics + Application Insights (workspace-based)
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    namePrefix: namePrefix
    location: location
    retentionDays: logAnalyticsRetentionDays
  }
}

// Key Vault (optional)
module keyvault 'modules/keyvault.bicep' = if (enableKeyVault) {
  name: 'keyvault'
  scope: rg
  params: {
    namePrefix: namePrefix
    location: location
    tenantId: subscription().tenantId
    adminObjectId: adminObjectId
  }
}

// Compute Key Vault-related values without referencing conditional module outputs
var computedVaultName = '${namePrefix}-kv'
// Use VaultName/SecretName syntax to avoid InvalidSyntax resolution errors
var discogsTokenReference = enableKeyVault ? '@Microsoft.KeyVault(VaultName=${computedVaultName};SecretName=DISCOGS-TOKEN)' : ''
var clientApiKeyReference = enableKeyVault ? '@Microsoft.KeyVault(VaultName=${computedVaultName};SecretName=X-API-KEY)' : ''

module functionapp 'modules/functionapp.bicep' = {
  name: 'functionapp'
  scope: rg
  params: {
    namePrefix: namePrefix
    location: location
    pythonVersion: pythonVersion
    storageConnectionString: storage.outputs.connectionString
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
  discogsTokenReference: discogsTokenReference
  clientApiKeyReference: clientApiKeyReference
    useFlexConsumption: useFlexConsumption
  }
}

// Grant Function MSI access to Key Vault secrets (when KV is enabled)
module kvAccess 'modules/keyvault-access.bicep' = if (enableKeyVault) {
  name: 'keyvaultAccess'
  scope: rg
  params: {
  keyVaultName: computedVaultName
    principalId: functionapp.outputs.principalId
    userObjectId: userObjectId
    userRoleDefinitionId: userRoleDefinitionId
  }
}

// Useful outputs
output resourceGroupName string = rg.name
output functionAppName string = functionapp.outputs.functionAppName
output functionAppHostname string = functionapp.outputs.defaultHostName
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString
output keyVaultName string = enableKeyVault ? computedVaultName : ''
output discogsTokenSecretUri string = ''
output clientApiKeySecretUri string = ''
