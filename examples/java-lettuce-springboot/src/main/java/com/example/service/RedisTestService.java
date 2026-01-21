package com.example.service;

import io.lettuce.core.api.StatefulRedisConnection;
import io.lettuce.core.api.sync.RedisCommands;
import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;
import io.lettuce.core.cluster.api.sync.RedisAdvancedClusterCommands;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

/**
 * Service for testing Redis operations.
 * Works with both Enterprise Cluster (standard connection) and OSS Cluster policies.
 */
@Service
public class RedisTestService {

    private static final Logger log = LoggerFactory.getLogger(RedisTestService.class);
    private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss");

    @Value("${azure.redis.cluster-policy:EnterpriseCluster}")
    private String clusterPolicy;

    @Value("${azure.auth.type:user-assigned-managed-identity}")
    private String authType;

    // Autowired - one will be null depending on cluster policy
    @Autowired(required = false)
    private StatefulRedisConnection<String, String> standardConnection;

    @Autowired(required = false)
    private StatefulRedisClusterConnection<String, String> clusterConnection;

    @PostConstruct
    public void runTests() {
        boolean isOSSCluster = "OSSCluster".equalsIgnoreCase(clusterPolicy);
        String authDescription = getAuthDescription();

        log.info("\n" + "=".repeat(70));
        log.info("AZURE MANAGED REDIS - SPRING BOOT LETTUCE DEMO");
        log.info("Authentication: {}", authDescription);
        log.info("Cluster Policy: {} ({})", clusterPolicy, isOSSCluster ? "cluster-aware" : "standard");
        log.info("=".repeat(70) + "\n");

        try {
            if (isOSSCluster) {
                runClusterTests();
            } else {
                runStandardTests();
            }
        } catch (Exception e) {
            log.error("❌ Tests failed: {}", e.getMessage(), e);
            throw new RuntimeException("Redis tests failed", e);
        }
    }

    private String getAuthDescription() {
        switch (authType) {
            case "user-assigned-managed-identity":
                return "User-Assigned Managed Identity";
            case "system-assigned-managed-identity":
                return "System-Assigned Managed Identity";
            case "service-principal":
                return "Service Principal";
            default:
                return authType;
        }
    }

    private void runStandardTests() {
        if (standardConnection == null) {
            log.error("Standard connection not available!");
            return;
        }

        RedisCommands<String, String> commands = standardConnection.sync();

        // Test 1: PING
        log.info("1. Testing PING...");
        String pong = commands.ping();
        log.info("   ✅ PING response: {}\n", pong);

        // Test 2: ACL WHOAMI
        log.info("2. Verifying Entra ID authentication...");
        String user = commands.aclWhoami();
        log.info("   ✅ Connected as: {}...\n", user.substring(0, Math.min(8, user.length())));

        // Test 3: SET operation
        log.info("3. Testing SET operation...");
        String testKey = "springboot-test:" + LocalDateTime.now().format(FORMATTER);
        String testValue = "Hello from Spring Boot with Entra ID!";
        commands.setex(testKey, 300, testValue);
        log.info("   ✅ SET '{}'\n", testKey);

        // Test 4: GET operation
        log.info("4. Testing GET operation...");
        String retrieved = commands.get(testKey);
        log.info("   ✅ GET '{}' = '{}'\n", testKey, retrieved);

        // Test 5: INCR operation
        log.info("5. Testing INCR operation...");
        String counterKey = "springboot-counter";
        long newValue = commands.incr(counterKey);
        log.info("   ✅ INCR '{}' = {}\n", counterKey, newValue);

        // Test 6: DBSIZE
        log.info("6. Getting database size...");
        Long dbSize = commands.dbsize();
        log.info("   Database contains {} keys\n", dbSize);

        // Test 7: Cleanup
        log.info("7. Cleaning up test key...");
        commands.del(testKey);
        log.info("   ✅ Deleted test key\n");

        printSuccess();
    }

    private void runClusterTests() {
        if (clusterConnection == null) {
            log.error("Cluster connection not available!");
            return;
        }

        RedisAdvancedClusterCommands<String, String> commands = clusterConnection.sync();

        // Test 1: PING
        log.info("1. Testing PING...");
        String pong = commands.ping();
        log.info("   ✅ PING response: {}\n", pong);

        // Test 2: ACL WHOAMI
        log.info("2. Verifying Entra ID authentication...");
        String user = commands.aclWhoami();
        log.info("   ✅ Connected as: {}...\n", user.substring(0, Math.min(8, user.length())));

        // Test 3: CLUSTER INFO
        log.info("3. Getting cluster info...");
        String clusterInfo = commands.clusterInfo();
        clusterInfo.lines()
            .filter(line -> line.startsWith("cluster_state") || 
                           line.startsWith("cluster_known_nodes") ||
                           line.startsWith("cluster_size"))
            .forEach(line -> log.info("   {}", line));
        log.info("");

        // Test 4: SET operation
        log.info("4. Testing SET operation...");
        String testKey = "springboot-cluster-test:" + LocalDateTime.now().format(FORMATTER);
        String testValue = "Hello from Spring Boot Cluster with Entra ID!";
        commands.setex(testKey, 300, testValue);
        log.info("   ✅ SET '{}'\n", testKey);

        // Test 5: GET operation
        log.info("5. Testing GET operation...");
        String retrieved = commands.get(testKey);
        log.info("   ✅ GET '{}' = '{}'\n", testKey, retrieved);

        // Test 6: Test routing to different slots
        log.info("6. Testing cluster slot routing...");
        for (int i = 0; i < 3; i++) {
            String key = "slot-test-{" + i + "}:" + System.currentTimeMillis();
            commands.setex(key, 60, "test-" + i);
            long slot = commands.clusterKeyslot(key);
            log.info("   Key '{}' -> slot {}", key, slot);
        }
        log.info("");

        // Test 7: Cleanup
        log.info("7. Cleaning up test key...");
        commands.del(testKey);
        log.info("   ✅ Deleted test key\n");

        // Test 8: DBSIZE
        log.info("8. Getting database size...");
        Long dbSize = commands.dbsize();
        log.info("   Database contains {} keys\n", dbSize);

        printSuccess();
    }

    private void printSuccess() {
        log.info("=".repeat(70));
        log.info("✅ DEMO COMPLETE - All operations successful!");
        log.info("=".repeat(70) + "\n");
    }
}
