#!/bin/bash
# Complete reset script for all nodes including storage

CONTROL_PLANES="10.38.235.41 10.38.235.80 10.38.235.71"
WORKERS="10.38.235.56 10.38.235.75 10.38.235.66 10.38.235.90"
ALL_NODES="$CONTROL_PLANES $WORKERS"

for node in $ALL_NODES; do
    echo "=== Resetting $node ==="
    ssh nutanix@$node "
        # Stop and reset Kubernetes
        sudo kubeadm reset -f
        
        # Clean Kubernetes directories
        sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /var/lib/cni
        sudo rm -rf /run/kubeadm /run/cluster-api
        sudo rm -rf /etc/cni/net.d
        sudo rm -rf /var/lib/containerd/io.containerd.grpc.v1.cri
        
        # Clean up VIP (important!)
        sudo ip addr del 10.38.235.110/32 dev ens3 2>/dev/null || true
        
        # Reset iptables
        sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
        sudo ipvsadm --clear 2>/dev/null || true
        
        # Stop services
        sudo systemctl stop kubelet containerd
        sudo systemctl restart containerd
        
        # ===== STORAGE CLEANUP =====
        # Unmount all volumes
        echo 'Cleaning storage volumes...'
        for mount in \$(mount | grep /mnt/disks/vol | awk '{print \$3}'); do
            sudo umount \$mount 2>/dev/null || true
        done
        
        # Clean up loop devices
        for loop in \$(losetup -a | grep vol | cut -d: -f1); do
            sudo losetup -d \$loop 2>/dev/null || true
        done
        
        # Remove volume files
        sudo rm -rf /var/lib/k8s-volumes
        sudo rm -f /var/lib/disk*.img
        
        # Remove mount directories
        sudo rm -rf /mnt/disks
        
        # Clean fstab entries
        sudo sed -i '/\/mnt\/disks\/vol/d' /etc/fstab
        sudo sed -i '/k8s-volumes/d' /etc/fstab
        
        # Clean additional storage directories
        sudo rm -rf /tmp/helm-charts
        sudo rm -rf /var/tmp/helm-repo
        sudo rm -rf /mnt/prometheus
        
        # Clean Docker/containerd auth
        sudo rm -f /var/lib/kubelet/config.json
        sudo rm -f /root/.docker/config.json
        
        echo 'Storage cleanup complete'
    "
done

# Clean local files
echo "=== Cleaning local files ==="
rm -f nkp-poc.conf nkp-poc-bootstrap.conf
rm -f kommander.yaml
rm -f preprovisioned_inventory.yaml

# Verification checks
echo ""
echo "=== Verification ==="

# Check no VIPs remain
echo "Checking for VIP cleanup:"
for node in $ALL_NODES; do
    echo -n "$node: "
    ssh nutanix@$node "ip addr show | grep 10.38.235.110" || echo "clean"
done

echo ""
echo "Checking kubelet status:"
for node in $ALL_NODES; do
    echo -n "$node: "
    ssh nutanix@$node "sudo systemctl status kubelet 2>&1 | grep Active"
done

echo ""
echo "Checking for mounted volumes:"
for node in $WORKERS; do
    echo -n "$node: "
    ssh nutanix@$node "mount | grep /mnt/disks" || echo "no volumes mounted"
done

echo ""
echo "=== Reset complete ==="
echo "Nodes are ready for fresh installation"
