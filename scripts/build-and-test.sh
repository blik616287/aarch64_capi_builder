#!/bin/bash
#
# ARM64 CAPI Image Builder - End-to-End Automation
#
# This script automates the entire process of building and testing an ARM64
# Cluster API (CAPI) image for Kubernetes deployment on Grace Hopper / DGX systems.
#
# Prerequisites:
#   - AWS CLI configured with profile 'coaa'
#   - Terraform installed
#   - SSH client
#
# Usage:
#   ./build-and-test.sh --profile <aws-profile> --region <aws-region> [options]
#
# Required:
#   --profile         AWS CLI profile name (e.g., coaa, default, myprofile)
#   --region          AWS region (e.g., us-east-2, us-west-1, eu-west-1)
#
# Options:
#   --skip-infra        Skip terraform infrastructure creation
#   --skip-build        Skip image build (use existing image in S3)
#   --skip-test         Skip PXE boot testing
#   --cleanup           Destroy ALL infrastructure (including S3 bucket)
#   --cleanup-vms-only  Terminate VMs but keep S3 bucket with images
#   --k8s-version       Kubernetes version (default: v1.32.4)
#
# Examples:
#   ./build-and-test.sh --profile coaa --region us-east-2
#   ./build-and-test.sh --profile myaws --region us-west-1 --k8s-version v1.33.0
#   ./build-and-test.sh --profile coaa --region us-east-2 --cleanup-vms-only
#
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
SSH_KEY="$TERRAFORM_DIR/ssh-key.pem"

# Build configuration
K8S_VERSION="${K8S_VERSION:-v1.32.4}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.0.4}"
CNI_VERSION="${CNI_VERSION:-1.6.0}"
CRICTL_VERSION="${CRICTL_VERSION:-1.32.0}"

# AWS configuration (must be provided via args or env vars)
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-}"

# Options
SKIP_INFRA=false
SKIP_BUILD=false
SKIP_TEST=false
CLEANUP=false
CLEANUP_VMS_ONLY=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_banner() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           ARM64 CAPI Image Builder - End-to-End                   ║"
    echo "╠═══════════════════════════════════════════════════════════════════╣"
    echo "║  AWS Profile: $(printf '%-20s' "$AWS_PROFILE")                           ║"
    echo "║  AWS Region:  $(printf '%-20s' "$AWS_REGION")                           ║"
    echo "║  Kubernetes:  $(printf '%-20s' "$K8S_VERSION")                           ║"
    echo "║  Target: Grace Hopper / DGX ARM64 Systems                         ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v aws >/dev/null 2>&1 || missing+=("aws-cli")
    command -v terraform >/dev/null 2>&1 || missing+=("terraform")
    command -v ssh >/dev/null 2>&1 || missing+=("ssh")
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        log_error "AWS credentials not configured for profile '$AWS_PROFILE'"
        exit 1
    fi

    log_success "All prerequisites met"
}

wait_for_ssh() {
    local host=$1
    local max_attempts=${2:-30}
    local attempt=1

    log_info "Waiting for SSH on $host..."

    while [[ $attempt -le $max_attempts ]]; do
        if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
               ubuntu@"$host" "echo 'SSH ready'" 2>/dev/null; then
            log_success "SSH connection established"
            return 0
        fi
        echo -n "."
        sleep 10
        ((attempt++))
    done

    log_error "Failed to establish SSH connection after $max_attempts attempts"
    return 1
}

wait_for_cloud_init() {
    local host=$1

    log_info "Waiting for cloud-init to complete on $host..."

    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$host" \
        "cloud-init status --wait" 2>/dev/null || true

    log_success "Cloud-init completed"
}

# =============================================================================
# Infrastructure Management
# =============================================================================
create_infrastructure() {
    log_info "Creating AWS infrastructure..."
    log_info "Profile: $AWS_PROFILE, Region: $AWS_REGION"

    cd "$TERRAFORM_DIR"

    # Initialize terraform
    terraform init -input=false

    # Apply with test host enabled (on-demand by default)
    terraform apply \
        -var "aws_profile=$AWS_PROFILE" \
        -var "aws_region=$AWS_REGION" \
        -var enable_test_host=true \
        -var enable_pxe_server=false \
        -auto-approve

    # Save SSH key
    terraform output -raw ssh_private_key > "$SSH_KEY"
    chmod 600 "$SSH_KEY"

    # Get outputs
    TEST_HOST_IP=$(terraform output -raw test_host_public_ip)
    S3_BUCKET=$(terraform output -raw s3_bucket_name)

    log_success "Infrastructure created"
    log_info "Test host (c7g.metal): $TEST_HOST_IP"
    log_info "S3 bucket: $S3_BUCKET"

    export TEST_HOST_IP S3_BUCKET
}

destroy_infrastructure() {
    log_info "Destroying ALL AWS infrastructure (including S3 bucket)..."

    cd "$TERRAFORM_DIR"
    terraform destroy \
        -var "aws_profile=$AWS_PROFILE" \
        -var "aws_region=$AWS_REGION" \
        -auto-approve

    log_success "All infrastructure destroyed"
}

cleanup_vms_only() {
    log_info "Terminating VMs only (keeping S3 bucket with images)..."

    cd "$TERRAFORM_DIR"
    terraform apply \
        -var "aws_profile=$AWS_PROFILE" \
        -var "aws_region=$AWS_REGION" \
        -var enable_test_host=false \
        -var enable_pxe_server=false \
        -auto-approve

    log_success "VMs terminated. S3 bucket preserved."
    log_info "Images available at: s3://$S3_BUCKET/"
}

# =============================================================================
# Image Building
# =============================================================================
build_image() {
    log_info "Starting ARM64 CAPI image build on c7g.metal..."

    # Wait for instance to be ready
    wait_for_ssh "$TEST_HOST_IP"
    wait_for_cloud_init "$TEST_HOST_IP"

    # Copy build scripts to remote host
    log_info "Copying build scripts to remote host..."

    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$SCRIPT_DIR/remote-build.sh" \
        "$PROJECT_DIR/files/sysprep-main.yml" \
        "$PROJECT_DIR/files/sysprep-handlers.yml" \
        ubuntu@"$TEST_HOST_IP":/tmp/

    # Run the build
    log_info "Executing remote build (this takes ~5 minutes)..."

    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$TEST_HOST_IP" \
        "chmod +x /tmp/remote-build.sh && \
         K8S_VERSION=$K8S_VERSION \
         CONTAINERD_VERSION=$CONTAINERD_VERSION \
         CNI_VERSION=$CNI_VERSION \
         CRICTL_VERSION=$CRICTL_VERSION \
         /tmp/remote-build.sh" 2>&1 | tee "$PROJECT_DIR/build.log"

    log_success "Image build completed"
}

upload_to_s3() {
    log_info "Uploading images to S3..."

    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$TEST_HOST_IP" \
        "cd /opt/capi-build/output && \
         aws s3 cp . s3://$S3_BUCKET/images/ --recursive \
             --exclude '*' \
             --include '*.qcow2' \
             --include '*.raw' \
             --include '*.vmdk' \
             --include '*.ova' \
             --region $AWS_REGION && \
         aws s3 cp /opt/capi-build/pxe-files/ s3://$S3_BUCKET/pxe/ \
             --recursive --region $AWS_REGION"

    log_success "Images uploaded to S3"

    # List uploaded files
    log_info "Uploaded artifacts:"
    aws s3 ls "s3://$S3_BUCKET/" --recursive --human-readable --profile "$AWS_PROFILE"
}

# =============================================================================
# Testing
# =============================================================================
run_tests() {
    log_info "Running image validation tests..."

    # Copy test script
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        "$SCRIPT_DIR/validate-image.sh" \
        ubuntu@"$TEST_HOST_IP":/tmp/

    # Run validation
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@"$TEST_HOST_IP" \
        "chmod +x /tmp/validate-image.sh && /tmp/validate-image.sh" 2>&1 | \
        tee "$PROJECT_DIR/test.log"

    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        log_success "All tests passed!"
    else
        log_error "Some tests failed. Check test.log for details."
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                AWS_PROFILE="$2"
                shift 2
                ;;
            --region)
                AWS_REGION="$2"
                shift 2
                ;;
            --skip-infra)
                SKIP_INFRA=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-test)
                SKIP_TEST=true
                shift
                ;;
            --cleanup)
                CLEANUP=true
                shift
                ;;
            --cleanup-vms-only)
                CLEANUP_VMS_ONLY=true
                shift
                ;;
            --k8s-version)
                K8S_VERSION="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 --profile <aws-profile> --region <aws-region> [options]"
                echo ""
                echo "Required:"
                echo "  --profile           AWS CLI profile name"
                echo "  --region            AWS region"
                echo ""
                echo "Options:"
                echo "  --skip-infra        Skip terraform infrastructure creation"
                echo "  --skip-build        Skip image build"
                echo "  --skip-test         Skip validation tests"
                echo "  --cleanup           Destroy ALL infrastructure (including S3 bucket)"
                echo "  --cleanup-vms-only  Terminate VMs but keep S3 bucket with images"
                echo "  --k8s-version       Kubernetes version (default: v1.32.4)"
                echo ""
                echo "Examples:"
                echo "  $0 --profile coaa --region us-east-2"
                echo "  $0 --profile myaws --region us-west-1 --k8s-version v1.33.0"
                echo "  $0 --profile coaa --region us-east-2 --cleanup-vms-only"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_error "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Validate required args
    if [[ -z "$AWS_PROFILE" ]]; then
        log_error "Missing required argument: --profile"
        log_error "Use --help for usage information"
        exit 1
    fi

    if [[ -z "$AWS_REGION" ]]; then
        log_error "Missing required argument: --region"
        log_error "Use --help for usage information"
        exit 1
    fi
}

main() {
    parse_args "$@"
    print_banner
    check_prerequisites

    START_TIME=$(date +%s)

    # Step 1: Infrastructure
    if [[ "$SKIP_INFRA" == "false" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  STEP 1: Creating Infrastructure"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        create_infrastructure
    else
        log_warn "Skipping infrastructure creation"
        cd "$TERRAFORM_DIR"
        TEST_HOST_IP=$(terraform output -raw test_host_public_ip 2>/dev/null || echo "")
        S3_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || echo "")

        if [[ -z "$TEST_HOST_IP" ]]; then
            log_error "No existing infrastructure found. Remove --skip-infra flag."
            exit 1
        fi
        export TEST_HOST_IP S3_BUCKET
    fi

    # Step 2: Build Image
    if [[ "$SKIP_BUILD" == "false" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  STEP 2: Building ARM64 CAPI Image"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        build_image

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  STEP 3: Uploading to S3"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        upload_to_s3
    else
        log_warn "Skipping image build"
    fi

    # Step 3: Test
    if [[ "$SKIP_TEST" == "false" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  STEP 4: Validating Image"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        run_tests
    else
        log_warn "Skipping tests"
    fi

    # Cleanup
    if [[ "$CLEANUP" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Cleanup (Full)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        destroy_infrastructure
    elif [[ "$CLEANUP_VMS_ONLY" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Cleanup (VMs Only)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        cleanup_vms_only
    fi

    # Summary
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║                         BUILD COMPLETE                            ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Duration: $((DURATION / 60))m $((DURATION % 60))s"
    echo ""

    if [[ "$CLEANUP" == "true" ]]; then
        echo "  All infrastructure destroyed."
    else
        echo "  Artifacts in S3:"
        echo "    s3://$S3_BUCKET/images/ubuntu-2204-arm64-kube-${K8S_VERSION#v}.qcow2"
        echo "    s3://$S3_BUCKET/images/ubuntu-2204-arm64-kube-${K8S_VERSION#v}.raw"
        echo "    s3://$S3_BUCKET/images/ubuntu-2204-arm64-kube-${K8S_VERSION#v}.vmdk"
        echo "    s3://$S3_BUCKET/images/ubuntu-2204-arm64-kube-${K8S_VERSION#v}.ova"
        echo ""

        if [[ "$CLEANUP_VMS_ONLY" == "true" ]]; then
            echo "  VMs terminated. S3 bucket preserved."
        else
            echo "  Test Host: ubuntu@$TEST_HOST_IP"
            echo "  SSH Key:   $SSH_KEY"
            echo ""
            echo "  To terminate VMs (keep images):"
            echo "    $0 --profile $AWS_PROFILE --region $AWS_REGION --skip-infra --skip-build --skip-test --cleanup-vms-only"
            echo ""
            echo "  To destroy ALL infrastructure:"
            echo "    $0 --profile $AWS_PROFILE --region $AWS_REGION --skip-infra --skip-build --skip-test --cleanup"
        fi
    fi
    echo ""
}

main "$@"
