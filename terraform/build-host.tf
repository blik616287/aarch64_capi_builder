# Get latest Ubuntu 22.04 AMI for x86
data "aws_ami" "ubuntu_x86" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# x86 Build Host (c5.2xlarge)
resource "aws_instance" "build_host" {
  ami                    = data.aws_ami.ubuntu_x86.id
  instance_type          = var.build_instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.builder.id]
  iam_instance_profile   = aws_iam_instance_profile.builder.name

  associate_public_ip_address = true

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/user-data.log) 2>&1

    echo "=== Starting build host setup ==="

    # Retry function for apt operations
    apt_retry() {
      local max_attempts=3
      local attempt=1
      while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt of $max_attempts: $@"
        if "$@"; then
          return 0
        fi
        echo "Failed, retrying in 10 seconds..."
        sleep 10
        apt-get update --fix-missing || true
        attempt=$((attempt + 1))
      done
      echo "All attempts failed for: $@"
      return 1
    }

    # Wait for apt locks to be released (cloud-init may be running)
    wait_for_apt() {
      while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo "Waiting for apt lock..."
        sleep 5
      done
    }

    wait_for_apt

    # Update package lists
    apt_retry apt-get update

    # Skip upgrade - just install what we need (avoids transient mirror issues)
    # apt-get upgrade -y

    # Install basic dependencies
    apt_retry apt-get install -y --no-install-recommends \
      git \
      make \
      curl \
      unzip \
      jq \
      python3-pip \
      python3-venv \
      awscli

    # Install QEMU for ARM emulation
    apt_retry apt-get install -y --no-install-recommends \
      qemu-user-static \
      binfmt-support \
      qemu-system-arm \
      qemu-utils \
      qemu-efi-aarch64

    # Enable ARM64 binary format
    update-binfmts --enable qemu-aarch64

    # Verify binfmt is working
    if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
      echo "ARM64 emulation enabled successfully"
    else
      echo "WARNING: ARM64 emulation may not be properly configured"
    fi

    # Install Packer
    curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com jammy main" > /etc/apt/sources.list.d/hashicorp.list
    apt-get update
    apt_retry apt-get install -y packer

    # Install Ansible
    pip3 install --break-system-packages ansible || pip3 install ansible

    # Create working directory
    mkdir -p /opt/image-builder/scripts
    mkdir -p /opt/image-builder/output
    chown -R ubuntu:ubuntu /opt/image-builder

    # Clone image-builder repo as ubuntu user
    su - ubuntu -c "git clone https://github.com/kubernetes-sigs/image-builder.git /opt/image-builder/image-builder"

    # Signal completion
    touch /tmp/user-data-complete

    echo "=== Build host setup complete ==="
  EOF

  tags = {
    Name    = "${var.project_name}-build-host"
    Project = var.project_name
    Role    = "builder"
  }
}
