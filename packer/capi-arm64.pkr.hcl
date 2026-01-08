packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
    ansible = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "kubernetes_semver" {
  type    = string
}

variable "kubernetes_series" {
  type    = string
}

variable "kubernetes_deb_version" {
  type    = string
}

variable "containerd_version" {
  type    = string
}

variable "kubernetes_cni_semver" {
  type    = string
}

variable "kubernetes_cni_deb_version" {
  type    = string
}

variable "crictl_version" {
  type    = string
}

variable "image_builder_dir" {
  type    = string
}

variable "output_directory" {
  type    = string
  default = "output"
}

source "qemu" "capi-ubuntu-arm64" {
  iso_url          = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img"
  iso_checksum     = "file:https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS"
  disk_image       = true
  output_directory = var.output_directory
  format           = "qcow2"

  qemu_binary      = "qemu-system-aarch64"
  machine_type     = "virt"
  accelerator      = "kvm"
  cpu_model        = "host"

  memory           = 4096
  cpus             = 4
  disk_size        = "20G"

  headless         = true

  ssh_username     = "builder"
  ssh_password     = "5fYrXb8i2zjcOMxF"
  ssh_timeout      = "20m"

  shutdown_command = ""
  shutdown_timeout = "5m"

  boot_wait        = "10s"

  cd_files         = ["/opt/capi-build/cloud-init/*"]
  cd_label         = "cidata"

  efi_boot          = true
  efi_firmware_code = "/usr/share/AAVMF/AAVMF_CODE.fd"
  efi_firmware_vars = "/usr/share/AAVMF/AAVMF_VARS.fd"

  vm_name          = "ubuntu-2204-arm64-kube-${var.kubernetes_semver}"
}

build {
  sources = ["source.qemu.capi-ubuntu-arm64"]

  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init...'",
      "cloud-init status --wait || true",
      "echo 'Cloud-init complete'",
      "uname -a"
    ]
  }

  provisioner "ansible" {
    playbook_file   = "${var.image_builder_dir}/ansible/firstboot.yml"
    user            = "builder"
    use_proxy       = false
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False"
    ]
    extra_arguments = [
      "-e", "ansible_python_interpreter=/usr/bin/python3",
      "-e", "ansible_ssh_pass=5fYrXb8i2zjcOMxF",
      "--ssh-extra-args", "-o PubkeyAuthentication=no",
      "-e", "ubuntu_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "ubuntu_security_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "extra_debs=",
      "-e", "extra_repos=",
      "-e", "disable_public_repos=false",
      "-e", "reenable_public_repos=true",
      "-e", "remove_extra_repos=false",
      "-e", "@/opt/capi-build/arm64-vars.json"
    ]
  }

  provisioner "shell" {
    expect_disconnect = true
    inline = ["sudo reboot now"]
  }

  provisioner "ansible" {
    playbook_file   = "${var.image_builder_dir}/ansible/node.yml"
    user            = "builder"
    use_proxy       = false
    pause_before    = "30s"
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False"
    ]
    extra_arguments = [
      "-e", "ansible_ssh_pass=5fYrXb8i2zjcOMxF",
      "--ssh-extra-args", "-o PubkeyAuthentication=no",
      "-e", "ansible_python_interpreter=/usr/bin/python3",
      "-e", "kubernetes_semver=${var.kubernetes_semver}",
      "-e", "kubernetes_series=${var.kubernetes_series}",
      "-e", "kubernetes_deb_version=${var.kubernetes_deb_version}",
      "-e", "kubernetes_source_type=pkg",
      "-e", "kubernetes_cni_semver=${var.kubernetes_cni_semver}",
      "-e", "kubernetes_cni_deb_version=${var.kubernetes_cni_deb_version}",
      "-e", "kubernetes_cni_source_type=pkg",
      "-e", "containerd_version=${var.containerd_version}",
      "-e", "containerd_service_url=https://raw.githubusercontent.com/containerd/containerd/refs/tags/v${var.containerd_version}/containerd.service",
      "-e", "containerd_wasm_shims_runtimes=",
      "-e", "containerd_additional_settings=",
      "-e", "containerd_cri_socket=/var/run/containerd/containerd.sock",
      "-e", "containerd_gvisor_runtime=false",
      "-e", "containerd_gvisor_version=latest",
      "-e", "runc_version=1.2.8",
      "-e", "crictl_version=${var.crictl_version}",
      "-e", "pause_image=registry.k8s.io/pause:3.10",
      "-e", "kubernetes_container_registry=registry.k8s.io",
      "-e", "kubernetes_deb_repo=https://pkgs.k8s.io/core:/stable:/${var.kubernetes_series}/deb/",
      "-e", "kubernetes_deb_gpg_key=https://pkgs.k8s.io/core:/stable:/${var.kubernetes_series}/deb/Release.key",
      "-e", "systemd_prefix=/usr/lib/systemd",
      "-e", "sysusr_prefix=/usr",
      "-e", "sysusrlocal_prefix=/usr/local",
      "-e", "python_path=",
      "-e", "http_proxy=",
      "-e", "https_proxy=",
      "-e", "no_proxy=",
      "-e", "disable_public_repos=false",
      "-e", "reenable_public_repos=true",
      "-e", "remove_extra_repos=false",
      "-e", "node_custom_roles_pre=",
      "-e", "node_custom_roles_post=",
      "-e", "node_custom_roles_post_sysprep=",
      "-e", "load_additional_components=false",
      "-e", "additional_registry_images=false",
      "-e", "additional_url_images=false",
      "-e", "additional_executables=false",
      "-e", "ecr_credential_provider=false",
      "-e", "ubuntu_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "ubuntu_security_repo=http://ports.ubuntu.com/ubuntu-ports",
      "-e", "extra_debs=",
      "-e", "extra_repos="
    ]
  }

}
