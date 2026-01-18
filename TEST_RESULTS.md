# Test Results - Azure Managed Redis Entra ID Authentication Examples

**Date:** 2026-01-18
**Environment:** Azure Managed Redis Enterprise (westus3)
**Redis Host:** redis-3ae172dc9e9da.westus3.redis.azure.net:10000
**Test VM:** 4.227.91.227 (debug-vm-3ae172dc9e9da)

## Infrastructure Setup

| Component | Status | Details |
|-----------|--------|---------|
| Azure Managed Redis | ✅ Existing | Balanced_B5 SKU, Enterprise cluster policy |
| User-Assigned Managed Identity | ✅ Created | `redis-test-identity` (5aa192ae-5e22-4aab-8f0c-d53b26e96229) |
| Access Policy Assignment | ✅ Created | `default` policy assigned to identity |
| Test VM Identity | ✅ Assigned | Managed identity attached to debug VM |

## Test Results

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
   ✅ SET 'entra-auth-test:2026-01-18T08:50:22.288416'
3. Testing GET operation...
   ✅ GET = 'Hello from Entra ID authenticated client!'
============================================================
DEMO COMPLETE - All operations successful!
```

### ✅ Node.js (Managed Identity)
- **Status:** PASSED  
- **Package:** `redis` v4.7.0 + `@azure/identity` v4.2.0
- **Operations Tested:** PING, SET, GET, INFO, DELETE
- **Notes:** Uses `ManagedIdentityCredential` to get token, extracts OID from JWT

```
============================================================
AZURE MANAGED REDIS - NODE.JS MANAGED IDENTITY AUTH DEMO
============================================================
1. Creating managed identity credential...
   ✅ Credential created for: 5aa192ae...
2. Acquiring initial token...
   ✅ Token acquired, OID: 8ce652ba-f1cd-4b54-a168-cc09b6d25fed
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
   ✅ Configuration created for: 5aa192ae...
2. Connecting to Redis...
   ✅ Connected to redis-3ae172dc9e9da.westus3.redis.azure.net
3. Testing PING...
   ✅ PING response: 1.6564ms
============================================================
DEMO COMPLETE - All operations successful!
```

### ✅ Java Lettuce (Managed Identity)
- **Status:** PASSED
- **Packages:** `lettuce-core` v6.6.0.RELEASE + `redis-authx-entraid` v0.1.1-beta2
- **Operations Tested:** PING, SET, GET, DBSIZE, DELETE
- **Notes:** Uses `EntraIDTokenAuthConfigBuilder` with `ManagedIdentityInfo.UserManagedIdentityType.CLIENT_ID`
- **Key Learning:** Scope must be `https://redis.azure.com` (without `.default`)

```
============================================================
AZURE MANAGED REDIS - LETTUCE MANAGED IDENTITY AUTH DEMO
============================================================
1. Creating credentials provider...
   ✅ Credentials provider created for: 5aa192ae...
2. Testing credentials...
   ✅ Credentials resolved, username: 8ce652ba...
5. Connecting to Redis...
   Connected as: 8ce652ba-f1cd-4b54-a168-cc09b6d25fed
6. Testing PING...
   ✅ PING response: PONG
============================================================
DEMO COMPLETE - All operations successful!
```

### ⚠️ Java Jedis (Needs Fix)
- **Status:** COMPILATION ERROR
- **Issue:** `redis-authx-entraid` v0.1.1-beta1 has different API than expected
- **Missing Classes:** `UserManagedIdentityType`, `AuthXManager`
- **Action Required:** Update to use current `redis-authx-entraid` API

### ⚠️ Go (Dependency Issue)
- **Status:** DEPENDENCY ERROR
- **Issue:** `github.com/redis-developer/go-redis-entraid` v0.1.0 revision not found
- **Action Required:** Update go.mod to use correct package version

## Authentication Verification

The following confirms Entra ID authentication is working:

1. **Token Acquisition:** Successfully obtained tokens from Azure Instance Metadata Service (IMDS)
2. **Token Format:** JWT with correct audience (`https://redis.azure.com/`)  
3. **AUTH Command:** Successfully authenticated using OID as username and token as password
4. **Access Policy:** Identity recognized by Redis and granted permissions

## Key Configuration Values

```bash
# Environment variables used for testing
export AZURE_CLIENT_ID='5aa192ae-5e22-4aab-8f0c-d53b26e96229'
export REDIS_HOSTNAME='redis-3ae172dc9e9da.westus3.redis.azure.net'
export REDIS_PORT='10000'
export PRINCIPAL_ID='8ce652ba-f1cd-4b54-a168-cc09b6d25fed'
```

## Recommendations

1. **Fix Java Jedis Example:** Update to use correct `redis-authx-entraid` API
2. **Fix Go Example:** Update go.mod with correct package versions
3. **Test Lettuce Spring Boot:** Run the java-lettuce-springboot example
4. **Service Principal Tests:** Test service principal auth for non-Azure environments
5. **Token Refresh Testing:** Run long-duration tests to verify token refresh works
