package com.example;

import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.core.TokenAuthConfig;
import redis.clients.jedis.*;
import redis.clients.jedis.authentication.AuthXManager;
import redis.clients.jedis.exceptions.JedisException;

import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Set;

/**
 * Azure Managed Redis - Service Principal Authentication Example (Jedis)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a Service Principal with Entra ID authentication.
 * 
 * This is useful for:
 * - Local development
 * - CI/CD pipelines
 * - Non-Azure environments
 * 
 * Requirements:
 * - Java 17+
 * - Jedis 5.2+
 * - redis-authx-entraid 0.1.1-beta2
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Application (client) ID of the service principal
 * - AZURE_CLIENT_SECRET: Client secret of the service principal
 * - AZURE_TENANT_ID: Directory (tenant) ID
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 */
public class ServicePrincipalExample {
    
    private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    public static void main(String[] args) {
        // Load configuration
        String clientId = System.getenv("AZURE_CLIENT_ID");
        String clientSecret = System.getenv("AZURE_CLIENT_SECRET");
        String tenantId = System.getenv("AZURE_TENANT_ID");
        String redisHost = System.getenv("REDIS_HOSTNAME");
        int redisPort = Integer.parseInt(System.getenv().getOrDefault("REDIS_PORT", "10000"));

        // Validate configuration
        StringBuilder missing = new StringBuilder();
        if (clientId == null || clientId.isEmpty()) {
            missing.append("AZURE_CLIENT_ID ");
        }
        if (clientSecret == null || clientSecret.isEmpty()) {
            missing.append("AZURE_CLIENT_SECRET ");
        }
        if (tenantId == null || tenantId.isEmpty()) {
            missing.append("AZURE_TENANT_ID ");
        }
        if (redisHost == null || redisHost.isEmpty()) {
            missing.append("REDIS_HOSTNAME ");
        }
        
        if (missing.length() > 0) {
            System.err.println("Error: Missing required environment variables: " + missing.toString().trim());
            System.err.println("\nPlease set:");
            System.err.println("  export AZURE_CLIENT_ID='your-client-id'");
            System.err.println("  export AZURE_CLIENT_SECRET='your-client-secret'");
            System.err.println("  export AZURE_TENANT_ID='your-tenant-id'");
            System.err.println("  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'");
            System.exit(1);
        }

        System.out.println("\n" + "=".repeat(60));
        System.out.println("AZURE MANAGED REDIS - JEDIS SERVICE PRINCIPAL AUTH DEMO");
        System.out.println("=".repeat(60) + "\n");

        try {
            // Create Entra ID authentication configuration for service principal
            System.out.println("1. Creating authentication configuration...");
            String authority = "https://login.microsoftonline.com/" + tenantId;
            
            TokenAuthConfig authConfig = EntraIDTokenAuthConfigBuilder.builder()
                .clientId(clientId)
                .secret(clientSecret)
                .authority(authority)
                .scopes(Set.of("https://redis.azure.com/.default"))
                .build();
            System.out.println("   ✅ Auth config created for service principal: " + clientId.substring(0, 8) + "...\n");

            // Create Jedis client configuration with authentication
            System.out.println("2. Creating Jedis client configuration...");
            AuthXManager authXManager = new AuthXManager(authConfig);
            
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
                String testKey = "jedis-sp-test:" + LocalDateTime.now().format(FORMATTER);
                String testValue = "Hello from Jedis with Service Principal auth!";
                jedis.setex(testKey, 60, testValue);
                System.out.println("   ✅ SET '" + testKey + "' = '" + testValue + "'\n");

                // Test GET
                System.out.println("6. Testing GET operation...");
                String retrieved = jedis.get(testKey);
                System.out.println("   ✅ GET '" + testKey + "' = '" + retrieved + "'\n");

                // Test HSET/HGET (Hash operations)
                System.out.println("7. Testing Hash operations...");
                String hashKey = "jedis-sp-hash";
                jedis.hset(hashKey, "field1", "value1");
                jedis.hset(hashKey, "field2", "value2");
                String hashValue = jedis.hget(hashKey, "field1");
                System.out.println("   ✅ HSET/HGET '" + hashKey + "' field1 = '" + hashValue + "'\n");

                // Test DBSIZE
                System.out.println("8. Getting database size...");
                long dbSize = jedis.dbSize();
                System.out.println("   Database contains " + dbSize + " keys\n");

                // Cleanup
                System.out.println("9. Cleaning up test keys...");
                jedis.del(testKey, hashKey);
                System.out.println("   ✅ Deleted test keys\n");

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
