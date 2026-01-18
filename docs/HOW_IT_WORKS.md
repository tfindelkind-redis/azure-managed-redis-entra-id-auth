# How Entra ID Authentication Works with Azure Managed Redis

## Overview

Microsoft Entra ID (formerly Azure Active Directory) authentication provides a **passwordless, identity-based** authentication mechanism for Azure Managed Redis. Instead of using static access keys, applications authenticate using OAuth 2.0 tokens issued by Microsoft Entra ID.

> **Note:** Azure Managed Redis uses Microsoft Entra ID authentication **by default** for new instances. When you create a new cache, managed identity is automatically enabled.

## 🔑 Core Concepts

### Traditional Authentication (Access Keys)

```
┌──────────────┐                    ┌─────────────────┐
│              │   Static Password  │                 │
│  Application │───────────────────▶│  Azure Redis    │
│              │   (Access Key)     │                 │
└──────────────┘                    └─────────────────┘
```

**Problems:**
- Keys are static secrets that can be leaked
- Manual rotation required
- No identity-based audit trail
- Keys often stored in config files or environment variables

### Entra ID Authentication (Token-Based)

```
                    ┌─────────────────┐
                    │  Microsoft      │
                    │  Entra ID       │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
              ▼                             ▼
       1. Request Token              4. Validate Token
              │                             │
┌─────────────┴─────────────┐   ┌──────────┴───────────┐
│                           │   │                      │
│       Application         │──▶│   Azure Managed      │
│                           │   │   Redis              │
└───────────────────────────┘   └──────────────────────┘
       2. Receive Token           3. Connect with Token
```

**Benefits:**
- ✅ No static secrets to manage
- ✅ Automatic token rotation (~1 hour lifetime)
- ✅ Full audit trail with identity information
- ✅ Centralized access control
- ✅ Can revoke access instantly

## 📋 Prerequisites

### 1. Azure Managed Redis Instance
- Azure Managed Redis (any tier: Memory Optimized, Balanced, Compute Optimized, or Flash Optimized)
- Entra ID authentication enabled (default for new instances)
- **SSL/TLS required** - Entra ID authentication only works over encrypted connections

### 2. Identity Configuration
Choose one of:
- **System-assigned Managed Identity** - Automatic, tied to Azure resource lifecycle
- **User-assigned Managed Identity** - Reusable across multiple resources
- **Service Principal** - For non-Azure environments or CI/CD pipelines

### 3. Access Policy Assignment (Data Access Configuration)
> ⚠️ **Critical Step** - Often missed!

An access policy assignment grants the identity permission to access Redis at the **data plane** level. Azure provides three built-in access policies:

| Policy | Permissions |
|--------|-------------|
| **Data Owner** | Full access - all commands on all keys |
| **Data Contributor** | Read and write access |
| **Data Reader** | Read-only access |

You can also create **custom access policies** using Redis ACL syntax for fine-grained control.

## 🔄 Authentication Flow - Step by Step

### Phase 1: Token Acquisition

```
Step 1: Application requests token
┌───────────────┐     GET /token     ┌──────────────────┐
│               │──────────────────▶ │  Azure Instance  │
│  Application  │                    │  Metadata Service│
│               │◀──────────────────│  (IMDS)          │
└───────────────┘  OAuth 2.0 Token   └──────────────────┘
```

**What happens:**
1. Application calls the token endpoint with the Redis scope
2. Azure validates the managed identity exists and is assigned to this resource
3. Azure returns an OAuth 2.0 access token with:
   - `aud` (audience): `https://redis.azure.com/`
   - `oid` (object ID): Identity's principal ID
   - `exp` (expiration): ~1 hour from now
   - `iat` (issued at): Current timestamp
   - `nbf` (not before): When token becomes valid

**Token Scope:**
```
https://redis.azure.com/.default
```
or (alternative format):
```
acca5fbb-b7e4-4009-81f1-37e38fd66d78/.default
```

### Phase 2: Redis Connection

```
Step 2: Connect to Redis with token as password
┌───────────────┐    AUTH <oid> <token>   ┌────────────────┐
│               │────────────────────────▶│                │
│  Application  │                         │  Azure Managed │
│  (Redis       │◀────────────────────────│  Redis         │
│   Client)     │    Connection OK        │                │
└───────────────┘                         └────────────────┘
```

**What happens:**
1. Redis client uses the token as the password in the AUTH command
2. Username is the Object ID of the identity
3. Redis validates the token with Entra ID
4. Redis checks if the identity has an access policy assignment
5. Connection established if valid

### Phase 3: Token Refresh (Automatic)

```
Step 3: Continuous token refresh (handled by client library)

  Time ─────────────────────────────────────────────────────▶
   │
   │  Token 1                Token 2                Token 3
   │  ├──────────────────────┤──────────────────────┤───────
   │  │                      │                      │
   │  │      ▲               │      ▲               │
   │  │  Refresh at least    │  Refresh at least    │
   │  │  3 min before expiry │  3 min before expiry │
   │                              
   │  0 min              ~57 min              ~117 min
```

**What happens:**
1. Client libraries monitor token expiration
2. New token requested **at least 3 minutes before** current expires (per Microsoft best practices)
3. Redis AUTH command sent with new token
4. No connection interruption

> ⚠️ **Best Practice:** Microsoft recommends sending a new token at least **3 minutes before expiry** to avoid connection disruption. Consider adding jitter (random delay) to stagger AUTH commands across multiple clients.

### Phase 4: Re-authentication on Connection Loss

When connections drop (network issues, failover, etc.), clients must:
1. Obtain a fresh token
2. Re-establish connection with new AUTH

## 🌐 Cluster Policy Impact on Client Handling

Azure Managed Redis supports different **cluster policies** that significantly affect how your client library must be configured:

### Cluster Policies Overview

| Policy | Description | Client Requirement | Port |
|--------|-------------|-------------------|------|
| **OSS Cluster** | Uses native Redis Cluster protocol. Data distributed across shards. | **Cluster-aware client required** | Default |
| **Enterprise** | Single-endpoint proxy. Server handles data distribution. | Standard (non-cluster) client | Default |
| **Non-Clustered** | Single shard, ≤25GB only | Standard client | N/A (smaller SKUs) |

### OSS Cluster Policy (Most Common for Large Deployments)

When using **OSS Cluster** policy:

```
┌─────────────────────────────────────────────────────────────┐
│                    OSS Cluster Architecture                  │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   Client                   Azure Managed Redis               │
│   ┌─────┐                  ┌──────────────────┐             │
│   │     │──CLUSTER NODES──▶│  Primary Endpoint │             │
│   │     │◀────────────────│  (Proxy to Shard)│             │
│   │     │                  └──────────────────┘             │
│   │     │                           │                       │
│   │     │   Receives internal       │ Routes based on       │
│   │     │   node addresses          │ hash slot             │
│   │     │   (85XX ports)            ▼                       │
│   │     │                  ┌─────────────────────┐          │
│   │     │                  │ Shard 0 │ Shard 1  │...        │
│   └─────┘                  │(10.x.x) │(10.x.x)  │           │
│                            └─────────────────────┘          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Critical: MappingSocketAddressResolver**

With OSS cluster policy, Redis uses the `CLUSTER NODES` command to inform clients about shard topology. This returns **internal IP addresses** (e.g., `10.x.x.x:85XX`) that are not directly reachable from your application.

You **must** configure a `MappingSocketAddressResolver` (in Lettuce) or similar mechanism to:
1. Map internal cluster IPs back to the public hostname
2. Ensure SSL certificate validation works (cert is for public hostname)

```java
// Java Lettuce Example - Required for OSS Cluster
MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(
    DnsResolvers.UNRESOLVED,
    hostAndPort -> HostAndPort.of(publicHostName, hostAndPort.getPort())
);
```

**Lettuce Configuration Requirements for OSS Cluster:**
```java
ClusterTopologyRefreshOptions topologyOptions = ClusterTopologyRefreshOptions.builder()
    .enablePeriodicRefresh(Duration.ofSeconds(5))
    .dynamicRefreshSources(false)  // Required - do NOT use dynamic sources
    .adaptiveRefreshTriggersTimeout(Duration.ofSeconds(5))
    .build();
```

> ⚠️ **Critical:** `dynamicRefreshSources(false)` is **required** for Azure Managed Redis. Without this, Lettuce may try to connect directly to internal IPs and fail.

### Enterprise Cluster Policy

When using **Enterprise** policy:
- Azure proxy handles all data distribution
- Client connects to a single endpoint
- **No cluster-aware client needed**
- Simpler configuration, but only available on certain tiers

### Node.js ioredis Cluster Configuration

```javascript
// For OSS Cluster policy
const redis = new Redis.Cluster([{
  host: 'your-cache.redis.azure.com',
  port: 10000
}], {
  dnsLookup: (address, callback) => callback(null, address),
  redisOptions: {
    tls: { servername: 'your-cache.redis.azure.com' },
    password: async () => await getToken(),
    username: principalId
  },
  // Map internal IPs to public hostname
  natMap: {
    // Will be populated based on CLUSTER NODES response
  }
});
```

### Python redis-py-cluster

```python
# For OSS Cluster policy
from rediscluster import RedisCluster

rc = RedisCluster(
    host='your-cache.redis.azure.com',
    port=10000,
    ssl=True,
    ssl_cert_reqs='required',
    password=token,
    username=principal_id,
    # address_remap function for internal IP mapping
)
```

## 🏛️ Architecture Components

### 1. Microsoft Entra ID (Identity Provider)
- Issues OAuth 2.0 tokens
- Validates identity claims
- Manages token lifecycle

### 2. Azure Instance Metadata Service (IMDS)
- **Endpoint:** `http://169.254.169.254/metadata/identity/oauth2/token`
- Available only from within Azure resources
- Provides tokens for managed identities
- No credentials required (identity is implicit)

### 3. Access Policy Assignment
- Maps an identity to Redis permissions
- Required for data plane access
- Different from RBAC (control plane)

```
┌─────────────────────────────────────────────────────────┐
│                  Azure Managed Redis                     │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  Access Policy Assignments:                             │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Name: app-identity                              │   │
│  │ Policy: default                                 │   │
│  │ User Object ID: abc123-def456-...              │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │ Name: developer-access                          │   │
│  │ Policy: default                                 │   │
│  │ User Object ID: xyz789-uvw012-...              │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## 🔐 Token Structure

An Entra ID token for Redis looks like this (decoded JWT):

```json
{
  "header": {
    "typ": "JWT",
    "alg": "RS256",
    "kid": "key-id"
  },
  "payload": {
    "aud": "https://redis.azure.com/",
    "iss": "https://sts.windows.net/{tenant-id}/",
    "iat": 1705555555,
    "exp": 1705559155,
    "oid": "abc123-def456-ghi789-...",
    "sub": "abc123-def456-ghi789-...",
    "tid": "tenant-id",
    "azp": "client-id"
  }
}
```

**Key Claims:**
- `aud`: Audience - must be `https://redis.azure.com/`
- `oid`: Object ID - used as Redis username
- `exp`: Expiration time - typically ~1 hour
- `tid`: Tenant ID - your Azure AD tenant

## 🔄 Client Library Responsibilities

All official client libraries handle:

| Responsibility | Handled By |
|---------------|-----------|
| Initial token acquisition | ✅ Client library |
| Token caching | ✅ Client library |
| Token refresh before expiration | ✅ Client library |
| Retry on transient failures | ✅ Client library |
| Re-authentication on connection loss | ✅ Client library |

**Your code only needs to:**
1. Configure the credential provider
2. Create the Redis client
3. Use Redis normally

## 🆚 Comparison: Access Keys vs Entra ID

| Aspect | Access Keys | Entra ID |
|--------|------------|----------|
| **Secret Storage** | Required (key in config) | Not needed |
| **Rotation** | Manual (disruptive) | Automatic (seamless) |
| **Audit Trail** | Limited | Full identity tracking |
| **Revocation** | Change key everywhere | Remove access policy |
| **Multi-app Access** | Share key (risky) | Individual identities |
| **Connection Setup** | Simple | Slightly more complex |
| **Security** | Lower | Higher |

## 🚨 Common Issues & Troubleshooting

### 1. "I have RBAC role, why doesn't auth work?"

**RBAC** (Role-Based Access Control) controls the **control plane** (Azure management operations).
**Access Policy** controls the **data plane** (Redis operations).

You need BOTH:
- RBAC role for Azure management (optional, for infrastructure)
- Access Policy for Redis data access (required)

### 2. "My token is valid, but I get 'invalid username-password'"

This usually means:
- Access policy assignment is missing
- Object ID in token doesn't match any access policy
- Token audience is wrong (should be `https://redis.azure.com/`)
- **Clock skew** - your system time differs from Azure's time

### 3. "Do I need to handle token refresh in my code?"

No! All official client libraries handle this automatically. Just configure the credential provider and the library manages the rest.

### 4. "Tokens appear to expire in the past"

**Clock Skew Issue:** If your system clock is ahead of Azure's time, tokens may appear already expired when received.

**Fix:** Sync your system clock with NTP:
```bash
# Linux
sudo ntpdate -u time.windows.com

# Check current offset
ntpq -p
```

### 5. "Connection refused to 10.x.x.x addresses"

**Cluster IP Mapping Issue:** With OSS cluster policy, Redis advertises internal IPs that aren't reachable.

**Fix:** Configure `MappingSocketAddressResolver` (Lettuce) or `natMap` (ioredis) to map internal IPs back to the public hostname.

### 6. "SSL certificate validation fails"

When connecting to internal cluster IPs, the SSL cert won't match (it's issued for the public hostname).

**Fix:** Always connect via the public hostname. Use socket address mapping instead of connecting directly to internal IPs.

### 7. "MOVED errors in cluster mode"

The client doesn't recognize it's in cluster mode.

**Fix:** 
- Ensure you're using a cluster-aware client
- For Lettuce: Use `RedisClusterClient` not `RedisClient`
- For ioredis: Use `Redis.Cluster` not `Redis`

> 📖 **For detailed troubleshooting:** See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)

## 📚 Next Steps

1. [Azure Setup Guide](./AZURE_SETUP.md) - Configure your Azure resources
2. [Managed Identities](./MANAGED_IDENTITIES.md) - Deep dive on identity types
3. [Access Policies](./ACCESS_POLICIES.md) - Configure data plane access
4. [Choose your language example](../examples/) - Working code samples
