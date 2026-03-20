terraform {
  required_providers {
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
  optional_network_id = try(data.zillaforge_networks.optional[0].networks[0].id, null)
}
