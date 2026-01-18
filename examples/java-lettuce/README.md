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
        <version>6.4.0.RELEASE</version>
    </dependency>
    
    <!-- Entra ID Authentication for Lettuce -->
    <dependency>
        <groupId>redis.clients.authentication</groupId>
        <artifactId>redis-authx-entraid</artifactId>
        <version>0.1.1-beta1</version>
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
                    ├── ManagedIdentityExample.java
                    └── ServicePrincipalExample.java
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
