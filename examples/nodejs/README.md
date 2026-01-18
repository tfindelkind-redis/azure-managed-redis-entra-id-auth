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
├── managed_identity_example.mjs
├── service_principal_example.mjs
└── default_credential_example.mjs
```

## 🔧 Cluster Policy Support

The `managed_identity_example.mjs` automatically detects the cluster policy via the `REDIS_CLUSTER_POLICY` environment variable:

- **EnterpriseCluster** (default): Uses `createClient()` - server handles slot routing
- **OSSCluster**: Uses `createCluster()` with `nodeAddressMap` for SSL/SNI validation

```javascript
// The example auto-detects and uses the appropriate client
const clusterPolicy = process.env.REDIS_CLUSTER_POLICY || 'EnterpriseCluster';
if (clusterPolicy === 'OSSCluster') {
    client = createCluster({...});  // Cluster-aware client with nodeAddressMap
} else {
    client = createClient({...});   // Standard client
}
```

## 🔧 Running Examples

```bash
# Install dependencies
npm install

# Run with managed identity (from Azure)
export AZURE_CLIENT_ID="your-managed-identity-client-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
node managed_identity_example.mjs

# Run with service principal (local development)
export AZURE_CLIENT_ID="your-client-id"
export AZURE_CLIENT_SECRET="your-secret"
export AZURE_TENANT_ID="your-tenant-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
node service_principal_example.mjs
```

## 🔧 Configuration

### Environment Variables

```bash
# Required for all
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
export REDIS_PORT="10000"  # Optional, defaults to 10000

# For Managed Identity
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

## 📚 Resources

- [node-redis Documentation](https://redis.io/docs/latest/develop/clients/nodejs/)
- [@redis/entraid GitHub](https://github.com/redis/node-redis/tree/master/packages/entraid)
- [Azure Managed Redis Entra ID Docs](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/managed-redis/managed-redis-entra-for-authentication)
