/**
 * Azure Managed Redis - Service Principal Authentication Example (Node.js)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a Service Principal with Entra ID authentication.
 * 
 * CLUSTER POLICY SUPPORT:
 * - Enterprise Cluster: Uses standard client (server handles slot routing)
 * - OSS Cluster: Uses cluster mode with address mapping for SSL/SNI
 * 
 * This is useful for:
 * - Local development
 * - CI/CD pipelines
 * - Non-Azure environments
 * 
 * Requirements:
 * - Node.js 18+
 * - @redis/client 5.0+
 * - @redis/entraid 1.1+
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Application (client) ID of the service principal
 * - AZURE_CLIENT_SECRET: Client secret of the service principal
 * - AZURE_TENANT_ID: Directory (tenant) ID
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 * - REDIS_CLUSTER_POLICY: "EnterpriseCluster" or "OSSCluster" (default: EnterpriseCluster)
 */

import { createClient, createCluster } from '@redis/client';
import { EntraIdCredentialsProviderFactory } from '@redis/entraid';

// Load configuration from environment
const config = {
  clientId: process.env.AZURE_CLIENT_ID,
  clientSecret: process.env.AZURE_CLIENT_SECRET,
  tenantId: process.env.AZURE_TENANT_ID,
  redisHost: process.env.REDIS_HOSTNAME,
  redisPort: parseInt(process.env.REDIS_PORT || '10000', 10),
  clusterPolicy: process.env.REDIS_CLUSTER_POLICY || 'EnterpriseCluster'
};

// Validate configuration
function validateConfig() {
  const missing = [];
  if (!config.clientId) missing.push('AZURE_CLIENT_ID');
  if (!config.clientSecret) missing.push('AZURE_CLIENT_SECRET');
  if (!config.tenantId) missing.push('AZURE_TENANT_ID');
  if (!config.redisHost) missing.push('REDIS_HOSTNAME');
  
  if (missing.length > 0) {
    console.error(`Error: Missing required environment variables: ${missing.join(', ')}`);
    console.error('\nPlease set:');
    console.error("  export AZURE_CLIENT_ID='your-client-id'");
    console.error("  export AZURE_CLIENT_SECRET='your-client-secret'");
    console.error("  export AZURE_TENANT_ID='your-tenant-id'");
    console.error("  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'");
    process.exit(1);
  }
}

async function runWithEnterpriseClient() {
  console.log('Using standard client (Enterprise Cluster policy - server handles routing)\n');

  // Create credentials provider for service principal
  console.log('1. Creating credentials provider...');
  const provider = EntraIdCredentialsProviderFactory.createForClientCredentials({
    clientId: config.clientId,
    clientSecret: config.clientSecret,
    authorityConfig: {
      type: 'multi-tenant',
      tenantId: config.tenantId
    },
    tokenManagerConfig: {
      expirationRefreshRatio: 0.8,
      retry: {
        maxAttempts: 3,
        initialDelayMs: 100,
        maxDelayMs: 1000,
        backoffMultiplier: 2
      }
    }
  });
  console.log(`   ✅ Credentials provider created for SP: ${config.clientId.substring(0, 8)}...\n`);

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

  // Create credentials provider for service principal
  console.log('1. Creating credentials provider...');
  const provider = EntraIdCredentialsProviderFactory.createForClientCredentials({
    clientId: config.clientId,
    clientSecret: config.clientSecret,
    authorityConfig: {
      type: 'multi-tenant',
      tenantId: config.tenantId
    },
    tokenManagerConfig: {
      expirationRefreshRatio: 0.8,
      retry: {
        maxAttempts: 3,
        initialDelayMs: 100,
        maxDelayMs: 1000,
        backoffMultiplier: 2
      }
    }
  });
  console.log(`   ✅ Credentials provider created for SP: ${config.clientId.substring(0, 8)}...\n`);

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
  const testKey = `nodejs-sp-test:${new Date().toISOString()}`;
  const testValue = 'Hello from Node.js with Service Principal auth!';
  await client.set(testKey, testValue, { EX: 60 });
  console.log(`   ✅ SET '${testKey}'\n`);

  // Test GET
  console.log('6. Testing GET operation...');
  const retrieved = await client.get(testKey);
  console.log(`   ✅ GET '${testKey}' = '${retrieved}'\n`);

  // Test Hash operations
  console.log('7. Testing Hash operations...');
  const hashKey = 'nodejs-sp-hash';
  await client.hSet(hashKey, { field1: 'value1', field2: 'value2' });
  const hashValue = await client.hGet(hashKey, 'field1');
  console.log(`   ✅ HSET/HGET '${hashKey}' field1 = '${hashValue}'\n`);

  // Test List operations
  console.log('8. Testing List operations...');
  const listKey = 'nodejs-sp-list';
  await client.rPush(listKey, ['item1', 'item2', 'item3']);
  const listLength = await client.lLen(listKey);
  console.log(`   ✅ RPUSH/LLEN '${listKey}' length = ${listLength}\n`);

  // Test DBSIZE
  console.log('9. Getting database size...');
  const dbSize = await client.dbSize();
  console.log(`   Database contains ${dbSize} keys\n`);

  // Cleanup
  console.log('10. Cleaning up test keys...');
  await client.del(testKey);
  await client.del(hashKey);
  await client.del(listKey);
  console.log('   ✅ Deleted test keys\n');

  console.log('='.repeat(70));
  console.log('DEMO COMPLETE - All operations successful!');
  console.log('='.repeat(70));
}

async function main() {
  validateConfig();

  const isOSSCluster = config.clusterPolicy.toLowerCase() === 'osscluster';

  console.log('\n' + '='.repeat(70));
  console.log('AZURE MANAGED REDIS - SERVICE PRINCIPAL (NODE.JS)');
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
