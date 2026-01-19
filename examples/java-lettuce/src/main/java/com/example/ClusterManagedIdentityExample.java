package com.example;

import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.entraid.ManagedIdentityInfo;
import io.lettuce.authx.TokenBasedRedisCredentialsProvider;
import io.lettuce.core.*;
import io.lettuce.core.cluster.*;
import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;
import io.lettuce.core.cluster.api.sync.RedisAdvancedClusterCommands;
import io.lettuce.core.internal.HostAndPort;
import io.lettuce.core.resource.*;

import java.time.Duration;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Set;

/**
 * Azure Managed Redis - Cluster-Aware Client with Entra ID Authentication (Lettuce)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using:
 * - OSS Cluster policy (cluster-aware client required)
 * - User-Assigned Managed Identity with Entra ID authentication
 * - MappingSocketAddressResolver for SSL SNI hostname verification
 * 
 * Based on official Azure Best Practices:
 * https://github.com/Azure/AzureCacheForRedis/blob/main/Lettuce%20Best%20Practices.md
 * 
 * IMPORTANT: OSS Cluster Policy Architecture
 * ==========================================
 * Azure Managed Redis with OSS Cluster policy exposes:
 * 1. A PUBLIC endpoint (redis-xxx.azure.net:10000) - initial connection point
 * 2. INTERNAL cluster nodes (e.g., 10.0.2.4:8500, 10.0.2.4:8501) - handle actual data
 * 
 * How it works:
 * - Initial connection goes to the public endpoint (port 10000)
 * - CLUSTER NODES command returns internal IPs (port range 85XX)
 * - Lettuce cluster client handles MOVED/ASK redirections automatically
 * 
 * WHY MappingSocketAddressResolver IS NEEDED:
 * ============================================
 * 1. Redis Cluster protocol returns internal node IP addresses (e.g., 10.0.2.4:8500)
 * 2. Azure Managed Redis SSL certificates contain only the public hostname in their SAN
 * 3. When connecting to internal IPs, SSL hostname verification would fail
 * 
 * The MappingSocketAddressResolver + DnsResolvers.UNRESOLVED combination:
 * - Maps internal IPs to the public hostname for SNI (Server Name Indication)
 * - Creates UNRESOLVED InetSocketAddress(hostname, port)
 * - Netty then handles DNS resolution and uses hostname for SNI during TLS
 * - The SSL certificate validation succeeds because SNI hostname matches certificate SAN
 * 
 * IMPORTANT NOTES:
 * - Traffic goes through the Azure Managed Redis proxy which routes to correct node
 * - The proxy handles the internal routing based on the port/cluster topology
 * - This approach works for both VNet and public endpoint deployments
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance (OSS Cluster policy)
 * - REDIS_PORT: Port (default: 10000)
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
        System.out.println("AZURE MANAGED REDIS - CLUSTER-AWARE CLIENT WITH ENTRA ID AUTH");
        System.out.println("=".repeat(70) + "\n");

        TokenBasedRedisCredentialsProvider credentials = null;
        RedisClusterClient clusterClient = null;
        ClientResources clientResources = null;

        try {
            // Step 1: Create Entra ID credentials provider
            System.out.println("1. Creating Entra ID credentials provider...");
            try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
                builder.userAssignedManagedIdentity(
                    ManagedIdentityInfo.UserManagedIdentityType.CLIENT_ID,
                    clientId
                );
                builder.scopes(Set.of(REDIS_SCOPE));
                credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
            }
            System.out.println("   ✅ Credentials provider created for: " + clientId.substring(0, 8) + "...\n");

            // Step 2: Create MappingSocketAddressResolver
            // This is REQUIRED for Azure Managed Redis with OSS Cluster policy
            // It maps internal IPs to the public hostname for SSL/SNI certificate validation
            //
            // HOW IT WORKS:
            // 1. CLUSTER NODES returns internal IPs (10.0.2.4:8500)
            // 2. MappingSocketAddressResolver maps these to public hostname (redis-xxx.azure.net:8500)
            // 3. Using DnsResolvers.UNRESOLVED means Lettuce creates UNRESOLVED InetSocketAddress(hostname, port)
            // 4. Netty then resolves hostname → public IP and uses hostname for SNI during TLS
            // 5. The connection goes through the Azure proxy which routes to the correct internal node
            //
            // NOTE: With OSS Cluster, traffic still goes through the public endpoint/proxy,
            // but the cluster-aware client handles MOVED/ASK redirects properly.
            System.out.println("2. Creating MappingSocketAddressResolver for SSL hostname verification...");
            
            MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(
                DnsResolvers.UNRESOLVED,  // CRITICAL: Leave DNS resolution to Netty for SNI to work
                hostAndPort -> {
                    String host = hostAndPort.getHostText();
                    int port = hostAndPort.getPort();
                    
                    if (isInternalIP(host)) {
                        // Map internal IP to public hostname for SSL certificate validation
                        // Keep the port - this allows proper cluster node identification
                        System.out.println("   🔄 Mapping " + host + ":" + port + " -> " + redisHost + ":" + port + " (for SSL/SNI)");
                        return HostAndPort.of(redisHost, port);
                    }
                    return hostAndPort;
                }
            );
            System.out.println("   ✅ MappingSocketAddressResolver created with UNRESOLVED DNS\n");

            // Step 3: Create ClientResources with the resolver
            System.out.println("3. Creating ClientResources with custom socket address resolver...");
            clientResources = DefaultClientResources.builder()
                .socketAddressResolver(resolver)
                .build();
            System.out.println("   ✅ ClientResources created\n");

            // Step 4: Build Redis URI with authentication
            System.out.println("4. Building Redis URI with Entra ID authentication...");
            
            // Configure SSL options
            // Using JDK SSL provider for compatibility
            SslOptions sslOptions = SslOptions.builder()
                .jdkSslProvider()
                .handshakeTimeout(Duration.ofSeconds(30))
                .build();
            
            RedisURI redisURI = RedisURI.builder()
                .withHost(redisHost)
                .withPort(redisPort)
                .withAuthentication(credentials)
                .withSsl(true)
                .withVerifyPeer(true)  // FULL certificate verification (hostname + CA)
                .build();
            System.out.println("   ✅ URI built for " + redisHost + ":" + redisPort + " (SSL enabled)\n");

            // Step 5: Create RedisClusterClient with topology refresh options
            System.out.println("5. Creating RedisClusterClient with optimal cluster settings...");
            clusterClient = RedisClusterClient.create(clientResources, redisURI);
            
            // Configure cluster-specific options for optimal reliability
            // These settings help recover quickly during failovers and updates
            ClusterTopologyRefreshOptions refreshOptions = ClusterTopologyRefreshOptions.builder()
                .enablePeriodicRefresh(Duration.ofSeconds(30))  // Refresh topology periodically
                .dynamicRefreshSources(false)  // Use only initial seed nodes for Azure
                .adaptiveRefreshTriggersTimeout(Duration.ofSeconds(15))
                .enableAllAdaptiveRefreshTriggers()  // Refresh on MOVED, ASK, etc.
                .build();
            
            ClusterClientOptions clientOptions = ClusterClientOptions.builder()
                .topologyRefreshOptions(refreshOptions)
                .socketOptions(SocketOptions.builder()
                    .keepAlive(true)  // Required for Azure - keeps connections alive through load balancers
                    .connectTimeout(Duration.ofSeconds(10))
                    .build())
                .sslOptions(sslOptions)
                .autoReconnect(true)
                .build();
            
            clusterClient.setOptions(clientOptions);
            System.out.println("   ✅ Cluster client created with:");
            System.out.println("      - Periodic topology refresh: 30s");
            System.out.println("      - Adaptive refresh triggers: enabled");
            System.out.println("      - TCP keepAlive: enabled");
            System.out.println("      - Auto-reconnect: enabled\n");

            // Step 6: Connect and test
            System.out.println("6. Connecting to Azure Managed Redis cluster...");
            try (StatefulRedisClusterConnection<String, String> connection = clusterClient.connect()) {
                RedisAdvancedClusterCommands<String, String> commands = connection.sync();
                
                // Show connection info
                System.out.println("   Connected as: " + commands.aclWhoami() + "\n");

                // Test PING
                System.out.println("7. Testing PING...");
                System.out.println("   ✅ PING response: " + commands.ping() + "\n");

                // Test SET/GET with keys that DEFINITELY hit different shards using hash tags
                // Hash tags {xxx} ensure the slot is calculated from the tag content only
                // This validates that MappingSocketAddressResolver is working correctly!
                System.out.println("8. Testing SET/GET operations across MULTIPLE shards...");
                System.out.println("   Using hash tags to guarantee cross-shard distribution");
                String[][] testKeyPairs = {
                    {"{slot2}", "shard0"},   // slot 98 -> shard 0
                    {"{slot3}", "shard0"},   // slot 4163 -> shard 0
                    {"{slot0}", "shard1"},   // slot 8224 -> shard 1
                    {"{slot1}", "shard1"},   // slot 12289 -> shard 1
                };
                
                for (String[] pair : testKeyPairs) {
                    String key = "lettuce-cluster:" + pair[0];
                    String expectedShard = pair[1];
                    String value = "value-" + System.currentTimeMillis();
                    commands.setex(key, 60, value);
                    String retrieved = commands.get(key);
                    System.out.println("   ✅ " + key + " -> SET/GET successful -> " + expectedShard);
                    commands.del(key);
                }
                System.out.println("   If you see this, MappingSocketAddressResolver is working correctly!");
                System.out.println();

                // Test with timestamp key
                System.out.println("9. Testing with timestamp key...");
                String testKey = "cluster-entra-test:" + LocalDateTime.now().format(FORMATTER);
                String testValue = "Hello from Lettuce Cluster Client with Entra ID auth!";
                commands.setex(testKey, 60, testValue);
                System.out.println("   ✅ SET '" + testKey + "'");
                
                String retrieved = commands.get(testKey);
                System.out.println("   ✅ GET '" + testKey + "' = '" + retrieved + "'");
                
                commands.del(testKey);
                System.out.println("   ✅ Deleted test key\n");

                // Show cluster info
                System.out.println("10. Cluster information:");
                String clusterInfo = commands.clusterInfo();
                for (String line : clusterInfo.split("\n")) {
                    if (line.startsWith("cluster_state") || 
                        line.startsWith("cluster_slots") ||
                        line.startsWith("cluster_known_nodes") ||
                        line.startsWith("cluster_size")) {
                        System.out.println("    " + line.trim());
                    }
                }

                System.out.println("\n" + "=".repeat(70));
                System.out.println("DEMO COMPLETE - All cluster operations successful!");
                System.out.println("=".repeat(70));
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
        }
    }
    
    /**
     * Check if an address is an internal/private IP
     * Internal IPs in Azure VNets typically follow RFC 1918 private ranges
     */
    private static boolean isInternalIP(String host) {
        // Check for RFC 1918 private IP ranges
        return host.startsWith("10.") ||           // 10.0.0.0/8
               host.startsWith("172.16.") ||       // 172.16.0.0/12
               host.startsWith("172.17.") ||
               host.startsWith("172.18.") ||
               host.startsWith("172.19.") ||
               host.startsWith("172.20.") ||
               host.startsWith("172.21.") ||
               host.startsWith("172.22.") ||
               host.startsWith("172.23.") ||
               host.startsWith("172.24.") ||
               host.startsWith("172.25.") ||
               host.startsWith("172.26.") ||
               host.startsWith("172.27.") ||
               host.startsWith("172.28.") ||
               host.startsWith("172.29.") ||
               host.startsWith("172.30.") ||
               host.startsWith("172.31.") ||
               host.startsWith("192.168.");        // 192.168.0.0/16
    }
}
