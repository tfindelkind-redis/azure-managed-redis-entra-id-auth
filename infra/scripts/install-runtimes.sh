#!/bin/bash
# Install all runtimes needed to test the Redis Entra ID examples
# This script runs on the test VM during provisioning

set -e

echo "=== Starting runtime installation ==="

# ============================================
# Retry logic for transient apt failures
# ============================================
APT_MAX_RETRIES=5
APT_RETRY_DELAY=30

apt_retry() {
    local cmd="$@"
    local attempt=1
    
    while [ $attempt -le $APT_MAX_RETRIES ]; do
        echo "Attempt $attempt/$APT_MAX_RETRIES: $cmd"
        if eval "$cmd"; then
            return 0
        fi
        
        echo "Command failed. Waiting ${APT_RETRY_DELAY}s before retry..."
        sleep $APT_RETRY_DELAY
        
        # Clean apt cache and fix any broken state
        rm -rf /var/lib/apt/lists/*
        apt-get clean
        
        attempt=$((attempt + 1))
    done
    
    echo "ERROR: Command failed after $APT_MAX_RETRIES attempts: $cmd"
    return 1
}

# Update package lists with retry
apt_retry "apt-get update"

# ============================================
# Python 3.11+ with pip
# ============================================
echo "Installing Python..."
apt_retry "apt-get install -y python3 python3-pip python3-venv"
python3 --version
pip3 --version

# ============================================
# Node.js 20 LTS
# ============================================
echo "Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt_retry "apt-get install -y nodejs"
node --version
npm --version

# ============================================
# .NET 8.0 SDK
# ============================================
echo "Installing .NET 8.0..."
wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
apt_retry "apt-get update"
apt_retry "apt-get install -y dotnet-sdk-8.0"
dotnet --version

# ============================================
# Java 17 (OpenJDK) + Maven
# ============================================
echo "Installing Java 17 and Maven..."
apt_retry "apt-get install -y openjdk-17-jdk maven"
java --version
mvn --version

# ============================================
# Go 1.22
# ============================================
echo "Installing Go..."
GO_VERSION="1.22.0"
wget "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
rm -rf /usr/local/go
tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
rm "go${GO_VERSION}.linux-amd64.tar.gz"
echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
export PATH=$PATH:/usr/local/go/bin
go version

# ============================================
# Git (for cloning the examples)
# ============================================
echo "Installing Git..."
apt_retry "apt-get install -y git"

# ============================================
# Additional utilities
# ============================================
echo "Installing additional utilities..."
apt_retry "apt-get install -y curl jq unzip openssl net-tools dnsutils"

# ============================================
# Azure CLI (for debugging/troubleshooting)
# ============================================
echo "Installing Azure CLI..."
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# ============================================
# NTP for time synchronization (critical for Entra ID!)
# ============================================
echo "Configuring NTP time synchronization..."
apt_retry "apt-get install -y chrony"
systemctl enable chrony
systemctl start chrony

# Verify time sync
chronyc tracking

# ============================================
# Create test directory and clone examples
# ============================================
echo "Setting up test environment..."
mkdir -p /home/azureuser/redis-examples
chown azureuser:azureuser /home/azureuser/redis-examples

# Create helper script for running tests
cat > /home/azureuser/run-tests.sh << 'EOF'
#!/bin/bash
# Helper script to run Redis Entra ID examples
# Usage: ./run-tests.sh [python|nodejs|dotnet|java|go|all]

set -e

EXAMPLES_DIR="/home/azureuser/redis-examples"

# Check if AZURE_CLIENT_ID and REDIS_HOSTNAME are set
if [ -z "$AZURE_CLIENT_ID" ] || [ -z "$REDIS_HOSTNAME" ]; then
    echo "Error: Please set environment variables:"
    echo "  export AZURE_CLIENT_ID='your-managed-identity-client-id'"
    echo "  export REDIS_HOSTNAME='your-redis.region.redisenterprise.cache.azure.net'"
    exit 1
fi

export REDIS_PORT="${REDIS_PORT:-10000}"

run_python() {
    echo "=== Running Python Example ==="
    cd "$EXAMPLES_DIR/examples/python"
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt
    python managed_identity_example.py
    deactivate
}

run_nodejs() {
    echo "=== Running Node.js Example ==="
    cd "$EXAMPLES_DIR/examples/nodejs"
    npm install
    node managed_identity_example.mjs
}

run_dotnet() {
    echo "=== Running .NET Example ==="
    cd "$EXAMPLES_DIR/examples/dotnet"
    dotnet run -- managed-identity
}

run_java_lettuce() {
    echo "=== Running Java Lettuce Example ==="
    cd "$EXAMPLES_DIR/examples/java-lettuce"
    mvn clean compile exec:java -Dexec.mainClass="com.example.ManagedIdentityExample"
}

run_java_lettuce_springboot() {
    echo "=== Running Java Lettuce Spring Boot Example ==="
    cd "$EXAMPLES_DIR/examples/java-lettuce-springboot"
    mvn clean spring-boot:run
}

run_java_jedis() {
    echo "=== Running Java Jedis Example ==="
    cd "$EXAMPLES_DIR/examples/java-jedis"
    mvn clean compile exec:java -Dexec.mainClass="com.example.ManagedIdentityExample"
}

run_go() {
    echo "=== Running Go Example ==="
    cd "$EXAMPLES_DIR/examples/go"
    go run managed_identity_example.go
}

case "${1:-all}" in
    python)     run_python ;;
    nodejs)     run_nodejs ;;
    dotnet)     run_dotnet ;;
    java)       run_java_lettuce ;;
    java-springboot) run_java_lettuce_springboot ;;
    jedis)      run_java_jedis ;;
    go)         run_go ;;
    all)
        run_python
        run_nodejs
        run_dotnet
        run_java_lettuce
        run_java_jedis
        run_go
        echo ""
        echo "=== ALL TESTS COMPLETED ==="
        ;;
    *)
        echo "Usage: $0 [python|nodejs|dotnet|java|java-springboot|jedis|go|all]"
        exit 1
        ;;
esac
EOF

chmod +x /home/azureuser/run-tests.sh
chown azureuser:azureuser /home/azureuser/run-tests.sh

# ============================================
# Create environment setup script
# ============================================
cat > /home/azureuser/setup-env.sh << 'EOF'
#!/bin/bash
# Source this file to set up environment variables for testing
# Usage: source ./setup-env.sh

# These values come from azd deployment outputs
export AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"
export REDIS_HOSTNAME="${REDIS_HOSTNAME:-}"
export REDIS_PORT="${REDIS_PORT:-10000}"

echo "Environment variables set:"
echo "  AZURE_CLIENT_ID: $AZURE_CLIENT_ID"
echo "  REDIS_HOSTNAME: $REDIS_HOSTNAME"
echo "  REDIS_PORT: $REDIS_PORT"

# Verify time sync (critical for Entra ID!)
echo ""
echo "Time synchronization status:"
chronyc tracking | grep -E "Leap status|System time"
EOF

chmod +x /home/azureuser/setup-env.sh
chown azureuser:azureuser /home/azureuser/setup-env.sh

echo "=== Runtime installation complete ==="
echo ""
echo "Installed versions:"
echo "  Python:  $(python3 --version)"
echo "  Node.js: $(node --version)"
echo "  .NET:    $(dotnet --version)"
echo "  Java:    $(java --version 2>&1 | head -1)"
echo "  Maven:   $(mvn --version | head -1)"
echo "  Go:      $(go version)"
echo ""
echo "To test, SSH to the VM and run:"
echo "  1. Clone examples: git clone <repo> /home/azureuser/redis-examples"
echo "  2. Set env vars: export AZURE_CLIENT_ID='...' REDIS_HOSTNAME='...'"
echo "  3. Run tests: ./run-tests.sh all"
