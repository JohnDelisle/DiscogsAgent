@description('Prefix for resource names')
param namePrefix string
@description('Azure region')
param location string

// Storage account name must be globally unique, 3-24 lowercase letters/numbers
var storageAccountName = toLower(replace('${namePrefix}sa', '-', ''))

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// Use resource function to list keys
var firstKey = storage.listKeys().keys[0].value
var connectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${firstKey};EndpointSuffix=${environment().suffixes.storage}'

output connectionString string = connectionString
output storageAccountName string = storage.name
