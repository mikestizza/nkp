#!/bin/bash

# Ubuntu 22.04 NKP Prerequisites Setup and Validation Script
# Version: 1.0
# Purpose: Prepare and validate Ubuntu 22.04 for NKP deployment

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
FIXES_APPLIED=false
REPORT_FILE="/tmp/nkp-prereq-report-$(date +%Y%m%d-%H%M%S).txt"

# Function to print colored output
print_msg() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
    echo "$msg" >> "$REPORT_FILE"
}

# Function to check and fix an issue
check_and_fix() {
    local check_name=$1
    local check_cmd=$2
    local fix_cmd=$3
    local description=$4
    
    print_msg "$BLUE" "\nChecking: $description"
    
    if eval "$check_cmd"; then
        print_msg "$GREEN" "  ✓ PASS: $description"
        return 0
    else
        print_msg "$YELLOW" "  ✗ FAIL: $description"
        
        if [ "$FIX_MODE" = true ]; then
            print_msg "$YELLOW" "  → Applying fix..."
            if eval "$fix_cmd"; then
                # Re-check after fix
                if eval "$check_cmd"; then
                    print_msg "$GREEN" "  ✓ FIXED: $description"
                    FIXES_APPLIED=true
                else
                    print_msg "$RED" "  ✗ Fix failed for: $description"
                    VALIDATION_PASSED=false
                fi
            else
                print_msg "$RED" "  ✗ Could not apply fix for: $description"
                VALIDATION_PASSED=false
            fi
        else
            VALIDATION_PASSED=false
        fi
    fi
}

# Header
clear
echo "==================================================================" > "$REPORT_FILE"
echo "Ubuntu 22.04 NKP Prerequisites Report" >> "$REPORT_FILE"
echo "Generated: $(date)" >> "$REPORT_FILE"
echo "Hostname: $(hostname)" >> "$REPORT_FILE"
echo "==================================================================" >> "$REPORT_FILE"

print_msg "$BLUE" "╔══════════════════════════════════════════════════════════╗"
print_msg "$BLUE" "║    Ubuntu 22.04 NKP Prerequisites Setup & Validation    ║"
print_msg "$BLUE" "╚══════════════════════════════════════════════════════════╝"
echo

# Check if running in fix mode
if [ "$1" == "--fix" ] || [ "$1" == "-f" ]; then
    FIX_MODE=true
    print_msg "$YELLOW" "Running in FIX mode - will attempt to fix issues automatically"
else
    FIX_MODE=false
    print_msg "$BLUE" "Running in CHECK mode - will only report issues"
    print_msg "$BLUE" "To auto-fix issues, run: $0 --fix"
fi
echo

# System Information
print_msg "$GREEN" "=== System Information ==="
print_msg "$BLUE" "  OS: $(lsb_release -d | cut -f2)"
print_msg "$BLUE" "  Kernel: $(uname -r)"
print_msg "$BLUE" "  Architecture: $(uname -m)"
print_msg "$BLUE" "  Hostname: $(hostname)"
print_msg "$BLUE" "  CPU Cores: $(nproc)"
print_msg "$BLUE" "  Memory: $(free -h | awk '/^Mem:/ {print $2}')"
print_msg "$BLUE" "  Disk: $(df -h / | awk 'NR==2 {print $4}') available"

# Prerequisites Checks
print_msg "$GREEN" "\n=== Prerequisites Validation ==="

# 1. Check Ubuntu version
check_and_fix "ubuntu_version" \
    "[[ $(lsb_release -rs) == '22.04' ]]" \
    "echo 'Cannot auto-fix OS version - manual reinstall required'" \
    "Ubuntu 22.04 LTS"

# 2. Check and create NKP user with sudo
check_and_fix "nkp_user" \
    "id nutanix >/dev/null 2>&1 && sudo -u nutanix -n true 2>/dev/null" \
    "useradd -m -s /bin/bash nutanix 2>/dev/null || true; echo 'nutanix ALL=(ALL) NOPASSWD:ALL' | tee /etc/sudoers.d/nutanix" \
    "NKP user (nutanix) with passwordless sudo"

# 3. Check and disable swap
check_and_fix "swap" \
    "[[ $(swapon -s | wc -l) -eq 0 ]]" \
    "swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab" \
    "Swap disabled"

# 4. Check and load kernel modules
check_and_fix "overlay_module" \
    "lsmod | grep -q overlay" \
    "modprobe overlay && echo 'overlay' >> /etc/modules-load.d/k8s.conf" \
    "Overlay kernel module"

check_and_fix "br_netfilter_module" \
    "lsmod | grep -q br_netfilter" \
    "modprobe br_netfilter && echo 'br_netfilter' >> /etc/modules-load.d/k8s.conf" \
    "br_netfilter kernel module"

# 5. Check and configure sysctl settings
check_and_fix "ip_forward" \
    "[[ $(sysctl -n net.ipv4.ip_forward) == '1' ]]" \
    "echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/k8s.conf && sysctl -p /etc/sysctl.d/k8s.conf" \
    "IPv4 forwarding enabled"

check_and_fix "bridge_nf_call_iptables" \
    "[[ $(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null) == '1' ]]" \
    "echo 'net.bridge.bridge-nf-call-iptables = 1' >> /etc/sysctl.d/k8s.conf && sysctl -p /etc/sysctl.d/k8s.conf" \
    "Bridge netfilter for iptables"

check_and_fix "bridge_nf_call_ip6tables" \
    "[[ $(sysctl -n net.bridge.bridge-nf-call-ip6tables 2>/dev/null) == '1' ]]" \
    "echo 'net.bridge.bridge-nf-call-ip6tables = 1' >> /etc/sysctl.d/k8s.conf && sysctl -p /etc/sysctl.d/k8s.conf" \
    "Bridge netfilter for ip6tables"

# 6. Check and disable firewall
check_and_fix "ufw_disabled" \
    "! ufw status 2>/dev/null | grep -q 'Status: active'" \
    "ufw disable" \
    "UFW firewall disabled"

# 7. Check time synchronization
check_and_fix "time_sync" \
    "[[ $(timedatectl show --property=NTPSynchronized --value) == 'yes' ]]" \
    "apt-get install -y chrony >/dev/null 2>&1 && systemctl enable --now chrony" \
    "NTP time synchronization"

# 8. Check DNS resolution
check_and_fix "dns_resolution" \
    "nslookup google.com >/dev/null 2>&1" \
    "echo 'nameserver 8.8.8.8' >> /etc/resolv.conf" \
    "DNS resolution"

# 9. Check hostname resolution
check_and_fix "hostname_resolution" \
    "getent hosts $(hostname) >/dev/null 2>&1" \
    "echo '127.0.1.1 $(hostname)' >> /etc/hosts" \
    "Hostname resolution in /etc/hosts"

# 10. Check required packages
REQUIRED_PACKAGES="curl wget socat conntrack ipset net-tools dnsutils chrony"
check_and_fix "required_packages" \
    "which curl wget socat conntrack ipset >/dev/null 2>&1" \
    "apt-get update >/dev/null 2>&1 && apt-get install -y $REQUIRED_PACKAGES >/dev/null 2>&1" \
    "Required system packages"

# 11. Check for conflicting Kubernetes packages
check_and_fix "no_existing_k8s" \
    "! (dpkg -l | grep -qE 'kubelet|kubeadm|kubectl|kubernetes-cni')" \
    "apt-get remove -y kubelet kubeadm kubectl kubernetes-cni 2>/dev/null; rm -f /etc/apt/sources.list.d/kubernetes*.list" \
    "No conflicting Kubernetes packages"

# 12. Check AppArmor (warning only)
apparmor_profiles=$(aa-status 2>/dev/null | grep -c 'profiles are in enforce mode' || echo "0")
if [ "$apparmor_profiles" -gt 0 ]; then
    print_msg "$YELLOW" "\n⚠ WARNING: AppArmor has $apparmor_profiles enforcing profiles"
    print_msg "$YELLOW" "  This may cause issues with container operations"
fi

# 13. Check NetworkManager (warning only)
if systemctl is-active NetworkManager >/dev/null 2>&1; then
    print_msg "$YELLOW" "\n⚠ WARNING: NetworkManager is active"
    print_msg "$YELLOW" "  This may interfere with CNI networking"
    if [ "$FIX_MODE" = true ]; then
        print_msg "$YELLOW" "  → Disabling NetworkManager..."
        systemctl disable --now NetworkManager 2>/dev/null
    fi
fi

# 14. Check disk space (minimum 50GB free on root)
check_and_fix "disk_space" \
    "[[ $(df -BG / | awk 'NR==2 {print int($4)}') -ge 50 ]]" \
    "echo 'Cannot auto-fix disk space - manual cleanup required'" \
    "Minimum 50GB free disk space on /"

# 15. Check /var space (minimum 30GB)
check_and_fix "var_space" \
    "[[ $(df -BG /var | awk 'NR==2 {print int($4)}') -ge 30 ]]" \
    "echo 'Cannot auto-fix /var space - manual cleanup required'" \
    "Minimum 30GB free space in /var"

# 16. Check memory (minimum 8GB)
check_and_fix "memory" \
    "[[ $(free -g | awk '/^Mem:/ {print int($2)}') -ge 8 ]]" \
    "echo 'Cannot auto-fix memory - hardware upgrade required'" \
    "Minimum 8GB RAM"

# 17. Check CPU cores (minimum 4)
check_and_fix "cpu_cores" \
    "[[ $(nproc) -ge 4 ]]" \
    "echo 'Cannot auto-fix CPU cores - hardware upgrade required'" \
    "Minimum 4 CPU cores"

# 18. Check overlay filesystem support
check_and_fix "overlay_fs" \
    "grep -q overlay /proc/filesystems" \
    "echo 'Overlay filesystem not supported - kernel upgrade may be required'" \
    "Overlay filesystem support"

# 19. Create required directories for local storage
check_and_fix "storage_dirs" \
    "[[ -d /mnt/local-storage/pv1 ]]" \
    "mkdir -p /mnt/local-storage/{pv1,pv2,pv3,pv4,pv5} && chmod 777 /mnt/local-storage/*" \
    "Local storage directories"

check_and_fix "prometheus_dir" \
    "[[ -d /mnt/prometheus ]]" \
    "mkdir -p /mnt/prometheus && chmod 777 /mnt/prometheus" \
    "Prometheus storage directory"

# 11. Check network connectivity to required registries
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

# Helm repositories to check (subset of most critical)
HELM_REPOS=(
    "charts.bitnami.com"
    "prometheus-community.github.io"
    "grafana.github.io"
    "mesosphere.github.io"
)

print_msg "$BLUE" "\nChecking Helm repository connectivity..."
for repo in "${HELM_REPOS[@]}"; do
    if curl -k --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "https://$repo" 2>/dev/null | grep -qE '^[23][0-9]{2}$'; then
        print_msg "$GREEN" "  ✓ $repo: reachable"
    else
        print_msg "$RED" "  ✗ $repo: unreachable"
        VALIDATION_PASSED=false
    fi
done

# System packages update
if [ "$FIX_MODE" = true ]; then
    print_msg "$GREEN" "\n=== System Updates ==="
    print_msg "$BLUE" "Updating system packages..."
    
    apt-get update >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        print_msg "$GREEN" "  ✓ Package list updated"
    else
        print_msg "$RED" "  ✗ Failed to update package list"
    fi
    
    # Install useful packages
    print_msg "$BLUE" "Installing required packages..."
    PACKAGES="curl wget git vim net-tools htop iotop sysstat"
    apt-get install -y $PACKAGES >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        print_msg "$GREEN" "  ✓ Required packages installed"
    else
        print_msg "$YELLOW" "  ⚠ Some packages may have failed to install"
    fi
fi

# Final Summary
echo
print_msg "$BLUE" "╔══════════════════════════════════════════════════════════╗"
print_msg "$BLUE" "║                        Summary                           ║"
print_msg "$BLUE" "╚══════════════════════════════════════════════════════════╝"
echo

if [ "$VALIDATION_PASSED" = true ]; then
    if [ "$FIXES_APPLIED" = true ]; then
        print_msg "$GREEN" "✓ All prerequisites met after applying fixes"
        print_msg "$YELLOW" "⚠ IMPORTANT: Reboot recommended to ensure all changes take effect"
        print_msg "$YELLOW" "  Run: sudo reboot"
    else
        print_msg "$GREEN" "✓ All prerequisites already met - system is ready for NKP"
    fi
else
    print_msg "$RED" "✗ Some prerequisites are not met"
    
    if [ "$FIX_MODE" = false ]; then
        print_msg "$YELLOW" "\nTo attempt automatic fixes, run:"
        print_msg "$YELLOW" "  sudo $0 --fix"
    else
        print_msg "$YELLOW" "\nSome issues could not be automatically fixed."
        print_msg "$YELLOW" "Review the report and address issues manually."
    fi
fi

echo
print_msg "$BLUE" "Report saved to: $REPORT_FILE"

# Create a summary file for automation
if [ "$VALIDATION_PASSED" = true ]; then
    echo "READY" > /tmp/nkp-ready-status
else
    echo "NOT_READY" > /tmp/nkp-ready-status
fi

exit $([ "$VALIDATION_PASSED" = true ] && echo 0 || echo 1)
