# Spring Boot + Lettuce + Azure Managed Redis with Entra ID

This example demonstrates how to connect a **Spring Boot** application to **Azure Managed Redis** using **Lettuce** with **Entra ID authentication**.

## 🎯 Key Features

### Three Authentication Methods (via Spring Profiles)

| Profile | Auth Method | Required Environment Variables |
|---------|-------------|-------------------------------|
| `user-mi` | User-Assigned Managed Identity | `AZURE_CLIENT_ID`, `REDIS_HOSTNAME` |
| `system-mi` | System-Assigned Managed Identity | `REDIS_HOSTNAME` |
| `service-principal` | Service Principal | `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `REDIS_HOSTNAME` |

### Two Cluster Policies

| Policy | Client Type | Use Case |
|--------|-------------|----------|
| `EnterpriseCluster` | Standard `RedisClient` | Server handles slot routing (default) |
| `OSSCluster` | `RedisClusterClient` | Client-side cluster-aware with address remapping |

### MappingSocketAddressResolver (for OSS Cluster)

Azure Managed Redis cluster nodes advertise internal IP addresses in `CLUSTER SLOTS` responses. For OSS Cluster policy, this example includes a `MappingSocketAddressResolver` that:
- Intercepts connection attempts to internal cluster IPs
- Remaps them to the public Azure hostname for SSL/SNI verification
- Ensures all connections work correctly through Azure's load balancer

## 📋 Prerequisites

1. **Azure Managed Redis** with Entra ID authentication enabled
2. **Managed Identity** or **Service Principal** with access policy in the Redis instance
3. **Azure VM or Container Apps** with the identity attached (for managed identity auth)
4. **Java 17+**
5. **Maven**

## 🔧 Configuration

### Environment Variables

```bash
# Common - Required for all auth methods
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
export REDIS_PORT="10000"  # Default for Azure Managed Redis
export REDIS_CLUSTER_POLICY="EnterpriseCluster"  # or "OSSCluster"

# For User-Assigned Managed Identity (profile: user-mi)
export AZURE_CLIENT_ID="your-managed-identity-client-id"

# For Service Principal (profile: service-principal)
export AZURE_CLIENT_ID="your-sp-client-id"
export AZURE_CLIENT_SECRET="your-sp-client-secret"
export AZURE_TENANT_ID="your-tenant-id"
```

### Application Properties

See `src/main/resources/application.yml` for all configuration options.

## 🚀 Running the Example

### With User-Assigned Managed Identity
```bash
export AZURE_CLIENT_ID="your-mi-client-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"

mvn spring-boot:run -Dspring-boot.run.profiles=user-mi
```

### With System-Assigned Managed Identity
```bash
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"

mvn spring-boot:run -Dspring-boot.run.profiles=system-mi
```

### With Service Principal
```bash
export AZURE_CLIENT_ID="your-sp-client-id"
export AZURE_CLIENT_SECRET="your-sp-secret"
export AZURE_TENANT_ID="your-tenant-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"

mvn spring-boot:run -Dspring-boot.run.profiles=service-principal
```

### With OSS Cluster Policy
```bash
export REDIS_CLUSTER_POLICY="OSSCluster"
mvn spring-boot:run -Dspring-boot.run.profiles=user-mi
```

## 📁 Project Structure

```
java-lettuce-springboot/
├── README.md
├── pom.xml
├── dependencies.json
└── src/main/
    ├── java/com/example/
    │   ├── Application.java           # Spring Boot entry point
    │   ├── config/
    │   │   └── RedisConfig.java       # Unified Redis configuration
    │   │                               # - Supports all 3 auth methods
    │   │                               # - Supports both cluster policies
    │   │                               # - MappingSocketAddressResolver for OSS Cluster
    │   └── service/
    │       └── RedisTestService.java  # Demo operations (PING, SET, GET, etc.)
    └── resources/
        └── application.yml            # Configuration with profile support
```

## 🔍 How It Works

### Profile-Based Authentication

The `RedisConfig` class reads `azure.auth.type` from the active profile and creates the appropriate credentials provider:

```java
switch (authType) {
    case "user-assigned-managed-identity":
        authConfig = EntraIDTokenAuthConfigBuilder.builder()
            .userAssignedManagedIdentity(CLIENT_ID, managedIdentityClientId)
            .scopes(Set.of(REDIS_SCOPE))
            .build();
        break;
        
    case "system-assigned-managed-identity":
        authConfig = EntraIDTokenAuthConfigBuilder.builder()
            .systemAssignedManagedIdentity()
            .scopes(Set.of(REDIS_SCOPE))
            .build();
        break;
        
    case "service-principal":
        authConfig = EntraIDTokenAuthConfigBuilder.builder()
            .clientId(servicePrincipalClientId)
            .secret(servicePrincipalClientSecret)
            .authority("https://login.microsoftonline.com/" + tenantId)
            .scopes(Set.of(REDIS_SCOPE + "/.default"))
            .build();
        break;
}
```

### Cluster Policy-Based Client Selection

The configuration creates either a standard `RedisClient` or `RedisClusterClient` based on the cluster policy:

- **EnterpriseCluster**: Uses `RedisClient` - server handles slot routing transparently
- **OSSCluster**: Uses `RedisClusterClient` with `MappingSocketAddressResolver` for address remapping

## ✅ Test Results

This example has been tested with **Azure Managed Redis (Balanced_B1)** using **OSS Cluster policy**:

| Auth Method | Status |
|-------------|--------|
| User-Assigned MI | ✅ PASS |
| System-Assigned MI | ✅ PASS |
| Service Principal | ✅ PASS |

## 🔧 Troubleshooting

### Connection Refused to 10.x.x.x (OSS Cluster)

If you see connection errors to private IPs with OSS Cluster:
```
Connection refused: /10.0.0.5:10000
```

This means address mapping isn't working. Ensure:
1. `REDIS_CLUSTER_POLICY=OSSCluster` is set
2. The `MappingSocketAddressResolver` is being created

### Token Expiration Issues

If tokens appear expired immediately:
1. Check system clock: `date`
2. Sync with NTP: `sudo timedatectl set-ntp true`

### "Unknown auth type" Error

Ensure you're running with a valid Spring profile:
```bash
-Dspring-boot.run.profiles=user-mi   # or system-mi, service-principal
```

### Excessive "Maintenance events not supported" Messages

This can occur if topology refresh triggers are too aggressive. The application includes logging suppression in `application.yml` for Lettuce handshake messages. If you still see these, ensure:
1. Topology refresh is set to a reasonable interval (5+ minutes)
2. `enableAllAdaptiveRefreshTriggers()` is NOT used (causes constant re-auth)

## 📚 Dependencies

- **Spring Boot 3.3+**
- **Lettuce 6.5+** with cluster support
- **redis-authx-entraid 0.1.1-beta2** for Entra ID authentication
- **Azure Identity** for token management
