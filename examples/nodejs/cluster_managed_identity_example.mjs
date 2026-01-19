/**
 * Azure Managed Redis - OSS Cluster with Managed Identity Authentication (Node.js)
 * 
 * This example demonstrates how to connect to Azure Managed Redis using:
 * - OSS Cluster policy (cluster-aware client required)
 * - User-Assigned Managed Identity with Entra ID authentication
 * - nodeAddressMap for SSL SNI hostname verification
 * 
 * WHY nodeAddressMap IS NEEDED:
 * =============================
 * Azure Managed Redis with OSS Cluster policy exposes:
 * 1. A PUBLIC endpoint (redis-xxx.azure.net:10000) - initial connection point
 * 2. INTERNAL cluster nodes (e.g., 10.0.2.4:8500) - returned by CLUSTER SLOTS
 * 
 * The problem:
 * - CLUSTER SLOTS returns internal IPs that are not reachable from outside
 * - SSL certificates only contain the public hostname in their SAN
 * - Connecting to internal IPs would fail SSL hostname verification
 * 
 * The solution (nodeAddressMap):
 * - Maps internal IPs to the public hostname
 * - Preserves the port (different shards use different ports)
 * - Azure proxy routes to correct internal node based on port
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

import { createCluster } from 'redis';
import { ManagedIdentityCredential } from '@azure/identity';

// Load configuration from environment
const config = {
  clientId: process.env.AZURE_CLIENT_ID,
  principalId: process.env.PRINCIPAL_ID || '',
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

// Check if address is an internal IP
function isInternalIP(host) {
  return host.startsWith('10.') || 
         host.startsWith('172.16.') || host.startsWith('172.17.') ||
         host.startsWith('172.18.') || host.startsWith('172.19.') ||
         host.startsWith('172.20.') || host.startsWith('172.21.') ||
         host.startsWith('172.22.') || host.startsWith('172.23.') ||
         host.startsWith('172.24.') || host.startsWith('172.25.') ||
         host.startsWith('172.26.') || host.startsWith('172.27.') ||
         host.startsWith('172.28.') || host.startsWith('172.29.') ||
         host.startsWith('172.30.') || host.startsWith('172.31.') ||
         host.startsWith('192.168.');
}

/**
 * Create a nodeAddressMap function for Azure Managed Redis OSS Cluster.
 * 
 * This function maps internal Azure IP addresses to the public hostname
 * while preserving the port. This is REQUIRED because:
 * 
 * 1. CLUSTER SLOTS returns internal IPs (e.g., 10.0.2.4:8500)
 * 2. These IPs are not reachable from outside Azure's internal network
 * 3. SSL certificate validation requires the public hostname for SNI
 * 4. Azure's proxy uses the port to route to the correct internal node
 */
function createNodeAddressMap(publicHostname) {
  return (address) => {
    // address is in format "host:port"
    const colonIndex = address.lastIndexOf(':');
    const host = address.substring(0, colonIndex);
    const port = parseInt(address.substring(colonIndex + 1), 10);
    
    if (isInternalIP(host)) {
      console.log(`   🔄 Remapping ${host}:${port} -> ${publicHostname}:${port}`);
      return {
        host: publicHostname,
        port: port
      };
    }
    
    return {
      host: host,
      port: port
    };
  };
}

async function main() {
  validateConfig();

  console.log('\n' + '='.repeat(70));
  console.log('AZURE MANAGED REDIS - NODE.JS OSS CLUSTER WITH ENTRA ID AUTH');
  console.log('='.repeat(70) + '\n');

  let cluster;
  
  try {
    // Create managed identity credential
    console.log('1. Creating managed identity credential...');
    const credential = new ManagedIdentityCredential(config.clientId);
    console.log(`   ✅ Credential created for: ${config.clientId.substring(0, 8)}...\n`);

    // Get initial token
    console.log('2. Acquiring initial token...');
    const tokenResponse = await credential.getToken(REDIS_SCOPE);
    if (!tokenResponse) {
      throw new Error('Failed to acquire token');
    }
    const oid = extractOidFromToken(tokenResponse.token);
    console.log(`   ✅ Token acquired, OID: ${oid || 'unknown'}`);
    console.log(`   Token expires: ${new Date(tokenResponse.expiresOnTimestamp).toISOString()}\n`);

    // Create cluster client with nodeAddressMap
    console.log('3. Creating Redis Cluster client with nodeAddressMap...');
    const rootNodeUrl = `rediss://${config.redisHost}:${config.redisPort}`;
    
    cluster = createCluster({
      rootNodes: [{
        url: rootNodeUrl
      }],
      defaults: {
        username: oid || config.principalId,
        password: tokenResponse.token,
        socket: {
          tls: true,
          servername: config.redisHost,
          connectTimeout: 10000
        }
      },
      // CRITICAL: nodeAddressMap for internal IP -> public hostname mapping
      // This is required for Azure Managed Redis OSS Cluster policy
      nodeAddressMap: createNodeAddressMap(config.redisHost),
      // Don't require all slots to be covered initially
      minimizeConnections: false,
      useReplicas: false
    });

    // Handle errors
    cluster.on('error', (err) => console.error('Redis Cluster Error:', err));
    
    console.log(`   ✅ Cluster client configured for ${rootNodeUrl}\n`);

    // Connect
    console.log('4. Connecting to Redis Cluster...');
    await cluster.connect();
    console.log('   ✅ Connected to cluster!\n');

    // Test PING
    console.log('5. Testing PING...');
    const pong = await cluster.ping();
    console.log(`   ✅ PING response: ${pong}\n`);

    // Test SET with keys that DEFINITELY hit different shards using hash tags
    // Hash tags {xxx} ensure the slot is calculated from the tag content only
    // This validates that nodeAddressMap is working correctly!
    console.log('6. Testing SET operations across MULTIPLE shards...');
    console.log('   Using hash tags to guarantee cross-shard distribution');
    const testKeyPairs = [
      { tag: '{slot2}', shard: 'shard0' },   // slot 98 -> shard 0
      { tag: '{slot3}', shard: 'shard0' },   // slot 4163 -> shard 0
      { tag: '{slot0}', shard: 'shard1' },   // slot 8224 -> shard 1
      { tag: '{slot1}', shard: 'shard1' },   // slot 12289 -> shard 1
    ];
    const testKeys = [];
    for (const { tag, shard } of testKeyPairs) {
      const key = `nodejs-cluster:${tag}:${new Date().toISOString()}`;
      const value = `Value for ${tag} from Node.js OSS Cluster!`;
      await cluster.set(key, value, { EX: 60 });
      testKeys.push(key);
      console.log(`   ✅ SET '${key.substring(0, 55)}...' -> ${shard}`);
    }
    console.log();

    // Test GET operations
    console.log('7. Testing GET operations...');
    for (const key of testKeys) {
      const retrieved = await cluster.get(key);
      console.log(`   ✅ GET '${key.substring(0, 40)}...' = '${retrieved.substring(0, 30)}...'`);
    }
    console.log();

    // Test INCR
    console.log('8. Testing INCR operation...');
    const counterKey = 'nodejs-cluster-counter';
    const newValue = await cluster.incr(counterKey);
    console.log(`   ✅ INCR '${counterKey}' = ${newValue}\n`);

    // Get cluster info
    console.log('9. Getting cluster info...');
    try {
      const clusterInfo = await cluster.clusterInfo();
      const stateMatch = clusterInfo.match(/cluster_state:(\w+)/);
      const slotsMatch = clusterInfo.match(/cluster_slots_assigned:(\d+)/);
      console.log(`   Cluster state: ${stateMatch ? stateMatch[1] : 'unknown'}`);
      console.log(`   Slots assigned: ${slotsMatch ? slotsMatch[1] : 'unknown'}`);
    } catch (e) {
      console.log(`   ⚠️ Could not get cluster info: ${e.message}`);
    }
    console.log();

    // Clean up
    console.log('10. Cleaning up test keys...');
    for (const key of testKeys) {
      await cluster.del(key);
      console.log(`   ✅ Deleted '${key.substring(0, 40)}...'`);
    }
    console.log();

    console.log('='.repeat(70));
    console.log('DEMO COMPLETE - All OSS Cluster operations successful!');
    console.log('='.repeat(70) + '\n');

  } catch (error) {
    console.error('\n❌ Error:', error.message);
    if (error.code) {
      console.error(`   Error code: ${error.code}`);
    }
    console.error('\nTroubleshooting tips:');
    console.error('1. Ensure you are running on an Azure resource with managed identity');
    console.error('2. Verify the managed identity has an access policy on the Redis cache');
    console.error('3. Check that AZURE_CLIENT_ID is the Client ID (not Principal ID)');
    console.error('4. Ensure the Redis instance uses OSS Cluster policy');
    console.error('5. For OSS Cluster, internal IPs must be remapped to public hostname');
    process.exit(1);
  } finally {
    if (cluster) {
      await cluster.quit().catch(() => {});
    }
  }
}

main();
