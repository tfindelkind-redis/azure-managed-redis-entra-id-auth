/**
 * Azure Managed Redis - Managed Identity Authentication Example (Node.js)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using
 * a User-Assigned Managed Identity with Entra ID authentication.
 * 
 * Requirements:
 * - Node.js 18+
 * - redis (node-redis)
 * - @azure/identity
 * 
 * Environment Variables:
 * - AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
 * - REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
 * - REDIS_PORT: Port (default: 10000)
 * 
 * This code should be run from an Azure resource that has the
 * managed identity assigned.
 */

import { createClient } from 'redis';
import { ManagedIdentityCredential } from '@azure/identity';

// Load configuration from environment
const config = {
  clientId: process.env.AZURE_CLIENT_ID,
  principalId: process.env.PRINCIPAL_ID || '', // Object ID for AUTH username
  redisHost: process.env.REDIS_HOSTNAME,
  redisPort: parseInt(process.env.REDIS_PORT || '10000', 10)
};

// Redis scope for Entra ID
const REDIS_SCOPE = 'https://redis.azure.com/.default';

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

// Extract OID from JWT token for use as username
function extractOidFromToken(token) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const payload = JSON.parse(Buffer.from(parts[1], 'base64').toString());
    return payload.oid;
  } catch {
    return null;
  }
}

async function main() {
  validateConfig();

  console.log('\n' + '='.repeat(60));
  console.log('AZURE MANAGED REDIS - NODE.JS MANAGED IDENTITY AUTH DEMO');
  console.log('='.repeat(60) + '\n');

  let client;
  
  try {
    // Create managed identity credential
    console.log('1. Creating managed identity credential...');
    const credential = new ManagedIdentityCredential(config.clientId);
    console.log(`   ✅ Credential created for: ${config.clientId.substring(0, 8)}...\n`);

    // Get initial token to extract OID for username
    console.log('2. Acquiring initial token...');
    const tokenResponse = await credential.getToken(REDIS_SCOPE);
    if (!tokenResponse) {
      throw new Error('Failed to acquire token');
    }
    const oid = extractOidFromToken(tokenResponse.token);
    console.log(`   ✅ Token acquired, OID: ${oid || 'unknown'}`);
    console.log(`   Token expires: ${new Date(tokenResponse.expiresOnTimestamp).toISOString()}\n`);

    // Create Redis client with Entra ID auth
    console.log('3. Creating Redis client...');
    const redisUrl = `rediss://${config.redisHost}:${config.redisPort}`;
    
    client = createClient({
      url: redisUrl,
      username: oid || config.principalId,
      password: tokenResponse.token,
      socket: {
        tls: true,
        servername: config.redisHost
      }
    });

    // Handle errors
    client.on('error', (err) => console.error('Redis Client Error:', err));
    
    console.log(`   ✅ Client configured for ${redisUrl}\n`);

    // Connect
    console.log('4. Connecting to Redis...');
    await client.connect();
    console.log('   ✅ Connected!\n');

    // Test PING
    console.log('5. Testing PING...');
    const pong = await client.ping();
    console.log(`   ✅ PING response: ${pong}\n`);

    // Test SET
    console.log('6. Testing SET operation...');
    const testKey = `nodejs-entra-test:${new Date().toISOString()}`;
    const testValue = 'Hello from Node.js with Entra ID auth!';
    await client.set(testKey, testValue, { EX: 60 }); // Expires in 60 seconds
    console.log(`   ✅ SET '${testKey}'\n`);

    // Test GET
    console.log('7. Testing GET operation...');
    const retrieved = await client.get(testKey);
    console.log(`   ✅ GET '${testKey}' = '${retrieved}'\n`);

    // Server info
    console.log('8. Getting server info...');
    const info = await client.info('server');
    const versionMatch = info.match(/redis_version:(.+)/);
    console.log(`   Redis Version: ${versionMatch ? versionMatch[1].trim() : 'unknown'}\n`);

    // Clean up
    console.log('9. Cleaning up test key...');
    await client.del(testKey);
    console.log(`   ✅ Deleted '${testKey}'\n`);

    console.log('='.repeat(60));
    console.log('DEMO COMPLETE - All operations successful!');
    console.log('='.repeat(60) + '\n');

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    if (error.code) {
      console.error(`   Error code: ${error.code}`);
    }
    console.error('\nTroubleshooting tips:');
    console.error('1. Ensure you are running on an Azure resource with managed identity');
    console.error('2. Verify the managed identity has an access policy on the Redis cache');
    console.error('3. Check that AZURE_CLIENT_ID matches your user-assigned managed identity');
    process.exit(1);
  } finally {
    if (client) {
      await client.quit();
    }
  }
}

main();
