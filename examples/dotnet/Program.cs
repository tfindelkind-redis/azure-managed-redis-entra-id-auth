/*
 * Azure Managed Redis - Entra ID Authentication Examples (.NET)
 * 
 * Entry point for running the authentication examples.
 * 
 * Usage:
 *   dotnet run --ManagedIdentity     Run with User-Assigned Managed Identity
 *   dotnet run --ServicePrincipal    Run with Service Principal
 */

namespace EntraIdAuth;

class Program
{
    static async Task Main(string[] args)
    {
        if (args.Length == 0)
        {
            ShowHelp();
            return;
        }

        switch (args[0].ToLower())
        {
            case "--managedidentity":
            case "-mi":
                await ManagedIdentityExample.RunAsync();
                break;
            
            case "--serviceprincipal":
            case "-sp":
                await ServicePrincipalExample.RunAsync();
                break;
            
            case "--help":
            case "-h":
                ShowHelp();
                break;
            
            default:
                Console.WriteLine($"Unknown option: {args[0]}");
                ShowHelp();
                break;
        }
    }

    static void ShowHelp()
    {
        Console.WriteLine();
        Console.WriteLine("Azure Managed Redis - Entra ID Authentication Examples");
        Console.WriteLine();
        Console.WriteLine("Usage: dotnet run <option>");
        Console.WriteLine();
        Console.WriteLine("Options:");
        Console.WriteLine("  --ManagedIdentity, -mi    Run with User-Assigned Managed Identity");
        Console.WriteLine("  --ServicePrincipal, -sp   Run with Service Principal");
        Console.WriteLine("  --help, -h                Show this help message");
        Console.WriteLine();
        Console.WriteLine("Environment Variables:");
        Console.WriteLine("  For Managed Identity:");
        Console.WriteLine("    AZURE_CLIENT_ID     Client ID of the managed identity");
        Console.WriteLine("    REDIS_HOSTNAME      Redis hostname");
        Console.WriteLine();
        Console.WriteLine("  For Service Principal:");
        Console.WriteLine("    AZURE_CLIENT_ID     Application (client) ID");
        Console.WriteLine("    AZURE_CLIENT_SECRET Client secret");
        Console.WriteLine("    AZURE_TENANT_ID     Directory (tenant) ID");
        Console.WriteLine("    REDIS_HOSTNAME      Redis hostname");
        Console.WriteLine();
    }
}
