#!/bin/bash

# NKP Pre-provisioned Infrastructure Checker
# Version: 4.0 - Production Ready
# Purpose: Validate bare metal nodes are ready for NKP deployment
# Design: Simple, reliable, portable, no dependencies

set -euo pipefail

# Colors for output (works on most terminals)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration file support for repeatability
CONFIG_FILE="${1:-}"
SAVE_CONFIG=false
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="nkp-precheck-report-${TIMESTAMP}.txt"

# Initialize variables
declare -a CONTROL_PLANE_IPS=()
declare -a WORKER_IPS=()
declare -a ALL_NODES=()
VIP=""
SSH_USER=""
SSH_KEY_PATH=""
DEPLOY_USER=""
SILENT_MODE=false

# Simple logging
log() {
    echo -e "$1" | tee -a "$REPORT_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$REPORT_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$REPORT_FILE"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1" | tee -a "$REPORT_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$REPORT_FILE"
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# Load configuration from file
load_config() {
    local config_file=$1
    if [[ -f "$config_file" ]]; then
        log_info "Loading configuration from $config_file"
        source "$config_file"
        return 0
    else
        log_error "Configuration file not found: $config_file"
        return 1
    fi
}

# Save configuration for reuse
save_config() {
    local config_file="nkp-config-${TIMESTAMP}.conf"
    cat > "$config_file" <<EOF
# NKP Pre-check Configuration
# Generated: $(date)

# Control Plane IPs (comma-separated)
CONTROL_PLANE_IPS=(${CONTROL_PLANE_IPS[@]})

# Worker Node IPs (comma-separated)  
WORKER_IPS=(${WORKER_IPS[@]})

# Virtual IP for API Server
VIP="$VIP"

# SSH Configuration
SSH_USER="$SSH_USER"
SSH_KEY_PATH="$SSH_KEY_PATH"

# Deployment User (will be created/verified on nodes)
DEPLOY_USER="$DEPLOY_USER"
EOF
    log_success "Configuration saved to $config_file"
    log_info "Reuse with: $0 $config_file"
}

# Interactive configuration gathering
gather_config() {
    log_info "=== Cluster Configuration ==="
    
    # SSH User
    read -p "SSH username for nodes [current user: $(whoami)]: " input
    SSH_USER=${input:-$(whoami)}
    
    # SSH Key
    default_key="$HOME/.ssh/id_rsa"
    read -p "SSH private key path [$default_key]: " input
    SSH_KEY_PATH=${input:-$default_key}
    
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_warn "SSH key not found at $SSH_KEY_PATH"
        read -p "Continue without key (will use password auth)? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
        SSH_KEY_PATH=""
    fi
    
    # Deployment user
    read -p "Deployment username [nkp]: " input
    DEPLOY_USER=${input:-nkp}
    
    # Control plane nodes
    read -p "Control plane IPs (comma-separated): " input
    IFS=',' read -ra CONTROL_PLANE_IPS <<< "$input"
    for ip in "${CONTROL_PLANE_IPS[@]}"; do
        ip=$(echo "$ip" | xargs)
        validate_ip "$ip" || { log_error "Invalid IP: $ip"; exit 1; }
        ALL_NODES+=("$ip")
    done
    
    # Worker nodes
    read -p "Worker node IPs (comma-separated): " input
    IFS=',' read -ra WORKER_IPS <<< "$input"
    for ip in "${WORKER_IPS[@]}"; do
        ip=$(echo "$ip" | xargs)
        validate_ip "$ip" || { log_error "Invalid IP: $ip"; exit 1; }
        ALL_NODES+=("$ip")
    done
    
    # VIP
    read -p "Virtual IP (VIP) for API server: " VIP
    validate_ip "$VIP" || { log_error "Invalid VIP: $VIP"; exit 1; }
    
    # Save config option
    read -p "Save configuration for reuse? [Y/n]: " save
    [[ "$save" =~ ^[Nn]$ ]] || SAVE_CONFIG=true
}

# Simple SSH test - just check if we can connect
test_ssh() {
    local node=$1
    local ssh_opts="-o ConnectTimeout=5 -o StrictHostKeyChecking=no"
    
    if [[ -n "$SSH_KEY_PATH" ]]; then
        ssh_opts="$ssh_opts -i $SSH_KEY_PATH"
    fi
    
    if ssh $ssh_opts "$SSH_USER@$node" "echo 'SSH_OK'" 2>/dev/null | grep -q "SSH_OK"; then
        return 0
    fi
    return 1
}

# Execute command on remote node
run_remote() {
    local node=$1
    local cmd=$2
    local ssh_opts="-o ConnectTimeout=5 -o StrictHostKeyChecking=no"
    
    if [[ -n "$SSH_KEY_PATH" ]]; then
        ssh_opts="$ssh_opts -i $SSH_KEY_PATH"
    fi
    
    ssh $ssh_opts "$SSH_USER@$node" "$cmd" 2>/dev/null
}

# Check single node
check_node() {
    local node=$1
    local node_type=$2
    local failed_checks=0
    
    log_info "\nChecking $node_type node: $node"
    
    # 1. SSH connectivity
    echo -n "  SSH connectivity: "
    if test_ssh "$node"; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        log_error "Cannot SSH to $node"
        return 1
    fi
    
    # 2. Hostname
    echo -n "  Hostname: "
    local hostname=$(run_remote "$node" "hostname" || echo "unknown")
    echo "$hostname"
    
    # 3. Network interface
    echo -n "  Primary interface: "
    local iface=$(run_remote "$node" "ip -4 route show default | grep -oP 'dev \K\S+'" || echo "unknown")
    echo "$iface"
    
    # 4. Kernel modules
    echo -n "  Kernel modules (overlay, br_netfilter): "
    if run_remote "$node" "lsmod | grep -q overlay && lsmod | grep -q br_netfilter"; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}Missing${NC}"
        ((failed_checks++))
    fi
    
    # 5. Swap
    echo -n "  Swap disabled: "
    if run_remote "$node" "swapon -s | grep -q '^/'"; then
        echo -e "${YELLOW}Enabled${NC}"
        ((failed_checks++))
    else
        echo -e "${GREEN}✓${NC}"
    fi
    
    # 6. IP forwarding
    echo -n "  IP forwarding: "
    local ipf=$(run_remote "$node" "sysctl -n net.ipv4.ip_forward" || echo "0")
    if [[ "$ipf" == "1" ]]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}Disabled${NC}"
        ((failed_checks++))
    fi
    
    # 7. Check deployment user
    echo -n "  User '$DEPLOY_USER': "
    if run_remote "$node" "id $DEPLOY_USER" &>/dev/null; then
        echo -e "${GREEN}Exists${NC}"
        
        # Check sudo
        echo -n "    Sudo access: "
        if run_remote "$node" "sudo -l -U $DEPLOY_USER 2>/dev/null | grep -q 'NOPASSWD.*ALL'"; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${YELLOW}Needs configuration${NC}"
            ((failed_checks++))
        fi
    else
        echo -e "${YELLOW}Not found${NC}"
        ((failed_checks++))
    fi
    
    # 8. Container runtime
    echo -n "  Container runtime: "
    if run_remote "$node" "command -v docker" &>/dev/null; then
        echo -e "${GREEN}Docker${NC}"
    elif run_remote "$node" "command -v containerd" &>/dev/null; then
        echo -e "${GREEN}Containerd${NC}"
    else
        echo -e "${YELLOW}None${NC}"
        ((failed_checks++))
    fi
    
    # 9. Worker-specific: storage directories
    if [[ "$node_type" == "worker" ]]; then
        echo -n "  Storage directories: "
        if run_remote "$node" "test -d /mnt/local-storage/pv1" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${YELLOW}Not configured${NC}"
            ((failed_checks++))
        fi
    fi
    
    return $failed_checks
}

# Apply fixes to node
fix_node() {
    local node=$1
    local node_type=$2
    
    log_info "Applying fixes to $node..."
    
    # Create fix script to run on remote node
    local fix_script='
#!/bin/bash
set -e

DEPLOY_USER="'$DEPLOY_USER'"
NODE_TYPE="'$node_type'"

echo "Starting fixes on $(hostname)..."

# 1. Create deployment user if needed
if ! id "$DEPLOY_USER" &>/dev/null; then
    echo "Creating user $DEPLOY_USER..."
    sudo useradd -m -s /bin/bash "$DEPLOY_USER" || true
    echo "$DEPLOY_USER:changeme123" | sudo chpasswd
fi

# 2. Configure sudo for deployment user
echo "Configuring sudo for $DEPLOY_USER..."
echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$DEPLOY_USER
sudo usermod -aG sudo "$DEPLOY_USER" 2>/dev/null || true

# 3. Disable swap
echo "Disabling swap..."
sudo swapoff -a
sudo sed -i "/ swap / s/^/#/" /etc/fstab

# 4. Load kernel modules
echo "Loading kernel modules..."
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# 5. Configure sysctl for Kubernetes
echo "Configuring sysctl..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system >/dev/null 2>&1

# 6. Disable UFW firewall
echo "Disabling UFW firewall..."
sudo ufw disable 2>/dev/null || true

# 7. Clean up existing Kubernetes packages
echo "Cleaning Kubernetes packages..."
sudo apt-get remove -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/kubernetes*.list
sudo apt-get update >/dev/null 2>&1 || true

# 8. Worker-specific: storage directories
if [[ "$NODE_TYPE" == "worker" ]]; then
    echo "Creating storage directories for worker..."
    sudo mkdir -p /mnt/local-storage/{pv1,pv2,pv3,pv4,pv5}
    sudo chmod 777 /mnt/local-storage/*
    sudo mkdir -p /mnt/prometheus
    sudo chmod 777 /mnt/prometheus
fi

echo "Fixes applied successfully!"
'
    
    # Execute fix script on remote node
    if run_remote "$node" "$fix_script"; then
        log_success "Fixes applied to $node"
    else
        log_error "Failed to apply some fixes to $node"
    fi
}

# Test network connectivity between nodes
test_connectivity() {
    log_info "\n=== Network Connectivity Test ==="
    
    # Test VIP availability
    echo -n "VIP $VIP availability: "
    if ping -c 1 -W 2 "$VIP" &>/dev/null; then
        echo -e "${RED}In use (should be free!)${NC}"
        log_warn "VIP is already in use!"
    else
        echo -e "${GREEN}Available${NC}"
    fi
    
    # Test node-to-node connectivity
    log_info "\nNode-to-node connectivity:"
    for source in "${ALL_NODES[@]}"; do
        echo -n "  From $source: "
        local reachable=0
        local total=0
        for target in "${ALL_NODES[@]}"; do
            [[ "$source" == "$target" ]] && continue
            ((total++))
            if run_remote "$source" "ping -c 1 -W 1 $target" &>/dev/null; then
                ((reachable++))
            fi
        done
        echo "$reachable/$total nodes reachable"
    done
}

# Main execution
main() {
    log "NKP Pre-provisioned Infrastructure Checker v4.0"
    log "Report: $REPORT_FILE"
    log "================================================\n"
    
    # Load or gather configuration
    if [[ -n "$CONFIG_FILE" ]]; then
        load_config "$CONFIG_FILE" || exit 1
    else
        gather_config
        [[ "$SAVE_CONFIG" == true ]] && save_config
    fi
    
    # Display configuration
    log_info "\nConfiguration Summary:"
    log "  Control Plane: ${#CONTROL_PLANE_IPS[@]} nodes"
    log "  Workers: ${#WORKER_IPS[@]} nodes"
    log "  VIP: $VIP"
    log "  SSH User: $SSH_USER"
    log "  Deploy User: $DEPLOY_USER"
    
    # Phase 1: Check all nodes
    log_info "\n=== Phase 1: Node Validation ==="
    local total_issues=0
    
    for node in "${CONTROL_PLANE_IPS[@]}"; do
        check_node "$node" "control-plane"
        total_issues=$((total_issues + $?))
    done
    
    for node in "${WORKER_IPS[@]}"; do
        check_node "$node" "worker"
        total_issues=$((total_issues + $?))
    done
    
    # Phase 2: Offer fixes if issues found
    if [[ $total_issues -gt 0 ]]; then
        log_warn "\nFound $total_issues issue(s) across all nodes"
        read -p "Apply automatic fixes? [y/N]: " apply_fixes
        
        if [[ "$apply_fixes" =~ ^[Yy]$ ]]; then
            log_info "\n=== Phase 2: Applying Fixes ==="
            
            for node in "${CONTROL_PLANE_IPS[@]}"; do
                fix_node "$node" "control-plane"
            done
            
            for node in "${WORKER_IPS[@]}"; do
                fix_node "$node" "worker"
            done
            
            log_info "\n=== Re-checking After Fixes ==="
            total_issues=0
            for node in "${CONTROL_PLANE_IPS[@]}"; do
                check_node "$node" "control-plane"
                total_issues=$((total_issues + $?))
            done
            
            for node in "${WORKER_IPS[@]}"; do
                check_node "$node" "worker"
                total_issues=$((total_issues + $?))
            done
        fi
    fi
    
    # Phase 3: Network connectivity
    test_connectivity
    
    # Final summary
    log_info "\n=== Final Summary ==="
    if [[ $total_issues -eq 0 ]]; then
        log_success "✓ All nodes passed validation!"
        log_success "✓ Cluster is ready for NKP deployment"
        
        # Show interface info for deployment
        log_info "\nFor NKP deployment, use:"
        local first_cp="${CONTROL_PLANE_IPS[0]}"
        local iface=$(run_remote "$first_cp" "ip -4 route show default | grep -oP 'dev \K\S+'" || echo "eth0")
        log "  --virtual-ip-interface $iface"
        log "  --control-plane-endpoint-host $VIP"
    else
        log_error "✗ Found $total_issues issue(s)"
        log_error "✗ Fix issues before deployment"
    fi
    
    log "\n================================================"
    log "Full report saved to: $REPORT_FILE"
}

# Run main
main "$@"
