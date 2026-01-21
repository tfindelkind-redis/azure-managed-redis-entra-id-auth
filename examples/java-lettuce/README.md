# Java (Lettuce) - Entra ID Authentication for Azure Managed Redis

This directory contains Java examples using the Lettuce client for authenticating to Azure Managed Redis with Microsoft Entra ID.

## 📦 Dependencies

Add to your `pom.xml`:

```xml
<dependencies>
    <!-- Lettuce Redis Client -->
    <dependency>
        <groupId>io.lettuce</groupId>
        <artifactId>lettuce-core</artifactId>
        <version>7.2.1.RELEASE</version>
    </dependency>
    
    <!-- Entra ID Authentication for Lettuce -->
    <dependency>
        <groupId>redis.clients.authentication</groupId>
        <artifactId>redis-authx-entraid</artifactId>
        <version>0.1.1-beta2</version>
    </dependency>
</dependencies>
```

## 📁 Project Structure

```
java-lettuce/
├── README.md
├── pom.xml
├── dependencies.json
└── src/
    └── main/
        └── java/
            └── com/
                └── example/
                    ├── UserAssignedManagedIdentityExample.java   # User-Assigned MI
                    ├── SystemAssignedManagedIdentityExample.java # System-Assigned MI
                    └── ServicePrincipalExample.java              # Service Principal
```

## 🔑 Authentication Options

All three examples support **both** cluster policies (Enterprise and OSS Cluster).

| File | Auth Type | Required Env Vars | Use Case |
|------|-----------|-------------------|----------|
| **UserAssignedManagedIdentityExample.java** | User-Assigned MI | `AZURE_CLIENT_ID` | Azure resources with specific identity |
| **SystemAssignedManagedIdentityExample.java** | System-Assigned MI | None | Azure VMs/App Services with auto identity |
| **ServicePrincipalExample.java** | Service Principal | `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` | Non-Azure, CI/CD, local dev |

### Common Environment Variables

```bash
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
export REDIS_PORT=10000  # Optional, default is 10000
export REDIS_CLUSTER_POLICY="OSSCluster"  # or "EnterpriseCluster" (default)
```

---

### Option 1: User-Assigned Managed Identity

Best for Azure resources where you want to control which identity is used.

```java
try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
    builder.userAssignedManagedIdentity(
        ManagedIdentityInfo.UserManagedIdentityType.CLIENT_ID,
        System.getenv("AZURE_CLIENT_ID")
    );
    builder.scopes(Set.of("https://redis.azure.com"));
    credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
}
```

**Run:**
```bash
export AZURE_CLIENT_ID="your-managed-identity-client-id"
mvn exec:java -Dexec.mainClass="com.example.UserAssignedManagedIdentityExample"
```

---

### Option 2: System-Assigned Managed Identity

Simplest option for Azure VMs and App Services - no client ID needed.

```java
try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
    builder.systemAssignedManagedIdentity();
    builder.scopes(Set.of("https://redis.azure.com"));
    credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
}
```

**Run:**
```bash
# No AZURE_CLIENT_ID needed - Azure provides the identity automatically
mvn exec:java -Dexec.mainClass="com.example.SystemAssignedManagedIdentityExample"
```

---

### Option 3: Service Principal

Best for non-Azure environments, CI/CD pipelines, and local development.

```java
try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
    builder.clientId(System.getenv("AZURE_CLIENT_ID"))
           .secret(System.getenv("AZURE_CLIENT_SECRET"))
           .authority("https://login.microsoftonline.com/" + System.getenv("AZURE_TENANT_ID"))
           .scopes(Set.of("https://redis.azure.com/.default"));
    credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
}
```

**Run:**
```bash
export AZURE_CLIENT_ID="your-app-registration-client-id"
export AZURE_CLIENT_SECRET="your-app-registration-secret"
export AZURE_TENANT_ID="your-tenant-id"
mvn exec:java -Dexec.mainClass="com.example.ServicePrincipalExample"
```

---

## 🔧 Cluster Policy Support

All examples auto-detect cluster policy via `REDIS_CLUSTER_POLICY` environment variable:

- **EnterpriseCluster** (default): Uses `RedisClient` - server handles slot routing
- **OSSCluster**: Uses `RedisClusterClient` with `MappingSocketAddressResolver` for SSL/SNI

```java
boolean isOSSCluster = "OSSCluster".equalsIgnoreCase(clusterPolicy);
if (isOSSCluster) {
    runWithClusterClient(...);  // RedisClusterClient with address remapping
} else {
    runWithStandardClient(...); // Standard RedisClient
}
```

### OSS Cluster: MOVED Handling

With OSS Cluster policy, Redis returns `MOVED` responses when keys are on different shards. All examples demonstrate this:

```
Cluster slot distribution:
  Primary 1: 10.0.2.4:8501 (slots: 0-8191)
  Primary 2: 10.0.2.4:8500 (slots: 8192-16383)

Writing keys to different shards (transparent MOVED handling):
  ✅ Wrote 'lettuce-test:{A}' (slot 6373)
  ✅ Wrote 'lettuce-test:{B}' (slot 10374)
  → Lettuce ClusterClient handled MOVED redirects automatically!
```

### MappingSocketAddressResolver for SSL/SNI

OSS Cluster returns internal IPs (e.g., `10.0.2.4:8500`) which would fail SSL certificate validation. All examples use `MappingSocketAddressResolver` to map these to the public hostname:

```java
MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(
    DnsResolvers.UNRESOLVED,  // Let Netty handle DNS for SNI
    hostAndPort -> {
        if (isInternalIP(hostAndPort.getHostText())) {
            // Map internal IP to public hostname for SSL/SNI
            return HostAndPort.of(redisHost, hostAndPort.getPort());
        }
        return hostAndPort;
    }
);
```

---

## 🔧 Building and Running

```bash
# Build
mvn clean compile

# Run User-Assigned Managed Identity example
export AZURE_CLIENT_ID="your-managed-identity-client-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
mvn exec:java -Dexec.mainClass="com.example.UserAssignedManagedIdentityExample"

# Run System-Assigned Managed Identity example (on Azure VM)
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
mvn exec:java -Dexec.mainClass="com.example.SystemAssignedManagedIdentityExample"

# Run Service Principal example
export AZURE_CLIENT_ID="your-app-client-id"
export AZURE_CLIENT_SECRET="your-app-secret"
export AZURE_TENANT_ID="your-tenant-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
mvn exec:java -Dexec.mainClass="com.example.ServicePrincipalExample"
```

---

## 🔧 Key Features

### Automatic Re-authentication

All examples enable automatic re-authentication when tokens are refreshed:

```java
ClientOptions clientOptions = ClientOptions.builder()
    .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
    .socketOptions(SocketOptions.builder().keepAlive(true).build())
    .build();
```

### Test Credentials Before Connection

```java
// Optionally verify credentials work before connecting
credentials.resolveCredentials()
    .doOnNext(c -> System.out.println("Username: " + c.getUsername()))
    .block();
```

---

## 📚 Resources

- [Lettuce Documentation](https://redis.io/docs/latest/develop/clients/lettuce/)
- [redis-authx-entraid GitHub](https://github.com/redis/jvm-redis-authx-entraid)
- [Azure Managed Redis Entra ID Docs](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/managed-redis/managed-redis-entra-for-authentication)
