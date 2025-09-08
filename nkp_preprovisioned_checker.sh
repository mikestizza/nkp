#!/bin/bash

# NKP Pre-provisioned Infrastructure Checker - FIXED VERSION
# Version: 4.2 - With descriptions
# Validates bare metal nodes for Kubernetes deployment

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

# Check single node with descriptions
check_node() {
    local node=$1
    local node_type=$2
    
    echo "Checking $node_type: $node"
    
    # Run all checks in a single SSH session for efficiency
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$node" '
        echo "  Hostname: $(hostname)"
        echo -n "  Network Interface (for VIP binding): "; ip -4 route show default | grep -oP "dev \K\S+" || echo "unknown"
        echo -n "  Swap (must be disabled for K8s): "; swapon -s 2>/dev/null | grep -q "^/" && echo "ENABLED - needs fix" || echo "disabled ✓"
        echo -n "  Kernel Modules (container networking): "; lsmod | grep -q overlay && lsmod | grep -q br_netfilter && echo "loaded ✓" || echo "MISSING - needs fix"
        echo -n "  IP Forward (pod communication): "; [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && echo "enabled ✓" || echo "DISABLED - needs fix"
        echo -n "  Bridge Netfilter (iptables for bridges): "; [ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" = "1" ] && echo "enabled ✓" || echo "DISABLED - needs fix"
        echo -n "  Firewall (must allow K8s ports): "; ufw status 2>/dev/null | grep -q "Status: active" && echo "ACTIVE - needs fix" || echo "disabled ✓"
        echo -n "  Container Runtime: "; command -v containerd &>/dev/null && echo "containerd installed ✓" || echo "NONE - needs fix"
        echo -n "  Old K8s packages (should be clean): "; dpkg -l 2>/dev/null | grep -E "kubelet|kubeadm|kubectl" | grep -q "^ii" && echo "FOUND - needs cleanup" || echo "clean ✓"
        if [ "'$node_type'" = "worker" ]; then
            echo "  === Worker Storage Requirements ==="
            echo -n "  Local PV directories (/mnt/local-storage): "; [ -d /mnt/local-storage/pv1 ] && echo "exists ✓" || echo "MISSING - needs fix"
            echo -n "  Prometheus storage (/mnt/prometheus): "; [ -d /mnt/prometheus ] && echo "exists ✓" || echo "MISSING - needs fix"
        fi
    ' || echo "  ERROR: Cannot connect to $node"
    
    echo ""
}

# Apply fixes with descriptions
apply_fixes() {
    local node=$1
    local node_type=$2
    
    echo "Applying fixes to $node..."
    
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$node" '
        echo "  Disabling swap (K8s requirement)..."
        sudo swapoff -a
        sudo sed -i "/ swap / s/^/#/" /etc/fstab
        
        echo "  Loading kernel modules for container networking..."
        sudo modprobe overlay
        sudo modprobe br_netfilter
        echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
        
        echo "  Configuring network settings for K8s..."
        cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
        sudo sysctl --system >/dev/null 2>&1
        
        echo "  Disabling firewall (K8s manages its own rules)..."
        sudo ufw disable 2>/dev/null || true
        
        echo "  Cleaning old Kubernetes packages..."
        sudo apt-get remove -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null || true
        sudo rm -f /etc/apt/sources.list.d/kubernetes*.list
        
        # Worker storage
        if [ "'$node_type'" = "worker" ]; then
            echo "  Creating persistent volume directories..."
            sudo mkdir -p /mnt/local-storage/{pv1,pv2,pv3,pv4,pv5}
            sudo chmod 777 /mnt/local-storage/*
            echo "  Creating Prometheus monitoring storage..."
            sudo mkdir -p /mnt/prometheus
            sudo chmod 777 /mnt/prometheus
        fi
        
        echo "  ✓ All fixes applied!"
    ' || echo "  ERROR: Failed to apply fixes"
}

# Main execution
echo "=== Phase 1: Checking all nodes ==="
echo "Validating prerequisites for Kubernetes deployment..."
echo ""

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
echo -n "VIP $VIP availability (must be free): "
ping -c 1 -W 2 "$VIP" &>/dev/null && echo "IN USE - WARNING!" || echo "Available ✓"

echo ""
echo "=== Summary ==="
echo "Report saved to: $REPORT_FILE"
echo ""
echo "For NKP deployment, use these parameters:"
first_cp="${CONTROL_PLANE_IPS[0]}"
iface=$(run_cmd "$first_cp" "ip -4 route show default | grep -oP 'dev \K\S+'" || echo "eth0")
echo "  --virtual-ip-interface $iface"
echo "  --control-plane-endpoint-host $VIP"
echo ""
echo "Key checks performed:"
echo "  • Swap: Must be disabled for Kubernetes memory management"
echo "  • Kernel modules: overlay (storage) and br_netfilter (networking)"
echo "  • IP forwarding: Required for pod-to-pod communication"
echo "  • Bridge netfilter: Allows iptables rules on bridged traffic"
echo "  • Firewall: Disabled to allow Kubernetes to manage its own rules"
echo "  • Storage dirs: Local persistent volumes for stateful workloads"
