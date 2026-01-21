package com.example.config;

import io.lettuce.authx.TokenBasedRedisCredentialsProvider;
import io.lettuce.core.*;
import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.cluster.*;
import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;
import io.lettuce.core.internal.HostAndPort;
import io.lettuce.core.resource.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import redis.clients.authentication.entraid.EntraIDTokenAuthConfigBuilder;
import redis.clients.authentication.entraid.ManagedIdentityInfo;
import redis.clients.authentication.core.TokenAuthConfig;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.time.Duration;
import java.util.Set;

/**
 * Unified Redis Configuration for Azure Managed Redis with Entra ID Authentication.
 * 
 * CLUSTER POLICY SUPPORT:
 * - EnterpriseCluster: Uses standard RedisClient (server handles slot routing)
 * - OSSCluster: Uses RedisClusterClient with MappingSocketAddressResolver
 * 
 * AUTHENTICATION METHODS (via Spring profiles):
 * - user-mi: User-Assigned Managed Identity
 * - system-mi: System-Assigned Managed Identity
 * - service-principal: Service Principal (Client Credentials)
 * 
 * The MappingSocketAddressResolver is CRITICAL for OSS Cluster mode because:
 * - Cluster nodes advertise internal IP addresses in CLUSTER SLOTS responses
 * - SSL certificates only contain the public hostname
 * - The resolver maps internal IPs back to the public hostname for SSL/SNI
 */
@Configuration
public class RedisConfig {

    private static final Logger log = LoggerFactory.getLogger(RedisConfig.class);
    private static final String REDIS_SCOPE = "https://redis.azure.com";

    @Value("${azure.redis.hostname}")
    private String redisHostname;

    @Value("${azure.redis.port:10000}")
    private int redisPort;

    @Value("${azure.redis.cluster-policy:EnterpriseCluster}")
    private String clusterPolicy;

    @Value("${azure.redis.ssl:true}")
    private boolean useSsl;

    @Value("${azure.auth.type:user-assigned-managed-identity}")
    private String authType;

    @Value("${azure.identity.client-id:}")
    private String managedIdentityClientId;

    @Value("${azure.service-principal.client-id:}")
    private String servicePrincipalClientId;

    @Value("${azure.service-principal.client-secret:}")
    private String servicePrincipalClientSecret;

    @Value("${azure.service-principal.tenant-id:}")
    private String servicePrincipalTenantId;

    // Cached IP for hostname mapping
    private String cachedIP;

    /**
     * Creates the Entra ID credentials provider based on active Spring profile.
     */
    @Bean
    public TokenBasedRedisCredentialsProvider redisCredentialsProvider() {
        log.info("Creating Entra ID credentials provider...");
        log.info("   Auth type: {}", authType);
        log.info("   Cluster policy: {}", clusterPolicy);

        TokenAuthConfig authConfig;

        switch (authType) {
            case "user-assigned-managed-identity":
                log.info("   Using User-Assigned Managed Identity: {}...", 
                        managedIdentityClientId.substring(0, Math.min(8, managedIdentityClientId.length())));
                authConfig = EntraIDTokenAuthConfigBuilder.builder()
                    .userAssignedManagedIdentity(
                        ManagedIdentityInfo.UserManagedIdentityType.CLIENT_ID,
                        managedIdentityClientId)
                    .scopes(Set.of(REDIS_SCOPE))
                    .build();
                break;

            case "system-assigned-managed-identity":
                log.info("   Using System-Assigned Managed Identity");
                authConfig = EntraIDTokenAuthConfigBuilder.builder()
                    .systemAssignedManagedIdentity()
                    .scopes(Set.of(REDIS_SCOPE))
                    .build();
                break;

            case "service-principal":
                log.info("   Using Service Principal: {}...", 
                        servicePrincipalClientId.substring(0, Math.min(8, servicePrincipalClientId.length())));
                String authority = "https://login.microsoftonline.com/" + servicePrincipalTenantId;
                authConfig = EntraIDTokenAuthConfigBuilder.builder()
                    .clientId(servicePrincipalClientId)
                    .secret(servicePrincipalClientSecret)
                    .authority(authority)
                    .scopes(Set.of(REDIS_SCOPE + "/.default"))
                    .build();
                break;

            default:
                throw new IllegalArgumentException("Unknown auth type: " + authType);
        }

        TokenBasedRedisCredentialsProvider provider = TokenBasedRedisCredentialsProvider.create(authConfig);
        
        // Verify credentials
        provider.resolveCredentials()
            .doOnNext(creds -> log.info("   ✅ Credentials resolved, username (OID): {}...", 
                    creds.getUsername().substring(0, Math.min(8, creds.getUsername().length()))))
            .doOnError(e -> log.error("   ❌ Failed to resolve credentials: {}", e.getMessage()))
            .block();

        return provider;
    }

    /**
     * Creates ClientResources with MappingSocketAddressResolver for OSS Cluster.
     */
    @Bean(destroyMethod = "shutdown")
    public ClientResources clientResources() {
        boolean isOSSCluster = "OSSCluster".equalsIgnoreCase(clusterPolicy);
        
        if (!isOSSCluster) {
            log.info("Creating ClientResources (Enterprise policy - standard resolver)");
            return DefaultClientResources.create();
        }

        log.info("Creating ClientResources with MappingSocketAddressResolver (OSS Cluster)");
        
        MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(
            DnsResolvers.UNRESOLVED,
            hostAndPort -> {
                String originalHost = hostAndPort.getHostText();
                // Map any internal IP (or the resolved IP) back to the public hostname
                if (isPrivateIP(originalHost) || originalHost.equals(redisHostname)) {
                    return HostAndPort.of(redisHostname, hostAndPort.getPort());
                }
                return hostAndPort;
            }
        );

        return DefaultClientResources.builder()
            .socketAddressResolver(resolver)
            .build();
    }

    private boolean isPrivateIP(String ip) {
        return ip.startsWith("10.") || 
               ip.startsWith("172.16.") || ip.startsWith("172.17.") || ip.startsWith("172.18.") ||
               ip.startsWith("172.19.") || ip.startsWith("172.20.") || ip.startsWith("172.21.") ||
               ip.startsWith("172.22.") || ip.startsWith("172.23.") || ip.startsWith("172.24.") ||
               ip.startsWith("172.25.") || ip.startsWith("172.26.") || ip.startsWith("172.27.") ||
               ip.startsWith("172.28.") || ip.startsWith("172.29.") || ip.startsWith("172.30.") ||
               ip.startsWith("172.31.") || ip.startsWith("192.168.");
    }

    /**
     * Creates client options with auto re-authentication.
     */
    @Bean
    public ClientOptions clientOptions() {
        return ClientOptions.builder()
            .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
            .socketOptions(SocketOptions.builder()
                .connectTimeout(Duration.ofSeconds(10))
                .keepAlive(true)
                .build())
            .build();
    }

    /**
     * Creates cluster client options (for OSS Cluster policy).
     */
    @Bean
    public ClusterClientOptions clusterClientOptions() {
        ClusterTopologyRefreshOptions topologyRefresh = ClusterTopologyRefreshOptions.builder()
            .enablePeriodicRefresh(Duration.ofSeconds(5))
            .dynamicRefreshSources(false)  // Important for Azure
            .adaptiveRefreshTriggersTimeout(Duration.ofSeconds(5))
            .enableAllAdaptiveRefreshTriggers()
            .build();

        return ClusterClientOptions.builder()
            .reauthenticateBehavior(ClientOptions.ReauthenticateBehavior.ON_NEW_CREDENTIALS)
            .topologyRefreshOptions(topologyRefresh)
            .socketOptions(SocketOptions.builder()
                .connectTimeout(Duration.ofSeconds(10))
                .keepAlive(true)
                .build())
            .autoReconnect(true)
            .build();
    }

    /**
     * Creates Redis URI with authentication.
     */
    @Bean
    public RedisURI redisURI(TokenBasedRedisCredentialsProvider credentialsProvider) {
        return RedisURI.builder()
            .withHost(redisHostname)
            .withPort(redisPort)
            .withSsl(useSsl)
            .withAuthentication(credentialsProvider)
            .build();
    }

    /**
     * Creates standard RedisClient (for Enterprise Cluster policy).
     */
    @Bean(destroyMethod = "shutdown")
    public RedisClient redisClient(ClientResources clientResources, ClientOptions clientOptions, RedisURI redisURI) {
        boolean isOSSCluster = "OSSCluster".equalsIgnoreCase(clusterPolicy);
        if (isOSSCluster) {
            log.info("Skipping standard RedisClient (using cluster client for OSS policy)");
            return null;
        }

        log.info("Creating RedisClient for Enterprise Cluster policy");
        RedisClient client = RedisClient.create(clientResources, redisURI);
        client.setOptions(clientOptions);
        return client;
    }

    /**
     * Creates RedisClusterClient (for OSS Cluster policy).
     */
    @Bean(destroyMethod = "shutdown")
    public RedisClusterClient redisClusterClient(
            ClientResources clientResources, 
            ClusterClientOptions clusterClientOptions, 
            RedisURI redisURI) {
        
        boolean isOSSCluster = "OSSCluster".equalsIgnoreCase(clusterPolicy);
        if (!isOSSCluster) {
            log.info("Skipping RedisClusterClient (using standard client for Enterprise policy)");
            return null;
        }

        log.info("Creating RedisClusterClient for OSS Cluster policy");
        RedisClusterClient client = RedisClusterClient.create(clientResources, redisURI);
        client.setOptions(clusterClientOptions);
        return client;
    }

    /**
     * Creates standard connection (for Enterprise Cluster policy).
     */
    @Bean(destroyMethod = "close")
    public StatefulRedisConnection<String, String> redisConnection(RedisClient redisClient) {
        if (redisClient == null) {
            return null;
        }

        log.info("Establishing standard Redis connection...");
        StatefulRedisConnection<String, String> connection = redisClient.connect();
        
        String pong = connection.sync().ping();
        log.info("✅ Connected! PING response: {}", pong);
        log.info("   User: {}", connection.sync().aclWhoami());
        
        return connection;
    }

    /**
     * Creates cluster connection (for OSS Cluster policy).
     */
    @Bean(destroyMethod = "close")
    public StatefulRedisClusterConnection<String, String> redisClusterConnection(RedisClusterClient redisClusterClient) {
        if (redisClusterClient == null) {
            return null;
        }

        log.info("Establishing cluster Redis connection...");
        StatefulRedisClusterConnection<String, String> connection = redisClusterClient.connect();
        
        String pong = connection.sync().ping();
        log.info("✅ Connected to cluster! PING response: {}", pong);
        
        connection.sync().clusterInfo().lines()
            .filter(line -> line.startsWith("cluster_state") || line.startsWith("cluster_known_nodes"))
            .forEach(line -> log.info("   {}", line));
        
        return connection;
    }
}
