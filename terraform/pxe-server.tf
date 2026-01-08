# PXE Server (t4g.small ARM instance)
# Used for testing PXE boot in AWS before deploying to on-prem
resource "aws_instance" "pxe_server" {
  count = var.enable_pxe_server ? 1 : 0

  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.pxe_instance_type
  key_name               = aws_key_pair.main.key_name
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.pxe.id]
  iam_instance_profile   = aws_iam_instance_profile.builder.name

  associate_public_ip_address = true

  # Disable source/dest check for DHCP/PXE to work
  source_dest_check = false

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Update system
    apt-get update
    apt-get upgrade -y

    # Install PXE server components
    apt-get install -y \
      dnsmasq \
      nginx \
      tftpd-hpa \
      grub-efi-arm64-bin \
      awscli \
      jq

    # Create TFTP directories
    mkdir -p /var/lib/tftpboot/grub
    mkdir -p /var/www/html/images

    # Get GRUB EFI binary for ARM64
    cp /usr/lib/grub/arm64-efi/grubaa64.efi /var/lib/tftpboot/ 2>/dev/null || \
    cp /usr/lib/grub/arm64-efi-signed/grubaa64.efi /var/lib/tftpboot/ 2>/dev/null || \
    grub-mkimage -o /var/lib/tftpboot/grubaa64.efi -O arm64-efi -p /grub \
      net tftp http linux normal configfile

    # Create basic GRUB config
    cat > /var/lib/tftpboot/grub/grub.cfg << 'GRUBCFG'
    set timeout=10
    set default=0

    menuentry "Ubuntu ARM64 CAPI Image" {
        linux /vmlinuz-arm64 ip=dhcp root=/dev/ram0 ramdisk_size=2097152
        initrd /initrd-arm64.img
    }

    menuentry "Ubuntu ARM64 CAPI Image (Install)" {
        linux /vmlinuz-arm64 ip=dhcp autoinstall ds=nocloud-net;s=http://$${pxe_server_ip}/cloud-init/
        initrd /initrd-arm64.img
    }
    GRUBCFG

    # Get local IP for configuration
    LOCAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

    # Configure dnsmasq for DHCP and TFTP
    cat > /etc/dnsmasq.d/pxe.conf << DNSMASQ
    # Disable DNS
    port=0

    # Enable TFTP
    enable-tftp
    tftp-root=/var/lib/tftpboot

    # DHCP range (adjust for your subnet)
    # Using a small range within the VPC subnet for testing
    dhcp-range=172.31.0.200,172.31.0.250,255.255.240.0,12h

    # PXE boot options for ARM64 UEFI
    dhcp-match=set:efi-arm64,option:client-arch,11
    dhcp-boot=tag:efi-arm64,grubaa64.efi

    # Set next-server to this host
    dhcp-option=66,$LOCAL_IP

    # Log DHCP requests
    log-dhcp
    DNSMASQ

    # Configure nginx for serving large image files
    cat > /etc/nginx/sites-available/pxe << 'NGINX'
    server {
        listen 80;
        server_name _;

        location /images/ {
            alias /var/www/html/images/;
            autoindex on;
        }

        location /cloud-init/ {
            alias /var/www/html/cloud-init/;
            autoindex on;
        }
    }
    NGINX

    ln -sf /etc/nginx/sites-available/pxe /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    # Create cloud-init directory
    mkdir -p /var/www/html/cloud-init

    # Create basic cloud-init meta-data
    cat > /var/www/html/cloud-init/meta-data << 'METADATA'
    instance-id: pxe-boot-instance
    local-hostname: pxe-client
    METADATA

    # Create basic cloud-init user-data
    cat > /var/www/html/cloud-init/user-data << 'USERDATA'
    #cloud-config
    users:
      - name: ubuntu
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        ssh_authorized_keys:
          - ssh-rsa PLACEHOLDER_FOR_SSH_KEY

    package_update: true
    packages:
      - qemu-guest-agent
    USERDATA

    # Set permissions
    chown -R tftp:tftp /var/lib/tftpboot
    chmod -R 755 /var/lib/tftpboot
    chown -R www-data:www-data /var/www/html
    chmod -R 755 /var/www/html

    # Note: dnsmasq is NOT started by default to avoid conflicts
    # Start manually after verifying configuration:
    # sudo systemctl start dnsmasq

    systemctl enable nginx
    systemctl restart nginx

    # Signal completion
    touch /tmp/user-data-complete

    echo "PXE server setup complete!"
    echo "NOTE: dnsmasq (DHCP) is NOT started automatically."
    echo "Review /etc/dnsmasq.d/pxe.conf and start manually when ready."
  EOF

  tags = {
    Name    = "${var.project_name}-pxe-server"
    Project = var.project_name
    Role    = "pxe"
  }
}

# Output PXE server IP for GRUB config
output "pxe_server_private_ip" {
  description = "Private IP of the PXE server"
  value       = var.enable_pxe_server ? aws_instance.pxe_server[0].private_ip : null
}
