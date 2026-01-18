# How Entra ID Authentication Works with Azure Managed Redis

## Overview

Microsoft Entra ID (formerly Azure Active Directory) authentication provides a **passwordless, identity-based** authentication mechanism for Azure Managed Redis. Instead of using static access keys, applications authenticate using OAuth 2.0 tokens issued by Microsoft Entra ID.

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
- Azure Managed Redis (or Azure Cache for Redis Enterprise)
- Entra ID authentication enabled (default for new instances)

### 2. Identity Configuration
Choose one of:
- **System-assigned Managed Identity** - Automatic, tied to Azure resource
- **User-assigned Managed Identity** - Reusable across resources
- **Service Principal** - For non-Azure environments

### 3. Access Policy Assignment
> ⚠️ **Critical Step** - Often missed!

An access policy assignment grants the identity permission to access Redis at the data plane level.

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
1. Application calls the token endpoint (IMDS at `169.254.169.254` for Azure VMs/App Service)
2. Azure validates the managed identity exists and is assigned to this resource
3. Azure returns an OAuth 2.0 access token with:
   - `aud` (audience): `https://redis.azure.com/`
   - `oid` (object ID): Identity's principal ID
   - `exp` (expiration): ~1 hour from now

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
   │  │         ▲            │         ▲            │
   │  │    Refresh at        │    Refresh at        │
   │  │    ~75% lifetime     │    ~75% lifetime     │
   │                              
   │  0 min              ~45 min              ~90 min
```

**What happens:**
1. Client libraries monitor token expiration
2. New token requested before current expires (typically at 75% of lifetime)
3. Redis AUTH command sent with new token
4. No connection interruption

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

## 🚨 Common Misunderstandings

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

### 3. "Do I need to handle token refresh in my code?"

No! All official client libraries handle this automatically. Just configure the credential provider and the library manages the rest.

## 📚 Next Steps

1. [Azure Setup Guide](./AZURE_SETUP.md) - Configure your Azure resources
2. [Managed Identities](./MANAGED_IDENTITIES.md) - Deep dive on identity types
3. [Access Policies](./ACCESS_POLICIES.md) - Configure data plane access
4. [Choose your language example](../examples/) - Working code samples
