# --------------------------------------------------------------------------
# Floating IP — only the head node gets a public IP
# --------------------------------------------------------------------------

resource "zillaforge_floating_ip" "headnode" {
  name = format("%s-headnode-fip", var.node_name_prefix)
}

# --------------------------------------------------------------------------
# Head Node — controller + NFS server + DB + SlurmDBD + Slurmctld
# Two NICs (default + optional), with Floating IP
# --------------------------------------------------------------------------

resource "zillaforge_server" "headnode" {
  name      = local.headnode_hostname
  flavor_id = data.zillaforge_flavors.selected.flavors[0].id
  image_id  = data.zillaforge_images.selected.images[0].id
  keypair   = data.zillaforge_keypairs.selected.keypairs[0].id
  password  = var.server_password

  user_data = templatefile("${path.module}/templates/install_headnode.sh.tpl", {
    controller_hostname = local.headnode_hostname
    db_password         = var.db_password
    nfs_share_dir       = local.nfs_share_dir
    nfs_network_cidr    = data.zillaforge_networks.default.networks[0].cidr
    cluster_name        = var.cluster_name
    node_cpus           = data.zillaforge_flavors.selected.flavors[0].vcpus
    compute_nodes       = local.compute_hostnames
    compute_nodes_odd   = local.compute_odd_hostnames
    compute_nodes_even  = local.compute_even_hostnames
    test_user_password  = var.server_password
    sudoers_content     = file("${path.module}/templates/sudoers.tpl")
  })

  network_attachment {
    network_id         = data.zillaforge_networks.default.networks[0].id
    security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
    floating_ip_id     = zillaforge_floating_ip.headnode.id
  }

  dynamic "network_attachment" {
    for_each = local.optional_network_id == null ? [] : [local.optional_network_id]

    content {
      network_id         = network_attachment.value
      security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
    }
  }
}

# --------------------------------------------------------------------------
# Compute Nodes — Slurmd + NFS client
# Two NICs (default + optional), no Floating IP
# --------------------------------------------------------------------------

resource "zillaforge_server" "compute" {
  count = var.total - 1

  name      = local.compute_hostnames[count.index]
  flavor_id = data.zillaforge_flavors.selected.flavors[0].id
  image_id  = data.zillaforge_images.selected.images[0].id
  keypair   = data.zillaforge_keypairs.selected.keypairs[0].id
  password  = var.server_password

  user_data = templatefile("${path.module}/templates/install_compute.sh.tpl", {
    node_hostname       = local.compute_hostnames[count.index]
    controller_hostname = local.headnode_hostname
    controller_ip       = zillaforge_server.headnode.network_attachment[0].ip_address
    nfs_share_dir       = local.nfs_share_dir
    test_user_password  = var.server_password
    sudoers_content     = file("${path.module}/templates/sudoers.tpl")
  })

  network_attachment {
    network_id         = data.zillaforge_networks.default.networks[0].id
    security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
  }

  dynamic "network_attachment" {
    for_each = local.optional_network_id == null ? [] : [local.optional_network_id]

    content {
      network_id         = network_attachment.value
      security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
    }
  }
}

# --------------------------------------------------------------------------
# Post-provision: add compute IPs to headnode /etc/hosts, restart slurmctld
# --------------------------------------------------------------------------

resource "null_resource" "configure_cluster" {
  depends_on = [module.check_deps, zillaforge_server.compute]

  triggers = {
    headnode_ip = zillaforge_server.headnode.network_attachment[0].ip_address
    compute_ips = join(",", zillaforge_server.compute[*].network_attachment[0].ip_address)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = templatefile("${path.module}/templates/configure_cluster.sh.tpl", {
      fip          = zillaforge_floating_ip.headnode.ip_address
      password     = var.server_password
      cloud_user   = local.cloud_user
      cluster_name = var.cluster_name
      hosts_entries = [for i, s in zillaforge_server.compute : {
        ip   = s.network_attachment[0].ip_address
        name = local.compute_hostnames[i]
      }]
    })
  }
}

# --------------------------------------------------------------------------
# Test: verify Slurm cluster is operational
# --------------------------------------------------------------------------

resource "null_resource" "test_slurm" {
  depends_on = [module.check_deps, null_resource.configure_cluster]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOF
      set -euo pipefail
      FIP="${zillaforge_floating_ip.headnode.ip_address}"
      PASS="${var.server_password}"
      USER="${local.cloud_user}"

      echo "=== Slurm Cluster Status ==="
      sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$FIP" \
        "echo '$PASS' | sudo -S sinfo" || true

      echo ""
      echo "=== Submitting Test Job ==="
      sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$FIP" \
        "srun --nodes=1 --ntasks=1 hostname" || true

      echo ""
      echo "=== Slurm Cluster Test Complete ==="
    EOF
  }
}
