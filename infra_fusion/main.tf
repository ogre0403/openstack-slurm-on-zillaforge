terraform {
  required_providers {
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3.0"
    }

    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }

    zillaforge = {
      source  = "hashicorp/zillaforge"
      version = "0.0.1-alpha"
    }
  }
}

provider "zillaforge" {
  api_endpoint     = var.api_endpoint
  api_key          = var.api_key
  project_sys_code = var.project_sys_code
}

locals {
  cloud_user          = "cloud-user"
  project_root        = abspath("${path.root}/..")
  nfs_share_dir       = "/home"
  optional_network_id = try(data.zillaforge_networks.optional[0].networks[0].id, null)

  # Node naming:
  #   index 0 = Slurm headnode
  #   index 1 = OpenStack controller
  #   index 2..total-1 = dual-role workers (Slurm compute + OpenStack compute)
  headnode_hostname   = format("%s-01-headnode-tf", var.node_name_prefix)
  controller_hostname = format("%s-02-control-tf", var.node_name_prefix)
  worker_hostnames    = [for i in range(var.total - 2) : format("%s-%02d-worker-tf", var.node_name_prefix, i + 3)]

  worker_odd_hostnames  = [for i in range(var.total - 2) : local.worker_hostnames[i] if(i + 3) % 2 == 1]
  worker_even_hostnames = [for i in range(var.total - 2) : local.worker_hostnames[i] if(i + 3) % 2 == 0]
}
