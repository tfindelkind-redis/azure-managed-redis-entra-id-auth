package com.example;

import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.core.TokenAuthConfig;
import redis.clients.authentication.entraid.ManagedIdentityInfo.UserManagedIdentityType;
import redis.clients.jedis.*;
import redis.clients.jedis.authentication.AuthXManager;
import redis.clients.jedis.exceptions.JedisException;

import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Set;

/**
 * Azure Managed Redis - Managed Identity Authentication Example (Jedis)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
 * 
 * Requirements:
 * - Java 17+
 * - Jedis 5.2+
 * - redis-authx-entraid 0.1.1-beta2
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 * 
 * This code should be run from an Azure resource (App Service, VM, etc.)
 * that has the managed identity assigned.
 */
public class ManagedIdentityExample {
    
    private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    public static void main(String[] args) {
        // Load configuration
        String clientId = System.getenv("AZURE_CLIENT_ID");
        String redisHost = System.getenv("REDIS_HOSTNAME");
        int redisPort = Integer.parseInt(System.getenv().getOrDefault("REDIS_PORT", "10000"));

        // Validate configuration
        if (clientId == null || clientId.isEmpty()) {
            System.err.println("Error: AZURE_CLIENT_ID environment variable is required");
            System.exit(1);
        }
        if (redisHost == null || redisHost.isEmpty()) {
            System.err.println("Error: REDIS_HOSTNAME environment variable is required");
            System.exit(1);
        }

        System.out.println("\n" + "=".repeat(60));
        System.out.println("AZURE MANAGED REDIS - JEDIS MANAGED IDENTITY AUTH DEMO");
        System.out.println("=".repeat(60) + "\n");

        try {
            // Create Entra ID authentication configuration for managed identity
            System.out.println("1. Creating authentication configuration...");
            TokenAuthConfig authConfig = EntraIDTokenAuthConfigBuilder.builder()
                .userAssignedManagedIdentity(
                    UserManagedIdentityType.CLIENT_ID,
                    clientId
                )
                .scopes(Set.of("https://redis.azure.com"))
                .build();
            System.out.println("   ✅ Auth config created for managed identity: " + clientId.substring(0, 8) + "...\n");

            // Create AuthXManager for token-based authentication
            System.out.println("2. Creating Jedis client configuration...");
            AuthXManager authXManager = new AuthXManager(authConfig);
            
            // Create Jedis client configuration with authentication
            JedisClientConfig config = DefaultJedisClientConfig.builder()
                .authXManager(authXManager)
                .ssl(true)
                .connectionTimeoutMillis(10000)
                .socketTimeoutMillis(10000)
                .build();
            System.out.println("   ✅ Client config created with SSL enabled\n");

            // Connect to Redis using RedisClient (recommended over deprecated JedisPooled)
            System.out.println("3. Connecting to Redis at " + redisHost + ":" + redisPort + "...");
            try (RedisClient jedis = RedisClient.builder()
                    .hostAndPort(new HostAndPort(redisHost, redisPort))
                    .clientConfig(config)
                    .build()) {
                
                // Test PING
                System.out.println("\n4. Testing PING...");
                String pong = jedis.ping();
                System.out.println("   ✅ PING response: " + pong + "\n");

                // Test SET
                System.out.println("5. Testing SET operation...");
                String testKey = "jedis-entra-test:" + LocalDateTime.now().format(FORMATTER);
                String testValue = "Hello from Jedis with Entra ID auth!";
                jedis.setex(testKey, 60, testValue); // Expires in 60 seconds
                System.out.println("   ✅ SET '" + testKey + "' = '" + testValue + "'\n");

                // Test GET
                System.out.println("6. Testing GET operation...");
                String retrieved = jedis.get(testKey);
                System.out.println("   ✅ GET '" + testKey + "' = '" + retrieved + "'\n");

                // Test INCR
                System.out.println("7. Testing INCR operation...");
                String counterKey = "jedis-counter";
                long newValue = jedis.incr(counterKey);
                System.out.println("   ✅ INCR '" + counterKey + "' = " + newValue + "\n");

                // Test DBSIZE
                System.out.println("8. Getting database size...");
                long dbSize = jedis.dbSize();
                System.out.println("   Database contains " + dbSize + " keys\n");

                // Cleanup
                System.out.println("9. Cleaning up test key...");
                jedis.del(testKey);
                System.out.println("   ✅ Deleted '" + testKey + "'\n");

                System.out.println("=".repeat(60));
                System.out.println("DEMO COMPLETE - All operations successful!");
                System.out.println("=".repeat(60));
            }
        } catch (JedisException e) {
            System.err.println("\n❌ Redis error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        } catch (Exception e) {
            System.err.println("\n❌ Error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }
}
