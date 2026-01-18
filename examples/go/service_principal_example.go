/*
Azure Managed Redis - Service Principal Authentication Example (Go)

This example demonstrates how to connect to Azure Managed Redis using
a Service Principal with Entra ID authentication.

This is useful for:
- Local development
- CI/CD pipelines
- Non-Azure environments

Environment Variables:
- AZURE_CLIENT_ID: Application (client) ID of the service principal
- AZURE_CLIENT_SECRET: Client secret of the service principal
- AZURE_TENANT_ID: Directory (tenant) ID
- REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
- REDIS_PORT: Port (default: 10000)
*/

package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"os"
	"time"

	entraid "github.com/redis/go-redis-entraid"
	"github.com/redis/go-redis-entraid/identity"
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
	clientSecret := os.Getenv("AZURE_CLIENT_SECRET")
	tenantID := os.Getenv("AZURE_TENANT_ID")
	redisHost := os.Getenv("REDIS_HOSTNAME")
	redisPort := getEnvOrDefault("REDIS_PORT", "10000")

	// Validate configuration
	var missing []string
	if clientID == "" {
		missing = append(missing, "AZURE_CLIENT_ID")
	}
	if clientSecret == "" {
		missing = append(missing, "AZURE_CLIENT_SECRET")
	}
	if tenantID == "" {
		missing = append(missing, "AZURE_TENANT_ID")
	}
	if redisHost == "" {
		missing = append(missing, "REDIS_HOSTNAME")
	}

	if len(missing) > 0 {
		fmt.Printf("Error: Missing required environment variables: %v\n", missing)
		fmt.Println("\nPlease set:")
		fmt.Println("  export AZURE_CLIENT_ID='your-client-id'")
		fmt.Println("  export AZURE_CLIENT_SECRET='your-client-secret'")
		fmt.Println("  export AZURE_TENANT_ID='your-tenant-id'")
		fmt.Println("  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'")
		os.Exit(1)
	}

	fmt.Println()
	fmt.Println("============================================================")
	fmt.Println("AZURE MANAGED REDIS - GO SERVICE PRINCIPAL AUTH DEMO")
	fmt.Println("============================================================")
	fmt.Println()

	// Create credentials provider for service principal
	fmt.Println("1. Creating credentials provider...")
	provider, err := entraid.NewConfidentialCredentialsProvider(
		entraid.ConfidentialCredentialsProviderOptions{
			ConfidentialIdentityProviderOptions: identity.ConfidentialIdentityProviderOptions{
				ClientID:        clientID,
				ClientSecret:    clientSecret,
				CredentialsType: identity.ClientSecretCredentialType,
				Authority: identity.AuthorityConfiguration{
					AuthorityType: identity.AuthorityTypeDefault,
					TenantID:      tenantID,
				},
			},
		},
	)
	if err != nil {
		log.Fatalf("   ❌ Failed to create credentials provider: %v", err)
	}
	fmt.Printf("   ✅ Credentials provider created for SP: %s...\n\n", clientID[:8])

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
	testKey := fmt.Sprintf("go-sp-test:%s", time.Now().Format(time.RFC3339))
	testValue := "Hello from Go with Service Principal auth!"
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

	// Test Hash operations
	fmt.Println("6. Testing Hash operations...")
	hashKey := "go-sp-hash"
	err = client.HSet(ctx, hashKey, "field1", "value1", "field2", "value2").Err()
	if err != nil {
		log.Fatalf("   ❌ HSET failed: %v", err)
	}
	hashValue, err := client.HGet(ctx, hashKey, "field1").Result()
	if err != nil {
		log.Fatalf("   ❌ HGET failed: %v", err)
	}
	fmt.Printf("   ✅ HSET/HGET '%s' field1 = '%s'\n\n", hashKey, hashValue)

	// Test DBSIZE
	fmt.Println("7. Getting database size...")
	dbSize, err := client.DBSize(ctx).Result()
	if err != nil {
		log.Fatalf("   ❌ DBSIZE failed: %v", err)
	}
	fmt.Printf("   Database contains %d keys\n\n", dbSize)

	// Cleanup
	fmt.Println("8. Cleaning up test keys...")
	err = client.Del(ctx, testKey, hashKey).Err()
	if err != nil {
		log.Printf("   ⚠️  DELETE failed: %v", err)
	} else {
		fmt.Println("   ✅ Deleted test keys\n")
	}

	fmt.Println("============================================================")
	fmt.Println("DEMO COMPLETE - All operations successful!")
	fmt.Println("============================================================")
}
