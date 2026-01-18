# Python - Entra ID Authentication for Azure Managed Redis

This directory contains Python examples for authenticating to Azure Managed Redis using Microsoft Entra ID.

## 📦 Required Packages

```bash
pip install redis>=5.0.0 redis-entraid>=1.0.0
```

Or use the requirements file:
```bash
pip install -r requirements.txt
```

## 🔑 Authentication Options

### Option 1: User-Assigned Managed Identity (Recommended for Azure)

Best for: Azure App Service, Azure Functions, Azure VMs, Azure Container Apps

```python
from redis import Redis
from redis_entraid.cred_provider import (
    create_from_managed_identity,
    ManagedIdentityType,
    ManagedIdentityIdType
)
import os

# Get configuration from environment
client_id = os.environ["AZURE_CLIENT_ID"]
redis_host = os.environ["REDIS_HOSTNAME"]
redis_port = int(os.environ.get("REDIS_PORT", 10000))

# Create credential provider
credential_provider = create_from_managed_identity(
    identity_type=ManagedIdentityType.USER_ASSIGNED,
    resource="https://redis.azure.com/",
    id_type=ManagedIdentityIdType.CLIENT_ID,
    id_value=client_id
)

# Connect to Redis
client = Redis(
    host=redis_host,
    port=redis_port,
    credential_provider=credential_provider,
    ssl=True,
    decode_responses=True
)

# Test connection
print(client.ping())  # True
```

### Option 2: System-Assigned Managed Identity

Best for: Single-purpose Azure resources

```python
from redis import Redis
from redis_entraid.cred_provider import (
    create_from_managed_identity,
    ManagedIdentityType
)

credential_provider = create_from_managed_identity(
    identity_type=ManagedIdentityType.SYSTEM_ASSIGNED,
    resource="https://redis.azure.com/"
)

client = Redis(
    host="your-redis.region.redis.azure.net",
    port=10000,
    credential_provider=credential_provider,
    ssl=True
)
```

### Option 3: Service Principal (For Local Development)

Best for: Local development, CI/CD pipelines, non-Azure environments

```python
from redis import Redis
from redis_entraid.cred_provider import create_from_service_principal
import os

# Get credentials from environment
client_id = os.environ["AZURE_CLIENT_ID"]
client_secret = os.environ["AZURE_CLIENT_SECRET"]
tenant_id = os.environ["AZURE_TENANT_ID"]

credential_provider = create_from_service_principal(
    client_id=client_id,
    client_secret=client_secret,
    tenant_id=tenant_id
)

client = Redis(
    host=os.environ["REDIS_HOSTNAME"],
    port=10000,
    credential_provider=credential_provider,
    ssl=True,
    decode_responses=True
)
```

## 📁 Example Files

| File | Description |
|------|-------------|
| `managed_identity_example.py` | Complete example using managed identity |
| `service_principal_example.py` | Complete example using service principal |
| `flask_app_example/` | Full Flask application example |

## 🔧 Configuration

### Environment Variables

```bash
# Required for all
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
export REDIS_PORT="10000"  # Optional, defaults to 10000

# For User-Assigned Managed Identity
export AZURE_CLIENT_ID="your-managed-identity-client-id"

# For Service Principal
export AZURE_CLIENT_ID="your-service-principal-client-id"
export AZURE_CLIENT_SECRET="your-client-secret"
export AZURE_TENANT_ID="your-tenant-id"
```

## 🧪 Testing Locally

For local testing, you'll need a Service Principal since IMDS is only available on Azure resources.

1. Create a Service Principal:
```bash
az ad sp create-for-rbac --name "redis-local-dev"
```

2. Create Access Policy for the Service Principal:
```bash
# Get the Object ID of the service principal
SP_OBJECT_ID=$(az ad sp show --id <app-id> --query id -o tsv)

# Create access policy assignment
az rest --method PUT \
  --uri "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Cache/redisEnterprise/{cluster}/databases/default/accessPolicyAssignments/local-dev?api-version=2024-10-01" \
  --body "{
    \"properties\": {
      \"accessPolicyName\": \"default\",
      \"user\": {
        \"objectId\": \"$SP_OBJECT_ID\"
      }
    }
  }"
```

3. Set environment variables and run:
```bash
export AZURE_CLIENT_ID="..."
export AZURE_CLIENT_SECRET="..."
export AZURE_TENANT_ID="..."
export REDIS_HOSTNAME="..."

python service_principal_example.py
```

## 🚨 Common Issues

### "invalid username-password pair"

**Cause:** Access policy assignment is missing for the identity.

**Fix:** Create access policy assignment for the identity's Object ID.

### "Failed to get token from IMDS"

**Cause:** Running locally instead of on Azure, or managed identity not assigned.

**Fix:** 
- Use Service Principal for local development
- Or ensure managed identity is assigned to your Azure resource

### "Connection refused"

**Cause:** Network issues or Redis not accessible.

**Fix:**
- Check firewall rules
- Verify VNet configuration if using private endpoints

## 📚 Resources

- [redis-py Documentation](https://redis.io/docs/latest/develop/clients/redis-py/)
- [redis-entraid GitHub](https://github.com/redis/redis-py-entraid)
- [Azure Managed Redis Entra ID Docs](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/managed-redis/managed-redis-entra-for-authentication)
