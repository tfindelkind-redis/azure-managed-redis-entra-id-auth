@description('Name of the Redis cache')
param name string

@description('Location for the resource')
param location string

@description('Tags for the resource')
param tags object

@description('SKU for Azure Managed Redis')
@allowed(['Balanced_B0', 'Balanced_B1', 'Balanced_B3', 'Balanced_B5', 'Balanced_B10', 'Balanced_B20', 'MemoryOptimized_M10', 'MemoryOptimized_M20', 'MemoryOptimized_M50', 'ComputeOptimized_X5', 'ComputeOptimized_X10'])
param sku string

@description('Cluster policy: OSSCluster or EnterpriseCluster')
@allowed(['OSSCluster', 'EnterpriseCluster'])
param clusterPolicy string

@description('Subnet ID for private endpoint')
param subnetId string

@description('Principal ID of the managed identity for access policy')
param managedIdentityPrincipalId string

@description('Client ID of the managed identity (for alias)')
param managedIdentityClientId string

@description('Enable High Availability (replica nodes)')
param highAvailability bool = true

// Azure Managed Redis (preview API)
resource redis 'Microsoft.Cache/redisEnterprise@2024-09-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    minimumTlsVersion: '1.2'
    highAvailability: highAvailability ? 'Enabled' : 'Disabled'
  }
}

// Redis database with configurable cluster policy and Entra ID auth
resource database 'Microsoft.Cache/redisEnterprise/databases@2024-09-01-preview' = {
  parent: redis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: clusterPolicy
    evictionPolicy: 'NoEviction'
    // Enable Entra ID authentication (disable access keys)
    accessKeysAuthentication: 'Disabled'
  }
}

// Access policy assignment for the user-assigned managed identity
// This grants the managed identity access to Redis using Entra ID
resource accessPolicy 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2024-09-01-preview' = {
  parent: database
  name: 'user-assigned-mi-access'
  properties: {
    accessPolicyName: 'default'  // Data Owner - Full access
    user: {
      objectId: managedIdentityPrincipalId
    }
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
  name: 'privatelink.${location}.redis.azure.net'
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
output hostname string = redis.properties.hostName
output port int = database.properties.port
output clusterPolicy string = clusterPolicy
