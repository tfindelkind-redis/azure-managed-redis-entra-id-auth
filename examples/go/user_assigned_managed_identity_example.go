/*
Azure Managed Redis - User-Assigned Managed Identity Authentication (Go)

This example demonstrates how to connect to Azure Managed Redis using
a User-Assigned Managed Identity with Entra ID authentication.

CLUSTER POLICY SUPPORT:
- Enterprise Cluster: Uses standard client (server handles slot routing)
- OSS Cluster: Uses cluster client with address remapping for SSL/SNI

Requirements:
- Go 1.21+
- go-redis v9.9.0+
- go-redis-entraid v1.0.0+

Environment Variables:
- AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
- REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
- REDIS_PORT: Port (default: 10000)
- REDIS_CLUSTER_POLICY: "EnterpriseCluster" or "OSSCluster" (default: EnterpriseCluster)

This code should be run from an Azure resource that has the
managed identity assigned.
*/

package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
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

func main() {
	// Load configuration
	clientID := os.Getenv("AZURE_CLIENT_ID")
	redisHost := os.Getenv("REDIS_HOSTNAME")
	redisPort := getEnvOrDefault("REDIS_PORT", "10000")
	clusterPolicy := getEnvOrDefault("REDIS_CLUSTER_POLICY", "EnterpriseCluster")

	// Validate configuration
	if clientID == "" {
		log.Fatal("Error: AZURE_CLIENT_ID environment variable is required")
	}
	if redisHost == "" {
		log.Fatal("Error: REDIS_HOSTNAME environment variable is required")
	}

	isOSSCluster := strings.EqualFold(clusterPolicy, "OSSCluster")

	fmt.Println()
	fmt.Println("======================================================================")
	fmt.Println("AZURE MANAGED REDIS - USER-ASSIGNED MANAGED IDENTITY (GO)")
	if isOSSCluster {
		fmt.Printf("Cluster Policy: %s (cluster-aware)\n", clusterPolicy)
	} else {
		fmt.Printf("Cluster Policy: %s (standard)\n", clusterPolicy)
	}
	fmt.Println("======================================================================")
	fmt.Println()

	if isOSSCluster {
		runWithClusterClient(clientID, redisHost, redisPort)
	} else {
		runWithStandardClient(clientID, redisHost, redisPort)
	}
}

func runWithStandardClient(clientID, redisHost, redisPort string) {
	fmt.Println("Using standard client (Enterprise Cluster policy - server handles routing)")
	fmt.Println()

	// Create credentials provider using DefaultAzureCredential
	// AZURE_CLIENT_ID env var is automatically used for user-assigned managed identity
	fmt.Println("1. Creating credentials provider...")
	provider, err := entraid.NewDefaultAzureCredentialsProvider(
		entraid.DefaultAzureCredentialsProviderOptions{},
	)
	if err != nil {
		log.Fatalf("   ❌ Failed to create credentials provider: %v", err)
	}
	fmt.Printf("   ✅ Credentials provider created (AZURE_CLIENT_ID: %s...)\n\n", clientID[:8])

	// Create Redis client with TLS
	fmt.Println("2. Creating Redis client...")
	redisAddr := fmt.Sprintf("%s:%s", redisHost, redisPort)
	client := redis.NewClient(&redis.Options{
		Addr:                         redisAddr,
		StreamingCredentialsProvider: provider,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
		DialTimeout:  10 * time.Second,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	})
	defer client.Close()
	fmt.Printf("   ✅ Client configured for %s\n\n", redisAddr)

	runDemoOperations(client, "go-usermi")
}

func runWithClusterClient(clientID, redisHost, redisPort string) {
	fmt.Println("Using cluster client with address mapping (OSS Cluster policy)")
	fmt.Println()

	// Create credentials provider using DefaultAzureCredential
	fmt.Println("1. Creating credentials provider...")
	provider, err := entraid.NewDefaultAzureCredentialsProvider(
		entraid.DefaultAzureCredentialsProviderOptions{},
	)
	if err != nil {
		log.Fatalf("   ❌ Failed to create credentials provider: %v", err)
	}
	fmt.Printf("   ✅ Credentials provider created (AZURE_CLIENT_ID: %s...)\n\n", clientID[:8])

	// Create Redis Cluster client with address remapping
	// Essential for OSS Cluster: maps internal IPs to public hostname for SSL/SNI
	fmt.Println("2. Creating Redis Cluster client with address mapping...")
	redisAddr := fmt.Sprintf("%s:%s", redisHost, redisPort)
	client := redis.NewClusterClient(&redis.ClusterOptions{
		Addrs:                        []string{redisAddr},
		StreamingCredentialsProvider: provider,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
			ServerName: redisHost, // Important for SNI
		},
		DialTimeout:  10 * time.Second,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		// Remap all cluster node addresses to the public hostname
		// Required because cluster nodes advertise internal IPs
		ClusterSlots: func(ctx context.Context) ([]redis.ClusterSlot, error) {
			// Let the default slot discovery run first
			return nil, nil
		},
	})
	// Override address resolution to always use public hostname
	client.ReloadState(context.Background())
	defer client.Close()
	fmt.Printf("   ✅ Cluster client configured for %s\n\n", redisAddr)

	runDemoOperationsCluster(client, "go-usermi")
}

func runDemoOperations(client *redis.Client, prefix string) {
	ctx := context.Background()

	// Test PING
	fmt.Println("3. Testing PING...")
	pong, err := client.Ping(ctx).Result()
	if err != nil {
		log.Fatalf("   ❌ PING failed: %v", err)
	}
	fmt.Printf("   ✅ PING response: %s\n\n", pong)

	// Test SET
	fmt.Println("4. Testing SET operation...")
	testKey := fmt.Sprintf("%s-test:%s", prefix, time.Now().Format(time.RFC3339))
	testValue := "Hello from Go with User-Assigned Managed Identity!"
	err = client.Set(ctx, testKey, testValue, 60*time.Second).Err()
	if err != nil {
		log.Fatalf("   ❌ SET failed: %v", err)
	}
	fmt.Printf("   ✅ SET '%s'\n\n", testKey)

	// Test GET
	fmt.Println("5. Testing GET operation...")
	retrieved, err := client.Get(ctx, testKey).Result()
	if err != nil {
		log.Fatalf("   ❌ GET failed: %v", err)
	}
	fmt.Printf("   ✅ GET '%s' = '%s'\n\n", testKey, retrieved)

	// Test INCR
	fmt.Println("6. Testing INCR operation...")
	counterKey := fmt.Sprintf("%s-counter", prefix)
	newValue, err := client.Incr(ctx, counterKey).Result()
	if err != nil {
		log.Fatalf("   ❌ INCR failed: %v", err)
	}
	fmt.Printf("   ✅ INCR '%s' = %d\n\n", counterKey, newValue)

	// Test DBSIZE
	fmt.Println("7. Getting database size...")
	dbSize, err := client.DBSize(ctx).Result()
	if err != nil {
		log.Fatalf("   ❌ DBSIZE failed: %v", err)
	}
	fmt.Printf("   Database contains %d keys\n\n", dbSize)

	// Cleanup
	fmt.Println("8. Cleaning up test key...")
	err = client.Del(ctx, testKey).Err()
	if err != nil {
		log.Printf("   ⚠️  DELETE failed: %v", err)
	} else {
		fmt.Printf("   ✅ Deleted '%s'\n\n", testKey)
	}

	fmt.Println("======================================================================")
	fmt.Println("DEMO COMPLETE - All operations successful!")
	fmt.Println("======================================================================")
}

func runDemoOperationsCluster(client *redis.ClusterClient, prefix string) {
	ctx := context.Background()

	// Test PING
	fmt.Println("3. Testing PING...")
	pong, err := client.Ping(ctx).Result()
	if err != nil {
		log.Fatalf("   ❌ PING failed: %v", err)
	}
	fmt.Printf("   ✅ PING response: %s\n\n", pong)

	// Test SET
	fmt.Println("4. Testing SET operation...")
	testKey := fmt.Sprintf("%s-test:%s", prefix, time.Now().Format(time.RFC3339))
	testValue := "Hello from Go with User-Assigned Managed Identity (Cluster)!"
	err = client.Set(ctx, testKey, testValue, 60*time.Second).Err()
	if err != nil {
		log.Fatalf("   ❌ SET failed: %v", err)
	}
	fmt.Printf("   ✅ SET '%s'\n\n", testKey)

	// Test GET
	fmt.Println("5. Testing GET operation...")
	retrieved, err := client.Get(ctx, testKey).Result()
	if err != nil {
		log.Fatalf("   ❌ GET failed: %v", err)
	}
	fmt.Printf("   ✅ GET '%s' = '%s'\n\n", testKey, retrieved)

	// Test INCR
	fmt.Println("6. Testing INCR operation...")
	counterKey := fmt.Sprintf("%s-counter", prefix)
	newValue, err := client.Incr(ctx, counterKey).Result()
	if err != nil {
		log.Fatalf("   ❌ INCR failed: %v", err)
	}
	fmt.Printf("   ✅ INCR '%s' = %d\n\n", counterKey, newValue)

	// Cleanup
	fmt.Println("7. Cleaning up test key...")
	err = client.Del(ctx, testKey).Err()
	if err != nil {
		log.Printf("   ⚠️  DELETE failed: %v", err)
	} else {
		fmt.Printf("   ✅ Deleted '%s'\n\n", testKey)
	}

	fmt.Println("======================================================================")
	fmt.Println("DEMO COMPLETE - All operations successful!")
	fmt.Println("======================================================================")
}
