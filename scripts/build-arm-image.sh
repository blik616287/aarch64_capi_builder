#!/bin/bash
#
# Build ARM64 CAPI Image using Kubernetes image-builder
# This script runs on the x86 build host using QEMU user-mode emulation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BUILDER_DIR="${IMAGE_BUILDER_DIR:-/opt/image-builder/image-builder}"
OUTPUT_DIR="${OUTPUT_DIR:-/opt/image-builder/output}"
PACKER_VAR_FILE="${PACKER_VAR_FILE:-arm64-ubuntu-2204-k8s-1.33.json}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check QEMU ARM emulation
    if ! update-binfmts --display qemu-aarch64 2>/dev/null | grep -q enabled; then
        log_error "QEMU ARM64 emulation not enabled"
        log_info "Run: sudo update-binfmts --enable qemu-aarch64"
        exit 1
    fi
    log_info "✓ QEMU ARM64 emulation enabled"

    # Check Packer
    if ! command -v packer &> /dev/null; then
        log_error "Packer not found"
        exit 1
    fi
    log_info "✓ Packer installed: $(packer version | head -1)"

    # Check Ansible
    if ! command -v ansible &> /dev/null; then
        log_error "Ansible not found"
        exit 1
    fi
    log_info "✓ Ansible installed: $(ansible --version | head -1)"

    # Check image-builder directory
    if [ ! -d "$IMAGE_BUILDER_DIR" ]; then
        log_error "image-builder not found at $IMAGE_BUILDER_DIR"
        exit 1
    fi
    log_info "✓ image-builder found"

    # Check var file exists
    local var_file_path="$IMAGE_BUILDER_DIR/images/capi/packer/config/$PACKER_VAR_FILE"
    if [ ! -f "$var_file_path" ]; then
        log_warn "Custom var file not found at $var_file_path"
        log_info "Copying from project..."
        cp "$SCRIPT_DIR/../packer/vars/$PACKER_VAR_FILE" "$var_file_path" || {
            log_error "Failed to copy var file"
            exit 1
        }
    fi
    log_info "✓ Packer var file ready"
}

setup_build_environment() {
    log_info "Setting up build environment..."

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Ensure we have the latest image-builder
    cd "$IMAGE_BUILDER_DIR"

    # Check if we need to update
    if [ "${UPDATE_IMAGE_BUILDER:-false}" = "true" ]; then
        log_info "Updating image-builder..."
        git fetch origin
        git pull origin main
    fi

    # Install dependencies if needed
    cd images/capi
    if [ ! -f ".deps-installed" ]; then
        log_info "Installing image-builder dependencies..."
        make deps-qemu
        touch .deps-installed
    fi
}

build_image() {
    log_info "Starting ARM64 CAPI image build..."
    log_info "This will take 30-60 minutes..."

    cd "$IMAGE_BUILDER_DIR/images/capi"

    # Set build variables
    export PACKER_VAR_FILES="packer/config/$PACKER_VAR_FILE"

    # Build the image
    # Using qemu builder for ARM64 with user-mode emulation
    log_info "Running: make build-qemu-ubuntu-2204"

    make build-qemu-ubuntu-2204 2>&1 | tee "$OUTPUT_DIR/build.log"

    # Check if build succeeded
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "Build failed! Check $OUTPUT_DIR/build.log for details"
        exit 1
    fi

    log_info "Build completed successfully!"
}

copy_artifacts() {
    log_info "Copying build artifacts to output directory..."

    cd "$IMAGE_BUILDER_DIR/images/capi"

    # Find the output directory from packer
    local packer_output
    packer_output=$(find . -maxdepth 1 -type d -name "output-*" | head -1)

    if [ -z "$packer_output" ]; then
        log_error "Could not find packer output directory"
        exit 1
    fi

    # Copy QCOW2 image
    local qcow2_file
    qcow2_file=$(find "$packer_output" -name "*.qcow2" | head -1)

    if [ -n "$qcow2_file" ]; then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        local output_name="ubuntu-2204-arm64-capi-k8s-1.33-${timestamp}.qcow2"

        cp "$qcow2_file" "$OUTPUT_DIR/$output_name"
        log_info "✓ QCOW2 image: $OUTPUT_DIR/$output_name"

        # Create symlink to latest
        ln -sf "$output_name" "$OUTPUT_DIR/ubuntu-2204-arm64-capi-latest.qcow2"
    else
        log_warn "No QCOW2 file found in output"
    fi

    # Copy manifest if exists
    if [ -f "$packer_output/packer-manifest.json" ]; then
        cp "$packer_output/packer-manifest.json" "$OUTPUT_DIR/"
        log_info "✓ Manifest copied"
    fi
}

print_summary() {
    log_info "=========================================="
    log_info "Build Summary"
    log_info "=========================================="
    log_info "Output directory: $OUTPUT_DIR"
    log_info ""
    log_info "Generated files:"
    ls -lh "$OUTPUT_DIR"/*.qcow2 2>/dev/null || true
    log_info ""
    log_info "Next steps:"
    log_info "  1. Run convert-formats.sh to create Raw/VMDK/OVA"
    log_info "  2. Run upload-to-s3.sh to upload artifacts"
    log_info "  3. Enable test host: terraform apply -var enable_test_host=true"
    log_info "  4. Run test-image.sh on the ARM test host"
    log_info "=========================================="
}

main() {
    log_info "ARM64 CAPI Image Builder"
    log_info "========================"

    check_prerequisites
    setup_build_environment
    build_image
    copy_artifacts
    print_summary
}

main "$@"
