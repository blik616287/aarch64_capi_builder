# Auto-discover default VPC and subnet if not provided

# Get the default VPC
data "aws_vpc" "default" {
  default = true
}

# Get a subnet in the default VPC (first available)
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

# Get availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Locals for resolved values
locals {
  # Use provided VPC or default VPC
  vpc_id = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default.id

  # Use provided subnet or first available in VPC
  subnet_id = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.default.ids[0]

  # AWS account ID
  account_id = data.aws_caller_identity.current.account_id
}
