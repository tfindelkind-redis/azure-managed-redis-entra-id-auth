# .NET - Entra ID Authentication for Azure Managed Redis

This directory contains .NET examples for authenticating to Azure Managed Redis using Microsoft Entra ID.

## 📦 Installation

```bash
dotnet add package StackExchange.Redis
dotnet add package Microsoft.Azure.StackExchangeRedis
```

## 🔑 Authentication Options

### Option 1: User-Assigned Managed Identity

```csharp
using StackExchange.Redis;
using Microsoft.Azure.StackExchangeRedis;

var redisHostname = Environment.GetEnvironmentVariable("REDIS_HOSTNAME")!;
var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID")!;

var configurationOptions = await ConfigurationOptions.Parse($"{redisHostname}:10000")
    .ConfigureForAzureWithUserAssignedManagedIdentityAsync(clientId);

configurationOptions.Ssl = true;
configurationOptions.AbortOnConnectFail = false;

using var connection = await ConnectionMultiplexer.ConnectAsync(configurationOptions);
var db = connection.GetDatabase();

await db.StringSetAsync("test-key", "Hello from .NET!");
var value = await db.StringGetAsync("test-key");
Console.WriteLine($"Value: {value}");
```

### Option 2: System-Assigned Managed Identity

```csharp
var configurationOptions = await ConfigurationOptions.Parse($"{redisHostname}:10000")
    .ConfigureForAzureWithSystemAssignedManagedIdentityAsync();
```

### Option 3: Service Principal

```csharp
var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID")!;
var tenantId = Environment.GetEnvironmentVariable("AZURE_TENANT_ID")!;
var secret = Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET")!;

var configurationOptions = await ConfigurationOptions.Parse($"{redisHostname}:10000")
    .ConfigureForAzureWithServicePrincipalAsync(clientId, tenantId, secret);
```

## 📁 Project Structure

```
dotnet/
├── README.md
├── EntraIdAuth.csproj
├── Program.cs                           # Entry point (detects --cluster flag)
├── ManagedIdentityExample.cs            # Enterprise policy
├── ClusterManagedIdentityExample.cs     # OSS Cluster policy
└── ServicePrincipalExample.cs           # Service principal auth
```

## 🔧 Cluster Policy Support

Azure Managed Redis supports two cluster policies:

### EnterpriseCluster (Default)
Uses standard `ConnectionMultiplexer` - server handles slot routing. See `ManagedIdentityExample.cs`.

### OSSCluster
Uses `ConnectionMultiplexer` with cluster topology discovery. StackExchange.Redis **automatically** handles cluster topology discovery and MOVED/ASK redirections. **No explicit address remapping is needed** unlike other language clients!

```csharp
// StackExchange.Redis handles OSS Cluster transparently
var configurationOptions = await ConfigurationOptions.Parse($"{redisHostname}:10000")
    .ConfigureForAzureWithUserAssignedManagedIdentityAsync(clientId);

configurationOptions.Ssl = true;
configurationOptions.AllowAdmin = true;  // For CLUSTER INFO commands

// The multiplexer automatically:
// - Discovers cluster topology via CLUSTER SLOTS
// - Routes commands to correct shard
// - Handles MOVED/ASK redirects
// - Manages internal IP resolution
using var connection = await ConnectionMultiplexer.ConnectAsync(configurationOptions);
```

See `ClusterManagedIdentityExample.cs` for the full implementation.

## 🔧 Running Examples

```bash
# Restore packages
dotnet restore

# Run with managed identity (from Azure)
export AZURE_CLIENT_ID="your-managed-identity-client-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
dotnet run --ManagedIdentity

# Run with service principal (local development)
export AZURE_CLIENT_ID="your-client-id"
export AZURE_CLIENT_SECRET="your-secret"
export AZURE_TENANT_ID="your-tenant-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
dotnet run --ServicePrincipal
```

## 🔧 Connection Options

### RESP3 Protocol (Recommended for Pub/Sub)

```csharp
configurationOptions.Protocol = RedisProtocol.Resp3;
```

### Custom Token Management

```csharp
configurationOptions.TokenExpirationRefreshRatio = 0.7;
configurationOptions.TokenExpirationRefreshWindow = TimeSpan.FromMinutes(5);
```

### Error Handling

```csharp
using StackExchange.Redis;

try
{
    using var connection = await ConnectionMultiplexer.ConnectAsync(configurationOptions);
    var db = connection.GetDatabase();
    await db.PingAsync();
    Console.WriteLine("Connected successfully!");
}
catch (RedisConnectionException ex)
{
    Console.WriteLine($"Connection failed: {ex.Message}");
    // Check access policy assignment
    // Verify managed identity has correct permissions
}
```

## 📝 Common Issues

### "Invalid username-password pair"
- The managed identity/service principal is not assigned to the Redis access policy
- The access policy assignment is not in effect yet (can take a few minutes)
- Using wrong client ID

### "NOPERM" errors
- The access policy doesn't have required permissions
- Default policy has `+@read +@write +@connection +@fast +@slow` but excludes admin commands

### Connection timeouts
- Ensure SSL/TLS is enabled (Azure Managed Redis requires it)
- Check network connectivity and firewall rules

## 📚 Resources

- [StackExchange.Redis Documentation](https://stackexchange.github.io/StackExchange.Redis/)
- [Microsoft.Azure.StackExchangeRedis NuGet](https://www.nuget.org/packages/Microsoft.Azure.StackExchangeRedis)
- [Azure Managed Redis Entra ID Docs](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/managed-redis/managed-redis-entra-for-authentication)
