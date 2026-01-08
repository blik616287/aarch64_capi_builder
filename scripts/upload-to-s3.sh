#!/bin/bash
#
# Upload image artifacts to S3
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-/opt/image-builder/output}"

# Source environment if available
if [ -f /opt/image-builder/.env ]; then
    source /opt/image-builder/.env
fi

S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-images}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    if [ -z "$S3_BUCKET" ]; then
        log_error "S3_BUCKET not set"
        log_info "Set it via: export S3_BUCKET=your-bucket-name"
        log_info "Or check /opt/image-builder/.env"
        exit 1
    fi

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found"
        exit 1
    fi

    # Verify S3 access
    if ! aws s3 ls "s3://$S3_BUCKET" &>/dev/null; then
        log_error "Cannot access S3 bucket: $S3_BUCKET"
        exit 1
    fi

    log_info "✓ S3 bucket accessible: $S3_BUCKET"
}

upload_file() {
    local file="$1"
    local s3_path="$2"

    local file_size
    file_size=$(ls -lh "$file" | awk '{print $5}')

    log_info "Uploading: $(basename "$file") ($file_size)"
    log_info "  → s3://$S3_BUCKET/$s3_path"

    aws s3 cp "$file" "s3://$S3_BUCKET/$s3_path" \
        --no-progress \
        --metadata "build-date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    log_info "  ✓ Upload complete"
}

upload_images() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)

    log_info "Uploading images to S3..."
    log_info "Timestamp: $timestamp"
    log_info ""

    # Upload each format
    for ext in qcow2 raw vmdk ova; do
        local file
        file=$(ls -t "$OUTPUT_DIR"/*."$ext" 2>/dev/null | grep -v "latest" | head -1 || true)

        if [ -n "$file" ] && [ -f "$file" ]; then
            local base_name
            base_name=$(basename "$file")
            upload_file "$file" "$S3_PREFIX/$base_name"
        else
            log_warn "No .$ext file found, skipping"
        fi
    done

    # Upload build log if exists
    if [ -f "$OUTPUT_DIR/build.log" ]; then
        upload_file "$OUTPUT_DIR/build.log" "$S3_PREFIX/build-$timestamp.log"
    fi
}

upload_pxe_files() {
    log_info ""
    log_info "Checking for PXE files..."

    local pxe_dir="$OUTPUT_DIR/pxe"

    if [ -d "$pxe_dir" ]; then
        for file in "$pxe_dir"/*; do
            if [ -f "$file" ]; then
                upload_file "$file" "pxe/$(basename "$file")"
            fi
        done
    else
        log_warn "No PXE directory found at $pxe_dir"
        log_info "Run extract-pxe-files.sh first to extract kernel/initrd"
    fi
}

print_summary() {
    log_info ""
    log_info "=========================================="
    log_info "Upload Summary"
    log_info "=========================================="
    log_info ""
    log_info "S3 bucket: $S3_BUCKET"
    log_info "Prefix: $S3_PREFIX"
    log_info ""
    log_info "Uploaded files:"
    aws s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" --human-readable 2>/dev/null || true
    log_info ""
    log_info "PXE files:"
    aws s3 ls "s3://$S3_BUCKET/pxe/" --human-readable 2>/dev/null || true
}

main() {
    log_info "S3 Image Uploader"
    log_info "================="

    check_prerequisites
    upload_images
    upload_pxe_files
    print_summary
}

main "$@"
