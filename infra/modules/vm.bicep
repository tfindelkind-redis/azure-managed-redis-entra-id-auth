@description('Name of the VM')
param name string

@description('Location for the resource')
param location string

@description('Tags for the resource')
param tags object

@description('Subnet ID for the VM')
param subnetId string

@description('Admin username')
param adminUsername string

@description('Admin password')
@secure()
param adminPassword string

@description('User-assigned managed identity ID')
param managedIdentityId string

// Public IP for SSH access
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${name}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// NIC for VM
resource nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: '${name}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// VM with Ubuntu and all required runtimes for testing
resource vm 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2s_v3'
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// Custom script extension to install all runtimes
resource vmExtension 'Microsoft.Compute/virtualMachines/extensions@2023-07-01' = {
  parent: vm
  name: 'install-runtimes'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      script: base64(loadTextContent('../scripts/install-runtimes.sh'))
    }
  }
}

output id string = vm.id
output name string = vm.name
output publicIpAddress string = publicIp.properties.ipAddress
