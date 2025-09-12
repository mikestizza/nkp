#!/bin/bash
#Portable NKP Harbor Deployment Script 

set -e

# Version and metadata
SCRIPT_VERSION="1.1.1"
SCRIPT_NAME="Enhanced NKP Harbor Deployment"

# Default configuration - can be overridden
DEFAULT_HARBOR_PORT="80"
DEFAULT_HARBOR_USERNAME="admin"
DEFAULT_HARBOR_PASSWORD="Harbor12345"
DEFAULT_NKP_VERSION="2.15.0"
DEFAULT_HARBOR_PROJECT="nkp"

# Minimum system requirements
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
success() { echo -e "${GREEN}[✅]${NC} $*"; }
warning() { echo -e "${YELLOW}[⚠️]${NC} $*"; }
error() { echo -e "${RED}[❌]${NC} $*"; }
info() { echo -e "${BLUE}[ℹ️]${NC} $*"; }

show_banner() {
    echo -e "${PURPLE}"
    echo "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀"
    echo "🚀                                                                    🚀"
    echo "🚀    $SCRIPT_NAME v$SCRIPT_VERSION                        🚀"
    echo "🚀    Enhanced problem detection and auto-resolution               🚀"
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

# Enhanced system requirements checking with auto-setup
check_system_requirements() {
    log "Checking system requirements..."
    
    local issues=()
    local auto_fixes=()
    
    # Check available disk space
    local available_gb=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
    if [[ $available_gb -lt $MIN_DISK_SPACE_GB ]]; then
        issues+=("Insufficient disk space: ${available_gb}GB available, ${MIN_DISK_SPACE_GB}GB required")
        
        # Check if we can expand disk space
        if command -v lvextend &> /dev/null && sudo vgs &>/dev/null; then
            local vg_free=$(sudo vgs --noheadings -o vg_free --units g | grep -o '[0-9.]*' | head -1)
            if [[ -n "$vg_free" ]] && (( $(echo "$vg_free > 10" | bc -l 2>/dev/null || echo 0) )); then
                auto_fixes+=("expand_lvm:Expand LVM volume (+${vg_free}GB available)")
            fi
        fi
        
        # Always offer cleanup
        auto_fixes+=("cleanup_docker:Clean up Docker resources")
        auto_fixes+=("cleanup_system:Clean up system packages")
    fi
    
    # Check available memory
    local available_mem_gb=$(free -g | awk 'NR==2{printf "%.0f", $7}')
    if [[ $available_mem_gb -lt $MIN_MEMORY_GB ]]; then
        issues+=("Low available memory: ${available_mem_gb}GB available, ${MIN_MEMORY_GB}GB recommended")
        auto_fixes+=("show_memory_tips:Show memory optimization tips")
    fi
    
    # Check if running as root (which can cause permission issues)
    if [[ "$EUID" -eq 0 ]]; then
        warning "Running as root. This may cause permission issues with Docker."
        info "Consider running as a non-root user in the docker group."
    fi
    
    # Check Docker group membership
    if ! groups | grep -q docker && [[ "$EUID" -ne 0 ]]; then
        issues+=("User not in docker group")
        auto_fixes+=("add_docker_group:Add current user to docker group")
    fi
    
    # Check for swap space (helpful for memory-constrained systems)
    local swap_mb=$(free -m | awk 'NR==3{print $2}')
    if [[ "$swap_mb" -eq 0 ]] && [[ $available_mem_gb -lt 8 ]]; then
        issues+=("No swap space configured (recommended for systems with <8GB RAM)")
        auto_fixes+=("setup_swap:Create 2GB swap file")
    fi
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        error "System requirement issues found:"
        for issue in "${issues[@]}"; do
            echo "  - $issue"
        done
        
        if [[ ${#auto_fixes[@]} -gt 0 ]]; then
            echo ""
            warning "Available automatic fixes:"
            for i in "${!auto_fixes[@]}"; do
                local fix="${auto_fixes[$i]}"
                local fix_desc="${fix#*:}"
                echo "  $((i+1)). $fix_desc"
            done
            echo "  $((${#auto_fixes[@]}+1)). Continue without fixes"
            echo "  $((${#auto_fixes[@]}+2)). Exit"
            
            read -p "Select option (1-$((${#auto_fixes[@]}+2))): " choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#auto_fixes[@]} ]]; then
                local selected_fix="${auto_fixes[$((choice-1))]}"
                local fix_action="${selected_fix%%:*}"
                apply_system_fix "$fix_action"
            elif [[ "$choice" -eq $((${#auto_fixes[@]}+2)) ]]; then
                exit 1
            fi
        else
            read -p "Continue despite issues? (y/N): " input
            if [[ ! "${input,,}" =~ ^y ]]; then
                exit 1
            fi
        fi
    else
        success "System requirements check passed"
    fi
}

# Apply system fixes based on user selection
apply_system_fix() {
    local fix_action="$1"
    
    case "$fix_action" in
        "expand_lvm")
            log "Expanding LVM volume..."
            if sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv 2>/dev/null; then
                if sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv; then
                    success "LVM volume expanded successfully"
                    local new_available=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
                    info "New available space: ${new_available}GB"
                else
                    error "Failed to resize filesystem"
                fi
            else
                error "Failed to extend LVM volume"
            fi
            ;;
        "cleanup_docker")
            log "Cleaning up Docker resources..."
            if docker system prune -af --volumes 2>/dev/null; then
                success "Docker cleanup completed"
                local freed=$(df / | awk 'NR==2 {printf "%.0f", $4/1024/1024}')
                info "Available space after cleanup: ${freed}GB"
            else
                warning "Docker cleanup failed or Docker not available"
            fi
            ;;
        "cleanup_system")
            log "Cleaning up system packages..."
            if sudo apt autoremove -y && sudo apt autoclean; then
                success "System cleanup completed"
            else
                error "System cleanup failed"
            fi
            ;;
        "add_docker_group")
            log "Adding user to docker group..."
            if sudo usermod -aG docker "$USER"; then
                success "User added to docker group"
                warning "Please log out and back in, or run: newgrp docker"
                read -p "Run 'newgrp docker' now? (Y/n): " input
                if [[ ! "${input,,}" =~ ^n ]]; then
                    exec newgrp docker
                fi
            else
                error "Failed to add user to docker group"
            fi
            ;;
        "setup_swap")
            log "Setting up 2GB swap file..."
            if setup_swap_file; then
                success "Swap file created successfully"
            else
                error "Failed to create swap file"
            fi
            ;;
        "show_memory_tips")
            info "Memory optimization tips:"
            info "  - Close unnecessary applications"
            info "  - Consider adding swap space"
            info "  - Monitor memory usage: free -h"
            info "  - Check for memory leaks: ps aux --sort=-%mem | head"
            ;;
    esac
}

# Enhanced Docker environment validation with auto-setup
validate_docker_environment() {
    log "Validating Docker environment..."
    
    local issues=()
    local auto_fixes=()
    
    # Check Docker installation
    if ! command -v docker &> /dev/null; then
        issues+=("Docker not installed")
        auto_fixes+=("install_docker:Install Docker Engine")
    else
        local docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        if [[ "$docker_version" == "unknown" ]]; then
            issues+=("Docker daemon not running or accessible")
            auto_fixes+=("start_docker:Start Docker daemon")
        else
            success "Docker version: $docker_version"
        fi
    fi
    
    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        issues+=("Docker Compose not installed")
        auto_fixes+=("install_compose:Install Docker Compose v2")
    else
        local compose_version=$(docker-compose version --short 2>/dev/null || echo "unknown")
        if [[ "$compose_version" == "unknown" ]]; then
            issues+=("Docker Compose not working properly")
            auto_fixes+=("fix_compose:Fix Docker Compose installation")
        elif [[ "$compose_version" =~ ^1\. ]]; then
            warning "Old Docker Compose version detected: $compose_version"
            auto_fixes+=("upgrade_compose:Upgrade to Docker Compose v2")
        else
            success "Docker Compose version: $compose_version"
        fi
    fi
    
    # Check for conflicting containerd installations (FIXED)
    # Only flag as issue if we have BOTH containerd AND containerd.io
    if dpkg -l | awk '$2 == "containerd" && $1 == "ii" {exit 0} END {exit 1}' && \
       dpkg -l | grep -q "^ii.*containerd.io"; then
        issues+=("Conflicting containerd packages detected")
        auto_fixes+=("fix_containerd:Resolve containerd conflicts")
    fi
    
    # Check required tools
    local missing_tools=()
    local tools=("curl" "jq" "nc")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        issues+=("Missing required tools: ${missing_tools[*]}")
        auto_fixes+=("install_tools:Install missing system tools")
    fi
    
    # Check NKP binary
    if ! command -v nkp &> /dev/null; then
        issues+=("NKP binary not found")
        auto_fixes+=("install_nkp:Download and install NKP binary")
    fi
    
    # Check Docker daemon configuration
    local daemon_json="/etc/docker/daemon.json"
    if [[ -f "$daemon_json" ]]; then
        if ! jq empty "$daemon_json" 2>/dev/null; then
            issues+=("Invalid JSON in Docker daemon configuration")
            auto_fixes+=("fix_daemon_json:Fix Docker daemon configuration")
        fi
    fi
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        error "Docker environment issues found:"
        for issue in "${issues[@]}"; do
            echo "  - $issue"
        done
        
        if [[ ${#auto_fixes[@]} -gt 0 ]]; then
            echo ""
            warning "Available automatic fixes:"
            for i in "${!auto_fixes[@]}"; do
                local fix="${auto_fixes[$i]}"
                local fix_desc="${fix#*:}"
                echo "  $((i+1)). $fix_desc"
            done
            echo "  $((${#auto_fixes[@]}+1)). Fix all automatically"
            echo "  $((${#auto_fixes[@]}+2)). Continue without fixes"
            echo "  $((${#auto_fixes[@]}+3)). Exit"
            
            read -p "Select option (1-$((${#auto_fixes[@]}+3))): " choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                if [[ $choice -ge 1 ]] && [[ $choice -le ${#auto_fixes[@]} ]]; then
                    local selected_fix="${auto_fixes[$((choice-1))]}"
                    local fix_action="${selected_fix%%:*}"
                    apply_docker_fix "$fix_action"
                elif [[ "$choice" -eq $((${#auto_fixes[@]}+1)) ]]; then
                    log "Applying all fixes automatically..."
                    for fix in "${auto_fixes[@]}"; do
                        local fix_action="${fix%%:*}"
                        apply_docker_fix "$fix_action"
                    done
                elif [[ "$choice" -eq $((${#auto_fixes[@]}+3)) ]]; then
                    exit 1
                fi
            fi
        else
            exit 1
        fi
    else
        success "Docker environment validation passed"
    fi
}

# Apply Docker environment fixes
apply_docker_fix() {
    local fix_action="$1"
    
    case "$fix_action" in
        "install_docker")
            log "Installing Docker Engine..."
            if sudo apt update && sudo apt install -y docker.io; then
                success "Docker installed successfully"
                if sudo systemctl enable docker && sudo systemctl start docker; then
                    success "Docker daemon started"
                fi
            else
                error "Failed to install Docker"
            fi
            ;;
        "start_docker")
            log "Starting Docker daemon..."
            if sudo systemctl start docker && sudo systemctl enable docker; then
                success "Docker daemon started"
            else
                error "Failed to start Docker daemon"
            fi
            ;;
        "install_compose")
            log "Installing Docker Compose v2..."
            if install_docker_compose; then
                success "Docker Compose installed successfully"
            else
                error "Failed to install Docker Compose"
            fi
            ;;
        "upgrade_compose")
            log "Upgrading to Docker Compose v2..."
            sudo apt remove -y docker-compose 2>/dev/null || true
            if install_docker_compose; then
                success "Docker Compose upgraded successfully"
            else
                error "Failed to upgrade Docker Compose"
            fi
            ;;
        "fix_compose")
            log "Fixing Docker Compose installation..."
            sudo apt remove -y docker-compose 2>/dev/null || true
            if install_docker_compose; then
                success "Docker Compose fixed successfully"
            else
                error "Failed to fix Docker Compose"
            fi
            ;;
        "fix_containerd")
            log "Resolving containerd conflicts..."
            if sudo apt remove -y containerd && sudo apt install -y docker.io; then
                success "Containerd conflicts resolved"
            else
                error "Failed to resolve containerd conflicts"
            fi
            ;;
        "install_tools")
            log "Installing missing system tools..."
            if sudo apt update && sudo apt install -y curl jq netcat-openbsd; then
                success "System tools installed successfully"
            else
                error "Failed to install system tools"
            fi
            ;;
        "install_nkp")
            log "Installing NKP binary..."
            if install_nkp_binary; then
                success "NKP binary installed successfully"
            else
                error "Failed to install NKP binary"
            fi
            ;;
        "fix_daemon_json")
            log "Fixing Docker daemon configuration..."
            local daemon_json="/etc/docker/daemon.json"
            if sudo cp "$daemon_json" "${daemon_json}.backup.$(date +%Y%m%d_%H%M%S)"; then
                echo '{}' | sudo tee "$daemon_json" > /dev/null
                success "Docker daemon configuration fixed"
            else
                error "Failed to fix Docker daemon configuration"
            fi
            ;;
    esac
}

# Helper function to create swap file
setup_swap_file() {
    local swap_size="2G"
    local swap_file="/swapfile"
    
    log "Creating ${swap_size} swap file at ${swap_file}..."
    
    # Check if swap file already exists
    if [[ -f "$swap_file" ]]; then
        warning "Swap file already exists at $swap_file"
        return 0
    fi
    
    # Create swap file
    if sudo fallocate -l "$swap_size" "$swap_file" 2>/dev/null || sudo dd if=/dev/zero of="$swap_file" bs=1M count=2048; then
        sudo chmod 600 "$swap_file"
        if sudo mkswap "$swap_file" && sudo swapon "$swap_file"; then
            # Add to fstab for persistence
            if ! grep -q "$swap_file" /etc/fstab; then
                echo "$swap_file none swap sw 0 0" | sudo tee -a /etc/fstab
            fi
            success "Swap file created and activated"
            return 0
        else
            error "Failed to activate swap file"
            sudo rm -f "$swap_file"
            return 1
        fi
    else
        error "Failed to create swap file"
        return 1
    fi
}

# Helper function to install Docker Compose
install_docker_compose() {
    local compose_url="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
    local compose_path="/usr/local/bin/docker-compose"
    
    if sudo curl -L "$compose_url" -o "$compose_path" && sudo chmod +x "$compose_path"; then
        return 0
    else
        return 1
    fi
}

# Helper function to install NKP binary
install_nkp_binary() {
    log "Detecting NKP binary in current directory..."
    
    # Check if NKP binary exists in current directory
    local nkp_candidates=("./nkp" "./nkp_v*_linux_amd64" "./nkp-*")
    local found_nkp=""
    
    for pattern in "${nkp_candidates[@]}"; do
        local files=($(ls $pattern 2>/dev/null))
        for file in "${files[@]}"; do
            if [[ -f "$file" ]] && [[ -x "$file" || "$file" == *.tar.gz ]]; then
                found_nkp="$file"
                break 2
            fi
        done
    done
    
    if [[ -n "$found_nkp" ]]; then
        if [[ "$found_nkp" == *.tar.gz ]]; then
            log "Extracting NKP from $found_nkp..."
            if tar -xzf "$found_nkp" nkp 2>/dev/null; then
                found_nkp="./nkp"
            else
                error "Failed to extract NKP from $found_nkp"
                return 1
            fi
        fi
        
        log "Installing NKP binary from $found_nkp..."
        if sudo cp "$found_nkp" /usr/local/bin/nkp && sudo chmod +x /usr/local/bin/nkp; then
            success "NKP binary installed to /usr/local/bin/nkp"
            return 0
        else
            error "Failed to install NKP binary"
            return 1
        fi
    else
        warning "NKP binary not found in current directory"
        info "Please download NKP from: https://github.com/mesosphere/konvoy/releases"
        info "Available options:"
        info "  1. Download manually and place in current directory"
        info "  2. Continue without NKP (bundle push will fail)"
        
        read -p "Download NKP automatically? (y/N): " input
        if [[ "${input,,}" =~ ^y ]]; then
            download_nkp_binary
            return $?
        else
            return 1
        fi
    fi
}

# Helper function to download NKP binary
download_nkp_binary() {
    local nkp_version="${NKP_VERSION:-$DEFAULT_NKP_VERSION}"
    local arch="linux_amd64"
    local download_url="https://github.com/mesosphere/konvoy/releases/download/v${nkp_version}/nkp_v${nkp_version}_${arch}.tar.gz"
    
    log "Downloading NKP v${nkp_version} for ${arch}..."
    
    if curl -L "$download_url" -o "nkp_v${nkp_version}_${arch}.tar.gz"; then
        if tar -xzf "nkp_v${nkp_version}_${arch}.tar.gz" nkp; then
            if sudo cp nkp /usr/local/bin/nkp && sudo chmod +x /usr/local/bin/nkp; then
                success "NKP v${nkp_version} downloaded and installed"
                rm -f "nkp_v${nkp_version}_${arch}.tar.gz" nkp
                return 0
            fi
        fi
    fi
    
    error "Failed to download and install NKP binary"
    return 1
}

# Enhanced Harbor setup with missing component detection
setup_harbor_environment() {
    log "Checking Harbor environment setup..."
    
    local harbor_issues=()
    local harbor_fixes=()
    
    # Check if Harbor is installed
    if ! docker images | grep -q goharbor; then
        harbor_issues+=("Harbor Docker images not found")
        
        # Check for Harbor installer
        local harbor_installer=""
        local harbor_patterns=("harbor-offline-installer-*.tgz" "harbor-online-installer-*.tgz" "./harbor")
        
        for pattern in "${harbor_patterns[@]}"; do
            local files=($(ls $pattern 2>/dev/null))
            if [[ ${#files[@]} -gt 0 ]]; then
                harbor_installer="${files[0]}"
                break
            fi
        done
        
        if [[ -n "$harbor_installer" ]] && [[ -f "$harbor_installer" ]]; then
            harbor_fixes+=("install_harbor_from_file:Install Harbor from $harbor_installer")
        else
            harbor_fixes+=("download_install_harbor:Download and install Harbor")
        fi
    fi
    
    # Check if Harbor is running
    if ! docker ps | grep -q harbor; then
        harbor_issues+=("Harbor containers not running")
        if docker images | grep -q goharbor; then
            harbor_fixes+=("start_harbor:Start existing Harbor installation")
        fi
    fi
    
    # Check Harbor accessibility
    if docker ps | grep -q harbor; then
        local harbor_port=$(docker ps | grep harbor | grep -o '0\.0\.0\.0:[0-9]*->8080' | cut -d: -f2 | cut -d- -f1 | head -1)
        if [[ -n "$harbor_port" ]]; then
            if ! curl -s "http://localhost:$harbor_port" | grep -q Harbor; then
                harbor_issues+=("Harbor web interface not accessible")
                harbor_fixes+=("restart_harbor:Restart Harbor services")
            fi
        fi
    fi
    
    if [[ ${#harbor_issues[@]} -gt 0 ]]; then
        warning "Harbor environment issues found:"
        for issue in "${harbor_issues[@]}"; do
            echo "  - $issue"
        done
        
        if [[ ${#harbor_fixes[@]} -gt 0 ]]; then
            echo ""
            info "Available Harbor setup options:"
            for i in "${!harbor_fixes[@]}"; do
                local fix="${harbor_fixes[$i]}"
                local fix_desc="${fix#*:}"
                echo "  $((i+1)). $fix_desc"
            done
            echo "  $((${#harbor_fixes[@]}+1)). Skip Harbor setup (manual configuration required)"
            echo "  $((${#harbor_fixes[@]}+2)). Exit"
            
            read -p "Select option (1-$((${#harbor_fixes[@]}+2))): " choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                if [[ $choice -ge 1 ]] && [[ $choice -le ${#harbor_fixes[@]} ]]; then
                    local selected_fix="${harbor_fixes[$((choice-1))]}"
                    local fix_action="${selected_fix%%:*}"
                    apply_harbor_fix "$fix_action"
                elif [[ "$choice" -eq $((${#harbor_fixes[@]}+2)) ]]; then
                    exit 1
                fi
            fi
        fi
    else
        success "Harbor environment is ready"
    fi
}

# Apply Harbor environment fixes
apply_harbor_fix() {
    local fix_action="$1"
    
    case "$fix_action" in
        "install_harbor_from_file")
            log "Installing Harbor from existing file..."
            local installer=$(ls harbor-offline-installer-*.tgz harbor-online-installer-*.tgz 2>/dev/null | head -1)
            if [[ -n "$installer" ]]; then
                if install_harbor_from_package "$installer"; then
                    success "Harbor installed successfully"
                else
                    error "Failed to install Harbor from $installer"
                fi
            fi
            ;;
        "download_install_harbor")
            log "Downloading and installing Harbor..."
            if download_and_install_harbor; then
                success "Harbor downloaded and installed successfully"
            else
                error "Failed to download and install Harbor"
            fi
            ;;
        "start_harbor")
            log "Starting existing Harbor installation..."
            if start_harbor_services; then
                success "Harbor services started successfully"
            else
                error "Failed to start Harbor services"
            fi
            ;;
        "restart_harbor")
            log "Restarting Harbor services..."
            if restart_harbor_services; then
                success "Harbor services restarted successfully"
            else
                error "Failed to restart Harbor services"
            fi
            ;;
    esac
}

# Helper function to install Harbor from package (FIXED)
install_harbor_from_package() {
    local package_file="$1"
    local temp_dir=$(mktemp -d)
    
    log "Extracting Harbor installer: $package_file"
    if tar -xzf "$package_file" -C "$temp_dir"; then
        local harbor_dir="$temp_dir/harbor"
        if [[ -d "$harbor_dir" ]]; then
            # Save current directory
            local original_dir=$(pwd)
            cd "$harbor_dir"
            
            # Create basic configuration
            if [[ -f "harbor.yml.tmpl" ]] && [[ ! -f "harbor.yml" ]]; then
                cp harbor.yml.tmpl harbor.yml
                
                # Basic configuration setup
                local host_ip=$(hostname -I | awk '{print $1}')
                sed -i "s/hostname: reg.mydomain.com/hostname: ${host_ip:-localhost}/" harbor.yml
                sed -i '/^https:/,/^[[:space:]]*certificate:/ s/^/#/' harbor.yml
                sed -i '/^[[:space:]]*private_key:/ s/^/#/' harbor.yml
                
                # Set default admin password
                sed -i "s/harbor_admin_password: .*/harbor_admin_password: Harbor12345/" harbor.yml
            fi
            
            # Install Harbor
            if sudo ./install.sh; then
                cd "$original_dir"
                rm -rf "$temp_dir"
                return 0
            else
                cd "$original_dir"
                rm -rf "$temp_dir"
                return 1
            fi
        else
            error "Harbor directory not found in extracted archive"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        error "Failed to extract Harbor installer"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Helper function to download and install Harbor (FIXED)
download_and_install_harbor() {
    local harbor_version="v2.10.0"
    local harbor_url="https://github.com/goharbor/harbor/releases/download/${harbor_version}/harbor-offline-installer-${harbor_version}.tgz"
    
    log "Downloading Harbor ${harbor_version}..."
    if curl -L "$harbor_url" -o "harbor-offline-installer-${harbor_version}.tgz"; then
        # Call the function and capture its exit status
        install_harbor_from_package "harbor-offline-installer-${harbor_version}.tgz"
        local result=$?
        return $result
    else
        return 1
    fi
}

# Helper function to start Harbor services
start_harbor_services() {
    local harbor_dirs=("./harbor" "../harbor" "/opt/harbor")
    
    for dir in "${harbor_dirs[@]}"; do
        if [[ -d "$dir" ]] && [[ -f "$dir/docker-compose.yml" ]]; then
            cd "$dir"
            if sudo docker-compose up -d; then
                cd - > /dev/null
                return 0
            fi
            cd - > /dev/null
        fi
    done
    
    return 1
}

# Helper function to restart Harbor services
restart_harbor_services() {
    local harbor_dirs=("./harbor" "../harbor" "/opt/harbor")
    
    for dir in "${harbor_dirs[@]}"; do
        if [[ -d "$dir" ]] && [[ -f "$dir/docker-compose.yml" ]]; then
            cd "$dir"
            if sudo docker-compose restart; then
                cd - > /dev/null
                return 0
            fi
            cd - > /dev/null
        fi
    done
    
    return 1
}

# Enhanced Harbor container state management
manage_harbor_containers() {
    log "Managing Harbor container state..."
    
    # Check for existing Harbor containers
    local existing_containers=$(docker ps -aq --filter "name=harbor" 2>/dev/null || true)
    
    if [[ -n "$existing_containers" ]]; then
        warning "Found existing Harbor containers"
        
        # Check for problematic containers (those that failed to start properly)
        local problematic=$(docker ps -a --filter "name=harbor" --filter "status=exited" --format "{{.Names}}: {{.Status}}" 2>/dev/null || true)
        if [[ -n "$problematic" ]]; then
            warning "Found problematic Harbor containers:"
            echo "$problematic"
            
            log "Cleaning up problematic containers..."
            docker stop $existing_containers 2>/dev/null || true
            docker rm -f $existing_containers 2>/dev/null || true
            
            # Clean up associated resources
            docker network ls --filter "name=harbor" --format "{{.ID}}" | xargs -r docker network rm 2>/dev/null || true
            docker volume ls --filter "name=harbor" --format "{{.Name}}" | xargs -r docker volume rm 2>/dev/null || true
            
            success "Cleaned up problematic Harbor containers"
        fi
    fi
    
    # Clean up any orphaned or corrupted image metadata
    if docker images --filter "dangling=true" -q | grep -q .; then
        log "Cleaning up dangling images..."
        docker image prune -f
    fi
}

# Auto-detect environment with enhanced logic
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

# Enhanced Harbor project creation with error handling
create_harbor_project() {
    local project_name="$1"
    
    log "Creating Harbor project: $project_name"
    
    # Check if project already exists
    local project_url="$HARBOR_URL/api/v2.0/projects?name=$project_name"
    local existing_project=$(curl -s -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" "$project_url" 2>/dev/null || echo "[]")
    
    if echo "$existing_project" | jq -e '.[] | select(.name == "'$project_name'")' > /dev/null 2>&1; then
        success "Project '$project_name' already exists"
        return 0
    fi
    
    # Create new project with retry logic
    local create_url="$HARBOR_URL/api/v2.0/projects"
    local project_data='{
        "project_name": "'$project_name'",
        "public": false,
        "metadata": {
            "public": "false"
        }
    }'
    
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        local response=$(curl -s -w "%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" \
            -d "$project_data" \
            "$create_url" 2>/dev/null || echo "000")
        
        local http_code="${response: -3}"
        
        if [[ "$http_code" == "201" ]]; then
            success "Project '$project_name' created successfully"
            return 0
        elif [[ "$http_code" == "409" ]]; then
            success "Project '$project_name' already exists (created concurrently)"
            return 0
        else
            warning "Attempt $((retry_count + 1)) failed (HTTP: $http_code)"
            ((retry_count++))
            if [[ $retry_count -lt $max_retries ]]; then
                sleep 2
            fi
        fi
    done
    
    error "Failed to create project '$project_name' after $max_retries attempts"
    return 1
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

# Verify prerequisites with enhanced checking (FIXED JQ ISSUE)
verify_prerequisites() {
    log "Verifying prerequisites..."
    
    local missing_tools=()
    
    # Check required tools - FIXED version checking
    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    else
        local docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "installed")
        success "docker available (version: $docker_version)"
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    else
        local curl_version=$(curl --version 2>/dev/null | head -1 | awk '{print $2}' || echo "installed")
        success "curl available (version: $curl_version)"
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    else
        # Fixed: jq --version outputs to stderr, redirect properly
        local jq_version=$(jq --version 2>&1 | head -1 || echo "installed")
        success "jq available (version: $jq_version)"
    fi
    
    if ! command -v nkp &> /dev/null; then
        missing_tools+=("nkp")
    else
        local nkp_version=$(nkp version 2>/dev/null | head -1 || echo "installed")
        success "nkp available (version: $nkp_version)"
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        info "Installation commands:"
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                docker) info "  sudo apt install docker.io" ;;
                curl) info "  sudo apt install curl" ;;
                jq) info "  sudo apt install jq" ;;
                nkp) info "  Download from: https://github.com/mesosphere/konvoy/releases" ;;
            esac
        done
        return 1
    fi
    
    success "All required tools are available"
}

# Enhanced Harbor connectivity verification
verify_harbor() {
    log "Verifying Harbor connectivity..."
    
    build_harbor_url
    
    # Test basic connectivity first
    if ! curl -s --connect-timeout 10 "$HARBOR_HOST:$HARBOR_PORT" > /dev/null 2>&1; then
        error "Cannot connect to Harbor at: $HARBOR_HOST:$HARBOR_PORT"
        info "Troubleshooting steps:"
        info "  1. Check if Harbor is running: docker ps | grep harbor"
        info "  2. Verify network connectivity: ping $HARBOR_HOST"
        info "  3. Check firewall rules"
        info "  4. Verify Harbor installation"
        return 1
    fi
    
    # Test Harbor health endpoint
    local health_url="$HARBOR_URL/api/v2.0/health"
    local health_response=$(curl -s --connect-timeout 10 "$health_url" 2>/dev/null || echo "")
    
    if ! echo "$health_response" | grep -q "healthy"; then
        warning "Harbor health check failed"
        info "Health response: $health_response"
        
        # Try alternative health checks
        local basic_url="$HARBOR_URL/"
        if curl -s --connect-timeout 10 "$basic_url" | grep -q "Harbor"; then
            warning "Harbor web interface accessible but API may not be ready"
            info "Waiting for Harbor to fully initialize..."
            sleep 10
        else
            error "Harbor is not accessible at: $HARBOR_URL"
            return 1
        fi
    else
        success "Harbor is healthy and accessible"
    fi
    
    # Test authentication with improved error handling
    local auth_test_url="$HARBOR_URL/api/v2.0/projects"
    local auth_response=$(curl -s -w "%{http_code}" -u "$HARBOR_USERNAME:$HARBOR_PASSWORD" "$auth_test_url" 2>/dev/null || echo "000")
    local auth_http_code="${auth_response: -3}"
    
    case "$auth_http_code" in
        200) success "Harbor authentication successful" ;;
        401) 
            error "Harbor authentication failed - invalid credentials"
            info "Please check username and password"
            return 1
            ;;
        403)
            error "Harbor authentication failed - access forbidden"
            info "User may not have required permissions"
            return 1
            ;;
        *)
            warning "Harbor authentication test inconclusive (HTTP: $auth_http_code)"
            info "Continuing with deployment..."
            ;;
    esac
}

# Format protocol display
format_protocol() {
    if [[ "${USE_HTTPS,,}" == "true" ]]; then
        echo "HTTPS"
    else
        echo "HTTP"
    fi
}

# Enhanced NKP bundle verification
verify_nkp_bundles() {
    log "Verifying NKP bundles..."
    
    if [[ ! -d "$NKP_BUNDLE_DIR" ]]; then
        error "NKP bundle directory not found: $NKP_BUNDLE_DIR"
        info "Expected directory structure:"
        info "  $NKP_BUNDLE_DIR/"
        info "  └── container-images/"
        info "      ├── konvoy-image-bundle-v$NKP_VERSION.tar"
        info "      └── kommander-image-bundle-v$NKP_VERSION.tar"
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
    local total_size=0
    
    for bundle in "${bundles[@]}"; do
        if [[ -f "$bundle" ]]; then
            local size_mb=$(du -m "$bundle" | cut -f1)
            success "Found bundle: $(basename "$bundle") (${size_mb}MB)"
            ((found_bundles++))
            total_size=$((total_size + size_mb))
            
            # Verify bundle is not corrupted (basic check)
            if ! tar -tf "$bundle" > /dev/null 2>&1; then
                error "Bundle appears corrupted: $(basename "$bundle")"
                return 1
            fi
        else
            warning "Bundle not found: $(basename "$bundle")"
        fi
    done
    
    if [[ $found_bundles -eq 0 ]]; then
        error "No NKP bundles found in: $bundle_dir"
        info "Available files:"
        ls -la "$bundle_dir" 2>/dev/null || echo "Directory not accessible"
        return 1
    fi
    
    info "Total bundle size: ${total_size}MB"
    success "NKP bundles verified ($found_bundles found)"
}

# Enhanced Docker daemon configuration
configure_docker_daemon() {
    log "Configuring Docker daemon for insecure registry..."
    
    local daemon_json="/etc/docker/daemon.json"
    local needs_restart=false
    
    # Build registry entry
    local registry_entry="$HARBOR_HOST"
    if [[ "$HARBOR_PORT" != "80" ]]; then
        registry_entry="$HARBOR_HOST:$HARBOR_PORT"
    fi
    
    # Check if already configured
    if [[ -f "$daemon_json" ]] && jq -e --arg registry "$registry_entry" '.["insecure-registries"] | index($registry)' "$daemon_json" > /dev/null 2>&1; then
        success "Docker daemon already configured for Harbor registry"
        return 0
    fi
    
    # Only configure for HTTP (insecure) registries
    if [[ "${USE_HTTPS,,}" != "true" ]]; then
        warning "HTTP registry detected - Docker daemon configuration needed"
        
        if [[ "$EUID" -eq 0 ]] || groups | grep -q docker; then
            info "Configuring Docker daemon for insecure registry..."
            
            # Backup existing config
            if [[ -f "$daemon_json" ]]; then
                sudo cp "$daemon_json" "${daemon_json}.backup.$(date +%Y%m%d_%H%M%S)"
            fi
            
            # Create or update daemon.json
            if [[ -f "$daemon_json" ]]; then
                # Update existing file
                local temp_file=$(mktemp)
                if sudo jq --arg registry "$registry_entry" \
                    '.["insecure-registries"] = (.["insecure-registries"] // []) + [$registry] | .["insecure-registries"] |= unique' \
                    "$daemon_json" > "$temp_file" 2>/dev/null; then
                    sudo mv "$temp_file" "$daemon_json"
                else
                    rm -f "$temp_file"
                    error "Failed to update Docker daemon configuration"
                    return 1
                fi
            else
                # Create new file
                echo "{\"insecure-registries\": [\"$registry_entry\"]}" | sudo tee "$daemon_json" > /dev/null
            fi
            
            needs_restart=true
        else
            warning "Cannot configure Docker daemon (no sudo/docker group access)"
            info "Please manually add to $daemon_json:"
            info "  {\"insecure-registries\": [\"$registry_entry\"]}"
        fi
    fi
    
    if [[ "$needs_restart" == "true" ]]; then
        info "Restarting Docker daemon..."
        if sudo systemctl restart docker; then
            sleep 5  # Give more time for restart
            success "Docker daemon restarted"
            
            # Verify Docker is working after restart
            if ! docker ps > /dev/null 2>&1; then
                error "Docker daemon restart failed or not responding"
                return 1
            fi
        else
            error "Failed to restart Docker daemon"
            return 1
        fi
    fi
}

# Enhanced bundle pushing with better error handling and progress monitoring
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
            
            # Check available disk space before pushing
            local bundle_size_mb=$(du -m "$bundle" | cut -f1)
            local available_mb=$(df /tmp | awk 'NR==2 {printf "%.0f", $4/1024}')
            
            if [[ $available_mb -lt $((bundle_size_mb * 3)) ]]; then
                warning "Low disk space. Available: ${available_mb}MB, Need: ~$((bundle_size_mb * 3))MB"
                info "Consider cleaning up: docker system prune -f"
                
                read -p "Continue with low disk space? (y/N): " input
                if [[ ! "${input,,}" =~ ^y ]]; then
                    error "Insufficient disk space for bundle extraction"
                    return 1
                fi
            fi
            
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
            
            # Execute with timeout and better error handling
            local max_attempts=2
            local attempt=1
            local push_success=false
            
            while [[ $attempt -le $max_attempts ]] && [[ "$push_success" == "false" ]]; do
                if [[ $attempt -gt 1 ]]; then
                    warning "Retry attempt $attempt for $bundle_name"
                    sleep 10
                fi
                
                # Use timeout to prevent hanging
                if timeout 3600 nkp "${nkp_args[@]}"; then
                    success "Successfully pushed: $bundle_name"
                    push_success=true
                    ((success_count++))
                    
                    # Estimate image count
                    if [[ "$bundle_name" == *"konvoy"* ]]; then
                        total_images=$((total_images + 110))
                    elif [[ "$bundle_name" == *"kommander"* ]]; then
                        total_images=$((total_images + 135))
                    fi
                else
                    local exit_code=$?
                    if [[ $exit_code -eq 124 ]]; then
                        error "Push timed out for: $bundle_name (attempt $attempt)"
                    else
                        error "Push failed for: $bundle_name (attempt $attempt, exit code: $exit_code)"
                    fi
                    
                    # Cleanup any partial state
                    docker system prune -f > /dev/null 2>&1 || true
                fi
                
                ((attempt++))
            done
            
            if [[ "$push_success" == "false" ]]; then
                error "Failed to push $bundle_name after $max_attempts attempts"
                info "Common issues and solutions:"
                info "  1. Network connectivity - check Harbor accessibility"
                info "  2. Disk space - run: docker system prune -af"
                info "  3. Registry permissions - verify project exists and user has push access"
                info "  4. Registry storage - check Harbor storage configuration"
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
    echo "🔧 VERIFICATION COMMANDS:"
    echo "docker login $HARBOR_HOST$([ "$HARBOR_PORT" != "80" ] && [ "$HARBOR_PORT" != "443" ] && echo ":$HARBOR_PORT") -u $HARBOR_USERNAME"
    echo "docker pull $HARBOR_HOST$([ "$HARBOR_PORT" != "80" ] && [ "$HARBOR_PORT" != "443" ] && echo ":$HARBOR_PORT")/$HARBOR_PROJECT/mesosphere/konvoy:v$NKP_VERSION"
    echo ""
    echo "🎉 YOUR PRIVATE REGISTRY IS READY FOR NKP DEPLOYMENT! 🎉"
}

# Enhanced error recovery and cleanup
cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        warning "Script failed with exit code: $exit_code"
        info "Cleanup recommendations:"
        info "  1. Check logs above for specific error messages"
        info "  2. Clean Docker resources: docker system prune -af"
        info "  3. Restart Docker if needed: sudo systemctl restart docker"
        info "  4. Check disk space: df -h"
        info "  5. Verify Harbor status: docker ps | grep harbor"
    fi
}

# Set trap for cleanup
trap cleanup_on_failure EXIT

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
    echo "  --check-system      Check system requirements only"
    echo "  --fix-docker        Attempt to fix Docker environment issues"
    echo "  --setup-harbor      Set up Harbor environment interactively"
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
    echo "  $0 --check-system                      # Check system requirements"
    echo "  $0 --fix-docker                        # Fix Docker environment"
    echo "  $0 --setup-harbor                      # Set up Harbor interactively"
    echo "  $0 --auto                              # Auto-detect and run"
    echo "  $0 --config my-config.conf             # Use configuration file"
    echo "  HARBOR_HOST=harbor.local $0 --auto     # Set host via environment"
    echo "  $0 --generate-config                   # Generate config file"
}

# Main execution
main() {
    local auto_mode=false
    local verify_only=false
    local push_only=false
    local generate_config_only=false
    local check_system_only=false
    local fix_docker_only=false
    local setup_harbor_only=false
    
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
            --check-system)
                check_system_only=true
                shift
                ;;
            --fix-docker)
                fix_docker_only=true
                shift
                ;;
            --setup-harbor)
                setup_harbor_only=true
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
    
    # Enhanced system validation with setup prompts
    if [[ "$check_system_only" == "true" ]]; then
        check_system_requirements
        exit 0
    fi
    
    if [[ "$fix_docker_only" == "true" ]]; then
        validate_docker_environment
        exit 0
    fi
    
    if [[ "$setup_harbor_only" == "true" ]]; then
        setup_harbor_environment
        exit 0
    fi
    
    # System requirements check with auto-setup
    check_system_requirements
    
    # Docker environment validation with auto-setup
    validate_docker_environment
    
    # Harbor environment setup with auto-detection
    setup_harbor_environment
    
    # Harbor container management
    manage_harbor_containers
    
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
    configure_docker_daemon || exit 1
    
    # Push bundles
    if [[ "$push_only" != "false" ]] || [[ "$verify_only" != "true" ]]; then
        push_bundles || exit 1
    fi
    
    # Generate summary
    generate_summary
    
    success "Deployment completed successfully!"
    
    # Clear the trap since we completed successfully
    trap - EXIT
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
