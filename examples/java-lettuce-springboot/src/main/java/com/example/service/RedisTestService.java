package com.example.service;

import io.lettuce.core.cluster.api.StatefulRedisClusterConnection;
import io.lettuce.core.cluster.api.sync.RedisClusterCommands;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

/**
 * Service for testing Redis cluster operations.
 * Runs basic tests to verify the connection works correctly.
 */
@Service
public class RedisTestService {

    private static final Logger log = LoggerFactory.getLogger(RedisTestService.class);
    private static final DateTimeFormatter FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss");

    private final StatefulRedisClusterConnection<String, String> connection;

    public RedisTestService(StatefulRedisClusterConnection<String, String> connection) {
        this.connection = connection;
    }

    @PostConstruct
    public void runTests() {
        log.info("\n" + "=".repeat(60));
        log.info("RUNNING REDIS CLUSTER CONNECTION TESTS");
        log.info("=".repeat(60) + "\n");

        RedisClusterCommands<String, String> commands = connection.sync();

        try {
            // Test 1: PING
            log.info("Test 1: PING");
            String pong = commands.ping();
            log.info("   ✅ PING response: {}\n", pong);

            // Test 2: ACL WHOAMI
            log.info("Test 2: ACL WHOAMI (verify Entra ID auth)");
            String user = commands.aclWhoami();
            log.info("   ✅ Connected as: {}\n", user);

            // Test 3: CLUSTER INFO
            log.info("Test 3: CLUSTER INFO");
            String clusterInfo = commands.clusterInfo();
            clusterInfo.lines()
                .filter(line -> line.startsWith("cluster_state") || 
                               line.startsWith("cluster_known_nodes") ||
                               line.startsWith("cluster_size"))
                .forEach(line -> log.info("   {}", line));
            log.info("");

            // Test 4: SET operation
            log.info("Test 4: SET operation");
            String testKey = "springboot-cluster-test:" + LocalDateTime.now().format(FORMATTER);
            String testValue = "Hello from Spring Boot Lettuce Cluster with Entra ID!";
            commands.setex(testKey, 300, testValue);
            log.info("   ✅ SET '{}'\n", testKey);

            // Test 5: GET operation
            log.info("Test 5: GET operation");
            String retrieved = commands.get(testKey);
            log.info("   ✅ GET '{}' = '{}'\n", testKey, retrieved);

            // Test 6: Test routing to different slots
            log.info("Test 6: Testing cluster slot routing");
            for (int i = 0; i < 3; i++) {
                String key = "slot-test-{" + i + "}:" + System.currentTimeMillis();
                commands.setex(key, 60, "test-" + i);
                long slot = commands.clusterKeyslot(key);
                log.info("   Key '{}' -> slot {}", key, slot);
            }
            log.info("");

            // Test 7: Cleanup
            log.info("Test 7: Cleanup");
            commands.del(testKey);
            log.info("   ✅ Deleted test key\n");

            // Test 8: DBSIZE (across cluster)
            log.info("Test 8: DBSIZE");
            Long dbSize = commands.dbsize();
            log.info("   Database contains {} keys\n", dbSize);

            log.info("=".repeat(60));
            log.info("✅ ALL TESTS PASSED - Cluster connection working correctly!");
            log.info("=".repeat(60) + "\n");

        } catch (Exception e) {
            log.error("❌ Test failed: {}", e.getMessage(), e);
            throw new RuntimeException("Redis cluster tests failed", e);
        }
    }
}
