#!/bin/bash

# NKP Pre-provisioned Infrastructure Checker - READ ONLY
# Version: 5.0 - Check only, no modifications
# Validates bare metal nodes for Kubernetes deployment readiness

set -u

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Config
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="nkp-readiness-report-${TIMESTAMP}.txt"

# Arrays
CONTROL_PLANE_IPS=()
WORKER_IPS=()
ALL_NODES=()
FAILED_NODES=0
TOTAL_ISSUES=0

# Simple logging
log() {
    echo -e "$1" | tee -a "$REPORT_FILE"
}

# Gather configuration
echo "=== NKP Cluster Readiness Check (Read-Only) ==="
echo ""
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

# Check single node
check_node() {
    local node=$1
    local node_type=$2
    local issues=0
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Checking $node_type: $node"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Run all checks in a single SSH session
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$node" '
        echo "  Hostname: $(hostname)"
        echo ""
        
        echo "  Network Configuration:"
        echo -n "    • Primary Interface (VIP binding): "
        ip -4 route show default | grep -oP "dev \K\S+" || echo "unknown"
        
        echo ""
        echo "  System Requirements:"
        
        echo -n "    • Swap Status (must be disabled): "
        if swapon -s 2>/dev/null | grep -q "^/"; then 
            echo -e "\033[0;31m✗ ENABLED\033[0m"
            issues=$((issues + 1))
        else 
            echo -e "\033[0;32m✓ Disabled\033[0m"
        fi
        
        echo -n "    • Kernel Modules (networking): "
        if lsmod | grep -q overlay && lsmod | grep -q br_netfilter; then 
            echo -e "\033[0;32m✓ Loaded\033[0m"
        else 
            echo -e "\033[0;31m✗ MISSING\033[0m"
            issues=$((issues + 1))
        fi
        
        echo -n "    • IP Forwarding (pod routing): "
        if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ]; then 
            echo -e "\033[0;32m✓ Enabled\033[0m"
        else 
            echo -e "\033[0;31m✗ DISABLED\033[0m"
            issues=$((issues + 1))
        fi
        
        echo -n "    • Bridge Netfilter (iptables): "
        if [ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)" = "1" ]; then 
            echo -e "\033[0;32m✓ Enabled\033[0m"
        else 
            echo -e "\033[0;31m✗ DISABLED\033[0m"
            issues=$((issues + 1))
        fi
        
        echo -n "    • Firewall Status: "
        if ufw status 2>/dev/null | grep -q "Status: active"; then 
            echo -e "\033[1;33m⚠ ACTIVE (verify K8s ports)\033[0m"
            issues=$((issues + 1))
        else 
            echo -e "\033[0;32m✓ Disabled\033[0m"
        fi
        
        echo -n "    • Container Runtime: "
        if command -v containerd &>/dev/null; then 
            echo -e "\033[0;32m✓ Containerd installed\033[0m"
        else 
            echo -e "\033[0;31m✗ NOT FOUND\033[0m"
            issues=$((issues + 1))
        fi
        
        echo -n "    • Old K8s Packages: "
        if dpkg -l 2>/dev/null | grep -E "kubelet|kubeadm|kubectl" | grep -q "^ii"; then 
            echo -e "\033[1;33m⚠ Found (should be removed)\033[0m"
            issues=$((issues + 1))
        else 
            echo -e "\033[0;32m✓ Clean\033[0m"
        fi
        
        if [ "'$node_type'" = "worker" ]; then
            echo ""
            echo "  Worker Storage Requirements:"
            
            echo -n "    • Local PV Directories: "
            if [ -d /mnt/local-storage/pv1 ]; then 
                echo -e "\033[0;32m✓ Configured\033[0m"
            else 
                echo -e "\033[0;31m✗ NOT FOUND\033[0m"
                issues=$((issues + 1))
            fi
            
            echo -n "    • Prometheus Storage: "
            if [ -d /mnt/prometheus ]; then 
                echo -e "\033[0;32m✓ Configured\033[0m"
            else 
                echo -e "\033[0;31m✗ NOT FOUND\033[0m"
                issues=$((issues + 1))
            fi
        fi
        
        exit $issues
    '
    
    local result=$?
    if [ $result -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}Issues found: $result${NC}"
        TOTAL_ISSUES=$((TOTAL_ISSUES + result))
    else
        echo ""
        echo -e "  ${GREEN}✓ All checks passed${NC}"
    fi
    
    echo ""
    return $result
}

# Main execution
echo "=== Starting Cluster Validation ==="
echo "Checking prerequisites for NKP deployment..."
echo ""

for node in "${CONTROL_PLANE_IPS[@]}"; do
    if ! check_node "$node" "control-plane"; then
        FAILED_NODES=$((FAILED_NODES + 1))
    fi
done

for node in "${WORKER_IPS[@]}"; do
    if ! check_node "$node" "worker"; then
        FAILED_NODES=$((FAILED_NODES + 1))
    fi
done

# Network test
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Network Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -n "  VIP $VIP Status: "
if ping -c 1 -W 2 "$VIP" &>/dev/null; then
    echo -e "${RED}✗ IN USE (must be free!)${NC}"
    TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
else
    echo -e "${GREEN}✓ Available${NC}"
fi

# Final summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VALIDATION SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $TOTAL_ISSUES -eq 0 ]; then
    echo -e "${GREEN}✓ CLUSTER READY${NC}"
    echo "All nodes passed validation checks"
else
    echo -e "${RED}✗ CLUSTER NOT READY${NC}"
    echo "Found $TOTAL_ISSUES total issue(s) across $FAILED_NODES node(s)"
    echo ""
    echo "Required fixes:"
    echo "  • Disable swap: swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab"
    echo "  • Load modules: modprobe overlay br_netfilter"
    echo "  • Enable IP forward: sysctl -w net.ipv4.ip_forward=1"
    echo "  • Configure bridge: sysctl -w net.bridge.bridge-nf-call-iptables=1"
    echo "  • Disable firewall: ufw disable"
    echo "  • Install containerd if missing"
    echo "  • Create worker storage: mkdir -p /mnt/local-storage/pv{1..5} /mnt/prometheus"
fi

echo ""
echo "Deployment parameters for NKP:"
first_cp="${CONTROL_PLANE_IPS[0]}"
iface=$(run_cmd "$first_cp" "ip -4 route show default | grep -oP 'dev \K\S+'" || echo "eth0")
echo "  --virtual-ip-interface $iface"
echo "  --control-plane-endpoint-host $VIP"
echo ""
echo "Full report saved to: $REPORT_FILE"
