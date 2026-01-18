/*
 * Azure Managed Redis - Service Principal Authentication Example (.NET)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a Service Principal with Entra ID authentication.
 * 
 * This is useful for:
 * - Local development
 * - CI/CD pipelines
 * - Non-Azure environments
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Application (client) ID of the service principal
 * - AZURE_CLIENT_SECRET: Client secret of the service principal
 * - AZURE_TENANT_ID: Directory (tenant) ID
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 */

using StackExchange.Redis;
using Microsoft.Azure.StackExchangeRedis;

namespace EntraIdAuth;

public class ServicePrincipalExample
{
    public static async Task RunAsync()
    {
        // Load configuration
        var clientId = Environment.GetEnvironmentVariable("AZURE_CLIENT_ID");
        var clientSecret = Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET");
        var tenantId = Environment.GetEnvironmentVariable("AZURE_TENANT_ID");
        var redisHostname = Environment.GetEnvironmentVariable("REDIS_HOSTNAME");
        var redisPort = Environment.GetEnvironmentVariable("REDIS_PORT") ?? "10000";

        // Validate configuration
        var missing = new List<string>();
        if (string.IsNullOrEmpty(clientId)) missing.Add("AZURE_CLIENT_ID");
        if (string.IsNullOrEmpty(clientSecret)) missing.Add("AZURE_CLIENT_SECRET");
        if (string.IsNullOrEmpty(tenantId)) missing.Add("AZURE_TENANT_ID");
        if (string.IsNullOrEmpty(redisHostname)) missing.Add("REDIS_HOSTNAME");

        if (missing.Count > 0)
        {
            Console.WriteLine($"Error: Missing required environment variables: {string.Join(", ", missing)}");
            Console.WriteLine();
            Console.WriteLine("Please set:");
            Console.WriteLine("  export AZURE_CLIENT_ID='your-client-id'");
            Console.WriteLine("  export AZURE_CLIENT_SECRET='your-client-secret'");
            Console.WriteLine("  export AZURE_TENANT_ID='your-tenant-id'");
            Console.WriteLine("  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'");
            Environment.Exit(1);
        }

        Console.WriteLine();
        Console.WriteLine("============================================================");
        Console.WriteLine("AZURE MANAGED REDIS - .NET SERVICE PRINCIPAL AUTH DEMO");
        Console.WriteLine("============================================================");
        Console.WriteLine();

        // Create configuration options with Service Principal authentication
        Console.WriteLine("1. Creating connection configuration...");
        var connectionString = $"{redisHostname}:{redisPort}";
        
        var configurationOptions = await ConfigurationOptions.Parse(connectionString)
            .ConfigureForAzureWithServicePrincipalAsync(clientId!, tenantId!, clientSecret!);

        // Configure additional options
        configurationOptions.Ssl = true;
        configurationOptions.AbortOnConnectFail = false;
        configurationOptions.ConnectTimeout = 10000;
        configurationOptions.SyncTimeout = 10000;
        
        Console.WriteLine($"   ✅ Configuration created for SP: {clientId![..8]}...");
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
        var testKey = $"dotnet-sp-test:{DateTime.Now:o}";
        var testValue = "Hello from .NET with Service Principal auth!";
        await db.StringSetAsync(testKey, testValue, TimeSpan.FromSeconds(60));
        Console.WriteLine($"   ✅ SET '{testKey}'");
        Console.WriteLine();

        // Test GET
        Console.WriteLine("5. Testing GET operation...");
        var retrieved = await db.StringGetAsync(testKey);
        Console.WriteLine($"   ✅ GET '{testKey}' = '{retrieved}'");
        Console.WriteLine();

        // Test List operations
        Console.WriteLine("6. Testing List operations...");
        var listKey = "dotnet-sp-list";
        await db.ListRightPushAsync(listKey, new RedisValue[] { "item1", "item2", "item3" });
        var listLength = await db.ListLengthAsync(listKey);
        var firstItem = await db.ListGetByIndexAsync(listKey, 0);
        Console.WriteLine($"   ✅ RPUSH/LLEN '{listKey}' length = {listLength}, first = '{firstItem}'");
        Console.WriteLine();

        // Test Set operations
        Console.WriteLine("7. Testing Set operations...");
        var setKey = "dotnet-sp-set";
        await db.SetAddAsync(setKey, new RedisValue[] { "member1", "member2", "member3" });
        var setSize = await db.SetLengthAsync(setKey);
        var isMember = await db.SetContainsAsync(setKey, "member1");
        Console.WriteLine($"   ✅ SADD/SCARD '{setKey}' size = {setSize}, contains member1 = {isMember}");
        Console.WriteLine();

        // Get server info
        Console.WriteLine("8. Getting server info...");
        var server = connection.GetServer(connection.GetEndPoints()[0]);
        var dbSize = await server.DatabaseSizeAsync();
        Console.WriteLine($"   Database contains {dbSize} keys");
        Console.WriteLine();

        // Cleanup
        Console.WriteLine("9. Cleaning up test keys...");
        await db.KeyDeleteAsync(new RedisKey[] { testKey, listKey, setKey });
        Console.WriteLine("   ✅ Deleted test keys");
        Console.WriteLine();

        Console.WriteLine("============================================================");
        Console.WriteLine("DEMO COMPLETE - All operations successful!");
        Console.WriteLine("============================================================");
    }
}
