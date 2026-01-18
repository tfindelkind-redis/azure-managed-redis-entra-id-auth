"""
Azure Managed Redis - Service Principal Authentication Example

This example demonstrates how to connect to Azure Managed Redis using
a Service Principal with Entra ID authentication.

This is useful for:
- Local development
- CI/CD pipelines
- Non-Azure environments

Requirements:
- redis>=5.0.0
- redis-entraid>=1.0.0
- python-dotenv>=1.0.0 (optional, for .env file support)

Environment Variables:
- AZURE_CLIENT_ID: Application (client) ID of the service principal
- AZURE_CLIENT_SECRET: Client secret of the service principal
- AZURE_TENANT_ID: Directory (tenant) ID
- REDIS_HOSTNAME: Hostname of your Azure Managed Redis instance
- REDIS_PORT: Port (default: 10000)

Before running:
1. Create a service principal in Azure AD
2. Create an access policy assignment for the service principal's Object ID
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

from redis import Redis, RedisError
from redis_entraid.cred_provider import create_from_service_principal

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
        'client_secret': os.environ.get('AZURE_CLIENT_SECRET'),
        'tenant_id': os.environ.get('AZURE_TENANT_ID'),
        'redis_host': os.environ.get('REDIS_HOSTNAME'),
        'redis_port': int(os.environ.get('REDIS_PORT', 10000)),
    }
    
    # Validate required config
    missing = []
    if not config['client_id']:
        missing.append('AZURE_CLIENT_ID')
    if not config['client_secret']:
        missing.append('AZURE_CLIENT_SECRET')
    if not config['tenant_id']:
        missing.append('AZURE_TENANT_ID')
    if not config['redis_host']:
        missing.append('REDIS_HOSTNAME')
    
    if missing:
        raise ValueError(f"Missing required environment variables: {', '.join(missing)}")
    
    return config


def create_redis_client(config: dict) -> Redis:
    """
    Create a Redis client with Entra ID authentication using service principal.
    
    Args:
        config: Configuration dictionary with credentials and Redis connection info
    
    Returns:
        Redis client instance
    """
    logger.info(f"Creating credential provider for service principal: {config['client_id'][:8]}...")
    
    # Create credential provider for service principal
    credential_provider = create_from_service_principal(
        client_id=config['client_id'],
        client_secret=config['client_secret'],
        tenant_id=config['tenant_id']
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
    print("AZURE MANAGED REDIS - SERVICE PRINCIPAL AUTH DEMO")
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
    test_key = f"sp-auth-test:{datetime.now().isoformat()}"
    test_value = "Hello from Service Principal authenticated client!"
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
    
    # Test 4: INCR operation
    print("4. Testing INCR operation...")
    counter_key = "sp-auth-counter"
    try:
        new_value = client.incr(counter_key)
        print(f"   ✅ INCR '{counter_key}' = {new_value}\n")
    except RedisError as e:
        print(f"   ❌ INCR failed: {e}\n")
    
    # Test 5: DBSIZE
    print("5. Getting database size...")
    try:
        size = client.dbsize()
        print(f"   Database contains {size} keys\n")
    except RedisError as e:
        print(f"   ❌ DBSIZE failed: {e}\n")
    
    # Cleanup
    print("6. Cleaning up test key...")
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
        print("\nPlease set the required environment variables:")
        print("  export AZURE_CLIENT_ID='your-client-id'")
        print("  export AZURE_CLIENT_SECRET='your-client-secret'")
        print("  export AZURE_TENANT_ID='your-tenant-id'")
        print("  export REDIS_HOSTNAME='your-redis.region.redis.azure.net'")
        sys.exit(1)
    except RedisError as e:
        logger.error(f"Redis error: {e}")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
