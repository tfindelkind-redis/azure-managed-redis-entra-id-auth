"""
Azure Managed Redis - System-Assigned Managed Identity Authentication Example

This example demonstrates how to connect to Azure Managed Redis using
a System-Assigned Managed Identity with Entra ID authentication.

CLUSTER POLICY SUPPORT:
- Enterprise Cluster: Uses standard Redis client (server handles slot routing)
- OSS Cluster: Uses RedisCluster with address remapping for SSL/SNI

Requirements:
- redis>=5.0.0
- redis-entraid>=1.1.0

Environment Variables:
- REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
- REDIS_PORT: Port (default: 10000)
- REDIS_CLUSTER_POLICY: "EnterpriseCluster" or "OSSCluster" (default: EnterpriseCluster)

NOTE: No AZURE_CLIENT_ID needed - Azure provides the identity automatically
when running on a resource with system-assigned managed identity enabled.

This code should be run from an Azure resource (App Service, VM, etc.)
that has system-assigned managed identity enabled.
"""

import os
import sys
import logging
from datetime import datetime

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

from redis import Redis, RedisError
from redis.cluster import RedisCluster
from redis_entraid.cred_provider import (
    create_from_managed_identity,
    ManagedIdentityType
)

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


def get_config():
    """Load configuration from environment variables."""
    config = {
        'redis_host': os.environ.get('REDIS_HOSTNAME'),
        'redis_port': int(os.environ.get('REDIS_PORT', 10000)),
        'cluster_policy': os.environ.get('REDIS_CLUSTER_POLICY', 'EnterpriseCluster'),
    }
    
    if not config['redis_host']:
        raise ValueError("REDIS_HOSTNAME environment variable is required")
    
    return config


def create_address_remap(public_hostname: str):
    """Create address remapping function for OSS Cluster SSL/SNI."""
    def remap(address):
        host, port = address
        if (host.startswith('10.') or host.startswith('172.') or host.startswith('192.168.')):
            return (public_hostname, port)
        return address
    return remap


def create_credential_provider():
    """Create Entra ID credential provider for system-assigned managed identity."""
    logger.info("Creating credential provider for system-assigned managed identity...")
    return create_from_managed_identity(
        identity_type=ManagedIdentityType.SYSTEM_ASSIGNED,
        resource="https://redis.azure.com/"
    )


def run_with_standard_client(config: dict):
    """Run with standard Redis client (Enterprise Cluster policy)."""
    credential_provider = create_credential_provider()
    
    logger.info(f"Connecting to Redis at {config['redis_host']}:{config['redis_port']}")
    
    client = Redis(
        host=config['redis_host'],
        port=config['redis_port'],
        credential_provider=credential_provider,
        ssl=True,
        decode_responses=True,
        socket_connect_timeout=10,
        socket_timeout=10
    )
    
    run_demo_operations(client, is_cluster=False)
    client.close()


def run_with_cluster_client(config: dict):
    """Run with RedisCluster client (OSS Cluster policy)."""
    credential_provider = create_credential_provider()
    address_remap = create_address_remap(config['redis_host'])
    
    logger.info(f"Creating address remapper for {config['redis_host']}")
    logger.info(f"Connecting to Redis Cluster at {config['redis_host']}:{config['redis_port']}")
    
    client = RedisCluster(
        host=config['redis_host'],
        port=config['redis_port'],
        credential_provider=credential_provider,
        ssl=True,
        decode_responses=True,
        address_remap=address_remap,
        socket_connect_timeout=10,
        socket_timeout=10
    )
    
    run_demo_operations(client, is_cluster=True)
    client.close()


def run_demo_operations(client, is_cluster: bool):
    """Run demonstration Redis operations."""
    cluster_type = "OSS Cluster" if is_cluster else "Enterprise"
    
    print("\n" + "="*70)
    print(f"AZURE MANAGED REDIS - SYSTEM-ASSIGNED MI ({cluster_type})")
    print("="*70 + "\n")
    
    # Test 1: PING
    print("1. Testing connection with PING...")
    try:
        result = client.ping()
        print(f"   ✅ PING response: {result}\n")
    except RedisError as e:
        print(f"   ❌ PING failed: {e}\n")
        return
    
    # Test 2: SET
    print("2. Testing SET operation...")
    test_key = f"python-sysmi-test:{datetime.now().isoformat()}"
    test_value = "Hello from Python with System-Assigned MI!"
    try:
        client.set(test_key, test_value, ex=60)
        print(f"   ✅ SET '{test_key}' = '{test_value}'\n")
    except RedisError as e:
        print(f"   ❌ SET failed: {e}\n")
        return
    
    # Test 3: GET
    print("3. Testing GET operation...")
    try:
        retrieved = client.get(test_key)
        print(f"   ✅ GET '{test_key}' = '{retrieved}'\n")
    except RedisError as e:
        print(f"   ❌ GET failed: {e}\n")
        return
    
    # Test 4: INCR
    print("4. Testing INCR operation...")
    counter_key = "python-sysmi-counter"
    try:
        new_value = client.incr(counter_key)
        print(f"   ✅ INCR '{counter_key}' = {new_value}\n")
    except RedisError as e:
        print(f"   ❌ INCR failed: {e}\n")
    
    # Test 5: Server info
    print("5. Getting server info...")
    try:
        info = client.info('server')
        print(f"   Redis Version: {info.get('redis_version', 'N/A')}")
        print(f"   Redis Mode: {info.get('redis_mode', 'N/A')}\n")
    except RedisError as e:
        print(f"   ❌ INFO failed: {e}\n")
    
    # Cleanup
    print("6. Cleaning up test key...")
    try:
        client.delete(test_key)
        print(f"   ✅ Deleted '{test_key}'\n")
    except RedisError as e:
        print(f"   ⚠️  Cleanup failed: {e}\n")
    
    print("="*70)
    print("DEMO COMPLETE - All operations successful!")
    print("="*70)


def main():
    try:
        config = get_config()
        is_oss_cluster = config['cluster_policy'].lower() == 'osscluster'
        
        print(f"\nCluster Policy: {config['cluster_policy']}")
        print(f"Auth Method: System-Assigned Managed Identity")
        print(f"(No Client ID required - using VM's system identity)\n")
        
        if is_oss_cluster:
            run_with_cluster_client(config)
        else:
            run_with_standard_client(config)
            
    except ValueError as e:
        logger.error(f"Configuration error: {e}")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
