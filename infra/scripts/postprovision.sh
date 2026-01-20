#!/bin/bash
# Post-provision hook for azd
# Creates service principal and configures Redis access policies

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔑 Post-provision: Creating Service Principal for testing...${NC}"

# Get environment values
AZURE_ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "dev")
AZURE_SUBSCRIPTION_ID=$(azd env get-value AZURE_SUBSCRIPTION_ID 2>/dev/null)
RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "rg-${AZURE_ENV_NAME}")
REDIS_HOSTNAME=$(azd env get-value REDIS_HOSTNAME 2>/dev/null)

# Extract Redis cluster name from hostname
REDIS_CLUSTER_NAME=$(echo "$REDIS_HOSTNAME" | cut -d'.' -f1)

if [ -z "$REDIS_CLUSTER_NAME" ]; then
    echo -e "${YELLOW}⚠️  Redis hostname not available yet, skipping service principal creation${NC}"
    exit 0
fi

SP_NAME="sp-redis-${AZURE_ENV_NAME}"

# Check if service principal already exists
EXISTING_APP_ID=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")

if [ -n "$EXISTING_APP_ID" ] && [ "$EXISTING_APP_ID" != "null" ] && [ "$EXISTING_APP_ID" != "" ]; then
    echo -e "${YELLOW}ℹ️  Service principal already exists: $SP_NAME${NC}"
    SP_CLIENT_ID=$EXISTING_APP_ID
    SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$SP_CLIENT_ID'" --query "[0].id" -o tsv)
    SP_TENANT_ID=$(az account show --query "tenantId" -o tsv)
    
    # Create new secret
    echo -e "${BLUE}   Creating new client secret...${NC}"
    SP_SECRET=$(az ad app credential reset --id "$SP_CLIENT_ID" --append --years 1 --query "password" -o tsv)
else
    echo -e "${BLUE}   Creating new service principal...${NC}"
    SP_RESULT=$(az ad sp create-for-rbac --name "$SP_NAME" --years 1 --query "{appId:appId, password:password, tenant:tenant}" -o json)
    SP_CLIENT_ID=$(echo $SP_RESULT | jq -r '.appId')
    SP_SECRET=$(echo $SP_RESULT | jq -r '.password')
    SP_TENANT_ID=$(echo $SP_RESULT | jq -r '.tenant')
    SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$SP_CLIENT_ID'" --query "[0].id" -o tsv)
fi

echo -e "${GREEN}✅ Service Principal: $SP_NAME${NC}"
echo -e "   Client ID: ${GREEN}${SP_CLIENT_ID:0:8}...${NC}"
echo -e "   Object ID: ${GREEN}${SP_OBJECT_ID:0:8}...${NC}"

# Create Redis access policy for Service Principal
echo ""
echo -e "${BLUE}🔐 Creating Redis access policy for Service Principal...${NC}"
az redisenterprise database access-policy-assignment create \
    --cluster-name "$REDIS_CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --database-name "default" \
    --access-policy-assignment-name "service-principal-access" \
    --access-policy-name "default" \
    --object-id "$SP_OBJECT_ID" \
    --object-id-alias "$SP_NAME" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    --output none 2>/dev/null || echo -e "${YELLOW}   (Access policy may already exist)${NC}"
echo -e "${GREEN}✅ Service Principal access policy configured${NC}"

# Save to azd environment
echo ""
echo -e "${BLUE}💾 Saving service principal credentials to azd environment...${NC}"
azd env set SERVICE_PRINCIPAL_CLIENT_ID "$SP_CLIENT_ID"
azd env set SERVICE_PRINCIPAL_CLIENT_SECRET "$SP_SECRET"
azd env set SERVICE_PRINCIPAL_TENANT_ID "$SP_TENANT_ID"
azd env set SERVICE_PRINCIPAL_OBJECT_ID "$SP_OBJECT_ID"

echo ""
echo -e "${GREEN}✅ Post-provision completed!${NC}"
echo ""
echo -e "${BLUE}Three authentication methods are now configured:${NC}"
echo -e "  1. User-Assigned Managed Identity (AZURE_CLIENT_ID)"
echo -e "  2. System-Assigned Managed Identity (auto-detected on VM)"
echo -e "  3. Service Principal (SERVICE_PRINCIPAL_* env vars)"
