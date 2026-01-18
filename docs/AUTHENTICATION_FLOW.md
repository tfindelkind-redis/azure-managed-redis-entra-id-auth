# Authentication Flow - Detailed Walkthrough

This document provides a detailed, step-by-step explanation of the Entra ID authentication flow for Azure Managed Redis.

## 🔄 Complete Authentication Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          ENTRA ID AUTHENTICATION FLOW                        │
└─────────────────────────────────────────────────────────────────────────────┘

  ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────────┐
  │          │     │  IMDS/   │     │ Microsoft│     │ Azure Managed│
  │   App    │     │  Entra   │     │ Entra ID │     │    Redis     │
  │          │     │          │     │          │     │              │
  └────┬─────┘     └────┬─────┘     └────┬─────┘     └──────┬───────┘
       │                │                │                  │
       │  1. Request    │                │                  │
       │     Token      │                │                  │
       │───────────────▶│                │                  │
       │                │                │                  │
       │                │  2. Validate   │                  │
       │                │     Identity   │                  │
       │                │───────────────▶│                  │
       │                │                │                  │
       │                │  3. Issue      │                  │
       │                │     Token      │                  │
       │                │◀───────────────│                  │
       │                │                │                  │
       │  4. Return     │                │                  │
       │     Token      │                │                  │
       │◀───────────────│                │                  │
       │                │                │                  │
       │  5. Connect with Token          │                  │
       │     AUTH <oid> <token>          │                  │
       │─────────────────────────────────│─────────────────▶│
       │                │                │                  │
       │                │                │  6. Validate     │
       │                │                │     Token        │
       │                │                │◀─────────────────│
       │                │                │                  │
       │                │                │  7. Token Valid  │
       │                │                │─────────────────▶│
       │                │                │                  │
       │                │                │  8. Check Access │
       │                │                │     Policy       │
       │                │                │                  │
       │  9. Connection Established      │                  │
       │◀────────────────────────────────│──────────────────│
       │                │                │                  │
       │                │                │                  │
       ▼                ▼                ▼                  ▼
```

## 📝 Step-by-Step Breakdown

### Step 1: Application Requests Token

**What happens:** Your application (via the credential provider) requests an access token from Azure.

**For Managed Identity (IMDS):**
```http
GET http://169.254.169.254/metadata/identity/oauth2/token
    ?api-version=2019-08-01
    &resource=https://redis.azure.com/
    &client_id=<managed-identity-client-id>   # For user-assigned only
Headers:
    Metadata: true
```

**For Service Principal:**
```http
POST https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

client_id={client-id}
&client_secret={client-secret}
&scope=https://redis.azure.com/.default
&grant_type=client_credentials
```

### Step 2: Azure Validates Identity

**What happens:** Azure verifies the identity making the request.

**For Managed Identity:**
- IMDS checks if the calling Azure resource has the managed identity assigned
- Validates the resource is within Azure's trusted compute

**For Service Principal:**
- Validates client ID and secret (or certificate)
- Checks if the service principal exists in the tenant

### Step 3: Entra ID Issues Token

**What happens:** If validation passes, Entra ID creates a signed JWT token.

**Token contents:**
```json
{
  "aud": "https://redis.azure.com/",
  "iss": "https://sts.windows.net/{tenant-id}/",
  "iat": 1705555555,
  "exp": 1705559155,
  "oid": "abc123-def456-ghi789",  // Object ID - used as Redis username
  "sub": "abc123-def456-ghi789",
  "tid": "{tenant-id}"
}
```

### Step 4: Token Returned to Application

**What happens:** The credential provider receives and caches the token.

**Example response:**
```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIs...",
  "token_type": "Bearer",
  "expires_in": 3599,
  "resource": "https://redis.azure.com/"
}
```

### Step 5: Application Connects to Redis

**What happens:** The Redis client uses the token to authenticate.

**Redis AUTH command sent:**
```
AUTH <object-id> <token>
```

Where:
- `<object-id>` is the `oid` claim from the token
- `<token>` is the complete access token string

### Step 6: Redis Validates Token

**What happens:** Azure Managed Redis verifies the token with Entra ID.

**Validation checks:**
- ✅ Token signature is valid (signed by Entra ID)
- ✅ Token is not expired (`exp` claim)
- ✅ Token audience is `https://redis.azure.com/`
- ✅ Token issuer is the expected Entra ID endpoint

### Step 7: Token Validation Result

**What happens:** Entra ID confirms the token is valid.

### Step 8: Check Access Policy

**What happens:** Redis checks if the identity has an access policy assignment.

```
Access Policy Check:
┌─────────────────────────────────────────┐
│ Object ID from token: abc123-def456     │
│                                         │
│ Access Policies:                        │
│   - app-identity → abc123-def456 ✅     │
│   - dev-access → xyz789-uvw012          │
│                                         │
│ Result: AUTHORIZED                      │
└─────────────────────────────────────────┘
```

### Step 9: Connection Established

**What happens:** If all checks pass, the connection is established.

The application can now execute Redis commands normally:
```python
client.set("key", "value")
client.get("key")
```

## 🔄 Token Refresh Flow

After initial connection, the client library automatically refreshes tokens:

```
  Time ─────────────────────────────────────────────────────────────▶
   │
   │     Initial          Refresh           Refresh
   │     Connect          Point 1           Point 2
   │        │                │                 │
   │        ▼                ▼                 ▼
   │  ┌──────────┐     ┌──────────┐     ┌──────────┐
   │  │ Token 1  │     │ Token 2  │     │ Token 3  │
   │  │ (~1 hr)  │     │ (~1 hr)  │     │ (~1 hr)  │
   │  └──────────┘     └──────────┘     └──────────┘
   │        │                │                 │
   │        │                │                 │
   │   0 min          ~45 min           ~90 min
   │                     │                 │
   │                     │                 │
   │              Refresh at 75%    Refresh at 75%
   │              of token life     of token life
```

**Refresh process:**
1. Client library monitors token expiration time
2. At ~75% of lifetime (configurable), requests new token
3. Sends new AUTH command to Redis
4. No connection interruption for the application

## 🔐 Security Considerations

### Token Scope
The token is scoped to `https://redis.azure.com/`, meaning it can ONLY be used for Redis authentication. It cannot access other Azure resources.

### Token Lifetime
- Default: ~1 hour (3600 seconds)
- Cannot be used after expiration
- New token required for continued access

### No Secret Storage
With managed identities:
- No secrets in code or config
- IMDS validates the calling resource's identity
- Identity is implicit based on Azure resource

## 🚨 Failure Scenarios

### Scenario 1: Missing Access Policy

```
Error: "invalid username-password pair"

Cause: Identity authenticated successfully, but no access policy exists.

Fix: Create access policy assignment for the identity's Object ID.
```

### Scenario 2: Token Expired

```
Error: "token expired" or connection dropped

Cause: Token refresh failed or wasn't attempted.

Fix: 
- Ensure client library supports auto-refresh
- Check network connectivity to IMDS/Entra ID
```

### Scenario 3: Wrong Audience

```
Error: "invalid token"

Cause: Token was requested for wrong resource.

Fix: Ensure scope/resource is https://redis.azure.com/
```

### Scenario 4: IMDS Not Available

```
Error: "Failed to get token" or connection timeout to 169.254.169.254

Cause: Application not running on Azure or IMDS blocked.

Fix:
- Verify running on Azure resource (VM, App Service, AKS, etc.)
- Check NSG rules don't block IMDS
- For local dev, use Service Principal instead
```

## 📊 Monitoring & Logging

### What to Monitor

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| Token acquisition failures | Failed requests to IMDS/Entra ID | Any failures |
| Token refresh failures | Failed token renewals | > 0 per hour |
| AUTH command failures | Redis authentication errors | Any failures |
| Connection drops | Unexpected disconnections | Unusual spike |

### Recommended Logging

```python
# Example: What to log
logger.info(f"Token acquired, expires at: {token.expires_on}")
logger.info(f"Connecting to Redis: {redis_host}")
logger.info(f"Redis connection established")
logger.debug(f"Token refreshed, new expiry: {new_token.expires_on}")
logger.error(f"Token acquisition failed: {error}")
```

## 📚 Next Steps

- [Azure Setup Guide](./AZURE_SETUP.md) - Configure your Azure resources
- [Troubleshooting Guide](./TROUBLESHOOTING.md) - Common issues and solutions
- [Language Examples](../examples/) - Working code for your platform
