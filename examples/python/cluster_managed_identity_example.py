"""
Azure Managed Redis - OSS Cluster with Managed Identity Authentication Example

This example demonstrates how to connect to Azure Managed Redis using:
- OSS Cluster policy (cluster-aware client required)
- User-Assigned Managed Identity with Entra ID authentication
- Address remapping for SSL SNI hostname verification

WHY ADDRESS REMAPPING IS NEEDED:
================================
Azure Managed Redis with OSS Cluster policy exposes:
1. A PUBLIC endpoint (redis-xxx.azure.net:10000) - initial connection point
2. INTERNAL cluster nodes (e.g., 10.0.2.4:8500) - returned by CLUSTER SLOTS

The problem:
- CLUSTER SLOTS returns internal IPs that are not reachable from outside
- SSL certificates only contain the public hostname in their SAN
- Connecting to internal IPs would fail SSL hostname verification

The solution (address_remap):
- Maps internal IPs to the public hostname
- Preserves the port (different shards use different ports)
- Azure proxy routes to correct internal node based on port

Requirements:
- redis>=5.0.0
- redis-entraid>=1.1.0

Environment Variables:
- AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
- REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
- REDIS_PORT: Port (default: 10000)

This code should be run from an Azure resource (VM, Container App, etc.)
that has the managed identity assigned.
"""

import os
import sys
import logging
from datetime import datetime

# Try to load .env file if present
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

from redis.cluster import RedisCluster, ClusterNode
from redis_entraid.cred_provider import (
    create_from_managed_identity,
    ManagedIdentityType,
    ManagedIdentityIdType
)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def get_config():
    """Load configuration from environment variables."""
    config = {
        'client_id': os.environ.get('AZURE_CLIENT_ID'),
        'redis_host': os.environ.get('REDIS_HOSTNAME'),
        'redis_port': int(os.environ.get('REDIS_PORT', 10000)),
    }
    
    # Validate required config
    if not config['client_id']:
        raise ValueError("AZURE_CLIENT_ID environment variable is required")
    if not config['redis_host']:
        raise ValueError("REDIS_HOSTNAME environment variable is required")
    
    return config


def create_address_remap(public_hostname: str):
    """
    Create an address remapping function for Azure Managed Redis OSS Cluster.
    
    This function maps internal Azure IP addresses (10.x.x.x) to the public hostname
    while preserving the port. This is required because:
    
    1. CLUSTER SLOTS returns internal IPs (e.g., 10.0.2.4:8500)
    2. These IPs are not reachable from outside Azure's internal network
    3. SSL certificate validation requires the public hostname for SNI
    4. Azure's proxy uses the port to route to the correct internal node
    
    Args:
        public_hostname: The public hostname of the Azure Managed Redis instance
    
    Returns:
        A function that maps (host, port) tuples to the correct address
    """
    def remap(address):
        host, port = address
        # Check if this is an internal Azure IP address
        if (host.startswith('10.') or 
            host.startswith('172.16.') or 
            host.startswith('172.17.') or
            host.startswith('172.18.') or
            host.startswith('172.19.') or
            host.startswith('172.20.') or
            host.startswith('172.21.') or
            host.startswith('172.22.') or
            host.startswith('172.23.') or
            host.startswith('172.24.') or
            host.startswith('172.25.') or
            host.startswith('172.26.') or
            host.startswith('172.27.') or
            host.startswith('172.28.') or
            host.startswith('172.29.') or
            host.startswith('172.30.') or
            host.startswith('172.31.') or
            host.startswith('192.168.')):
            logger.debug(f"Remapping {host}:{port} -> {public_hostname}:{port}")
            return (public_hostname, port)
        return address
    
    return remap


def create_redis_cluster_client(config: dict) -> RedisCluster:
    """
    Create a Redis Cluster client with Entra ID authentication using managed identity.
    
    This creates a cluster-aware client that:
    - Discovers all cluster nodes
    - Handles MOVED/ASK redirects automatically
    - Remaps internal IPs to public hostname for SSL
    
    Args:
        config: Configuration dictionary with client_id, redis_host, redis_port
    
    Returns:
        RedisCluster client instance
    """
    logger.info(f"Creating credential provider for managed identity: {config['client_id'][:8]}...")
    
    # Create credential provider for user-assigned managed identity
    credential_provider = create_from_managed_identity(
        identity_type=ManagedIdentityType.USER_ASSIGNED,
        resource="https://redis.azure.com/",
        id_type=ManagedIdentityIdType.CLIENT_ID,
        id_value=config['client_id']
    )
    
    logger.info(f"Creating address remapper for {config['redis_host']}")
    
    # Create address remap function
    # This is CRITICAL for Azure Managed Redis OSS Cluster
    address_remap = create_address_remap(config['redis_host'])
    
    logger.info(f"Connecting to Redis Cluster at {config['redis_host']}:{config['redis_port']}")
    
    # Create startup node
    startup_node = ClusterNode(
        host=config['redis_host'],
        port=config['redis_port']
    )
    
    # Create Redis Cluster client with address remapping
    client = RedisCluster(
        startup_nodes=[startup_node],
        credential_provider=credential_provider,
        ssl=True,
        decode_responses=True,
        socket_connect_timeout=10,
        socket_timeout=10,
        # CRITICAL: Address remap for internal IP -> public hostname mapping
        address_remap=address_remap,
        # Skip full coverage check since Azure may not expose all slots initially
        require_full_coverage=False
    )
    
    return client


def run_demo(client: RedisCluster, config: dict):
    """Run demonstration of Redis operations using OSS Cluster client."""
    
    print("\n" + "=" * 70)
    print("AZURE MANAGED REDIS - PYTHON OSS CLUSTER WITH ENTRA ID AUTH")
    print("=" * 70 + "\n")
    
    print(f"Redis Host: {config['redis_host']}")
    print(f"Redis Port: {config['redis_port']}")
    print(f"Client ID: {config['client_id'][:8]}...")
    print()
    
    # Test PING
    print("1. Testing PING...")
    result = client.ping()
    print(f"   ✅ PING response: {result}\n")
    
    # Test SET with keys that DEFINITELY hit different shards using hash tags
    # Hash tags {xxx} ensure the slot is calculated from the tag content only
    # This is critical to test address remapping!
    print("2. Testing SET operations across MULTIPLE shards...")
    print("   Using hash tags to guarantee cross-shard distribution")
    test_keys = [
        ("{slot2}", "shard0"),   # slot 98 -> shard 0
        ("{slot3}", "shard0"),   # slot 4163 -> shard 0
        ("{slot0}", "shard1"),   # slot 8224 -> shard 1
        ("{slot1}", "shard1"),   # slot 12289 -> shard 1
    ]
    saved_keys = []
    for hash_tag, expected_shard in test_keys:
        key = f"py-cluster:{hash_tag}:{datetime.now().isoformat()}"
        value = f"Value for {hash_tag} from Python OSS Cluster!"
        client.set(key, value, ex=60)  # Expires in 60 seconds
        saved_keys.append(key)
        print(f"   ✅ SET '{key[:50]}...' -> {expected_shard}")
    print()
    
    # Test GET - this will trigger MOVED redirects if address remapping works
    print("3. Testing GET operations (validates cross-shard routing)...")
    for key in saved_keys:
        retrieved = client.get(key)
        print(f"   ✅ GET '{key[:50]}...'")
    print(f"   If you see this, address remapping is working correctly!")
    print()
    
    # Clean up references
    test_keys = saved_keys
    
    # Test INCR (counter operations)
    print("4. Testing INCR operation...")
    counter_key = "py-cluster-counter"
    new_value = client.incr(counter_key)
    print(f"   ✅ INCR '{counter_key}' = {new_value}\n")
    
    # Test cluster-specific info
    print("5. Getting cluster info...")
    try:
        cluster_info = client.cluster_info()
        state = cluster_info.get('cluster_state', 'unknown')
        slots_assigned = cluster_info.get('cluster_slots_assigned', 'unknown')
        print(f"   Cluster state: {state}")
        print(f"   Slots assigned: {slots_assigned}")
    except Exception as e:
        print(f"   ⚠️ Could not get cluster info: {e}")
    print()
    
    # Show cluster nodes (demonstrates address remapping)
    print("6. Getting cluster nodes...")
    try:
        nodes = client.cluster_nodes()
        primary_count = sum(1 for n in nodes.values() if 'master' in str(n.get('flags', '')).lower())
        replica_count = sum(1 for n in nodes.values() if 'slave' in str(n.get('flags', '')).lower())
        print(f"   Primary nodes: {primary_count}")
        print(f"   Replica nodes: {replica_count}")
    except Exception as e:
        print(f"   ⚠️ Could not get cluster nodes: {e}")
    print()
    
    # Clean up
    print("7. Cleaning up test keys...")
    for key in test_keys:
        try:
            client.delete(key)
            print(f"   ✅ Deleted '{key[:40]}...'")
        except Exception as e:
            print(f"   ⚠️ Could not delete '{key[:40]}...': {e}")
    print()
    
    print("=" * 70)
    print("DEMO COMPLETE - All OSS Cluster operations successful!")
    print("=" * 70 + "\n")


def main():
    """Main entry point."""
    try:
        config = get_config()
        
        logger.info("Starting Azure Managed Redis OSS Cluster example...")
        
        client = create_redis_cluster_client(config)
        
        # Run demo
        run_demo(client, config)
        
        # Close connection
        client.close()
        
        logger.info("Example completed successfully")
        return 0
        
    except Exception as e:
        logger.error(f"Error: {e}")
        print(f"\n❌ Error: {e}")
        print("\nTroubleshooting tips:")
        print("1. Ensure you are running on an Azure resource with managed identity")
        print("2. Verify the managed identity has an access policy on the Redis cache")
        print("3. Check that AZURE_CLIENT_ID is the Client ID (not Principal ID)")
        print("4. Ensure the Redis instance uses OSS Cluster policy")
        print("5. For OSS Cluster, internal IPs must be remapped to public hostname")
        return 1


if __name__ == "__main__":
    sys.exit(main())
