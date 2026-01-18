# Java (Jedis) - Entra ID Authentication for Azure Managed Redis

This directory contains Java examples using the Jedis client for authenticating to Azure Managed Redis with Microsoft Entra ID.

## 📦 Dependencies

Add to your `pom.xml`:

```xml
<dependencies>
    <!-- Jedis Redis Client -->
    <dependency>
        <groupId>redis.clients</groupId>
        <artifactId>jedis</artifactId>
        <version>7.2.1</version>
    </dependency>
    
    <!-- Entra ID Authentication for Jedis -->
    <dependency>
        <groupId>redis.clients.authentication</groupId>
        <artifactId>redis-authx-entraid</artifactId>
        <version>0.1.1-beta2</version>
    </dependency>
</dependencies>
```

Or for Gradle (`build.gradle`):

```groovy
dependencies {
    implementation 'redis.clients:jedis:7.2.1'
    implementation 'redis.clients.authentication:redis-authx-entraid:0.1.1-beta2'
}
```

## 🔑 Authentication Options

### Option 1: User-Assigned Managed Identity

```java
import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.core.TokenAuthConfig;
import redis.clients.authentication.entraid.ManagedIdentityInfo.UserManagedIdentityType;
import redis.clients.jedis.*;
import redis.clients.jedis.authentication.AuthXManager;
import java.util.Set;

TokenAuthConfig authConfig = EntraIDTokenAuthConfigBuilder.builder()
    .userAssignedManagedIdentity(
        UserManagedIdentityType.CLIENT_ID,
        System.getenv("AZURE_CLIENT_ID")
    )
    .scopes(Set.of("https://redis.azure.com"))
    .build();

AuthXManager authXManager = new AuthXManager(authConfig);

JedisClientConfig config = DefaultJedisClientConfig.builder()
    .authXManager(authXManager)
    .ssl(true)
    .build();

try (RedisClient jedis = RedisClient.builder()
        .hostAndPort(new HostAndPort("your-redis.region.redis.azure.net", 10000))
        .clientConfig(config)
        .build()) {
    System.out.println("PING: " + jedis.ping());
}
```

### Option 2: System-Assigned Managed Identity

```java
TokenAuthConfig authConfig = EntraIDTokenAuthConfigBuilder.builder()
    .systemAssignedManagedIdentity()
    .scopes(Set.of("https://redis.azure.com"))
    .build();
```

### Option 3: Service Principal

```java
TokenAuthConfig authConfig = EntraIDTokenAuthConfigBuilder.builder()
    .clientId(System.getenv("AZURE_CLIENT_ID"))
    .secret(System.getenv("AZURE_CLIENT_SECRET"))
    .authority("https://login.microsoftonline.com/" + System.getenv("AZURE_TENANT_ID"))
    .scopes(Set.of("https://redis.azure.com/.default"))
    .build();
```

## 🌐 Cluster Policy Support

Azure Managed Redis supports two cluster policies:

### EnterpriseCluster (Default)
Standard Redis client works - server handles slot routing internally.

### OSSCluster
Requires cluster-aware client using `RedisClusterClient`:

```java
try (RedisClusterClient jedis = RedisClusterClient.builder()
        .nodes(Collections.singleton(new HostAndPort(redisHost, redisPort)))
        .clientConfig(config)
        .build()) {
    System.out.println("PING: " + jedis.ping());
}
```

## 📁 Project Structure

```
java-jedis/
├── README.md
├── pom.xml
└── src/
    └── main/
        └── java/
            └── com/
                └── example/
                    ├── ManagedIdentityExample.java
                    └── ServicePrincipalExample.java
```

## 🔧 Building and Running

```bash
# Build
mvn clean package

# Run Managed Identity Example (from Azure)
java -cp target/jedis-entra-example-1.0.jar com.example.ManagedIdentityExample

# Run Service Principal Example
export AZURE_CLIENT_ID="your-client-id"
export AZURE_CLIENT_SECRET="your-secret"
export AZURE_TENANT_ID="your-tenant-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
java -cp target/jedis-entra-example-1.0.jar com.example.ServicePrincipalExample
```

## 🔧 Configuration

### Environment Variables

```bash
# For Managed Identity
export AZURE_CLIENT_ID="your-managed-identity-client-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
export REDIS_PORT="10000"

# For Service Principal
export AZURE_CLIENT_ID="your-sp-client-id"
export AZURE_CLIENT_SECRET="your-sp-secret"
export AZURE_TENANT_ID="your-tenant-id"
```

## 🚨 Common Issues

### SSL Certificate Errors

You may need to configure SSL properly:

```java
SSLSocketFactory sslFactory = (SSLSocketFactory) SSLSocketFactory.getDefault();

JedisClientConfig config = DefaultJedisClientConfig.builder()
    .authXManager(new AuthXManager(authConfig))
    .ssl(true)
    .sslSocketFactory(sslFactory)
    .build();
```

### Connection Timeout

```java
JedisClientConfig config = DefaultJedisClientConfig.builder()
    .authXManager(new AuthXManager(authConfig))
    .ssl(true)
    .connectionTimeoutMillis(10000)
    .socketTimeoutMillis(10000)
    .build();
```

## 📚 Resources

- [Jedis Documentation](https://redis.io/docs/latest/develop/clients/jedis/)
- [redis-authx-entraid GitHub](https://github.com/redis/jvm-redis-authx-entraid)
- [Azure Managed Redis Entra ID Docs](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/managed-redis/managed-redis-entra-for-authentication)
