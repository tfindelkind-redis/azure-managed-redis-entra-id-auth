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
 * Azure Managed Redis - User-Assigned Managed Identity Authentication (Jedis)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
 * 
 * CLUSTER POLICY SUPPORT:
 * - Enterprise Cluster: ✅ Fully supported (server handles slot routing)
 * - OSS Cluster: ⚠️ Limited - Jedis with Entra ID doesn't fully support cluster mode
 *   Use Lettuce for OSS Cluster with Entra ID authentication
 * 
 * Requirements:
 * - Java 17+
 * - Jedis 5.2+
 * - redis-authx-entraid 0.1.1-beta2
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Client ID of the user-assigned managed identity (REQUIRED)
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 * - REDIS_CLUSTER_POLICY: "EnterpriseCluster" or "OSSCluster" (default: EnterpriseCluster)
 * 
 * This code should be run from an Azure resource (App Service, VM, etc.)
 * that has the managed identity assigned.
 */
public class UserAssignedManagedIdentityExample {
    
    private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static final String REDIS_SCOPE = "https://redis.azure.com";

    public static void main(String[] args) {
        String clientId = System.getenv("AZURE_CLIENT_ID");
        String redisHost = System.getenv("REDIS_HOSTNAME");
        int redisPort = Integer.parseInt(System.getenv().getOrDefault("REDIS_PORT", "10000"));
        String clusterPolicy = System.getenv().getOrDefault("REDIS_CLUSTER_POLICY", "EnterpriseCluster");

        if (clientId == null || clientId.isEmpty()) {
            System.err.println("Error: AZURE_CLIENT_ID environment variable is required");
            System.exit(1);
        }
        if (redisHost == null || redisHost.isEmpty()) {
            System.err.println("Error: REDIS_HOSTNAME environment variable is required");
            System.exit(1);
        }

        boolean isOSSCluster = "OSSCluster".equalsIgnoreCase(clusterPolicy);

        System.out.println("\n" + "=".repeat(70));
        System.out.println("AZURE MANAGED REDIS - USER-ASSIGNED MI (JEDIS)");
        System.out.println("Cluster Policy: " + clusterPolicy + (isOSSCluster ? " (limited support)" : " (full support)"));
        System.out.println("=".repeat(70) + "\n");

        if (isOSSCluster) {
            System.out.println("⚠️  WARNING: Jedis with Entra ID has limited OSS Cluster support.");
            System.out.println("   For OSS Cluster, consider using Lettuce instead.\n");
        }

        try {
            System.out.println("1. Creating authentication configuration...");
            TokenAuthConfig authConfig = EntraIDTokenAuthConfigBuilder.builder()
                .userAssignedManagedIdentity(UserManagedIdentityType.CLIENT_ID, clientId)
                .scopes(Set.of(REDIS_SCOPE))
                .build();
            System.out.println("   ✅ Auth config created for: " + clientId.substring(0, 8) + "...\n");

            System.out.println("2. Creating Jedis client configuration...");
            AuthXManager authXManager = new AuthXManager(authConfig);
            
            JedisClientConfig config = DefaultJedisClientConfig.builder()
                .authXManager(authXManager)
                .ssl(true)
                .connectionTimeoutMillis(10000)
                .socketTimeoutMillis(10000)
                .build();
            System.out.println("   ✅ Client config created with SSL enabled\n");

            System.out.println("3. Connecting to Redis at " + redisHost + ":" + redisPort + "...\n");
            try (RedisClient jedis = RedisClient.builder()
                    .hostAndPort(new HostAndPort(redisHost, redisPort))
                    .clientConfig(config)
                    .build()) {
                
                runDemoOperations(jedis, isOSSCluster);
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

    private static void runDemoOperations(RedisClient jedis, boolean isOSSCluster) {
        System.out.println("4. Testing PING...");
        String pong = jedis.ping();
        System.out.println("   ✅ PING response: " + pong + "\n");

        System.out.println("5. Testing SET operation...");
        String testKey = "jedis-usermi-test:" + LocalDateTime.now().format(FORMATTER);
        String testValue = "Hello from Jedis with User-Assigned MI!";
        jedis.setex(testKey, 60, testValue);
        System.out.println("   ✅ SET '" + testKey + "' = '" + testValue + "'\n");

        System.out.println("6. Testing GET operation...");
        String retrieved = jedis.get(testKey);
        System.out.println("   ✅ GET '" + testKey + "' = '" + retrieved + "'\n");

        System.out.println("7. Testing INCR operation...");
        String counterKey = "jedis-usermi-counter";
        long newValue = jedis.incr(counterKey);
        System.out.println("   ✅ INCR '" + counterKey + "' = " + newValue + "\n");

        System.out.println("8. Getting database size...");
        long dbSize = jedis.dbSize();
        System.out.println("   Database contains " + dbSize + " keys\n");

        System.out.println("9. Cleaning up test key...");
        jedis.del(testKey);
        System.out.println("   ✅ Deleted '" + testKey + "'\n");

        System.out.println("=".repeat(70));
        System.out.println("DEMO COMPLETE - All operations successful!");
        System.out.println("=".repeat(70));
    }
}
