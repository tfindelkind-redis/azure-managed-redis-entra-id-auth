# Go - Entra ID Authentication for Azure Managed Redis

This directory contains Go examples for authenticating to Azure Managed Redis using Microsoft Entra ID.

## 📦 Installation

```bash
go get github.com/redis/go-redis/v9
go get github.com/redis/go-redis-entraid
```

## 🔑 Authentication Options

### Option 1: User-Assigned Managed Identity

```go
package main

import (
    "context"
    "fmt"
    "log"
    "os"

    "github.com/redis-developer/go-redis-entraid/entraid"
    "github.com/redis-developer/go-redis-entraid/identity"
    "github.com/redis/go-redis/v9"
)

func main() {
    // Create credentials provider for user-assigned managed identity
    provider, err := entraid.NewManagedIdentityCredentialsProvider(
        entraid.ManagedIdentityCredentialsProviderOptions{
            ManagedIdentityProviderOptions: identity.ManagedIdentityProviderOptions{
                ManagedIdentityType:  identity.UserAssignedClientID,
                UserAssignedClientID: os.Getenv("AZURE_CLIENT_ID"),
            },
        },
    )
    if err != nil {
        log.Fatalf("Failed to create credentials provider: %v", err)
    }

    // Create Redis client
    client := redis.NewClient(&redis.Options{
        Addr:                         os.Getenv("REDIS_HOSTNAME") + ":10000",
        StreamingCredentialsProvider: provider,
        TLSConfig:                    &tls.Config{MinVersion: tls.VersionTLS12},
    })
    defer client.Close()

    // Test connection
    ctx := context.Background()
    pong, err := client.Ping(ctx).Result()
    if err != nil {
        log.Fatalf("PING failed: %v", err)
    }
    fmt.Println("PING:", pong)
}
```

### Option 2: System-Assigned Managed Identity

```go
provider, err := entraid.NewManagedIdentityCredentialsProvider(
    entraid.ManagedIdentityCredentialsProviderOptions{
        ManagedIdentityProviderOptions: identity.ManagedIdentityProviderOptions{
            ManagedIdentityType: identity.SystemAssignedIdentity,
        },
    },
)
```

### Option 3: Service Principal

```go
provider, err := entraid.NewConfidentialCredentialsProvider(
    entraid.ConfidentialCredentialsProviderOptions{
        ConfidentialIdentityProviderOptions: identity.ConfidentialIdentityProviderOptions{
            ClientID:        os.Getenv("AZURE_CLIENT_ID"),
            ClientSecret:    os.Getenv("AZURE_CLIENT_SECRET"),
            CredentialsType: identity.ClientSecretCredentialType,
            Authority: identity.AuthorityConfiguration{
                AuthorityType: identity.AuthorityTypeDefault,
                TenantID:      os.Getenv("AZURE_TENANT_ID"),
            },
        },
    },
)
```

## 📁 Project Structure

```
go/
├── README.md
├── go.mod
├── managed_identity_example.go           # Enterprise policy
├── cluster_managed_identity_example.go   # OSS Cluster policy
└── service_principal_example.go          # Service principal auth
```

## 🔧 Cluster Policy Support

Azure Managed Redis supports two cluster policies:

### EnterpriseCluster (Default)
Uses `redis.NewClient()` - server handles slot routing. See `managed_identity_example.go`.

### OSSCluster
Uses `redis.NewClusterClient()` with custom `Dialer` for address remapping. The key challenge is that Azure returns internal IPs in CLUSTER SLOTS responses that are unreachable from outside Azure:

```go
import (
    "crypto/tls"
    "net"
    "github.com/redis/go-redis/v9"
)

// Custom dialer that remaps internal IPs to public hostname
func createClusterDialer(publicHostname string) func(ctx context.Context, network, addr string) (net.Conn, error) {
    return func(ctx context.Context, network, addr string) (net.Conn, error) {
        host, port, _ := net.SplitHostPort(addr)
        
        // Check if this is a private IP that needs remapping
        if strings.HasPrefix(host, "10.") || 
           strings.HasPrefix(host, "192.168.") ||
           isPrivate172(host) {
            addr = net.JoinHostPort(publicHostname, port)
        }
        
        // Create TLS connection with correct ServerName for SNI
        return tls.DialWithDialer(&net.Dialer{}, network, addr, &tls.Config{
            MinVersion: tls.VersionTLS12,
            ServerName: publicHostname,  // Critical for SSL validation!
        })
    }
}

client := redis.NewClusterClient(&redis.ClusterOptions{
    Addrs:                        []string{redisAddr},
    StreamingCredentialsProvider: provider,
    TLSConfig:                    tlsConfig,
    Dialer:                       createClusterDialer(redisHost),  // Key for OSS Cluster!
})
```

See `cluster_managed_identity_example.go` for the full implementation.

## 🔧 Running Examples

```bash
# Initialize module
go mod tidy

# Run with managed identity (from Azure)
export AZURE_CLIENT_ID="your-managed-identity-client-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
go run managed_identity_example.go

# Run with service principal (local development)
export AZURE_CLIENT_ID="your-client-id"
export AZURE_CLIENT_SECRET="your-secret"
export AZURE_TENANT_ID="your-tenant-id"
export REDIS_HOSTNAME="your-redis.region.redis.azure.net"
go run service_principal_example.go
```

## 🔧 Custom Configuration

```go
import (
    "time"
    "strings"
    "github.com/redis-developer/go-redis-entraid/manager"
)

options := entraid.CredentialsProviderOptions{
    TokenManagerOptions: manager.TokenManagerOptions{
        ExpirationRefreshRatio: 0.7,
        LowerRefreshBounds:     10000,
        RetryOptions: manager.RetryOptions{
            MaxAttempts:       3,
            InitialDelay:      1000 * time.Millisecond,
            MaxDelay:          30000 * time.Millisecond,
            BackoffMultiplier: 2.0,
            IsRetryable: func(err error) bool {
                return strings.Contains(err.Error(), "network error") ||
                    strings.Contains(err.Error(), "timeout")
            },
        },
    },
}
```

## 📚 Resources

- [go-redis Documentation](https://redis.io/docs/latest/develop/clients/go/)
- [go-redis-entraid GitHub](https://github.com/redis/go-redis-entraid)
- [Azure Managed Redis Entra ID Docs](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/managed-redis/managed-redis-entra-for-authentication)
