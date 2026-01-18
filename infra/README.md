# Azure Infrastructure for Testing Redis Entra ID Examples

This directory contains Azure Developer CLI (`azd`) compatible Bicep templates for deploying a complete test environment.

## What Gets Deployed

1. **Resource Group** - Container for all resources
2. **User-Assigned Managed Identity** - For authenticating to Redis via Entra ID
3. **Virtual Network** - Isolated network with subnets for VM and Redis
4. **Azure Managed Redis** (Cluster OSS tier) - With Entra ID auth enabled
5. **Test VM** (Ubuntu 22.04) - Pre-installed with all runtimes:
   - Python 3.x
   - Node.js 20
   - .NET 8.0
   - Java 17 + Maven
   - Go 1.22
   - Azure CLI
   - NTP (for time sync - critical for Entra ID!)

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)
- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- Azure subscription with permissions to create resources

## Quick Start

```bash
# 1. Login to Azure
azd auth login

# 2. Initialize environment (from repo root)
cd /path/to/azure-managed-redis-entra-id-auth
azd init

# 3. Set the VM password
azd env set VM_ADMIN_PASSWORD "YourSecurePassword123!"

# 4. Deploy
azd up

# 5. Get outputs
azd env get-values
```

## After Deployment

SSH to the test VM and run the examples:

```bash
# Get the SSH command from outputs
SSH_CMD=$(azd env get-values | grep SSH_CONNECTION_STRING | cut -d'=' -f2 | tr -d '"')
$SSH_CMD

# On the VM, clone the examples
git clone https://github.com/YOUR_USERNAME/azure-managed-redis-entra-id-auth.git ~/redis-examples

# Set environment variables
export AZURE_CLIENT_ID="<from azd outputs>"
export REDIS_HOSTNAME="<from azd outputs>"
export REDIS_PORT="10000"

# Run all tests
./run-tests.sh all
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Resource Group                          │
│                                                             │
│  ┌─────────────────┐        ┌─────────────────────────────┐│
│  │   Managed       │        │        Virtual Network       ││
│  │   Identity      │        │  ┌─────────┐ ┌─────────────┐││
│  │                 │        │  │ VM      │ │ Redis       │││
│  │  Used by VM to  │◄───────│  │ Subnet  │ │ Subnet      │││
│  │  auth to Redis  │        │  │         │ │             │││
│  └─────────────────┘        │  │  ┌───┐  │ │  ┌───────┐  │││
│           │                 │  │  │VM │──┼─┼──│ Redis │  │││
│           │                 │  │  └───┘  │ │  └───────┘  │││
│           ▼                 │  └─────────┘ └─────────────┘││
│  ┌─────────────────┐        └─────────────────────────────┘│
│  │  Access Policy  │                                       │
│  │  Assignment     │                                       │
│  │  (Data Owner)   │                                       │
│  └─────────────────┘                                       │
└─────────────────────────────────────────────────────────────┘
```

## Configuration Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `environmentName` | Name prefix for resources | (required) |
| `location` | Azure region | (required) |
| `redisSku` | Redis SKU | `MemoryOptimized_M10` |
| `enableClusterMode` | Enable OSS Cluster mode | `true` |
| `vmAdminUsername` | VM admin user | `azureuser` |
| `vmAdminPassword` | VM admin password | (required) |

## Cleanup

```bash
azd down
```

## Troubleshooting

### Time Sync Issues

If you see token expiration errors, check time sync on the VM:

```bash
# Check NTP status
chronyc tracking

# Force sync
sudo chronyc -a makestep
```

### Network Connectivity

Test Redis connectivity from the VM:

```bash
# DNS resolution
nslookup $REDIS_HOSTNAME

# SSL test
openssl s_client -connect $REDIS_HOSTNAME:10000 -servername $REDIS_HOSTNAME
```

### Managed Identity Issues

Verify the identity is attached and working:

```bash
# Get token using Azure CLI (uses managed identity automatically)
az account get-access-token --resource https://redis.azure.com/

# Check identity metadata
curl -H "Metadata: true" "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://redis.azure.com/"
```
