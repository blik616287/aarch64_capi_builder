#!/bin/bash
#
# Test PXE boot configuration
# This validates the PXE server setup and boot files
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

PXE_SERVER="${PXE_SERVER:-localhost}"
TFTP_ROOT="${TFTP_ROOT:-/var/lib/tftpboot}"
HTTP_ROOT="${HTTP_ROOT:-/var/www/html}"

test_tftp_files() {
    log_info "=== Testing TFTP Files ==="

    local files=("grubaa64.efi" "vmlinuz-arm64" "initrd-arm64.img" "grub/grub.cfg")
    local all_present=true

    for file in "${files[@]}"; do
        if [ -f "$TFTP_ROOT/$file" ]; then
            local size
            size=$(ls -lh "$TFTP_ROOT/$file" | awk '{print $5}')
            log_pass "$file ($size)"
        else
            log_fail "$file - NOT FOUND"
            all_present=false
        fi
    done

    if [ "$all_present" = true ]; then
        log_pass "All TFTP files present"
        return 0
    else
        log_fail "Some TFTP files missing"
        return 1
    fi
}

test_http_files() {
    log_info "=== Testing HTTP Files ==="

    # Check images directory
    if [ -d "$HTTP_ROOT/images" ]; then
        log_pass "Images directory exists"
        local image_count
        image_count=$(ls -1 "$HTTP_ROOT/images"/*.{raw,qcow2} 2>/dev/null | wc -l || echo "0")
        log_info "  Images found: $image_count"
    else
        log_warn "Images directory not found"
    fi

    # Check cloud-init files
    if [ -d "$HTTP_ROOT/cloud-init" ]; then
        log_pass "Cloud-init directory exists"

        if [ -f "$HTTP_ROOT/cloud-init/user-data" ]; then
            log_pass "user-data present"
        else
            log_fail "user-data missing"
        fi

        if [ -f "$HTTP_ROOT/cloud-init/meta-data" ]; then
            log_pass "meta-data present"
        else
            log_fail "meta-data missing"
        fi
    else
        log_warn "Cloud-init directory not found"
    fi
}

test_services() {
    log_info "=== Testing Services ==="

    # Check nginx
    if systemctl is-active --quiet nginx; then
        log_pass "nginx is running"
    else
        log_fail "nginx is not running"
    fi

    # Check dnsmasq (may not be running by default)
    if systemctl is-active --quiet dnsmasq; then
        log_pass "dnsmasq is running"
    else
        log_warn "dnsmasq is not running (start manually when ready)"
    fi

    # Check TFTP
    if systemctl is-active --quiet tftpd-hpa 2>/dev/null; then
        log_pass "tftpd-hpa is running"
    else
        log_info "tftpd-hpa not running (dnsmasq provides TFTP)"
    fi
}

test_network_connectivity() {
    log_info "=== Testing Network Connectivity ==="

    # Get local IP
    local local_ip
    local_ip=$(hostname -I | awk '{print $1}')
    log_info "Local IP: $local_ip"

    # Test HTTP
    if curl -s -o /dev/null -w "%{http_code}" "http://$local_ip/" | grep -q "200\|301\|403"; then
        log_pass "HTTP responding"
    else
        log_fail "HTTP not responding"
    fi

    # Test TFTP (basic check)
    if command -v tftp &>/dev/null; then
        if echo "get grubaa64.efi" | tftp "$local_ip" 2>&1 | grep -q "Received"; then
            log_pass "TFTP responding"
            rm -f grubaa64.efi
        else
            log_warn "TFTP may not be responding correctly"
        fi
    else
        log_info "tftp client not installed, skipping TFTP test"
    fi
}

test_grub_config() {
    log_info "=== Validating GRUB Config ==="

    local grub_cfg="$TFTP_ROOT/grub/grub.cfg"

    if [ ! -f "$grub_cfg" ]; then
        log_fail "grub.cfg not found"
        return 1
    fi

    # Check for required entries
    if grep -q "vmlinuz-arm64" "$grub_cfg"; then
        log_pass "Kernel path configured"
    else
        log_fail "Kernel path not found in grub.cfg"
    fi

    if grep -q "initrd-arm64" "$grub_cfg"; then
        log_pass "Initrd path configured"
    else
        log_fail "Initrd path not found in grub.cfg"
    fi

    if grep -q "menuentry" "$grub_cfg"; then
        local entry_count
        entry_count=$(grep -c "menuentry" "$grub_cfg")
        log_pass "Found $entry_count menu entries"
    else
        log_fail "No menu entries found"
    fi

    log_info "GRUB config content:"
    echo "---"
    cat "$grub_cfg"
    echo "---"
}

test_dnsmasq_config() {
    log_info "=== Validating dnsmasq Config ==="

    local dnsmasq_cfg="/etc/dnsmasq.d/pxe.conf"

    if [ ! -f "$dnsmasq_cfg" ]; then
        log_warn "dnsmasq PXE config not found at $dnsmasq_cfg"
        return 0
    fi

    # Check DHCP range
    if grep -q "dhcp-range" "$dnsmasq_cfg"; then
        log_pass "DHCP range configured"
        grep "dhcp-range" "$dnsmasq_cfg"
    else
        log_fail "DHCP range not configured"
    fi

    # Check PXE boot options
    if grep -q "dhcp-boot" "$dnsmasq_cfg"; then
        log_pass "PXE boot option configured"
        grep "dhcp-boot" "$dnsmasq_cfg"
    else
        log_fail "PXE boot option not configured"
    fi

    # Check TFTP
    if grep -q "enable-tftp" "$dnsmasq_cfg"; then
        log_pass "TFTP enabled"
    else
        log_fail "TFTP not enabled"
    fi
}

simulate_pxe_boot() {
    log_info "=== Simulating PXE Boot (QEMU) ==="

    if ! command -v qemu-system-aarch64 &>/dev/null; then
        log_warn "qemu-system-aarch64 not available, skipping simulation"
        return 0
    fi

    log_info "This would launch a VM that attempts PXE boot"
    log_info "To test manually, run:"
    log_info ""
    log_info "  qemu-system-aarch64 \\"
    log_info "    -machine virt \\"
    log_info "    -cpu cortex-a72 \\"
    log_info "    -m 2048 \\"
    log_info "    -boot n \\"
    log_info "    -netdev user,id=net0,tftp=$TFTP_ROOT,bootfile=grubaa64.efi \\"
    log_info "    -device virtio-net-pci,netdev=net0 \\"
    log_info "    -nographic"
    log_info ""
}

print_summary() {
    log_info ""
    log_info "=========================================="
    log_info "PXE Configuration Summary"
    log_info "=========================================="
    log_info ""
    log_info "TFTP Root: $TFTP_ROOT"
    log_info "HTTP Root: $HTTP_ROOT"
    log_info ""
    log_info "To complete PXE setup:"
    log_info "  1. Ensure all boot files are in $TFTP_ROOT"
    log_info "  2. Place disk image in $HTTP_ROOT/images/"
    log_info "  3. Update $TFTP_ROOT/grub/grub.cfg with correct paths"
    log_info "  4. Review /etc/dnsmasq.d/pxe.conf DHCP range"
    log_info "  5. Start dnsmasq: sudo systemctl start dnsmasq"
    log_info ""
    log_info "WARNING: Only run dnsmasq on isolated networks!"
}

main() {
    log_info "PXE Boot Configuration Test"
    log_info "============================"

    test_tftp_files
    test_http_files
    test_services
    test_network_connectivity
    test_grub_config
    test_dnsmasq_config
    simulate_pxe_boot
    print_summary
}

main "$@"
