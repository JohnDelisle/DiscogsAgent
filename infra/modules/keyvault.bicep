@description('Prefix for resource names')
param namePrefix string
@description('Azure region')
param location string
@description('Tenant ID for access policies')
param tenantId string
@description('Optional AAD objectId of an admin to grant full secret permissions')
@minLength(0)
param adminObjectId string = ''
@description('Use RBAC for Key Vault data plane (recommended). When true, accessPolicies are ignored and RBAC role assignments must be used.')
param useRbac bool = true

var keyVaultName = '${namePrefix}-kv'

resource kv 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    enableRbacAuthorization: useRbac
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    // If RBAC is enabled, accessPolicies are ignored; keep empty for compatibility
    accessPolicies: useRbac ? [] : (length(adminObjectId) > 0 ? [
      {
        tenantId: tenantId
        objectId: adminObjectId
        permissions: {
          secrets: [ 'get', 'list', 'set', 'delete', 'recover', 'backup', 'restore' ]
        }
      }
    ] : [])
    softDeleteRetentionInDays: 90
  }
}

output keyVaultName string = kv.name
