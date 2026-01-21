/*
 * Azure Managed Redis - User-Assigned Managed Identity Authentication (.NET)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
 * 
 * CLUSTER POLICY SUPPORT:
 * - Enterprise Cluster: ✅ Fully supported (server handles slot routing)
 * - OSS Cluster: ✅ Fully supported (StackExchange.Redis handles cluster automatically)
 * 
 * Note: StackExchange.Redis automatically handles cluster topology discovery
 * and slot routing for both Enterprise and OSS Cluster policies.
 * 
 * Requirements:
 * - .NET 8.0+
 * - StackExchange.Redis 2.8.0+
 * - Microsoft.Azure.StackExchangeRedis 3.2.0+
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 * - REDIS_CLUSTER_POLICY: "EnterpriseCluster" or "OSSCluster" (default: EnterpriseCluster)
 * 
 * This code should be run from an Azure resource that has the
 * managed identity assigned.
 */

using StackExchange.Redis;
using Microsoft.Azure.StackExchangeRedis;

namespace EntraIdAuth;

public class UserAssignedManagedIdentityExample
{
    public static async Task RunAsync()
    {
        // Load configuration
        var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID");
        var redisHostname = Environment.GetEnvironmentVariable("REDIS_HOSTNAME");
        var redisPort = Environment.GetEnvironmentVariable("REDIS_PORT") ?? "10000";
        var clusterPolicy = Environment.GetEnvironmentVariable("REDIS_CLUSTER_POLICY") ?? "EnterpriseCluster";

        // Validate configuration
        if (string.IsNullOrEmpty(clientId))
        {
            Console.WriteLine("Error: AZURE_CLIENT_ID environment variable is required");
            Environment.Exit(1);
        }
        if (string.IsNullOrEmpty(redisHostname))
        {
            Console.WriteLine("Error: REDIS_HOSTNAME environment variable is required");
            Environment.Exit(1);
        }

        var isOSSCluster = clusterPolicy.Equals("OSSCluster", StringComparison.OrdinalIgnoreCase);

        Console.WriteLine();
        Console.WriteLine("======================================================================");
        Console.WriteLine("AZURE MANAGED REDIS - USER-ASSIGNED MANAGED IDENTITY (.NET)");
        Console.WriteLine($"Cluster Policy: {clusterPolicy}" + (isOSSCluster ? " (cluster-aware)" : " (standard)"));
        Console.WriteLine("======================================================================");
        Console.WriteLine();

        // Create configuration options with Entra ID authentication
        Console.WriteLine("1. Creating connection configuration...");
        var connectionString = $"{redisHostname}:{redisPort}";
        
        var configurationOptions = await ConfigurationOptions.Parse(connectionString)
            .ConfigureForAzureWithUserAssignedManagedIdentityAsync(clientId);

        // Configure additional options
        configurationOptions.Ssl = true;
        configurationOptions.AbortOnConnectFail = false;
        configurationOptions.ConnectTimeout = 10000;
        configurationOptions.SyncTimeout = 10000;
        
        Console.WriteLine($"   ✅ Configuration created for: {clientId[..8]}...");
        Console.WriteLine();

        // Connect to Redis
        Console.WriteLine("2. Connecting to Redis...");
        using var connection = await ConnectionMultiplexer.ConnectAsync(configurationOptions);
        Console.WriteLine($"   ✅ Connected to {redisHostname}");
        Console.WriteLine();

        var db = connection.GetDatabase();

        // Test PING
        Console.WriteLine("3. Testing PING...");
        var pingResult = await db.PingAsync();
        Console.WriteLine($"   ✅ PING response: {pingResult.TotalMilliseconds}ms");
        Console.WriteLine();

        // Test SET
        Console.WriteLine("4. Testing SET operation...");
        var testKey = $"dotnet-usermi-test:{DateTime.Now:o}";
        var testValue = "Hello from .NET with User-Assigned Managed Identity!";
        await db.StringSetAsync(testKey, testValue, TimeSpan.FromSeconds(60));
        Console.WriteLine($"   ✅ SET '{testKey}'");
        Console.WriteLine();

        // Test GET
        Console.WriteLine("5. Testing GET operation...");
        var retrieved = await db.StringGetAsync(testKey);
        Console.WriteLine($"   ✅ GET '{testKey}' = '{retrieved}'");
        Console.WriteLine();

        // Test INCR
        Console.WriteLine("6. Testing INCR operation...");
        var counterKey = "dotnet-usermi-counter";
        var newValue = await db.StringIncrementAsync(counterKey);
        Console.WriteLine($"   ✅ INCR '{counterKey}' = {newValue}");
        Console.WriteLine();

        // Test Hash operations
        Console.WriteLine("7. Testing Hash operations...");
        var hashKey = "dotnet-usermi-hash";
        await db.HashSetAsync(hashKey, new HashEntry[] {
            new("field1", "value1"),
            new("field2", "value2")
        });
        var hashValue = await db.HashGetAsync(hashKey, "field1");
        Console.WriteLine($"   ✅ HSET/HGET '{hashKey}' field1 = '{hashValue}'");
        Console.WriteLine();

        // Get server info
        Console.WriteLine("8. Getting server info...");
        var server = connection.GetServer(connection.GetEndPoints()[0]);
        var dbSize = await server.DatabaseSizeAsync();
        Console.WriteLine($"   Database contains {dbSize} keys");
        Console.WriteLine();

        // Cleanup - delete keys individually for OSS Cluster compatibility
        Console.WriteLine("9. Cleaning up test keys...");
        await db.KeyDeleteAsync(testKey);
        await db.KeyDeleteAsync(hashKey);
        await db.KeyDeleteAsync(counterKey);
        Console.WriteLine("   ✅ Deleted test keys");
        Console.WriteLine();

        Console.WriteLine("======================================================================");
        Console.WriteLine("DEMO COMPLETE - All operations successful!");
        Console.WriteLine("======================================================================");
    }
}
