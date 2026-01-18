#!/bin/bash
# =============================================================================
# Azure Managed Redis Entra ID Auth - Test Runner
# =============================================================================
# Usage:
#   ./run.sh <language> [--cluster]
#
# Examples:
#   ./run.sh python           # Run Python example (Enterprise policy)
#   ./run.sh java             # Run Java Lettuce example
#   ./run.sh java --cluster   # Run Java Lettuce Cluster example (OSS Cluster policy)
#   ./run.sh all              # Run all examples
#   ./run.sh status           # Show current deployment status
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
    echo -e "${CYAN}Managed Identity:${NC}"
    echo -e "  Client ID:      ${GREEN}$AZURE_CLIENT_ID${NC}"
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
    run_on_vm "mkdir -p ~/python ~/nodejs ~/dotnet ~/java-lettuce ~/java-jedis ~/go-example"
    
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
    
    echo -e "${GREEN}✅ Examples copied to VM${NC}"
}

# Run Python example
run_python() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Running Python Example${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/python && \
        python3 -m venv .venv 2>/dev/null || true && \
        source .venv/bin/activate && \
        pip install -q -r requirements.txt && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        python managed_identity_example.py"
}

# Run Node.js example
run_nodejs() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Running Node.js Example${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/nodejs && \
        npm install --silent 2>/dev/null && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        node managed_identity_example.mjs"
}

# Run .NET example
run_dotnet() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Running .NET Example${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/dotnet && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        dotnet run -- --ManagedIdentity 2>&1"
}

# Run Java Lettuce example (supports both Enterprise and OSS Cluster)
run_java() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Running Java Lettuce Example${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-lettuce && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        export REDIS_CLUSTER_POLICY='$REDIS_CLUSTER_POLICY' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.ManagedIdentityExample' -q 2>&1"
}

# Run Java Lettuce Cluster example (OSS Cluster policy - cluster-aware client)
run_java_cluster() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Running Java Lettuce Example (OSS Cluster)${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    if [ "$REDIS_CLUSTER_POLICY" != "OSSCluster" ]; then
        echo -e "${YELLOW}⚠️  Warning: Current deployment uses '$REDIS_CLUSTER_POLICY' policy.${NC}"
        echo -e "${YELLOW}   The cluster example is designed for 'OSSCluster' policy.${NC}"
        echo -e "${YELLOW}   It may still work but won't demonstrate cluster features.${NC}"
        echo ""
    fi
    
    run_on_vm "cd ~/java-lettuce && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.ClusterManagedIdentityExample' -q 2>&1"
}

# Run Java Jedis example
run_jedis() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Running Java Jedis Example${NC}"
    echo -e "${BLUE}==========================================${NC}"
    
    run_on_vm "cd ~/java-jedis && \
        export AZURE_CLIENT_ID='$AZURE_CLIENT_ID' && \
        export REDIS_HOSTNAME='$REDIS_HOSTNAME' && \
        export REDIS_PORT='$REDIS_PORT' && \
        mvn compile -q && \
        mvn exec:java -Dexec.mainClass='com.example.ManagedIdentityExample' -q 2>&1"
}

# Run Go example
run_go() {
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Running Go Example${NC}"
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
        go run managed_identity_example.go 2>&1"
}

# Run all examples
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
    
    local passed=0
    local failed=0
    local results=()
    
    # All examples now support both Enterprise and OSS Cluster policies
    
    # Python
    if run_python; then
        results+=("Python: ✅ PASSED")
        ((passed++))
    else
        results+=("Python: ❌ FAILED")
        ((failed++))
    fi
    
    # Node.js
    if run_nodejs; then
        results+=("Node.js: ✅ PASSED")
        ((passed++))
    else
        results+=("Node.js: ❌ FAILED")
        ((failed++))
    fi
    
    # .NET
    if run_dotnet; then
        results+=(".NET: ✅ PASSED")
        ((passed++))
    else
        results+=(".NET: ❌ FAILED")
        ((failed++))
    fi
    
    # Java Lettuce (uses appropriate client based on policy)
    if run_java; then
        results+=("Java Lettuce: ✅ PASSED")
        ((passed++))
    else
        results+=("Java Lettuce: ❌ FAILED")
        ((failed++))
    fi
    
    # Go
    if run_go; then
        results+=("Go: ✅ PASSED")
        ((passed++))
    else
        results+=("Go: ❌ FAILED")
        ((failed++))
    fi
    
    # Summary
    echo ""
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  Test Summary (${REDIS_CLUSTER_POLICY})${NC}"
    echo -e "${BLUE}==========================================${NC}"
    for result in "${results[@]}"; do
        echo "  $result"
    done
    echo ""
    echo -e "  Total: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}"
    echo ""
    
    [ $failed -eq 0 ] && return 0 || return 1
}

# Print usage
usage() {
    echo ""
    echo -e "${BLUE}Azure Managed Redis Entra ID Auth - Test Runner${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status          Show deployment status and connection info"
    echo "  setup           Copy example files to VM"
    echo "  python          Run Python example"
    echo "  nodejs          Run Node.js example"
    echo "  dotnet          Run .NET example"
    echo "  java            Run Java Lettuce example (Enterprise policy)"
    echo "  java --cluster  Run Java Lettuce Cluster example (OSS Cluster policy)"
    echo "  jedis           Run Java Jedis example"
    echo "  go              Run Go example"
    echo "  all             Run all examples (smart: skips incompatible tests)"
    echo ""
    echo "Cluster Policy Notes:"
    echo "  • Enterprise policy: All standard clients work"
    echo "  • OSS Cluster policy: Only cluster-aware clients work reliably"
    echo "    - Use 'java --cluster' for cluster-aware Java Lettuce"
    echo "    - Other examples may fail with MOVED errors"
    echo ""
    echo "Quick Start:"
    echo "  1. azd up                          # Deploy infrastructure"
    echo "  2. ./run.sh setup                  # Copy examples to VM"
    echo "  3. ./run.sh all                    # Run all tests"
    echo ""
    echo "For OSS Cluster deployments:"
    echo "  azd env set REDIS_CLUSTER_POLICY OSSCluster"
    echo "  azd up"
    echo "  ./run.sh setup && ./run.sh java --cluster"
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
            run_python
            ;;
        nodejs|node)
            load_azd_env
            validate_env
            run_nodejs
            ;;
        dotnet|csharp)
            load_azd_env
            validate_env
            run_dotnet
            ;;
        java|lettuce)
            load_azd_env
            validate_env
            if [ "$option" = "--cluster" ] || [ "$option" = "cluster" ]; then
                run_java_cluster
            else
                run_java
            fi
            ;;
        jedis)
            load_azd_env
            validate_env
            run_jedis
            ;;
        go|golang)
            load_azd_env
            validate_env
            run_go
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
