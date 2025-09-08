#!/bin/bash

# NKP Bare Metal Node Readiness Check Script v2.0
# Enhanced for multi-node cluster validation
# For Ubuntu 22.04 nodes preparing for Nutanix Kubernetes Platform deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script variables
SCRIPT_VERSION="2.0"
LOG_FILE="/tmp/nkp-readiness-check-$(date +%Y%m%d-%H%M%S).log"
ERRORS_FOUND=0

# Cluster configuration variables
CONTROL_PLANE_IPS=()
WORKER_IPS=()
VIP=""
CLUSTER_SUBNET=""
CURRENT_NODE_IP=""
CURRENT_NODE_TYPE=""
CURRENT_HOSTNAME=""
PRIMARY_INTERFACE=""

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
        "HEADER")
            echo -e "\n${BLUE}=== $message ===${NC}" | tee -a $LOG_FILE
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

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to gather cluster configuration
gather_cluster_config() {
    print_status "HEADER" "Cluster Configuration"
    
    # Get control plane IPs
    echo -e "\n${YELLOW}Enter Control Plane node IPs (comma-separated):${NC}"
    echo "Example: 172.26.240.41,172.26.240.42,172.26.240.43"
    read -p "Control Plane IPs: " cp_input
    IFS=',' read -ra CONTROL_PLANE_IPS <<< "$cp_input"
    
    # Validate control plane IPs
    for ip in "${CONTROL_PLANE_IPS[@]}"; do
        ip=$(echo $ip | xargs) # trim whitespace
        if ! validate_ip "$ip"; then
            print_status "ERROR" "Invalid IP address: $ip"
            exit 1
        fi
    done
    print_status "SUCCESS" "Control Plane nodes: ${#CONTROL_PLANE_IPS[@]} configured"
    
    # Get worker IPs
    echo -e "\n${YELLOW}Enter Worker node IPs (comma-separated):${NC}"
    echo "Example: 172.26.240.44,172.26.240.45,172.26.240.46,172.26.240.47"
    read -p "Worker IPs: " worker_input
    IFS=',' read -ra WORKER_IPS <<< "$worker_input"
    
    # Validate worker IPs
    for ip in "${WORKER_IPS[@]}"; do
        ip=$(echo $ip | xargs) # trim whitespace
        if ! validate_ip "$ip"; then
            print_status "ERROR" "Invalid IP address: $ip"
            exit 1
        fi
    done
    print_status "SUCCESS" "Worker nodes: ${#WORKER_IPS[@]} configured"
    
    # Get VIP
    echo -e "\n${YELLOW}Enter Virtual IP (VIP) for API server:${NC}"
    read -p "VIP: " VIP
    if ! validate_ip "$VIP"; then
        print_status "ERROR" "Invalid VIP address: $VIP"
        exit 1
    fi
    
    # Get cluster subnet
    echo -e "\n${YELLOW}Enter cluster subnet (e.g., 172.26.240.0/24):${NC}"
    read -p "Cluster subnet: " CLUSTER_SUBNET
    
    # Display configuration summary
    echo -e "\n${GREEN}Cluster Configuration Summary:${NC}"
    echo "================================"
    echo "Control Plane nodes: ${CONTROL_PLANE_IPS[*]}"
    echo "Worker nodes: ${WORKER_IPS[*]}"
    echo "Virtual IP: $VIP"
    echo "Cluster subnet: $CLUSTER_SUBNET"
    echo ""
    
    read -p "Is this configuration correct? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "INFO" "Configuration cancelled. Please run the script again."
        exit 1
    fi
}

# Function to identify current node
identify_current_node() {
    print_status "HEADER" "Node Identification"
    
    # Get current hostname
    CURRENT_HOSTNAME=$(hostname)
    print_status "INFO" "Current hostname: $CURRENT_HOSTNAME"
    
    # Get all IPs on this node
    local node_ips=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1')
    
    print_status "INFO" "Detecting node type based on configured IPs..."
    
    # Check if this node is a control plane
    for ip in $node_ips; do
        for cp_ip in "${CONTROL_PLANE_IPS[@]}"; do
            cp_ip=$(echo $cp_ip | xargs)
            if [[ "$ip" == "$cp_ip" ]]; then
                CURRENT_NODE_IP=$ip
                CURRENT_NODE_TYPE="control-plane"
                print_status "SUCCESS" "This is a CONTROL PLANE node with IP: $CURRENT_NODE_IP"
                return
            fi
        done
    done
    
    # Check if this node is a worker
    for ip in $node_ips; do
        for worker_ip in "${WORKER_IPS[@]}"; do
            worker_ip=$(echo $worker_ip | xargs)
            if [[ "$ip" == "$worker_ip" ]]; then
                CURRENT_NODE_IP=$ip
                CURRENT_NODE_TYPE="worker"
                print_status "SUCCESS" "This is a WORKER node with IP: $CURRENT_NODE_IP"
                return
            fi
        done
    done
    
    # Node not found in configuration
    print_status "ERROR" "This node's IP is not in the cluster configuration!"
    echo "Node IPs found: $node_ips"
    echo "Please verify the cluster configuration."
    exit 1
}

# Function to display network interfaces
display_network_interfaces() {
    print_status "HEADER" "Network Interfaces"
    
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
        
        # Check if this interface has the current node IP
        if [ "$ip_addr" == "$CURRENT_NODE_IP" ]; then
            echo -e "    ${YELLOW}*** Primary interface for this node ***${NC}"
            PRIMARY_INTERFACE=$iface
        fi
    done
    
    if [ ! -z "$PRIMARY_INTERFACE" ]; then
        echo -e "\n${GREEN}Primary Interface Detected: $PRIMARY_INTERFACE${NC}"
        echo -e "${YELLOW}Use '--virtual-ip-interface $PRIMARY_INTERFACE' in NKP deployment${NC}"
    else
        print_status "WARNING" "Could not detect primary interface"
    fi
}

# Function to check and create user
check_create_user() {
    print_status "HEADER" "User Configuration"
    
    # Check if nkp user exists
    if id "nkp" &>/dev/null; then
        print_status "SUCCESS" "User 'nkp' exists"
    else
        print_status "INFO" "Creating user 'nkp'..."
        useradd -m -s /bin/bash nkp
        echo "nkp:nkp@k8s2024" | chpasswd
        print_status "SUCCESS" "User 'nkp' created with default password"
        print_status "WARNING" "Default password set to 'nkp@k8s2024' - Please change it!"
    fi
    
    # Check sudoers
    if sudo -l -U nkp 2>/dev/null | grep -q "NOPASSWD: ALL"; then
        print_status "SUCCESS" "User 'nkp' has passwordless sudo access"
    else
        print_status "INFO" "Adding 'nkp' to sudoers..."
        echo "nkp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/nkp
        print_status "SUCCESS" "User 'nkp' added to sudoers"
    fi
    
    # Setup SSH key for nkp user (if not exists)
    if [ ! -f /home/nkp/.ssh/id_rsa ]; then
        print_status "INFO" "Generating SSH key for nkp user"
        sudo -u nkp ssh-keygen -t rsa -b 4096 -f /home/nkp/.ssh/id_rsa -N "" -q
        print_status "SUCCESS" "SSH key generated for nkp user"
    else
        print_status "SUCCESS" "SSH key already exists for nkp user"
    fi
}

# Function to disable swap
disable_swap() {
    print_status "HEADER" "System Configuration - Swap"
    
    # Check current swap status
    if [ $(swapon -s | wc -l) -gt 1 ]; then
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
    print_status "HEADER" "Kernel Modules"
    
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
    print_status "HEADER" "Sysctl Parameters"
    
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
    print_status "HEADER" "Firewall Configuration"
    
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
    print_status "HEADER" "Kubernetes Package Cleanup"
    
    # Remove any existing k8s packages
    apt-get remove -y kubelet kubeadm kubectl kubernetes-cni &>/dev/null || true
    rm -f /etc/apt/sources.list.d/kubernetes*.list
    apt-get update &>/dev/null
    
    print_status "SUCCESS" "Kubernetes packages cleaned"
}

# Function to create storage directories (for worker nodes)
create_storage_directories() {
    if [[ "$CURRENT_NODE_TYPE" == "worker" ]]; then
        print_status "HEADER" "Storage Directories (Worker Node)"
        
        # Create local storage directories
        mkdir -p /mnt/local-storage/{pv1,pv2,pv3,pv4,pv5}
        chmod 777 /mnt/local-storage/*
        
        # Create prometheus directory
        mkdir -p /mnt/prometheus
        chmod 777 /mnt/prometheus
        
        print_status "SUCCESS" "Storage directories created"
        
        # List created directories
        echo "Created directories:"
        ls -ld /mnt/local-storage/pv* | head -5
        ls -ld /mnt/prometheus
    fi
}

# Function to test cluster network connectivity
test_cluster_connectivity() {
    print_status "HEADER" "Cluster Network Connectivity"
    
    # Check VIP availability
    print_status "INFO" "Checking VIP availability..."
    if ping -c 1 -W 2 $VIP &>/dev/null; then
        print_status "WARNING" "VIP $VIP is already in use! This should be unused."
    else
        print_status "SUCCESS" "VIP $VIP is not in use (as expected)"
    fi
    
    # Check connectivity to cluster subnet
    print_status "INFO" "Checking connectivity to cluster subnet $CLUSTER_SUBNET"
    
    # Extract network address from CIDR
    network_addr=$(echo $CLUSTER_SUBNET | cut -d'/' -f1)
    
    # Try to get route to network
    if ip route get $network_addr &>/dev/null; then
        print_status "SUCCESS" "Route to cluster subnet exists"
    else
        print_status "WARNING" "No direct route to cluster subnet $CLUSTER_SUBNET"
    fi
    
    # Test connectivity to other cluster nodes
    print_status "INFO" "Testing connectivity to cluster nodes..."
    
    echo -e "\nControl Plane nodes connectivity:"
    for cp_ip in "${CONTROL_PLANE_IPS[@]}"; do
        cp_ip=$(echo $cp_ip | xargs)
        if ping -c 1 -W 2 $cp_ip &>/dev/null; then
            echo -e "  $cp_ip: ${GREEN}✓ Reachable${NC}"
        else
            echo -e "  $cp_ip: ${RED}✗ Unreachable${NC}"
            if [[ "$cp_ip" != "$CURRENT_NODE_IP" ]]; then
                print_status "WARNING" "Cannot reach control plane node $cp_ip"
            fi
        fi
    done
    
    echo -e "\nWorker nodes connectivity:"
    for worker_ip in "${WORKER_IPS[@]}"; do
        worker_ip=$(echo $worker_ip | xargs)
        if ping -c 1 -W 2 $worker_ip &>/dev/null; then
            echo -e "  $worker_ip: ${GREEN}✓ Reachable${NC}"
        else
            echo -e "  $worker_ip: ${RED}✗ Unreachable${NC}"
            if [[ "$worker_ip" != "$CURRENT_NODE_IP" ]]; then
                print_status "WARNING" "Cannot reach worker node $worker_ip"
            fi
        fi
    done
}

# Function to test container registry access
test_registry_access() {
    print_status "HEADER" "Container Registry Access"
    
    # List of critical registries for NKP
    declare -a registries=(
        "docker.io"
        "gcr.io"
        "registry.k8s.io"
        "quay.io"
        "ghcr.io"
        "nvcr.io"
        "mcr.microsoft.com"
    )
    
    echo "Testing registry connectivity:"
    local failed_registries=0
    
    for registry in "${registries[@]}"; do
        if timeout 5 curl -s -o /dev/null -w "%{http_code}" https://$registry 2>/dev/null | grep -q "200\|301\|302\|401\|403"; then
            echo -e "  $registry: ${GREEN}✓ Accessible${NC}"
        else
            echo -e "  $registry: ${RED}✗ Not accessible${NC}"
            failed_registries=$((failed_registries + 1))
        fi
    done
    
    if [ $failed_registries -eq 0 ]; then
        print_status "SUCCESS" "All container registries accessible"
    else
        print_status "WARNING" "$failed_registries registries not accessible"
    fi
    
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
        print_status "INFO" "No container runtime found - skipping image pull test"
    fi
}

# Function to test helm repository access
test_helm_repo_access() {
    print_status "HEADER" "Helm Repository Access"
    
    # Critical helm repositories for NKP
    declare -a helm_repos=(
        "charts.bitnami.com"
        "charts.jetstack.io"
        "grafana.github.io"
        "prometheus-community.github.io"
        "kubernetes.github.io"
        "mesosphere.github.io"
    )
    
    echo "Testing Helm repository connectivity:"
    local failed_repos=0
    
    for repo in "${helm_repos[@]}"; do
        if timeout 5 curl -s -o /dev/null -w "%{http_code}" https://$repo 2>/dev/null | grep -q "200\|301\|302\|403\|404"; then
            echo -e "  $repo: ${GREEN}✓ Accessible${NC}"
        else
            echo -e "  $repo: ${RED}✗ Not accessible${NC}"
            failed_repos=$((failed_repos + 1))
        fi
    done
    
    if [ $failed_repos -eq 0 ]; then
        print_status "SUCCESS" "All Helm repositories accessible"
    else
        print_status "WARNING" "$failed_repos Helm repositories not accessible"
    fi
}

# Function to generate summary report
generate_summary() {
    print_status "HEADER" "Summary Report"
    
    echo -e "\n${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}     Node Readiness Check Complete      ${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}Cluster Configuration:${NC}"
    echo "├─ Deployment User: $DEPLOY_USER"
    echo "├─ Control Plane: ${#CONTROL_PLANE_IPS[@]} nodes"
    echo "├─ Workers: ${#WORKER_IPS[@]} nodes"
    echo "├─ VIP: $VIP"
    echo "└─ Subnet: $CLUSTER_SUBNET"
    
    echo -e "\n${GREEN}Current Node:${NC}"
    echo "├─ Hostname: $CURRENT_HOSTNAME"
    echo "├─ IP: $CURRENT_NODE_IP"
    echo "├─ Type: $CURRENT_NODE_TYPE"
    echo "└─ Primary Interface: ${PRIMARY_INTERFACE:-Not detected}"
    
    echo ""
    if [ $ERRORS_FOUND -eq 0 ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}✓ All checks passed!${NC}"
        echo -e "${GREEN}  Node is ready for NKP deployment${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}✗ Found $ERRORS_FOUND error(s)${NC}"
        echo -e "${RED}  Please fix these before proceeding${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    
    # Provide deployment command template
    if [[ "$CURRENT_NODE_TYPE" == "control-plane" ]] && [ ! -z "$PRIMARY_INTERFACE" ]; then
        echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}Deployment Command Template:${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "nkp create cluster preprovisioned \\"
        echo "  --cluster-name nkp-poc \\"
        echo "  --control-plane-endpoint-host $VIP \\"
        echo -e "  ${GREEN}--virtual-ip-interface $PRIMARY_INTERFACE${NC} \\"
        echo "  --control-plane-replicas ${#CONTROL_PLANE_IPS[@]} \\"
        echo "  --worker-replicas ${#WORKER_IPS[@]} \\"
        echo "  --namespace default"
    fi
    
    echo -e "\n${BLUE}Log file: $LOG_FILE${NC}"
}

# Function to perform all checks
run_all_checks() {
    identify_current_node
    display_network_interfaces
    check_create_user
    disable_swap
    load_kernel_modules
    configure_sysctl
    disable_firewall
    clean_kubernetes_packages
    create_storage_directories
    test_cluster_connectivity
    test_registry_access
    test_helm_repo_access
}

# Main execution
main() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   NKP Bare Metal Node Readiness Check v$SCRIPT_VERSION   ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This script will verify node readiness for NKP deployment"
    echo "and validate cluster-wide configuration."
    echo ""
    
    # Check privileges
    check_privileges
    
    # Gather cluster configuration
    gather_cluster_config
    
    # Run all checks
    run_all_checks
    
    # Generate summary
    generate_summary
}

# Run main function
main
