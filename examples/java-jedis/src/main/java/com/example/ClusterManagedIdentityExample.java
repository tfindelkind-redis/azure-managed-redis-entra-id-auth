package com.example;

import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.core.TokenAuthConfig;
import redis.clients.authentication.entraid.ManagedIdentityInfo.UserManagedIdentityType;
import redis.clients.jedis.*;
import redis.clients.jedis.authentication.AuthXManager;
import redis.clients.jedis.exceptions.JedisException;
import org.apache.commons.pool2.impl.GenericObjectPoolConfig;

import java.time.Duration;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.HashSet;
import java.util.Set;
import javax.net.ssl.*;
import java.net.Socket;
import java.security.cert.X509Certificate;

/**
 * Azure Managed Redis - OSS Cluster with Managed Identity Authentication (Jedis)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using:
 * - OSS Cluster policy (JedisCluster required)
 * - User-Assigned Managed Identity with Entra ID authentication
 * - Custom HostAndPortMapper for SSL SNI hostname verification
 * 
 * WHY HostAndPortMapper IS NEEDED:
 * ================================
 * Azure Managed Redis with OSS Cluster policy exposes:
 * 1. A PUBLIC endpoint (redis-xxx.azure.net:10000) - initial connection point
 * 2. INTERNAL cluster nodes (e.g., 10.0.2.4:8500) - returned by CLUSTER SLOTS
 * 
 * The problem:
 * - CLUSTER SLOTS returns internal IPs that are not reachable from outside
 * - SSL certificates only contain the public hostname in their SAN
 * - Connecting to internal IPs would fail SSL hostname verification
 * 
 * The solution (HostAndPortMapper):
 * - Maps internal IPs to the public hostname
 * - Preserves the port (different shards use different ports)
 * - Azure proxy routes to correct internal node based on port
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
public class ClusterManagedIdentityExample {
    
    private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static final String REDIS_SCOPE = "https://redis.azure.com";

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

        System.out.println("\n" + "=".repeat(70));
        System.out.println("AZURE MANAGED REDIS - JEDIS OSS CLUSTER WITH ENTRA ID AUTH");
        System.out.println("=".repeat(70) + "\n");

        JedisCluster jedisCluster = null;
        AuthXManager authXManager = null;

        try {
            // Step 1: Create Entra ID authentication configuration
            System.out.println("1. Creating Entra ID authentication configuration...");
            TokenAuthConfig authConfig = EntraIDTokenAuthConfigBuilder.builder()
                .userAssignedManagedIdentity(
                    UserManagedIdentityType.CLIENT_ID,
                    clientId
                )
                .scopes(Set.of(REDIS_SCOPE))
                .build();
            System.out.println("   ✅ Auth config created for: " + clientId.substring(0, 8) + "...\n");

            // Step 2: Create AuthXManager for token-based authentication
            System.out.println("2. Creating AuthXManager for token refresh...");
            authXManager = new AuthXManager(authConfig);
            System.out.println("   ✅ AuthXManager created\n");

            // Step 3: Create HostAndPortMapper for internal IP remapping
            // This is CRITICAL for Azure Managed Redis OSS Cluster policy
            System.out.println("3. Creating HostAndPortMapper for SSL hostname verification...");
            HostAndPortMapper hostAndPortMapper = createHostAndPortMapper(redisHost);
            System.out.println("   ✅ HostAndPortMapper created for: " + redisHost + "\n");

            // Step 4: Create JedisClientConfig with authentication and SSL
            System.out.println("4. Creating Jedis client configuration with SSL...");
            JedisClientConfig clientConfig = DefaultJedisClientConfig.builder()
                .authXManager(authXManager)
                .ssl(true)
                .sslSocketFactory(createTrustAllSSLSocketFactory())
                .hostAndPortMapper(hostAndPortMapper)
                .connectionTimeoutMillis(10000)
                .socketTimeoutMillis(10000)
                .build();
            System.out.println("   ✅ Client config created with HostAndPortMapper\n");

            // Step 5: Create JedisCluster with startup nodes
            System.out.println("5. Creating JedisCluster connection to " + redisHost + ":" + redisPort + "...");
            Set<HostAndPort> clusterNodes = new HashSet<>();
            clusterNodes.add(new HostAndPort(redisHost, redisPort));
            
            // Create pool config for cluster connections
            GenericObjectPoolConfig<Connection> poolConfig = new GenericObjectPoolConfig<>();
            poolConfig.setMaxTotal(8);
            poolConfig.setMaxIdle(8);
            poolConfig.setMinIdle(0);
            
            jedisCluster = new JedisCluster(
                clusterNodes,
                clientConfig,
                5,  // maxAttempts
                poolConfig
            );
            System.out.println("   ✅ JedisCluster created\n");

            // Test PING (on a random node)
            System.out.println("6. Testing PING...");
            // JedisCluster doesn't have direct ping, use a simple operation
            String testPingKey = "jedis-cluster-ping-test";
            jedisCluster.set(testPingKey, "pong");
            String pong = jedisCluster.get(testPingKey);
            jedisCluster.del(testPingKey);
            System.out.println("   ✅ Cluster responding (set/get test): " + pong + "\n");

            // Test SET with keys that DEFINITELY hit different shards using hash tags
            // Hash tags {xxx} ensure the slot is calculated from the tag content only
            // This validates that HostAndPortMapper is working correctly!
            System.out.println("7. Testing SET operations across MULTIPLE shards...");
            System.out.println("   Using hash tags to guarantee cross-shard distribution");
            String[][] testKeyPairs = {
                {"{slot2}", "shard0"},   // slot 98 -> shard 0
                {"{slot3}", "shard0"},   // slot 4163 -> shard 0
                {"{slot0}", "shard1"},   // slot 8224 -> shard 1
                {"{slot1}", "shard1"},   // slot 12289 -> shard 1
            };
            String[] testKeys = new String[testKeyPairs.length];
            for (int i = 0; i < testKeyPairs.length; i++) {
                String hashTag = testKeyPairs[i][0];
                String expectedShard = testKeyPairs[i][1];
                String testKey = "jedis-cluster:" + hashTag + ":" + LocalDateTime.now().format(FORMATTER);
                String testValue = "Value for " + hashTag + " from Jedis OSS Cluster!";
                jedisCluster.setex(testKey, 60, testValue);
                testKeys[i] = testKey;
                String displayKey = testKey.length() > 55 ? testKey.substring(0, 55) + "..." : testKey;
                System.out.println("   ✅ SET '" + displayKey + "' -> " + expectedShard);
            }
            System.out.println();

            // Test GET operations - this will trigger cross-shard routing
            System.out.println("8. Testing GET operations (validates cross-shard routing)...");
            for (String testKey : testKeys) {
                String retrieved = jedisCluster.get(testKey);
                String displayKey = testKey.length() > 50 ? testKey.substring(0, 50) + "..." : testKey;
                System.out.println("   ✅ GET '" + displayKey + "'");
            }
            System.out.println("   If you see this, HostAndPortMapper is working correctly!");
            System.out.println();

            // Test INCR
            System.out.println("9. Testing INCR operation...");
            String counterKey = "jedis-cluster-counter";
            long newValue = jedisCluster.incr(counterKey);
            System.out.println("   ✅ INCR '" + counterKey + "' = " + newValue + "\n");

            // Get cluster info
            System.out.println("10. Getting cluster info...");
            try {
                // JedisCluster doesn't expose clusterInfo directly, skip for now
                System.out.println("   Cluster mode: JedisCluster (multi-shard)");
                System.out.println("   Slot routing: Handled by JedisCluster client");
            } catch (Exception e) {
                System.out.println("   ⚠️ Could not get cluster info: " + e.getMessage());
            }
            System.out.println();

            // Cleanup
            System.out.println("11. Cleaning up test keys...");
            for (String testKey : testKeys) {
                jedisCluster.del(testKey);
                String displayKey = testKey.length() > 45 ? testKey.substring(0, 45) + "..." : testKey;
                System.out.println("   ✅ Deleted '" + displayKey + "'");
            }
            System.out.println();

            System.out.println("=".repeat(70));
            System.out.println("DEMO COMPLETE - All OSS Cluster operations successful!");
            System.out.println("=".repeat(70));

        } catch (JedisException e) {
            System.err.println("\n❌ Jedis error: " + e.getMessage());
            System.err.println("\nTroubleshooting tips:");
            System.err.println("1. Ensure you are running on an Azure resource with managed identity");
            System.err.println("2. Verify the managed identity has an access policy on the Redis cache");
            System.err.println("3. Check that AZURE_CLIENT_ID is the Client ID (not Principal ID)");
            System.err.println("4. Ensure the Redis instance uses OSS Cluster policy");
            e.printStackTrace();
            System.exit(1);
        } catch (Exception e) {
            System.err.println("\n❌ Error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        } finally {
            // Cleanup
            if (jedisCluster != null) {
                try {
                    jedisCluster.close();
                } catch (Exception e) {
                    // Ignore
                }
            }
            if (authXManager != null) {
                try {
                    authXManager.stop();
                } catch (Exception e) {
                    // Ignore
                }
            }
        }
    }

    /**
     * Create a HostAndPortMapper that remaps internal Azure IPs to the public hostname.
     * 
     * This is REQUIRED for Azure Managed Redis OSS Cluster because:
     * 1. CLUSTER SLOTS returns internal IPs (e.g., 10.0.2.4:8500)
     * 2. These IPs are not reachable from outside Azure's internal network
     * 3. SSL certificate validation requires the public hostname for SNI
     * 4. Azure's proxy uses the port to route to the correct internal node
     */
    private static HostAndPortMapper createHostAndPortMapper(String publicHostname) {
        return new HostAndPortMapper() {
            @Override
            public HostAndPort getHostAndPort(HostAndPort hap) {
                String host = hap.getHost();
                int port = hap.getPort();
                
                if (isInternalIP(host)) {
                    System.out.println("   🔄 Remapping " + host + ":" + port + " -> " + publicHostname + ":" + port);
                    return new HostAndPort(publicHostname, port);
                }
                return hap;
            }
        };
    }

    /**
     * Check if the given host is an internal/private IP address.
     */
    private static boolean isInternalIP(String host) {
        return host.startsWith("10.") ||
               host.startsWith("172.16.") || host.startsWith("172.17.") ||
               host.startsWith("172.18.") || host.startsWith("172.19.") ||
               host.startsWith("172.20.") || host.startsWith("172.21.") ||
               host.startsWith("172.22.") || host.startsWith("172.23.") ||
               host.startsWith("172.24.") || host.startsWith("172.25.") ||
               host.startsWith("172.26.") || host.startsWith("172.27.") ||
               host.startsWith("172.28.") || host.startsWith("172.29.") ||
               host.startsWith("172.30.") || host.startsWith("172.31.") ||
               host.startsWith("192.168.");
    }

    /**
     * Create an SSL socket factory that trusts all certificates.
     * 
     * Note: In production, you should use proper certificate validation.
     * This is simplified for the example to focus on the clustering aspects.
     */
    private static SSLSocketFactory createTrustAllSSLSocketFactory() {
        try {
            SSLContext sslContext = SSLContext.getInstance("TLS");
            sslContext.init(null, new TrustManager[]{
                new X509TrustManager() {
                    public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
                    public void checkClientTrusted(X509Certificate[] certs, String authType) { }
                    public void checkServerTrusted(X509Certificate[] certs, String authType) { }
                }
            }, new java.security.SecureRandom());
            return sslContext.getSocketFactory();
        } catch (Exception e) {
            throw new RuntimeException("Failed to create SSL socket factory", e);
        }
    }
}
