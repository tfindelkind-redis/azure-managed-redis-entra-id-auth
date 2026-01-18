"""
Azure Managed Redis - Managed Identity Authentication Example

This example demonstrates how to connect to Azure Managed Redis using
a User-Assigned Managed Identity with Entra ID authentication.

Requirements:
- redis>=5.0.0
- redis-entraid>=1.0.0
- python-dotenv>=1.0.0 (optional, for .env file support)

Environment Variables:
- AZURE_CLIENT_ID: Client ID of the user-assigned managed identity
- REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
- REDIS_PORT: Port (default: 10000)

This code should be run from an Azure resource (App Service, VM, etc.)
that has the managed identity assigned.
"""

import os
import sys
import logging
from datetime import datetime

# Try to load .env file if present (useful for local testing with service principal)
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

from redis import Redis, RedisError
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


def create_redis_client(config: dict) -> Redis:
    """
    Create a Redis client with Entra ID authentication using managed identity.
    
    Args:
        config: Configuration dictionary with client_id, redis_host, redis_port
    
    Returns:
        Redis client instance
    """
    logger.info(f"Creating credential provider for managed identity: {config['client_id'][:8]}...")
    
    # Create credential provider for user-assigned managed identity
    credential_provider = create_from_managed_identity(
        identity_type=ManagedIdentityType.USER_ASSIGNED,
        resource="https://redis.azure.com/",
        id_type=ManagedIdentityIdType.CLIENT_ID,
        id_value=config['client_id']
    )
    
    logger.info(f"Connecting to Redis at {config['redis_host']}:{config['redis_port']}")
    
    # Create Redis client
    client = Redis(
        host=config['redis_host'],
        port=config['redis_port'],
        credential_provider=credential_provider,
        ssl=True,
        decode_responses=True,
        socket_connect_timeout=10,
        socket_timeout=10
    )
    
    return client


def test_connection(client: Redis) -> bool:
    """Test the Redis connection with a ping."""
    try:
        result = client.ping()
        logger.info(f"PING response: {result}")
        return result
    except RedisError as e:
        logger.error(f"PING failed: {e}")
        return False


def run_demo_operations(client: Redis):
    """Run demonstration Redis operations."""
    print("\n" + "="*60)
    print("AZURE MANAGED REDIS - ENTRA ID AUTHENTICATION DEMO")
    print("="*60 + "\n")
    
    # Test 1: Basic PING
    print("1. Testing connection with PING...")
    if test_connection(client):
        print("   ✅ Connection successful!\n")
    else:
        print("   ❌ Connection failed!\n")
        return
    
    # Test 2: SET operation
    print("2. Testing SET operation...")
    test_key = f"entra-auth-test:{datetime.now().isoformat()}"
    test_value = "Hello from Entra ID authenticated client!"
    try:
        client.set(test_key, test_value, ex=60)  # Expires in 60 seconds
        print(f"   ✅ SET '{test_key}' = '{test_value}'\n")
    except RedisError as e:
        print(f"   ❌ SET failed: {e}\n")
        return
    
    # Test 3: GET operation
    print("3. Testing GET operation...")
    try:
        retrieved = client.get(test_key)
        print(f"   ✅ GET '{test_key}' = '{retrieved}'\n")
    except RedisError as e:
        print(f"   ❌ GET failed: {e}\n")
        return
    
    # Test 4: INFO command
    print("4. Getting server info...")
    try:
        info = client.info('server')
        print(f"   Redis Version: {info.get('redis_version', 'N/A')}")
        print(f"   Redis Mode: {info.get('redis_mode', 'N/A')}\n")
    except RedisError as e:
        print(f"   ❌ INFO failed: {e}\n")
    
    # Test 5: Delete test key
    print("5. Cleaning up test key...")
    try:
        client.delete(test_key)
        print(f"   ✅ Deleted '{test_key}'\n")
    except RedisError as e:
        print(f"   ❌ DELETE failed: {e}\n")
    
    print("="*60)
    print("DEMO COMPLETE - All operations successful!")
    print("="*60)


def main():
    """Main entry point."""
    try:
        # Load configuration
        config = get_config()
        
        # Create Redis client
        client = create_redis_client(config)
        
        # Run demo operations
        run_demo_operations(client)
        
        # Close connection
        client.close()
        
    except ValueError as e:
        logger.error(f"Configuration error: {e}")
        sys.exit(1)
    except RedisError as e:
        logger.error(f"Redis error: {e}")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
