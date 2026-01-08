#!/bin/bash
set -e

# ARM64 CAPI Image Builder for AWS
# Automated build script for Grace Hopper / DGX systems

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BUILDER_DIR="/opt/test-images/image-builder/images/capi"
OUTPUT_DIR="/opt/capi-build/output"
BUILD_LOG="/opt/capi-build/build.log"

# Kubernetes version config
K8S_VERSION="${K8S_VERSION:-v1.32.4}"
K8S_SERIES="${K8S_SERIES:-v1.32}"
K8S_DEB_VERSION="${K8S_DEB_VERSION:-1.32.4-1.1}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.4}"
CNI_VERSION="${CNI_VERSION:-v1.6.0}"
CNI_DEB_VERSION="${CNI_DEB_VERSION:-1.6.0-1.1}"
CRICTL_VERSION="${CRICTL_VERSION:-1.32.0}"

echo "=== ARM64 CAPI Image Builder ==="
echo "Kubernetes: ${K8S_VERSION}"
echo "Containerd: ${CONTAINERD_VERSION}"
echo "CNI: ${CNI_VERSION}"
echo ""

# Only create cloud-init directory, not output (packer creates output)
mkdir -p "/opt/capi-build/cloud-init"
rm -rf "${OUTPUT_DIR}"

# Create cloud-init files
cat > "/opt/capi-build/cloud-init/user-data" << 'CLOUDINIT'
#cloud-config
ssh_pwauth: true
users:
  - name: builder
    passwd: $6$DI0d9IV6lH1Av1Ch$7PktU6MAFAbRol0tGlwNum6cN7mDlnCKGivZ3cyQKvR4zNVk85ikpzW4H3PmQ8GgaNSgJ/.ofa1wlLX.2sDqm/
    groups: [adm, cdrom, dip, plugdev, lxd, sudo]
    lock-passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
CLOUDINIT

cat > "/opt/capi-build/cloud-init/meta-data" << 'METADATA'
instance-id: capi-arm64-build
local-hostname: capi-arm64
METADATA

echo "Initializing packer plugins..."
cd /opt/capi-build
packer init /opt/capi-build/capi-arm64.pkr.hcl

echo "Validating packer config..."
packer validate \
  -var "kubernetes_semver=${K8S_VERSION}" \
  -var "kubernetes_series=${K8S_SERIES}" \
  -var "kubernetes_deb_version=${K8S_DEB_VERSION}" \
  -var "containerd_version=${CONTAINERD_VERSION}" \
  -var "kubernetes_cni_semver=${CNI_VERSION}" \
  -var "kubernetes_cni_deb_version=${CNI_DEB_VERSION}" \
  -var "crictl_version=${CRICTL_VERSION}" \
  -var "image_builder_dir=${IMAGE_BUILDER_DIR}" \
  -var "output_directory=${OUTPUT_DIR}" \
  /opt/capi-build/capi-arm64.pkr.hcl

echo ""
echo "Starting CAPI ARM64 image build..."
echo "Build log: ${BUILD_LOG}"
echo ""

packer build \
  -var "kubernetes_semver=${K8S_VERSION}" \
  -var "kubernetes_series=${K8S_SERIES}" \
  -var "kubernetes_deb_version=${K8S_DEB_VERSION}" \
  -var "containerd_version=${CONTAINERD_VERSION}" \
  -var "kubernetes_cni_semver=${CNI_VERSION}" \
  -var "kubernetes_cni_deb_version=${CNI_DEB_VERSION}" \
  -var "crictl_version=${CRICTL_VERSION}" \
  -var "image_builder_dir=${IMAGE_BUILDER_DIR}" \
  -var "output_directory=${OUTPUT_DIR}" \
  /opt/capi-build/capi-arm64.pkr.hcl 2>&1 | tee "${BUILD_LOG}"

echo ""
echo "=== Build Complete ==="
ls -lh "${OUTPUT_DIR}/"
