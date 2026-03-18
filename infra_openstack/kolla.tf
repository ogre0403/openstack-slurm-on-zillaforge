# --------------------------------------------------------------------------
# Generate kolla-ansible configuration files from templates
# --------------------------------------------------------------------------

resource "local_file" "nfs_shares" {
  content = templatefile("${path.module}/templates/nfs_shares.tpl", {
    bastion_ip = zillaforge_server.bastion.network_attachment[0].ip_address
  })
  filename = "${path.module}/../kolla-ansible/etc/kolla/config/nfs_shares"
}

resource "local_file" "globals_yml" {
  content = templatefile("${path.module}/templates/globals_yml.tpl", {
    controller_ip          = zillaforge_server.nodes[0].network_attachment[0].ip_address
    network_interface_name = data.external.nic_names.result.network_interface
    tunnel_interface_name  = data.external.nic_names.result.tunnel_interface
  })
  filename = "${path.module}/../kolla-ansible/etc/kolla/globals.yml"
}

resource "local_file" "vars" {
  content = templatefile("${path.module}/templates/99-vars.tpl", {
    server_password = var.server_password
    ansible_user    = local.cloud_user
  })
  filename = "${path.module}/../kolla-ansible/etc/kolla/inventroy/99-vars"
}

resource "local_file" "compute" {
  content = templatefile("${path.module}/templates/05-compute.tpl", {
    compute_nodes = [
      for s in slice(zillaforge_server.nodes, 1, length(zillaforge_server.nodes)) : {
        name = s.name
        ip   = s.network_attachment[0].ip_address
      }
    ]
  })
  filename = "${path.module}/../kolla-ansible/etc/kolla/inventroy/05-compute"
}

resource "local_file" "controller" {
  content = templatefile("${path.module}/templates/01-controller.tpl", {
    controller_name = zillaforge_server.nodes[0].name
    controller_ip   = zillaforge_server.nodes[0].network_attachment[0].ip_address
  })
  filename = "${path.module}/../kolla-ansible/etc/kolla/inventroy/01-controller"
}

resource "null_resource" "sync_project" {
  depends_on = [local_file.globals_yml]

  triggers = {
    bastion_ip   = zillaforge_floating_ip.bastion.ip_address
    project_root = local.project_root
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOF
      set -euo pipefail
      command -v sshpass >/dev/null || { echo "sshpass is required to sync files"; exit 1; }
      sshpass -p "${var.server_password}" rsync -az --exclude '.git' -e "ssh -o StrictHostKeyChecking=no" "${local.project_root}/" "${local.cloud_user}@${zillaforge_floating_ip.bastion.ip_address}:resource_manage/"
    EOF
  }
}
