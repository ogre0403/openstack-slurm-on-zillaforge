# --------------------------------------------------------------------------
# Bastion VM — single NIC on default network, with Floating IP
# --------------------------------------------------------------------------

resource "zillaforge_floating_ip" "bastion" {
  name = format("%s-bastion-tf-fip", var.node_name_prefix)
}

resource "zillaforge_server" "bastion" {
  name      = format("%s-00-bastion-tf", var.node_name_prefix)
  flavor_id = data.zillaforge_flavors.selected.flavors[0].id
  image_id  = data.zillaforge_images.selected.images[0].id
  keypair   = data.zillaforge_keypairs.selected.keypairs[0].id
  password  = var.server_password

  user_data = <<-EOF
#!/bin/bash
hostnamectl set-hostname "${format("%s-00-bastion-tf", var.node_name_prefix)}"
PASS="${var.server_password}"

# Install Docker
echo "$PASS" | sudo -S dnf remove -y docker \
                  docker-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-engine \
                  podman \
                  runc || true
echo "$PASS" | sudo -S dnf -y install dnf-plugins-core
echo "$PASS" | sudo -S dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
echo "$PASS" | sudo -S dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
echo "$PASS" | sudo -S systemctl enable --now docker
echo "$PASS" | sudo -S sudo groupadd docker
echo "$PASS" | sudo -S usermod -aG docker ${local.cloud_user}

# Generate SSH keypair for ${local.cloud_user} (skip if already exists)
CLOUD_USER_HOME=$(getent passwd ${local.cloud_user} | cut -d: -f6)
echo "$PASS" | sudo -S -u ${local.cloud_user} bash -c "[ -f $CLOUD_USER_HOME/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f $CLOUD_USER_HOME/.ssh/id_rsa -q"

# Install sshpass to allow password-based ssh-copy-id
echo "$PASS" | sudo -S dnf install -y sshpass make tmux vim

# Copy SSH public key to all nodes (retry up to 10 times per node to wait for boot)
%{for ip in [for s in zillaforge_server.nodes : s.network_attachment[0].ip_address]~}
for i in $(seq 1 10); do
  echo "$PASS" | sudo -S -u ${local.cloud_user} sshpass -p "$PASS" ssh-copy-id -o StrictHostKeyChecking=no ${local.cloud_user}@${ip} && break
  sleep 15
done
%{endfor~}

# Install and configure NFS server
echo "$PASS" | sudo -S dnf install -y nfs-utils
echo "$PASS" | sudo -S mkdir -p /kolla_nfs
echo "$PASS" | sudo -S chown nobody:nobody /kolla_nfs
echo "$PASS" | sudo -S chmod 777 /kolla_nfs
echo "$PASS" | sudo -S bash -c 'echo "/kolla_nfs ${data.zillaforge_networks.default.networks[0].cidr}(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports'
echo "$PASS" | sudo -S systemctl enable --now nfs-server
EOF

  network_attachment {
    network_id         = data.zillaforge_networks.default.networks[0].id
    security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
    floating_ip_id     = zillaforge_floating_ip.bastion.id
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
# Configure Docker insecure registry on bastion after creation
# (cannot be done in user_data because the bastion IP is only known after creation)
# --------------------------------------------------------------------------

resource "null_resource" "bastion_docker_daemon" {
  depends_on = [zillaforge_server.bastion]

  connection {
    type     = "ssh"
    host     = zillaforge_floating_ip.bastion.ip_address
    user     = local.cloud_user
    password = var.server_password
  }

  provisioner "remote-exec" {
    inline = [
      "PASS='${var.server_password}'",
      # Wait for user_data to finish installing and starting Docker
      "while ! echo \"$PASS\" | sudo -S systemctl is-active --quiet docker 2>/dev/null; do sleep 5; done",
      "echo \"$PASS\" | sudo -S mkdir -p /etc/docker",
      "echo '{\"insecure-registries\":[\"${zillaforge_server.bastion.network_attachment[0].ip_address}:5000\"]}' | sudo -S tee /etc/docker/daemon.json",
      "echo \"$PASS\" | sudo -S systemctl restart docker",
    ]
  }
}

# --------------------------------------------------------------------------
# Worker VMs — two NICs, no Floating IP, count driven by var.total
# --------------------------------------------------------------------------
# Controller Floating IP (optional — only when enable_controller_fip = true)
# --------------------------------------------------------------------------

resource "zillaforge_floating_ip" "controller" {
  count = var.enable_controller_fip ? 1 : 0
  name  = format("%s-controller-tf-fip", var.node_name_prefix)
}

# --------------------------------------------------------------------------

resource "zillaforge_server" "nodes" {
  count = var.total

  name      = count.index == 0 ? format("%s-01-control-tf", var.node_name_prefix) : format("%s-%02d-compute-tf", var.node_name_prefix, count.index + 1)
  flavor_id = data.zillaforge_flavors.selected.flavors[0].id
  image_id  = data.zillaforge_images.selected.images[0].id
  keypair   = data.zillaforge_keypairs.selected.keypairs[0].id
  password  = var.server_password

  user_data = <<-USERDATA
#!/bin/bash
hostnamectl set-hostname "${count.index == 0 ? format("%s-01-control-tf", var.node_name_prefix) : format("%s-%02d-compute-tf", var.node_name_prefix, count.index + 1)}"
USERDATA

  network_attachment {
    network_id         = data.zillaforge_networks.default.networks[0].id
    security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
    floating_ip_id     = (count.index == 0 && var.enable_controller_fip) ? zillaforge_floating_ip.controller[0].id : null
  }

  dynamic "network_attachment" {
    for_each = local.optional_network_id == null ? [] : [local.optional_network_id]

    content {
      network_id         = network_attachment.value
      security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
    }
  }
}
