

#!/bin/bash
# Harbor Registry Setup Script for Air-Gapped NKP Deployment
# This script will set up a complete Harbor registry with all required projects and images

set -e # Exit on any error

# Step 1: Set up environment variables
export REGISTRY_URL="http://x.x.x.x"  # Change this to your Harbor URL
export REGISTRY_USERNAME="admin"
export REGISTRY_PASSWORD="Harbor12345"   # Change this to your Harbor password

echo "==== Harbor Registry Setup for Air-Gapped NKP Deployment ===="
echo "Harbor URL: ${REGISTRY_URL}"
echo "Harbor Username: ${REGISTRY_USERNAME}"

# Step 2: Configure Docker for insecure registry
echo "==== Configuring Docker for Insecure Registry ===="
echo '{ "insecure-registries" : ["'${REGISTRY_URL##*/}'"] }' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
echo "Docker configured for insecure registry: ${REGISTRY_URL##*/}"

# Step 3: Create all required projects in Harbor
echo "==== Creating Harbor Projects ===="
# List of all projects extracted from the working Harbor instance
PROJECTS=(
  "alpine" "aquasec" "autoscaling" "banzaicloud" "bitnami" "brancz" "calico" "capi-ipam-ic" 
  "ceph" "cilium" "cloud-provider-gcp" "cloud-pv-vsphere" "cloudnative-pg" "cluster-api-aws" 
  "cluster-api-azure" "cluster-api-gcp" "cluster-api-vsphere" "coredns" "curlimages" "d2iq-labs" 
  "ebs-csi-driver" "eks-distro" "fairwinds" "fairwinds-ops" "fluent" "fluxcd" "frrouting" 
  "ghcr.io" "goharbor" "grafana" "helm" "ingress-nginx" "istio" "jaegertracing" "jetstack" 
  "jpillora" "k8s" "kiali" "kiwigrid" "knative-releases" "kubecost1" "kube-logging" 
  "kubernetesui" "kube-state-metrics" "kube-vip" "library" "mesosphere" "metallb" "nfd" 
  "nginxinc" "nkp" "nutanix" "nutanix-cloud-native" "nvidia" "openpolicyagent" "oss" 
  "prometheus" "prometheus-adapter" "prometheus-operator" "provider-aws" "rancher" "rook" 
  "semitechnologies" "sig-storage" "stakater" "thanos" "tigera" "traefik" "velero"
)

for project in "${PROJECTS[@]}"; do
  echo "Creating project: $project"
  curl -s -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD} -X POST "${REGISTRY_URL}/api/v2.0/projects" \
    -H "Content-Type: application/json" \
    -d "{\"project_name\": \"$project\", \"public\": true}" || true
  # We use || true to continue even if the project already exists
done
echo "Created all required Harbor projects"

# Step 4: Function to fix bundle repositories (adds library/ prefix to standalone repos)
fix_bundle() {
  local bundle_path=$1
  local output_path=$2
  
  echo "==== Fixing bundle at $bundle_path ===="
  # Create temporary directory
  rm -rf /tmp/bundle-extract
  mkdir -p /tmp/bundle-extract
  
  # Extract the bundle
  echo "Extracting bundle..."
  tar -xf "$bundle_path" -C /tmp/bundle-extract
  
  # Fix standalone repositories by adding library/ prefix
  echo "Fixing repository names in images.yaml..."
  cd /tmp/bundle-extract
  
  # Create and run the fix script
  cat > /tmp/fix-repos.sh << 'EOF'
#!/bin/bash
# Find all lines with image repositories that don't have a project/ prefix
grep -n '^    [^/]*:' images.yaml | while read -r line; do
  # Extract line number and repo name
  linenum=$(echo "$line" | cut -d':' -f1)
  repo=$(echo "$line" | cut -d':' -f2 | tr -d ' ')
  
  # Skip library/ prefixes as they're already correctly formatted
  if [[ "$repo" != "library/"* ]]; then
    # Add library/ prefix to the repository
    sed -i "${linenum}s/    ${repo}:/    library\/${repo}:/g" images.yaml
    echo "Fixed repository at line $linenum: $repo -> library/$repo"
  fi
done
EOF
  chmod +x /tmp/fix-repos.sh
  /tmp/fix-repos.sh
  
  # Create new bundle
  echo "Creating fixed bundle at $output_path..."
  tar -cf "$output_path" .
  echo "Fixed bundle created at $output_path"
}

# Step 5: Push required images that are known to be missing from the bundles
push_core_images() {
  echo "==== Pushing Core System Images ===="
  
  # Core system images that are known to be needed
  CORE_IMAGES=(
    "registry.k8s.io/pause:3.10|library/pause:3.10"
    "registry.k8s.io/kube-proxy:v1.31.4|library/kube-proxy:v1.31.4"
  )
  
  for img in "${CORE_IMAGES[@]}"; do
    src_img=$(echo $img | cut -d'|' -f1)
    dest_img=$(echo $img | cut -d'|' -f2)
    
    echo "Pulling $src_img and pushing as $dest_img"
    docker pull $src_img && \
    docker tag $src_img ${REGISTRY_URL##*/}/$dest_img && \
    docker push ${REGISTRY_URL##*/}/$dest_img
  done
}

# Step 6: Push the bundles
push_bundles() {
  echo "==== Pushing NKP Bundles to Harbor ===="
  
  # Determine bundle path - first check if input is provided
  BUNDLE_DIR=${1:-"./container-images"}
  if [ ! -d "$BUNDLE_DIR" ]; then
    echo "Bundle directory $BUNDLE_DIR not found!"
    echo "Please specify the correct path to container-images directory"
    return 1
  fi

  # 1. Fix and push Konvoy bundle
  if [ -f "$BUNDLE_DIR/konvoy-image-bundle-v2.14.0.tar" ]; then
    echo "Fixing and pushing Konvoy bundle..."
    fix_bundle "$BUNDLE_DIR/konvoy-image-bundle-v2.14.0.tar" /tmp/modified-konvoy-bundle.tar
    nkp push bundle --bundle /tmp/modified-konvoy-bundle.tar \
      --to-registry=${REGISTRY_URL} \
      --to-registry-username=${REGISTRY_USERNAME} \
      --to-registry-password=${REGISTRY_PASSWORD} \
      --to-registry-insecure-skip-tls-verify \
      --on-existing-tag skip
  else
    echo "Konvoy bundle not found at $BUNDLE_DIR/konvoy-image-bundle-v2.14.0.tar"
  fi
  
  # 2. Fix and push Kommander bundle
  if [ -f "$BUNDLE_DIR/kommander-image-bundle-v2.14.0.tar" ]; then
    echo "Fixing and pushing Kommander bundle..."
    fix_bundle "$BUNDLE_DIR/kommander-image-bundle-v2.14.0.tar" /tmp/modified-kommander-bundle.tar
    nkp push bundle --bundle /tmp/modified-kommander-bundle.tar \
      --to-registry=${REGISTRY_URL} \
      --to-registry-username=${REGISTRY_USERNAME} \
      --to-registry-password=${REGISTRY_PASSWORD} \
      --to-registry-insecure-skip-tls-verify \
      --on-existing-tag skip
  else
    echo "Kommander bundle not found at $BUNDLE_DIR/kommander-image-bundle-v2.14.0.tar"
  fi
  
  # 3. Push catalog applications bundle
  if [ -f "$BUNDLE_DIR/nkp-catalog-applications-image-bundle-v2.14.0.tar" ]; then
    echo "Pushing catalog applications bundle..."
    nkp push bundle --bundle "$BUNDLE_DIR/nkp-catalog-applications-image-bundle-v2.14.0.tar" \
      --to-registry=${REGISTRY_URL} \
      --to-registry-username=${REGISTRY_USERNAME} \
      --to-registry-password=${REGISTRY_PASSWORD} \
      --to-registry-insecure-skip-tls-verify \
      --on-existing-tag skip
  else
    echo "Catalog bundle not found at $BUNDLE_DIR/nkp-catalog-applications-image-bundle-v2.14.0.tar"
  fi
}

# Step 7: Push individual image tarballs
push_individual_images() {
  echo "==== Pushing Individual Image Tarballs ===="
  
  # Determine bundle path - first check if input is provided
  BUNDLE_DIR=${1:-"."}
  
  # Load and push bootstrap image
  if [ -f "$BUNDLE_DIR/konvoy-bootstrap-image-v2.14.0.tar" ]; then
    echo "Pushing konvoy-bootstrap image..."
    docker load -i "$BUNDLE_DIR/konvoy-bootstrap-image-v2.14.0.tar"
    docker tag mesosphere/konvoy-bootstrap:v2.14.0 ${REGISTRY_URL##*/}/mesosphere/konvoy-bootstrap:v2.14.0
    docker push ${REGISTRY_URL##*/}/mesosphere/konvoy-bootstrap:v2.14.0
  else
    echo "Bootstrap image not found at $BUNDLE_DIR/konvoy-bootstrap-image-v2.14.0.tar"
  fi
  
  # Load and push image builder
  if [ -f "$BUNDLE_DIR/nkp-image-builder-image-v0.22.3.tar" ]; then
    echo "Pushing nkp-image-builder image..."
    docker load -i "$BUNDLE_DIR/nkp-image-builder-image-v0.22.3.tar"
    docker tag mesosphere/nkp-image-builder:v0.22.3 ${REGISTRY_URL##*/}/mesosphere/nkp-image-builder:v0.22.3
    docker push ${REGISTRY_URL##*/}/mesosphere/nkp-image-builder:v0.22.3
  else
    echo "Image builder not found at $BUNDLE_DIR/nkp-image-builder-image-v0.22.3.tar"
  fi
}

# Step 8: Function to handle missing images automatically
create_image_handler() {
  echo "==== Creating Missing Image Handler ===="
  
  cat > /tmp/pull-missing-images.sh << 'EOF'
#!/bin/bash

# Set registry variables
REGISTRY_URL="${REGISTRY_URL:-http://10.0.0.114}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-admin}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-Harbor12345}"
REGISTRY_HOST="${REGISTRY_URL##*/}"

# Known registries for different image prefixes
declare -A REGISTRY_MAP
REGISTRY_MAP["kubernetes"]="registry.k8s.io"
REGISTRY_MAP["k8s"]="registry.k8s.io"
REGISTRY_MAP["kube"]="registry.k8s.io"
REGISTRY_MAP["pause"]="registry.k8s.io"
REGISTRY_MAP["etcd"]="registry.k8s.io"
REGISTRY_MAP["coredns"]="registry.k8s.io"
REGISTRY_MAP["istio"]="docker.io/istio"
REGISTRY_MAP["fluxcd"]="ghcr.io/fluxcd"
REGISTRY_MAP["jetstack"]="quay.io/jetstack"
REGISTRY_MAP["prometheus"]="quay.io/prometheus"
REGISTRY_MAP["thanos"]="quay.io/thanos"
REGISTRY_MAP["jaegertracing"]="quay.io/jaegertracing"
REGISTRY_MAP["brancz"]="quay.io/brancz"
REGISTRY_MAP["grafana"]="docker.io/grafana"
REGISTRY_MAP["bitnami"]="docker.io/bitnami"
REGISTRY_MAP["mesosphere"]="docker.io/mesosphere"
REGISTRY_MAP["calico"]="docker.io/calico"
REGISTRY_MAP["knative"]="gcr.io/knative-releases"

# Process an image by attempting to pull from various registries
process_image() {
  local image=$1
  echo "Processing image: $image"
  
  # Split into repo and tag
  repo=$(echo "$image" | cut -d':' -f1)
  tag=$(echo "$image" | cut -d':' -f2)
  
  # Get base repo name (without namespace)
  base_repo=$(basename "$repo")
  
  # Try to match with a known registry based on repo prefix
  matched=false
  for key in "${!REGISTRY_MAP[@]}"; do
    if [[ "$base_repo" == "$key"* || "$repo" == *"/$key"* ]]; then
      known_registry="${REGISTRY_MAP[$key]}"
      echo "Found matching registry $known_registry for $repo"
      
      # Try with known_registry/repo:tag
      if docker pull "$known_registry/$repo:$tag" 2>/dev/null; then
        docker tag "$known_registry/$repo:$tag" "$REGISTRY_HOST/$image"
        docker push "$REGISTRY_HOST/$image"
        matched=true
        break
      # Try with known_registry/base_repo:tag
      elif docker pull "$known_registry/$base_repo:$tag" 2>/dev/null; then
        docker tag "$known_registry/$base_repo:$tag" "$REGISTRY_HOST/$image"
        docker push "$REGISTRY_HOST/$image"
        matched=true
        break
      fi
    fi
  done
  
  # If no match found with known registries, try common registries
  if [[ "$matched" == "false" ]]; then
    # Try Docker Hub
    if docker pull "$image" 2>/dev/null; then
      docker tag "$image" "$REGISTRY_HOST/$image"
      docker push "$REGISTRY_HOST/$image"
      return 0
    fi
    
    # Try Docker Hub with library/ prefix for single-name repos
    if [[ "$repo" != *"/"* ]] && docker pull "library/$repo:$tag" 2>/dev/null; then
      docker tag "library/$repo:$tag" "$REGISTRY_HOST/$image"
      docker push "$REGISTRY_HOST/$image"
      return 0
    fi
    
    # Try quay.io
    if docker pull "quay.io/$repo:$tag" 2>/dev/null; then
      docker tag "quay.io/$repo:$tag" "$REGISTRY_HOST/$image"
      docker push "$REGISTRY_HOST/$image"
      return 0
    fi
    
    # Try ghcr.io
    if docker pull "ghcr.io/$repo:$tag" 2>/dev/null; then
      docker tag "ghcr.io/$repo:$tag" "$REGISTRY_HOST/$image"
      docker push "$REGISTRY_HOST/$image"
      return 0
    fi
    
    # Try registry.k8s.io
    if docker pull "registry.k8s.io/$repo:$tag" 2>/dev/null; then
      docker tag "registry.k8s.io/$repo:$tag" "$REGISTRY_HOST/$image"
      docker push "$REGISTRY_HOST/$image"
      return 0
    fi
    
    # Try k8s.gcr.io (legacy registry)
    if docker pull "k8s.gcr.io/$repo:$tag" 2>/dev/null; then
      docker tag "k8s.gcr.io/$repo:$tag" "$REGISTRY_HOST/$image"
      docker push "$REGISTRY_HOST/$image"
      return 0
    fi
    
    echo "Failed to pull $image from any registry"
    return 1
  fi
  
  return 0
}

# Main processing loop
if [ $# -eq 0 ]; then
  echo "Usage: pull-missing-images.sh image1 [image2 ...]"
  echo "Example: pull-missing-images.sh library/pause:3.10 mesosphere/dex:v2.41.1-d2iq.2"
  exit 1
fi

# Process each image
for image in "$@"; do
  process_image "$image"
done
EOF

  chmod +x /tmp/pull-missing-images.sh
  echo "Created missing image handler script at /tmp/pull-missing-images.sh"
  echo "Usage: /tmp/pull-missing-images.sh library/pause:3.10 mesosphere/dex:v2.41.1-d2iq.2"
}

# Step 9: Verify registry content
verify_registry() {
  echo "==== Verifying Harbor Registry Content ===="
  
  echo "Listing all projects:"
  curl -s -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD} -X GET "${REGISTRY_URL}/api/v2.0/projects?page_size=100" | grep name
  
  echo "Listing repositories in library project:"
  curl -s -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD} -X GET "${REGISTRY_URL}/api/v2.0/projects/library/repositories"
  
  echo "Listing repositories in mesosphere project:"
  curl -s -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD} -X GET "${REGISTRY_URL}/api/v2.0/projects/mesosphere/repositories"
}

# Main execution flow with arguments
BUNDLE_DIR="./container-images"

# Function to display usage
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Options:"
  echo "  -d, --bundle-dir DIR     Path to the directory containing NKP bundle files (default: ./container-images)"
  echo "  -u, --registry-url URL   Harbor registry URL (default: http://10.0.0.114)"
  echo "  -n, --username USER      Harbor username (default: admin)"
  echo "  -p, --password PASS      Harbor password (default: Harbor12345)"
  echo "  -h, --help               Display this help message"
  echo "  --skip-docker-config     Skip Docker insecure registry configuration"
  echo "  --skip-projects          Skip creating Harbor projects"
  echo "  --skip-core-images       Skip pushing core system images"
  echo "  --push-bundles           Push all bundles"
  echo "  --push-individual        Push individual images"
  echo "  --verify                 Verify registry content"
  echo ""
  echo "Example:"
  echo "  $0 --bundle-dir /path/to/bundles --registry-url http://harbor.example.com --push-bundles"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--bundle-dir)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    -u|--registry-url)
      REGISTRY_URL="$2"
      shift 2
      ;;
    -n|--username)
      REGISTRY_USERNAME="$2"
      shift 2
      ;;
    -p|--password)
      REGISTRY_PASSWORD="$2"
      shift 2
      ;;
    --skip-docker-config)
      SKIP_DOCKER_CONFIG=true
      shift
      ;;
    --skip-projects)
      SKIP_PROJECTS=true
      shift
      ;;
    --skip-core-images)
      SKIP_CORE_IMAGES=true
      shift
      ;;
    --push-bundles)
      PUSH_BUNDLES=true
      shift
      ;;
    --push-individual)
      PUSH_INDIVIDUAL=true
      shift
      ;;
    --verify)
      VERIFY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

echo "==== Harbor Registry Setup for Air-Gapped NKP Deployment ===="
echo "Harbor URL: ${REGISTRY_URL}"
echo "Harbor Username: ${REGISTRY_USERNAME}"
echo "Bundle Directory: ${BUNDLE_DIR}"

# Execute functions based on flags
if [ "$SKIP_DOCKER_CONFIG" != "true" ]; then
  echo "==== Configuring Docker for Insecure Registry ===="
  echo '{ "insecure-registries" : ["'${REGISTRY_URL##*/}'"] }' | sudo tee /etc/docker/daemon.json
  sudo systemctl restart docker
  echo "Docker configured for insecure registry: ${REGISTRY_URL##*/}"
fi

if [ "$SKIP_PROJECTS" != "true" ]; then
  echo "==== Creating Harbor Projects ===="
  for project in "${PROJECTS[@]}"; do
    echo "Creating project: $project"
    curl -s -u ${REGISTRY_USERNAME}:${REGISTRY_PASSWORD} -X POST "${REGISTRY_URL}/api/v2.0/projects" \
      -H "Content-Type: application/json" \
      -d "{\"project_name\": \"$project\", \"public\": true}" || true
  done
  echo "Created all required Harbor projects"
fi

if [ "$SKIP_CORE_IMAGES" != "true" ]; then
  push_core_images
fi

# Create the image handler script
create_image_handler

if [ "$PUSH_BUNDLES" == "true" ]; then
  push_bundles "$BUNDLE_DIR"
fi

if [ "$PUSH_INDIVIDUAL" == "true" ]; then
  push_individual_images "$BUNDLE_DIR"
fi

if [ "$VERIFY" == "true" ]; then
  verify_registry
fi

# If no specific action was requested, show help
if [ "$SKIP_DOCKER_CONFIG" == "true" ] && [ "$SKIP_PROJECTS" == "true" ] && [ "$SKIP_CORE_IMAGES" == "true" ] && [ "$PUSH_BUNDLES" != "true" ] && [ "$PUSH_INDIVIDUAL" != "true" ] && [ "$VERIFY" != "true" ]; then
  echo "No specific actions requested. Here are the available commands:"
  echo ""
  echo "To push core system images:"
  echo "  $0 --skip-docker-config --skip-projects"
  echo ""
  echo "To push bundles:"
  echo "  $0 --skip-docker-config --skip-projects --skip-core-images --push-bundles"
  echo ""
  echo "To push individual images:"
  echo "  $0 --skip-docker-config --skip-projects --skip-core-images --push-individual"
  echo ""
  echo "To verify registry content:"
  echo "  $0 --skip-docker-config --skip-projects --skip-core-images --verify"
  echo ""
  echo "For help:"
  echo "  $0 --help"
fi

echo ""
echo "==== Harbor Registry Setup Script Complete ===="
echo "To handle any missing images during deployment use:"
echo "/tmp/pull-missing-images.sh missing/image:tag another/image:tag"
