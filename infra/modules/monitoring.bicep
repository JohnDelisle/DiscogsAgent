@description('Prefix for resource names')
param namePrefix string
@description('Azure region')
param location string
@description('Retention days for Log Analytics workspace')
param retentionDays int = 30

var workspaceName = '${namePrefix}-laws'

resource laws 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    retentionInDays: retentionDays
    features: {
      searchVersion: 1
    }
  }
  // sku property sometimes not present in older API metadata; can be uncommented if required
  // sku: {
  //   name: 'PerGB2018'
  // }
}

var appInsightsName = '${namePrefix}-appi'

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: laws.id
  }
}

output appInsightsConnectionString string = appi.properties.ConnectionString
output appInsightsName string = appi.name
output logAnalyticsWorkspaceId string = laws.id
