#!/bin/bash
# Harbor Deployment Script - Fixed Version 1.2.0
set -e

# Version and metadata
SCRIPT_VERSION="1.2.0"
SCRIPT_NAME="Harbor Deployment Script"

# Harbor Configuration
HARBOR_VERSION="${HARBOR_VERSION:-2.9.1}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
HARBOR_PROJECT="${HARBOR_PROJECT:-nkp}"
HARBOR_HOST="localhost"
HARBOR_PORT="80"

# System requirements
MIN_DISK_SPACE_GB=20
MIN_MEMORY_GB=4

# Color output functions
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PURPLE=''
    CYAN=''
    NC=''
fi

log() { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

show_banner() {
    echo -e "${PURPLE}"
    echo "╔════════════════════════════════════════════╗"
    echo "║     Harbor Registry Deployment Script      ║"
    echo "║              Version $SCRIPT_VERSION                ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check system requirements
check_system_requirements() {
    log "Checking system requirements..."
    
    local issues=()
    
    # Check disk space
    local available_gb=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
    if [[ $available_gb -lt $MIN_DISK_SPACE_GB ]]; then
        issues+=("Disk space: ${available_gb}GB available, ${MIN_DISK_SPACE_GB}GB required")
    else
        success "Disk space: ${available_gb}GB available"
    fi
    
    # Check memory
    local available_mem_gb=$(free -g | awk 'NR==2{printf "%.0f", $2}')
    if [[ $available_mem_gb -lt $MIN_MEMORY_GB ]]; then
        issues+=("Memory: ${available_mem_gb}GB available, ${MIN_MEMORY_GB}GB recommended")
    else
        success "Memory: ${available_mem_gb}GB available"
    fi
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        warning "System requirement issues:"
        for issue in "${issues[@]}"; do
            echo "  - $issue"
        done
        
        read -p "Continue anyway? (y/N): " input
        if [[ ! "${input,,}" =~ ^y ]]; then
            exit 1
        fi
    else
        success "System requirements met"
    fi
}

# Check Docker environment
check_docker() {
    log "Checking Docker environment..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        error "Docker not installed"
        info "Install with: sudo apt update && sudo apt install -y docker.io"
        info "Then: sudo systemctl start docker && sudo systemctl enable docker"
        info "Add user to group: sudo usermod -aG docker $USER"
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        error "Docker daemon not running or not accessible"
        info "Start with: sudo systemctl start docker"
        info "If permission denied: sudo usermod -aG docker $USER && newgrp docker"
        exit 1
    fi
    
    local docker_version=$(docker version --format '{{.Server.Version}}')
    success "Docker version: $docker_version"
    
    # Check Docker Compose
    if command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE="docker-compose"
        local compose_version=$(docker-compose version --short)
        success "Docker Compose version: $compose_version"
    elif docker compose version &> /dev/null; then
        DOCKER_COMPOSE="docker compose"
        success "Docker Compose (plugin) available"
    else
        error "Docker Compose not installed"
        info "Install with: sudo apt update && sudo apt install -y docker-compose"
        exit 1
    fi
}

# Check required tools
check_tools() {
    log "Checking required tools..."
    
    local missing_tools=()
    local tools=("curl" "jq" "tar")
    
    for tool in "${tools[@]}"; do
        if command -v "$tool" &> /dev/null; then
            success "$tool: installed"
        else
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing tools: ${missing_tools[*]}"
        info "Install with: sudo apt update && sudo apt install -y ${missing_tools[*]}"
        exit 1
    fi
}

# Clean up any existing partial installation
cleanup_existing_harbor() {
    log "Checking for existing Harbor installation..."
    
    # Check if Harbor containers are running
    if docker ps | grep -q "harbor-core"; then
        success "Harbor is already running"
        
        info "Harbor Status:"
        docker ps --format "table {{.Names}}\t{{.Status}}" | grep harbor
        
        echo ""
        read -p "Stop existing Harbor and reinstall? (y/N): " input
        if [[ "${input,,}" =~ ^y ]]; then
            if [[ -d "./harbor" ]] && [[ -f "./harbor/docker-compose.yml" ]]; then
                log "Stopping Harbor..."
                cd harbor
                $DOCKER_COMPOSE down -v
                cd ..
                success "Harbor stopped and volumes removed"
            fi
            
            # Clean up harbor directory
            log "Removing existing Harbor directory..."
            sudo rm -rf ./harbor
            success "Cleaned up existing Harbor installation"
            return 1
        else
            return 0
        fi
    fi
    
    # Check if partial harbor directory exists
    if [[ -d "./harbor" ]]; then
        warning "Found partial Harbor directory. Cleaning up..."
        sudo rm -rf ./harbor
        success "Cleaned up partial installation"
    fi
    
    return 1
}

# Download Harbor installer
download_harbor() {
    local installer_file="harbor-offline-installer-v${HARBOR_VERSION}.tgz"
    
    if [[ -f "$installer_file" ]]; then
        success "Found existing installer: $installer_file"
        return 0
    fi
    
    log "Downloading Harbor v${HARBOR_VERSION}..."
    local url="https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/${installer_file}"
    
    if command -v wget &> /dev/null; then
        wget -q --show-progress "$url" || {
            error "Download failed"
            exit 1
        }
    else
        curl -L -o "$installer_file" "$url" || {
            error "Download failed"
            exit 1
        }
    fi
    
    success "Downloaded: $installer_file"
}

# Install Harbor
install_harbor() {
    log "Installing Harbor..."
    
    # Always extract fresh to avoid partial extractions
    log "Extracting Harbor..."
    tar xzf harbor-offline-installer-v${HARBOR_VERSION}.tgz || {
        error "Failed to extract Harbor installer"
        exit 1
    }
    success "Harbor extracted"
    
    # Verify extraction was successful
    if [[ ! -f "./harbor/harbor.yml.tmpl" ]]; then
        error "Harbor extraction incomplete - missing harbor.yml.tmpl"
        error "Please check the tar file integrity"
        exit 1
    fi
    
    cd harbor
    
    # Configure Harbor
    log "Configuring Harbor..."
    
    # Create configuration from template
    cp harbor.yml.tmpl harbor.yml
    
    # Configure for HTTP only (simpler for private registry)
    sed -i "s/^hostname:.*/hostname: ${HARBOR_HOST}/" harbor.yml
    sed -i "s/^  port: 80/  port: ${HARBOR_PORT}/" harbor.yml
    sed -i "s/^harbor_admin_password:.*/harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}/" harbor.yml
    
    # Comment out HTTPS configuration
    sed -i 's/^https:/#https:/' harbor.yml
    sed -i 's/^  port: 443/#  port: 443/' harbor.yml
    sed -i 's/^  certificate:/#  certificate:/' harbor.yml
    sed -i 's/^  private_key:/#  private_key:/' harbor.yml
    
    success "Harbor configured"
    
    # Run installer
    log "Running Harbor installer (this may take several minutes)..."
    
    if sudo ./install.sh --with-trivy; then
        success "Harbor installed successfully"
    else
        error "Harbor installation failed"
        exit 1
    fi
    
    cd ..
}

# Wait for Harbor to be ready
wait_for_harbor() {
    log "Waiting for Harbor to be ready..."
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        # Check health endpoint
        if curl -s "http://${HARBOR_HOST}:${HARBOR_PORT}/api/v2.0/systeminfo" 2>/dev/null | grep -q "harbor_version"; then
            echo ""
            success "Harbor is ready!"
            return 0
        fi
        
        attempt=$((attempt + 1))
        echo -n "."
        sleep 5
    done
    
    echo ""
    error "Harbor failed to become ready"
    warning "Check logs with: cd harbor && $DOCKER_COMPOSE logs"
    
    # Show container status
    echo ""
    warning "Container Status:"
    docker ps -a --format "table {{.Names}}\t{{.Status}}" | grep harbor || true
    
    exit 1
}

# Configure Docker daemon
configure_docker_daemon() {
    log "Configuring Docker daemon for insecure registry..."
    
    local daemon_json="/etc/docker/daemon.json"
    local registry_entry="${HARBOR_HOST}"
    
    if [[ "$HARBOR_PORT" != "80" ]] && [[ "$HARBOR_PORT" != "443" ]]; then
        registry_entry="${HARBOR_HOST}:${HARBOR_PORT}"
    fi
    
    local needs_restart=false
    
    if [[ -f "$daemon_json" ]]; then
        # Check if already configured
        if ! sudo grep -q "$registry_entry" "$daemon_json" 2>/dev/null; then
            log "Adding $registry_entry to insecure-registries..."
            sudo cp "$daemon_json" "${daemon_json}.backup.$(date +%Y%m%d_%H%M%S)"
            
            # Use jq to properly add to insecure-registries array
            local temp_file=$(mktemp)
            sudo jq --arg registry "$registry_entry" \
                '.["insecure-registries"] = (.["insecure-registries"] // []) + [$registry] | .["insecure-registries"] |= unique' \
                "$daemon_json" > "$temp_file"
            sudo mv "$temp_file" "$daemon_json"
            needs_restart=true
        else
            success "Docker already configured for this registry"
        fi
    else
        # Create new daemon.json
        echo "{\"insecure-registries\": [\"$registry_entry\"]}" | sudo tee "$daemon_json" > /dev/null
        needs_restart=true
    fi
    
    if [[ "$needs_restart" == "true" ]]; then
        log "Restarting Docker daemon..."
        sudo systemctl restart docker
        sleep 5
        
        # Verify Docker is running
        if ! docker info &> /dev/null; then
            error "Docker failed to restart properly"
            sudo systemctl status docker
            exit 1
        fi
        
        success "Docker daemon restarted"
        
        # Restart Harbor after Docker restart
        log "Restarting Harbor after Docker restart..."
        cd harbor
        $DOCKER_COMPOSE up -d
        cd ..
        
        wait_for_harbor
    fi
}

# Create Harbor project
create_harbor_project() {
    local project_name="$1"
    
    log "Creating Harbor project: $project_name"
    
    local api_url="http://${HARBOR_HOST}:${HARBOR_PORT}/api/v2.0"
    
    # Wait a bit for API to be fully ready
    sleep 5
    
    # Check if project exists
    local existing=$(curl -s -u "admin:${HARBOR_ADMIN_PASSWORD}" \
        "${api_url}/projects?name=${project_name}" | jq -r '.[].name' 2>/dev/null)
    
    if [[ "$existing" == "$project_name" ]]; then
        success "Project '$project_name' already exists"
        return 0
    fi
    
    # Create project
    local response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -u "admin:${HARBOR_ADMIN_PASSWORD}" \
        -d "{\"project_name\": \"${project_name}\", \"public\": false}" \
        "${api_url}/projects" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -n1)
    
    if [[ "$http_code" == "201" ]] || [[ "$http_code" == "409" ]]; then
        success "Project '$project_name' is ready"
    else
        error "Failed to create project (HTTP: $http_code)"
        echo "$response" | head -n-1
        return 1
    fi
}

# Test Harbor login
test_harbor_login() {
    log "Testing Docker login to Harbor..."
    
    echo "${HARBOR_ADMIN_PASSWORD}" | docker login "${HARBOR_HOST}:${HARBOR_PORT}" \
        -u admin --password-stdin &> /dev/null
    
    if [[ $? -eq 0 ]]; then
        success "Docker login successful"
        docker logout "${HARBOR_HOST}:${HARBOR_PORT}" &> /dev/null
        return 0
    else
        error "Docker login failed"
        warning "Try manually: docker login ${HARBOR_HOST}:${HARBOR_PORT} -u admin"
        return 1
    fi
}

# Generate summary
generate_summary() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}       HARBOR DEPLOYMENT COMPLETED SUCCESSFULLY!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Harbor Access:${NC}"
    echo "  URL:      http://${HARBOR_HOST}:${HARBOR_PORT}"
    echo "  Username: admin"
    echo "  Password: ${HARBOR_ADMIN_PASSWORD}"
    echo "  Project:  ${HARBOR_PROJECT}"
    echo ""
    echo -e "${CYAN}Docker Registry:${NC}"
    echo "  Registry: ${HARBOR_HOST}:${HARBOR_PORT}"
    echo "  Login:    docker login ${HARBOR_HOST}:${HARBOR_PORT} -u admin -p ${HARBOR_ADMIN_PASSWORD}"
    echo ""
    echo -e "${CYAN}Push NKP Bundles:${NC}"
    echo "  Konvoy Bundle:"
    echo -e "${YELLOW}    nkp push bundle \\"
    echo "      --bundle ./nkp-v2.15.1/container-images/konvoy-image-bundle-v2.15.1.tar \\"
    echo "      --to-registry ${HARBOR_HOST}/${HARBOR_PROJECT} \\"
    echo "      --to-registry-username admin \\"
    echo "      --to-registry-password ${HARBOR_ADMIN_PASSWORD} \\"
    echo -e "      --to-registry-insecure-skip-tls-verify${NC}"
    echo ""
    echo "  Kommander Bundle:"
    echo -e "${YELLOW}    nkp push bundle \\"
    echo "      --bundle ./nkp-v2.15.1/container-images/kommander-image-bundle-v2.15.1.tar \\"
    echo "      --to-registry ${HARBOR_HOST}/${HARBOR_PROJECT} \\"
    echo "      --to-registry-username admin \\"
    echo "      --to-registry-password ${HARBOR_ADMIN_PASSWORD} \\"
    echo -e "      --to-registry-insecure-skip-tls-verify${NC}"
    echo ""
    echo -e "${CYAN}Harbor Management:${NC}"
    echo "  Stop:     cd harbor && $DOCKER_COMPOSE down"
    echo "  Start:    cd harbor && $DOCKER_COMPOSE up -d"
    echo "  Logs:     cd harbor && $DOCKER_COMPOSE logs -f"
    echo "  Status:   docker ps | grep harbor"
    echo ""
    echo -e "${CYAN}Troubleshooting:${NC}"
    echo "  View logs:       cd harbor && $DOCKER_COMPOSE logs"
    echo "  Restart all:     cd harbor && $DOCKER_COMPOSE down && $DOCKER_COMPOSE up -d"
    echo "  View core logs:  cd harbor && $DOCKER_COMPOSE logs harbor-core"
    echo ""
    echo -e "${CYAN}Test Commands:${NC}"
    echo "  API Test: curl -u admin:${HARBOR_ADMIN_PASSWORD} http://${HARBOR_HOST}:${HARBOR_PORT}/api/v2.0/systeminfo"
    echo ""
}

# Cleanup function for script interruption
cleanup() {
    echo ""
    warning "Script interrupted. Cleaning up..."
    cd "$ORIGINAL_DIR" 2>/dev/null || true
    exit 1
}

# Main execution
main() {
    # Save original directory
    ORIGINAL_DIR=$(pwd)
    
    # Setup trap for cleanup
    trap cleanup INT TERM
    
    show_banner
    
    # System checks
    check_system_requirements
    check_docker
    check_tools
    
    # Check and clean up any existing Harbor
    if cleanup_existing_harbor; then
        info "Using existing Harbor installation"
        configure_docker_daemon
        create_harbor_project "${HARBOR_PROJECT}"
        test_harbor_login
        generate_summary
        exit 0
    fi
    
    # Download and install Harbor
    download_harbor
    install_harbor
    wait_for_harbor
    
    # Configure Docker daemon
    configure_docker_daemon
    
    # Create project
    create_harbor_project "${HARBOR_PROJECT}"
    
    # Test login
    test_harbor_login
    
    # Generate summary
    generate_summary
}

# Error handler
trap 'error "Script failed at line $LINENO"' ERR

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
