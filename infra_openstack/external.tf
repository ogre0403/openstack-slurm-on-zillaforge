# --------------------------------------------------------------------------
# External scripts — runs during terraform plan/apply on the local machine
# --------------------------------------------------------------------------

module "check_deps" {
  source = "../modules/check_deps"
}

# Discover NIC names by SSH-ing into bastion after it is reachable
data "external" "nic_names" {
  depends_on = [module.check_deps]
  program    = ["bash", "${path.module}/scripts/discover_nics.sh"]

  query = {
    host        = zillaforge_floating_ip.bastion.ip_address
    user        = local.cloud_user
    password    = var.server_password
    default_ip  = zillaforge_server.bastion.network_attachment[0].ip_address
    optional_ip = try(zillaforge_server.bastion.network_attachment[1].ip_address, "")
  }
}
