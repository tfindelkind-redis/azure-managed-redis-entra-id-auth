targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (used for resource naming)')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Azure Managed Redis SKU - use Memory Optimized for Cluster OSS')
@allowed(['MemoryOptimized_M10', 'MemoryOptimized_M20', 'MemoryOptimized_M50', 'MemoryOptimized_M100'])
param redisSku string = 'MemoryOptimized_M10'

@description('Enable cluster mode for Redis (Cluster OSS tier)')
param enableClusterMode bool = true

@description('VM admin username')
param vmAdminUsername string = 'azureuser'

@description('VM admin password or SSH key')
@secure()
param vmAdminPassword string

@description('Enable Service Principal authentication for local testing (creates a Service Principal)')
param createServicePrincipal bool = true

// Tags for all resources
var tags = {
  'azd-env-name': environmentName
  purpose: 'redis-entra-id-testing'
}

// Naming convention
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

// User-Assigned Managed Identity for VM and Redis access
module managedIdentity './modules/managed-identity.bicep' = {
  name: 'managed-identity'
  scope: rg
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}${resourceToken}'
    location: location
    tags: tags
  }
}

// Virtual Network for VM and Redis
module vnet './modules/vnet.bicep' = {
  name: 'vnet'
  scope: rg
  params: {
    name: '${abbrs.networkVirtualNetworks}${resourceToken}'
    location: location
    tags: tags
  }
}

// Azure Managed Redis (Cluster OSS tier with Entra ID auth)
module redis './modules/redis.bicep' = {
  name: 'redis'
  scope: rg
  params: {
    name: '${abbrs.cacheRedis}${resourceToken}'
    location: location
    tags: tags
    sku: redisSku
    enableClusterMode: enableClusterMode
    subnetId: vnet.outputs.redisSubnetId
    managedIdentityPrincipalId: managedIdentity.outputs.principalId
    managedIdentityClientId: managedIdentity.outputs.clientId
  }
}

// Test VM with all runtimes installed
module vm './modules/vm.bicep' = {
  name: 'vm'
  scope: rg
  params: {
    name: '${abbrs.computeVirtualMachines}${resourceToken}'
    location: location
    tags: tags
    subnetId: vnet.outputs.vmSubnetId
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    managedIdentityId: managedIdentity.outputs.id
  }
}

// Outputs for use in testing
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_MANAGED_IDENTITY_CLIENT_ID string = managedIdentity.outputs.clientId
output AZURE_MANAGED_IDENTITY_PRINCIPAL_ID string = managedIdentity.outputs.principalId
output REDIS_HOSTNAME string = redis.outputs.hostname
output REDIS_PORT int = redis.outputs.port
output VM_PUBLIC_IP string = vm.outputs.publicIpAddress
output VM_ADMIN_USERNAME string = vmAdminUsername

// Connection string for SSH
output SSH_CONNECTION_STRING string = 'ssh ${vmAdminUsername}@${vm.outputs.publicIpAddress}'
