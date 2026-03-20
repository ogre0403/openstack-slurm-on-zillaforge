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
  headnode_hostname   = format("%s-01-headnode-tf", var.node_name_prefix)
  compute_hostnames   = [for i in range(var.total - 1) : format("%s-%02d-compute-tf", var.node_name_prefix, i + 2)]
  nfs_share_dir       = "/home"
  optional_network_id = try(data.zillaforge_networks.optional[0].networks[0].id, null)

  compute_odd_hostnames  = [for i in range(var.total - 1) : local.compute_hostnames[i] if(i + 2) % 2 == 1]
  compute_even_hostnames = [for i in range(var.total - 1) : local.compute_hostnames[i] if(i + 2) % 2 == 0]
}
