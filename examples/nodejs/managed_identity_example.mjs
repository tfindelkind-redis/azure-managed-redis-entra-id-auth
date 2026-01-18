/**
 * Azure Managed Redis - Managed Identity Authentication Example (Node.js)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
 * 
 * Requirements:
 * - Node.js 18+
 * - @redis/client
 * - @redis/entraid
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 * 
 * This code should be run from an Azure resource that has the
 * managed identity assigned.
 */

import { createClient } from '@redis/client';
import { EntraIdCredentialsProviderFactory } from '@redis/entraid';

// Load configuration from environment
const config = {
  clientId: process.env.AZURE_CLIENT_ID,
  redisHost: process.env.REDIS_HOSTNAME,
  redisPort: parseInt(process.env.REDIS_PORT || '10000', 10)
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

async function main() {
  validateConfig();

  console.log('\n' + '='.repeat(60));
  console.log('AZURE MANAGED REDIS - NODE.JS MANAGED IDENTITY AUTH DEMO');
  console.log('='.repeat(60) + '\n');

  let client;
  
  try {
    // Create credentials provider for user-assigned managed identity
    console.log('1. Creating credentials provider...');
    const provider = EntraIdCredentialsProviderFactory.createForUserAssignedManagedIdentity({
      clientId: config.clientId,
      userAssignedClientId: config.clientId,
      tokenManagerConfig: {
        expirationRefreshRatio: 0.8, // Refresh at 80% of token lifetime
        retry: {
          maxAttempts: 3,
          initialDelayMs: 100,
          maxDelayMs: 1000,
          backoffMultiplier: 2
        }
      }
    });
    console.log(`   ✅ Credentials provider created for: ${config.clientId.substring(0, 8)}...\n`);

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
    const testKey = `nodejs-entra-test:${new Date().toISOString()}`;
    const testValue = 'Hello from Node.js with Entra ID auth!';
    await client.set(testKey, testValue, { EX: 60 }); // Expires in 60 seconds
    console.log(`   ✅ SET '${testKey}'\n`);

    // Test GET
    console.log('6. Testing GET operation...');
    const retrieved = await client.get(testKey);
    console.log(`   ✅ GET '${testKey}' = '${retrieved}'\n`);

    // Test INCR
    console.log('7. Testing INCR operation...');
    const counterKey = 'nodejs-counter';
    const newValue = await client.incr(counterKey);
    console.log(`   ✅ INCR '${counterKey}' = ${newValue}\n`);

    // Test DBSIZE
    console.log('8. Getting database size...');
    const dbSize = await client.dbSize();
    console.log(`   Database contains ${dbSize} keys\n`);

    // Cleanup
    console.log('9. Cleaning up test key...');
    await client.del(testKey);
    console.log(`   ✅ Deleted '${testKey}'\n`);

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
