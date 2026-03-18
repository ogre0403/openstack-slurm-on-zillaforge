# --------------------------------------------------------------------------
# External scripts — runs during terraform plan/apply on the local machine
# --------------------------------------------------------------------------

# Early dependency check — ensures sshpass & ssh exist on this machine
# before any resource is created (runs during terraform plan).
data "external" "check_deps" {
  program = ["bash", "${path.module}/scripts/check_deps.sh"]
  query   = {}
}

# Discover NIC names by SSH-ing into bastion after it is reachable
data "external" "nic_names" {
  depends_on = [data.external.check_deps]
  program    = ["bash", "${path.module}/scripts/discover_nics.sh"]

  query = {
    host        = zillaforge_floating_ip.bastion.ip_address
    user        = local.cloud_user
    password    = var.server_password
    default_ip  = zillaforge_server.bastion.network_attachment[0].ip_address
    optional_ip = zillaforge_server.bastion.network_attachment[1].ip_address
  }
}
