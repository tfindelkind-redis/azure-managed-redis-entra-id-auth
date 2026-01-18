/*
 * Azure Managed Redis - Managed Identity Authentication Example (.NET)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
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

public class ManagedIdentityExample
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
        Console.WriteLine("============================================================");
        Console.WriteLine("AZURE MANAGED REDIS - .NET MANAGED IDENTITY AUTH DEMO");
        Console.WriteLine("============================================================");
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
        var testKey = $"dotnet-entra-test:{DateTime.Now:o}";
        var testValue = "Hello from .NET with Entra ID auth!";
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
        var counterKey = "dotnet-counter";
        var newValue = await db.StringIncrementAsync(counterKey);
        Console.WriteLine($"   ✅ INCR '{counterKey}' = {newValue}");
        Console.WriteLine();

        // Test Hash operations
        Console.WriteLine("7. Testing Hash operations...");
        var hashKey = "dotnet-hash";
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

        // Cleanup
        Console.WriteLine("9. Cleaning up test keys...");
        await db.KeyDeleteAsync(new RedisKey[] { testKey, hashKey });
        Console.WriteLine("   ✅ Deleted test keys");
        Console.WriteLine();

        Console.WriteLine("============================================================");
        Console.WriteLine("DEMO COMPLETE - All operations successful!");
        Console.WriteLine("============================================================");
    }
}
