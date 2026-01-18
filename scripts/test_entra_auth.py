#!/usr/bin/env python3
"""
Test Azure Managed Redis Entra ID Authentication with Managed Identity

This script runs on an Azure VM with a user-assigned managed identity
that has been granted access to Azure Managed Redis via access policy.
"""

import os
import sys
import json
import ssl
import time
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# Configuration
REDIS_HOST = os.getenv("REDIS_HOST", "redis-3ae172dc9e9da.westus3.redis.azure.net")
REDIS_PORT = int(os.getenv("REDIS_PORT", "10000"))
MANAGED_IDENTITY_CLIENT_ID = os.getenv("MANAGED_IDENTITY_CLIENT_ID", "5aa192ae-5e22-4aab-8f0c-d53b26e96229")
PRINCIPAL_ID = os.getenv("PRINCIPAL_ID", "8ce652ba-f1cd-4b54-a168-cc09b6d25fed")

IMDS_ENDPOINT = "http://169.254.169.254/metadata/identity/oauth2/token"
TOKEN_SCOPE = "https://redis.azure.com"


def get_token_from_imds():
    """Get Entra ID token using Azure Instance Metadata Service (IMDS)"""
    url = f"{IMDS_ENDPOINT}?api-version=2018-02-01&resource={TOKEN_SCOPE}&client_id={MANAGED_IDENTITY_CLIENT_ID}"
    
    req = Request(url)
    req.add_header("Metadata", "true")
    
    try:
        with urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            return data["access_token"], data.get("expires_on")
    except HTTPError as e:
        print(f"HTTP Error getting token: {e.code} - {e.reason}")
        try:
            error_body = json.loads(e.read().decode())
            print(f"Error details: {json.dumps(error_body, indent=2)}")
        except:
            pass
        raise
    except URLError as e:
        print(f"URL Error getting token: {e.reason}")
        print("Are you running this on an Azure VM with managed identity?")
        raise


def test_redis_connection():
    """Test Redis connection with Entra ID authentication"""
    print("=" * 60)
    print("Azure Managed Redis Entra ID Authentication Test (Python)")
    print("=" * 60)
    print()
    print(f"Redis Host: {REDIS_HOST}")
    print(f"Redis Port: {REDIS_PORT}")
    print(f"Managed Identity Client ID: {MANAGED_IDENTITY_CLIENT_ID}")
    print(f"Principal ID (OID): {PRINCIPAL_ID}")
    print()
    
    # Step 1: Get token
    print("Step 1: Acquiring Entra ID token from IMDS...")
    try:
        token, expires_on = get_token_from_imds()
        print(f"✓ Token acquired successfully")
        print(f"  Token expires at: {time.ctime(int(expires_on)) if expires_on else 'N/A'}")
        print(f"  Token (first 50 chars): {token[:50]}...")
    except Exception as e:
        print(f"✗ Failed to get token: {e}")
        return False
    
    print()
    
    # Step 2: Test Redis connection
    print("Step 2: Testing Redis connection...")
    
    try:
        import redis
    except ImportError:
        print("Installing redis package...")
        os.system("pip3 install redis")
        import redis
    
    try:
        # Create SSL context
        ssl_context = ssl.create_default_context()
        
        # Connect with Entra ID credentials
        # Username = Principal ID (OID), Password = Access Token
        client = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            username=PRINCIPAL_ID,
            password=token,
            ssl=True,
            ssl_cert_reqs="required",
            ssl_ca_certs=None,  # Use system CA certs
            decode_responses=True
        )
        
        # Test PING
        print("Sending PING command...")
        response = client.ping()
        if response:
            print("✓ PING successful!")
        
        # Test SET/GET
        test_key = f"entra-test-{int(time.time())}"
        test_value = "Hello from Entra ID auth!"
        
        print(f"Testing SET {test_key}...")
        client.set(test_key, test_value, ex=60)  # Expire in 60 seconds
        print(f"✓ SET successful")
        
        print(f"Testing GET {test_key}...")
        result = client.get(test_key)
        if result == test_value:
            print(f"✓ GET successful: {result}")
        else:
            print(f"✗ GET returned unexpected value: {result}")
            return False
        
        # Clean up
        client.delete(test_key)
        print(f"✓ Cleaned up test key")
        
        print()
        print("=" * 60)
        print("✓ ALL TESTS PASSED - Entra ID authentication is working!")
        print("=" * 60)
        return True
        
    except redis.AuthenticationError as e:
        print(f"✗ Authentication failed: {e}")
        print()
        print("Troubleshooting tips:")
        print("1. Verify the managed identity has an access policy assignment")
        print("2. Check that the Principal ID matches the identity's object ID")
        print("3. Ensure the access policy allows the operations you're performing")
        return False
    except redis.ConnectionError as e:
        print(f"✗ Connection failed: {e}")
        print()
        print("Troubleshooting tips:")
        print("1. Check if Redis is accessible from this VM (network/firewall)")
        print("2. Verify the Redis hostname and port are correct")
        print("3. Ensure TLS is properly configured")
        return False
    except Exception as e:
        print(f"✗ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        return False


if __name__ == "__main__":
    success = test_redis_connection()
    sys.exit(0 if success else 1)
