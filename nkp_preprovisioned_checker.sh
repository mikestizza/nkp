#!/bin/bash

# NKP Bare Metal Cluster Readiness Check Script v3.0
# Centralized Pre-check Script - Run from operator/management VM
# Performs remote validation of all cluster nodes via SSH
# For Ubuntu 22.04 nodes preparing for Nutanix Kubernetes Platform deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script variables
SCRIPT_VERSION="3.0"
LOG_FILE="/tmp/nkp-cluster-check-$(date +%Y%m%d-%H%M%S).log"
ERRORS_FOUND=0
WARNINGS_FOUND=0

# Cluster configuration variables
CONTROL_PLANE_IPS=()
WORKER_IPS=()
ALL_NODE_IPS=()
VIP=""
CLUSTER_SUBNET=""
DEPLOY_USER=""
SSH_USER=""
SSH_KEY=""
NODE_INTERFACES=()

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
            WARNINGS_FOUND=$((WARNINGS_FOUND + 1))
            ;;
        "ERROR")
            echo -e "${RED}[✗]${NC} $message" | tee -a $LOG_FILE
            ERRORS_FOUND=$((ERRORS_FOUND + 1))
            ;;
        "HEADER")
            echo -e "\n${CYAN}════════════════════════════════════════${NC}" | tee -a $LOG_FILE
            echo -e "${CYAN}▶ $message${NC}" | tee -a $LOG_FILE
            echo -e "${CYAN}════════════════════════════════════════${NC}" | tee -a $LOG_FILE
            ;;
        "NODE")
            echo -e "\n${BLUE}┌─ Node: $message${NC}" | tee -a $LOG_FILE
            ;;
    esac
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

# Function to test SSH connectivity
test_ssh_connection() {
    local ip=$1
    local user=$2
    local key_opt=""
    
    if [ ! -z "$SSH_KEY" ]; then
        key_opt="-i $SSH_KEY"
    fi
    
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes $key_opt $user@$ip "echo connected" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to execute command on remote node
remote_exec() {
    local ip=$1
    local cmd=$2
    local key_opt=""
    
    if [ ! -z "$SSH_KEY" ]; then
        key_opt="-i $SSH_KEY"
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o PasswordAuthentication=no $key_opt $SSH_USER@$ip "$cmd" 2>/dev/null
    elif [ ! -z "$SSH_PASSWORD" ]; then
        sshpass -p "$SSH_PASSWORD" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $SSH_USER@$ip "$cmd" 2>/dev/null
    else
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $SSH_USER@$ip "$cmd" 2>/dev/null
    fi
}

# Function to execute command with sudo on remote node
remote_sudo_exec() {
    local ip=$1
    local cmd=$2
    local key_opt=""
    
    if [ ! -z "$SSH_KEY" ]; then
        key_opt="-i $SSH_KEY"
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o PasswordAuthentication=no $key_opt $SSH_USER@$ip "sudo $cmd" 2>/dev/null
    elif [ ! -z "$SSH_PASSWORD" ]; then
        sshpass -p "$SSH_PASSWORD" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $SSH_USER@$ip "sudo $cmd" 2>/dev/null
    else
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $SSH_USER@$ip "sudo $cmd" 2>/dev/null
    fi
}

# Function to gather cluster configuration
gather_cluster_config() {
    print_status "HEADER" "Cluster Configuration Setup"
    
    # Get SSH user for connecting to nodes
    echo -e "\n${YELLOW}Enter SSH username for connecting to cluster nodes:${NC}"
    echo "This user must have sudo privileges on all nodes"
    read -p "SSH Username: " SSH_USER
    
    # Get SSH key if available
    echo -e "\n${YELLOW}Enter path to SSH private key (optional, press Enter to skip):${NC}"
    read -p "SSH Key Path: " key_input
    if [ ! -z "$key_input" ] && [ -f "$key_input" ]; then
        SSH_KEY="$key_input"
        print_status "SUCCESS" "SSH key found: $SSH_KEY"
    elif [ ! -z "$key_input" ]; then
        print_status "WARNING" "SSH key not found, will attempt password authentication"
    fi
    
    # Get deployment user
    echo -e "\n${YELLOW}Enter the username for NKP deployment:${NC}"
    echo "This user will be created/verified on all nodes"
    read -p "Deployment Username (default: nkp): " user_input
    DEPLOY_USER=${user_input:-nkp}
    
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
        ALL_NODE_IPS+=("$ip")
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
        ALL_NODE_IPS+=("$ip")
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
    echo "════════════════════════════════════"
    echo "SSH User: $SSH_USER"
    echo "Deployment User: $DEPLOY_USER"
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

# Function to test SSH connectivity to all nodes
test_all_ssh_connections() {
    print_status "HEADER" "Testing SSH Connectivity"
    
    local ssh_failed=0
    
    for ip in "${ALL_NODE_IPS[@]}"; do
        ip=$(echo $ip | xargs)
        echo -n "Testing SSH to $ip... "
        
        if test_ssh_connection "$ip" "$SSH_USER"; then
            echo -e "${GREEN}✓ Connected${NC}"
            
            # Test sudo access
            if remote_exec "$ip" "sudo -n echo test" &>/dev/null; then
                echo "  └─ Sudo access: ${GREEN}✓ Passwordless${NC}"
            else
                echo "  └─ Sudo access: ${YELLOW}! Requires password${NC}"
                print_status "WARNING" "Node $ip requires sudo password"
            fi
        else
            echo -e "${RED}✗ Failed${NC}"
            print_status "ERROR" "Cannot connect to $ip via SSH"
            ssh_failed=$((ssh_failed + 1))
        fi
    done
    
    if [ $ssh_failed -gt 0 ]; then
        print_status "ERROR" "SSH connection failed to $ssh_failed node(s)"
        echo -e "\n${YELLOW}Please ensure:${NC}"
        echo "1. SSH service is running on all nodes"
        echo "2. User '$SSH_USER' exists on all nodes"
        echo "3. SSH key or password authentication is configured"
        echo "4. No firewall is blocking SSH (port 22)"
        exit 1
    else
        print_status "SUCCESS" "SSH connectivity verified to all nodes"
    fi
}

# Function to check node prerequisites
check_node_prerequisites() {
    local ip=$1
    local node_type=$2
    
    print_status "NODE" "$ip ($node_type)"
    
    # Get hostname
    local hostname=$(remote_exec "$ip" "hostname")
    echo "  Hostname: $hostname"
    
    # Get network interfaces and find primary
    echo "  Network Interfaces:"
    local interfaces=$(remote_exec "$ip" "ip -o -4 addr show | grep -v '127.0.0.1'")
    local primary_iface=""
    
    while IFS= read -r line; do
        if [ ! -z "$line" ]; then
            local iface=$(echo $line | awk '{print $2}')
            local addr=$(echo $line | awk '{print $4}' | cut -d'/' -f1)
            
            if [ "$addr" == "$ip" ]; then
                primary_iface=$iface
                echo "    └─ ${GREEN}$iface: $addr (PRIMARY)${NC}"
                NODE_INTERFACES+=("$ip:$iface")
            else
                echo "    └─ $iface: $addr"
            fi
        fi
    done <<< "$interfaces"
    
    if [ -z "$primary_iface" ]; then
        print_status "ERROR" "Could not determine primary interface for $ip"
    fi
    
    # Check swap
    echo -n "  Swap Status: "
    if remote_exec "$ip" "swapon -s | grep -q '^/'" ; then
        echo -e "${RED}✗ Enabled${NC}"
        print_status "WARNING" "Swap is enabled on $ip"
    else
        echo -e "${GREEN}✓ Disabled${NC}"
    fi
    
    # Check kernel modules
    echo -n "  Kernel Modules: "
    local modules_ok=true
    for module in overlay br_netfilter; do
        if ! remote_exec "$ip" "lsmod | grep -q $module"; then
            modules_ok=false
        fi
    done
    
    if $modules_ok; then
        echo -e "${GREEN}✓ Loaded${NC}"
    else
        echo -e "${YELLOW}! Missing${NC}"
        print_status "WARNING" "Required kernel modules not loaded on $ip"
    fi
    
    # Check sysctl settings
    echo -n "  IP Forwarding: "
    local ipforward=$(remote_exec "$ip" "sysctl -n net.ipv4.ip_forward")
    if [ "$ipforward" = "1" ]; then
        echo -e "${GREEN}✓ Enabled${NC}"
    else
        echo -e "${YELLOW}! Disabled${NC}"
        print_status "WARNING" "IP forwarding disabled on $ip"
    fi
    
    # Check firewall
    echo -n "  Firewall: "
    if remote_exec "$ip" "systemctl is-active ufw" | grep -q "active"; then
        echo -e "${YELLOW}! Active${NC}"
        print_status "WARNING" "UFW firewall is active on $ip"
    else
        echo -e "${GREEN}✓ Disabled${NC}"
    fi
    
    # Check deployment user
    echo -n "  User '$DEPLOY_USER': "
    if remote_exec "$ip" "id $DEPLOY_USER" &>/dev/null; then
        echo -e "${GREEN}✓ Exists${NC}"
        
        # Check sudo access
        echo -n "    └─ Sudo: "
        if remote_exec "$ip" "sudo -l -U $DEPLOY_USER" | grep -q "NOPASSWD: ALL"; then
            echo -e "${GREEN}✓ Passwordless${NC}"
        else
            echo -e "${YELLOW}! Not configured${NC}"
            print_status "WARNING" "User $DEPLOY_USER needs sudo configuration on $ip"
        fi
    else
        echo -e "${YELLOW}! Does not exist${NC}"
        print_status "WARNING" "User $DEPLOY_USER needs to be created on $ip"
    fi
    
    # Check storage directories for worker nodes
    if [ "$node_type" = "worker" ]; then
        echo -n "  Storage Directories: "
        if remote_exec "$ip" "ls -d /mnt/local-storage/pv1 2>/dev/null" &>/dev/null; then
            echo -e "${GREEN}✓ Configured${NC}"
        else
            echo -e "${YELLOW}! Not configured${NC}"
            print_status "WARNING" "Storage directories need to be created on worker $ip"
        fi
    fi
    
    # Check container runtime
    echo -n "  Container Runtime: "
    if remote_exec "$ip" "docker --version" &>/dev/null; then
        echo -e "${GREEN}✓ Docker installed${NC}"
    elif remote_exec "$ip" "containerd --version" &>/dev/null; then
        echo -e "${GREEN}✓ Containerd installed${NC}"
    else
        echo -e "${YELLOW}! Not installed${NC}"
        print_status "WARNING" "No container runtime found on $ip"
    fi
}

# Function to fix node issues
fix_node_issues() {
    local ip=$1
    local node_type=$2
    
    print_status "INFO" "Attempting to fix issues on $ip..."
    
    # Create deployment user if needed
    if ! remote_exec "$ip" "id $DEPLOY_USER" &>/dev/null; then
        print_status "INFO" "Creating user $DEPLOY_USER on $ip"
        remote_sudo_exec "$ip" "useradd -m -s /bin/bash $DEPLOY_USER"
        remote_sudo_exec "$ip" "echo '$DEPLOY_USER:$DEPLOY_USER@k8s2025' | chpasswd"
        remote_sudo_exec "$ip" "echo '$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$DEPLOY_USER"
        remote_sudo_exec "$ip" "chmod 440 /etc/sudoers.d/$DEPLOY_USER"
        
        # Generate SSH key
        remote_sudo_exec "$ip" "sudo -u $DEPLOY_USER ssh-keygen -t rsa -b 4096 -f /home/$DEPLOY_USER/.ssh/id_rsa -N '' -q"
    fi
    
    # Disable swap
    print_status "INFO" "Disabling swap on $ip"
    remote_sudo_exec "$ip" "swapoff -a"
    remote_sudo_exec "$ip" "sed -i '/ swap / s/^/#/' /etc/fstab"
    
    # Load kernel modules
    print_status "INFO" "Loading kernel modules on $ip"
    remote_sudo_exec "$ip" "modprobe overlay"
    remote_sudo_exec "$ip" "modprobe br_netfilter"
    remote_sudo_exec "$ip" "cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF"
    
    # Configure sysctl
    print_status "INFO" "Configuring sysctl on $ip"
    remote_sudo_exec "$ip" "cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF"
    remote_sudo_exec "$ip" "sysctl --system"
    
    # Disable firewall
    print_status "INFO" "Disabling firewall on $ip"
    remote_sudo_exec "$ip" "ufw disable"
    remote_sudo_exec "$ip" "systemctl stop ufw"
    remote_sudo_exec "$ip" "systemctl disable ufw"
    
    # Clean Kubernetes packages
    print_status "INFO" "Cleaning Kubernetes packages on $ip"
    remote_sudo_exec "$ip" "apt-get remove -y kubelet kubeadm kubectl kubernetes-cni || true"
    remote_sudo_exec "$ip" "rm -f /etc/apt/sources.list.d/kubernetes*.list"
    
    # Create storage directories for workers
    if [ "$node_type" = "worker" ]; then
        print_status "INFO" "Creating storage directories on worker $ip"
        remote_sudo_exec "$ip" "mkdir -p /mnt/local-storage/{pv1,pv2,pv3,pv4,pv5}"
        remote_sudo_exec "$ip" "chmod 777 /mnt/local-storage/*"
        remote_sudo_exec "$ip" "mkdir -p /mnt/prometheus"
        remote_sudo_exec "$ip" "chmod 777 /mnt/prometheus"
    fi
    
    print_status "SUCCESS" "Fixes applied to $ip"
}

# Function to test cluster connectivity
test_cluster_connectivity() {
    print_status "HEADER" "Cluster Network Connectivity"
    
    # Check VIP availability
    print_status "INFO" "Checking VIP availability from operator VM..."
    if ping -c 1 -W 2 $VIP &>/dev/null; then
        print_status "WARNING" "VIP $VIP is already in use! This should be unused."
    else
        print_status "SUCCESS" "VIP $VIP is not in use (as expected)"
    fi
    
    # Test inter-node connectivity
    print_status "INFO" "Testing inter-node connectivity..."
    
    echo -e "\n${CYAN}Connectivity Matrix:${NC}"
    echo -n "From/To     "
    for target_ip in "${ALL_NODE_IPS[@]}"; do
        target_ip=$(echo $target_ip | xargs)
        printf "%-15s " "$target_ip"
    done
    echo ""
    
    for source_ip in "${ALL_NODE_IPS[@]}"; do
        source_ip=$(echo $source_ip | xargs)
        printf "%-12s" "$source_ip"
        
        for target_ip in "${ALL_NODE_IPS[@]}"; do
            target_ip=$(echo $target_ip | xargs)
            if [ "$source_ip" == "$target_ip" ]; then
                printf "%-15s " "---"
            else
                if remote_exec "$source_ip" "ping -c 1 -W 1 $target_ip" &>/dev/null; then
                    printf "${GREEN}%-15s${NC} " "✓"
                else
                    printf "${RED}%-15s${NC} " "✗"
                    print_status "WARNING" "$source_ip cannot reach $target_ip"
                fi
            fi
        done
        echo ""
    done
}

# Function to test registry access from nodes
test_registry_access() {
    print_status "HEADER" "Container Registry Access"
    
    # Test from first control plane node
    local test_node=${CONTROL_PLANE_IPS[0]}
    test_node=$(echo $test_node | xargs)
    
    print_status "INFO" "Testing registry access from $test_node"
    
    declare -a registries=(
        "docker.io"
        "gcr.io"
        "registry.k8s.io"
        "quay.io"
        "ghcr.io"
    )
    
    for registry in "${registries[@]}"; do
        echo -n "  $registry: "
        if remote_exec "$test_node" "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 https://$registry" | grep -q "200\|301\|302\|401\|403"; then
            echo -e "${GREEN}✓ Accessible${NC}"
        else
            echo -e "${RED}✗ Not accessible${NC}"
            print_status "WARNING" "Cannot reach $registry from cluster nodes"
        fi
    done
}

# Function to generate deployment script
generate_deployment_script() {
    print_status "HEADER" "Generating Deployment Script"
    
    # Find primary interface for first control plane
    local first_cp=${CONTROL_PLANE_IPS[0]}
    first_cp=$(echo $first_cp | xargs)
    local primary_iface=""
    
    for entry in "${NODE_INTERFACES[@]}"; do
        if [[ $entry == $first_cp:* ]]; then
            primary_iface=${entry#*:}
            break
        fi
    done
    
    if [ -z "$primary_iface" ]; then
        print_status "WARNING" "Could not determine primary interface, using default 'eth0'"
        primary_iface="eth0"
    fi
    
    # Create deployment script
    cat > /tmp/nkp-deploy.sh <<EOF
#!/bin/bash
# NKP Deployment Script
# Generated on $(date)

echo "Starting NKP deployment..."

nkp create cluster preprovisioned \\
  --cluster-name nkp-poc \\
  --control-plane-endpoint-host $VIP \\
  --virtual-ip-interface $primary_iface \\
  --control-plane-replicas ${#CONTROL_PLANE_IPS[@]} \\
  --worker-replicas ${#WORKER_IPS[@]} \\
  --namespace default

echo "Deployment command executed."
echo "Monitor the deployment with: nkp describe cluster nkp-poc"
EOF
    
    chmod +x /tmp/nkp-deploy.sh
    
    echo -e "\n${GREEN}Deployment script generated: /tmp/nkp-deploy.sh${NC}"
    echo -e "\n${YELLOW}NKP Deployment Command:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat /tmp/nkp-deploy.sh | grep -A10 "nkp create"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "\n${CYAN}Note: Virtual IP interface set to '$primary_iface'${NC}"
    echo "If this is incorrect, edit /tmp/nkp-deploy.sh before running"
}

# Function to generate summary report
generate_summary() {
    print_status "HEADER" "Cluster Readiness Summary"
    
    echo -e "\n${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}     Cluster Validation Complete         ${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    
    echo -e "\n${GREEN}Cluster Configuration:${NC}"
    echo "├─ Control Plane: ${#CONTROL_PLANE_IPS[@]} nodes"
    echo "├─ Workers: ${#WORKER_IPS[@]} nodes"
    echo "├─ VIP: $VIP"
    echo "├─ Subnet: $CLUSTER_SUBNET"
    echo "└─ Deployment User: $DEPLOY_USER"
    
    echo -e "\n${GREEN}Node Summary:${NC}"
    for ip in "${CONTROL_PLANE_IPS[@]}"; do
        ip=$(echo $ip | xargs)
        echo "├─ Control Plane: $ip"
    done
    for ip in "${WORKER_IPS[@]}"; do
        ip=$(echo $ip | xargs)
        echo "├─ Worker: $ip"
    done
    
    echo ""
    if [ $ERRORS_FOUND -eq 0 ] && [ $WARNINGS_FOUND -eq 0 ]; then
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${GREEN}✓ All checks passed!${NC}"
        echo -e "${GREEN}  Cluster is ready for NKP deployment${NC}"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    elif [ $ERRORS_FOUND -eq 0 ]; then
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}⚠ Found $WARNINGS_FOUND warning(s)${NC}"
        echo -e "${YELLOW}  Review warnings before deployment${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${RED}✗ Found $ERRORS_FOUND error(s) and $WARNINGS_FOUND warning(s)${NC}"
        echo -e "${RED}  Fix errors before proceeding${NC}"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    
    echo -e "\n${CYAN}Next Steps:${NC}"
    if [ $ERRORS_FOUND -eq 0 ]; then
        echo "1. Review the deployment script: /tmp/nkp-deploy.sh"
        echo "2. Ensure NKP CLI is installed on this operator VM"
        echo "3. Run the deployment: bash /tmp/nkp-deploy.sh"
        echo "4. Monitor deployment: nkp describe cluster nkp-poc"
    else
        echo "1. Fix the errors identified above"
        echo "2. Run this script again to verify fixes"
        echo "3. Proceed with deployment once all checks pass"
    fi
    
    echo -e "\n${BLUE}Log file: $LOG_FILE${NC}"
}

# Function to run all checks
run_all_checks() {
    # Test SSH connectivity first
    test_all_ssh_connections
    
    # Check prerequisites on all nodes
    print_status "HEADER" "Node Prerequisites Check"
    
    for ip in "${CONTROL_PLANE_IPS[@]}"; do
        ip=$(echo $ip | xargs)
        check_node_prerequisites "$ip" "control-plane"
    done
    
    for ip in "${WORKER_IPS[@]}"; do
        ip=$(echo $ip | xargs)
        check_node_prerequisites "$ip" "worker"
    done
    
    # Ask if user wants to fix issues
    if [ $WARNINGS_FOUND -gt 0 ] || [ $ERRORS_FOUND -gt 0 ]; then
        echo ""
        read -p "Do you want to automatically fix the issues found? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_status "HEADER" "Applying Fixes to Nodes"
            
            for ip in "${CONTROL_PLANE_IPS[@]}"; do
                ip=$(echo $ip | xargs)
                fix_node_issues "$ip" "control-plane"
            done
            
            for ip in "${WORKER_IPS[@]}"; do
                ip=$(echo $ip | xargs)
                fix_node_issues "$ip" "worker"
            done
            
            print_status "SUCCESS" "All fixes applied. Re-checking nodes..."
            
            # Reset counters and re-check
            ERRORS_FOUND=0
            WARNINGS_FOUND=0
            
            for ip in "${CONTROL_PLANE_IPS[@]}"; do
                ip=$(echo $ip | xargs)
                check_node_prerequisites "$ip" "control-plane"
            done
            
            for ip in "${WORKER_IPS[@]}"; do
                ip=$(echo $ip | xargs)
                check_node_prerequisites "$ip" "worker"
            done
        fi
    fi
    
    # Test cluster connectivity
    test_cluster_connectivity
    
    # Test registry access
    test_registry_access
    
    # Generate deployment script
    generate_deployment_script
}

# Main execution
main() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  NKP Cluster Readiness Check v$SCRIPT_VERSION - Centralized  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This script runs from your operator/management VM and"
    echo "performs remote validation of all cluster nodes via SSH."
    echo ""
    
    # Gather cluster configuration
    gather_cluster_config
    
    # Run all checks
    run_all_checks
    
    # Generate summary
    generate_summary
}

# Run main function
main
