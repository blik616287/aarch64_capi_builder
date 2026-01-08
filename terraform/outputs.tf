output "ssh_private_key" {
  description = "SSH private key for EC2 access"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}

output "ssh_public_key" {
  description = "SSH public key"
  value       = tls_private_key.ssh.public_key_openssh
}

output "build_host_public_ip" {
  description = "Public IP of the build host"
  value       = aws_instance.build_host.public_ip
}

output "build_host_private_ip" {
  description = "Private IP of the build host"
  value       = aws_instance.build_host.private_ip
}

output "test_host_public_ip" {
  description = "Public IP of the ARM test host"
  value       = var.enable_test_host ? aws_instance.test_host[0].public_ip : null
}

output "pxe_server_public_ip" {
  description = "Public IP of the PXE server"
  value       = var.enable_pxe_server ? aws_instance.pxe_server[0].public_ip : null
}

output "s3_bucket_name" {
  description = "S3 bucket for image artifacts"
  value       = aws_s3_bucket.images.id
}

output "ssh_command_build" {
  description = "SSH command to connect to build host"
  value       = "ssh -i ssh-key.pem ubuntu@${aws_instance.build_host.public_ip}"
}

output "save_ssh_key_command" {
  description = "Command to save SSH key locally"
  value       = "terraform output -raw ssh_private_key > ssh-key.pem && chmod 600 ssh-key.pem"
}
