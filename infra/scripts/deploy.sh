#!/bin/bash
set -e

# Azure Managed Redis Entra ID Auth - Deployment Script
# This script deploys all infrastructure in the correct order
# Supports both OSS Cluster and Enterprise Cluster policies

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(dirname "$INFRA_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Use azd environment if available, otherwise use defaults
if command -v azd &> /dev/null && azd env list &> /dev/null 2>&1; then
    echo -e "${BLUE}ℹ️  Using azd environment${NC}"
    AZURE_ENV_NAME=$(azd env get-value AZURE_ENV_NAME 2>/dev/null || echo "dev")
    AZURE_LOCATION=$(azd env get-value AZURE_LOCATION 2>/dev/null || echo "westus3")
    AZURE_SUBSCRIPTION_ID=$(azd env get-value AZURE_SUBSCRIPTION_ID 2>/dev/null || az account show --query id -o tsv)
    REDIS_CLUSTER_POLICY=$(azd env get-value REDIS_CLUSTER_POLICY 2>/dev/null || echo "EnterpriseCluster")
    REDIS_SKU=$(azd env get-value REDIS_SKU 2>/dev/null || echo "Balanced_B5")
    VM_ADMIN_PASSWORD=$(azd env get-value VM_ADMIN_PASSWORD 2>/dev/null || echo "")
else
    echo -e "${YELLOW}ℹ️  azd not configured, using environment variables or defaults${NC}"
    AZURE_ENV_NAME="${AZURE_ENV_NAME:-dev}"
    AZURE_LOCATION="${AZURE_LOCATION:-westus3}"
    AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
    REDIS_CLUSTER_POLICY="${REDIS_CLUSTER_POLICY:-EnterpriseCluster}"
    REDIS_SKU="${REDIS_SKU:-Balanced_B5}"
    VM_ADMIN_PASSWORD="${VM_ADMIN_PASSWORD:-}"
fi

RESOURCE_GROUP="rg-${AZURE_ENV_NAME}"
LOCATION="$AZURE_LOCATION"

# Generate password if not set
if [ -z "$VM_ADMIN_PASSWORD" ]; then
    VM_ADMIN_PASSWORD=$(openssl rand -base64 16)
    echo -e "${YELLOW}⚠️  Generated random VM password (save this): $VM_ADMIN_PASSWORD${NC}"
    if command -v azd &> /dev/null; then
        azd env set VM_ADMIN_PASSWORD "$VM_ADMIN_PASSWORD" 2>/dev/null || true
    fi
fi

echo ""
echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}Azure Managed Redis - Entra ID Auth Test Environment${NC}"
echo -e "${BLUE}==========================================${NC}"
echo -e "Resource Group:     ${GREEN}$RESOURCE_GROUP${NC}"
echo -e "Location:           ${GREEN}$LOCATION${NC}"
echo -e "Environment:        ${GREEN}$AZURE_ENV_NAME${NC}"
echo -e "Redis Cluster Policy: ${GREEN}$REDIS_CLUSTER_POLICY${NC}"
echo -e "Redis SKU:          ${GREEN}$REDIS_SKU${NC}"
echo -e "Subscription:       ${GREEN}$AZURE_SUBSCRIPTION_ID${NC}"
echo ""

# Function to check deployment status
check_deployment() {
    local name=$1
    local rg=$2
    az deployment group show -g "$rg" -n "$name" --query "properties.provisioningState" -o tsv 2>/dev/null || echo "NotFound"
}

# Function to wait for deployment
wait_for_deployment() {
    local name=$1
    local rg=$2
    local timeout=${3:-1800}  # Default 30 minutes
    local elapsed=0
    
    echo -e "${YELLOW}⏳ Waiting for deployment '$name' to complete (timeout: ${timeout}s)...${NC}"
    while [ $elapsed -lt $timeout ]; do
        state=$(check_deployment "$name" "$rg")
        if [ "$state" == "Succeeded" ]; then
            echo -e "${GREEN}✅ Deployment '$name' succeeded${NC}"
            return 0
        elif [ "$state" == "Failed" ] || [ "$state" == "Canceled" ]; then
            echo -e "${RED}❌ Deployment '$name' failed with state: $state${NC}"
            az deployment group show -g "$rg" -n "$name" --query "properties.error" -o json 2>/dev/null || true
            return 1
        fi
        sleep 15
        elapsed=$((elapsed + 15))
        echo -n "."
    done
    echo ""
    echo -e "${RED}⏱️  Deployment '$name' timed out after ${timeout}s${NC}"
    return 1
}

# Check prerequisites
echo -e "${BLUE}🔍 Checking prerequisites...${NC}"
if ! command -v az &> /dev/null; then
    echo -e "${RED}❌ Azure CLI not found. Please install: https://docs.microsoft.com/cli/azure/install-azure-cli${NC}"
    exit 1
fi

if ! az account show &> /dev/null; then
    echo -e "${RED}❌ Not logged in to Azure. Run: az login${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites OK${NC}"
echo ""

# Create resource group
echo -e "${BLUE}📦 Creating resource group...${NC}"
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    --tags environment="$AZURE_ENV_NAME" project="redis-entra-id-auth" clusterPolicy="$REDIS_CLUSTER_POLICY" \
    --output none

echo -e "${GREEN}✅ Resource group created: $RESOURCE_GROUP${NC}"
echo ""

# Deploy infrastructure using Bicep
DEPLOYMENT_NAME="redis-entra-id-$(date +%Y%m%d-%H%M%S)"
echo -e "${BLUE}🚀 Deploying infrastructure (this may take 15-20 minutes for Redis)...${NC}"
echo -e "   Deployment name: $DEPLOYMENT_NAME"
echo ""

az deployment sub create \
    --name "$DEPLOYMENT_NAME" \
    --location "$LOCATION" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    --template-file "$INFRA_DIR/main.bicep" \
    --parameters environmentName="$AZURE_ENV_NAME" \
                 location="$LOCATION" \
                 redisSku="$REDIS_SKU" \
                 redisClusterPolicy="$REDIS_CLUSTER_POLICY" \
                 vmAdminPassword="$VM_ADMIN_PASSWORD" \
    --output table

# Get deployment outputs
echo ""
echo -e "${BLUE}📋 Retrieving deployment outputs...${NC}"

OUTPUTS=$(az deployment sub show \
    --name "$DEPLOYMENT_NAME" \
    --subscription "$AZURE_SUBSCRIPTION_ID" \
    --query "properties.outputs" -o json)

REDIS_HOSTNAME=$(echo "$OUTPUTS" | jq -r '.REDIS_HOSTNAME.value // empty')
REDIS_PORT=$(echo "$OUTPUTS" | jq -r '.REDIS_PORT.value // empty')
AZURE_MANAGED_IDENTITY_CLIENT_ID=$(echo "$OUTPUTS" | jq -r '.AZURE_MANAGED_IDENTITY_CLIENT_ID.value // empty')
AZURE_MANAGED_IDENTITY_PRINCIPAL_ID=$(echo "$OUTPUTS" | jq -r '.AZURE_MANAGED_IDENTITY_PRINCIPAL_ID.value // empty')
VM_NAME=$(echo "$OUTPUTS" | jq -r '.VM_NAME.value // empty')
VM_PUBLIC_IP=$(echo "$OUTPUTS" | jq -r '.VM_PUBLIC_IP.value // empty')

# Save to azd environment
if command -v azd &> /dev/null; then
    echo -e "${BLUE}💾 Saving outputs to azd environment...${NC}"
    azd env set REDIS_HOSTNAME "$REDIS_HOSTNAME" 2>/dev/null || true
    azd env set REDIS_PORT "$REDIS_PORT" 2>/dev/null || true
    azd env set AZURE_MANAGED_IDENTITY_CLIENT_ID "$AZURE_MANAGED_IDENTITY_CLIENT_ID" 2>/dev/null || true
    azd env set AZURE_MANAGED_IDENTITY_PRINCIPAL_ID "$AZURE_MANAGED_IDENTITY_PRINCIPAL_ID" 2>/dev/null || true
    azd env set VM_NAME "$VM_NAME" 2>/dev/null || true
    azd env set VM_PUBLIC_IP "$VM_PUBLIC_IP" 2>/dev/null || true
    azd env set REDIS_CLUSTER_POLICY "$REDIS_CLUSTER_POLICY" 2>/dev/null || true
fi

# Print summary
echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}✅ Deployment Complete!${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo -e "${BLUE}Redis Configuration:${NC}"
echo -e "  Hostname:       ${GREEN}$REDIS_HOSTNAME${NC}"
echo -e "  Port:           ${GREEN}$REDIS_PORT${NC}"
echo -e "  Cluster Policy: ${GREEN}$REDIS_CLUSTER_POLICY${NC}"
echo ""
echo -e "${BLUE}Managed Identity:${NC}"
echo -e "  Client ID:      ${GREEN}$AZURE_MANAGED_IDENTITY_CLIENT_ID${NC}"
echo -e "  Principal ID:   ${GREEN}$AZURE_MANAGED_IDENTITY_PRINCIPAL_ID${NC}"
echo ""
echo -e "${BLUE}Test VM:${NC}"
echo -e "  Name:           ${GREEN}$VM_NAME${NC}"
echo -e "  Public IP:      ${GREEN}$VM_PUBLIC_IP${NC}"
echo -e "  Username:       ${GREEN}azureuser${NC}"
echo ""
echo -e "${YELLOW}📝 Quick Start - Run tests with:${NC}"
echo -e "   ${CYAN}./run.sh setup${NC}     # Copy examples to VM (first time)"
echo -e "   ${CYAN}./run.sh python${NC}    # Run Python example"
echo -e "   ${CYAN}./run.sh java${NC}      # Run Java Lettuce example"
echo -e "   ${CYAN}./run.sh all${NC}       # Run all examples"
echo ""
if [ "$REDIS_CLUSTER_POLICY" == "OSSCluster" ]; then
    echo -e "   ${CYAN}./run.sh java --cluster${NC}  # Run Java Lettuce Cluster example"
    echo ""
fi
echo -e "${YELLOW}📝 Or connect to VM manually:${NC}"
echo -e "   ssh azureuser@$VM_PUBLIC_IP"
echo ""

# Show cluster policy specific notes
if [ "$REDIS_CLUSTER_POLICY" == "OSSCluster" ]; then
    echo -e "${YELLOW}⚠️  OSS Cluster Policy Notes:${NC}"
    echo -e "   - Use cluster-aware clients (RedisClusterClient in Lettuce)"
    echo -e "   - MappingSocketAddressResolver with DnsResolvers.UNRESOLVED required"
    echo -e "   - Run: ${CYAN}./run.sh java --cluster${NC} to test"
    echo ""
else
    echo -e "${BLUE}ℹ️  Enterprise Cluster Policy Notes:${NC}"
    echo -e "   - Use standard Redis clients (RedisClient in Lettuce)"
    echo -e "   - No cluster-aware configuration needed"
    echo ""
fi
