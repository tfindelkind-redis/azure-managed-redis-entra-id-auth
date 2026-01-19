/*
Azure Managed Redis - OSS Cluster with Managed Identity Authentication (Go)

This example demonstrates how to connect to Azure Managed Redis using:
- OSS Cluster policy (cluster-aware client required)
- User-Assigned Managed Identity with Entra ID authentication
- Custom Dialer for SSL SNI hostname verification

WHY CUSTOM DIALER IS NEEDED:
============================
Azure Managed Redis with OSS Cluster policy exposes:
1. A PUBLIC endpoint (redis-xxx.azure.net:10000) - initial connection point
2. INTERNAL cluster nodes (e.g., 10.0.2.4:8500) - returned by CLUSTER SLOTS

The problem:
- CLUSTER SLOTS returns internal IPs that are not reachable from outside
- SSL certificates only contain the public hostname in their SAN
- Connecting to internal IPs would fail SSL hostname verification

The solution (custom Dialer with address remapping):
- Intercepts connection attempts to internal IPs
- Remaps to public hostname while preserving the port
- Azure proxy routes to correct internal node based on port

Requirements:
- Go 1.21+
- go-redis v9.9.0+
- go-redis-entraid v1.0.0+

Environment Variables:
- AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
- REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
- REDIS_PORT: Port (default: 10000)

This code should be run from an Azure resource that has the
managed identity assigned.
*/

package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"time"

	entraid "github.com/redis/go-redis-entraid"
	"github.com/redis/go-redis/v9"
)

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// isInternalIP checks if the given host is an internal/private IP address
func isInternalIP(host string) bool {
	return strings.HasPrefix(host, "10.") ||
		strings.HasPrefix(host, "172.16.") || strings.HasPrefix(host, "172.17.") ||
		strings.HasPrefix(host, "172.18.") || strings.HasPrefix(host, "172.19.") ||
		strings.HasPrefix(host, "172.20.") || strings.HasPrefix(host, "172.21.") ||
		strings.HasPrefix(host, "172.22.") || strings.HasPrefix(host, "172.23.") ||
		strings.HasPrefix(host, "172.24.") || strings.HasPrefix(host, "172.25.") ||
		strings.HasPrefix(host, "172.26.") || strings.HasPrefix(host, "172.27.") ||
		strings.HasPrefix(host, "172.28.") || strings.HasPrefix(host, "172.29.") ||
		strings.HasPrefix(host, "172.30.") || strings.HasPrefix(host, "172.31.") ||
		strings.HasPrefix(host, "192.168.")
}

// createClusterDialer creates a custom dialer that remaps internal IPs to the public hostname
// This is REQUIRED for Azure Managed Redis OSS Cluster policy because:
// 1. CLUSTER SLOTS returns internal IPs (e.g., 10.0.2.4:8500)
// 2. These IPs are not reachable from outside Azure's internal network
// 3. SSL certificate validation requires the public hostname for SNI
// 4. Azure's proxy uses the port to route to the correct internal node
func createClusterDialer(publicHostname string) func(ctx context.Context, network, addr string) (net.Conn, error) {
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		// Parse the address to get host and port
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, fmt.Errorf("invalid address %s: %w", addr, err)
		}

		// Remap internal IPs to public hostname
		targetHost := host
		if isInternalIP(host) {
			fmt.Printf("   🔄 Remapping %s:%s -> %s:%s\n", host, port, publicHostname, port)
			targetHost = publicHostname
		}

		// Create TLS connection with proper SNI
		targetAddr := net.JoinHostPort(targetHost, port)
		dialer := &net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}

		// Dial with TLS
		conn, err := tls.DialWithDialer(dialer, network, targetAddr, &tls.Config{
			MinVersion: tls.VersionTLS12,
			ServerName: publicHostname, // SNI must be the public hostname
		})
		if err != nil {
			return nil, fmt.Errorf("TLS dial to %s failed: %w", targetAddr, err)
		}

		return conn, nil
	}
}

func main() {
	// Load configuration
	clientID := os.Getenv("AZURE_CLIENT_ID")
	redisHost := os.Getenv("REDIS_HOSTNAME")
	redisPort := getEnvOrDefault("REDIS_PORT", "10000")

	// Validate configuration
	if clientID == "" {
		log.Fatal("Error: AZURE_CLIENT_ID environment variable is required")
	}
	if redisHost == "" {
		log.Fatal("Error: REDIS_HOSTNAME environment variable is required")
	}

	fmt.Println()
	fmt.Println("======================================================================")
	fmt.Println("AZURE MANAGED REDIS - GO OSS CLUSTER WITH ENTRA ID AUTH")
	fmt.Println("======================================================================")
	fmt.Println()

	// Create credentials provider
	fmt.Println("1. Creating credentials provider...")
	provider, err := entraid.NewDefaultAzureCredentialsProvider(
		entraid.DefaultAzureCredentialsProviderOptions{},
	)
	if err != nil {
		log.Fatalf("   ❌ Failed to create credentials provider: %v", err)
	}
	fmt.Printf("   ✅ Credentials provider created (using AZURE_CLIENT_ID: %s...)\n\n", clientID[:8])

	// Create cluster client with custom dialer for address remapping
	fmt.Println("2. Creating Redis Cluster client with address remapping...")
	redisAddr := fmt.Sprintf("%s:%s", redisHost, redisPort)

	clusterClient := redis.NewClusterClient(&redis.ClusterOptions{
		Addrs:                        []string{redisAddr},
		StreamingCredentialsProvider: provider,
		// CRITICAL: Custom Dialer for internal IP -> public hostname remapping
		// This is required for Azure Managed Redis OSS Cluster policy
		Dialer:       createClusterDialer(redisHost),
		DialTimeout:  10 * time.Second,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		// Cluster-specific options
		RouteByLatency: false,
		RouteRandomly:  false,
	})
	defer clusterClient.Close()
	fmt.Printf("   ✅ Cluster client configured for %s\n\n", redisAddr)

	ctx := context.Background()

	// Test PING
	fmt.Println("3. Testing PING...")
	pong, err := clusterClient.Ping(ctx).Result()
	if err != nil {
		log.Fatalf("   ❌ PING failed: %v", err)
	}
	fmt.Printf("   ✅ PING response: %s\n\n", pong)

	// Test SET with keys that DEFINITELY hit different shards using hash tags
	// Hash tags {xxx} ensure the slot is calculated from the tag content only
	// This validates that the custom Dialer is working correctly!
	fmt.Println("4. Testing SET operations across MULTIPLE shards...")
	fmt.Println("   Using hash tags to guarantee cross-shard distribution")
	type testKeyInfo struct {
		tag   string
		shard string
	}
	testKeyPairs := []testKeyInfo{
		{"{slot2}", "shard0"},  // slot 98 -> shard 0
		{"{slot3}", "shard0"},  // slot 4163 -> shard 0
		{"{slot0}", "shard1"},  // slot 8224 -> shard 1
		{"{slot1}", "shard1"},  // slot 12289 -> shard 1
	}
	testKeys := make([]string, 0, len(testKeyPairs))
	for _, pair := range testKeyPairs {
		key := fmt.Sprintf("go-cluster:%s:%s", pair.tag, time.Now().Format(time.RFC3339))
		value := fmt.Sprintf("Value for %s from Go OSS Cluster!", pair.tag)
		err = clusterClient.Set(ctx, key, value, 60*time.Second).Err()
		if err != nil {
			log.Fatalf("   ❌ SET failed for key %s: %v", key, err)
		}
		testKeys = append(testKeys, key)
		keyDisplay := key
		if len(key) > 55 {
			keyDisplay = key[:55] + "..."
		}
		fmt.Printf("   ✅ SET '%s' -> %s\n", keyDisplay, pair.shard)
	}
	fmt.Println()

	// Test GET operations - this will trigger MOVED redirects if Dialer works
	fmt.Println("5. Testing GET operations (validates cross-shard routing)...")
	for _, key := range testKeys {
		retrieved, err := clusterClient.Get(ctx, key).Result()
		if err != nil {
			log.Fatalf("   ❌ GET failed for key %s: %v", key, err)
		}
		keyDisplay := key
		if len(key) > 50 {
			keyDisplay = key[:50] + "..."
		}
		_ = retrieved // We just need to verify it works
		fmt.Printf("   ✅ GET '%s'\n", keyDisplay)
	}
	fmt.Println("   If you see this, address remapping via Dialer is working!")
	fmt.Println()

	// Test INCR
	fmt.Println("6. Testing INCR operation...")
	counterKey := "go-cluster-counter"
	newValue, err := clusterClient.Incr(ctx, counterKey).Result()
	if err != nil {
		log.Fatalf("   ❌ INCR failed: %v", err)
	}
	fmt.Printf("   ✅ INCR '%s' = %d\n\n", counterKey, newValue)

	// Get cluster info
	fmt.Println("7. Getting cluster info...")
	clusterInfo, err := clusterClient.ClusterInfo(ctx).Result()
	if err != nil {
		fmt.Printf("   ⚠️ Could not get cluster info: %v\n", err)
	} else {
		// Parse cluster state from info
		for _, line := range strings.Split(clusterInfo, "\n") {
			if strings.HasPrefix(line, "cluster_state:") {
				fmt.Printf("   %s\n", strings.TrimSpace(line))
			} else if strings.HasPrefix(line, "cluster_slots_assigned:") {
				fmt.Printf("   %s\n", strings.TrimSpace(line))
			}
		}
	}
	fmt.Println()

	// Get cluster nodes
	fmt.Println("8. Getting cluster nodes...")
	nodes, err := clusterClient.ClusterNodes(ctx).Result()
	if err != nil {
		fmt.Printf("   ⚠️ Could not get cluster nodes: %v\n", err)
	} else {
		primaryCount := 0
		replicaCount := 0
		for _, line := range strings.Split(nodes, "\n") {
			if strings.Contains(line, "master") {
				primaryCount++
			} else if strings.Contains(line, "slave") {
				replicaCount++
			}
		}
		fmt.Printf("   Primary nodes: %d\n", primaryCount)
		fmt.Printf("   Replica nodes: %d\n", replicaCount)
	}
	fmt.Println()

	// Cleanup
	fmt.Println("9. Cleaning up test keys...")
	for _, key := range testKeys {
		err = clusterClient.Del(ctx, key).Err()
		if err != nil {
			fmt.Printf("   ⚠️ DELETE failed for %s: %v\n", key, err)
		} else {
			keyDisplay := key
			if len(key) > 40 {
				keyDisplay = key[:40] + "..."
			}
			fmt.Printf("   ✅ Deleted '%s'\n", keyDisplay)
		}
	}
	fmt.Println()

	fmt.Println("======================================================================")
	fmt.Println("DEMO COMPLETE - All OSS Cluster operations successful!")
	fmt.Println("======================================================================")
}
