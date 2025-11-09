@description('Prefix for resource names')
param namePrefix string
@description('Azure region')
param location string
@description('Python version for Functions')
param pythonVersion string
@description('Storage account connection string')
param storageConnectionString string
@description('App Insights connection string')
param appInsightsConnectionString string
@description('Discogs token Key Vault reference string (e.g., @Microsoft.KeyVault(VaultName=...;SecretName=...))')
param discogsTokenReference string
@description('Client API key Key Vault reference string (e.g., @Microsoft.KeyVault(VaultName=...;SecretName=...))')
param clientApiKeyReference string

@description('Use Flex Consumption plan (true) or classic Consumption (false)')
param useFlexConsumption bool = false

var planName = '${namePrefix}-asp'
var functionName = '${namePrefix}-func'

// Consumption plan (ServerFarm)
// Plan (classic Consumption Y1 or Flex Consumption FC1)
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = if (!useFlexConsumption) {
  name: planName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true // Linux
  }
}

// Flex Consumption plan (preview / newer model) -- only created when requested
resource flexPlan 'Microsoft.Web/serverfarms@2023-12-01' = if (useFlexConsumption) {
  name: planName
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
  serverFarmId: useFlexConsumption ? flexPlan.id : plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|${pythonVersion}'
      appSettings: concat([
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
      ], !empty(discogsTokenReference) ? [
        {
          name: 'DISCOGS_TOKEN'
          value: discogsTokenReference
        }
      ] : [], !empty(clientApiKeyReference) ? [
        {
          name: 'X_API_KEY'
          value: clientApiKeyReference
        }
      ] : [])
    }
  }
}

output functionAppName string = func.name
output defaultHostName string = func.properties.defaultHostName
output principalId string = func.identity.principalId
