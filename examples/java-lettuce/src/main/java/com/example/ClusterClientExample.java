package com.example;

import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.entraid.ManagedIdentityInfo;
import io.lettuce.authx.TokenBasedRedisCredentialsProvider;
import io.lettuce.core.*;
import io.lettuce.core.cluster.*;
import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;
import io.lettuce.core.cluster.api.sync.RedisClusterCommands;
import io.lettuce.core.internal.HostAndPort;
import io.lettuce.core.resource.*;

import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Set;

/**
 * Azure Managed Redis - Cluster Client Example (Lettuce)
 * 
 * This example tests whether RedisClusterClient and MappingSocketAddressResolver
 * are needed for OSS Cluster mode in Azure Managed Redis.
 * 
 * Spoiler: They are NOT needed - the proxy endpoint handles cluster routing.
 */
public class ClusterClientExample {
    
    private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static final String REDIS_SCOPE = "https://redis.azure.com";

    public static void main(String[] args) {
        String clientId = System.getenv("AZURE_CLIENT_ID");
        String redisHost = System.getenv("REDIS_HOSTNAME");
        int redisPort = Integer.parseInt(System.getenv().getOrDefault("REDIS_PORT", "10000"));

        if (clientId == null || redisHost == null) {
            System.err.println("Error: AZURE_CLIENT_ID and REDIS_HOSTNAME required");
            System.exit(1);
        }

        System.out.println("\n" + "=".repeat(60));
        System.out.println("TESTING RedisClusterClient with MappingSocketAddressResolver");
        System.out.println("=".repeat(60) + "\n");

        TokenBasedRedisCredentialsProvider credentials = null;
        RedisClusterClient clusterClient = null;

        try {
            // Create credentials
            System.out.println("1. Creating credentials provider...");
            try (EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()) {
                builder.userAssignedManagedIdentity(
                    ManagedIdentityInfo.UserManagedIdentityType.CLIENT_ID,
                    clientId
                );
                builder.scopes(Set.of(REDIS_SCOPE));
                credentials = TokenBasedRedisCredentialsProvider.create(builder.build());
            }
            System.out.println("   ✅ Credentials created\n");

            // Create MappingSocketAddressResolver as mentioned in Azure docs
            // This maps internal cluster node addresses to the public endpoint
            System.out.println("2. Creating MappingSocketAddressResolver...");
            MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(
                DnsResolvers.UNRESOLVED,
                hostAndPort -> {
                    System.out.println("   🔄 Mapping: " + hostAndPort + " -> " + redisHost + ":" + redisPort);
                    return HostAndPort.of(redisHost, redisPort);
                }
            );
            System.out.println("   ✅ Resolver created\n");

            // Create ClientResources with the resolver
            System.out.println("3. Creating ClientResources...");
            ClientResources clientResources = ClientResources.builder()
                .socketAddressResolver(resolver)
                .build();
            System.out.println("   ✅ ClientResources created\n");

            // Build cluster URI
            System.out.println("4. Building Cluster URI...");
            RedisURI redisURI = RedisURI.builder()
                .withHost(redisHost)
                .withPort(redisPort)
                .withAuthentication(credentials)
                .withSsl(true)
                .build();
            System.out.println("   ✅ URI built\n");

            // Create cluster client
            System.out.println("5. Creating RedisClusterClient...");
            clusterClient = RedisClusterClient.create(clientResources, redisURI);
            
            // Configure cluster options
            ClusterClientOptions options = ClusterClientOptions.builder()
                .topologyRefreshOptions(ClusterTopologyRefreshOptions.builder()
                    .enablePeriodicRefresh(false)  // Disable - proxy handles this
                    .enableAllAdaptiveRefreshTriggers()  // But enable on demand
                    .build())
                .socketOptions(io.lettuce.core.SocketOptions.builder()
                    .keepAlive(true)
                    .build())
                .build();
            clusterClient.setOptions(options);
            System.out.println("   ✅ Cluster client created\n");

            // Connect
            System.out.println("6. Connecting to cluster...");
            try (StatefulRedisClusterConnection<String, String> connection = clusterClient.connect()) {
                RedisClusterCommands<String, String> commands = connection.sync();
                
                System.out.println("   Connected as: " + commands.aclWhoami() + "\n");

                // Test PING
                System.out.println("7. Testing PING...");
                System.out.println("   ✅ PING: " + commands.ping() + "\n");

                // Test SET/GET across multiple hash slots
                System.out.println("8. Testing SET/GET across hash slots...");
                String[] testKeys = {"foo", "bar", "baz", "qux"};  // Different hash slots
                for (String key : testKeys) {
                    String fullKey = "cluster-test:" + key;
                    commands.setex(fullKey, 60, "value-" + key);
                    String value = commands.get(fullKey);
                    System.out.println("   ✅ " + fullKey + " = " + value);
                    commands.del(fullKey);
                }
                
                System.out.println("\n" + "=".repeat(60));
                System.out.println("CLUSTER CLIENT TEST COMPLETE!");
                System.out.println("=".repeat(60));
            }
        } catch (Exception e) {
            System.err.println("\n❌ Error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        } finally {
            if (clusterClient != null) clusterClient.shutdown();
            if (credentials != null) credentials.close();
        }
    }
}
