#!/bin/bash

# NKP Pre-provisioned Infrastructure Checker - FIXED VERSION
# Version: 4.1 - Actually works
# Remove the pipefail that's causing issues

set -u  # Only keep undefined variable checking

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Config
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="nkp-precheck-report-${TIMESTAMP}.txt"

# Arrays
CONTROL_PLANE_IPS=()
WORKER_IPS=()
ALL_NODES=()

# Simple logging
log() {
    echo -e "$1" | tee -a "$REPORT_FILE"
}

# Gather configuration
echo "=== NKP Cluster Pre-Check ==="
read -p "Control plane IPs (comma-separated): " cp_input
IFS=',' read -ra CONTROL_PLANE_IPS <<< "$cp_input"

read -p "Worker node IPs (comma-separated): " w_input
IFS=',' read -ra WORKER_IPS <<< "$w_input"

read -p "VIP for API server: " VIP
read -p "SSH user [$(whoami)]: " input
SSH_USER=${input:-$(whoami)}

# Combine all nodes
ALL_NODES=("${CONTROL_PLANE_IPS[@]}" "${WORKER_IPS[@]}")

echo ""
log "Configuration:"
log "  Control Plane: ${CONTROL_PLANE_IPS[*]}"
log "  Workers: ${WORKER_IPS[*]}"
log "  VIP: $VIP"
log "  SSH User: $SSH_USER"
echo ""

# Function to run remote command
run_cmd() {
    local node=$1
    local cmd=$2
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$node" "$cmd" 2>/dev/null
}

# Check single node - SIMPLIFIED
check_node() {
    local node=$1
    local node_type=$2
    
    echo "Checking $node_type: $node"
    
    # Run all checks in a single SSH session for efficiency
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$node" '
        echo "  Hostname: $(hostname)"
        echo -n "  Interface: "; ip -4 route show default | grep -oP "dev \K\S+" || echo "unknown"
        echo -n "  Swap: "; swapon -s 2>/dev/null | grep -q "^/" && echo "ENABLED (needs fix)" || echo "disabled"
        echo -n "  Modules: "; lsmod | grep -q overlay && lsmod | grep -q br_netfilter && echo "loaded" || echo "MISSING (needs fix)"
        echo -n "  IP Forward: "; [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && echo "enabled" || echo "DISABLED (needs fix)"
        echo -n "  Bridge-nf: "; [ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" = "1" ] && echo "enabled" || echo "DISABLED (needs fix)"
        echo -n "  Firewall: "; ufw status 2>/dev/null | grep -q "Status: active" && echo "ACTIVE (needs fix)" || echo "disabled"
        echo -n "  Docker: "; command -v docker &>/dev/null && echo "installed" || (command -v containerd &>/dev/null && echo "containerd" || echo "NONE (needs fix)")
        if [ "'$node_type'" = "worker" ]; then
            echo -n "  Storage dirs: "; [ -d /mnt/local-storage/pv1 ] && echo "exists" || echo "MISSING (needs fix)"
            echo -n "  Prometheus dir: "; [ -d /mnt/prometheus ] && echo "exists" || echo "MISSING (needs fix)"
        fi
    ' || echo "  ERROR: Cannot connect to $node"
    
    echo ""
}

# Apply fixes
apply_fixes() {
    local node=$1
    local node_type=$2
    
    echo "Applying fixes to $node..."
    
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$node" '
        # Disable swap
        sudo swapoff -a
        sudo sed -i "/ swap / s/^/#/" /etc/fstab
        
        # Load modules
        sudo modprobe overlay
        sudo modprobe br_netfilter
        echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/k8s.conf
        
        # Configure sysctl
        cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
        sudo sysctl --system >/dev/null 2>&1
        
        # Disable firewall
        sudo ufw disable 2>/dev/null || true
        
        # Clean k8s packages
        sudo apt-get remove -y kubelet kubeadm kubectl 2>/dev/null || true
        
        # Worker storage
        if [ "'$node_type'" = "worker" ]; then
            sudo mkdir -p /mnt/local-storage/{pv1,pv2,pv3,pv4,pv5}
            sudo chmod 777 /mnt/local-storage/*
            sudo mkdir -p /mnt/prometheus
            sudo chmod 777 /mnt/prometheus
        fi
        
        echo "  Fixes applied!"
    ' || echo "  ERROR: Failed to apply fixes"
}

# Main execution
echo "=== Phase 1: Checking all nodes ==="
for node in "${CONTROL_PLANE_IPS[@]}"; do
    check_node "$node" "control-plane"
done

for node in "${WORKER_IPS[@]}"; do
    check_node "$node" "worker"
done

# Ask to fix
echo ""
read -p "Apply fixes to all nodes? [y/N]: " apply
if [[ "$apply" =~ ^[Yy]$ ]]; then
    echo ""
    echo "=== Phase 2: Applying fixes ==="
    for node in "${CONTROL_PLANE_IPS[@]}"; do
        apply_fixes "$node" "control-plane"
    done
    
    for node in "${WORKER_IPS[@]}"; do
        apply_fixes "$node" "worker"
    done
    
    echo ""
    echo "=== Phase 3: Re-checking all nodes ==="
    for node in "${CONTROL_PLANE_IPS[@]}"; do
        check_node "$node" "control-plane"
    done
    
    for node in "${WORKER_IPS[@]}"; do
        check_node "$node" "worker"
    done
fi

# Test connectivity
echo "=== Network Tests ==="
echo -n "VIP $VIP: "
ping -c 1 -W 2 "$VIP" &>/dev/null && echo "IN USE (should be free!)" || echo "Available (good)"

echo ""
echo "=== Summary ==="
echo "Report saved to: $REPORT_FILE"
echo ""
echo "For NKP deployment, use:"
first_cp="${CONTROL_PLANE_IPS[0]}"
iface=$(run_cmd "$first_cp" "ip -4 route show default | grep -oP 'dev \K\S+'" || echo "eth0")
echo "  --virtual-ip-interface $iface"
echo "  --control-plane-endpoint-host $VIP"
