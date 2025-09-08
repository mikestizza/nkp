#!/bin/bash

# Ubuntu 22.04 NKP Prerequisites Validation Script - Read Only
# Version: 1.0
# Purpose: Validate Ubuntu 22.04 readiness for NKP deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script must run as root or with sudo
if [ "$EUID" -ne 0 ]; then 
    echo "This script must run as root or with sudo"
    exit 1
fi

# Validation results
VALIDATION_PASSED=true
REPORT_FILE="/tmp/nkp-prereq-report-$(date +%Y%m%d-%H%M%S).txt"

# Function to print colored output
print_msg() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
    echo "$msg" >> "$REPORT_FILE"
}

# Function to check a prerequisite
check_prereq() {
    local check_name=$1
    local check_cmd=$2
    local description=$3
    local fix_instruction=$4
    
    print_msg "$BLUE" "\nChecking: $description"
    
    if eval "$check_cmd"; then
        print_msg "$GREEN" "  ✓ PASS: $description"
        return 0
    else
        print_msg "$RED" "  ✗ FAIL: $description"
        if [ -n "$fix_instruction" ]; then
            print_msg "$YELLOW" "  Fix: $fix_instruction"
        fi
        VALIDATION_PASSED=false
        return 1
    fi
}

# Header
clear
echo "==================================================================" > "$REPORT_FILE"
echo "Ubuntu 22.04 NKP Prerequisites Validation Report" >> "$REPORT_FILE"
echo "Generated: $(date)" >> "$REPORT_FILE"
echo "Hostname: $(hostname)" >> "$REPORT_FILE"
echo "==================================================================" >> "$REPORT_FILE"

print_msg "$BLUE" "╔══════════════════════════════════════════════════════════╗"
print_msg "$BLUE" "║   Ubuntu 22.04 NKP Prerequisites Validation (Read-Only)  ║"
print_msg "$BLUE" "╚══════════════════════════════════════════════════════════╝"
echo

# System Information
print_msg "$GREEN" "=== System Information ==="
print_msg "$BLUE" "  OS: $(lsb_release -d | cut -f2)"
print_msg "$BLUE" "  Kernel: $(uname -r)"
print_msg "$BLUE" "  Architecture: $(uname -m)"
print_msg "$BLUE" "  Hostname: $(hostname)"
print_msg "$BLUE" "  CPU Cores: $(nproc)"
print_msg "$BLUE" "  Memory: $(free -h | awk '/^Mem:/ {print $2}')"
print_msg "$BLUE" "  Disk: $(df -h / | awk 'NR==2 {print $4}') available on /"
print_msg "$BLUE" "  /var: $(df -h /var | awk 'NR==2 {print $4}') available"

# Prerequisites Checks
print_msg "$GREEN" "\n=== Prerequisites Validation ==="

# 1. Check Ubuntu version
check_prereq "ubuntu_version" \
    "[[ $(lsb_release -rs) == '22.04' ]]" \
    "Ubuntu 22.04 LTS" \
    "Install Ubuntu 22.04 LTS"

# 2. Check NKP user with sudo
check_prereq "nkp_user" \
    "id nutanix >/dev/null 2>&1 && sudo -u nutanix -n true 2>/dev/null" \
    "User 'nutanix' exists with passwordless sudo" \
    "useradd -m -s /bin/bash nutanix && echo 'nutanix ALL=(ALL) NOPASSWD:ALL' | tee /etc/sudoers.d/nutanix"

# 3. Check swap
check_prereq "swap" \
    "[[ $(swapon -s | wc -l) -eq 0 ]]" \
    "Swap is disabled" \
    "swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab"

# 4. Check kernel modules
check_prereq "overlay_module" \
    "lsmod | grep -q overlay" \
    "Overlay kernel module loaded" \
    "modprobe overlay && echo 'overlay' >> /etc/modules-load.d/k8s.conf"

check_prereq "br_netfilter_module" \
    "lsmod | grep -q br_netfilter" \
    "br_netfilter kernel module loaded" \
    "modprobe br_netfilter && echo 'br_netfilter' >> /etc/modules-load.d/k8s.conf"

# 5. Check sysctl settings
check_prereq "ip_forward" \
    "[[ $(sysctl -n net.ipv4.ip_forward) == '1' ]]" \
    "IPv4 forwarding enabled" \
    "Add 'net.ipv4.ip_forward = 1' to /etc/sysctl.d/k8s.conf && sysctl -p"

check_prereq "bridge_nf_call_iptables" \
    "[[ $(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null) == '1' ]]" \
    "Bridge netfilter for iptables" \
    "Add 'net.bridge.bridge-nf-call-iptables = 1' to /etc/sysctl.d/k8s.conf"

check_prereq "bridge_nf_call_ip6tables" \
    "[[ $(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null) == '1' ]]" \
    "Bridge netfilter for ip6tables" \
    "Add 'net.bridge.bridge-nf-call-ip6tables = 1' to /etc/sysctl.d/k8s.conf"

# 6. Check firewall
check_prereq "ufw_disabled" \
    "! ufw status 2>/dev/null | grep -q 'Status: active'" \
    "UFW firewall is disabled" \
    "ufw disable"

# 7. Check time synchronization
check_prereq "time_sync" \
    "[[ $(timedatectl show --property=NTPSynchronized --value) == 'yes' ]]" \
    "NTP time synchronization enabled" \
    "apt-get install -y chrony && systemctl enable --now chrony"

# 8. Check DNS resolution
check_prereq "dns_resolution" \
    "nslookup google.com >/dev/null 2>&1" \
    "DNS resolution working" \
    "Check /etc/resolv.conf for valid nameservers"

# 9. Check hostname resolution
check_prereq "hostname_resolution" \
    "getent hosts $(hostname) >/dev/null 2>&1" \
    "Hostname resolves locally" \
    "Add '127.0.1.1 $(hostname)' to /etc/hosts"

# 10. Check required packages
REQUIRED_PACKAGES="curl wget socat conntrack ipset net-tools dnsutils chrony"
missing_packages=""
for pkg in $REQUIRED_PACKAGES; do
    if ! which $pkg >/dev/null 2>&1; then
        missing_packages="$missing_packages $pkg"
    fi
done

if [ -z "$missing_packages" ]; then
    print_msg "$GREEN" "\n  ✓ PASS: All required packages installed"
else
    print_msg "$RED" "\n  ✗ FAIL: Missing packages:$missing_packages"
    print_msg "$YELLOW" "  Fix: apt-get update && apt-get install -y$missing_packages"
    VALIDATION_PASSED=false
fi

# 11. Check for conflicting Kubernetes packages
if dpkg -l | grep -qE 'kubelet|kubeadm|kubectl|kubernetes-cni'; then
    print_msg "$RED" "\n  ✗ FAIL: Existing Kubernetes packages found"
    print_msg "$YELLOW" "  Fix: apt-get remove -y kubelet kubeadm kubectl kubernetes-cni"
    VALIDATION_PASSED=false
else
    print_msg "$GREEN" "\n  ✓ PASS: No conflicting Kubernetes packages"
fi

# 12. Check AppArmor
apparmor_profiles=$(aa-status 2>/dev/null | grep -c 'profiles are in enforce mode' || echo "0")
if [ "$apparmor_profiles" -gt 0 ]; then
    print_msg "$YELLOW" "\n  ⚠ WARNING: AppArmor has $apparmor_profiles enforcing profiles"
    print_msg "$YELLOW" "  This may cause issues with container operations"
fi

# 13. Check NetworkManager
if systemctl is-active NetworkManager >/dev/null 2>&1; then
    print_msg "$YELLOW" "\n  ⚠ WARNING: NetworkManager is active"
    print_msg "$YELLOW" "  This may interfere with CNI networking"
    print_msg "$YELLOW" "  Consider: systemctl disable --now NetworkManager"
fi

# 14. Check disk space
root_space=$(df -BG / | awk 'NR==2 {print int($4)}')
if [ "$root_space" -ge 50 ]; then
    print_msg "$GREEN" "\n  ✓ PASS: Root filesystem has ${root_space}GB free (minimum 50GB)"
else
    print_msg "$RED" "\n  ✗ FAIL: Insufficient disk space on /: ${root_space}GB (minimum 50GB required)"
    VALIDATION_PASSED=false
fi

# 15. Check /var space
var_space=$(df -BG /var | awk 'NR==2 {print int($4)}')
if [ "$var_space" -ge 30 ]; then
    print_msg "$GREEN" "  ✓ PASS: /var has ${var_space}GB free (minimum 30GB)"
else
    print_msg "$YELLOW" "  ⚠ WARNING: Low space in /var: ${var_space}GB (30GB+ recommended)"
fi

# 16. Check memory
mem_gb=$(free -g | awk '/^Mem:/ {print int($2)}')
if [ "$mem_gb" -ge 8 ]; then
    print_msg "$GREEN" "  ✓ PASS: System has ${mem_gb}GB RAM (minimum 8GB)"
else
    print_msg "$RED" "  ✗ FAIL: Insufficient memory: ${mem_gb}GB (minimum 8GB required)"
    VALIDATION_PASSED=false
fi

# 17. Check CPU cores
cpu_cores=$(nproc)
if [ "$cpu_cores" -ge 4 ]; then
    print_msg "$GREEN" "  ✓ PASS: System has ${cpu_cores} CPU cores (minimum 4)"
else
    print_msg "$RED" "  ✗ FAIL: Insufficient CPU cores: ${cpu_cores} (minimum 4 required)"
    VALIDATION_PASSED=false
fi

# 18. Check overlay filesystem support
if grep -q overlay /proc/filesystems; then
    print_msg "$GREEN" "  ✓ PASS: Overlay filesystem is supported"
else
    print_msg "$RED" "  ✗ FAIL: Overlay filesystem not supported"
    print_msg "$YELLOW" "  Fix: Kernel upgrade may be required"
    VALIDATION_PASSED=false
fi

# 19. Check storage directories
if [ -d /mnt/local-storage/pv1 ]; then
    print_msg "$GREEN" "  ✓ PASS: Local storage directories exist"
else
    print_msg "$YELLOW" "  ⚠ INFO: Local storage directories not created"
    print_msg "$YELLOW" "  Fix: mkdir -p /mnt/local-storage/{pv1,pv2,pv3,pv4,pv5} && chmod 777 /mnt/local-storage/*"
fi

if [ -d /mnt/prometheus ]; then
    print_msg "$GREEN" "  ✓ PASS: Prometheus storage directory exists"
else
    print_msg "$YELLOW" "  ⚠ INFO: Prometheus storage directory not created"
    print_msg "$YELLOW" "  Fix: mkdir -p /mnt/prometheus && chmod 777 /mnt/prometheus"
fi

# 20. Network connectivity tests
print_msg "$GREEN" "\n=== External Connectivity Validation ==="

# Container registries to check
REGISTRIES=(
    "docker.io"
    "gcr.io"
    "registry.k8s.io"
    "quay.io"
    "ghcr.io"
)

print_msg "$BLUE" "Checking container registry connectivity..."
registry_failed=false
for registry in "${REGISTRIES[@]}"; do
    if curl -k --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "https://$registry" 2>/dev/null | grep -qE '^[23][0-9]{2}$'; then
        print_msg "$GREEN" "  ✓ $registry: reachable"
    else
        print_msg "$RED" "  ✗ $registry: unreachable"
        registry_failed=true
        VALIDATION_PASSED=false
    fi
done

if [ "$registry_failed" = true ]; then
    print_msg "$YELLOW" "\n  Check your internet connectivity and firewall rules"
fi

# Final Summary
echo
print_msg "$BLUE" "╔══════════════════════════════════════════════════════════╗"
print_msg "$BLUE" "║                        Summary                           ║"
print_msg "$BLUE" "╚══════════════════════════════════════════════════════════╝"
echo

if [ "$VALIDATION_PASSED" = true ]; then
    print_msg "$GREEN" "✓ All prerequisites are met - system is ready for NKP"
else
    print_msg "$RED" "✗ Some prerequisites are not met"
    print_msg "$YELLOW" "\nReview the report above for specific issues and fixes."
    print_msg "$YELLOW" "Each failed item includes instructions on how to fix it."
fi

echo
print_msg "$BLUE" "Report saved to: $REPORT_FILE"
print_msg "$YELLOW" "\nNote: This is a read-only validation. No changes were made to the system."

# Create a status file for automation
if [ "$VALIDATION_PASSED" = true ]; then
    echo "READY" > /tmp/nkp-ready-status
else
    echo "NOT_READY" > /tmp/nkp-ready-status
fi

exit $([ "$VALIDATION_PASSED" = true ] && echo 0 || echo 1)
