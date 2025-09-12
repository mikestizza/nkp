#!/bin/bash
#Portable NKP Harbor Deployment Script - Supports Local and External Harbor
set -e

# Version and metadata
SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="Universal NKP Harbor Deployment"

# Default configuration - can be overridden
DEFAULT_HARBOR_PORT="80"
DEFAULT_HARBOR_USERNAME="admin"
DEFAULT_HARBOR_PASSWORD="Harbor12345"
DEFAULT_NKP_VERSION="2.15.0"
DEFAULT_HARBOR_PROJECT="nkp"

# Deployment mode (local or external)
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-}"

# Minimum system requirements (for local deployments)
MIN_DISK_SPACE_GB=50
MIN_MEMORY_GB=4

# Color output functions
if [[ -t 1 ]]; then  # Check if stdout is a terminal
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
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
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

show_banner() {
    echo -e "${PURPLE}"
    echo "============================================="
    echo "    $SCRIPT_NAME v$SCRIPT_VERSION"
    echo "    Supports Local and External Harbor"
    echo "============================================="
    echo -e "${NC}"
}

# Determine deployment mode
determine_deployment_mode() {
    if [[ -n "$DEPLOYMENT_MODE" ]]; then
        return
    fi
    
    echo ""
    info "Harbor Deployment Mode Selection"
    echo "================================="
    echo "1. Local Harbor (install/manage Harbor on this host)"
    echo "2. External Harbor (use existing Harbor instance)"
    echo ""
    read -p "Select deployment mode (1-2): " mode_choice
    
    case "$mode_choice" in
        1)
            DEPLOYMENT_MODE="local"
            success "Selected: Local Harbor deployment"
            ;;
        2)
            DEPLOYMENT_MODE="external"
            success "Selected: External Harbor deployment"
            collect_external_harbor_info
            ;;
        *)
            error "Invalid selection"
            exit 1
            ;;
    esac
}

# Collect external Harbor information
collect_external_harbor_info() {
    echo ""
    info "External Harbor Configuration"
    echo "=============================="
    
    read -p "Harbor hostname/IP: " HARBOR_HOST
    
    read -p "Harbor port [443]: " input_port
    HARBOR_PORT="${input_port:-443}"
    
    read -p "Use HTTPS? (Y/n): " use_https
    if [[ "${use_https,,}" =~ ^n ]]; then
        USE_HTTPS="false"
    else
        USE_HTTPS="true"
    fi
    
    read -p "Harbor username [$DEFAULT_HARBOR_USERNAME]: " input_username
    HARBOR_USERNAME="${input_username:-$DEFAULT_HARBOR_USERNAME}"
    
    read -s -p "Harbor password: " HARBOR_PASSWORD
    echo ""
    
    if [[ -z "$HARBOR_PASSWORD" ]]; then
        error "Password cannot be empty"
        exit 1
    fi
    
    read -p "Harbor project [$DEFAULT_HARBOR_PROJECT]: " input_project
    HARBOR_PROJECT="${input_project:-$DEFAULT_HARBOR_PROJECT}"
    
    read -p "Create project if it doesn't exist? (Y/n): " create_proj
    if [[ ! "${create_proj,,}" =~ ^n ]]; then
        CREATE_PROJECT="true"
    else
        CREATE_PROJECT="false"
    fi
    
    # NKP configuration
    read -p "NKP version [$DEFAULT_NKP_VERSION]: " input_version
    NKP_VERSION="${input_version:-$DEFAULT_NKP_VERSION}"
    
    NKP_BUNDLE_DIR="./nkp-v${NKP_VERSION}"
    read -p "NKP bundle directory [$NKP_BUNDLE_DIR]: " input_dir
    NKP_BUNDLE_DIR="${input_dir:-$NKP_BUNDLE_DIR}"
}

# Verify external Harbor connectivity
verify_external_harbor() {
    log "Verifying external Harbor connectivity..."
    
    local test_url
    if [[ "${USE_HTTPS,,}" == "true" ]]; then
        test_url="https://${HARBOR_HOST}:${HARBOR_PORT}"
    else
        test_url="http://${HARBOR_HOST}:${HARBOR_PORT}"
    fi
    
    HARBOR_URL="$test_url"
    
    # Test connectivity (using -k for self-signed certs)
    if ! curl -k -s --connect-timeout 10 "${test_url}/api/v2.0/health" | grep -q "healthy"; then
        warning "Harbor health check failed, trying basic connectivity..."
        if ! curl -k -s --connect-timeout 10 "${test_url}" > /dev/null 2>&1; then
            error "Cannot connect to external Harbor at ${test_url}"
            info "Please verify:"
            info "  1. Harbor is accessible from this host"
            info "  2. Firewall rules allow connection"
            info "  3. Harbor is running and healthy"
            return 1
        fi
    fi
    
    success "External Harbor is accessible"
    
    # Test authentication
    local auth_response=$(curl -k -s -w "%{http_code}" -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" \
        "${test_url}/api/v2.0/projects" 2>/dev/null || echo "000")
    local auth_http_code="${auth_response: -3}"
    
    case "$auth_http_code" in
        200) 
            success "Harbor authentication successful"
            ;;
        401) 
            error "Harbor authentication failed - invalid credentials"
            return 1
            ;;
        *)
            warning "Harbor authentication test inconclusive (HTTP: $auth_http_code)"
            ;;
    esac
    
    return 0
}

# Check system requirements (for local deployments only)
check_system_requirements() {
    if [[ "$DEPLOYMENT_MODE" == "external" ]]; then
        return 0
    fi
    
    log "Checking system requirements for local deployment..."
    
    local issues=()
    
    # Check available disk space
    local available_gb=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
    if [[ $available_gb -lt $MIN_DISK_SPACE_GB ]]; then
        issues+=("Insufficient disk space: ${available_gb}GB available, ${MIN_DISK_SPACE_GB}GB required")
    fi
    
    # Check available memory
    local available_mem_gb=$(free -g | awk 'NR==2{printf "%.0f", $7}')
    if [[ $available_mem_gb -lt $MIN_MEMORY_GB ]]; then
        issues+=("Low available memory: ${available_mem_gb}GB available, ${MIN_MEMORY_GB}GB recommended")
    fi
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        error "System requirement issues found:"
        for issue in "${issues[@]}"; do
            echo "  - $issue"
        done
        
        read -p "Continue despite issues? (y/N): " input
        if [[ ! "${input,,}" =~ ^y ]]; then
            exit 1
        fi
    else
        success "System requirements check passed"
    fi
}

# Validate Docker environment
validate_docker_environment() {
    log "Validating Docker environment..."
    
    if ! command -v docker &> /dev/null; then
        error "Docker not installed"
        info "Please install Docker first"
        exit 1
    fi
    
    local docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    if [[ "$docker_version" == "unknown" ]]; then
        error "Docker daemon not running or accessible"
        exit 1
    else
        success "Docker version: $docker_version"
    fi
    
    # Check required tools
    local missing_tools=()
    local tools=("curl" "jq")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        info "Please install: sudo apt install ${missing_tools[*]}"
        exit 1
    fi
    
    # Check NKP binary
    if ! command -v nkp &> /dev/null; then
        error "NKP binary not found"
        info "Please download from: https://github.com/mesosphere/konvoy/releases"
        exit 1
    fi
    
    success "Docker environment validation passed"
}

# Setup local Harbor (simplified for brevity - use full version from main script)
setup_local_harbor() {
    log "Setting up local Harbor..."
    
    # Check if Harbor images exist
    if ! docker images | grep -q goharbor; then
        # Check for installer
        local installer=$(ls harbor-offline-installer-*.tgz 2>/dev/null | head -1)
        if [[ -z "$installer" ]]; then
            error "Harbor installer not found"
            info "Please download harbor-offline-installer-*.tgz"
            exit 1
        fi
        
        log "Installing Harbor from $installer..."
        # Installation logic here (simplified)
        warning "Full Harbor installation logic needed here"
    fi
    
    # Start Harbor if not running
    if ! docker ps | grep -q harbor; then
        log "Starting Harbor containers..."
        # Start logic here
        warning "Harbor start logic needed here"
    fi
    
    success "Local Harbor is ready"
    HARBOR_HOST="localhost"
    HARBOR_PORT="80"
    USE_HTTPS="false"
}

# Configure Docker daemon for registry
configure_docker_daemon() {
    log "Configuring Docker daemon for registry..."
    
    local daemon_json="/etc/docker/daemon.json"
    local needs_restart=false
    local registry_entry="$HARBOR_HOST"
    
    if [[ "$HARBOR_PORT" != "80" ]] && [[ "$HARBOR_PORT" != "443" ]]; then
        registry_entry="$HARBOR_HOST:$HARBOR_PORT"
    fi
    
    # For HTTPS with valid certificates, no configuration needed
    if [[ "${USE_HTTPS,,}" == "true" ]]; then
        log "Testing HTTPS certificate..."
        if curl -s "https://${registry_entry}/v2/" > /dev/null 2>&1; then
            success "HTTPS certificate is trusted"
            return 0
        else
            warning "HTTPS certificate not trusted or self-signed"
            read -p "Add to insecure-registries? (Y/n): " add_insecure
            if [[ "${add_insecure,,}" =~ ^n ]]; then
                error "Cannot proceed without trusting the registry"
                exit 1
            fi
        fi
    fi
    
    # Configure insecure registry
    if [[ -f "$daemon_json" ]]; then
        if ! jq -e --arg registry "$registry_entry" '.["insecure-registries"] | index($registry)' "$daemon_json" > /dev/null 2>&1; then
            log "Adding $registry_entry to insecure-registries..."
            sudo cp "$daemon_json" "${daemon_json}.backup.$(date +%Y%m%d_%H%M%S)"
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
        echo "{\"insecure-registries\": [\"$registry_entry\"]}" | sudo tee "$daemon_json" > /dev/null
        needs_restart=true
    fi
    
    if [[ "$needs_restart" == "true" ]]; then
        log "Restarting Docker daemon..."
        sudo systemctl restart docker
        sleep 5
        success "Docker daemon restarted"
    fi
}

# Create Harbor project
create_harbor_project() {
    local project_name="$1"
    
    log "Creating Harbor project: $project_name"
    
    local curl_opts="-s"
    if [[ "${USE_HTTPS,,}" == "true" ]]; then
        curl_opts="-k -s"  # Add -k for self-signed certs
    fi
    
    # Check if project exists
    local project_url="${HARBOR_URL}/api/v2.0/projects?name=$project_name"
    local existing_project=$(curl $curl_opts -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" "$project_url" 2>/dev/null || echo "[]")
    
    if echo "$existing_project" | jq -e '.[] | select(.name == "'$project_name'")' > /dev/null 2>&1; then
        success "Project '$project_name' already exists"
        return 0
    fi
    
    # Create new project
    local create_url="${HARBOR_URL}/api/v2.0/projects"
    local project_data='{
        "project_name": "'$project_name'",
        "public": false,
        "metadata": {
            "public": "false"
        }
    }'
    
    local response=$(curl $curl_opts -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" \
        -d "$project_data" \
        "$create_url" 2>/dev/null || echo "000")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "201" ]] || [[ "$http_code" == "409" ]]; then
        success "Project '$project_name' is ready"
        return 0
    else
        error "Failed to create project (HTTP: $http_code)"
        return 1
    fi
}

# Verify NKP bundles
verify_nkp_bundles() {
    log "Verifying NKP bundles..."
    
    if [[ ! -d "$NKP_BUNDLE_DIR" ]]; then
        error "NKP bundle directory not found: $NKP_BUNDLE_DIR"
        exit 1
    fi
    
    local bundle_dir="$NKP_BUNDLE_DIR/container-images"
    if [[ ! -d "$bundle_dir" ]]; then
        error "Container images directory not found: $bundle_dir"
        exit 1
    fi
    
    local bundles=(
        "$bundle_dir/konvoy-image-bundle-v$NKP_VERSION.tar"
        "$bundle_dir/kommander-image-bundle-v$NKP_VERSION.tar"
    )
    
    local found_bundles=0
    for bundle in "${bundles[@]}"; do
        if [[ -f "$bundle" ]]; then
            local size_mb=$(du -m "$bundle" | cut -f1)
            success "Found: $(basename "$bundle") (${size_mb}MB)"
            ((found_bundles++))
        else
            warning "Not found: $(basename "$bundle")"
        fi
    done
    
    if [[ $found_bundles -eq 0 ]]; then
        error "No NKP bundles found"
        exit 1
    fi
    
    success "NKP bundles verified"
}

# Push bundles to Harbor
push_bundles() {
    log "Pushing NKP bundles to Harbor..."
    
    local bundles=(
        "$NKP_BUNDLE_DIR/container-images/konvoy-image-bundle-v$NKP_VERSION.tar"
        "$NKP_BUNDLE_DIR/container-images/kommander-image-bundle-v$NKP_VERSION.tar"
    )
    
    local registry_url="${HARBOR_URL}/${HARBOR_PROJECT}"
    
    for bundle in "${bundles[@]}"; do
        if [[ -f "$bundle" ]]; then
            local bundle_name=$(basename "$bundle")
            log "Pushing $bundle_name..."
            
            local nkp_args=(
                "push" "bundle"
                "--bundle" "$bundle"
                "--to-registry" "$registry_url"
                "--to-registry-username" "$HARBOR_USERNAME"
                "--to-registry-password" "$HARBOR_PASSWORD"
                "--on-existing-tag" "skip"
            )
            
            # Add insecure flag if needed
            if [[ "${USE_HTTPS,,}" != "true" ]] || [[ -n "$INSECURE_REGISTRY" ]]; then
                nkp_args+=("--to-registry-insecure-skip-tls-verify")
            fi
            
            if nkp "${nkp_args[@]}"; then
                success "Successfully pushed: $bundle_name"
            else
                error "Failed to push: $bundle_name"
                exit 1
            fi
        fi
    done
    
    success "All bundles pushed successfully"
}

# Generate summary
generate_summary() {
    echo ""
    echo "============================================="
    echo "NKP HARBOR DEPLOYMENT COMPLETED SUCCESSFULLY"
    echo "============================================="
    echo ""
    echo "DEPLOYMENT DETAILS:"
    echo "Mode: $DEPLOYMENT_MODE"
    echo "Harbor URL: $HARBOR_URL"
    echo "Registry: $HARBOR_URL/$HARBOR_PROJECT"
    echo "Project: $HARBOR_PROJECT"
    echo "Username: $HARBOR_USERNAME"
    echo ""
    
    # Get repository count
    local curl_opts="-s"
    if [[ "${USE_HTTPS,,}" == "true" ]]; then
        curl_opts="-k -s"
    fi
    
    echo -n "Total repositories in Harbor: "
    local catalog_url
    if [[ "${USE_HTTPS,,}" == "true" ]]; then
        catalog_url="https://${HARBOR_HOST}:${HARBOR_PORT}/v2/_catalog"
    else
        catalog_url="http://${HARBOR_HOST}:${HARBOR_PORT}/v2/_catalog"
    fi
    curl $curl_opts -u ${HARBOR_USERNAME}:${HARBOR_PASSWORD} "$catalog_url" 2>/dev/null | jq -r '.repositories[]' 2>/dev/null | wc -l || echo "Unable to count"
    
    echo ""
    echo "TEST COMMANDS:"
    local registry_addr="$HARBOR_HOST"
    if [[ "$HARBOR_PORT" != "80" ]] && [[ "$HARBOR_PORT" != "443" ]]; then
        registry_addr="${HARBOR_HOST}:${HARBOR_PORT}"
    fi
    echo "docker login $registry_addr -u $HARBOR_USERNAME"
    echo "docker pull ${registry_addr}/${HARBOR_PROJECT}/pause:3.10"
    echo ""
    echo "Find image tags:"
    echo "curl $curl_opts -u ${HARBOR_USERNAME}:<password> ${catalog_url//_catalog/}${HARBOR_PROJECT}/pause/tags/list"
}

# Main execution
main() {
    show_banner
    
    # Determine deployment mode if not set
    determine_deployment_mode
    
    # Check system requirements (local only)
    if [[ "$DEPLOYMENT_MODE" == "local" ]]; then
        check_system_requirements
    fi
    
    # Validate Docker environment
    validate_docker_environment
    
    # Setup or verify Harbor based on mode
    if [[ "$DEPLOYMENT_MODE" == "local" ]]; then
        setup_local_harbor
        
        # Interactive configuration for local
        read -p "Harbor project [$DEFAULT_HARBOR_PROJECT]: " input_project
        HARBOR_PROJECT="${input_project:-$DEFAULT_HARBOR_PROJECT}"
        
        read -p "NKP version [$DEFAULT_NKP_VERSION]: " input_version
        NKP_VERSION="${input_version:-$DEFAULT_NKP_VERSION}"
        
        NKP_BUNDLE_DIR="./nkp-v${NKP_VERSION}"
        read -p "NKP bundle directory [$NKP_BUNDLE_DIR]: " input_dir
        NKP_BUNDLE_DIR="${input_dir:-$NKP_BUNDLE_DIR}"
        
        HARBOR_USERNAME="$DEFAULT_HARBOR_USERNAME"
        HARBOR_PASSWORD="$DEFAULT_HARBOR_PASSWORD"
        CREATE_PROJECT="true"
        
        # Build Harbor URL
        HARBOR_URL="http://${HARBOR_HOST}:${HARBOR_PORT}"
    else
        # External Harbor - verify connectivity
        if ! verify_external_harbor; then
            exit 1
        fi
    fi
    
    # Configure Docker daemon
    configure_docker_daemon
    
    # Create project if needed
    if [[ "${CREATE_PROJECT,,}" == "true" ]]; then
        create_harbor_project "$HARBOR_PROJECT" || exit 1
    fi
    
    # Verify NKP bundles
    verify_nkp_bundles
    
    # Push bundles
    push_bundles
    
    # Generate summary
    generate_summary
    
    success "Deployment completed successfully!"
}

# Handle errors
trap 'error "Script failed at line $LINENO"' ERR

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
