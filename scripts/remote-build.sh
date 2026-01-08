#!/bin/bash
#
# Remote Build Script - Runs on c7g.metal ARM64 instance
#
# This script is executed on the ARM64 build host to create the CAPI image.
# It handles the complete build process including:
#   - Setting up the build environment
#   - Running Packer to build the image
#   - Converting to multiple formats (QCOW2, RAW, VMDK, OVA)
#   - Extracting PXE boot files
#
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
K8S_VERSION="${K8S_VERSION:-v1.32.4}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.4}"
CNI_VERSION="${CNI_VERSION:-1.6.0}"
CRICTL_VERSION="${CRICTL_VERSION:-1.32.0}"
RUNC_VERSION="${RUNC_VERSION:-1.2.8}"

BUILD_DIR="/opt/capi-build"
OUTPUT_DIR="$BUILD_DIR/output"
PXE_DIR="$BUILD_DIR/pxe-files"
IMAGE_BUILDER_DIR="/opt/test-images/image-builder"

# Derived values
K8S_SEMVER="${K8S_VERSION}"
K8S_SERIES="${K8S_VERSION%.*}"
K8S_DEB_VERSION="${K8S_VERSION#v}-1.1"

IMAGE_NAME="ubuntu-2204-arm64-kube-${K8S_VERSION#v}"

# =============================================================================
# Helper Functions
# =============================================================================
log_info() { echo "[INFO] $(date '+%H:%M:%S') $1" >&2; }
log_success() { echo "[SUCCESS] $(date '+%H:%M:%S') $1" >&2; }
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $1" >&2; }

# =============================================================================
# Setup Build Environment
# =============================================================================
setup_environment() {
    log_info "Setting up build environment..."

    sudo mkdir -p "$BUILD_DIR" "$OUTPUT_DIR" "$PXE_DIR"
    sudo chown -R ubuntu:ubuntu "$BUILD_DIR"

    # Ensure KVM is accessible
    if [[ ! -w /dev/kvm ]]; then
        sudo chmod 666 /dev/kvm
    fi

    # Install required packages
    if ! command -v packer &>/dev/null || ! command -v sshpass &>/dev/null; then
        log_info "Installing required packages..."
        sudo apt-get update -qq

        # Install sshpass, genisoimage, qemu, ansible
        sudo apt-get install -y -qq sshpass genisoimage qemu-system-arm qemu-efi-aarch64 \
            qemu-utils ansible python3-pip cloud-image-utils

        # Install Packer from HashiCorp
        if ! command -v packer &>/dev/null; then
            log_info "Installing Packer..."
            wget -q -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
            sudo apt-get update -qq
            sudo apt-get install -y -qq packer
        fi
    fi

    # Clone image-builder if not present (for ansible roles)
    if [[ ! -d "$IMAGE_BUILDER_DIR" ]]; then
        log_info "Cloning image-builder repository..."
        sudo mkdir -p "$(dirname $IMAGE_BUILDER_DIR)"
        sudo git clone --depth 1 https://github.com/kubernetes-sigs/image-builder.git "$IMAGE_BUILDER_DIR"
        sudo chown -R ubuntu:ubuntu "$(dirname $IMAGE_BUILDER_DIR)"
    fi

    log_success "Build environment ready"
}

# =============================================================================
# Create Packer Configuration
# =============================================================================
create_packer_config() {
    log_info "Creating Packer configuration..."

    # Generate random password for builder user
    BUILDER_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

    cat > "$BUILD_DIR/capi-arm64.pkr.hcl" << 'PACKER_EOF'
packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "kubernetes_semver" {
  type    = string
  default = "v1.32.4"
}

variable "kubernetes_series" {
  type    = string
  default = "v1.32"
}

variable "kubernetes_deb_version" {
  type    = string
  default = "1.32.4-1.1"
}

variable "containerd_version" {
  type    = string
  default = "2.0.4"
}

variable "cni_version" {
  type    = string
  default = "1.6.0"
}

variable "crictl_version" {
  type    = string
  default = "1.32.0"
}

variable "runc_version" {
  type    = string
  default = "1.2.8"
}

variable "builder_password" {
  type      = string
  sensitive = true
}

variable "output_directory" {
  type    = string
  default = "/opt/capi-build/output"
}

variable "image_name" {
  type    = string
  default = "ubuntu-2204-arm64-kube-v1.32.4"
}

source "qemu" "capi-ubuntu-arm64" {
  iso_url          = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
  iso_checksum     = "file:https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
  disk_image       = true
  disk_size        = "20G"
  format           = "qcow2"
  output_directory = var.output_directory
  vm_name          = var.image_name

  qemu_binary  = "qemu-system-aarch64"
  accelerator  = "kvm"
  machine_type = "virt"
  cpu_model    = "host"
  memory       = 4096
  cpus         = 4

  efi_boot          = true
  efi_firmware_code = "/usr/share/AAVMF/AAVMF_CODE.fd"
  efi_firmware_vars = "/usr/share/AAVMF/AAVMF_VARS.fd"

  qemuargs = [
    ["-cpu", "host"],
    ["-boot", "strict=off"]
  ]

  ssh_username         = "builder"
  ssh_password         = var.builder_password
  ssh_timeout          = "20m"
  ssh_handshake_attempts = 100

  cd_files = ["${path.root}/cloud-init/user-data", "${path.root}/cloud-init/meta-data"]
  cd_label = "cidata"

  shutdown_command = ""
  shutdown_timeout = "5m"

  headless = true
}

build {
  sources = ["source.qemu.capi-ubuntu-arm64"]

  # First boot setup
  provisioner "ansible" {
    user             = "builder"
    playbook_file    = "/opt/test-images/image-builder/images/capi/ansible/firstboot.yml"
    use_proxy        = false
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_SSH_ARGS=-o PubkeyAuthentication=no -o PasswordAuthentication=yes"
    ]
    extra_arguments = [
      "-e", "ansible_ssh_pass=${var.builder_password}",
      "-e", "ansible_ssh_common_args='-o PubkeyAuthentication=no -o PasswordAuthentication=yes'",
      "-e", "ubuntu_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "ubuntu_security_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "extra_debs=",
      "-e", "extra_repos=",
      "-e", "@/opt/capi-build/arm64-vars.json"
    ]
  }

  # Reboot after firstboot
  provisioner "shell" {
    inline = ["sudo reboot"]
    expect_disconnect = true
  }

  provisioner "shell" {
    inline = ["echo 'Reconnected after reboot'"]
    pause_before = "30s"
  }

  # Main node setup with Kubernetes
  provisioner "ansible" {
    user             = "builder"
    playbook_file    = "/opt/test-images/image-builder/images/capi/ansible/node.yml"
    use_proxy        = false
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_SSH_ARGS=-o PubkeyAuthentication=no -o PasswordAuthentication=yes"
    ]
    extra_arguments = [
      "-e", "ansible_ssh_pass=${var.builder_password}",
      "-e", "ansible_ssh_common_args='-o PubkeyAuthentication=no -o PasswordAuthentication=yes'",
      "-e", "@/opt/capi-build/arm64-vars.json",
      "-e", "ubuntu_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "ubuntu_security_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "extra_debs=",
      "-e", "extra_repos=",
      "-e", "kubernetes_semver=${var.kubernetes_semver}",
      "-e", "kubernetes_series=${var.kubernetes_series}",
      "-e", "kubernetes_cni_semver=v${var.cni_version}",
      "-e", "kubernetes_cni_source_type=http",
      "-e", "kubernetes_cni_http_source=https://github.com/containernetworking/plugins/releases/download",
      "-e", "kubernetes_source_type=http",
      "-e", "kubernetes_http_source=https://dl.k8s.io/release",
      "-e", "kubeadm_template=etc/kubeadm.yml",
      "-e", "kubernetes_container_registry=registry.k8s.io",
      "-e", "containerd_version=${var.containerd_version}",
      "-e", "containerd_url=https://github.com/containerd/containerd/releases/download/v${var.containerd_version}/containerd-${var.containerd_version}-linux-arm64.tar.gz",
      "-e", "containerd_sha256=",
      "-e", "containerd_service_url=https://raw.githubusercontent.com/containerd/containerd/refs/tags/v${var.containerd_version}/containerd.service",
      "-e", "containerd_wasm_shims_runtimes=",
      "-e", "containerd_additional_settings=",
      "-e", "containerd_cri_socket=/var/run/containerd/containerd.sock",
      "-e", "containerd_gvisor_runtime=false",
      "-e", "containerd_gvisor_version=latest",
      "-e", "crictl_url=https://github.com/kubernetes-sigs/cri-tools/releases/download/v${var.crictl_version}/crictl-v${var.crictl_version}-linux-arm64.tar.gz",
      "-e", "crictl_sha256=",
      "-e", "crictl_source_type=http",
      "-e", "runc_version=${var.runc_version}",
      "-e", "ecr_credential_provider=false",
      "-e", "node_custom_roles_post_sysprep=",
      "-e", "python_path="
    ]
  }
}
PACKER_EOF

    # Create cloud-init files
    mkdir -p "$BUILD_DIR/cloud-init"

    cat > "$BUILD_DIR/cloud-init/user-data" << EOF
#cloud-config
users:
  - name: builder
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: $BUILDER_PASSWORD
ssh_pwauth: true
runcmd:
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
EOF

    cat > "$BUILD_DIR/cloud-init/meta-data" << EOF
instance-id: capi-build-$(date +%s)
local-hostname: capi-builder
EOF

    # Create ARM64 vars file to override x86-only packages
    # linux-cloud-tools-virtual, linux-tools-virtual are x86-only Hyper-V packages
    cat > "$BUILD_DIR/arm64-vars.json" << EOF
{
  "common_virt_debs": [],
  "common_virt_rpms": [],
  "enable_hv_kvp_daemon": false,
  "auditd_enabled": false,
  "qemu_debs": ["cloud-init", "cloud-guest-utils", "cloud-initramfs-growroot"],
  "containerd_wasm_shims_runtimes": "",
  "sysusr_prefix": "/usr/local",
  "sysusrlocal_prefix": "/usr/local",
  "systemd_prefix": "/usr/lib/systemd",
  "pause_image": "registry.k8s.io/pause:3.10",
  "crictl_version": "$CRICTL_VERSION",
  "crictl_source_type": "http",
  "crictl_url": "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$CRICTL_VERSION/crictl-v$CRICTL_VERSION-linux-arm64.tar.gz",
  "load_additional_components": false
}
EOF

    # Fix image-builder qemu.yml for ARM64
    local qemu_yml="$IMAGE_BUILDER_DIR/images/capi/ansible/roles/providers/tasks/qemu.yml"
    if [[ -f "$qemu_yml" ]] && ! grep -q "ignore_errors: true" "$qemu_yml"; then
        log_info "Patching qemu.yml for ARM64 compatibility..."
        sudo cp "$qemu_yml" "${qemu_yml}.bak"
        sudo tee "$qemu_yml" > /dev/null << 'QEMU_YML'
- name: Install cloud-init packages
  ansible.builtin.apt:
    name: "{{ qemu_debs }}"
    state: present
  when: ansible_os_family == "Debian"

- name: Enable hv-kvp-daemon
  ansible.builtin.systemd:
    name: hv-kvp-daemon
    enabled: true
    state: started
  when:
    - ansible_os_family == "Debian"
    - enable_hv_kvp_daemon | default(false)
  ignore_errors: true
QEMU_YML
    fi

    # Patch kubernetes tasks to create bash-completion directory
    local k8s_main="$IMAGE_BUILDER_DIR/images/capi/ansible/roles/kubernetes/tasks/main.yml"
    if [[ -f "$k8s_main" ]] && ! grep -q "Create bash-completion directory" "$k8s_main"; then
        log_info "Patching kubernetes tasks.yml to create bash-completion directory..."
        # Insert directory creation task before the kubectl completion task
        sudo sed -i '/- name: Generate kubectl bash completion/i\
- name: Create bash-completion directory\
  ansible.builtin.file:\
    path: "{{ sysusr_prefix }}/share/bash-completion/completions"\
    state: directory\
    mode: "0755"\
' "$k8s_main"
    fi

    # Copy patched sysprep files that handle SSH disconnection
    # The VM becomes unreachable after removing SSH host keys - patched files have ignore_unreachable on all remaining tasks/handlers
    local sysprep_dir="$IMAGE_BUILDER_DIR/images/capi/ansible/roles/sysprep"
    if [[ -f "/tmp/sysprep-main.yml" ]]; then
        log_info "Installing patched sysprep tasks file..."
        sudo cp /tmp/sysprep-main.yml "$sysprep_dir/tasks/main.yml"
    fi
    if [[ -f "/tmp/sysprep-handlers.yml" ]]; then
        log_info "Installing patched sysprep handlers file..."
        sudo cp /tmp/sysprep-handlers.yml "$sysprep_dir/handlers/main.yml"
    fi

    log_success "Packer configuration created"
    echo "$BUILDER_PASSWORD"
}

# =============================================================================
# Run Packer Build
# =============================================================================
run_packer_build() {
    local builder_password=$1

    log_info "Starting Packer build..."

    cd "$BUILD_DIR"

    # Clean output directory
    rm -rf "$OUTPUT_DIR"

    # Initialize packer plugins
    packer init capi-arm64.pkr.hcl

    # Run build
    local start_time=$(date +%s)

    # Use upgraded ansible from ~/.local/bin
    export PATH="$HOME/.local/bin:$PATH"

    packer build \
        -var "builder_password=$builder_password" \
        -var "kubernetes_semver=$K8S_SEMVER" \
        -var "kubernetes_series=$K8S_SERIES" \
        -var "kubernetes_deb_version=$K8S_DEB_VERSION" \
        -var "containerd_version=$CONTAINERD_VERSION" \
        -var "cni_version=$CNI_VERSION" \
        -var "crictl_version=$CRICTL_VERSION" \
        -var "runc_version=$RUNC_VERSION" \
        -var "output_directory=$OUTPUT_DIR" \
        -var "image_name=$IMAGE_NAME" \
        capi-arm64.pkr.hcl

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "Packer build completed in ${duration}s"
}

# =============================================================================
# Convert Image Formats
# =============================================================================
convert_formats() {
    log_info "Converting image formats..."

    cd "$OUTPUT_DIR"
    local qcow2_file="$IMAGE_NAME"

    # Rename to .qcow2 extension
    if [[ -f "$qcow2_file" ]] && [[ ! -f "${qcow2_file}.qcow2" ]]; then
        mv "$qcow2_file" "${qcow2_file}.qcow2"
        qcow2_file="${qcow2_file}.qcow2"
    fi

    # Convert to RAW
    log_info "Converting to RAW format..."
    qemu-img convert -f qcow2 -O raw "$qcow2_file" "${IMAGE_NAME}.raw"

    # Convert to VMDK
    log_info "Converting to VMDK format..."
    qemu-img convert -f qcow2 -O vmdk "$qcow2_file" "${IMAGE_NAME}.vmdk"

    # Create OVA
    log_info "Creating OVA package..."
    create_ova

    log_success "All format conversions completed"
    ls -lh "$OUTPUT_DIR"
}

create_ova() {
    cd "$OUTPUT_DIR"

    # Get VMDK size
    local vmdk_size=$(stat -c%s "${IMAGE_NAME}.vmdk")

    # Create OVF descriptor
    cat > "${IMAGE_NAME}.ovf" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:href="${IMAGE_NAME}.vmdk" ovf:id="file1" ovf:size="$vmdk_size"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="20" ovf:capacityAllocationUnits="byte * 2^30" ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <VirtualSystem ovf:id="${IMAGE_NAME}">
    <Info>Ubuntu 22.04 ARM64 Kubernetes ${K8S_VERSION} CAPI Image</Info>
    <Name>${IMAGE_NAME}</Name>
    <OperatingSystemSection ovf:id="96">
      <Info>Ubuntu 64-bit ARM</Info>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${IMAGE_NAME}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-17</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>4 virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>4</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>8192MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>8192</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>Hard Disk 1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

    # Create manifest
    echo "SHA256(${IMAGE_NAME}.vmdk)= $(sha256sum ${IMAGE_NAME}.vmdk | awk '{print $1}')" > "${IMAGE_NAME}.mf"
    echo "SHA256(${IMAGE_NAME}.ovf)= $(sha256sum ${IMAGE_NAME}.ovf | awk '{print $1}')" >> "${IMAGE_NAME}.mf"

    # Create OVA (tar archive)
    tar -cvf "${IMAGE_NAME}.ova" "${IMAGE_NAME}.ovf" "${IMAGE_NAME}.vmdk" "${IMAGE_NAME}.mf"

    # Cleanup intermediate files
    rm -f "${IMAGE_NAME}.ovf" "${IMAGE_NAME}.mf"
}

# =============================================================================
# Extract PXE Boot Files
# =============================================================================
extract_pxe_files() {
    log_info "Extracting PXE boot files..."

    cd "$OUTPUT_DIR"
    local qcow2_file="${IMAGE_NAME}.qcow2"

    # Load NBD module
    sudo modprobe nbd max_part=8

    # Connect QCOW2 to NBD
    sudo qemu-nbd --connect=/dev/nbd0 "$qcow2_file"
    sleep 2

    # Mount the boot partition
    sudo mkdir -p /mnt/capi-boot
    sudo mount /dev/nbd0p1 /mnt/capi-boot

    # Copy kernel and initrd
    sudo cp /mnt/capi-boot/boot/vmlinuz* "$PXE_DIR/" 2>/dev/null || \
        sudo cp /mnt/capi-boot/vmlinuz* "$PXE_DIR/"
    sudo cp /mnt/capi-boot/boot/initrd* "$PXE_DIR/" 2>/dev/null || \
        sudo cp /mnt/capi-boot/initrd* "$PXE_DIR/"

    # Fix permissions
    sudo chmod 644 "$PXE_DIR"/*
    sudo chown ubuntu:ubuntu "$PXE_DIR"/*

    # Cleanup
    sudo umount /mnt/capi-boot
    sudo qemu-nbd --disconnect /dev/nbd0

    log_success "PXE files extracted"
    ls -lh "$PXE_DIR"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           ARM64 CAPI Image Build - Remote Builder                 ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Kubernetes: $K8S_VERSION"
    echo "  containerd: $CONTAINERD_VERSION"
    echo "  CNI:        $CNI_VERSION"
    echo "  crictl:     $CRICTL_VERSION"
    echo ""

    local start_time=$(date +%s)

    setup_environment

    local builder_password
    builder_password=$(create_packer_config)

    run_packer_build "$builder_password"

    convert_formats

    extract_pxe_files

    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                     BUILD COMPLETE                                ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Total time: ${total_duration}s ($((total_duration / 60))m $((total_duration % 60))s)"
    echo ""
    echo "  Output files:"
    ls -lh "$OUTPUT_DIR"
    echo ""
    echo "  PXE files:"
    ls -lh "$PXE_DIR"
    echo ""
}

main "$@"
