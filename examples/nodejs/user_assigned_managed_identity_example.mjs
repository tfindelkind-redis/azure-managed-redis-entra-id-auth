/**
 * Azure Managed Redis - User-Assigned Managed Identity Authentication (Node.js)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
 * 
 * CLUSTER POLICY SUPPORT:
 * - Enterprise Cluster: Uses standard client (server handles slot routing)
 * - OSS Cluster: Uses cluster mode with address mapping for SSL/SNI
 * 
 * Requirements:
 * - Node.js 18+
 * - @redis/client 5.0+
 * - @redis/entraid 5.0+
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

import { createClient, createCluster } from '@redis/client';
import { EntraIdCredentialsProviderFactory } from '@redis/entraid';

// Load configuration from environment
const config = {
  clientId: process.env.AZURE_CLIENT_ID,
  redisHost: process.env.REDIS_HOSTNAME,
  redisPort: parseInt(process.env.REDIS_PORT || '10000', 10),
  clusterPolicy: process.env.REDIS_CLUSTER_POLICY || 'EnterpriseCluster'
};

// Validate configuration
function validateConfig() {
  const missing = [];
  if (!config.clientId) missing.push('AZURE_CLIENT_ID');
  if (!config.redisHost) missing.push('REDIS_HOSTNAME');
  
  if (missing.length > 0) {
    console.error(`Error: Missing required environment variables: ${missing.join(', ')}`);
    console.error('\nPlease set:');
    console.error("  export AZURE_CLIENT_ID='your-managed-identity-client-id'");
    console.error("  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'");
    process.exit(1);
  }
}

async function runWithEnterpriseClient() {
  console.log('Using standard client (Enterprise Cluster policy - server handles routing)\n');

  // Create credentials provider for User-Assigned Managed Identity
  console.log('1. Creating credentials provider...');
  const provider = EntraIdCredentialsProviderFactory.createForUserAssignedManagedIdentity({
    clientId: config.clientId,
    userAssignedClientId: config.clientId,
    tokenManagerConfig: {
      expirationRefreshRatio: 0.8
    }
  });
  console.log(`   ✅ Credentials provider created for: ${config.clientId.substring(0, 8)}...\n`);

  // Create Redis client
  console.log('2. Creating Redis client...');
  const redisUrl = `rediss://${config.redisHost}:${config.redisPort}`;
  const client = createClient({
    url: redisUrl,
    credentialsProvider: provider
  });
  console.log(`   ✅ Client configured for ${redisUrl}\n`);

  // Connect
  console.log('3. Connecting to Redis...');
  await client.connect();
  console.log('   ✅ Connected!\n');

  await runDemoOperations(client);

  await client.disconnect();
}

async function runWithOSSCluster() {
  console.log('Using cluster client with address mapping (OSS Cluster policy)\n');

  // Create credentials provider for User-Assigned Managed Identity
  console.log('1. Creating credentials provider...');
  const provider = EntraIdCredentialsProviderFactory.createForUserAssignedManagedIdentity({
    clientId: config.clientId,
    userAssignedClientId: config.clientId,
    tokenManagerConfig: {
      expirationRefreshRatio: 0.8
    }
  });
  console.log(`   ✅ Credentials provider created for: ${config.clientId.substring(0, 8)}...\n`);

  // Create Redis Cluster client with address remapping
  // This is essential for OSS Cluster: cluster nodes advertise internal IPs
  // but SSL certificates only have the public hostname
  console.log('2. Creating Redis Cluster client with address mapping...');
  const client = createCluster({
    rootNodes: [{
      url: `rediss://${config.redisHost}:${config.redisPort}`
    }],
    credentialsProvider: provider,
    defaults: {
      socket: {
        tls: true,
        servername: config.redisHost
      }
    },
    // Map all cluster node addresses back to the public hostname
    nodeAddressMap: (address) => {
      // All internal IPs get remapped to the public hostname
      // The port is preserved from what the cluster reports
      return {
        host: config.redisHost,
        port: address.port
      };
    }
  });
  console.log(`   ✅ Cluster client configured for ${config.redisHost}:${config.redisPort}\n`);

  // Connect
  console.log('3. Connecting to Redis Cluster...');
  await client.connect();
  console.log('   ✅ Connected!\n');

  await runDemoOperations(client);

  await client.disconnect();
}

async function runDemoOperations(client) {
  // Test PING
  console.log('4. Testing PING...');
  const pong = await client.ping();
  console.log(`   ✅ PING response: ${pong}\n`);

  // Test SET
  console.log('5. Testing SET operation...');
  const testKey = `nodejs-usermi-test:${new Date().toISOString()}`;
  const testValue = 'Hello from Node.js with User-Assigned Managed Identity!';
  await client.set(testKey, testValue, { EX: 60 });
  console.log(`   ✅ SET '${testKey}'\n`);

  // Test GET
  console.log('6. Testing GET operation...');
  const retrieved = await client.get(testKey);
  console.log(`   ✅ GET '${testKey}' = '${retrieved}'\n`);

  // Test INCR
  console.log('7. Testing INCR operation...');
  const counterKey = 'nodejs-usermi-counter';
  const newValue = await client.incr(counterKey);
  console.log(`   ✅ INCR '${counterKey}' = ${newValue}\n`);

  // Test Hash operations
  console.log('8. Testing Hash operations...');
  const hashKey = 'nodejs-usermi-hash';
  await client.hSet(hashKey, { field1: 'value1', field2: 'value2' });
  const hashValue = await client.hGet(hashKey, 'field1');
  console.log(`   ✅ HSET/HGET '${hashKey}' field1 = '${hashValue}'\n`);

  // Cleanup
  console.log('9. Cleaning up test keys...');
  await client.del(testKey);
  await client.del(hashKey);
  console.log('   ✅ Deleted test keys\n');

  console.log('='.repeat(70));
  console.log('DEMO COMPLETE - All operations successful!');
  console.log('='.repeat(70));
}

async function main() {
  validateConfig();

  const isOSSCluster = config.clusterPolicy.toLowerCase() === 'osscluster';

  console.log('\n' + '='.repeat(70));
  console.log('AZURE MANAGED REDIS - USER-ASSIGNED MANAGED IDENTITY (NODE.JS)');
  console.log(`Cluster Policy: ${config.clusterPolicy}${isOSSCluster ? ' (cluster-aware)' : ' (standard)'}`);
  console.log('='.repeat(70) + '\n');

  try {
    if (isOSSCluster) {
      await runWithOSSCluster();
    } else {
      await runWithEnterpriseClient();
    }
  } catch (error) {
    console.error('\n❌ Error:', error.message);
    console.error(error.stack);
    process.exit(1);
  }
}

main();
