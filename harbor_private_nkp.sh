#!/bin/bash
# Portable NKP Harbor Deployment Script

set -e

# Version and metadata
SCRIPT_VERSION="1.0.1"
SCRIPT_NAME="Portable NKP Harbor Deployment"

# Default configuration - can be overridden
DEFAULT_HARBOR_PORT="80"
DEFAULT_HARBOR_USERNAME="admin"
DEFAULT_HARBOR_PASSWORD="Harbor12345"
DEFAULT_NKP_VERSION="2.15.0"
DEFAULT_HARBOR_PROJECT="library"

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
success() { echo -e "${GREEN}[✅]${NC} $*"; }
warning() { echo -e "${YELLOW}[⚠️]${NC} $*"; }
error() { echo -e "${RED}[❌]${NC} $*"; }
info() { echo -e "${BLUE}[ℹ️]${NC} $*"; }

show_banner() {
    echo -e "${PURPLE}"
    echo "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀"
    echo "🚀                                                                    🚀"
    echo "🚀    $SCRIPT_NAME v$SCRIPT_VERSION                        🚀"
    echo "🚀    Portable across environments and configurations               🚀"
    echo "🚀                                                                    🚀"
    echo "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀"
    echo -e "${NC}"
}

# Configuration file support
CONFIG_FILE=""
load_config_file() {
    local config_file="$1"
    if [[ -f "$config_file" ]]; then
        info "Loading configuration from: $config_file"
        # Source the config file safely
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            # Remove quotes from value
            value=$(echo "$value" | sed 's/^"//;s/"$//')
            
            case "$key" in
                HARBOR_HOST) HARBOR_HOST="$value" ;;
                HARBOR_PORT) HARBOR_PORT="$value" ;;
                HARBOR_USERNAME) HARBOR_USERNAME="$value" ;;
                HARBOR_PASSWORD) HARBOR_PASSWORD="$value" ;;
                HARBOR_PROJECT) HARBOR_PROJECT="$value" ;;
                NKP_VERSION) NKP_VERSION="$value" ;;
                NKP_BUNDLE_DIR) NKP_BUNDLE_DIR="$value" ;;
                USE_HTTPS) USE_HTTPS="$value" ;;
            esac
        done < "$config_file"
        success "Configuration loaded from file"
    else
        warning "Configuration file not found: $config_file"
    fi
}

# Auto-detect environment
auto_detect_environment() {
    log "Auto-detecting environment..."
    
    # Detect Harbor host
    if [[ -z "${HARBOR_HOST:-}" ]]; then
        # Try common Harbor hostnames
        local possible_hosts=(
            "harbor.local"
            "registry.local" 
            "harbor"
            "registry"
            "localhost"
        )
        
        for host in "${possible_hosts[@]}"; do
            if ping -c 1 -W 1 "$host" &>/dev/null; then
                HARBOR_HOST="$host"
                info "Auto-detected Harbor host: $host"
                break
            fi
        done
        
        # Check for common Harbor ports
        if [[ -n "${HARBOR_HOST:-}" ]]; then
            for port in 80 443 8080 8443; do
                if nc -z "$HARBOR_HOST" "$port" 2>/dev/null; then
                    HARBOR_PORT="$port"
                    info "Auto-detected Harbor port: $port"
                    break
                fi
            done
        fi
    fi
    
    # Detect NKP bundle directory
    if [[ -z "${NKP_BUNDLE_DIR:-}" ]]; then
        local possible_dirs=(
            "./nkp-v${NKP_VERSION:-$DEFAULT_NKP_VERSION}"
            "./nkp"
            "./nkp-bundles"
            "../nkp-v${NKP_VERSION:-$DEFAULT_NKP_VERSION}"
            "/opt/nkp"
            "$HOME/nkp"
        )
        
        for dir in "${possible_dirs[@]}"; do
            if [[ -d "$dir" ]] && [[ -d "$dir/container-images" ]]; then
                NKP_BUNDLE_DIR="$dir"
                info "Auto-detected NKP bundle directory: $dir"
                break
            fi
        done
    fi
    
    # Auto-detect NKP version from bundle files
    if [[ -n "${NKP_BUNDLE_DIR:-}" ]] && [[ -z "${NKP_VERSION:-}" ]]; then
        local bundle_file=$(find "$NKP_BUNDLE_DIR" -name "*konvoy-image-bundle-v*.tar" | head -1)
        if [[ -n "$bundle_file" ]]; then
            NKP_VERSION=$(basename "$bundle_file" | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' | sed 's/^v//')
            info "Auto-detected NKP version: $NKP_VERSION"
        fi
    fi
}

# Create Harbor project
create_harbor_project() {
    local project_name="$1"
    
    log "Creating Harbor project: $project_name"
    
    # Check if project already exists
    local project_url="$HARBOR_URL/api/v2.0/projects?name=$project_name"
    local existing_project=$(curl -s -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" "$project_url")
    
    if echo "$existing_project" | jq -e '.[] | select(.name == "'$project_name'")' > /dev/null 2>&1; then
        success "Project '$project_name' already exists"
        return 0
    fi
    
    # Create new project
    local create_url="$HARBOR_URL/api/v2.0/projects"
    local project_data='{
        "project_name": "'$project_name'",
        "public": false,
        "metadata": {
            "public": "false"
        }
    }'
    
    local response=$(curl -s -w "%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" \
        -d "$project_data" \
        "$create_url")
    
    local http_code="${response: -3}"
    
    if [[ "$http_code" == "201" ]]; then
        success "Project '$project_name' created successfully"
    else
        error "Failed to create project '$project_name' (HTTP: $http_code)"
        return 1
    fi
}

# Interactive configuration
interactive_config() {
    echo ""
    info "Interactive Configuration"
    echo "=========================="
    
    # Harbor Host
    if [[ -z "${HARBOR_HOST:-}" ]]; then
        read -p "Enter Harbor hostname or IP: " HARBOR_HOST
    else
        read -p "Harbor hostname [$HARBOR_HOST]: " input
        HARBOR_HOST="${input:-$HARBOR_HOST}"
    fi
    
    # Harbor Port
    if [[ -z "${HARBOR_PORT:-}" ]]; then
        HARBOR_PORT="$DEFAULT_HARBOR_PORT"
    fi
    read -p "Harbor port [$HARBOR_PORT]: " input
    HARBOR_PORT="${input:-$HARBOR_PORT}"
    
    # Determine protocol
    if [[ "$HARBOR_PORT" == "443" ]]; then
        USE_HTTPS="true"
    else
        read -p "Use HTTPS? (y/N): " input
        if [[ "${input,,}" =~ ^y ]]; then
            USE_HTTPS="true"
        else
            USE_HTTPS="false"
        fi
    fi
    
    # Harbor credentials
    read -p "Harbor username [$DEFAULT_HARBOR_USERNAME]: " input
    HARBOR_USERNAME="${input:-$DEFAULT_HARBOR_USERNAME}"
    
    read -s -p "Harbor password [$DEFAULT_HARBOR_PASSWORD]: " input
    echo ""
    HARBOR_PASSWORD="${input:-$DEFAULT_HARBOR_PASSWORD}"
    
    # Harbor project configuration
    echo ""
    info "Harbor Project Configuration"
    echo "============================"
    read -p "Harbor project name [$DEFAULT_HARBOR_PROJECT]: " input
    HARBOR_PROJECT="${input:-$DEFAULT_HARBOR_PROJECT}"
    
    if [[ "$HARBOR_PROJECT" != "library" ]]; then
        read -p "Create new project '$HARBOR_PROJECT' if it doesn't exist? (Y/n): " input
        if [[ ! "${input,,}" =~ ^n ]]; then
            CREATE_PROJECT="true"
        else
            CREATE_PROJECT="false"
        fi
    else
        CREATE_PROJECT="false"
    fi
    
    # NKP Version
    read -p "NKP version [$DEFAULT_NKP_VERSION]: " input
    NKP_VERSION="${input:-$DEFAULT_NKP_VERSION}"
    
    # NKP Bundle Directory
    if [[ -z "${NKP_BUNDLE_DIR:-}" ]]; then
        NKP_BUNDLE_DIR="./nkp-v$NKP_VERSION"
    fi
    read -p "NKP bundle directory [$NKP_BUNDLE_DIR]: " input
    NKP_BUNDLE_DIR="${input:-$NKP_BUNDLE_DIR}"
}

# Generate configuration file
generate_config_file() {
    local config_file="${1:-harbor-nkp-config.conf}"
    
    cat > "$config_file" << EOF
# NKP Harbor Deployment Configuration
# Generated on $(date)

# Harbor Configuration
HARBOR_HOST="$HARBOR_HOST"
HARBOR_PORT="$HARBOR_PORT"
HARBOR_USERNAME="$HARBOR_USERNAME"
HARBOR_PASSWORD="$HARBOR_PASSWORD"
HARBOR_PROJECT="$HARBOR_PROJECT"
USE_HTTPS="$USE_HTTPS"

# NKP Configuration  
NKP_VERSION="$NKP_VERSION"
NKP_BUNDLE_DIR="$NKP_BUNDLE_DIR"

# Optional: Additional settings
# DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
# SKIP_VERIFICATION="false"
# VERBOSE_OUTPUT="true"
EOF

    success "Configuration saved to: $config_file"
    info "You can edit this file and use it with: $0 --config $config_file"
}

# Build Harbor URL
build_harbor_url() {
    local protocol="http"
    if [[ "${USE_HTTPS,,}" == "true" ]]; then
        protocol="https"
    fi
    
    if [[ "$HARBOR_PORT" == "80" && "$protocol" == "http" ]] || [[ "$HARBOR_PORT" == "443" && "$protocol" == "https" ]]; then
        HARBOR_URL="$protocol://$HARBOR_HOST"
    else
        HARBOR_URL="$protocol://$HARBOR_HOST:$HARBOR_PORT"
    fi
}

# Verify prerequisites
verify_prerequisites() {
    log "Verifying prerequisites..."
    
    local missing_tools=()
    
    # Check required tools
    for tool in docker curl jq nkp; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        info "Please install the missing tools and try again."
        return 1
    fi
    
    success "All required tools are available"
}

# Verify Harbor connectivity
verify_harbor() {
    log "Verifying Harbor connectivity..."
    
    build_harbor_url
    
    local health_url="$HARBOR_URL/api/v2.0/health"
    if ! curl -s --connect-timeout 10 "$health_url" | grep -q "healthy"; then
        error "Harbor is not healthy or not accessible at: $HARBOR_URL"
        info "Please check:"
        info "  - Harbor is running and accessible"
        info "  - Hostname/IP is correct: $HARBOR_HOST"
        info "  - Port is correct: $HARBOR_PORT"
        info "  - Protocol is correct: $(format_protocol)"
        return 1
    fi
    
    success "Harbor is healthy and accessible"
    
    # Test authentication
    if ! curl -s -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" "$HARBOR_URL/api/v2.0/projects" > /dev/null; then
        error "Harbor authentication failed"
        info "Please check username and password"
        return 1
    fi
    
    success "Harbor authentication successful"
}

# Format protocol display
format_protocol() {
    if [[ "${USE_HTTPS,,}" == "true" ]]; then
        echo "HTTPS"
    else
        echo "HTTP"
    fi
}

# Verify NKP bundles
verify_nkp_bundles() {
    log "Verifying NKP bundles..."
    
    if [[ ! -d "$NKP_BUNDLE_DIR" ]]; then
        error "NKP bundle directory not found: $NKP_BUNDLE_DIR"
        return 1
    fi
    
    local bundle_dir="$NKP_BUNDLE_DIR/container-images"
    if [[ ! -d "$bundle_dir" ]]; then
        error "Container images directory not found: $bundle_dir"
        return 1
    fi
    
    local bundles=(
        "$bundle_dir/konvoy-image-bundle-v$NKP_VERSION.tar"
        "$bundle_dir/kommander-image-bundle-v$NKP_VERSION.tar"
    )
    
    local found_bundles=0
    for bundle in "${bundles[@]}"; do
        if [[ -f "$bundle" ]]; then
            success "Found bundle: $(basename "$bundle")"
            ((found_bundles++))
        else
            warning "Bundle not found: $(basename "$bundle")"
        fi
    done
    
    if [[ $found_bundles -eq 0 ]]; then
        error "No NKP bundles found in: $bundle_dir"
        return 1
    fi
    
    success "NKP bundles verified ($found_bundles found)"
}

# Configure Docker daemon for insecure registry
configure_docker_daemon() {
    log "Configuring Docker daemon for insecure registry..."
    
    local daemon_json="/etc/docker/daemon.json"
    local needs_restart=false
    
    # Check if already configured
    if [[ -f "$daemon_json" ]] && grep -q "$HARBOR_HOST" "$daemon_json"; then
        success "Docker daemon already configured for Harbor registry"
        return 0
    fi
    
    # Only configure for HTTP (insecure) registries
    if [[ "${USE_HTTPS,,}" != "true" ]]; then
        warning "HTTP registry detected - Docker daemon configuration may be needed"
        
        if [[ "$EUID" -eq 0 ]] || groups | grep -q docker; then
            info "Configuring Docker daemon for insecure registry..."
            
            # Backup existing config
            if [[ -f "$daemon_json" ]]; then
                sudo cp "$daemon_json" "${daemon_json}.backup.$(date +%Y%m%d_%H%M%S)"
            fi
            
            # Create or update daemon.json
            local registry_entry="$HARBOR_HOST"
            if [[ "$HARBOR_PORT" != "80" ]]; then
                registry_entry="$HARBOR_HOST:$HARBOR_PORT"
            fi
            
            if [[ -f "$daemon_json" ]]; then
                # Update existing file
                sudo jq --arg registry "$registry_entry" \
                    '.["insecure-registries"] = (.["insecure-registries"] // []) + [$registry] | .["insecure-registries"] |= unique' \
                    "$daemon_json" > /tmp/daemon.json.tmp
                sudo mv /tmp/daemon.json.tmp "$daemon_json"
            else
                # Create new file
                echo "{\"insecure-registries\": [\"$registry_entry\"]}" | sudo tee "$daemon_json" > /dev/null
            fi
            
            needs_restart=true
        else
            warning "Cannot configure Docker daemon (no sudo/docker group access)"
            info "Please manually add to $daemon_json:"
            info "  {\"insecure-registries\": [\"$HARBOR_HOST:$HARBOR_PORT\"]}"
        fi
    fi
    
    if [[ "$needs_restart" == "true" ]]; then
        info "Restarting Docker daemon..."
        sudo systemctl restart docker
        sleep 3
        success "Docker daemon restarted"
    fi
}

# Push bundles using the specified project namespace
push_bundles() {
    log "Pushing NKP bundles using /$HARBOR_PROJECT namespace..."
    
    local bundles=(
        "$NKP_BUNDLE_DIR/container-images/konvoy-image-bundle-v$NKP_VERSION.tar"
        "$NKP_BUNDLE_DIR/container-images/kommander-image-bundle-v$NKP_VERSION.tar"
    )
    
    local success_count=0
    local total_images=0
    
    # Use the specified project namespace
    local registry_url="$HARBOR_URL/$HARBOR_PROJECT"
    
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
            
            # Add insecure flag for HTTP
            if [[ "${USE_HTTPS,,}" != "true" ]]; then
                nkp_args+=("--to-registry-insecure-skip-tls-verify")
            fi
            
            if nkp "${nkp_args[@]}"; then
                success "Successfully pushed: $bundle_name"
                ((success_count++))
                
                # Estimate image count
                if [[ "$bundle_name" == *"konvoy"* ]]; then
                    total_images=$((total_images + 110))
                elif [[ "$bundle_name" == *"kommander"* ]]; then
                    total_images=$((total_images + 135))
                fi
            else
                error "Failed to push: $bundle_name"
                return 1
            fi
        fi
    done
    
    success "Bundle push complete: $success_count bundles, ~$total_images images"
}

# Generate deployment summary
generate_summary() {
    log "Generating deployment summary..."
    
    echo ""
    echo "🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉"
    echo "🎉                                                                    🎉"
    echo "🎉    ✅ NKP HARBOR DEPLOYMENT COMPLETED SUCCESSFULLY! ✅              🎉"
    echo "🎉                                                                    🎉"
    echo "🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉🎉"
    echo ""
    echo "📋 DEPLOYMENT SUMMARY"
    echo "===================="
    echo "Harbor URL: $HARBOR_URL"
    echo "Registry URL: $HARBOR_URL/$HARBOR_PROJECT"
    echo "Project: $HARBOR_PROJECT"
    echo "Username: $HARBOR_USERNAME"
    echo "Password: $HARBOR_PASSWORD"
    echo "Protocol: $(format_protocol)"
    echo ""
    echo "🌐 WEB UI ACCESS:"
    echo "URL: $HARBOR_URL"
    echo "Username: $HARBOR_USERNAME"
    echo "Password: $HARBOR_PASSWORD"
    echo ""
    echo "🎉 YOUR PRIVATE REGISTRY IS READY FOR NKP DEPLOYMENT! 🎉"
}

# Show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --config FILE       Load configuration from file"
    echo "  --auto              Auto-detect environment (no interactive prompts)"
    echo "  --generate-config   Generate configuration file and exit"
    echo "  --verify-only       Only verify environment and connectivity"
    echo "  --push-only         Only push bundles (skip verification)"
    echo "  --help              Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  HARBOR_HOST         Harbor hostname or IP"
    echo "  HARBOR_PORT         Harbor port (default: 80)"
    echo "  HARBOR_USERNAME     Harbor username (default: admin)"
    echo "  HARBOR_PASSWORD     Harbor password (default: Harbor12345)"
    echo "  HARBOR_PROJECT      Harbor project name (default: library)"
    echo "  NKP_VERSION         NKP version (default: 2.15.0)"
    echo "  NKP_BUNDLE_DIR      NKP bundle directory"
    echo "  USE_HTTPS           Use HTTPS (true/false)"
    echo ""
    echo "Examples:"
    echo "  $0 --auto                           # Auto-detect and run"
    echo "  $0 --config my-config.conf          # Use configuration file"
    echo "  HARBOR_HOST=harbor.local $0 --auto  # Set host via environment"
    echo "  $0 --generate-config                # Generate config file"
}

# Main execution
main() {
    local auto_mode=false
    local verify_only=false
    local push_only=false
    local generate_config_only=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --auto)
                auto_mode=true
                shift
                ;;
            --verify-only)
                verify_only=true
                shift
                ;;
            --push-only)
                push_only=true
                shift
                ;;
            --generate-config)
                generate_config_only=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    show_banner
    
    # Load configuration file if provided
    if [[ -n "$CONFIG_FILE" ]]; then
        load_config_file "$CONFIG_FILE"
    fi
    
    # Auto-detect environment
    auto_detect_environment
    
    # Interactive configuration if not in auto mode
    if [[ "$auto_mode" != "true" ]] && [[ "$generate_config_only" != "true" ]]; then
        interactive_config
    fi
    
    # Generate config and exit if requested
    if [[ "$generate_config_only" == "true" ]]; then
        if [[ "$auto_mode" != "true" ]]; then
            interactive_config
        fi
        generate_config_file
        exit 0
    fi
    
    # Set defaults for any missing values
    HARBOR_HOST="${HARBOR_HOST:-localhost}"
    HARBOR_PORT="${HARBOR_PORT:-$DEFAULT_HARBOR_PORT}"
    HARBOR_USERNAME="${HARBOR_USERNAME:-$DEFAULT_HARBOR_USERNAME}"
    HARBOR_PASSWORD="${HARBOR_PASSWORD:-$DEFAULT_HARBOR_PASSWORD}"
    HARBOR_PROJECT="${HARBOR_PROJECT:-$DEFAULT_HARBOR_PROJECT}"
    NKP_VERSION="${NKP_VERSION:-$DEFAULT_NKP_VERSION}"
    NKP_BUNDLE_DIR="${NKP_BUNDLE_DIR:-./nkp-v$NKP_VERSION}"
    USE_HTTPS="${USE_HTTPS:-false}"
    CREATE_PROJECT="${CREATE_PROJECT:-false}"
    
    # Verify prerequisites
    verify_prerequisites || exit 1
    
    # Verify Harbor
    verify_harbor || exit 1
    
    # Create Harbor project if needed
    if [[ "${CREATE_PROJECT,,}" == "true" ]] && [[ "$HARBOR_PROJECT" != "library" ]]; then
        create_harbor_project "$HARBOR_PROJECT" || exit 1
    fi
    
    # Verify NKP bundles
    verify_nkp_bundles || exit 1
    
    if [[ "$verify_only" == "true" ]]; then
        success "Verification completed successfully!"
        exit 0
    fi
    
    # Configure Docker daemon
    configure_docker_daemon
    
    # Push bundles
    if [[ "$push_only" != "false" ]] || [[ "$verify_only" != "true" ]]; then
        push_bundles || exit 1
    fi
    
    # Generate summary
    generate_summary
    
    success "Deployment completed successfully!"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
