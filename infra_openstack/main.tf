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

  user_data = <<-EOF
#!/bin/bash
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

# Generate SSH keypair for cloud-user (skip if already exists)
CLOUD_USER_HOME=$(getent passwd cloud-user | cut -d: -f6)
echo "$PASS" | sudo -S -u cloud-user bash -c "[ -f $CLOUD_USER_HOME/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f $CLOUD_USER_HOME/.ssh/id_rsa -q"

# Install sshpass to allow password-based ssh-copy-id
echo "$PASS" | sudo -S dnf install -y sshpass

# Copy SSH public key to all nodes (retry up to 10 times per node to wait for boot)
%{ for ip in [for s in zillaforge_server.nodes : s.network_attachment[0].ip_address] ~}
for i in $(seq 1 10); do
  echo "$PASS" | sudo -S -u cloud-user sshpass -p "$PASS" ssh-copy-id -o StrictHostKeyChecking=no cloud-user@${ip} && break
  sleep 15
done
%{ endfor ~}

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
  description = "Bastion 的 Floating IP"
  value       = zillaforge_floating_ip.bastion.ip_address
}

output "bastion_default_network_ip" {
  description = "Bastion 在 default network 上的 IP"
  value       = zillaforge_server.bastion.network_attachment[0].ip_address
}

output "nodes_default_network_ips" {
  description = "所有 nodes 在 default network 上的 IP"
  value       = { for s in zillaforge_server.nodes : s.name => s.network_attachment[0].ip_address }
}
