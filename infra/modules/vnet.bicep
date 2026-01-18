@description('Name of the VNet')
param name string

@description('Location for the resource')
param location string

@description('Tags for the resource')
param tags object

var addressPrefix = '10.0.0.0/16'

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: 'vm-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: {
            id: vmNsg.id
          }
        }
      }
      {
        name: 'redis-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
          // Redis subnet needs delegations for private endpoints
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// NSG for VM subnet - allow SSH
resource vmNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${name}-vm-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

output id string = vnet.id
output name string = vnet.name
output vmSubnetId string = vnet.properties.subnets[0].id
output redisSubnetId string = vnet.properties.subnets[1].id
