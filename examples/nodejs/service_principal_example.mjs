/**
 * Azure Managed Redis - Service Principal Authentication Example (Node.js)
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

import { createClient } from '@redis/client';
import { EntraIdCredentialsProviderFactory } from '@redis/entraid';

// Load configuration from environment
const config = {
  clientId: process.env.AZURE_CLIENT_ID,
  clientSecret: process.env.AZURE_CLIENT_SECRET,
  tenantId: process.env.AZURE_TENANT_ID,
  redisHost: process.env.REDIS_HOSTNAME,
  redisPort: parseInt(process.env.REDIS_PORT || '10000', 10)
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

async function main() {
  validateConfig();

  console.log('\n' + '='.repeat(60));
  console.log('AZURE MANAGED REDIS - NODE.JS SERVICE PRINCIPAL AUTH DEMO');
  console.log('='.repeat(60) + '\n');

  let client;
  
  try {
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
    client = createClient({
      url: redisUrl,
      credentialsProvider: provider
    });
    console.log(`   ✅ Client configured for ${redisUrl}\n`);

    // Connect
    console.log('3. Connecting to Redis...');
    await client.connect();
    console.log('   ✅ Connected!\n');

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
    await client.del([testKey, hashKey, listKey]);
    console.log('   ✅ Deleted test keys\n');

    console.log('='.repeat(60));
    console.log('DEMO COMPLETE - All operations successful!');
    console.log('='.repeat(60));

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    console.error(error.stack);
    process.exit(1);
  } finally {
    if (client) {
      await client.disconnect();
    }
  }
}

main();
