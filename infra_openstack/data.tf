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

  lifecycle {
    postcondition {
      condition     = length(self.networks) > 0
      error_message = "Network '${var.optional_network_name}' does not exist. Please create it manually before running terraform apply."
    }
  }
}

data "zillaforge_security_groups" "selected" {
  name = var.securitygroup_name
}

data "zillaforge_keypairs" "selected" {
  name = var.keypair_name
}
