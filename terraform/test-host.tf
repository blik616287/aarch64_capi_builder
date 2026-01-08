# Get latest Ubuntu 22.04 AMI for ARM64
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ARM Test Host (c7g.metal) - Only created when enabled
# This is a bare metal instance with full KVM support for testing nested virtualization
resource "aws_instance" "test_host" {
  count = var.enable_test_host ? 1 : 0

  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.test_instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.builder.id]
  iam_instance_profile   = aws_iam_instance_profile.builder.name

  associate_public_ip_address = true

  # Use spot instance for cost savings
  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price          = var.spot_max_price == "0" ? null : var.spot_max_price
        spot_instance_type = "one-time"
      }
    }
  }

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Update system
    apt-get update
    apt-get upgrade -y

    # Install KVM and virtualization tools
    apt-get install -y \
      qemu-kvm \
      libvirt-daemon-system \
      libvirt-clients \
      virtinst \
      bridge-utils \
      cpu-checker \
      qemu-utils \
      cloud-image-utils \
      awscli \
      jq

    # Add ubuntu user to libvirt group
    usermod -aG libvirt ubuntu
    usermod -aG kvm ubuntu

    # Enable and start libvirtd
    systemctl enable libvirtd
    systemctl start libvirtd

    # Verify KVM is available
    if [ -e /dev/kvm ]; then
      echo "KVM is available!"
      chmod 666 /dev/kvm
    else
      echo "WARNING: KVM not available on this instance"
    fi

    # Create working directory
    mkdir -p /opt/test-images
    chown ubuntu:ubuntu /opt/test-images

    # Signal completion
    touch /tmp/user-data-complete

    echo "Test host setup complete!"
  EOF

  tags = {
    Name    = "${var.project_name}-test-host"
    Project = var.project_name
    Role    = "tester"
  }
}

# Output spot instance request ID if using spot
output "test_host_spot_request_id" {
  description = "Spot instance request ID (if using spot)"
  value       = var.enable_test_host && var.use_spot_instances ? aws_instance.test_host[0].spot_instance_request_id : null
}
