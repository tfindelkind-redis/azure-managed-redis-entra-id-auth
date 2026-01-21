/**
 * Azure Managed Redis - System-Assigned Managed Identity Authentication (Node.js)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a System-Assigned Managed Identity with Entra ID authentication.
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
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 * - REDIS_CLUSTER_POLICY: "EnterpriseCluster" or "OSSCluster" (default: EnterpriseCluster)
 * 
 * Note: System-Assigned Managed Identity doesn't require AZURE_CLIENT_ID
 * The identity is automatically associated with the Azure resource.
 * 
 * This code should be run from an Azure resource that has a
 * system-assigned managed identity enabled.
 */

import { createClient, createCluster } from '@redis/client';
import { EntraIdCredentialsProviderFactory } from '@redis/entraid';

// Load configuration from environment
const config = {
  redisHost: process.env.REDIS_HOSTNAME,
  redisPort: parseInt(process.env.REDIS_PORT || '10000', 10),
  clusterPolicy: process.env.REDIS_CLUSTER_POLICY || 'EnterpriseCluster'
};

// Validate configuration
function validateConfig() {
  const missing = [];
  if (!config.redisHost) missing.push('REDIS_HOSTNAME');
  
  if (missing.length > 0) {
    console.error(`Error: Missing required environment variables: ${missing.join(', ')}`);
    console.error('\nPlease set:');
    console.error("  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'");
    process.exit(1);
  }
}

async function runWithEnterpriseClient() {
  console.log('Using standard client (Enterprise Cluster policy - server handles routing)\n');

  // Create credentials provider for System-Assigned Managed Identity
  console.log('1. Creating credentials provider...');
  const provider = EntraIdCredentialsProviderFactory.createForSystemAssignedManagedIdentity({
    tokenManagerConfig: {
      expirationRefreshRatio: 0.8
    }
  });
  console.log('   ✅ Credentials provider created for System-Assigned MI\n');

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

  // Create credentials provider for System-Assigned Managed Identity
  console.log('1. Creating credentials provider...');
  const provider = EntraIdCredentialsProviderFactory.createForSystemAssignedManagedIdentity({
    tokenManagerConfig: {
      expirationRefreshRatio: 0.8
    }
  });
  console.log('   ✅ Credentials provider created for System-Assigned MI\n');

  // Create Redis Cluster client with address remapping
  console.log('2. Creating Redis Cluster client with address mapping...');
  const client = createCluster({
    rootNodes: [{
      socket: {
        host: config.redisHost,
        port: config.redisPort,
        tls: true,
        servername: config.redisHost,
        connectTimeout: 30000,
        reconnectStrategy: false
      }
    }],
    // IMPORTANT: credentialsProvider must be inside defaults for cluster client
    defaults: {
      credentialsProvider: provider,
      socket: {
        tls: true,
        servername: config.redisHost,
        connectTimeout: 30000
      }
    },
    // Map all cluster node addresses back to the public hostname
    // nodeAddressMap receives an address string like "10.0.0.1:6379"
    nodeAddressMap: (address) => {
      // address is a string in format "host:port"
      const colonIndex = address.lastIndexOf(':');
      const originalHost = address.substring(0, colonIndex);
      const port = parseInt(address.substring(colonIndex + 1), 10);
      
      console.log(`   🔄 Mapping ${originalHost}:${port} -> ${config.redisHost}:${port}`);
      return {
        host: config.redisHost,
        port: port
      };
    }
  });

  // Add error handler for debugging
  client.on('error', (err) => {
    console.error('   ❌ Cluster client error:', err.message);
  });

  console.log(`   ✅ Cluster client configured for ${config.redisHost}:${config.redisPort}\n`);

  // Connect with timeout
  console.log('3. Connecting to Redis Cluster...');
  const connectTimeout = setTimeout(() => {
    console.error('   ⏱️ Connection timeout after 60 seconds');
    process.exit(1);
  }, 60000);

  try {
    await client.connect();
    clearTimeout(connectTimeout);
    console.log('   ✅ Connected!\n');
  } catch (connectError) {
    clearTimeout(connectTimeout);
    console.error('   ❌ Connection failed:', connectError.message);
    throw connectError;
  }

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
  const testKey = `nodejs-sysmi-test:${new Date().toISOString()}`;
  const testValue = 'Hello from Node.js with System-Assigned Managed Identity!';
  await client.set(testKey, testValue, { EX: 60 });
  console.log(`   ✅ SET '${testKey}'\n`);

  // Test GET
  console.log('6. Testing GET operation...');
  const retrieved = await client.get(testKey);
  console.log(`   ✅ GET '${testKey}' = '${retrieved}'\n`);

  // Test INCR
  console.log('7. Testing INCR operation...');
  const counterKey = 'nodejs-sysmi-counter';
  const newValue = await client.incr(counterKey);
  console.log(`   ✅ INCR '${counterKey}' = ${newValue}\n`);

  // Test Hash operations
  console.log('8. Testing Hash operations...');
  const hashKey = 'nodejs-sysmi-hash';
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
  console.log('AZURE MANAGED REDIS - SYSTEM-ASSIGNED MANAGED IDENTITY (NODE.JS)');
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
