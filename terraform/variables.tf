variable "aws_region" {
  description = "AWS region"
  type        = string
  # No default - must be provided
}

variable "aws_profile" {
  description = "AWS CLI profile"
  type        = string
  # No default - must be provided
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
  default     = "arm-capi-builder"
}

variable "vpc_id" {
  description = "VPC ID for resources (leave empty to use default VPC)"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID for EC2 instances (leave empty to auto-select)"
  type        = string
  default     = ""
}

variable "build_instance_type" {
  description = "Instance type for x86 build host"
  type        = string
  default     = "c5.2xlarge"
}

variable "test_instance_type" {
  description = "Instance type for ARM test host (bare metal)"
  type        = string
  default     = "c7g.metal"
}

variable "pxe_instance_type" {
  description = "Instance type for PXE server"
  type        = string
  default     = "t4g.small"
}

variable "enable_test_host" {
  description = "Whether to create the ARM test host (expensive, enable only when needed)"
  type        = bool
  default     = false
}

variable "enable_pxe_server" {
  description = "Whether to create the PXE server"
  type        = bool
  default     = false
}

variable "use_spot_instances" {
  description = "Use spot instances for cost savings (often unavailable for metal instances)"
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Maximum spot price (0 = on-demand price cap)"
  type        = string
  default     = "0"
}
