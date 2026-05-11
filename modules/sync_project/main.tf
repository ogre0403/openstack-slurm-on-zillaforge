terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

variable "project_root" {
  type = string
}

variable "cloud_user" {
  type = string
}

variable "server_password" {
  type      = string
  sensitive = true
}

variable "target_host" {
  type = string
}

resource "null_resource" "sync_project" {
  triggers = {
    target_host  = var.target_host
    project_root = var.project_root
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOF
      set -euo pipefail
      command -v sshpass >/dev/null || { echo "sshpass is required to sync files"; exit 1; }
      retries=10
      delay=15
      for i in $(seq 1 $retries); do
        sshpass -p "${var.server_password}" rsync -az --exclude '.git' -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10" "${var.project_root}/" "${var.cloud_user}@${var.target_host}:resource_manage/" && break
        echo "Attempt $i/$retries failed, retrying in $${delay}s..."
        sleep $delay
        if [ $i -eq $retries ]; then
          echo "All $retries attempts failed"
          exit 1
        fi
      done
    EOF
  }
}
