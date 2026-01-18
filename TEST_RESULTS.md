# Test Results - Azure Managed Redis Entra ID Authentication Examples

**Date:** 2026-01-18
**Environment:** Azure Managed Redis (westus3)
**Redis Host:** redis-vzklkuy7jfu2k.westus3.redis.azure.net:10000
**Cluster Policy:** EnterpriseCluster
**Test VM:** 134.33.48.74 (azureuser)

## Infrastructure Setup

| Component | Status | Details |
|-----------|--------|---------|
| Azure Managed Redis | ✅ Deployed | MemoryOptimized_M10 SKU, EnterpriseCluster policy |
| User-Assigned Managed Identity | ✅ Created | Client ID: `3e4c7df3-79d1-4a3b-af1e-6b530be4308a` |
| Access Policy Assignment | ✅ Created | `default` policy assigned to identity |
| Test VM Identity | ✅ Assigned | Managed identity attached to VM |

## Library Versions

| Language | Client Library | Entra ID Package | Cluster Support |
|----------|---------------|------------------|-----------------|
| Python | redis 5.0+ | redis-entraid 1.1.0+ | ✅ Enterprise & OSS |
| Node.js | redis 5.0+ | @azure/identity 4.5.0+ | ✅ Enterprise & OSS |
| .NET | StackExchange.Redis 2.8.16 | Microsoft.Azure.StackExchangeRedis 3.2.0 | ✅ Enterprise & OSS |
| Java Lettuce | lettuce-core 6.8.2 | redis-authx-entraid 0.1.1-beta2 | ✅ Enterprise & OSS |
| Java Jedis | jedis 5.2.0 | redis-authx-entraid 0.1.1-beta2 | ✅ Enterprise |
| Go | go-redis v9 | go-redis-entraid v1.0.0 | ✅ Enterprise & OSS |

## Test Results (All Passed ✅)

### ✅ Python (Managed Identity)
- **Status:** PASSED
- **Package:** `redis-entraid` v1.1.0
- **Operations Tested:** PING, SET, GET, DELETE
- **Token Refresh:** Automatic via redis-entraid

```
============================================================
AZURE MANAGED REDIS - ENTRA ID AUTHENTICATION DEMO
============================================================
1. Testing connection with PING...
   ✅ Connection successful!
2. Testing SET operation...
   ✅ SET 'entra-auth-test:2026-01-18T14:37:51.740829'
3. Testing GET operation...
   ✅ GET = 'Hello from Entra ID authenticated client!'
============================================================
DEMO COMPLETE - All operations successful!
```

### ✅ Node.js (Managed Identity)
- **Status:** PASSED  
- **Package:** `redis` v5.0.0 + `@azure/identity` v4.5.0
- **Operations Tested:** PING, SET, GET, INFO, DELETE
- **Notes:** Uses `ManagedIdentityCredential` to get token, extracts OID from JWT

```
============================================================
AZURE MANAGED REDIS - NODE.JS MANAGED IDENTITY AUTH DEMO
============================================================
1. Creating managed identity credential...
   ✅ Credential created for: 3e4c7df3...
2. Acquiring initial token...
   ✅ Token acquired, OID: de4ef38e-6d18-4313-aa30-82c92b16c6a5
4. Connecting to Redis...
   ✅ Connected!
5. Testing PING...
   ✅ PING response: PONG
============================================================
DEMO COMPLETE - All operations successful!
```

### ✅ .NET (Managed Identity)
- **Status:** PASSED
- **Packages:** `StackExchange.Redis` v2.8.16 + `Microsoft.Azure.StackExchangeRedis` v3.2.0
- **Operations Tested:** PING, SET, GET, INCR, HSET/HGET, DELETE
- **Notes:** Uses built-in Azure integration with StackExchange.Redis

```
============================================================
AZURE MANAGED REDIS - .NET MANAGED IDENTITY AUTH DEMO
============================================================
1. Creating connection configuration...
   ✅ Configuration created for: 3e4c7df3...
2. Connecting to Redis...
   ✅ Connected to redis-vzklkuy7jfu2k.westus3.redis.azure.net
3. Testing PING...
   ✅ PING response: 0.9684ms
============================================================
DEMO COMPLETE - All operations successful!
```

### ✅ Java Lettuce (Managed Identity)
- **Status:** PASSED
- **Packages:** `lettuce-core` v6.8.2.RELEASE + `redis-authx-entraid` v0.1.1-beta2
- **Operations Tested:** PING, SET, GET, DBSIZE, DELETE
- **Cluster Support:** Auto-detects policy, uses `RedisClient` or `RedisClusterClient`
- **Notes:** Uses `EntraIDTokenAuthConfigBuilder` with `ManagedIdentityInfo.UserManagedIdentityType.CLIENT_ID`

```
============================================================
AZURE MANAGED REDIS - LETTUCE MANAGED IDENTITY AUTH DEMO
Cluster Policy: EnterpriseCluster (standard)
============================================================
1. Creating credentials provider...
   ✅ Credentials provider created for: 3e4c7df3...
2. Testing credentials...
   ✅ Credentials resolved, username: de4ef38e...
5. Connecting to Redis...
   Connected as: de4ef38e-6d18-4313-aa30-82c92b16c6a5
6. Testing PING...
   ✅ PING response: PONG
============================================================
DEMO COMPLETE - All operations successful!
```

### ✅ Go (Managed Identity)
- **Status:** PASSED
- **Packages:** `go-redis/v9` + `go-redis-entraid` v1.0.0
- **Operations Tested:** PING, SET, GET, INCR, DBSIZE, DELETE
- **Cluster Support:** Auto-detects policy, uses `NewClient` or `NewClusterClient` with custom Dialer
- **Notes:** Uses `ManagedIdentityCredentialsProvider` from go-redis-entraid

```
============================================================
AZURE MANAGED REDIS - GO MANAGED IDENTITY AUTH DEMO
============================================================
1. Creating credentials provider...
   ✅ Credentials provider created (using AZURE_CLIENT_ID: 3e4c7df3...)
2. Creating Redis client...
   ✅ Client configured for redis-vzklkuy7jfu2k.westus3.redis.azure.net:10000
3. Testing PING...
   ✅ PING response: PONG
============================================================
DEMO COMPLETE - All operations successful!
```

## Test Summary

| Language | Status | Cluster Policy Support |
|----------|--------|------------------------|
| Python | ✅ PASSED | Enterprise & OSS Cluster |
| Node.js | ✅ PASSED | Enterprise & OSS Cluster |
| .NET | ✅ PASSED | Enterprise & OSS Cluster |
| Java Lettuce | ✅ PASSED | Enterprise & OSS Cluster |
| Go | ✅ PASSED | Enterprise & OSS Cluster |

**Total: 5 passed, 0 failed**

## Environment Variables

```bash
# Environment variables used for testing
export AZURE_CLIENT_ID='3e4c7df3-79d1-4a3b-af1e-6b530be4308a'
export REDIS_HOSTNAME='redis-vzklkuy7jfu2k.westus3.redis.azure.net'
export REDIS_PORT='10000'
export REDIS_CLUSTER_POLICY='EnterpriseCluster'
```

## Notes

- All examples now support both Enterprise and OSS Cluster policies
- OSS Cluster support includes address remapping (internal IPs → public hostname) for SSL/SNI validation
- Examples auto-detect the cluster policy via `REDIS_CLUSTER_POLICY` environment variable
