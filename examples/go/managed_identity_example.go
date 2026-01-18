/*
Azure Managed Redis - Managed Identity Authentication Example (Go)

This example demonstrates how to connect to Azure Managed Redis using
a User-Assigned Managed Identity with Entra ID authentication.

Requirements:
- Go 1.21+
- go-redis v9.9.0+
- go-redis-entraid

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
	"os"
	"time"

	"github.com/redis-developer/go-redis-entraid/entraid"
	"github.com/redis-developer/go-redis-entraid/identity"
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

	// Validate configuration
	if clientID == "" {
		log.Fatal("Error: AZURE_CLIENT_ID environment variable is required")
	}
	if redisHost == "" {
		log.Fatal("Error: REDIS_HOSTNAME environment variable is required")
	}

	fmt.Println()
	fmt.Println("============================================================")
	fmt.Println("AZURE MANAGED REDIS - GO MANAGED IDENTITY AUTH DEMO")
	fmt.Println("============================================================")
	fmt.Println()

	// Create credentials provider for user-assigned managed identity
	fmt.Println("1. Creating credentials provider...")
	provider, err := entraid.NewManagedIdentityCredentialsProvider(
		entraid.ManagedIdentityCredentialsProviderOptions{
			ManagedIdentityProviderOptions: identity.ManagedIdentityProviderOptions{
				ManagedIdentityType:  identity.UserAssignedClientID,
				UserAssignedClientID: clientID,
			},
		},
	)
	if err != nil {
		log.Fatalf("   ❌ Failed to create credentials provider: %v", err)
	}
	fmt.Printf("   ✅ Credentials provider created for: %s...\n\n", clientID[:8])

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
	testKey := fmt.Sprintf("go-entra-test:%s", time.Now().Format(time.RFC3339))
	testValue := "Hello from Go with Entra ID auth!"
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
	counterKey := "go-counter"
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

	fmt.Println("============================================================")
	fmt.Println("DEMO COMPLETE - All operations successful!")
	fmt.Println("============================================================")
}
