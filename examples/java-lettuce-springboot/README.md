# Spring Boot + Lettuce + Azure Managed Redis (Cluster OSS) with Entra ID

This example demonstrates how to connect a **Spring Boot** application to **Azure Managed Redis (Cluster OSS tier)** using **Lettuce** with **Entra ID authentication** via **User-Assigned Managed Identity**.

## 🎯 Key Features

This example specifically addresses common issues with Lettuce + Azure Managed Redis:

### 1. MappingSocketAddressResolver (CRITICAL!)

Azure Managed Redis cluster nodes advertise internal IP addresses in `CLUSTER SLOTS` responses. Without proper address mapping, Lettuce will try to connect directly to these internal IPs and fail.

This example includes a `MappingSocketAddressResolver` that:
- Intercepts connection attempts to internal cluster IPs
- Remaps them to the public Azure hostname
- Ensures all connections go through Azure's load balancer

### 2. Clock Skew Detection

A common cause of Entra ID authentication failures is **clock skew** - when your system's clock is out of sync with Azure's servers.

Symptoms include:
- Tokens appear expired immediately after fetching
- Token expiration dates are in the past
- Intermittent authentication failures

This example includes a `TokenValidationService` that:
- Compares local time to Azure's time
- Validates token timestamps
- Provides clear error messages for clock skew issues

### 3. Automatic Token Refresh

Uses Lettuce's `ReauthenticateBehavior.ON_NEW_CREDENTIALS` to automatically re-authenticate when tokens are refreshed.

## 📋 Prerequisites

1. **Azure Managed Redis** (Cluster OSS tier) with Entra ID authentication enabled
2. **User-Assigned Managed Identity** with access policy in the Redis instance
3. **Azure VM or Container Apps** with the managed identity attached
4. **Java 17+**
5. **Maven**

## 🔧 Configuration

### Environment Variables

```bash
export AZURE_CLIENT_ID="your-managed-identity-client-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
export REDIS_PORT="10000"  # Default for Azure Managed Redis
```

### Application Properties

See `src/main/resources/application.yml` for all configuration options.

## 🚀 Running the Example

```bash
# Build
mvn clean package -DskipTests

# Run
mvn spring-boot:run

# Or with explicit configuration
AZURE_CLIENT_ID=xxx REDIS_HOSTNAME=xxx.redis.azure.net mvn spring-boot:run
```

## 🔍 Troubleshooting

### Token Expiration in the Past

If you see logs like:
```
❌ TOKEN IS ALREADY EXPIRED!
   Expires at: 2024-01-15T10:00:00Z
   Current time: 2024-01-15T10:05:00Z
   Expired 300 seconds ago
```

**Solution**: Synchronize your system clock:
```bash
# On Linux
sudo timedatectl set-ntp true

# On Azure VM, ensure the Azure Guest Agent is running
sudo systemctl status waagent
```

### Connection Refused to 10.x.x.x

If you see connection errors to private IPs:
```
Connection refused: /10.0.0.5:10000
```

**This means the MappingSocketAddressResolver is not working correctly.**

Check that:
1. The `ClientResources` bean with the resolver is being created
2. The resolver is passed to the `RedisClusterClient`
3. Logs show "MappingResolver" entries

### Intermittent Authentication Failures

Can be caused by:
1. **Clock skew** - see above
2. **Token refresh timing** - ensure `ON_NEW_CREDENTIALS` behavior is set
3. **Network latency** - increase timeout values

### ACL WHOAMI Returns Unexpected User

If `ACL WHOAMI` doesn't return your managed identity's OID:
1. Verify the access policy is correctly configured in Azure
2. Check that the OID in the token matches the access policy
3. Ensure you're using the correct managed identity

## 📁 Project Structure

```
├── pom.xml
├── README.md
└── src/main/java/com/example/
    ├── Application.java
    ├── config/
    │   └── RedisClusterConfig.java      # Main configuration with MappingSocketAddressResolver
    └── service/
        ├── TokenValidationService.java  # Clock skew detection and token validation
        └── RedisTestService.java        # Connection tests
```

## 📚 References

- [Azure Cache for Redis - Lettuce Best Practices](https://github.com/Azure/AzureCacheForRedis/blob/main/Lettuce%20Best%20Practices.md)
- [redis-authx-entraid GitHub](https://github.com/redis/redis-authx-java)
- [Lettuce Reference Guide](https://lettuce.io/core/release/reference/)
