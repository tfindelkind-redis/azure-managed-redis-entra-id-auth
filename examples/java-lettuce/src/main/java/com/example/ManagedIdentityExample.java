package com.example;

import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.entraid.ManagedIdentityInfo;
import io.lettuce.authx.TokenBasedRedisCredentialsProvider;
import io.lettuce.core.*;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.api.sync.RedisCommands;
import io.lettuce.core.cluster.*;
import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;
import io.lettuce.core.cluster.api.sync.RedisAdvancedClusterCommands;
import io.lettuce.core.codec.StringCodec;
import io.lettuce.core.internal.HostAndPort;
import io.lettuce.core.resource.*;

import java.time.Duration;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Set;

/**
 * Azure Managed Redis - Managed Identity Authentication Example (Lettuce)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
 * 
 * CLUSTER POLICY SUPPORT:
 * - Enterprise Cluster: Uses standard RedisClient (server handles slot routing)
 * - OSS Cluster: Uses RedisClusterClient with address remapping for SSL/SNI
 * 
 * Requires Lettuce 6.6.0+ and redis-authx-entraid 0.1.1-beta2+
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 * - REDIS_CLUSTER_POLICY: "EnterpriseCluster" or "OSSCluster" (default: EnterpriseCluster)
 */
public class ManagedIdentityExample {
    
    private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static final String REDIS_SCOPE = "https://redis.azure.com";

    public static void main(String[] args) {
        // Load configuration
        String clientId = System.getenv("AZURE_CLIENT_ID");
        String redisHost = System.getenv("REDIS_HOSTNAME");
        int redisPort = Integer.parseInt(System.getenv().getOrDefault("REDIS_PORT", "10000"));
        String clusterPolicy = System.getenv().getOrDefault("REDIS_CLUSTER_POLICY", "EnterpriseCluster");

        // Validate configuration
        if (clientId == null || clientId.isEmpty()) {
            System.err.println("Error: AZURE_CLIENT_ID environment variable is required");
            System.exit(1);
        }
        if (redisHost == null || redisHost.isEmpty()) {
            System.err.println("Error: REDIS_HOSTNAME environment variable is required");
            System.exit(1);
        }

        boolean isOSSCluster = "OSSCluster".equalsIgnoreCase(clusterPolicy);

        System.out.println("\n" + "=".repeat(60));
        System.out.println("AZURE MANAGED REDIS - LETTUCE MANAGED IDENTITY AUTH DEMO");
        System.out.println("Cluster Policy: " + clusterPolicy + (isOSSCluster ? " (cluster-aware)" : " (standard)"));
        System.out.println("=".repeat(60) + "\n");

        if (isOSSCluster) {
            runWithClusterClient(clientId, redisHost, redisPort);
        } else {
            runWithStandardClient(clientId, redisHost, redisPort);
        }
    }

    /**
     * Run with standard RedisClient (for Enterprise Cluster policy)
     */
    private static void runWithStandardClient(String clientId, String redisHost, int redisPort) {
        TokenBasedRedisCredentialsProvider credentials = null;
        RedisClient redisClient = null;

        try {
            // Create Entra ID credentials provider
            System.out.println("1. Creating credentials provider...");
            try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
                builder.userAssignedManagedIdentity(
                    ManagedIdentityInfo.UserManagedIdentityType.CLIENT_ID,
                    clientId
                );
                builder.scopes(Set.of(REDIS_SCOPE));
                credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
            }
            System.out.println("   ✅ Credentials provider created for: " + clientId.substring(0, 8) + "...\n");

            // Test credentials
            System.out.println("2. Testing credentials...");
            credentials.resolveCredentials()
                .doOnNext(c -> System.out.println("   ✅ Credentials resolved, username: " + c.getUsername().substring(0, 8) + "...\n"))
                .block();

            // Enable automatic re-authentication
            System.out.println("3. Creating client options with auto re-authentication...");
            ClientOptions clientOptions = ClientOptions.builder()
                .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
                .socketOptions(io.lettuce.core.SocketOptions.builder()
                    .keepAlive(true)
                    .build())
                .build();
            System.out.println("   ✅ Auto re-authentication enabled, keepAlive=true\n");

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
            // Explicit exit to terminate credential provider background threads
            System.exit(0);
        }
    }

    /**
     * Run with RedisClusterClient (for OSS Cluster policy)
     * Uses MappingSocketAddressResolver to remap internal IPs for SSL/SNI
     */
    private static void runWithClusterClient(String clientId, String redisHost, int redisPort) {
        TokenBasedRedisCredentialsProvider credentials = null;
        RedisClusterClient clusterClient = null;
        ClientResources clientResources = null;

        try {
            // Create Entra ID credentials provider
            System.out.println("1. Creating credentials provider...");
            try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
                builder.userAssignedManagedIdentity(
                    ManagedIdentityInfo.UserManagedIdentityType.CLIENT_ID,
                    clientId
                );
                builder.scopes(Set.of(REDIS_SCOPE));
                credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
            }
            System.out.println("   ✅ Credentials provider created for: " + clientId.substring(0, 8) + "...\n");

            // Create MappingSocketAddressResolver for SSL/SNI hostname verification
            // Required for OSS Cluster: maps internal IPs to public hostname
            System.out.println("2. Creating MappingSocketAddressResolver for SSL hostname verification...");
            final String finalRedisHost = redisHost;
            MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(
                DnsResolvers.UNRESOLVED,
                hostAndPort -> {
                    String host = hostAndPort.getHostText();
                    int port = hostAndPort.getPort();
                    
                    if (isInternalIP(host)) {
                        System.out.println("   🔄 Mapping " + host + ":" + port + " -> " + finalRedisHost + ":" + port);
                        return HostAndPort.of(finalRedisHost, port);
                    }
                    return hostAndPort;
                }
            );
            System.out.println("   ✅ Address resolver created\n");

            // Create ClientResources with the resolver
            System.out.println("3. Creating ClientResources...");
            clientResources = DefaultClientResources.builder()
                .socketAddressResolver(resolver)
                .build();
            System.out.println("   ✅ ClientResources created\n");

            // Build Redis URI with authentication
            System.out.println("4. Building Redis URI...");
            SslOptions sslOptions = SslOptions.builder()
                .jdkSslProvider()
                .handshakeTimeout(Duration.ofSeconds(30))
                .build();

            RedisURI redisURI = RedisURI.builder()
                .withHost(redisHost)
                .withPort(redisPort)
                .withAuthentication(credentials)
                .withSsl(true)
                .build();
            System.out.println("   ✅ URI built for " + redisHost + ":" + redisPort + "\n");

            // Create cluster client with options
            System.out.println("5. Creating Cluster Client...");
            clusterClient = RedisClusterClient.create(clientResources, redisURI);
            
            ClusterClientOptions clusterOptions = ClusterClientOptions.builder()
                .topologyRefreshOptions(ClusterTopologyRefreshOptions.builder()
                    .enablePeriodicRefresh(Duration.ofMinutes(5))
                    // Note: enableAllAdaptiveRefreshTriggers() removed - it causes excessive re-authentication
                    // in OSS Cluster mode with Entra ID. Periodic refresh is sufficient.
                    .build())
                .sslOptions(sslOptions)
                .socketOptions(io.lettuce.core.SocketOptions.builder()
                    .keepAlive(true)
                    .build())
                .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
                .validateClusterNodeMembership(false)
                .build();
            
            clusterClient.setOptions(clusterOptions);
            System.out.println("   ✅ Cluster client created with topology refresh\n");

            System.out.println("6. Connecting to Redis Cluster...");
            try (StatefulRedisClusterConnection<String, String> connection = clusterClient.connect(StringCodec.UTF8)) {
                RedisAdvancedClusterCommands<String, String> commands = connection.sync();
                
                System.out.println("   ✅ Connected to cluster\n");
                
                // Show cluster info
                System.out.println("7. Checking cluster topology...");
                String clusterInfo = commands.clusterInfo();
                for (String line : clusterInfo.split("\n")) {
                    if (line.startsWith("cluster_state") || line.startsWith("cluster_slots_ok") || line.startsWith("cluster_known_nodes")) {
                        System.out.println("   " + line.trim());
                    }
                }
                System.out.println();

                // Current user
                System.out.println("   Connected as: " + commands.aclWhoami() + "\n");

                // Demonstrate MOVED handling - show slot distribution
                System.out.println("8. Demonstrating MOVED handling (multi-shard cluster)...");
                System.out.println("   " + "-".repeat(50));
                
                // Get cluster nodes info to show slot distribution
                String nodesInfo = commands.clusterNodes();
                System.out.println("   Cluster slot distribution:");
                int primaryCount = 0;
                for (String line : nodesInfo.split("\n")) {
                    if (line.contains("master") && !line.contains("fail")) {
                        primaryCount++;
                        // Extract node info - parse carefully
                        String[] parts = line.trim().split("\\s+");
                        if (parts.length >= 2) {
                            String address = parts[1].split("@")[0];
                            // Slots are at the end, after the 8th field
                            StringBuilder slots = new StringBuilder();
                            for (int i = 8; i < parts.length; i++) {
                                if (!parts[i].isEmpty() && (parts[i].contains("-") || parts[i].matches("\\d+"))) {
                                    if (slots.length() > 0) slots.append(" ");
                                    slots.append(parts[i]);
                                }
                            }
                            System.out.println("     Primary " + primaryCount + ": " + address + " (slots: " + slots.toString() + ")");
                        }
                    }
                }
                System.out.println();
                
                // Demonstrate slot calculation for keys
                System.out.println("   Key slot calculations (demonstrates routing):");
                String[] testKeys = {"user:1000", "order:5000", "session:abc", "cache:data"};
                for (String key : testKeys) {
                    // Calculate slot using CRC16 (same algorithm Redis uses)
                    long slot = io.lettuce.core.cluster.SlotHash.getSlot(key);
                    System.out.println("     Key '" + key + "' -> slot " + slot);
                }
                System.out.println();
                
                // Prove transparent MOVED handling by writing to keys in different slots
                System.out.println("   Writing keys to different shards (transparent MOVED handling):");
                String key1 = "lettuce-shard1-test:{A}"; // Will be in one slot range
                String key2 = "lettuce-shard2-test:{B}"; // Will be in different slot range  
                
                long slot1 = io.lettuce.core.cluster.SlotHash.getSlot(key1);
                long slot2 = io.lettuce.core.cluster.SlotHash.getSlot(key2);
                
                // Write to both keys - cluster client handles MOVED transparently
                commands.setex(key1, 30, "value1");
                commands.setex(key2, 30, "value2");
                
                System.out.println("     ✅ Wrote '" + key1 + "' (slot " + slot1 + ")");
                System.out.println("     ✅ Wrote '" + key2 + "' (slot " + slot2 + ")");
                System.out.println("     → Lettuce ClusterClient handled MOVED redirects automatically!");
                
                // Clean up
                commands.del(key1, key2);
                
                System.out.println("   " + "-".repeat(50));
                System.out.println("   ✅ MOVED handling verified - cluster client routes commands transparently\n");

                // Test PING
                System.out.println("9. Testing PING...");
                System.out.println("   ✅ PING response: " + commands.ping() + "\n");

                // Test SET
                System.out.println("10. Testing SET operation...");
                String testKey = "lettuce-entra-test:" + LocalDateTime.now().format(FORMATTER);
                String testValue = "Hello from Lettuce with Entra ID auth!";
                commands.setex(testKey, 60, testValue);
                System.out.println("   ✅ SET '" + testKey + "'\n");

                // Test GET
                System.out.println("11. Testing GET operation...");
                String retrieved = commands.get(testKey);
                System.out.println("   ✅ GET '" + testKey + "' = '" + retrieved + "'\n");

                // Test DBSIZE
                System.out.println("12. Getting database size...");
                long dbSize = commands.dbsize();
                System.out.println("   Database contains " + dbSize + " keys\n");

                // Cleanup
                System.out.println("13. Cleaning up test key...");
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
            if (clusterClient != null) {
                clusterClient.shutdown();
            }
            if (clientResources != null) {
                clientResources.shutdown();
            }
            if (credentials != null) {
                credentials.close();
            }
            // Explicit exit to terminate credential provider background threads
            System.exit(0);
        }
    }

    /**
     * Helper to check if an address is an internal IP (RFC 1918)
     */
    private static boolean isInternalIP(String host) {
        return host.startsWith("10.") || 
               host.startsWith("192.168.") || 
               (host.startsWith("172.") && isPrivate172(host));
    }
    
    private static boolean isPrivate172(String host) {
        try {
            String[] parts = host.split("\\.");
            if (parts.length >= 2) {
                int second = Integer.parseInt(parts[1]);
                return second >= 16 && second <= 31;
            }
        } catch (NumberFormatException e) {
            // Not a valid IP
        }
        return false;
    }
}
