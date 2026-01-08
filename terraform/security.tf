# Security group for build/test hosts
resource "aws_security_group" "builder" {
  name        = "${var.project_name}-builder-sg"
  description = "Security group for ARM CAPI image builder"
  vpc_id      = local.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Consider restricting to your IP
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-builder-sg"
    Project = var.project_name
  }
}

# Security group for PXE server
resource "aws_security_group" "pxe" {
  name        = "${var.project_name}-pxe-sg"
  description = "Security group for PXE server"
  vpc_id      = local.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # TFTP (PXE boot)
  ingress {
    description = "TFTP"
    from_port   = 69
    to_port     = 69
    protocol    = "udp"
    cidr_blocks = ["172.31.0.0/16"]
  }

  # DHCP server
  ingress {
    description = "DHCP server"
    from_port   = 67
    to_port     = 67
    protocol    = "udp"
    cidr_blocks = ["172.31.0.0/16"]
  }

  # DHCP client
  ingress {
    description = "DHCP client"
    from_port   = 68
    to_port     = 68
    protocol    = "udp"
    cidr_blocks = ["172.31.0.0/16"]
  }

  # HTTP for image downloads
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["172.31.0.0/16"]
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-pxe-sg"
    Project = var.project_name
  }
}
