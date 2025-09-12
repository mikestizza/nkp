#!/bin/bash
# Standalone NKP Bundle Push Script
# Use this when Harbor is already installed and running

set -e

# Configuration - adjust these as needed
HARBOR_HOST="localhost"
HARBOR_PORT="80"
HARBOR_USERNAME="admin"
HARBOR_PASSWORD="Harbor12345"
HARBOR_PROJECT="nkp"
NKP_VERSION="2.14.2"
NKP_BUNDLE_DIR="./nkp-v${NKP_VERSION}"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=================================${NC}"
echo -e "${BLUE}NKP Bundle Push to Harbor${NC}"
echo -e "${BLUE}=================================${NC}"

# Build URLs
if [ "$HARBOR_PORT" = "80" ]; then
    HARBOR_URL="http://${HARBOR_HOST}"
    REGISTRY_ENTRY="${HARBOR_HOST}"
else
    HARBOR_URL="http://${HARBOR_HOST}:${HARBOR_PORT}"
    REGISTRY_ENTRY="${HARBOR_HOST}:${HARBOR_PORT}"
fi
REGISTRY_URL="${HARBOR_URL}/${HARBOR_PROJECT}"

echo "Harbor URL: $HARBOR_URL"
echo "Registry URL: $REGISTRY_URL"
echo "Project: $HARBOR_PROJECT"
echo ""

# Step 1: Check if Harbor is running
echo -e "${YELLOW}Checking Harbor status...${NC}"
if ! curl -s "${HARBOR_URL}/api/v2.0/health" | grep -q "healthy"; then
    echo -e "${RED}Harbor is not running or not healthy!${NC}"
    echo "Please start Harbor first:"
    echo "  docker ps | grep harbor"
    exit 1
fi
echo -e "${GREEN}✓ Harbor is running${NC}"

# Step 2: Configure Docker daemon for insecure registry
echo -e "${YELLOW}Configuring Docker for insecure registry...${NC}"
if [ -f /etc/docker/daemon.json ]; then
    if ! grep -q "$REGISTRY_ENTRY" /etc/docker/daemon.json; then
        echo "Adding $REGISTRY_ENTRY to insecure registries..."
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup
        sudo jq --arg registry "$REGISTRY_ENTRY" \
            '.["insecure-registries"] = (.["insecure-registries"] // []) + [$registry] | .["insecure-registries"] |= unique' \
            /etc/docker/daemon.json > /tmp/daemon.json
        sudo mv /tmp/daemon.json /etc/docker/daemon.json
        echo "Restarting Docker daemon..."
        sudo systemctl restart docker
        sleep 5
    else
        echo -e "${GREEN}✓ Docker already configured${NC}"
    fi
else
    echo "{\"insecure-registries\": [\"$REGISTRY_ENTRY\"]}" | sudo tee /etc/docker/daemon.json > /dev/null
    sudo systemctl restart docker
    sleep 5
fi

# Step 3: Create Harbor project if needed
echo -e "${YELLOW}Creating Harbor project: $HARBOR_PROJECT${NC}"
response=$(curl -s -w "%{http_code}" -X POST \
    "${HARBOR_URL}/api/v2.0/projects" \
    -H "Content-Type: application/json" \
    -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
    -d "{\"project_name\": \"${HARBOR_PROJECT}\", \"public\": false}" \
    2>/dev/null)
http_code="${response: -3}"
if [ "$http_code" = "201" ]; then
    echo -e "${GREEN}✓ Project created${NC}"
elif [ "$http_code" = "409" ]; then
    echo -e "${GREEN}✓ Project already exists${NC}"
else
    echo -e "${YELLOW}Warning: Could not create project (HTTP $http_code)${NC}"
fi

# Step 4: Check for NKP bundles
echo ""
echo -e "${YELLOW}Checking for NKP bundles...${NC}"
BUNDLES=(
    "$NKP_BUNDLE_DIR/container-images/konvoy-image-bundle-v${NKP_VERSION}.tar"
    "$NKP_BUNDLE_DIR/container-images/kommander-image-bundle-v${NKP_VERSION}.tar"
)

missing_bundles=false
for bundle in "${BUNDLES[@]}"; do
    if [ -f "$bundle" ]; then
        size_mb=$(du -m "$bundle" | cut -f1)
        echo -e "${GREEN}✓${NC} Found: $(basename $bundle) (${size_mb}MB)"
    else
        echo -e "${RED}✗${NC} Missing: $(basename $bundle)"
        missing_bundles=true
    fi
done

if [ "$missing_bundles" = true ]; then
    echo -e "${RED}Missing required bundles!${NC}"
    echo "Expected location: $NKP_BUNDLE_DIR/container-images/"
    exit 1
fi

# Step 5: Check disk space
echo ""
echo -e "${YELLOW}Checking disk space...${NC}"
available_mb=$(df /tmp | awk 'NR==2 {printf "%.0f", $4/1024}')
echo "Available space: ${available_mb}MB"
if [ $available_mb -lt 10000 ]; then
    echo -e "${YELLOW}Warning: Low disk space. Consider cleaning up:${NC}"
    echo "  docker system prune -af"
fi

# Step 6: Push bundles
echo ""
echo -e "${BLUE}Ready to push bundles to Harbor${NC}"
echo "This will take 10-20 minutes per bundle"
read -p "Continue? (y/n): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 1
fi

# Push each bundle
for bundle in "${BUNDLES[@]}"; do
    if [ -f "$bundle" ]; then
        bundle_name=$(basename "$bundle")
        echo ""
        echo -e "${YELLOW}Pushing $bundle_name...${NC}"
        echo "Command: nkp push bundle --bundle \"$bundle\" --to-registry \"$REGISTRY_URL\""
        echo ""
        
        if nkp push bundle \
            --bundle "$bundle" \
            --to-registry "$REGISTRY_URL" \
            --to-registry-username "$HARBOR_USERNAME" \
            --to-registry-password "$HARBOR_PASSWORD" \
            --to-registry-insecure-skip-tls-verify \
            --on-existing-tag skip; then
            echo -e "${GREEN}✓ Successfully pushed $bundle_name${NC}"
        else
            echo -e "${RED}✗ Failed to push $bundle_name${NC}"
            exit 1
        fi
    fi
done

# Step 7: Summary
echo ""
echo -e "${GREEN}=================================${NC}"
echo -e "${GREEN}✓ Bundle push complete!${NC}"
echo -e "${GREEN}=================================${NC}"
echo ""
echo "Harbor Web UI: ${HARBOR_URL}"
echo "Username: ${HARBOR_USERNAME}"
echo "Password: ${HARBOR_PASSWORD}"
echo ""
echo "Test the registry:"
echo "  docker login ${REGISTRY_ENTRY} -u ${HARBOR_USERNAME}"
echo "  docker pull ${REGISTRY_ENTRY}/${HARBOR_PROJECT}/mesosphere/konvoy:v${NKP_VERSION}"
