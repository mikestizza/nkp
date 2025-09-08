#!/bin/bash

# NKP Bare Metal Infrastructure Validation Script - Read Only
# Version: 1.0
# This script validates infrastructure readiness for NKP deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Arrays to store IPs
declare -a CONTROL_PLANE_IPS
declare -a WORKER_IPS
declare -a HOSTNAMES

# Validation results
VALIDATION_PASSED=true
VALIDATION_REPORT="validation-report-$(date +%Y%m%d-%H%M%S).txt"

# Function to print colored output
print_msg() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
    echo "$msg" >> "$VALIDATION_REPORT"
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        if [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]; then
            return 0
        fi
    fi
    return 1
}

# Function to test SSH connectivity
test_ssh() {
    local ip=$1
    local user=$2
    local key=$3
    
    timeout 5 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$key" "$user@$ip" "echo 'SSH OK'" &>/dev/null
    return $?
}

# Function to check node prerequisites
check_node_prereqs() {
    local ip=$1
    local user=$2
    local key=$3
    local node_type=$4
    local node_passed=true
    
    print_msg "$BLUE" "\nValidating $node_type node: $ip"
    print_msg "$BLUE" "----------------------------------------"
    
    # Check OS version
    local os_info=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "lsb_release -d 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME" 2>/dev/null || echo "Unknown")
    print_msg "$BLUE" "  OS: $os_info"
    
    # Check user sudo privileges
    ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "sudo -n true" 2>/dev/null
    if [ $? -ne 0 ]; then
        print_msg "$RED" "  ✗ FAIL: User $user cannot sudo without password"
        print_msg "$YELLOW" "    Fix: echo '$user ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$user"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: User has passwordless sudo"
    fi
    
    # Check swap
    local swap_status=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "swapon -s | wc -l" 2>/dev/null)
    if [ "$swap_status" -gt 1 ]; then
        print_msg "$RED" "  ✗ FAIL: Swap is enabled"
        print_msg "$YELLOW" "    Fix: sudo swapoff -a && sudo sed -i '/ swap / s/^/#/' /etc/fstab"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: Swap is disabled"
    fi
    
    # Check kernel modules
    local overlay_loaded=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "lsmod | grep -c overlay" 2>/dev/null || echo "0")
    local br_netfilter_loaded=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "lsmod | grep -c br_netfilter" 2>/dev/null || echo "0")
    
    if [ "$overlay_loaded" -eq 0 ]; then
        print_msg "$RED" "  ✗ FAIL: Overlay kernel module not loaded"
        print_msg "$YELLOW" "    Fix: sudo modprobe overlay && echo 'overlay' | sudo tee -a /etc/modules-load.d/k8s.conf"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: Overlay module loaded"
    fi
    
    if [ "$br_netfilter_loaded" -eq 0 ]; then
        print_msg "$RED" "  ✗ FAIL: br_netfilter kernel module not loaded"
        print_msg "$YELLOW" "    Fix: sudo modprobe br_netfilter && echo 'br_netfilter' | sudo tee -a /etc/modules-load.d/k8s.conf"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: br_netfilter module loaded"
    fi
    
    # Check sysctl settings
    local ip_forward=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "sysctl -n net.ipv4.ip_forward" 2>/dev/null || echo "0")
    if [ "$ip_forward" != "1" ]; then
        print_msg "$RED" "  ✗ FAIL: IP forwarding not enabled"
        print_msg "$YELLOW" "    Fix: Add to /etc/sysctl.d/k8s.conf: net.ipv4.ip_forward = 1"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: IP forwarding enabled"
    fi
    
    # Check time synchronization
    local time_sync=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "timedatectl show --property=NTPSynchronized --value" 2>/dev/null)
    if [ "$time_sync" != "yes" ]; then
        print_msg "$RED" "  ✗ FAIL: Time not synchronized via NTP"
        print_msg "$YELLOW" "    Fix: sudo apt install chrony && sudo systemctl enable --now chrony"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: Time synchronized via NTP"
    fi
    
    # Check DNS resolution
    ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "nslookup google.com >/dev/null 2>&1"
    if [ $? -ne 0 ]; then
        print_msg "$RED" "  ✗ FAIL: DNS resolution not working"
        print_msg "$YELLOW" "    Fix: Check /etc/resolv.conf for valid nameservers"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: DNS resolution working"
    fi
    
    # Check required packages
    local missing_pkgs=""
    for pkg in curl wget socat conntrack ipset; do
        ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "which $pkg >/dev/null 2>&1"
        if [ $? -ne 0 ]; then
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done
    
    if [ -n "$missing_pkgs" ]; then
        print_msg "$RED" "  ✗ FAIL: Missing packages:$missing_pkgs"
        print_msg "$YELLOW" "    Fix: sudo apt-get update && sudo apt-get install -y$missing_pkgs"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: Required packages installed"
    fi
    
    # Check AppArmor status
    local apparmor=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "sudo aa-status 2>/dev/null | grep -c 'profiles are in enforce mode'" || echo "0")
    if [ "$apparmor" -gt 0 ]; then
        print_msg "$YELLOW" "  ⚠ WARN: AppArmor has $apparmor enforcing profiles (may cause issues)"
    fi
    
    # Check NetworkManager
    local nm_status=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "systemctl is-active NetworkManager 2>/dev/null" || echo "inactive")
    if [ "$nm_status" = "active" ]; then
        print_msg "$YELLOW" "  ⚠ WARN: NetworkManager is active (may interfere with CNI)"
        print_msg "$YELLOW" "    Consider: sudo systemctl disable --now NetworkManager"
    fi
    
    # Check firewall
    local ufw_status=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "sudo ufw status 2>/dev/null | grep -c 'Status: active'" || echo "0")
    if [ "$ufw_status" -gt 0 ]; then
        print_msg "$YELLOW" "  ⚠ WARN: UFW firewall is active (may block cluster communication)"
        print_msg "$YELLOW" "    Fix: sudo ufw disable"
    else
        print_msg "$GREEN" "  ✓ PASS: UFW firewall inactive"
    fi
    
    # Check disk space
    local disk_space=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "df -BG / | awk 'NR==2 {print \$4}' | sed 's/G//'" 2>/dev/null || echo "0")
    if [ "$disk_space" -lt 50 ]; then
        print_msg "$RED" "  ✗ FAIL: Insufficient disk space: ${disk_space}GB available (minimum 50GB required)"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: Root disk space: ${disk_space}GB available"
    fi
    
    # Check /var space
    local var_space=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "df -BG /var | awk 'NR==2 {print \$4}' | sed 's/G//'" 2>/dev/null || echo "0")
    if [ "$var_space" -lt 30 ]; then
        print_msg "$YELLOW" "  ⚠ WARN: Low /var space: ${var_space}GB (30GB+ recommended for container storage)"
    else
        print_msg "$GREEN" "  ✓ PASS: /var space: ${var_space}GB available"
    fi
    
    # Check memory
    local mem_gb=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "free -g | awk '/^Mem:/ {print \$2}'" 2>/dev/null || echo "0")
    local min_mem=8
    if [ "$node_type" == "Control Plane" ]; then
        min_mem=16
    elif [ "$node_type" == "Worker" ]; then
        min_mem=32
    fi
    
    if [ "$mem_gb" -lt "$min_mem" ]; then
        print_msg "$RED" "  ✗ FAIL: Insufficient memory: ${mem_gb}GB (minimum ${min_mem}GB required for $node_type)"
        node_passed=false
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: Memory: ${mem_gb}GB"
    fi
    
    # Check CPU
    local cpu_cores=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "nproc" 2>/dev/null || echo "0")
    if [ "$cpu_cores" -lt 4 ]; then
        print_msg "$YELLOW" "  ⚠ WARN: Only ${cpu_cores} CPU cores (4+ recommended)"
    else
        print_msg "$GREEN" "  ✓ PASS: CPU cores: ${cpu_cores}"
    fi
    
    # Check for existing Kubernetes installation
    local kubectl_exists=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "which kubectl 2>/dev/null" || echo "")
    if [ -n "$kubectl_exists" ]; then
        print_msg "$YELLOW" "  ⚠ WARN: Existing kubectl found at $kubectl_exists"
        print_msg "$YELLOW" "    Consider removing old Kubernetes packages"
    fi
    
    # Check hostname and resolution
    local hostname=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "hostname" 2>/dev/null || echo "unknown")
    local resolved_ip=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$ip" "getent hosts $hostname | awk '{print \$1}'" 2>/dev/null)
    
    if [ -z "$resolved_ip" ]; then
        print_msg "$YELLOW" "  ⚠ WARN: Hostname $hostname does not resolve locally"
        print_msg "$YELLOW" "    Fix: Add '127.0.1.1 $hostname' to /etc/hosts"
    else
        print_msg "$BLUE" "  ℹ Hostname: $hostname (resolves to $resolved_ip)"
    fi
    
    # Store hostname for uniqueness check
    HOSTNAMES+=("$hostname")
    
    return $([ "$node_passed" = true ])
}

# Function to check node connectivity
check_node_connectivity() {
    local from_ip=$1
    local to_ip=$2
    local user=$3
    local key=$4
    
    local ping_result=$(ssh -o StrictHostKeyChecking=no -i "$key" "$user@$from_ip" "ping -c 2 -W 2 $to_ip &>/dev/null && echo 'OK' || echo 'FAIL'" 2>/dev/null)
    
    if [ "$ping_result" == "OK" ]; then
        return 0
    else
        return 1
    fi
}

# Header
clear
echo "==================================================================" > "$VALIDATION_REPORT"
echo "NKP Bare Metal Infrastructure Validation Report" >> "$VALIDATION_REPORT"
echo "Generated: $(date)" >> "$VALIDATION_REPORT"
echo "==================================================================" >> "$VALIDATION_REPORT"

print_msg "$BLUE" "╔══════════════════════════════════════════════════════════╗"
print_msg "$BLUE" "║      NKP Bare Metal Infrastructure Validation           ║"
print_msg "$BLUE" "║                    (Read-Only)                          ║"
print_msg "$BLUE" "╚══════════════════════════════════════════════════════════╝"
echo

# Step 1: Collect cluster information
print_msg "$GREEN" "=== Step 1: Cluster Information ==="
echo

while [ -z "$CLUSTER_NAME" ]; do
    read -p "Enter cluster name: " CLUSTER_NAME
done

while [ -z "$SSH_USER" ]; do
    read -p "Enter SSH username for nodes: " SSH_USER
done

while [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; do
    read -p "Enter path to SSH private key: " SSH_KEY
    SSH_KEY=$(eval echo "$SSH_KEY")  # Expand tilde
    if [ ! -f "$SSH_KEY" ]; then
        print_msg "$RED" "Error: SSH key not found at $SSH_KEY"
    fi
done

# Step 2: Collect Control Plane IPs
echo
print_msg "$GREEN" "=== Step 2: Control Plane Nodes ==="
echo

while true; do
    read -p "Number of control plane nodes (1 or 3): " CP_COUNT
    if [[ "$CP_COUNT" == "1" || "$CP_COUNT" == "3" ]]; then
        break
    fi
    print_msg "$RED" "Error: Control plane must be 1 or 3 nodes for production"
done

for i in $(seq 1 $CP_COUNT); do
    while true; do
        read -p "Control Plane Node $i IP: " CP_IP
        if validate_ip "$CP_IP"; then
            CONTROL_PLANE_IPS+=("$CP_IP")
            break
        else
            print_msg "$RED" "Invalid IP address format"
        fi
    done
done

# Collect VIP for HA configuration
if [ "$CP_COUNT" -eq 3 ]; then
    while true; do
        read -p "Control Plane Virtual IP (VIP): " VIP
        if validate_ip "$VIP"; then
            break
        else
            print_msg "$RED" "Invalid IP address format"
        fi
    done
fi

# Step 3: Collect Worker IPs
echo
print_msg "$GREEN" "=== Step 3: Worker Nodes ==="
echo

while [ -z "$WORKER_COUNT" ] || ! [[ "$WORKER_COUNT" =~ ^[0-9]+$ ]] || [ "$WORKER_COUNT" -lt 1 ]; do
    read -p "Number of worker nodes (minimum 1): " WORKER_COUNT
done

for i in $(seq 1 $WORKER_COUNT); do
    while true; do
        read -p "Worker Node $i IP: " WORKER_IP
        if validate_ip "$WORKER_IP"; then
            WORKER_IPS+=("$WORKER_IP")
            break
        else
            print_msg "$RED" "Invalid IP address format"
        fi
    done
done

# Step 4: Run validations
echo
print_msg "$GREEN" "=== Step 4: Running Infrastructure Validation ==="
echo

# Test SSH connectivity
print_msg "$BLUE" "\n>>> SSH Connectivity Test"
print_msg "$BLUE" "----------------------------------------"
SSH_FAILED=""

for ip in "${CONTROL_PLANE_IPS[@]}" "${WORKER_IPS[@]}"; do
    if test_ssh "$ip" "$SSH_USER" "$SSH_KEY"; then
        print_msg "$GREEN" "  ✓ SSH to $ip: SUCCESS"
    else
        print_msg "$RED" "  ✗ SSH to $ip: FAILED"
        SSH_FAILED+="$ip "
        VALIDATION_PASSED=false
    fi
done

if [ -n "$SSH_FAILED" ]; then
    print_msg "$RED" "\n  SSH access failed to: $SSH_FAILED"
    print_msg "$YELLOW" "  Fix: Run 'ssh-copy-id $SSH_USER@<node-ip>' for each failed node"
    echo
    read -p "Continue validation anyway? (y/n): " continue_anyway
    if [ "$continue_anyway" != "y" ]; then
        exit 1
    fi
fi

# Check control plane nodes
print_msg "$BLUE" "\n>>> Control Plane Node Validation"
for ip in "${CONTROL_PLANE_IPS[@]}"; do
    check_node_prereqs "$ip" "$SSH_USER" "$SSH_KEY" "Control Plane"
done

# Check worker nodes
print_msg "$BLUE" "\n>>> Worker Node Validation"
for ip in "${WORKER_IPS[@]}"; do
    check_node_prereqs "$ip" "$SSH_USER" "$SSH_KEY" "Worker"
done

# Check hostname uniqueness
print_msg "$BLUE" "\n>>> Hostname Uniqueness Check"
print_msg "$BLUE" "----------------------------------------"
unique_hostnames=($(printf "%s\n" "${HOSTNAMES[@]}" | sort -u))
if [ ${#unique_hostnames[@]} -ne ${#HOSTNAMES[@]} ]; then
    print_msg "$RED" "  ✗ FAIL: Duplicate hostnames detected"
    print_msg "$YELLOW" "  All hostnames must be unique across the cluster"
    VALIDATION_PASSED=false
else
    print_msg "$GREEN" "  ✓ PASS: All hostnames are unique"
fi

# Check VIP interface consistency for HA
if [ "$CP_COUNT" -eq 3 ]; then
    print_msg "$BLUE" "\n>>> HA Configuration Validation"
    print_msg "$BLUE" "----------------------------------------"
    
    INTERFACES=()
    for ip in "${CONTROL_PLANE_IPS[@]}"; do
        interface=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$ip" "ip route get 8.8.8.8 | awk '{print \$5; exit}'" 2>/dev/null)
        INTERFACES+=("$interface")
        print_msg "$BLUE" "  Node $ip primary interface: $interface"
    done
    
    # Check if all interfaces are the same
    first_int="${INTERFACES[0]}"
    all_same=true
    for int in "${INTERFACES[@]}"; do
        if [ "$int" != "$first_int" ]; then
            all_same=false
            break
        fi
    done
    
    if [ "$all_same" = false ]; then
        print_msg "$RED" "  ✗ FAIL: Network interfaces are not consistent across control plane nodes"
        print_msg "$YELLOW" "  Fix: Ensure all control plane nodes use the same interface name for VIP"
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: All control plane nodes use interface: $first_int"
    fi
    
    # Test VIP availability
    ping -c 2 -W 2 "$VIP" &>/dev/null
    if [ $? -eq 0 ]; then
        print_msg "$RED" "  ✗ FAIL: VIP $VIP is already in use"
        VALIDATION_PASSED=false
    else
        print_msg "$GREEN" "  ✓ PASS: VIP $VIP is available"
    fi
fi

# Network connectivity mesh test
print_msg "$BLUE" "\n>>> Network Connectivity Test"
print_msg "$BLUE" "----------------------------------------"
print_msg "$BLUE" "  Testing node-to-node connectivity..."

connectivity_issues=false
for from_ip in "${CONTROL_PLANE_IPS[@]}" "${WORKER_IPS[@]}"; do
    for to_ip in "${CONTROL_PLANE_IPS[@]}" "${WORKER_IPS[@]}"; do
        if [ "$from_ip" != "$to_ip" ]; then
            if check_node_connectivity "$from_ip" "$to_ip" "$SSH_USER" "$SSH_KEY"; then
                echo -n "."
            else
                print_msg "$RED" "\n  ✗ No connectivity: $from_ip -> $to_ip"
                connectivity_issues=true
                VALIDATION_PASSED=false
            fi
        fi
    done
done

if [ "$connectivity_issues" = false ]; then
    print_msg "$GREEN" "\n  ✓ PASS: All nodes can communicate"
else
    print_msg "$YELLOW" "\n  Fix: Check network configuration and firewall rules"
fi

# Test external registry connectivity
print_msg "$BLUE" "\n>>> External Registry Connectivity Test"
print_msg "$BLUE" "----------------------------------------"

# Define Helm repositories (subset for brevity)
HELM_REPOS=(
    "charts.bitnami.com"
    "prometheus-community.github.io"
    "grafana.github.io"
    "mesosphere.github.io"
)

# Define container registries
CONTAINER_REGISTRIES=(
    "docker.io"
    "gcr.io"
    "registry.k8s.io"
    "quay.io"
    "ghcr.io"
)

# Function to test HTTPS connectivity
test_https_connectivity() {
    local node_ip=$1
    local target=$2
    local timeout=5
    
    # Test using curl with timeout
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$node_ip" \
        "curl -k --connect-timeout $timeout -s -o /dev/null -w '%{http_code}' https://$target 2>/dev/null | grep -qE '^[23][0-9]{2}$'" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        return 0
    fi
    
    # Fallback to nc test for port 443
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$node_ip" \
        "timeout $timeout nc -zv $target 443 &>/dev/null" 2>/dev/null
    
    return $?
}

registry_issues=false

print_msg "$BLUE" "  Testing registry connectivity from first node..."
test_node="${CONTROL_PLANE_IPS[0]}"

for registry in "${CONTAINER_REGISTRIES[@]}"; do
    if test_https_connectivity "$test_node" "$registry"; then
        print_msg "$GREEN" "  ✓ $registry: reachable"
    else
        print_msg "$RED" "  ✗ $registry: unreachable"
        registry_issues=true
        VALIDATION_PASSED=false
    fi
done

if [ "$registry_issues" = true ]; then
    print_msg "$YELLOW" "\n  Fix: Check outbound HTTPS (port 443) connectivity and firewall rules"
    print_msg "$YELLOW" "  Ensure all nodes can reach required Helm and container registries"
fi

# Final summary
echo
print_msg "$BLUE" "╔══════════════════════════════════════════════════════════╗"
print_msg "$BLUE" "║                   Validation Summary                     ║"
print_msg "$BLUE" "╚══════════════════════════════════════════════════════════╝"
echo

if [ "$VALIDATION_PASSED" = true ]; then
    print_msg "$GREEN" "✓ Infrastructure validation PASSED"
    print_msg "$GREEN" "\nYour infrastructure is ready for NKP deployment!"
else
    print_msg "$RED" "✗ Infrastructure validation FAILED"
    print_msg "$YELLOW" "\nIssues were found that must be resolved before deployment."
    print_msg "$YELLOW" "Review the detailed report above for specific fixes."
fi

echo
print_msg "$BLUE" "Full validation report saved to: $VALIDATION_REPORT"
echo
print_msg "$YELLOW" "Note: This is a read-only validation. No changes were made to any systems."
