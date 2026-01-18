# Azure Setup Guide

This guide walks you through setting up Azure Managed Redis with Entra ID authentication.

## 📋 Prerequisites

- Azure subscription with appropriate permissions
- Azure CLI installed (`az` command)
- Terraform (optional, for IaC approach)

## 🎯 What We'll Create

1. **Resource Group** - Container for all resources
2. **Azure Managed Redis** - The Redis instance
3. **Managed Identity** - Identity for your application
4. **Access Policy Assignment** - Grants the identity access to Redis

## 🔧 Method 1: Azure CLI

### Step 1: Set Variables

```bash
# Configuration
RESOURCE_GROUP="rg-redis-entra-demo"
LOCATION="eastus"
REDIS_NAME="amr-entra-demo"
IDENTITY_NAME="id-redis-app"
```

### Step 2: Create Resource Group

```bash
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION
```

### Step 3: Create Azure Managed Redis

```bash
# Create the Redis cluster
az redisenterprise create \
  --name $REDIS_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku "Balanced_B1"

# Create the database with Entra ID auth enabled
az redisenterprise database create \
  --cluster-name $REDIS_NAME \
  --resource-group $RESOURCE_GROUP \
  --client-protocol "Encrypted" \
  --port 10000
```

### Step 4: Create User-Assigned Managed Identity

```bash
az identity create \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Get the principal ID (needed for access policy)
PRINCIPAL_ID=$(az identity show \
  --name $IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

echo "Principal ID: $PRINCIPAL_ID"
```

### Step 5: Create Access Policy Assignment

```bash
# Get subscription ID
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create access policy assignment using REST API
az rest --method PUT \
  --uri "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Cache/redisEnterprise/$REDIS_NAME/databases/default/accessPolicyAssignments/app-identity?api-version=2024-10-01" \
  --body "{
    \"properties\": {
      \"accessPolicyName\": \"default\",
      \"user\": {
        \"objectId\": \"$PRINCIPAL_ID\"
      }
    }
  }"
```

### Step 6: Get Connection Details

```bash
# Get Redis hostname
REDIS_HOST=$(az redisenterprise database show \
  --cluster-name $REDIS_NAME \
  --resource-group $RESOURCE_GROUP \
  --query hostName -o tsv)

echo "Redis Host: $REDIS_HOST"
echo "Redis Port: 10000"
echo "Identity Client ID: $(az identity show --name $IDENTITY_NAME --resource-group $RESOURCE_GROUP --query clientId -o tsv)"
```

## 🔧 Method 2: Terraform

### Create the following files:

#### providers.tf

```hcl
terraform {
  required_version = ">= 1.0"
  
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azapi" {}
```

#### variables.tf

```hcl
variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-redis-entra-demo"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "redis_name" {
  description = "Name of the Redis cluster"
  type        = string
  default     = "amr-entra-demo"
}

variable "identity_name" {
  description = "Name of the managed identity"
  type        = string
  default     = "id-redis-app"
}
```

#### main.tf

```hcl
# Resource Group
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# User-Assigned Managed Identity
resource "azurerm_user_assigned_identity" "redis_app" {
  name                = var.identity_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# Azure Managed Redis Cluster
resource "azurerm_redis_enterprise_cluster" "main" {
  name                = var.redis_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku_name            = "Balanced_B1"
}

# Azure Managed Redis Database
resource "azurerm_redis_enterprise_database" "main" {
  name                = "default"
  cluster_id          = azurerm_redis_enterprise_cluster.main.id
  client_protocol     = "Encrypted"
  port                = 10000
  
  # Disable access keys to enforce Entra ID auth
  # access_keys_authentication_enabled = false  # Uncomment when ready
}

# Access Policy Assignment (using AzAPI because azurerm doesn't support this yet)
resource "azapi_resource" "redis_access_policy" {
  type      = "Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2024-10-01"
  name      = "app-identity"
  parent_id = azurerm_redis_enterprise_database.main.id
  
  body = {
    properties = {
      accessPolicyName = "default"
      user = {
        objectId = azurerm_user_assigned_identity.redis_app.principal_id
      }
    }
  }

  # Ensure database is fully created first
  depends_on = [azurerm_redis_enterprise_database.main]
}
```

#### outputs.tf

```hcl
output "redis_hostname" {
  description = "Redis hostname"
  value       = azurerm_redis_enterprise_cluster.main.hostname
}

output "redis_port" {
  description = "Redis port"
  value       = 10000
}

output "identity_client_id" {
  description = "Managed identity client ID (use this in AZURE_CLIENT_ID)"
  value       = azurerm_user_assigned_identity.redis_app.client_id
}

output "identity_principal_id" {
  description = "Managed identity principal ID"
  value       = azurerm_user_assigned_identity.redis_app.principal_id
}

output "identity_id" {
  description = "Managed identity resource ID (for App Service assignment)"
  value       = azurerm_user_assigned_identity.redis_app.id
}
```

### Deploy with Terraform

```bash
# Initialize
terraform init

# Plan
terraform plan -out=tfplan

# Apply
terraform apply tfplan
```

## 🔧 Method 3: Bicep

### main.bicep

```bicep
@description('Azure region for resources')
param location string = resourceGroup().location

@description('Name prefix for resources')
param namePrefix string = 'redis-entra'

// User-Assigned Managed Identity
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}-app'
  location: location
}

// Azure Managed Redis Cluster
resource redisCluster 'Microsoft.Cache/redisEnterprise@2024-10-01' = {
  name: 'amr-${namePrefix}'
  location: location
  sku: {
    name: 'Balanced_B1'
    capacity: 2
  }
}

// Azure Managed Redis Database
resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2024-10-01' = {
  parent: redisCluster
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'OSSCluster'
  }
}

// Access Policy Assignment
resource accessPolicy 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2024-10-01' = {
  parent: redisDatabase
  name: 'app-identity'
  properties: {
    accessPolicyName: 'default'
    user: {
      objectId: managedIdentity.properties.principalId
    }
  }
}

// Outputs
output redisHostname string = redisCluster.properties.hostName
output redisPort int = 10000
output identityClientId string = managedIdentity.properties.clientId
output identityPrincipalId string = managedIdentity.properties.principalId
output identityResourceId string = managedIdentity.id
```

### Deploy with Bicep

```bash
# Create resource group
az group create --name rg-redis-entra-demo --location eastus

# Deploy Bicep
az deployment group create \
  --resource-group rg-redis-entra-demo \
  --template-file main.bicep
```

## 🖥️ Assign Identity to Your Application

### For Azure App Service

```bash
# Assign user-assigned managed identity
az webapp identity assign \
  --name your-app-name \
  --resource-group your-rg \
  --identities /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{identity-name}

# Set environment variables
az webapp config appsettings set \
  --name your-app-name \
  --resource-group your-rg \
  --settings \
    AZURE_CLIENT_ID="<identity-client-id>" \
    REDIS_HOSTNAME="<redis-hostname>" \
    REDIS_PORT="10000"
```

### For Azure Virtual Machine

```bash
# Assign user-assigned managed identity
az vm identity assign \
  --name your-vm-name \
  --resource-group your-rg \
  --identities /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{identity-name}
```

### For Azure Container Apps

```bash
az containerapp identity assign \
  --name your-app-name \
  --resource-group your-rg \
  --user-assigned /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{identity-name}
```

## ✅ Verification

### Verify Access Policy Exists

```bash
az rest --method GET \
  --uri "https://management.azure.com/subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.Cache/redisEnterprise/{cluster}/databases/default/accessPolicyAssignments?api-version=2024-10-01"
```

### Test Connection (from Azure resource with identity)

```bash
# Install redis-cli if needed
# For Python testing:
pip install redis redis-entraid

# Test script
python -c "
from redis import Redis
from redis_entraid.cred_provider import create_from_managed_identity, ManagedIdentityType

cred = create_from_managed_identity(
    identity_type=ManagedIdentityType.USER_ASSIGNED,
    resource='https://redis.azure.com/',
)

client = Redis(host='your-redis.region.redis.azure.net', port=10000, credential_provider=cred, ssl=True)
print(client.ping())
"
```

## 🚨 Common Issues

### "invalid username-password pair"
- Access policy assignment is missing
- Run the access policy creation step again

### "Connection refused"
- Check if Redis is running
- Verify network connectivity (VNet/firewall rules)

### "Cannot get token"
- Verify managed identity is assigned to your resource
- Check AZURE_CLIENT_ID environment variable

## 📚 Next Steps

- [Managed Identities Deep Dive](./MANAGED_IDENTITIES.md)
- [Service Principal Setup](./SERVICE_PRINCIPALS.md)
- [Language Examples](../examples/)
