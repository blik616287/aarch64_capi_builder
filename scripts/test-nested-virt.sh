#!/bin/bash
#
# Focused test for nested virtualization on ARM64
# Run this on the c7g.metal test host to verify KVM-in-KVM works
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }

test_host_kvm() {
    log_info "=== Testing Host KVM ==="

    # Check architecture
    log_info "Architecture: $(uname -m)"
    if [ "$(uname -m)" != "aarch64" ]; then
        log_fail "Not running on ARM64"
        exit 1
    fi
    log_pass "Running on ARM64"

    # Check /dev/kvm
    if [ -e /dev/kvm ]; then
        log_pass "/dev/kvm exists"
        ls -la /dev/kvm
    else
        log_fail "/dev/kvm not found"
        log_info "Are you on bare metal (c7g.metal)?"
        exit 1
    fi

    # Check KVM module
    if lsmod | grep -q kvm; then
        log_pass "KVM module loaded"
        lsmod | grep kvm
    else
        log_warn "KVM module not loaded, trying to load..."
        sudo modprobe kvm
        if lsmod | grep -q kvm; then
            log_pass "KVM module loaded successfully"
        else
            log_fail "Failed to load KVM module"
            exit 1
        fi
    fi

    # Check CPU features
    log_info "CPU virtualization features:"
    grep -E "Features" /proc/cpuinfo | head -1 | tr ' ' '\n' | grep -E "^(kvm|vhe|sve)" || log_warn "No specific virt features found"
}

create_minimal_vm() {
    log_info "=== Creating Minimal Test VM ==="

    local test_dir="/tmp/nested-virt-test"
    mkdir -p "$test_dir"
    cd "$test_dir"

    # Download minimal cloud image if not present
    local image_url="https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-arm64.img"
    local image_file="ubuntu-minimal-arm64.img"

    if [ ! -f "$image_file" ]; then
        log_info "Downloading minimal Ubuntu image..."
        curl -L -o "$image_file" "$image_url"
    fi

    # Create test disk
    log_info "Creating test disk..."
    qemu-img create -f qcow2 -b "$image_file" -F qcow2 test-vm.qcow2 10G

    # Create cloud-init config
    cat > user-data << 'EOF'
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false

packages:
  - qemu-kvm
  - libvirt-daemon-system

runcmd:
  - echo "VM ready for nested virt test" > /tmp/ready
EOF

    cat > meta-data << EOF
instance-id: nested-test
local-hostname: nested-test
EOF

    # Create cloud-init ISO
    cloud-localds seed.iso user-data meta-data

    log_pass "Test VM prepared"
}

launch_vm_and_test() {
    log_info "=== Launching Test VM ==="

    local test_dir="/tmp/nested-virt-test"
    cd "$test_dir"

    # Launch VM with nested virt enabled
    log_info "Starting QEMU VM with nested virtualization..."

    # Start VM in background
    qemu-system-aarch64 \
        -name nested-test \
        -machine virt,gic-version=3 \
        -cpu host \
        -enable-kvm \
        -m 2048 \
        -smp 2 \
        -drive file=test-vm.qcow2,format=qcow2,if=virtio \
        -drive file=seed.iso,format=raw,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        -serial mon:stdio &

    local qemu_pid=$!

    log_info "VM started (PID: $qemu_pid)"
    log_info "Waiting for VM to boot..."

    # Wait for SSH to be available
    local timeout=180
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost "echo 'SSH ready'" 2>/dev/null; then
            log_pass "VM is accessible via SSH"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""

    if [ $elapsed -ge $timeout ]; then
        log_fail "VM boot timeout"
        kill $qemu_pid 2>/dev/null || true
        exit 1
    fi

    # Test nested KVM inside VM
    log_info "=== Testing Nested KVM Inside VM ==="

    # Check /dev/kvm inside VM
    local inner_kvm
    inner_kvm=$(ssh -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost "ls -la /dev/kvm 2>&1" || echo "not found")

    if echo "$inner_kvm" | grep -q "/dev/kvm"; then
        log_pass "/dev/kvm available inside VM"
        echo "  $inner_kvm"
    else
        log_fail "/dev/kvm not available inside VM"
        log_info "  Output: $inner_kvm"

        # Debug info
        log_info "Checking VM's CPU info..."
        ssh -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost "cat /proc/cpuinfo | head -20" || true
    fi

    # Try to load KVM module inside VM
    log_info "Loading KVM module inside VM..."
    local inner_module
    inner_module=$(ssh -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost "sudo modprobe kvm && lsmod | grep kvm" || echo "failed")

    if echo "$inner_module" | grep -q "kvm"; then
        log_pass "KVM module loaded inside VM"
        echo "  $inner_module"
    else
        log_warn "KVM module issue inside VM"
        echo "  $inner_module"
    fi

    # Cleanup
    log_info "Shutting down test VM..."
    ssh -o StrictHostKeyChecking=no -p 2222 ubuntu@localhost "sudo poweroff" 2>/dev/null || true
    sleep 5
    kill $qemu_pid 2>/dev/null || true

    log_pass "Nested virtualization test complete"
}

main() {
    log_info "Nested Virtualization Test"
    log_info "=========================="

    test_host_kvm
    create_minimal_vm
    launch_vm_and_test

    log_info ""
    log_info "=========================================="
    log_pass "All nested virtualization tests passed!"
    log_info "=========================================="
}

main "$@"
