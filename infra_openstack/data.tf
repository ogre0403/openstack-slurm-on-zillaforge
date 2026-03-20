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
  count = var.optional_network_name == null || var.optional_network_name == "" ? 0 : 1

  name = var.optional_network_name
}

data "zillaforge_security_groups" "selected" {
  name = var.securitygroup_name
}

data "zillaforge_keypairs" "selected" {
  name = var.keypair_name
}
