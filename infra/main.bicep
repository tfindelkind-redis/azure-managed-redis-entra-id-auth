targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (used for resource naming)')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string = 'westus3'

@description('Azure Managed Redis SKU - B5 recommended for OSS Cluster testing (multiple primary shards)')
@allowed(['Balanced_B0', 'Balanced_B1', 'Balanced_B3', 'Balanced_B5', 'Balanced_B10', 'Balanced_B20', 'MemoryOptimized_M10', 'MemoryOptimized_M20', 'MemoryOptimized_M50', 'ComputeOptimized_X5', 'ComputeOptimized_X10'])
param redisSku string = 'Balanced_B5'

@description('Redis cluster policy: OSSCluster (for cluster-aware clients) or EnterpriseCluster (single endpoint proxy)')
@allowed(['OSSCluster', 'EnterpriseCluster'])
param redisClusterPolicy string = 'EnterpriseCluster'

@description('Enable High Availability (replica nodes) - strongly recommended for production')
param redisHighAvailability bool = true

@description('VM admin username')
param vmAdminUsername string = 'azureuser'

@description('VM admin password or SSH key')
@secure()
param vmAdminPassword string

@description('Optional: Existing managed identity principal ID to grant access (skips identity creation)')
param existingManagedIdentityPrincipalId string = ''

@description('Optional: Existing managed identity client ID')
param existingManagedIdentityClientId string = ''

@description('Optional: Existing managed identity resource ID')
param existingManagedIdentityId string = ''

// Tags for all resources
var tags = {
  'azd-env-name': environmentName
  purpose: 'redis-entra-id-testing'
  clusterPolicy: redisClusterPolicy
}

// Naming convention
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

// Use existing identity or create new one
var useExistingIdentity = !empty(existingManagedIdentityPrincipalId)

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

// User-Assigned Managed Identity for VM and Redis access (only if not using existing)
module managedIdentity './modules/managed-identity.bicep' = if (!useExistingIdentity) {
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

// Azure Managed Redis with configurable cluster policy
module redis './modules/redis.bicep' = {
  name: 'redis'
  scope: rg
  params: {
    name: '${abbrs.cacheRedis}${resourceToken}'
    location: location
    tags: tags
    sku: redisSku
    clusterPolicy: redisClusterPolicy
    highAvailability: redisHighAvailability
    subnetId: vnet.outputs.redisSubnetId
    managedIdentityPrincipalId: useExistingIdentity ? existingManagedIdentityPrincipalId : managedIdentity.outputs.principalId
    managedIdentityClientId: useExistingIdentity ? existingManagedIdentityClientId : managedIdentity.outputs.clientId
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
    managedIdentityId: useExistingIdentity ? existingManagedIdentityId : managedIdentity.outputs.id
  }
}

// Access policy for VM's system-assigned managed identity
// The parameters automatically create dependencies on redis and vm modules
module vmSystemIdentityAccessPolicy './modules/redis-access-policy.bicep' = {
  name: 'vm-system-identity-access-policy'
  scope: rg
  params: {
    redisClusterName: redis.outputs.name
    principalId: vm.outputs.systemAssignedPrincipalId
    accessPolicyAssignmentName: 'vm-system-identity-access'
  }
}

// Outputs for use in testing
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output REDIS_HOSTNAME string = redis.outputs.hostname
output REDIS_PORT int = redis.outputs.port
output REDIS_CLUSTER_POLICY string = redisClusterPolicy
output AZURE_MANAGED_IDENTITY_CLIENT_ID string = useExistingIdentity ? existingManagedIdentityClientId : managedIdentity.outputs.clientId
output AZURE_MANAGED_IDENTITY_PRINCIPAL_ID string = useExistingIdentity ? existingManagedIdentityPrincipalId : managedIdentity.outputs.principalId
output VM_SYSTEM_ASSIGNED_PRINCIPAL_ID string = vm.outputs.systemAssignedPrincipalId
output VM_NAME string = vm.outputs.name
output VM_PUBLIC_IP string = vm.outputs.publicIpAddress
output VM_ADMIN_USERNAME string = vmAdminUsername

// Connection string for SSH
output SSH_CONNECTION_STRING string = 'ssh ${vmAdminUsername}@${vm.outputs.publicIpAddress}'
