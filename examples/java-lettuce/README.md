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
        <version>6.8.2.RELEASE</version>
    </dependency>
    
    <!-- Entra ID Authentication for Lettuce -->
    <dependency>
        <groupId>redis.clients.authentication</groupId>
        <artifactId>redis-authx-entraid</artifactId>
        <version>0.1.1-beta2</version>
    </dependency>
</dependencies>
```

## 🔑 Authentication Options

### Option 1: User-Assigned Managed Identity

```java
import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.core.TokenBasedRedisCredentialsProvider;
import redis.clients.authentication.entraid.UserManagedIdentityType;
import io.lettuce.core.*;
import io.lettuce.core.api.sync.RedisCommands;

// Create credentials provider
TokenBasedRedisCredentialsProvider credentials;
try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
    builder.userAssignedManagedIdentity(
        UserManagedIdentityType.CLIENT_ID,
        System.getenv("AZURE_CLIENT_ID")
    );
    credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
}

// Enable automatic re-authentication
ClientOptions clientOptions = ClientOptions.builder()
    .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
    .build();

// Build Redis URI with authentication
RedisURI redisURI = RedisURI.builder()
    .withHost("your-redis.region.redis.azure.net")
    .withPort(10000)
    .withAuthentication(credentials)
    .withSsl(true)
    .build();

// Connect
RedisClient redisClient = RedisClient.create(redisURI);
redisClient.setOptions(clientOptions);

try (StatefulRedisConnection<String, String> connection = redisClient.connect()) {
    RedisCommands<String, String> commands = connection.sync();
    System.out.println("PING: " + commands.ping());
} finally {
    redisClient.shutdown();
    credentials.close();
}
```

### Option 2: System-Assigned Managed Identity

```java
try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
    builder.systemAssignedManagedIdentity();
    credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
}
```

### Option 3: Service Principal

```java
try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
    builder
        .clientId(System.getenv("AZURE_CLIENT_ID"))
        .secret(System.getenv("AZURE_CLIENT_SECRET"))
        .authority("https://login.microsoftonline.com/" + System.getenv("AZURE_TENANT_ID"))
        .scopes(Set.of("https://redis.azure.com/.default"));
    
    credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
}
```

## 📁 Project Structure

```
java-lettuce/
├── README.md
├── pom.xml
└── src/
    └── main/
        └── java/
            └── com/
                └── example/
                    ├── ManagedIdentityExample.java        # Multi-mode (Enterprise + OSS)
                    └── ClusterManagedIdentityExample.java # OSS Cluster dedicated
```

### Why Two Files?

| File | Cluster Policy | Used By | Purpose |
|------|---------------|---------|---------|
| **ManagedIdentityExample.java** | Both | Manual testing | Single file supporting both policies via `REDIS_CLUSTER_POLICY` env var |
| **ClusterManagedIdentityExample.java** | OSS Cluster | `run.sh` | Dedicated OSS implementation with detailed documentation and MOVED handling demo |

**When to use which:**
- **`ManagedIdentityExample.java`**: Best for understanding how to write code that works with either cluster policy. Auto-detects and switches between `RedisClient` (Enterprise) and `RedisClusterClient` (OSS).
- **`ClusterManagedIdentityExample.java`**: Best for understanding OSS Cluster specifics - includes extensive comments explaining MappingSocketAddressResolver, SSL/SNI, and MOVED handling.

## 🔧 Cluster Policy Support

The `ManagedIdentityExample.java` automatically detects the cluster policy via the `REDIS_CLUSTER_POLICY` environment variable:

- **EnterpriseCluster** (default): Uses `RedisClient` - server handles slot routing
- **OSSCluster**: Uses `RedisClusterClient` with `MappingSocketAddressResolver` for SSL/SNI validation

```java
// The example auto-detects and uses the appropriate client
String clusterPolicy = System.getenv().getOrDefault("REDIS_CLUSTER_POLICY", "EnterpriseCluster");
if ("OSSCluster".equalsIgnoreCase(clusterPolicy)) {
    // Use RedisClusterClient with MappingSocketAddressResolver
    runWithClusterClient(clientId, redisHost, redisPort);
} else {
    // Use standard RedisClient
    runWithStandardClient(clientId, redisHost, redisPort);
}
```

### OSS Cluster: MOVED Handling

With OSS Cluster policy, Redis returns `MOVED` responses when keys are on different shards. The `ClusterManagedIdentityExample.java` demonstrates this:

```java
// Calculate key slots using CRC16 (same algorithm Redis uses)
long slot = io.lettuce.core.cluster.SlotHash.getSlot("user:1000");  // slot 1649

// Lettuce ClusterClient handles MOVED redirects automatically
// Keys on different shards are routed transparently:
commands.setex("key:{A}", 30, "value1");  // slot 6373 -> shard 1
commands.setex("key:{B}", 30, "value2");  // slot 10374 -> shard 2
```

Example output showing MOVED handling:
```
Cluster slot distribution:
  Primary 1: 10.0.2.4:8501 (slots: 0-8191)
  Primary 2: 10.0.2.4:8500 (slots: 8192-16383)

Key slot calculations:
  Key 'user:1000' -> slot 1649
  Key 'session:abc' -> slot 14788

✅ Wrote 'lettuce-moved-test:{A}' (slot 6373)
✅ Wrote 'lettuce-moved-test:{B}' (slot 10374)
→ Lettuce ClusterClient handled MOVED redirects automatically!
```

### MappingSocketAddressResolver for SSL/SNI

OSS Cluster returns internal IPs (e.g., `10.0.2.4:8500`) which would fail SSL certificate validation. The `MappingSocketAddressResolver` maps these to the public hostname:

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

## 🔧 Building and Running

```bash
# Build
mvn clean package

# Run with managed identity
java -cp target/lettuce-entra-example-1.0.jar com.example.ManagedIdentityExample

# Run with service principal
export AZURE_CLIENT_ID="your-client-id"
export AZURE_CLIENT_SECRET="your-secret"
export AZURE_TENANT_ID="your-tenant-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
java -cp target/lettuce-entra-example-1.0.jar com.example.ServicePrincipalExample
```

## 🔧 Key Features

### Automatic Re-authentication

Lettuce supports automatic re-authentication when tokens are refreshed:

```java
ClientOptions clientOptions = ClientOptions.builder()
    .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
    .build();
```

### Test Credentials Before Connection

```java
// Optionally verify credentials work before connecting
credentials.resolveCredentials()
    .doOnNext(c -> System.out.println("Username: " + c.getUsername()))
    .block();
```

## 📚 Resources

- [Lettuce Documentation](https://redis.io/docs/latest/develop/clients/lettuce/)
- [redis-authx-entraid GitHub](https://github.com/redis/jvm-redis-authx-entraid)
- [Azure Managed Redis Entra ID Docs](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/managed-redis/managed-redis-entra-for-authentication)
