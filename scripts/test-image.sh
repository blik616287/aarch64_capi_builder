#!/bin/bash
#
# Test ARM64 CAPI image on ARM bare metal host
# This script must be run on the c7g.metal test host
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${TEST_DIR:-/opt/test-images}"
VM_NAME="${VM_NAME:-capi-test-vm}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CPUS="${VM_CPUS:-4}"

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

TEST_RESULTS=()

record_result() {
    local test_name="$1"
    local result="$2"
    TEST_RESULTS+=("$test_name:$result")
}

cleanup() {
    log_info "Cleaning up test VM..."
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
}

trap cleanup EXIT

test_kvm_available() {
    log_info "Testing KVM availability..."

    if [ -e /dev/kvm ]; then
        log_pass "KVM device exists"
        record_result "kvm_device" "pass"
    else
        log_fail "KVM device not found"
        record_result "kvm_device" "fail"
        return 1
    fi

    if kvm-ok 2>/dev/null | grep -q "can be used"; then
        log_pass "KVM acceleration available"
        record_result "kvm_acceleration" "pass"
    else
        log_warn "KVM acceleration may not be available"
        record_result "kvm_acceleration" "warn"
    fi
}

find_test_image() {
    local image

    # Check for local image first
    image=$(ls -t "$TEST_DIR"/*.qcow2 2>/dev/null | head -1 || true)

    if [ -z "$image" ]; then
        log_warn "No local image found, checking S3..."

        # Try to download from S3
        if [ -n "${S3_BUCKET:-}" ]; then
            local s3_image
            s3_image=$(aws s3 ls "s3://$S3_BUCKET/images/" 2>/dev/null | grep qcow2 | sort | tail -1 | awk '{print $4}' || true)

            if [ -n "$s3_image" ]; then
                log_info "Downloading: $s3_image"
                aws s3 cp "s3://$S3_BUCKET/images/$s3_image" "$TEST_DIR/"
                image="$TEST_DIR/$s3_image"
            fi
        fi
    fi

    if [ -z "$image" ] || [ ! -f "$image" ]; then
        log_error "No test image found"
        log_info "Copy an image to $TEST_DIR/ or set S3_BUCKET"
        exit 1
    fi

    echo "$image"
}

create_test_vm() {
    local image="$1"

    log_info "Creating test VM..."
    log_info "  Image: $image"
    log_info "  Memory: ${VM_MEMORY}MB"
    log_info "  CPUs: $VM_CPUS"

    # Create a copy of the image for testing
    local test_image="$TEST_DIR/${VM_NAME}.qcow2"
    cp "$image" "$test_image"

    # Create cloud-init ISO for credentials
    local cloud_init_dir="$TEST_DIR/cloud-init"
    mkdir -p "$cloud_init_dir"

    cat > "$cloud_init_dir/meta-data" << EOF
instance-id: test-instance
local-hostname: capi-test
EOF

    cat > "$cloud_init_dir/user-data" << EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: \$6\$rounds=4096\$xyz\$ghij
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_rsa.pub 2>/dev/null || echo "ssh-rsa PLACEHOLDER")

runcmd:
  - echo "Cloud-init complete" > /tmp/cloud-init-done
EOF

    # Generate cloud-init ISO
    cloud-localds "$TEST_DIR/${VM_NAME}-cidata.iso" \
        "$cloud_init_dir/user-data" \
        "$cloud_init_dir/meta-data"

    # Create VM using virt-install
    virt-install \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY" \
        --vcpus "$VM_CPUS" \
        --disk "path=$test_image,format=qcow2" \
        --disk "path=$TEST_DIR/${VM_NAME}-cidata.iso,device=cdrom" \
        --os-variant ubuntu22.04 \
        --network network=default \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --boot uefi

    log_info "VM created, waiting for boot..."
}

wait_for_vm_boot() {
    local timeout="${1:-300}"
    local elapsed=0

    log_info "Waiting for VM to boot (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        # Check if VM is running
        if ! virsh domstate "$VM_NAME" 2>/dev/null | grep -q running; then
            log_error "VM stopped unexpectedly"
            return 1
        fi

        # Try to get IP address
        local vm_ip
        vm_ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)

        if [ -n "$vm_ip" ]; then
            log_info "VM IP: $vm_ip"

            # Try SSH connection
            if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "echo 'SSH working'" 2>/dev/null; then
                log_pass "VM booted and SSH accessible"
                record_result "vm_boot" "pass"
                echo "$vm_ip"
                return 0
            fi
        fi

        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done

    echo ""
    log_fail "VM boot timeout"
    record_result "vm_boot" "fail"
    return 1
}

test_nested_virtualization() {
    local vm_ip="$1"

    log_info "Testing nested virtualization..."

    # Check for /dev/kvm inside VM
    local kvm_check
    kvm_check=$(ssh -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "ls -la /dev/kvm 2>&1" || echo "not found")

    if echo "$kvm_check" | grep -q "kvm"; then
        log_pass "KVM device available inside VM"
        record_result "nested_kvm_device" "pass"
    else
        log_fail "KVM device not available inside VM"
        log_info "  Output: $kvm_check"
        record_result "nested_kvm_device" "fail"
        return 1
    fi

    # Check CPU flags for virtualization
    local cpu_flags
    cpu_flags=$(ssh -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "grep -E 'Features|flags' /proc/cpuinfo | head -1" || echo "")

    log_info "  CPU features: ${cpu_flags:0:80}..."

    # Try to load KVM module inside VM
    local kvm_module
    kvm_module=$(ssh -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "sudo modprobe kvm 2>&1 && echo 'loaded'" || echo "failed")

    if [ "$kvm_module" = "loaded" ]; then
        log_pass "KVM module loads successfully inside VM"
        record_result "nested_kvm_module" "pass"
    else
        log_warn "KVM module load issue: $kvm_module"
        record_result "nested_kvm_module" "warn"
    fi
}

test_kubernetes_prerequisites() {
    local vm_ip="$1"

    log_info "Testing Kubernetes prerequisites..."

    # Check containerd
    local containerd_status
    containerd_status=$(ssh -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "systemctl is-active containerd 2>/dev/null" || echo "not installed")

    if [ "$containerd_status" = "active" ]; then
        log_pass "containerd is active"
        record_result "containerd" "pass"
    else
        log_warn "containerd status: $containerd_status"
        record_result "containerd" "warn"
    fi

    # Check kubelet binary
    local kubelet_version
    kubelet_version=$(ssh -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "kubelet --version 2>/dev/null" || echo "not found")

    if echo "$kubelet_version" | grep -q "v1.33"; then
        log_pass "kubelet v1.33.x installed"
        record_result "kubelet_version" "pass"
    else
        log_warn "kubelet: $kubelet_version"
        record_result "kubelet_version" "warn"
    fi

    # Check kubeadm
    local kubeadm_version
    kubeadm_version=$(ssh -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "kubeadm version -o short 2>/dev/null" || echo "not found")

    log_info "  kubeadm version: $kubeadm_version"

    # Run kubeadm preflight (dry-run)
    log_info "Running kubeadm preflight checks..."
    local preflight_result
    preflight_result=$(ssh -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "sudo kubeadm init --dry-run 2>&1" || echo "failed")

    if echo "$preflight_result" | grep -q "Your Kubernetes control-plane has initialized successfully"; then
        log_pass "kubeadm preflight passed"
        record_result "kubeadm_preflight" "pass"
    else
        log_warn "kubeadm preflight had issues"
        echo "$preflight_result" | tail -20
        record_result "kubeadm_preflight" "warn"
    fi
}

test_cloud_init() {
    local vm_ip="$1"

    log_info "Testing cloud-init..."

    # Check cloud-init status
    local cloud_init_status
    cloud_init_status=$(ssh -o StrictHostKeyChecking=no "ubuntu@$vm_ip" "cloud-init status 2>/dev/null" || echo "unknown")

    if echo "$cloud_init_status" | grep -q "done"; then
        log_pass "cloud-init completed successfully"
        record_result "cloud_init" "pass"
    else
        log_warn "cloud-init status: $cloud_init_status"
        record_result "cloud_init" "warn"
    fi
}

print_test_summary() {
    log_info ""
    log_info "=========================================="
    log_info "Test Summary"
    log_info "=========================================="

    local passed=0
    local failed=0
    local warned=0

    for result in "${TEST_RESULTS[@]}"; do
        local test_name="${result%%:*}"
        local test_result="${result##*:}"

        case "$test_result" in
            pass)
                echo -e "  ${GREEN}✓${NC} $test_name"
                ((passed++))
                ;;
            fail)
                echo -e "  ${RED}✗${NC} $test_name"
                ((failed++))
                ;;
            warn)
                echo -e "  ${YELLOW}!${NC} $test_name"
                ((warned++))
                ;;
        esac
    done

    log_info ""
    log_info "Results: $passed passed, $failed failed, $warned warnings"

    if [ $failed -gt 0 ]; then
        log_error "Some tests failed!"
        return 1
    elif [ $warned -gt 0 ]; then
        log_warn "Tests passed with warnings"
        return 0
    else
        log_pass "All tests passed!"
        return 0
    fi
}

main() {
    log_info "ARM64 CAPI Image Test Suite"
    log_info "==========================="

    # Verify we're on ARM
    if [ "$(uname -m)" != "aarch64" ]; then
        log_error "This script must run on ARM64 hardware"
        log_info "Current architecture: $(uname -m)"
        exit 1
    fi

    # Test KVM
    test_kvm_available || exit 1

    # Find and prepare image
    local image
    image=$(find_test_image)

    # Create test VM
    create_test_vm "$image"

    # Wait for boot
    local vm_ip
    vm_ip=$(wait_for_vm_boot 300) || exit 1

    # Run tests
    test_cloud_init "$vm_ip"
    test_nested_virtualization "$vm_ip"
    test_kubernetes_prerequisites "$vm_ip"

    # Summary
    print_test_summary
}

main "$@"
