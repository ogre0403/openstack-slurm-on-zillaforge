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

# --------------------------------------------------------------------------
# Data sources
# --------------------------------------------------------------------------

data "zillaforge_flavors" "selected" {
  name = var.flavor_name
}

data "zillaforge_images" "selected" {
  repository = var.image_repository
  tag        = var.image_tag
}

data "zillaforge_networks" "default" {
  name = var.default_network_name
}

data "zillaforge_networks" "optional" {
  name = var.optional_network_name
}

data "zillaforge_security_groups" "selected" {
  name = var.securitygroup_name
}

data "zillaforge_keypairs" "selected" {
  name = var.keypair_name
}

# --------------------------------------------------------------------------
# Bastion VM — single NIC on default network, with Floating IP
# --------------------------------------------------------------------------

resource "zillaforge_floating_ip" "bastion" {
  name = "opsk-bastion-tf-fip"
}

resource "zillaforge_server" "bastion" {
  name      = "opsk-bastion-tf"
  flavor_id = data.zillaforge_flavors.selected.flavors[0].id
  image_id  = data.zillaforge_images.selected.images[0].id
  keypair   = data.zillaforge_keypairs.selected.keypairs[0].id
  password  = var.server_password


  network_attachment {
    network_id         = data.zillaforge_networks.default.networks[0].id
    primary            = true
    security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
    floating_ip_id     = zillaforge_floating_ip.bastion.id
  }
}

# --------------------------------------------------------------------------
# Worker VMs — two NICs, no Floating IP, count driven by var.total
# --------------------------------------------------------------------------

resource "zillaforge_server" "nodes" {
  count = var.total

  name      = format("opsk-%02d-tf", count.index + 1)
  flavor_id = data.zillaforge_flavors.selected.flavors[0].id
  image_id  = data.zillaforge_images.selected.images[0].id
  keypair   = data.zillaforge_keypairs.selected.keypairs[0].id
  password  = var.server_password

  network_attachment {
    network_id         = data.zillaforge_networks.default.networks[0].id
    primary            = true
    security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
  }

  network_attachment {
    network_id         = data.zillaforge_networks.optional.networks[0].id
    security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
  }
}

# --------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------

output "bastion_floating_ip" {
  value = zillaforge_server.bastion.network_attachment[0].floating_ip
}

output "bastion_id" {
  value = zillaforge_server.bastion.id
}

output "node_ids" {
  value = { for s in zillaforge_server.nodes : s.name => s.id }
}
