#!/bin/bash

# NKP Bare Metal Node Readiness Check Script
# For Ubuntu 22.04 nodes preparing for Nutanix Kubernetes Platform deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script variables
SCRIPT_VERSION="1.0"
LOG_FILE="/tmp/nkp-readiness-check-$(date +%Y%m%d-%H%M%S).log"
SUMMARY_REPORT=""
NODE_TYPE=""
NODE_IP=""
NODE_HOSTNAME=""
ERRORS_FOUND=0

# Function to print colored output
print_status() {
    local status=$1
    local message=$2
    case $status in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} $message" | tee -a $LOG_FILE
            ;;
        "SUCCESS")
            echo -e "${GREEN}[✓]${NC} $message" | tee -a $LOG_FILE
            ;;
        "WARNING")
            echo -e "${YELLOW}[!]${NC} $message" | tee -a $LOG_FILE
            ;;
        "ERROR")
            echo -e "${RED}[✗]${NC} $message" | tee -a $LOG_FILE
            ERRORS_FOUND=$((ERRORS_FOUND + 1))
            ;;
    esac
}

# Function to check if running as root or with sudo
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        print_status "ERROR" "This script must be run as root or with sudo privileges"
        exit 1
    fi
}

# Function to gather node information
gather_node_info() {
    print_status "INFO" "=== Gathering Node Information ==="
    
    # Get node IP
    read -p "Enter this node's IP address: " NODE_IP
    if [[ ! $NODE_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        print_status "ERROR" "Invalid IP address format"
        exit 1
    fi
    
    # Get hostname
    CURRENT_HOSTNAME=$(hostname)
    read -p "Enter desired hostname (current: $CURRENT_HOSTNAME): " INPUT_HOSTNAME
    NODE_HOSTNAME=${INPUT_HOSTNAME:-$CURRENT_HOSTNAME}
    
    # Verify hostname is unique
    print_status "INFO" "Verifying hostname uniqueness..."
    if ping -c 1 -W 1 $NODE_HOSTNAME &>/dev/null && [ "$NODE_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
        print_status "WARNING" "Hostname $NODE_HOSTNAME appears to be in use on the network"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_status "SUCCESS" "Hostname $NODE_HOSTNAME appears to be unique"
    fi
    
    # Set hostname if different
    if [ "$NODE_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
        print_status "INFO" "Setting hostname to $NODE_HOSTNAME"
        hostnamectl set-hostname $NODE_HOSTNAME
        echo "$NODE_IP $NODE_HOSTNAME" >> /etc/hosts
    fi
    
    # Determine node type
    echo "Select node type:"
    echo "1) Control Plane Node"
    echo "2) Worker Node"
    echo "3) Both (Control Plane + Worker)"
    read -p "Enter choice [1-3]: " node_choice
    
    case $node_choice in
        1)
            NODE_TYPE="control-plane"
            ;;
        2)
            NODE_TYPE="worker"
            ;;
        3)
            NODE_TYPE="control-plane-worker"
            ;;
        *)
            print_status "ERROR" "Invalid choice"
            exit 1
            ;;
    esac
    
    print_status "SUCCESS" "Node configured as: $NODE_TYPE"
}

# Function to display network interfaces
display_network_interfaces() {
    print_status "INFO" "=== Network Interfaces ==="
    
    # Get all network interfaces
    interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo)
    
    echo "Available network interfaces on this node:"
    for iface in $interfaces; do
        ip_addr=$(ip -4 addr show $iface | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        mac_addr=$(ip link show $iface | grep -oP '(?<=link/ether\s)[a-f0-9:]+' | head -1)
        state=$(ip link show $iface | grep -oP '(?<=state\s)\w+' | head -1)
        
        echo -e "\n  Interface: ${GREEN}$iface${NC}"
        echo "    State: $state"
        echo "    IP: ${ip_addr:-Not configured}"
        echo "    MAC: ${mac_addr:-N/A}"
        
        # Check if this interface has the node IP
        if [ "$ip_addr" == "$NODE_IP" ]; then
            echo -e "    ${YELLOW}*** This interface has the node IP ***${NC}"
            PRIMARY_INTERFACE=$iface
        fi
    done
    
    echo -e "\n${YELLOW}Note: The virtual-ip-interface parameter should be set to the primary interface name${NC}"
    if [ ! -z "$PRIMARY_INTERFACE" ]; then
        echo -e "${GREEN}Recommended virtual-ip-interface: $PRIMARY_INTERFACE${NC}"
    fi
}

# Function to check and create user
check_create_user() {
    print_status "INFO" "=== Checking User Configuration ==="
    
    # Check if nkp user exists
    if id "nkp" &>/dev/null; then
        print_status "SUCCESS" "User 'nkp' exists"
    else
        print_status "WARNING" "User 'nkp' does not exist"
        read -p "Create 'nkp' user? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            useradd -m -s /bin/bash nkp
            echo "nkp:nkp123" | chpasswd
            print_status "SUCCESS" "User 'nkp' created with default password 'nkp123'"
            print_status "WARNING" "Please change the default password!"
        fi
    fi
    
    # Check sudoers
    if sudo -l -U nkp 2>/dev/null | grep -q "NOPASSWD: ALL"; then
        print_status "SUCCESS" "User 'nkp' has passwordless sudo access"
    else
        print_status "WARNING" "User 'nkp' does not have passwordless sudo access"
        read -p "Add 'nkp' to sudoers? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "nkp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/nkp
            print_status "SUCCESS" "User 'nkp' added to sudoers"
        fi
    fi
    
    # Setup SSH key for nkp user (if not exists)
    if [ ! -f /home/nkp/.ssh/id_rsa ]; then
        print_status "INFO" "Generating SSH key for nkp user"
        sudo -u nkp ssh-keygen -t rsa -b 4096 -f /home/nkp/.ssh/id_rsa -N ""
        print_status "SUCCESS" "SSH key generated for nkp user"
    else
        print_status "SUCCESS" "SSH key already exists for nkp user"
    fi
}

# Function to disable swap
disable_swap() {
    print_status "INFO" "=== Disabling Swap ==="
    
    # Check current swap status
    if [ $(swapon -s | wc -l) -gt 0 ]; then
        swapoff -a
        sed -i '/ swap / s/^/#/' /etc/fstab
        print_status "SUCCESS" "Swap disabled"
    else
        print_status "SUCCESS" "Swap already disabled"
    fi
    
    # Verify
    if free | grep -q "Swap:.*0.*0.*0"; then
        print_status "SUCCESS" "Swap verification passed"
    else
        print_status "ERROR" "Swap is still active"
    fi
}

# Function to load kernel modules
load_kernel_modules() {
    print_status "INFO" "=== Loading Kernel Modules ==="
    
    # Load required modules
    modprobe overlay
    modprobe br_netfilter
    
    # Make persistent
    cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
    
    # Verify modules are loaded
    if lsmod | grep -q overlay && lsmod | grep -q br_netfilter; then
        print_status "SUCCESS" "Kernel modules loaded successfully"
    else
        print_status "ERROR" "Failed to load kernel modules"
    fi
}

# Function to configure sysctl
configure_sysctl() {
    print_status "INFO" "=== Configuring Sysctl Parameters ==="
    
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
    
    sysctl --system &>/dev/null
    
    # Verify settings
    if [ "$(sysctl -n net.bridge.bridge-nf-call-iptables)" = "1" ] && \
       [ "$(sysctl -n net.bridge.bridge-nf-call-ip6tables)" = "1" ] && \
       [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]; then
        print_status "SUCCESS" "Sysctl parameters configured correctly"
    else
        print_status "ERROR" "Failed to configure sysctl parameters"
    fi
}

# Function to disable firewall
disable_firewall() {
    print_status "INFO" "=== Disabling Firewall ==="
    
    if systemctl is-active --quiet ufw; then
        ufw disable &>/dev/null
        systemctl stop ufw
        systemctl disable ufw &>/dev/null
        print_status "SUCCESS" "UFW firewall disabled"
    else
        print_status "SUCCESS" "UFW firewall already disabled"
    fi
}

# Function to clean Kubernetes packages
clean_kubernetes_packages() {
    print_status "INFO" "=== Cleaning Kubernetes Packages ==="
    
    # Remove any existing k8s packages
    apt-get remove -y kubelet kubeadm kubectl kubernetes-cni &>/dev/null || true
    rm -f /etc/apt/sources.list.d/kubernetes*.list
    apt-get update &>/dev/null
    
    print_status "SUCCESS" "Kubernetes packages cleaned"
}

# Function to create storage directories (for worker nodes)
create_storage_directories() {
    if [[ "$NODE_TYPE" == "worker" ]] || [[ "$NODE_TYPE" == "control-plane-worker" ]]; then
        print_status "INFO" "=== Creating Storage Directories ==="
        
        # Create local storage directories
        mkdir -p /mnt/local-storage/{pv1,pv2,pv3,pv4,pv5}
        chmod 777 /mnt/local-storage/*
        
        # Create prometheus directory
        mkdir -p /mnt/prometheus
        chmod 777 /mnt/prometheus
        
        print_status "SUCCESS" "Storage directories created"
        
        # List created directories
        echo "Created directories:"
        ls -la /mnt/local-storage/
        ls -la /mnt/prometheus
    fi
}

# Function to test container registry access
test_registry_access() {
    print_status "INFO" "=== Testing Container Registry Access ==="
    
    # List of registries to test
    declare -a registries=(
        "docker.io"
        "gcr.io"
        "k8s.gcr.io"
        "registry.k8s.io"
        "quay.io"
        "ghcr.io"
        "nvcr.io"
        "mcr.microsoft.com"
    )
    
    # Test connectivity to each registry
    echo "Testing registry connectivity:"
    for registry in "${registries[@]}"; do
        if timeout 5 curl -s -o /dev/null -w "%{http_code}" https://$registry 2>/dev/null | grep -q "200\|301\|302\|401\|403"; then
            echo -e "  $registry: ${GREEN}✓ Accessible${NC}"
        else
            echo -e "  $registry: ${RED}✗ Not accessible${NC}"
            print_status "WARNING" "Cannot reach $registry"
        fi
    done
    
    # Test pulling a small image (if docker/containerd is installed)
    if command -v docker &> /dev/null; then
        print_status "INFO" "Testing image pull with Docker..."
        if docker pull alpine:latest &>/dev/null; then
            print_status "SUCCESS" "Successfully pulled test image (alpine:latest)"
            docker rmi alpine:latest &>/dev/null
        else
            print_status "ERROR" "Failed to pull test image"
        fi
    elif command -v crictl &> /dev/null; then
        print_status "INFO" "Testing image pull with crictl..."
        if crictl pull alpine:latest &>/dev/null; then
            print_status "SUCCESS" "Successfully pulled test image (alpine:latest)"
        else
            print_status "ERROR" "Failed to pull test image"
        fi
    else
        print_status "WARNING" "No container runtime found to test image pull"
    fi
}

# Function to test helm repository access
test_helm_repo_access() {
    print_status "INFO" "=== Testing Helm Repository Access ==="
    
    # List of helm repositories to test
    declare -a helm_repos=(
        "pkg-containers.githubusercontent.com"
        "charts.bitnami.com"
        "charts.jetstack.io"
        "grafana.github.io"
        "prometheus-community.github.io"
        "kubernetes.github.io"
    )
    
    echo "Testing Helm repository connectivity:"
    for repo in "${helm_repos[@]}"; do
        if timeout 5 curl -s -o /dev/null -w "%{http_code}" https://$repo 2>/dev/null | grep -q "200\|301\|302\|403\|404"; then
            echo -e "  $repo: ${GREEN}✓ Accessible${NC}"
        else
            echo -e "  $repo: ${RED}✗ Not accessible${NC}"
            print_status "WARNING" "Cannot reach $repo"
        fi
    done
}

# Function to check network connectivity to cluster network
check_cluster_connectivity() {
    print_status "INFO" "=== Checking Cluster Network Connectivity ==="
    
    # Check if we can reach the VIP
    VIP="172.26.240.50"
    if ping -c 1 -W 2 $VIP &>/dev/null; then
        print_status "WARNING" "VIP $VIP is already in use! This should be unused."
    else
        print_status "SUCCESS" "VIP $VIP is not in use (as expected)"
    fi
    
    # Check connectivity to control plane subnet
    print_status "INFO" "Checking connectivity to 172.26.240.0/24 subnet"
    if ip route get 172.26.240.1 &>/dev/null; then
        print_status "SUCCESS" "Route to cluster subnet exists"
    else
        print_status "ERROR" "No route to cluster subnet 172.26.240.0/24"
    fi
}

# Function to generate summary report
generate_summary() {
    print_status "INFO" "=== Summary Report ==="
    
    echo -e "\n${BLUE}Node Readiness Check Summary${NC}"
    echo "=============================="
    echo "Node IP: $NODE_IP"
    echo "Hostname: $NODE_HOSTNAME"
    echo "Node Type: $NODE_TYPE"
    echo "Primary Interface: ${PRIMARY_INTERFACE:-Not detected}"
    echo ""
    
    if [ $ERRORS_FOUND -eq 0 ]; then
        echo -e "${GREEN}✓ All checks passed! Node is ready for NKP deployment.${NC}"
    else
        echo -e "${RED}✗ Found $ERRORS_FOUND error(s). Please fix these before proceeding.${NC}"
    fi
    
    echo ""
    echo "Log file saved to: $LOG_FILE"
    
    # Provide deployment hint
    if [ ! -z "$PRIMARY_INTERFACE" ]; then
        echo -e "\n${YELLOW}Deployment Hint:${NC}"
        echo "When running nkp create cluster, use:"
        echo "  --virtual-ip-interface $PRIMARY_INTERFACE"
    fi
}

# Function to perform all checks
run_all_checks() {
    check_privileges
    gather_node_info
    display_network_interfaces
    check_create_user
    disable_swap
    load_kernel_modules
    configure_sysctl
    disable_firewall
    clean_kubernetes_packages
    create_storage_directories
    test_registry_access
    test_helm_repo_access
    check_cluster_connectivity
}

# Main execution
main() {
    clear
    echo "=========================================="
    echo "NKP Bare Metal Node Readiness Check v$SCRIPT_VERSION"
    echo "=========================================="
    echo "This script will verify node readiness for NKP deployment"
    echo "Log file: $LOG_FILE"
    echo ""
    
    # Run all checks
    run_all_checks
    
    # Generate summary
    generate_summary
}

# Run main function
main
