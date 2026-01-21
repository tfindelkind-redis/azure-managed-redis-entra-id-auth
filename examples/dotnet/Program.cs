/*
 * Azure Managed Redis - Entra ID Authentication Examples (.NET)
 * 
 * Entry point for running the authentication examples.
 * 
 * Usage:
 *   dotnet run --user-mi           Run with User-Assigned Managed Identity
 *   dotnet run --system-mi         Run with System-Assigned Managed Identity
 *   dotnet run --service-principal Run with Service Principal
 *   dotnet run --help              Show help
 * 
 * All examples support both cluster policies via REDIS_CLUSTER_POLICY environment variable:
 *   - EnterpriseCluster (default)
 *   - OSSCluster
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
            case "--user-mi":
            case "--userassignedmanagedidentity":
            case "-umi":
                await UserAssignedManagedIdentityExample.RunAsync();
                break;
            
            case "--system-mi":
            case "--systemassignedmanagedidentity":
            case "-smi":
                await SystemAssignedManagedIdentityExample.RunAsync();
                break;
            
            case "--service-principal":
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
        Console.WriteLine(@"
Azure Managed Redis - Entra ID Authentication Examples (.NET)

Usage:
  dotnet run <authentication-type>

Authentication Types:
  --user-mi, -umi       User-Assigned Managed Identity
  --system-mi, -smi     System-Assigned Managed Identity
  --service-principal, -sp   Service Principal (Client Credentials)

Environment Variables (set before running):

  For User-Assigned Managed Identity (--user-mi):
    AZURE_CLIENT_ID    - Client ID of the user-assigned managed identity
    REDIS_HOSTNAME     - Hostname of your Azure Managed Redis instance
    REDIS_PORT         - Port (default: 10000)
    REDIS_CLUSTER_POLICY - ""EnterpriseCluster"" or ""OSSCluster"" (default: EnterpriseCluster)

  For System-Assigned Managed Identity (--system-mi):
    REDIS_HOSTNAME     - Hostname of your Azure Managed Redis instance
    REDIS_PORT         - Port (default: 10000)
    REDIS_CLUSTER_POLICY - ""EnterpriseCluster"" or ""OSSCluster"" (default: EnterpriseCluster)

  For Service Principal (--service-principal):
    AZURE_CLIENT_ID     - Application (client) ID of the service principal
    AZURE_CLIENT_SECRET - Client secret of the service principal
    AZURE_TENANT_ID     - Directory (tenant) ID
    REDIS_HOSTNAME      - Hostname of your Azure Managed Redis instance
    REDIS_PORT          - Port (default: 10000)
    REDIS_CLUSTER_POLICY - ""EnterpriseCluster"" or ""OSSCluster"" (default: EnterpriseCluster)

Examples:
  # Run with User-Assigned Managed Identity
  export AZURE_CLIENT_ID='your-mi-client-id'
  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'
  dotnet run --user-mi

  # Run with Service Principal
  export AZURE_CLIENT_ID='your-sp-client-id'
  export AZURE_CLIENT_SECRET='your-client-secret'
  export AZURE_TENANT_ID='your-tenant-id'
  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'
  dotnet run --service-principal
");
    }
}
