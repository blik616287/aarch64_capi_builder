# ARM64 CAPI Image Builder

Automated build system for creating ARM64 Cluster API (CAPI) images for Kubernetes deployment on NVIDIA Grace Hopper / DGX systems.

## Quick Start

```bash
# Build and test with your AWS profile and region
./scripts/build-and-test.sh --profile <your-profile> --region <your-region>

# Examples:
./scripts/build-and-test.sh --profile coaa --region us-east-2
./scripts/build-and-test.sh --profile default --region us-west-1
./scripts/build-and-test.sh --profile mycompany --region eu-west-1 --k8s-version v1.33.0
```

This will:
1. Create AWS infrastructure (c7g.metal ARM64 instance) in your specified region
2. Build the CAPI image with Kubernetes
3. Convert to multiple formats (QCOW2, RAW, VMDK, OVA)
4. Upload to S3
5. Run validation tests

## Prerequisites

- **AWS CLI** configured with your profile
- **Terraform** >= 1.0
- **SSH client**
- **jq** for JSON parsing

```bash
# Verify prerequisites (replace with your profile)
aws sts get-caller-identity --profile <your-profile>
terraform version
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Your Machine (runs build-and-test.sh)                          │
│  - Terraform to create infrastructure                           │
│  - SSH to orchestrate remote build                              │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  c7g.metal ARM64 Instance (~$2.50/hr)                           │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Packer + QEMU/KVM                                      │    │
│  │  - Native ARM64 build (no emulation)                    │    │
│  │  - kubernetes-sigs/image-builder ansible playbooks      │    │
│  │  - Build time: ~4 minutes                               │    │
│  └─────────────────────────────────────────────────────────┘    │
│                            │                                     │
│                            ▼                                     │
│  Output: QCOW2, RAW, VMDK, OVA + PXE files                      │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  S3 Bucket                                                      │
│  s3://arm-capi-builder-images-{account}/                        │
│  ├── images/                                                    │
│  │   ├── ubuntu-2204-arm64-kube-v1.32.4.qcow2                  │
│  │   ├── ubuntu-2204-arm64-kube-v1.32.4.raw                    │
│  │   ├── ubuntu-2204-arm64-kube-v1.32.4.vmdk                   │
│  │   └── ubuntu-2204-arm64-kube-v1.32.4.ova                    │
│  └── pxe/                                                       │
│      ├── vmlinuz-5.15.0-*                                       │
│      └── initrd.img-5.15.0-*                                    │
└─────────────────────────────────────────────────────────────────┘
```

## Usage

### Required Arguments

Every invocation requires AWS profile and region:

```bash
./scripts/build-and-test.sh --profile <profile> --region <region>
```

### Full Build (Default)

```bash
cd /home/blik/Desktop/instruct
./scripts/build-and-test.sh --profile coaa --region us-east-2
```

### Custom Kubernetes Version

```bash
./scripts/build-and-test.sh --profile coaa --region us-east-2 --k8s-version v1.33.0
```

### Skip Stages

```bash
# Skip infrastructure (use existing)
./scripts/build-and-test.sh --profile coaa --region us-east-2 --skip-infra

# Skip build (test existing image)
./scripts/build-and-test.sh --profile coaa --region us-east-2 --skip-infra --skip-build

# Skip tests
./scripts/build-and-test.sh --profile coaa --region us-east-2 --skip-test
```

### Cleanup After Build

```bash
# Terminate VMs but keep S3 bucket with images
./scripts/build-and-test.sh --profile coaa --region us-east-2 --cleanup-vms-only

# Destroy ALL infrastructure (including S3 bucket)
./scripts/build-and-test.sh --profile coaa --region us-east-2 --cleanup
```

### Manual Steps

If you prefer to run steps manually:

```bash
# 1. Create infrastructure
cd terraform
terraform init
terraform apply \
  -var "aws_profile=YOUR_PROFILE" \
  -var "aws_region=YOUR_REGION" \
  -var enable_test_host=true \
  -var use_spot_instances=false

# 2. Save SSH key
terraform output -raw ssh_private_key > ssh-key.pem
chmod 600 ssh-key.pem

# 3. SSH to build host
ssh -i ssh-key.pem ubuntu@$(terraform output -raw test_host_public_ip)

# 4. Run build (on remote host)
/tmp/remote-build.sh

# 5. Upload to S3 (on remote host)
aws s3 cp /opt/capi-build/output/ s3://BUCKET/images/ --recursive

# 6. Run tests (on remote host)
/tmp/validate-image.sh
```

## Output Artifacts

| Format | Use Case | Size |
|--------|----------|------|
| **QCOW2** | KVM/QEMU, OpenStack | ~4 GB |
| **RAW** | Bare metal, dd to disk | 20 GB |
| **VMDK** | VMware | ~4 GB |
| **OVA** | VMware import | ~4 GB |

### PXE Boot Files

| File | Description |
|------|-------------|
| `vmlinuz-*` | Linux kernel for ARM64 |
| `initrd.img-*` | Initial ramdisk |

## Image Contents

- **Ubuntu 22.04 LTS** (Jammy) ARM64
- **Kubernetes v1.32.4** (kubeadm, kubectl, kubelet)
- **containerd v2.0.4**
- **CNI plugins v1.6.0**
- **crictl v1.32.0**
- Cloud-init enabled
- SSH server configured

## Configuration

### Command Line Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `--profile` | **Yes** | AWS CLI profile name |
| `--region` | **Yes** | AWS region |
| `--k8s-version` | No | Kubernetes version (default: v1.32.4) |
| `--skip-infra` | No | Skip terraform infrastructure creation |
| `--skip-build` | No | Skip image build |
| `--skip-test` | No | Skip validation tests |
| `--cleanup` | No | Destroy ALL infrastructure (including S3) |
| `--cleanup-vms-only` | No | Terminate VMs but keep S3 bucket |

### Environment Variables (Optional)

| Variable | Description |
|----------|-------------|
| `K8S_VERSION` | Kubernetes version (default: v1.32.4) |
| `CONTAINERD_VERSION` | containerd version (default: 2.0.4) |
| `CNI_VERSION` | CNI plugins version (default: 1.6.0) |
| `CRICTL_VERSION` | crictl version (default: 1.32.0) |

### Terraform Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_profile` | (required) | AWS CLI profile |
| `aws_region` | (required) | AWS region |
| `vpc_id` | (auto) | VPC ID (auto-discovers default VPC) |
| `subnet_id` | (auto) | Subnet ID (auto-selects from VPC) |
| `enable_test_host` | false | Create c7g.metal instance |
| `enable_pxe_server` | false | Create PXE test server |
| `use_spot_instances` | false | Use spot pricing (often unavailable for metal) |

## Cost Estimate

| Resource | Rate | Typical Usage |
|----------|------|---------------|
| c7g.metal | ~$2.50/hr | 15-20 min build |
| S3 storage | ~$0.023/GB/mo | ~30 GB |
| **Total per build** | | **~$1-2** |

## Troubleshooting

### Build Fails with SSH Timeout

The image-builder ansible provisioner needs password auth:
- Ensure `sshpass` is installed on the build host
- Cloud-init must set up the builder user with password

### Spot Instance Unavailable

c7g.metal spot capacity is often exhausted:
```bash
terraform apply -var use_spot_instances=false
```

### Image Won't Boot

Check EFI firmware paths:
```bash
ls /usr/share/AAVMF/AAVMF_CODE.fd
ls /usr/share/AAVMF/AAVMF_VARS.fd
```

### containerd Not Starting

Check the service:
```bash
systemctl status containerd
journalctl -u containerd
```

## File Structure

```
.
├── README.md                 # This file
├── scripts/
│   ├── build-and-test.sh     # Main orchestration script
│   ├── remote-build.sh       # Runs on c7g.metal
│   └── validate-image.sh     # Image validation tests
├── terraform/
│   ├── providers.tf          # AWS provider config
│   ├── variables.tf          # Input variables
│   ├── keypair.tf            # SSH key generation
│   ├── security.tf           # Security groups
│   ├── s3.tf                 # Image storage bucket
│   ├── build-host.tf         # x86 builder (unused)
│   ├── test-host.tf          # ARM64 c7g.metal
│   └── pxe-server.tf         # Optional PXE server
├── ansible/                  # Ansible playbooks (reference)
└── packer/                   # Packer configs (reference)
```

## Testing the Image

### Boot with QEMU

```bash
# Download from S3
aws s3 cp s3://BUCKET/images/ubuntu-2204-arm64-kube-v1.32.4.qcow2 .

# Boot with KVM (on ARM64 host)
qemu-system-aarch64 \
  -machine virt,accel=kvm \
  -cpu host -m 4096 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
  -drive file=ubuntu-2204-arm64-kube-v1.32.4.qcow2,format=qcow2,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -nographic
```

### Initialize Kubernetes

```bash
# Inside the VM
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# Copy kubeconfig
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install CNI (e.g., Flannel)
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```

## License
MIT
