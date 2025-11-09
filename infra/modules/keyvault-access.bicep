@description('Name of the Key Vault to grant access to')
param keyVaultName string
@description('Principal ID of the Function App system-assigned identity')
param principalId string
@description('Role to assign for secret read (default: Key Vault Secrets User)')
param roleDefinitionId string = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')

@description('Optional AAD objectId of a user to grant RBAC for writing secrets (e.g., Secrets Officer)')
@minLength(0)
param userObjectId string = ''

@description('Optional role definition ID to grant to userObjectId (e.g., Key Vault Secrets Officer). If empty, no user grant is created.')
@minLength(0)
param userRoleDefinitionId string = ''

resource kv 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

// Assign RBAC so the Function MSI can read secrets via Key Vault references
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, principalId, 'kv-secrets-user')
  scope: kv
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

// Optionally grant a user role (e.g., Secrets Officer) so they can set secrets during deployment
resource kvUserGrant 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userObjectId) && !empty(userRoleDefinitionId)) {
  name: guid(kv.id, userObjectId, 'kv-user-grant')
  scope: kv
  properties: {
    roleDefinitionId: userRoleDefinitionId
    principalId: userObjectId
    principalType: 'User'
  }
}

output grantedPrincipalId string = principalId
