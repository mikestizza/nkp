# Create a quick status check script
cat << 'EOF' > check-capi-status.sh
#!/bin/bash
echo "=== Cluster Status ==="
kubectl get clusters -A

echo -e "\n=== Machines Status ==="
kubectl get machines -A -o wide

echo -e "\n=== Control Plane Status ==="
kubectl get kubeadmcontrolplane -A

echo -e "\n=== CAPI Controllers ==="
kubectl get pods -n capi-system
kubectl get pods -n cappp-system

echo -e "\n=== Addon Status ==="
kubectl get clusterresourcesets -A
EOF

chmod +x check-capi-status.sh
./check-capi-status.sh
