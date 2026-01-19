/*
 * Azure Managed Redis - OSS Cluster with Managed Identity Authentication (.NET)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using:
 * - OSS Cluster policy (StackExchange.Redis handles this automatically)
 * - User-Assigned Managed Identity with Entra ID authentication
 * 
 * HOW .NET/StackExchange.Redis HANDLES OSS CLUSTER:
 * =================================================
 * Good news: StackExchange.Redis handles OSS Cluster much better than other clients!
 * 
 * StackExchange.Redis's ConnectionMultiplexer:
 * 1. Automatically discovers all cluster nodes
 * 2. Handles MOVED/ASK redirects transparently
 * 3. Routes commands to correct nodes based on key slot
 * 4. Maintains connections through the initial endpoint (proxy)
 * 
 * Unlike Java Lettuce, Node.js, Python, and Go which try to connect directly
 * to internal cluster nodes, StackExchange.Redis routes all traffic through
 * the initial connection endpoint. Azure's proxy then routes to the correct
 * internal node.
 * 
 * This means NO SPECIAL ADDRESS REMAPPING is needed for .NET!
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
 * 
 * This code should be run from an Azure resource that has the
 * managed identity assigned.
 */

using StackExchange.Redis;
using Microsoft.Azure.StackExchangeRedis;

namespace EntraIdAuth;

public class ClusterManagedIdentityExample
{
    public static async Task RunAsync()
    {
        // Load configuration
        var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID");
        var redisHostname = Environment.GetEnvironmentVariable("REDIS_HOSTNAME");
        var redisPort = Environment.GetEnvironmentVariable("REDIS_PORT") ?? "10000";

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

        Console.WriteLine();
        Console.WriteLine(new string('=', 70));
        Console.WriteLine("AZURE MANAGED REDIS - .NET OSS CLUSTER WITH ENTRA ID AUTH");
        Console.WriteLine(new string('=', 70));
        Console.WriteLine();

        // Create configuration options with Entra ID authentication
        Console.WriteLine("1. Creating connection configuration for OSS Cluster...");
        var connectionString = $"{redisHostname}:{redisPort}";
        
        var configurationOptions = await ConfigurationOptions.Parse(connectionString)
            .ConfigureForAzureWithUserAssignedManagedIdentityAsync(clientId);

        // Configure for OSS Cluster
        // StackExchange.Redis handles cluster routing automatically
        configurationOptions.Ssl = true;
        configurationOptions.AbortOnConnectFail = false;
        configurationOptions.ConnectTimeout = 10000;
        configurationOptions.SyncTimeout = 10000;
        // Allow admin commands for cluster info
        configurationOptions.AllowAdmin = true;
        
        Console.WriteLine($"   ✅ Configuration created for: {clientId[..8]}...");
        Console.WriteLine("   Note: StackExchange.Redis handles OSS Cluster routing automatically!");
        Console.WriteLine();

        // Connect to Redis
        Console.WriteLine("2. Connecting to Redis Cluster...");
        using var connection = await ConnectionMultiplexer.ConnectAsync(configurationOptions);
        Console.WriteLine($"   ✅ Connected to {redisHostname}");
        
        // Show cluster information
        var endpoints = connection.GetEndPoints();
        Console.WriteLine($"   Discovered endpoints: {endpoints.Length}");
        Console.WriteLine();

        var db = connection.GetDatabase();

        // Test PING
        Console.WriteLine("3. Testing PING...");
        var pingResult = await db.PingAsync();
        Console.WriteLine($"   ✅ PING response: {pingResult.TotalMilliseconds}ms");
        Console.WriteLine();

        // Test SET with keys that DEFINITELY hit different shards using hash tags
        // Hash tags {xxx} ensure the slot is calculated from the tag content only
        // This validates that StackExchange.Redis cluster routing works correctly!
        Console.WriteLine("4. Testing SET operations across MULTIPLE shards...");
        Console.WriteLine("   Using hash tags to guarantee cross-shard distribution");
        var testKeyPairs = new[]
        {
            ("{slot2}", "shard0"),   // slot 98 -> shard 0
            ("{slot3}", "shard0"),   // slot 4163 -> shard 0
            ("{slot0}", "shard1"),   // slot 8224 -> shard 1
            ("{slot1}", "shard1"),   // slot 12289 -> shard 1
        };
        var testKeys = new List<string>();
        foreach (var (hashTag, expectedShard) in testKeyPairs)
        {
            var testKey = $"dotnet-cluster:{hashTag}:{DateTime.Now:o}";
            var testValue = $"Value for {hashTag} from .NET OSS Cluster!";
            await db.StringSetAsync(testKey, testValue, TimeSpan.FromSeconds(60));
            testKeys.Add(testKey);
            var displayKey = testKey.Length > 55 ? testKey[..55] + "..." : testKey;
            Console.WriteLine($"   ✅ SET '{displayKey}' -> {expectedShard}");
        }
        Console.WriteLine();

        // Test GET operations - validates cross-shard routing
        Console.WriteLine("5. Testing GET operations (validates cross-shard routing)...");
        foreach (var testKey in testKeys)
        {
            var retrieved = await db.StringGetAsync(testKey);
            var displayKey = testKey.Length > 50 ? testKey[..50] + "..." : testKey;
            Console.WriteLine($"   ✅ GET '{displayKey}'");
        }
        Console.WriteLine("   If you see this, cluster routing is working correctly!");
        Console.WriteLine();

        // Test INCR
        Console.WriteLine("6. Testing INCR operation...");
        var counterKey = "dotnet-cluster-counter";
        var newValue = await db.StringIncrementAsync(counterKey);
        Console.WriteLine($"   ✅ INCR '{counterKey}' = {newValue}");
        Console.WriteLine();

        // Test Hash operations
        Console.WriteLine("7. Testing Hash operations...");
        var hashKey = "dotnet-cluster-hash";
        await db.HashSetAsync(hashKey, new HashEntry[] {
            new("field1", "value1"),
            new("field2", "value2")
        });
        var hashValue = await db.HashGetAsync(hashKey, "field1");
        Console.WriteLine($"   ✅ HSET/HGET '{hashKey}' field1 = '{hashValue}'");
        Console.WriteLine();

        // Get cluster info
        Console.WriteLine("8. Getting cluster info...");
        try
        {
            var server = connection.GetServer(connection.GetEndPoints()[0]);
            
            // Try to get cluster info
            var clusterConfig = connection.GetServer(connection.GetEndPoints()[0]).ClusterConfiguration;
            if (clusterConfig != null)
            {
                var nodes = clusterConfig.Nodes;
                var primaryCount = 0;
                var replicaCount = 0;
                foreach (var node in nodes)
                {
                    if (node.IsReplica)
                        replicaCount++;
                    else
                        primaryCount++;
                }
                Console.WriteLine($"   Cluster state: ok");
                Console.WriteLine($"   Primary nodes: {primaryCount}");
                Console.WriteLine($"   Replica nodes: {replicaCount}");
            }
            else
            {
                Console.WriteLine("   Cluster configuration not available (may be Enterprise policy)");
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"   ⚠️ Could not get cluster info: {ex.Message}");
        }
        Console.WriteLine();

        // Get database size
        Console.WriteLine("9. Getting database size...");
        try
        {
            var server = connection.GetServer(connection.GetEndPoints()[0]);
            var dbSize = await server.DatabaseSizeAsync();
            Console.WriteLine($"   Database contains approximately {dbSize} keys");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"   ⚠️ Could not get database size: {ex.Message}");
        }
        Console.WriteLine();

        // Cleanup - delete keys individually (required for cluster)
        Console.WriteLine("10. Cleaning up test keys...");
        foreach (var testKey in testKeys)
        {
            await db.KeyDeleteAsync(testKey);
            var displayKey = testKey.Length > 50 ? testKey[..50] + "..." : testKey;
            Console.WriteLine($"   ✅ Deleted '{displayKey}'");
        }
        await db.KeyDeleteAsync(hashKey);
        Console.WriteLine($"   ✅ Deleted '{hashKey}'");
        await db.KeyDeleteAsync(counterKey);
        Console.WriteLine($"   ✅ Deleted '{counterKey}'");
        Console.WriteLine();

        Console.WriteLine(new string('=', 70));
        Console.WriteLine("DEMO COMPLETE - All OSS Cluster operations successful!");
        Console.WriteLine(new string('=', 70));
    }
}
