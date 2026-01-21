# Node.js - Entra ID Authentication for Azure Managed Redis

This directory contains Node.js examples for authenticating to Azure Managed Redis using Microsoft Entra ID.

## 📦 Installation

```bash
npm install @redis/client @redis/entraid
```

Or create with package.json:
```bash
npm install
```

## 🔑 Authentication Options

### Option 1: User-Assigned Managed Identity

```javascript
import { createClient } from '@redis/client';
import { EntraIdCredentialsProviderFactory } from '@redis/entraid';

const provider = EntraIdCredentialsProviderFactory.createForUserAssignedManagedIdentity({
  clientId: process.env.AZURE_CLIENT_ID,
  userAssignedClientId: process.env.AZURE_CLIENT_ID,
  tokenManagerConfig: {
    expirationRefreshRatio: 0.8
  }
});

const client = createClient({
  url: `rediss://${process.env.REDIS_HOSTNAME}:${process.env.REDIS_PORT || 10000}`,
  credentialsProvider: provider
});

await client.connect();
console.log('PING:', await client.ping());
await client.disconnect();
```

### Option 2: System-Assigned Managed Identity

```javascript
const provider = EntraIdCredentialsProviderFactory.createForSystemAssignedManagedIdentity({
  clientId: process.env.AZURE_CLIENT_ID
});
```

### Option 3: Service Principal

```javascript
const provider = EntraIdCredentialsProviderFactory.createForClientCredentials({
  clientId: process.env.AZURE_CLIENT_ID,
  clientSecret: process.env.AZURE_CLIENT_SECRET,
  authorityConfig: {
    type: 'multi-tenant',
    tenantId: process.env.AZURE_TENANT_ID
  },
  tokenManagerConfig: {
    expirationRefreshRatio: 0.8
  }
});
```

### Option 4: DefaultAzureCredential (Development)

```javascript
import { DefaultAzureCredential } from '@azure/identity';
import { EntraIdCredentialsProviderFactory, REDIS_SCOPE_DEFAULT } from '@redis/entraid';

const credential = new DefaultAzureCredential();

const provider = EntraIdCredentialsProviderFactory.createForDefaultAzureCredential({
  credential,
  scopes: REDIS_SCOPE_DEFAULT,
  tokenManagerConfig: {
    expirationRefreshRatio: 0.8
  }
});
```

## 📁 Project Structure

```
nodejs/
├── README.md
├── package.json
├── dependencies.json
├── user_assigned_managed_identity_example.mjs    # User-Assigned MI
├── system_assigned_managed_identity_example.mjs  # System-Assigned MI
└── service_principal_example.mjs                 # Service Principal auth
```

All examples support both cluster policies via the `REDIS_CLUSTER_POLICY` environment variable.

## 🔧 Cluster Policy Support

Azure Managed Redis supports two cluster policies:

### EnterpriseCluster (Default)
Uses `createClient()` - server handles slot routing.

### OSSCluster
Uses `createCluster()` with `nodeAddressMap` for address remapping. All examples automatically detect this via `REDIS_CLUSTER_POLICY` environment variable. The key challenge is that Azure returns internal IPs in CLUSTER SLOTS responses that are unreachable from outside Azure:

```javascript
import { createCluster } from 'redis';

// Create node address mapper for Azure's internal IPs
// Note: nodeAddressMap receives a string like "10.0.2.4:8500", not an object!
function createNodeAddressMap(publicHostname) {
    return (address) => {
        // address is a string like "10.0.2.4:8500"
        const colonIndex = address.lastIndexOf(':');
        const host = address.substring(0, colonIndex);
        const port = parseInt(address.substring(colonIndex + 1), 10);
        
        // Check if this is a private IP that needs remapping
        if (host.startsWith('10.') || 
            host.startsWith('192.168.') ||
            (host.startsWith('172.') && 
             parseInt(host.split('.')[1]) >= 16 && 
             parseInt(host.split('.')[1]) <= 31)) {
            console.log(`   🔄 Mapping ${host}:${port} -> ${publicHostname}:${port}`);
            return { host: publicHostname, port: port };
        }
        return { host, port };
    };
}

const client = createCluster({
    rootNodes: [{ url: `rediss://${redisHost}:${redisPort}` }],
    useReplicas: true,
    nodeAddressMap: createNodeAddressMap(redisHost),  // Key for OSS Cluster!
    defaults: {
        username: oid,
        password: token
    }
});
```

See any example file for the full implementation - all support both cluster policies.

## 🔧 Running Examples

```bash
# Install dependencies
npm install

# Run User-Assigned Managed Identity example
export AZURE_CLIENT_ID="your-managed-identity-client-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
node user_assigned_managed_identity_example.mjs

# Run System-Assigned Managed Identity example (on Azure VM/Container Apps)
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
node system_assigned_managed_identity_example.mjs

# Run Service Principal example (local development)
export AZURE_CLIENT_ID="your-client-id"
export AZURE_CLIENT_SECRET="your-secret"
export AZURE_TENANT_ID="your-tenant-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
node service_principal_example.mjs

# With OSS Cluster policy
export REDIS_CLUSTER_POLICY="OSSCluster"
node user_assigned_managed_identity_example.mjs
```

## 🔧 Configuration

### Environment Variables

```bash
# Required for all
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
export REDIS_PORT="10000"  # Optional, defaults to 10000
export REDIS_CLUSTER_POLICY="EnterpriseCluster"  # or "OSSCluster"

# For User-Assigned Managed Identity
export AZURE_CLIENT_ID="your-managed-identity-client-id"

# For Service Principal
export AZURE_CLIENT_ID="your-service-principal-client-id"
export AZURE_CLIENT_SECRET="your-client-secret"
export AZURE_TENANT_ID="your-tenant-id"
```

## ⚠️ Important Notes

### RESP2 PUB/SUB Limitations

When using RESP2 protocol with pub/sub:
- Subscription connections cannot be re-authenticated
- Connections will be closed when tokens expire
- Consider using RESP3 for pub/sub workloads

### Transactions

When using transactions with token-based auth:
- Use the `multi()` API, not raw commands
- The client handles re-authentication safely within transactions

## ✅ Test Results

This example has been tested with **Azure Managed Redis (Balanced_B1)** using **OSS Cluster policy**:

| Auth Method | Status |
|-------------|--------|
| User-Assigned MI | ✅ PASS |
| System-Assigned MI | ✅ PASS |
| Service Principal | ✅ PASS |

## 📚 Resources

- [node-redis Documentation](https://redis.io/docs/latest/develop/clients/nodejs/)
- [@redis/entraid GitHub](https://github.com/redis/node-redis/tree/master/packages/entraid)
- [Azure Managed Redis Entra ID Docs](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/managed-redis/managed-redis-entra-for-authentication)
