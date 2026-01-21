#!/bin/bash
# =============================================================================
# Azure Managed Redis Entra ID Auth - Test Runner
# =============================================================================
# Usage:
#   ./run.sh <language> [auth-type]
#
# Examples:
#   ./run.sh python                    # Run all Python auth examples
#   ./run.sh python user-mi            # Run Python user-assigned MI example
#   ./run.sh python system-mi          # Run Python system-assigned MI example
#   ./run.sh python sp                 # Run Python service principal example
#   ./run.sh java                      # Run all Java Lettuce auth examples
#   ./run.sh springboot                # Run Spring Boot with all profiles
#   ./run.sh all                       # Run all examples for all languages
#   ./run.sh status                    # Show current deployment status
#
# Auth Types:
#   user-mi     User-Assigned Managed Identity (runs on Azure VM)
#   system-mi   System-Assigned Managed Identity (runs on Azure VM)
#   sp          Service Principal (can run locally or on VM)
#   all         All three authentication types (default)
#
# Prerequisites:
#   - Run 'azd up' first to deploy infrastructure
#   - Or run './infra/scripts/deploy.sh' directly
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load environment from azd if available
load_azd_env() {
    if command -v azd &> /dev/null; then
        REDIS_HOSTNAME=$(azd env get-value REDIS_HOSTNAME 2>/dev/null || echo "")
        REDIS_PORT=$(azd env get-value REDIS_PORT 2>/dev/null || echo "10000")
        AZURE_CLIENT_ID=$(azd env get-value AZURE_MANAGED_IDENTITY_CLIENT_ID 2>/dev/null || azd env get-value MANAGED_IDENTITY_CLIENT_ID 2>/dev/null || echo "")
        VM_PUBLIC_IP=$(azd env get-value VM_PUBLIC_IP 2>/dev/null || echo "")
        VM_ADMIN_PASSWORD=$(azd env get-value VM_ADMIN_PASSWORD 2>/dev/null || echo "")
        REDIS_CLUSTER_POLICY=$(azd env get-value REDIS_CLUSTER_POLICY 2>/dev/null || echo "EnterpriseCluster")
        # Service Principal credentials
        SERVICE_PRINCIPAL_CLIENT_ID=$(azd env get-value SERVICE_PRINCIPAL_CLIENT_ID 2>/dev/null || echo "")
        SERVICE_PRINCIPAL_CLIENT_SECRET=$(azd env get-value SERVICE_PRINCIPAL_CLIENT_SECRET 2>/dev/null || echo "")
        SERVICE_PRINCIPAL_TENANT_ID=$(azd env get-value SERVICE_PRINCIPAL_TENANT_ID 2>/dev/null || echo "")
        # System-assigned identity
        VM_SYSTEM_ASSIGNED_PRINCIPAL_ID=$(azd env get-value VM_SYSTEM_ASSIGNED_PRINCIPAL_ID 2>/dev/null || echo "")
    fi
}

# Validate environment
validate_env() {
    local missing=()
    [ -z "$REDIS_HOSTNAME" ] && missing+=("REDIS_HOSTNAME")
    [ -z "$AZURE_CLIENT_ID" ] && missing+=("AZURE_CLIENT_ID")
    [ -z "$VM_PUBLIC_IP" ] && missing+=("VM_PUBLIC_IP")
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}❌ Missing environment variables: ${missing[*]}${NC}"
        echo ""
        echo "Please run 'azd up' first, or set these variables manually."
        echo "You can also run './infra/scripts/deploy.sh' to deploy."
        exit 1
    fi
}

# Show status
show_status() {
    load_azd_env
    
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Azure Managed Redis - Deployment Status${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""
    
    if [ -z "$REDIS_HOSTNAME" ]; then
        echo -e "${YELLOW}⚠️  No deployment found. Run 'azd up' first.${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}Redis Configuration:${NC}"
    echo -e "  Hostname:       ${GREEN}$REDIS_HOSTNAME${NC}"
    echo -e "  Port:           ${GREEN}$REDIS_PORT${NC}"
    echo -e "  Cluster Policy: ${GREEN}$REDIS_CLUSTER_POLICY${NC}"
    echo ""
    echo -e "${CYAN}Authentication Methods:${NC}"
    echo ""
    echo -e "  ${YELLOW}1. User-Assigned Managed Identity${NC}"
    echo -e "     Client ID: ${GREEN}$AZURE_CLIENT_ID${NC}"
    echo ""
    echo -e "  ${YELLOW}2. System-Assigned Managed Identity${NC}"
    if [ -n "$VM_SYSTEM_ASSIGNED_PRINCIPAL_ID" ]; then
        echo -e "     Principal ID: ${GREEN}$VM_SYSTEM_ASSIGNED_PRINCIPAL_ID${NC}"
    else
        echo -e "     Principal ID: ${YELLOW}(Available on VM, no env var needed)${NC}"
    fi
    echo ""
    echo -e "  ${YELLOW}3. Service Principal${NC}"
    if [ -n "$SERVICE_PRINCIPAL_CLIENT_ID" ]; then
        echo -e "     Client ID: ${GREEN}$SERVICE_PRINCIPAL_CLIENT_ID${NC}"
        echo -e "     Tenant ID: ${GREEN}$SERVICE_PRINCIPAL_TENANT_ID${NC}"
        echo -e "     Secret:    ${GREEN}(stored in azd env)${NC}"
    else
        echo -e "     ${YELLOW}(Not configured - run 'azd provision' or post-provision hook)${NC}"
    fi
    echo ""
    echo -e "${CYAN}Test VM:${NC}"
    echo -e "  Public IP:      ${GREEN}$VM_PUBLIC_IP${NC}"
    echo -e "  SSH:            ${GREEN}ssh azureuser@$VM_PUBLIC_IP${NC}"
    echo ""
    
    # Check VM connectivity
    echo -ne "${CYAN}Checking VM connectivity... ${NC}"
    if nc -z -w 5 "$VM_PUBLIC_IP" 22 2>/dev/null; then
        echo -e "${GREEN}✅ VM reachable${NC}"
    else
        echo -e "${RED}❌ VM not reachable on port 22${NC}"
    fi
    echo ""
}

# Run command on VM via SSH
run_on_vm() {
    local cmd="$1"
    local use_password="${2:-true}"
    
    if [ "$use_password" = "true" ] && [ -n "$VM_ADMIN_PASSWORD" ]; then
        # Use sshpass if available and password is set
        if command -v sshpass &> /dev/null; then
            sshpass -p "$VM_ADMIN_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "azureuser@$VM_PUBLIC_IP" "$cmd"
        else
            echo -e "${YELLOW}Note: Install 'sshpass' for passwordless execution, or use SSH keys.${NC}"
            echo -e "${YELLOW}Running with interactive SSH...${NC}"
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "azureuser@$VM_PUBLIC_IP" "$cmd"
        fi
    else
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "azureuser@$VM_PUBLIC_IP" "$cmd"
    fi
}

# Copy examples to VM and setup
setup_vm() {
    echo -e "${BLUE}📦 Setting up examples on VM...${NC}"
    
    # Create directories on VM
    # Note: ~/go is GOPATH default, so use ~/go-example for Go code
    run_on_vm "mkdir -p ~/python ~/nodejs ~/dotnet ~/java-lettuce ~/java-jedis ~/go-example ~/java-springboot"
    
    # Copy example files
    echo "   Copying Python example..."
    sshpass -p "$VM_ADMIN_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/python/"* "azureuser@$VM_PUBLIC_IP:~/python/" 2>/dev/null || \
        scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/python/"* "azureuser@$VM_PUBLIC_IP:~/python/"
    
    echo "   Copying Node.js example..."
    sshpass -p "$VM_ADMIN_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/nodejs/"* "azureuser@$VM_PUBLIC_IP:~/nodejs/" 2>/dev/null || \
        scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/nodejs/"* "azureuser@$VM_PUBLIC_IP:~/nodejs/"
    
    echo "   Copying .NET example..."
    sshpass -p "$VM_ADMIN_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/dotnet/"* "azureuser@$VM_PUBLIC_IP:~/dotnet/" 2>/dev/null || \
        scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/dotnet/"* "azureuser@$VM_PUBLIC_IP:~/dotnet/"
    
    echo "   Copying Java Lettuce example..."
    sshpass -p "$VM_ADMIN_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/java-lettuce/"* "azureuser@$VM_PUBLIC_IP:~/java-lettuce/" 2>/dev/null || \
        scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/java-lettuce/"* "azureuser@$VM_PUBLIC_IP:~/java-lettuce/"
    
    echo "   Copying Java Jedis example..."
    sshpass -p "$VM_ADMIN_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/java-jedis/"* "azureuser@$VM_PUBLIC_IP:~/java-jedis/" 2>/dev/null || \
        scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/java-jedis/"* "azureuser@$VM_PUBLIC_IP:~/java-jedis/"
    
    echo "   Copying Go example..."
    sshpass -p "$VM_ADMIN_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/go/"* "azureuser@$VM_PUBLIC_IP:~/go-example/" 2>/dev/null || \
        scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/go/"* "azureuser@$VM_PUBLIC_IP:~/go-example/"
    
    echo "   Copying Spring Boot example..."
    sshpass -p "$VM_ADMIN_PASSWORD" scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/java-lettuce-springboot/"* "azureuser@$VM_PUBLIC_IP:~/java-springboot/" 2>/dev/null || \
        scp -o StrictHostKeyChecking=no -r "$SCRIPT_DIR/examples/java-lettuce-springboot/"* "azureuser@$VM_PUBLIC_IP:~/java-springboot/"
    
    echo -e "${GREEN}✅ Examples copied to VM${NC}"
}

# Run Python example - User-Assigned Managed Identity
run_python_user_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Python - User-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/python && \
        python3 -m venv .venv 2>/dev/null || true && \
        source .venv/bin/activate && \
        pip install -q -r requirements.txt && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        python user_assigned_managed_identity_example.py"
}

# Run Python example - System-Assigned Managed Identity
run_python_system_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Python - System-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/python && \
        python3 -m venv .venv 2>/dev/null || true && \
        source .venv/bin/activate && \
        pip install -q -r requirements.txt && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        python system_assigned_managed_identity_example.py"
}

# Run Python example - Service Principal
run_python_sp() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Python - Service Principal${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/python && \
        python3 -m venv .venv 2>/dev/null || true && \
        source .venv/bin/activate && \
        pip install -q -r requirements.txt && \
        export AZURE_CLIENT_ID='$SERVICE_PRINCIPAL_CLIENT_ID' && \
        export AZURE_CLIENT_SECRET='$SERVICE_PRINCIPAL_CLIENT_SECRET' && \
        export AZURE_TENANT_ID='$SERVICE_PRINCIPAL_TENANT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        python service_principal_example.py"
}

# Run all Python examples
run_python() {
    local auth_type="${1:-all}"
    
    case "$auth_type" in
        user-mi|user)
            run_python_user_mi
            ;;
        system-mi|system)
            run_python_system_mi
            ;;
        sp|service-principal)
            run_python_sp
            ;;
        all|"")
            run_python_user_mi
            run_python_system_mi
            run_python_sp
            ;;
        *)
            echo -e "${RED}Unknown auth type: $auth_type${NC}"
            return 1
            ;;
    esac
}

# Run Node.js example - User-Assigned Managed Identity
run_nodejs_user_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Node.js - User-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/nodejs && \
        npm install --silent 2>/dev/null && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        node user_assigned_managed_identity_example.mjs"
}

# Run Node.js example - System-Assigned Managed Identity
run_nodejs_system_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Node.js - System-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/nodejs && \
        npm install --silent 2>/dev/null && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        node system_assigned_managed_identity_example.mjs"
}

# Run Node.js example - Service Principal
run_nodejs_sp() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Node.js - Service Principal${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/nodejs && \
        npm install --silent 2>/dev/null && \
        export AZURE_CLIENT_ID='$SERVICE_PRINCIPAL_CLIENT_ID' && \
        export AZURE_CLIENT_SECRET='$SERVICE_PRINCIPAL_CLIENT_SECRET' && \
        export AZURE_TENANT_ID='$SERVICE_PRINCIPAL_TENANT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        node service_principal_example.mjs"
}

# Run all Node.js examples
run_nodejs() {
    local auth_type="${1:-all}"
    
    case "$auth_type" in
        user-mi|user)
            run_nodejs_user_mi
            ;;
        system-mi|system)
            run_nodejs_system_mi
            ;;
        sp|service-principal)
            run_nodejs_sp
            ;;
        all|"")
            run_nodejs_user_mi
            run_nodejs_system_mi
            run_nodejs_sp
            ;;
        *)
            echo -e "${RED}Unknown auth type: $auth_type${NC}"
            return 1
            ;;
    esac
}

# Run .NET example - User-Assigned Managed Identity
run_dotnet_user_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  .NET - User-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/dotnet && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        dotnet run -- --user-mi 2>&1"
}

# Run .NET example - System-Assigned Managed Identity
run_dotnet_system_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  .NET - System-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/dotnet && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        dotnet run -- --system-mi 2>&1"
}

# Run .NET example - Service Principal
run_dotnet_sp() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  .NET - Service Principal${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/dotnet && \
        export AZURE_CLIENT_ID='$SERVICE_PRINCIPAL_CLIENT_ID' && \
        export AZURE_CLIENT_SECRET='$SERVICE_PRINCIPAL_CLIENT_SECRET' && \
        export AZURE_TENANT_ID='$SERVICE_PRINCIPAL_TENANT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        dotnet run -- -sp 2>&1"
}

# Run all .NET examples
run_dotnet() {
    local auth_type="${1:-all}"
    
    case "$auth_type" in
        user-mi|user)
            run_dotnet_user_mi
            ;;
        system-mi|system)
            run_dotnet_system_mi
            ;;
        sp|service-principal)
            run_dotnet_sp
            ;;
        all|"")
            run_dotnet_user_mi
            run_dotnet_system_mi
            run_dotnet_sp
            ;;
        *)
            echo -e "${RED}Unknown auth type: $auth_type${NC}"
            return 1
            ;;
    esac
}

# Run Java Lettuce example - User-Assigned Managed Identity
run_java_user_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Java Lettuce - User-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-lettuce && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.UserAssignedManagedIdentityExample' -Dio.netty.transport.noNative=true -q 2>&1"
}

# Run Java Lettuce example - System-Assigned Managed Identity
run_java_system_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Java Lettuce - System-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-lettuce && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.SystemAssignedManagedIdentityExample' -Dio.netty.transport.noNative=true -q 2>&1"
}

# Run Java Lettuce example - Service Principal
run_java_sp() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Java Lettuce - Service Principal${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-lettuce && \
        export AZURE_CLIENT_ID='$SERVICE_PRINCIPAL_CLIENT_ID' && \
        export AZURE_CLIENT_SECRET='$SERVICE_PRINCIPAL_CLIENT_SECRET' && \
        export AZURE_TENANT_ID='$SERVICE_PRINCIPAL_TENANT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.ServicePrincipalExample' -Dio.netty.transport.noNative=true -q 2>&1"
}

# Run all Java Lettuce examples
run_java() {
    local auth_type="${1:-all}"
    
    case "$auth_type" in
        user-mi|user)
            run_java_user_mi
            ;;
        system-mi|system)
            run_java_system_mi
            ;;
        sp|service-principal)
            run_java_sp
            ;;
        cluster)
            # Backwards compatibility - run user-mi with cluster
            run_java_user_mi
            ;;
        all|"")
            run_java_user_mi
            run_java_system_mi
            run_java_sp
            ;;
        *)
            echo -e "${RED}Unknown auth type: $auth_type${NC}"
            return 1
            ;;
    esac
}

# Run Java Lettuce Cluster example (explicit OSS Cluster - for backwards compatibility)
run_java_cluster() {
    run_java "user-mi"
}

# Run Java Jedis example - User-Assigned Managed Identity
run_jedis_user_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Java Jedis - User-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    if [ "$REDIS_CLUSTER_POLICY" = "OSSCluster" ]; then
        echo -e "${YELLOW}  ⚠️  Note: Jedis has limited OSS Cluster support${NC}"
    fi
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-jedis && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.UserAssignedManagedIdentityExample' -q 2>&1"
}

# Run Java Jedis example - System-Assigned Managed Identity
run_jedis_system_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Java Jedis - System-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    if [ "$REDIS_CLUSTER_POLICY" = "OSSCluster" ]; then
        echo -e "${YELLOW}  ⚠️  Note: Jedis has limited OSS Cluster support${NC}"
    fi
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-jedis && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.SystemAssignedManagedIdentityExample' -q 2>&1"
}

# Run Java Jedis example - Service Principal
run_jedis_sp() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Java Jedis - Service Principal${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    if [ "$REDIS_CLUSTER_POLICY" = "OSSCluster" ]; then
        echo -e "${YELLOW}  ⚠️  Note: Jedis has limited OSS Cluster support${NC}"
    fi
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-jedis && \
        export AZURE_CLIENT_ID='$SERVICE_PRINCIPAL_CLIENT_ID' && \
        export AZURE_CLIENT_SECRET='$SERVICE_PRINCIPAL_CLIENT_SECRET' && \
        export AZURE_TENANT_ID='$SERVICE_PRINCIPAL_TENANT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.ServicePrincipalExample' -q 2>&1"
}

# Run all Java Jedis examples
run_jedis() {
    local auth_type="${1:-all}"
    
    case "$auth_type" in
        user-mi|user)
            run_jedis_user_mi
            ;;
        system-mi|system)
            run_jedis_system_mi
            ;;
        sp|service-principal)
            run_jedis_sp
            ;;
        all|"")
            run_jedis_user_mi
            run_jedis_system_mi
            run_jedis_sp
            ;;
        *)
            echo -e "${RED}Unknown auth type: $auth_type${NC}"
            return 1
            ;;
    esac
}

# Run Go example - User-Assigned Managed Identity
run_go_user_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Go - User-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/go-example && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        export PATH=\$PATH:/usr/local/go/bin && \
        export GO111MODULE=on && \
        export GOPATH=\$HOME/gopath && \
        export GOCACHE=\$HOME/gocache && \
        mkdir -p \$GOPATH \$GOCACHE && \
        go mod tidy && \
        go run user_assigned_managed_identity_example.go 2>&1"
}

# Run Go example - System-Assigned Managed Identity
run_go_system_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Go - System-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/go-example && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        export PATH=\$PATH:/usr/local/go/bin && \
        export GO111MODULE=on && \
        export GOPATH=\$HOME/gopath && \
        export GOCACHE=\$HOME/gocache && \
        mkdir -p \$GOPATH \$GOCACHE && \
        go mod tidy && \
        go run system_assigned_managed_identity_example.go 2>&1"
}

# Run Go example - Service Principal
run_go_sp() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Go - Service Principal${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/go-example && \
        export AZURE_CLIENT_ID='$SERVICE_PRINCIPAL_CLIENT_ID' && \
        export AZURE_CLIENT_SECRET='$SERVICE_PRINCIPAL_CLIENT_SECRET' && \
        export AZURE_TENANT_ID='$SERVICE_PRINCIPAL_TENANT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        export PATH=\$PATH:/usr/local/go/bin && \
        export GO111MODULE=on && \
        export GOPATH=\$HOME/gopath && \
        export GOCACHE=\$HOME/gocache && \
        mkdir -p \$GOPATH \$GOCACHE && \
        go mod tidy && \
        go run service_principal_example.go 2>&1"
}

# Run all Go examples
run_go() {
    local auth_type="${1:-all}"
    
    case "$auth_type" in
        user-mi|user)
            run_go_user_mi
            ;;
        system-mi|system)
            run_go_system_mi
            ;;
        sp|service-principal)
            run_go_sp
            ;;
        all|"")
            run_go_user_mi
            run_go_system_mi
            run_go_sp
            ;;
        *)
            echo -e "${RED}Unknown auth type: $auth_type${NC}"
            return 1
            ;;
    esac
}

# Run Spring Boot example - User-Assigned Managed Identity
run_springboot_user_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Spring Boot - User-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-springboot && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q 2>/dev/null && \
        mvn spring-boot:run -Dspring-boot.run.profiles=user-mi -Dspring-boot.run.jvmArguments='-Dio.netty.transport.noNative=true' -q 2>&1 || mvn spring-boot:run -Dspring-boot.run.profiles=user-mi -Dspring-boot.run.jvmArguments='-Dio.netty.transport.noNative=true' 2>&1 | head -100"
}

# Run Spring Boot example - System-Assigned Managed Identity
run_springboot_system_mi() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Spring Boot - System-Assigned Managed Identity${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-springboot && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q 2>/dev/null && \
        mvn spring-boot:run -Dspring-boot.run.profiles=system-mi -Dspring-boot.run.jvmArguments='-Dio.netty.transport.noNative=true' -q 2>&1 || mvn spring-boot:run -Dspring-boot.run.profiles=system-mi -Dspring-boot.run.jvmArguments='-Dio.netty.transport.noNative=true' 2>&1 | head -100"
}

# Run Spring Boot example - Service Principal
run_springboot_sp() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Spring Boot - Service Principal${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-springboot && \
        export AZURE_CLIENT_ID='$SERVICE_PRINCIPAL_CLIENT_ID' && \
        export AZURE_CLIENT_SECRET='$SERVICE_PRINCIPAL_CLIENT_SECRET' && \
        export AZURE_TENANT_ID='$SERVICE_PRINCIPAL_TENANT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q 2>/dev/null && \
        mvn spring-boot:run -Dspring-boot.run.profiles=service-principal -Dspring-boot.run.jvmArguments='-Dio.netty.transport.noNative=true' -q 2>&1 || mvn spring-boot:run -Dspring-boot.run.profiles=service-principal -Dspring-boot.run.jvmArguments='-Dio.netty.transport.noNative=true' 2>&1 | head -100"
}

# Run all Spring Boot examples
run_springboot() {
    local auth_type="${1:-all}"
    
    case "$auth_type" in
        user-mi|user)
            run_springboot_user_mi
            ;;
        system-mi|system)
            run_springboot_system_mi
            ;;
        sp|service-principal)
            run_springboot_sp
            ;;
        all|"")
            run_springboot_user_mi
            run_springboot_system_mi
            run_springboot_sp
            ;;
        *)
            echo -e "${RED}Unknown auth type: $auth_type${NC}"
            return 1
            ;;
    esac
}

# Run all examples (auto-detects cluster policy)
run_all() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Running ALL Examples${NC}"
    echo -e "${BLUE}  Cluster Policy: ${CYAN}$REDIS_CLUSTER_POLICY${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""
    
    if [ "$REDIS_CLUSTER_POLICY" = "OSSCluster" ]; then
        echo -e "${CYAN}ℹ️  OSS Cluster Policy detected.${NC}"
        echo -e "${CYAN}   All examples now support cluster-aware clients with address remapping.${NC}"
        echo ""
    else
        echo -e "${CYAN}ℹ️  Enterprise Cluster Policy detected.${NC}"
        echo -e "${CYAN}   Using standard Redis clients (server handles slot routing).${NC}"
        echo ""
    fi
    
    local total_passed=0
    local total_failed=0
    
    # Results arrays (language_authmethod format: 0=fail, 1=pass)
    local python_user=0 python_sys=0 python_sp=0
    local nodejs_user=0 nodejs_sys=0 nodejs_sp=0
    local dotnet_user=0 dotnet_sys=0 dotnet_sp=0
    local java_user=0 java_sys=0 java_sp=0
    local go_user=0 go_sys=0 go_sp=0
    local jedis_user=0 jedis_sys=0 jedis_sp=0
    local spring_user=0 spring_sys=0 spring_sp=0
    
    # Python tests
    if run_python "user-mi"; then python_user=1; ((total_passed++)); else ((total_failed++)); fi
    if run_python "system-mi"; then python_sys=1; ((total_passed++)); else ((total_failed++)); fi
    if run_python "sp"; then python_sp=1; ((total_passed++)); else ((total_failed++)); fi
    
    # Node.js tests
    if run_nodejs "user-mi"; then nodejs_user=1; ((total_passed++)); else ((total_failed++)); fi
    if run_nodejs "system-mi"; then nodejs_sys=1; ((total_passed++)); else ((total_failed++)); fi
    if run_nodejs "sp"; then nodejs_sp=1; ((total_passed++)); else ((total_failed++)); fi
    
    # .NET tests
    if run_dotnet "user-mi"; then dotnet_user=1; ((total_passed++)); else ((total_failed++)); fi
    if run_dotnet "system-mi"; then dotnet_sys=1; ((total_passed++)); else ((total_failed++)); fi
    if run_dotnet "sp"; then dotnet_sp=1; ((total_passed++)); else ((total_failed++)); fi
    
    # Java Lettuce tests
    if run_java "user-mi"; then java_user=1; ((total_passed++)); else ((total_failed++)); fi
    if run_java "system-mi"; then java_sys=1; ((total_passed++)); else ((total_failed++)); fi
    if run_java "sp"; then java_sp=1; ((total_passed++)); else ((total_failed++)); fi
    
    # Go tests
    if run_go "user-mi"; then go_user=1; ((total_passed++)); else ((total_failed++)); fi
    if run_go "system-mi"; then go_sys=1; ((total_passed++)); else ((total_failed++)); fi
    if run_go "sp"; then go_sp=1; ((total_passed++)); else ((total_failed++)); fi
    
    # Java Jedis tests
    if run_jedis "user-mi"; then jedis_user=1; ((total_passed++)); else ((total_failed++)); fi
    if run_jedis "system-mi"; then jedis_sys=1; ((total_passed++)); else ((total_failed++)); fi
    if run_jedis "sp"; then jedis_sp=1; ((total_passed++)); else ((total_failed++)); fi
    
    # Spring Boot tests
    if run_springboot "user-mi"; then spring_user=1; ((total_passed++)); else ((total_failed++)); fi
    if run_springboot "system-mi"; then spring_sys=1; ((total_passed++)); else ((total_failed++)); fi
    if run_springboot "sp"; then spring_sp=1; ((total_passed++)); else ((total_failed++)); fi
    
    # Helper function to convert 0/1 to emoji
    result_icon() { [ "$1" -eq 1 ] && echo "✅" || echo "❌"; }
    
    # Helper to get status
    get_status() {
        local u=$1 s=$2 p=$3
        if [ $u -eq 1 ] && [ $s -eq 1 ] && [ $p -eq 1 ]; then
            echo -e "${GREEN}PASSED${NC}"
        elif [ $u -eq 0 ] && [ $s -eq 0 ] && [ $p -eq 0 ]; then
            echo -e "${RED}FAILED${NC}"
        else
            echo -e "${YELLOW}PARTIAL${NC}"
        fi
    }
    
    # Print Summary Table
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║               TEST SUMMARY - ${REDIS_CLUSTER_POLICY} Cluster Policy                       ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║${NC} ${CYAN}Language${NC}        │ ${CYAN}User-MI${NC} │ ${CYAN}System-MI${NC} │ ${CYAN}Service Principal${NC} │ ${CYAN}Status${NC}    ${BLUE}║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    
    printf "${BLUE}║${NC} %-14s │    %s   │     %s    │         %s         │ %b  ${BLUE}║${NC}\n" \
        "Python" "$(result_icon $python_user)" "$(result_icon $python_sys)" "$(result_icon $python_sp)" "$(get_status $python_user $python_sys $python_sp)"
    printf "${BLUE}║${NC} %-14s │    %s   │     %s    │         %s         │ %b  ${BLUE}║${NC}\n" \
        "Node.js" "$(result_icon $nodejs_user)" "$(result_icon $nodejs_sys)" "$(result_icon $nodejs_sp)" "$(get_status $nodejs_user $nodejs_sys $nodejs_sp)"
    printf "${BLUE}║${NC} %-14s │    %s   │     %s    │         %s         │ %b  ${BLUE}║${NC}\n" \
        ".NET" "$(result_icon $dotnet_user)" "$(result_icon $dotnet_sys)" "$(result_icon $dotnet_sp)" "$(get_status $dotnet_user $dotnet_sys $dotnet_sp)"
    printf "${BLUE}║${NC} %-14s │    %s   │     %s    │         %s         │ %b  ${BLUE}║${NC}\n" \
        "Java Lettuce" "$(result_icon $java_user)" "$(result_icon $java_sys)" "$(result_icon $java_sp)" "$(get_status $java_user $java_sys $java_sp)"
    printf "${BLUE}║${NC} %-14s │    %s   │     %s    │         %s         │ %b  ${BLUE}║${NC}\n" \
        "Go" "$(result_icon $go_user)" "$(result_icon $go_sys)" "$(result_icon $go_sp)" "$(get_status $go_user $go_sys $go_sp)"
    printf "${BLUE}║${NC} %-14s │    %s   │     %s    │         %s         │ %b  ${BLUE}║${NC}\n" \
        "Java Jedis" "$(result_icon $jedis_user)" "$(result_icon $jedis_sys)" "$(result_icon $jedis_sp)" "$(get_status $jedis_user $jedis_sys $jedis_sp)"
    printf "${BLUE}║${NC} %-14s │    %s   │     %s    │         %s         │ %b  ${BLUE}║${NC}\n" \
        "Spring Boot" "$(result_icon $spring_user)" "$(result_icon $spring_sys)" "$(result_icon $spring_sp)" "$(get_status $spring_user $spring_sys $spring_sp)"
    
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    printf "${BLUE}║${NC} ${CYAN}Total:${NC} ${GREEN}%d passed${NC}, ${RED}%d failed${NC} out of 21 tests                                 ${BLUE}║${NC}\n" "$total_passed" "$total_failed"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Notes for Jedis limitations on OSS Cluster
    if [ "$REDIS_CLUSTER_POLICY" = "OSSCluster" ]; then
        local jedis_total=$((jedis_user + jedis_sys + jedis_sp))
        if [ $jedis_total -lt 3 ]; then
            echo -e "${YELLOW}⚠️  Note: Java Jedis has limited OSS Cluster support with Entra ID.${NC}"
            echo -e "${YELLOW}   MOVED redirects to internal IPs cannot be followed.${NC}"
            echo -e "${YELLOW}   Recommendation: Use Lettuce for OSS Cluster deployments.${NC}"
            echo ""
        fi
    fi
    
    [ $total_failed -eq 0 ] && return 0 || return 1
}

# Print usage
usage() {
    echo ""
    echo -e "${BLUE}Azure Managed Redis Entra ID Auth - Test Runner${NC}"
    echo ""
    echo "Usage: $0 <command> [auth-type]"
    echo ""
    echo "Commands:"
    echo "  status          Show deployment status and connection info"
    echo "  setup           Copy example files to VM"
    echo "  python          Run Python examples"
    echo "  nodejs          Run Node.js examples"
    echo "  dotnet          Run .NET examples"
    echo "  java            Run Java Lettuce examples"
    echo "  jedis           Run Java Jedis examples"
    echo "  go              Run Go examples"
    echo "  springboot      Run Spring Boot examples"
    echo "  all             Run all examples (all languages, all auth types)"
    echo ""
    echo "Auth Types (optional, default: all):"
    echo "  user-mi         User-Assigned Managed Identity"
    echo "  system-mi       System-Assigned Managed Identity"
    echo "  sp              Service Principal"
    echo "  all             All three authentication methods"
    echo ""
    echo "Examples:"
    echo "  ./run.sh python                    # Run all Python auth examples"
    echo "  ./run.sh python user-mi            # Run Python user-assigned MI only"
    echo "  ./run.sh nodejs sp                 # Run Node.js service principal only"
    echo "  ./run.sh springboot system-mi      # Run Spring Boot system-assigned MI"
    echo "  ./run.sh all                       # Run everything"
    echo ""
    echo "Cluster Policy Auto-Detection:"
    echo "  All examples automatically detect the cluster policy from REDIS_CLUSTER_POLICY"
    echo "  environment variable and use the appropriate client implementation:"
    echo ""
    echo "  • Enterprise policy: Uses standard Redis clients"
    echo "    (Server handles slot routing transparently)"
    echo ""
    echo "  • OSS Cluster policy: Uses cluster-aware clients with address remapping"
    echo "    (Client maps internal Azure IPs to public hostname)"
    echo ""
    echo "Quick Start:"
    echo "  1. azd up                          # Deploy infrastructure"
    echo "  2. ./run.sh setup                  # Copy examples to VM"
    echo "  3. ./run.sh all                    # Run all tests"
    echo ""
    echo "To switch cluster policy:"
    echo "  azd env set REDIS_CLUSTER_POLICY OSSCluster  # or 'EnterpriseCluster'"
    echo "  azd up"
    echo "  ./run.sh setup && ./run.sh all"
    echo ""
}

# Main
main() {
    local cmd="${1:-}"
    local option="${2:-}"
    
    case "$cmd" in
        status)
            show_status
            ;;
        setup)
            load_azd_env
            validate_env
            setup_vm
            ;;
        python)
            load_azd_env
            validate_env
            run_python "$option"
            ;;
        nodejs|node)
            load_azd_env
            validate_env
            run_nodejs "$option"
            ;;
        dotnet|csharp)
            load_azd_env
            validate_env
            run_dotnet "$option"
            ;;
        java|lettuce)
            load_azd_env
            validate_env
            run_java "$option"
            ;;
        jedis)
            load_azd_env
            validate_env
            run_jedis "$option"
            ;;
        go|golang)
            load_azd_env
            validate_env
            run_go "$option"
            ;;
        springboot|spring)
            load_azd_env
            validate_env
            run_springboot "$option"
            ;;
        all)
            load_azd_env
            validate_env
            run_all
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown command: $cmd${NC}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
