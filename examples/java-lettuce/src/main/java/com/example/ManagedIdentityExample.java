package com.example;

import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.core.TokenBasedRedisCredentialsProvider;
import redis.clients.authentication.entraid.UserManagedIdentityType;
import io.lettuce.core.*;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.api.sync.RedisCommands;
import io.lettuce.core.codec.StringCodec;

import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

/**
 * Azure Managed Redis - Managed Identity Authentication Example (Lettuce)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
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
        System.out.println("AZURE MANAGED REDIS - LETTUCE MANAGED IDENTITY AUTH DEMO");
        System.out.println("=".repeat(60) + "\n");

        TokenBasedRedisCredentialsProvider credentials = null;
        RedisClient redisClient = null;

        try {
            // Create Entra ID credentials provider
            System.out.println("1. Creating credentials provider...");
            try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
                builder.userAssignedManagedIdentity(
                    UserManagedIdentityType.CLIENT_ID,
                    clientId
                );
                credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
            }
            System.out.println("   ✅ Credentials provider created for: " + clientId.substring(0, 8) + "...\n");

            // Test credentials (optional)
            System.out.println("2. Testing credentials...");
            final TokenBasedRedisCredentialsProvider finalCredentials = credentials;
            credentials.resolveCredentials()
                .doOnNext(c -> System.out.println("   ✅ Credentials resolved, username: " + c.getUsername().substring(0, 8) + "...\n"))
                .block();

            // Enable automatic re-authentication
            System.out.println("3. Creating client options with auto re-authentication...");
            ClientOptions clientOptions = ClientOptions.builder()
                .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
                .build();
            System.out.println("   ✅ Auto re-authentication enabled\n");

            // Build Redis URI
            System.out.println("4. Building Redis URI...");
            RedisURI redisURI = RedisURI.builder()
                .withHost(redisHost)
                .withPort(redisPort)
                .withAuthentication(credentials)
                .withSsl(true)
                .build();
            System.out.println("   ✅ URI built for " + redisHost + ":" + redisPort + "\n");

            // Create Redis client
            System.out.println("5. Connecting to Redis...");
            redisClient = RedisClient.create(redisURI);
            redisClient.setOptions(clientOptions);

            try (StatefulRedisConnection<String, String> connection = redisClient.connect(StringCodec.UTF8)) {
                RedisCommands<String, String> commands = connection.sync();
                
                // Current user
                System.out.println("   Connected as: " + commands.aclWhoami() + "\n");

                // Test PING
                System.out.println("6. Testing PING...");
                System.out.println("   ✅ PING response: " + commands.ping() + "\n");

                // Test SET
                System.out.println("7. Testing SET operation...");
                String testKey = "lettuce-entra-test:" + LocalDateTime.now().format(FORMATTER);
                String testValue = "Hello from Lettuce with Entra ID auth!";
                commands.setex(testKey, 60, testValue);
                System.out.println("   ✅ SET '" + testKey + "'\n");

                // Test GET
                System.out.println("8. Testing GET operation...");
                String retrieved = commands.get(testKey);
                System.out.println("   ✅ GET '" + testKey + "' = '" + retrieved + "'\n");

                // Test DBSIZE
                System.out.println("9. Getting database size...");
                long dbSize = commands.dbsize();
                System.out.println("   Database contains " + dbSize + " keys\n");

                // Cleanup
                System.out.println("10. Cleaning up test key...");
                commands.del(testKey);
                System.out.println("   ✅ Deleted test key\n");

                System.out.println("=".repeat(60));
                System.out.println("DEMO COMPLETE - All operations successful!");
                System.out.println("=".repeat(60));
            }
        } catch (Exception e) {
            System.err.println("\n❌ Error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        } finally {
            if (redisClient != null) {
                redisClient.shutdown();
            }
            if (credentials != null) {
                credentials.close();
            }
        }
    }
}
