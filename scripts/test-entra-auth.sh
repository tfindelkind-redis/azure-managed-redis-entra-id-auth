#!/bin/bash
# Test script for Azure Managed Redis Entra ID Authentication
# This script runs on the debug VM with managed identity

set -e

# Configuration
REDIS_HOST="redis-3ae172dc9e9da.westus3.redis.azure.net"
REDIS_PORT="10000"
MANAGED_IDENTITY_CLIENT_ID="5aa192ae-5e22-4aab-8f0c-d53b26e96229"
PRINCIPAL_ID="8ce652ba-f1cd-4b54-a168-cc09b6d25fed"
TOKEN_SCOPE="https://redis.azure.com/.default"

echo "============================================"
echo "Azure Managed Redis Entra ID Authentication Test"
echo "============================================"
echo ""
echo "Redis Host: $REDIS_HOST"
echo "Redis Port: $REDIS_PORT"
echo "Managed Identity Client ID: $MANAGED_IDENTITY_CLIENT_ID"
echo "Principal ID (OID): $PRINCIPAL_ID"
echo ""

# Step 1: Get Entra ID token using Managed Identity
echo "Step 1: Acquiring Entra ID token..."
TOKEN_RESPONSE=$(curl -s "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://redis.azure.com&client_id=$MANAGED_IDENTITY_CLIENT_ID" -H "Metadata: true")

if echo "$TOKEN_RESPONSE" | grep -q "error"; then
    echo "ERROR: Failed to get token"
    echo "$TOKEN_RESPONSE" | jq '.'
    exit 1
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
EXPIRES_ON=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_on')
EXPIRES_DATE=$(date -d @$EXPIRES_ON 2>/dev/null || date -r $EXPIRES_ON 2>/dev/null || echo "N/A")

echo "✓ Token acquired successfully"
echo "  Token expires at: $EXPIRES_DATE"
echo "  Token (first 50 chars): ${ACCESS_TOKEN:0:50}..."
echo ""

# Step 2: Test Redis connection with Entra ID token
echo "Step 2: Testing Redis connection..."
echo ""

# Using redis-cli with AUTH command
# Note: Enterprise cluster uses different endpoint format
# AUTH username password - where username is the principal ID and password is the token

echo "Connecting to Redis with Entra ID auth..."

# Test with openssl s_client to verify TLS connection works
echo "Testing TLS connection..."
echo "QUIT" | openssl s_client -connect "$REDIS_HOST:$REDIS_PORT" -servername "$REDIS_HOST" 2>/dev/null | head -20

# For actual Redis test, we need redis-cli or a programmatic client
# Let's check if redis-cli is available
if command -v redis-cli &> /dev/null; then
    echo ""
    echo "Testing Redis AUTH with redis-cli..."
    # Note: redis-cli AUTH with username requires version 6+
    echo "AUTH $PRINCIPAL_ID $ACCESS_TOKEN" | redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --tls --sni "$REDIS_HOST" --no-auth-warning 2>&1 || true
else
    echo ""
    echo "redis-cli not found, will test with Python..."
fi

echo ""
echo "============================================"
echo "Test completed - Check output above for results"
echo "============================================"
