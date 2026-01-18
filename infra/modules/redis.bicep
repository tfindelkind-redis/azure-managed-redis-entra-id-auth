@description('Name of the Redis cache')
param name string

@description('Location for the resource')
param location string

@description('Tags for the resource')
param tags object

@description('SKU for Azure Managed Redis')
@allowed(['MemoryOptimized_M10', 'MemoryOptimized_M20', 'MemoryOptimized_M50', 'MemoryOptimized_M100'])
param sku string

@description('Enable cluster mode')
param enableClusterMode bool

@description('Subnet ID for private endpoint')
param subnetId string

@description('Principal ID of the managed identity for access policy')
param managedIdentityPrincipalId string

@description('Client ID of the managed identity (for alias)')
param managedIdentityClientId string

// Azure Managed Redis (preview API)
resource redis 'Microsoft.Cache/redisEnterprise@2024-02-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    minimumTlsVersion: '1.2'
  }
}

// Redis database with cluster mode and Entra ID auth
resource database 'Microsoft.Cache/redisEnterprise/databases@2024-02-01' = {
  parent: redis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: enableClusterMode ? 'OSSCluster' : 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    // Enable Entra ID authentication
    accessKeysAuthentication: 'Disabled'
  }
}

// Access policy assignment for the managed identity
// This grants the managed identity access to Redis using Entra ID
resource accessPolicy 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2024-02-01' = {
  parent: database
  name: 'managed-identity-access'
  properties: {
    accessPolicyName: 'Data Owner'  // Full access
    objectId: managedIdentityPrincipalId
    objectIdAlias: 'test-vm-identity-${managedIdentityClientId}'
  }
}

// Private endpoint for Redis
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${name}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${name}-pe-connection'
        properties: {
          privateLinkServiceId: redis.id
          groupIds: [
            'redisEnterprise'
          ]
        }
      }
    ]
  }
}

// Private DNS zone for Redis
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redisenterprise.cache.azure.net'
  location: 'global'
  tags: tags
}

// Link DNS zone to VNet (need to get VNet from subnet)
resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${name}-dns-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      // Extract VNet ID from subnet ID
      id: substring(subnetId, 0, lastIndexOf(subnetId, '/subnets/'))
    }
  }
}

// DNS zone group for private endpoint
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output id string = redis.id
output name string = redis.name
output hostname string = '${redis.name}.${location}.redisenterprise.cache.azure.net'
output port int = 10000
