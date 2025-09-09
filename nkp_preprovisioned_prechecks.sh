#!/bin/bash

# NKP Pre-requisite Checker - Updated with storage mount requirements

set -u

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Config
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="nkp-readiness-${TIMESTAMP}.txt"

# Arrays
CONTROL_PLANE_IPS=()
WORKER_IPS=()
DEPLOY_USER=""
SSH_USER=""

# Simple logging
log() {
    echo -e "$1" | tee -a "$REPORT_FILE"
}

# Gather configuration
echo "=== NKP Pre-requisite Checker ==="
echo ""
read -p "Deployment username to check: " DEPLOY_USER
read -p "Control plane IPs (comma-separated): " cp_input
IFS=',' read -ra CONTROL_PLANE_IPS <<< "$cp_input"

read -p "Worker node IPs (comma-separated): " w_input
IFS=',' read -ra WORKER_IPS <<< "$w_input"

read -p "SSH user [$(whoami)]: " input
SSH_USER=${input:-$(whoami)}

echo ""
log "Configuration:"
log "  Deploy User: $DEPLOY_USER"
log "  Control Plane: ${#CONTROL_PLANE_IPS[@]} nodes"
log "  Workers: ${#WORKER_IPS[@]} nodes"
log "  SSH User: $SSH_USER"
echo ""

# Check function for single node
check_node() {
    local node=$1
    local node_type=$2

    # Trim whitespace from node IP
    node=$(echo "$node" | xargs)

    echo "========================================="
    echo "$node_type: $node"
    echo "========================================="

    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$node" "
        DEPLOY_USER='$DEPLOY_USER'
        NODE_TYPE='$node_type'

        echo '1. User Configuration:'
        echo -n '   User '\$DEPLOY_USER' exists: '
        if id \$DEPLOY_USER &>/dev/null; then
            echo -e '\033[0;32m[PASS]\033[0m'
            echo -n '   In sudo group: '
            if groups \$DEPLOY_USER | grep -q sudo; then
                echo -e '\033[0;32m[PASS]\033[0m'
            else
                echo -e '\033[0;31m[FAIL]\033[0m'
            fi
            echo -n '   Has NOPASSWD sudo: '
            if [ -f /etc/sudoers.d/\$DEPLOY_USER ] && grep -q 'NOPASSWD:ALL' /etc/sudoers.d/\$DEPLOY_USER; then
                echo -e '\033[0;32m[PASS]\033[0m'
            else
                echo -e '\033[0;31m[FAIL]\033[0m'
            fi
        else
            echo -e '\033[0;31m[FAIL] User not found\033[0m'
        fi

        echo ''
        echo '2. Swap Status:'
        echo -n '   Swap disabled: '
        if swapon -s 2>/dev/null | grep -q '^/'; then
            echo -e '\033[0;31m[FAIL] Swap is active\033[0m'
        else
            echo -e '\033[0;32m[PASS]\033[0m'
        fi
        echo -n '   Swap in /etc/fstab: '
        if grep -q '^[^#].*swap' /etc/fstab; then
            echo -e '\033[0;31m[FAIL] Not commented out\033[0m'
        else
            echo -e '\033[0;32m[PASS] Disabled\033[0m'
        fi

        echo ''
        echo '3. Kernel Modules:'
        echo -n '   overlay loaded: '
        if lsmod | grep -q overlay; then
            echo -e '\033[0;32m[PASS]\033[0m'
        else
            echo -e '\033[0;31m[FAIL]\033[0m'
        fi
        echo -n '   br_netfilter loaded: '
        if lsmod | grep -q br_netfilter; then
            echo -e '\033[0;32m[PASS]\033[0m'
        else
            echo -e '\033[0;31m[FAIL]\033[0m'
        fi
        echo -n '   Persistent config: '
        if [ -f /etc/modules-load.d/k8s.conf ] && grep -q overlay /etc/modules-load.d/k8s.conf && grep -q br_netfilter /etc/modules-load.d/k8s.conf; then
            echo -e '\033[0;32m[PASS]\033[0m'
        else
            echo -e '\033[0;31m[FAIL]\033[0m'
        fi

        echo ''
        echo '4. Sysctl Settings:'
        echo -n '   bridge-nf-call-iptables = 1: '
        if [ \"\$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)\" = \"1\" ]; then
            echo -e '\033[0;32m[PASS]\033[0m'
        else
            echo -e '\033[0;31m[FAIL]\033[0m'
        fi
        echo -n '   bridge-nf-call-ip6tables = 1: '
        if [ \"\$(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null)\" = \"1\" ]; then
            echo -e '\033[0;32m[PASS]\033[0m'
        else
            echo -e '\033[0;31m[FAIL]\033[0m'
        fi
        echo -n '   ip_forward = 1: '
        if [ \"\$(sysctl -n net.ipv4.ip_forward 2>/dev/null)\" = \"1\" ]; then
            echo -e '\033[0;32m[PASS]\033[0m'
        else
            echo -e '\033[0;31m[FAIL]\033[0m'
        fi
        echo -n '   Persistent config: '
        if [ -f /etc/sysctl.d/k8s.conf ] && grep -q 'net.bridge.bridge-nf-call-iptables = 1' /etc/sysctl.d/k8s.conf; then
            echo -e '\033[0;32m[PASS]\033[0m'
        else
            echo -e '\033[0;31m[FAIL]\033[0m'
        fi

        echo ''
        echo '5. Firewall:'
        echo -n '   UFW status: '
        if ufw status 2>/dev/null | grep -q 'Status: active'; then
            echo -e '\033[0;31m[FAIL] Active\033[0m'
        else
            echo -e '\033[0;32m[PASS] Disabled\033[0m'
        fi

        echo ''
        echo '6. Kubernetes Packages:'
        echo -n '   kubelet: '
        dpkg -l kubelet 2>/dev/null | grep -q '^ii' && echo -e '\033[0;31m[FAIL] Installed\033[0m' || echo -e '\033[0;32m[PASS] Not installed\033[0m'
        echo -n '   kubeadm: '
        dpkg -l kubeadm 2>/dev/null | grep -q '^ii' && echo -e '\033[0;31m[FAIL] Installed\033[0m' || echo -e '\033[0;32m[PASS] Not installed\033[0m'
        echo -n '   kubectl: '
        dpkg -l kubectl 2>/dev/null | grep -q '^ii' && echo -e '\033[0;31m[FAIL] Installed\033[0m' || echo -e '\033[0;32m[PASS] Not installed\033[0m'
        echo -n '   kubernetes-cni: '
        dpkg -l kubernetes-cni 2>/dev/null | grep -q '^ii' && echo -e '\033[0;31m[FAIL] Installed\033[0m' || echo -e '\033[0;32m[PASS] Not installed\033[0m'
        echo -n '   K8s apt sources: '
        if ls /etc/apt/sources.list.d/kubernetes*.list 2>/dev/null | grep -q kubernetes; then
            echo -e '\033[0;31m[FAIL] Found\033[0m'
        else
            echo -e '\033[0;32m[PASS] Clean\033[0m'
        fi

        if [ \"\$NODE_TYPE\" = \"worker\" ]; then
            echo ''
            echo '7. Worker Storage - Local Volume Provisioner:'
            echo '   Checking for MOUNTED volumes (required by local-volume-provisioner):'
            
            # Check if any volumes are mounted
            MOUNT_COUNT=\$(mount | grep '/mnt/disks/vol' | wc -l)
            echo -n \"   Mounted volumes found: \$MOUNT_COUNT \"
            if [ \$MOUNT_COUNT -ge 4 ]; then
                echo -e '\033[0;32m[PASS] (minimum 4 required)\033[0m'
            else
                echo -e '\033[0;31m[FAIL] (minimum 4 required)\033[0m'
            fi
            
            # Check first 5 mounts specifically
            for i in 1 2 3 4 5; do
                echo -n \"   /mnt/disks/vol\$i mounted: \"
                if mount | grep -q \"/mnt/disks/vol\$i\"; then
                    echo -e '\033[0;32m[PASS]\033[0m'
                else
                    echo -e '\033[1;33m[WARN] Not mounted\033[0m'
                fi
            done
            
            echo ''
            echo '8. Worker Storage - Helm Repository Support:'
            echo -n '   /var/tmp/helm-repo directory: '
            if [ -d /var/tmp/helm-repo ] && [ \"\$(stat -c %a /var/tmp/helm-repo)\" = \"777\" ]; then
                echo -e '\033[0;32m[PASS]\033[0m'
            else
                echo -e '\033[0;31m[FAIL] Missing or wrong permissions\033[0m'
            fi
            
            echo ''
            echo '9. Worker Storage - Prometheus:'
            echo -n '   /mnt/prometheus directory: '
            if [ -d /mnt/prometheus ] && [ \"\$(stat -c %a /mnt/prometheus)\" = \"777\" ]; then
                echo -e '\033[0;32m[PASS]\033[0m'
            else
                echo -e '\033[0;31m[FAIL] Missing or wrong permissions\033[0m'
            fi
        fi
    " || echo "ERROR: Cannot connect to $node"

    echo ""
}

# Main execution
echo "=== Checking Prerequisites ==="
echo ""

# Loop through each control plane node individually
for node in "${CONTROL_PLANE_IPS[@]}"; do
    check_node "$node" "control-plane"
done

# Loop through each worker node individually
for node in "${WORKER_IPS[@]}"; do
    check_node "$node" "worker"
done

echo "========================================="
echo "Fix Commands (run on nodes that failed):"
echo "========================================="
cat << 'EOF'

# 1. Create user (if not exists)
sudo useradd -m -s /bin/bash nutanix
sudo usermod -aG sudo nutanix
echo "nutanix ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/nutanix

# 2. Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# 3. Load kernel modules
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOL | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOL

# 4. Configure sysctl
cat <<EOL | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOL
sudo sysctl --system

# 5. Disable firewall
sudo ufw disable

# 6. Clean up Kubernetes packages
sudo apt-get remove -y kubelet kubeadm kubectl kubernetes-cni || true
sudo rm -f /etc/apt/sources.list.d/kubernetes*.list
sudo apt-get update

# 7. Create MOUNTED storage for local-volume-provisioner (workers only)
# IMPORTANT: local-volume-provisioner requires actual mount points, not just directories

# Option A: For testing/PoC - Use tmpfs (data lost on reboot)
for i in {1..5}; do
    sudo mkdir -p /mnt/disks/vol${i}
    sudo mount -t tmpfs -o size=1G tmpfs /mnt/disks/vol${i}
done

# Option B: For production - Use real disk partitions
# Example for each disk:
# sudo mkfs.xfs -f /dev/sdX
# sudo mkdir -p /mnt/disks/volX  
# echo '/dev/sdX /mnt/disks/volX xfs defaults,noatime 0 2' | sudo tee -a /etc/fstab
# sudo mount -a

# 8. Create helm-repository storage directory (workers only)
sudo mkdir -p /var/tmp/helm-repo
sudo chmod 777 /var/tmp/helm-repo

# 9. Create Prometheus directory (workers only)
sudo mkdir -p /mnt/prometheus
sudo chmod 777 /mnt/prometheus

EOF

echo "Report saved to: $REPORT_FILE"
