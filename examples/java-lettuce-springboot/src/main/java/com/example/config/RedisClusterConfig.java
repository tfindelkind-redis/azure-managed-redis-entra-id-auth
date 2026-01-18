package com.example.config;

import io.lettuce.core.ClientOptions;
import io.lettuce.core.RedisURI;
import io.lettuce.core.SocketOptions;
import io.lettuce.core.TimeoutOptions;
import io.lettuce.core.cluster.ClusterClientOptions;
import io.lettuce.core.cluster.ClusterTopologyRefreshOptions;
import io.lettuce.core.cluster.RedisClusterClient;
import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;
import io.lettuce.core.internal.HostAndPort;
import io.lettuce.core.resource.ClientResources;
import io.lettuce.core.resource.DefaultClientResources;
import io.lettuce.core.resource.DnsResolvers;
import io.lettuce.core.resource.MappingSocketAddressResolver;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import redis.clients.authentication.core.TokenBasedRedisCredentialsProvider;
import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.entraid.UserManagedIdentityType;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.time.Duration;
import java.util.function.Function;

/**
 * Redis Cluster Configuration for Azure Managed Redis with Entra ID Authentication.
 * 
 * CRITICAL: This configuration includes the MappingSocketAddressResolver which is
 * ESSENTIAL for Azure Managed Redis Cluster (OSS) to work correctly!
 * 
 * Why is MappingSocketAddressResolver needed?
 * -------------------------------------------
 * Azure Managed Redis cluster nodes advertise their internal IP addresses in CLUSTER SLOTS
 * responses. However, clients connecting from outside the cluster network cannot reach
 * these internal IPs directly. The MappingSocketAddressResolver intercepts the connection
 * attempts and maps the internal IPs back to the public hostname, ensuring all connections
 * go through the Azure load balancer/proxy.
 * 
 * Without this, you'll see errors like:
 * - Connection refused to 10.x.x.x (internal cluster IP)
 * - Cluster topology refresh failures
 * - Random connection drops when cluster redirects to different nodes
 */
@Configuration
public class RedisClusterConfig {

    private static final Logger log = LoggerFactory.getLogger(RedisClusterConfig.class);

    @Value("${azure.redis.hostname}")
    private String redisHostname;

    @Value("${azure.redis.port:10000}")
    private int redisPort;

    @Value("${azure.identity.client-id}")
    private String managedIdentityClientId;

    @Value("${azure.redis.ssl:true}")
    private boolean useSsl;

    // Cached IP address for hostname mapping (following Azure best practices)
    private String cacheIP;

    /**
     * Creates the Entra ID credentials provider using User-Assigned Managed Identity.
     */
    @Bean
    public TokenBasedRedisCredentialsProvider redisCredentialsProvider() {
        log.info("Creating Entra ID credentials provider for managed identity: {}...", 
                 managedIdentityClientId.substring(0, 8));
        
        EntraIDTokenAuthConfigBuilder builder = EntraIDTokenAuthConfigBuilder.builder()
            .userAssignedManagedIdentity(
                UserManagedIdentityType.CLIENT_ID,
                managedIdentityClientId
            );
        
        TokenBasedRedisCredentialsProvider provider = 
            TokenBasedRedisCredentialsProvider.create(builder.build());
        
        // Verify credentials can be resolved (and check token timing!)
        provider.resolveCredentials()
            .doOnNext(creds -> {
                log.info("✅ Credentials resolved successfully");
                log.info("   Username (OID): {}...", creds.getUsername().substring(0, 8));
                // Note: Token expiration is validated in TokenValidationService
            })
            .doOnError(e -> log.error("❌ Failed to resolve credentials: {}", e.getMessage()))
            .block();
        
        return provider;
    }

    /**
     * Creates ClientResources with MappingSocketAddressResolver.
     * 
     * THIS IS THE CRITICAL PIECE FOR AZURE MANAGED REDIS CLUSTER!
     * 
     * Why is this needed? (From Azure Best Practices documentation)
     * -------------------------------------------------------------
     * SSL certificate validation requires matching the address with the SAN (Subject Alternative Names)
     * in the SSL certificate. Redis protocol requires that node addresses be IP addresses.
     * However, the SANs in Azure Redis SSL certificates contain only the Hostname since
     * public IP addresses can change.
     * 
     * The MappingSocketAddressResolver maps internal cluster IPs back to the public hostname,
     * ensuring SSL certificate validation succeeds.
     * 
     * @see <a href="https://github.com/Azure/AzureCacheForRedis/blob/main/Lettuce%20Best%20Practices.md">
     *      Azure Cache for Redis - Lettuce Best Practices</a>
     */
    @Bean(destroyMethod = "shutdown")
    public ClientResources clientResources() {
        log.info("Creating ClientResources with MappingSocketAddressResolver (Azure Best Practices)");
        
        // Following the exact pattern from Azure's Lettuce Best Practices documentation:
        // https://github.com/Azure/AzureCacheForRedis/blob/main/Lettuce%20Best%20Practices.md
        
        Function<HostAndPort, HostAndPort> mappingFunction = hostAndPort -> {
            // Resolve the cache hostname to IP on first call
            if (cacheIP == null) {
                try {
                    InetAddress[] addresses = DnsResolvers.JVM_DEFAULT.resolve(redisHostname);
                    cacheIP = addresses[0].getHostAddress();
                    log.info("   Resolved {} -> {}", redisHostname, cacheIP);
                } catch (UnknownHostException e) {
                    log.error("Failed to resolve hostname {}: {}", redisHostname, e.getMessage());
                    throw new RuntimeException("Cannot resolve Redis hostname", e);
                }
            }
            
            String originalHost = hostAndPort.getHostText();
            HostAndPort finalAddress = hostAndPort;
            
            // If the host matches the cache IP, map it back to the hostname
            // This is critical for SSL certificate validation
            if (originalHost.equals(cacheIP)) {
                finalAddress = HostAndPort.of(redisHostname, hostAndPort.getPort());
                log.debug("MappingResolver: {} -> {}", originalHost, redisHostname);
            }
            // Also handle any private IP addresses that might be returned by cluster
            else if (isPrivateIP(originalHost)) {
                finalAddress = HostAndPort.of(redisHostname, hostAndPort.getPort());
                log.debug("MappingResolver: Mapping private IP {} -> {}", originalHost, redisHostname);
            }
            
            return finalAddress;
        };

        MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(
            DnsResolvers.JVM_DEFAULT,  // Use JVM default DNS resolver as per Azure best practices
            mappingFunction
        );

        return DefaultClientResources.builder()
            .socketAddressResolver(resolver)
            .build();
    }
    
    /**
     * Checks if an IP address is a private (RFC 1918) address.
     */
    private boolean isPrivateIP(String ip) {
        return ip.startsWith("10.") || 
               ip.startsWith("172.16.") || ip.startsWith("172.17.") || ip.startsWith("172.18.") ||
               ip.startsWith("172.19.") || ip.startsWith("172.20.") || ip.startsWith("172.21.") ||
               ip.startsWith("172.22.") || ip.startsWith("172.23.") || ip.startsWith("172.24.") ||
               ip.startsWith("172.25.") || ip.startsWith("172.26.") || ip.startsWith("172.27.") ||
               ip.startsWith("172.28.") || ip.startsWith("172.29.") || ip.startsWith("172.30.") ||
               ip.startsWith("172.31.") ||
               ip.startsWith("192.168.");
    }

    /**
     * Creates cluster-specific client options following Azure Best Practices.
     * 
     * Key settings for optimal reliability during failovers and updates:
     * - enablePeriodicRefresh(5s): Detect topology changes quickly
     * - dynamicRefreshSources(false): Important for Azure - don't use discovered nodes as refresh sources
     * - adaptiveRefreshTriggersTimeout(5s): Fast timeout for adaptive refresh triggers
     * - enableAllAdaptiveRefreshTriggers(): React to MOVED, ASK, persistent reconnects, etc.
     * 
     * @see <a href="https://github.com/Azure/AzureCacheForRedis/blob/main/Lettuce%20Best%20Practices.md">
     *      Azure Cache for Redis - Lettuce Best Practices</a>
     */
    @Bean
    public ClusterClientOptions clusterClientOptions() {
        log.info("Creating ClusterClientOptions (Azure Best Practices + Entra ID auto-reauth)");
        
        // Cluster topology refresh options - CRITICAL for reliability during updates/failovers
        // These settings are directly from Azure's Lettuce Best Practices documentation
        ClusterTopologyRefreshOptions topologyRefreshOptions = ClusterTopologyRefreshOptions.builder()
            // Periodic refresh every 5 seconds to detect configuration changes quickly
            .enablePeriodicRefresh(Duration.ofSeconds(5))
            // IMPORTANT: Set to false for Azure - don't use discovered cluster nodes as refresh sources
            .dynamicRefreshSources(false)
            // Fast timeout for adaptive triggers
            .adaptiveRefreshTriggersTimeout(Duration.ofSeconds(5))
            // Enable all adaptive triggers: MOVED_REDIRECT, ASK_REDIRECT, PERSISTENT_RECONNECTS, etc.
            .enableAllAdaptiveRefreshTriggers()
            .build();
        
        log.info("   Topology refresh: periodic=5s, dynamicSources=false, adaptiveTimeout=5s");

        return ClusterClientOptions.builder()
            // CRITICAL for Entra ID: Enable automatic re-authentication when token refreshes
            .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
            // Apply the topology refresh options
            .topologyRefreshOptions(topologyRefreshOptions)
            // Socket options - keepAlive is important for Azure
            .socketOptions(SocketOptions.builder()
                .connectTimeout(Duration.ofSeconds(10))
                .keepAlive(true)  // Required for Azure - keeps connections alive
                .build())
            .timeoutOptions(TimeoutOptions.enabled(Duration.ofSeconds(10)))
            .autoReconnect(true)
            .build();
    }

    /**
     * Creates the Redis Cluster Client.
     */
    @Bean(destroyMethod = "shutdown")
    public RedisClusterClient redisClusterClient(
            ClientResources clientResources,
            ClusterClientOptions clusterClientOptions,
            TokenBasedRedisCredentialsProvider credentialsProvider) {
        
        log.info("Creating RedisClusterClient for {}:{}", redisHostname, redisPort);
        
        RedisURI redisUri = RedisURI.builder()
            .withHost(redisHostname)
            .withPort(redisPort)
            .withSsl(useSsl)
            .withAuthentication(credentialsProvider)
            .build();

        RedisClusterClient client = RedisClusterClient.create(clientResources, redisUri);
        client.setOptions(clusterClientOptions);
        
        return client;
    }

    /**
     * Creates a stateful cluster connection.
     */
    @Bean(destroyMethod = "close")
    public StatefulRedisClusterConnection<String, String> redisClusterConnection(
            RedisClusterClient redisClusterClient) {
        
        log.info("Establishing cluster connection...");
        StatefulRedisClusterConnection<String, String> connection = redisClusterClient.connect();
        
        // Test the connection
        String pong = connection.sync().ping();
        log.info("✅ Connected to cluster! PING response: {}", pong);
        
        // Log cluster info
        connection.sync().clusterInfo().lines()
            .filter(line -> line.startsWith("cluster_state") || line.startsWith("cluster_known_nodes"))
            .forEach(line -> log.info("   {}", line));
        
        return connection;
    }
}
