# --------------------------------------------------------------------------
# Floating IPs
# --------------------------------------------------------------------------

# Bastion always gets a Floating IP
resource "zillaforge_floating_ip" "bastion" {
  name = format("%s-bastion-tf-fip", var.node_name_prefix)
}

# Controller Floating IP (optional — only when enable_controller_fip = true)
resource "zillaforge_floating_ip" "controller" {
  count = var.enable_controller_fip ? 1 : 0
  name  = format("%s-controller-tf-fip", var.node_name_prefix)
}

# --------------------------------------------------------------------------
# Bastion VM — Docker host, NFS server for kolla, SSH jump host
# Single NIC on default network, with Floating IP. NOT counted in var.total.
# --------------------------------------------------------------------------

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

# Install tools for password-based SSH operations only
echo "$PASS" | sudo -S dnf install -y sshpass make tmux vim

# Install and configure NFS server
echo "$PASS" | sudo -S dnf install -y nfs-utils
echo "$PASS" | sudo -S mkdir -p /kolla_nfs
echo "$PASS" | sudo -S chown nobody:nobody /kolla_nfs
echo "$PASS" | sudo -S chmod 777 /kolla_nfs
echo "$PASS" | sudo -S bash -c 'echo "/kolla_nfs ${data.zillaforge_networks.default.networks[0].cidr}(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports'
echo "$PASS" | sudo -S systemctl enable --now nfs-server

# Install Slurm client stack on bastion so it can submit jobs and call slurmrestd
echo "$PASS" | sudo -S dnf install -y epel-release
OS_VER=$(rpm -E '%%{rhel}')
if [ "$OS_VER" = "8" ]; then
  echo "$PASS" | sudo -S dnf config-manager --set-enabled powertools
else
  echo "$PASS" | sudo -S dnf config-manager --set-enabled crb
fi
echo "$PASS" | sudo -S dnf install -y munge munge-libs munge-devel slurm nfs-utils curl --allowerasing
echo "$PASS" | sudo -S bash -c "getent group slurm >/dev/null || groupadd -r slurm"
echo "$PASS" | sudo -S bash -c "getent passwd slurm >/dev/null || useradd -r -g slurm -s /bin/nologin -d /nonexistent slurm"
echo "$PASS" | sudo -S bash -c "getent group munge >/dev/null || groupadd -r munge"
echo "$PASS" | sudo -S bash -c "getent passwd munge >/dev/null || useradd -r -g munge -s /bin/nologin -d /nonexistent munge"
echo "$PASS" | sudo -S mkdir -p /etc/slurm ${local.nfs_share_dir} /var/log/slurm /run/slurm

# Prepare persistent NFS mount for the Slurm share exported by the headnode
HEADNODE_IP="${zillaforge_server.headnode.network_attachment[0].ip_address}"
if ! echo "$PASS" | sudo -S grep -q "^$HEADNODE_IP:${local.nfs_share_dir} " /etc/fstab; then
  echo "$PASS" | sudo -S bash -c 'echo "'$HEADNODE_IP':'${local.nfs_share_dir}' '${local.nfs_share_dir}' nfs defaults,_netdev 0 0" >> /etc/fstab'
fi
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
# Slurm Head Node — NFS server + DB + SlurmDBD + Slurmctld + slurmrestd
# Index 0 in the total count. Gets a Floating IP.
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
    compute_nodes       = local.worker_hostnames
    compute_nodes_odd   = local.worker_odd_hostnames
    compute_nodes_even  = local.worker_even_hostnames
    test_user_password  = var.server_password
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
# OpenStack Controller Node — index 1 in total count
# Runs cloud-init for OpenStack (dummy0 interface for neutron)
# --------------------------------------------------------------------------

resource "zillaforge_server" "controller" {
  name      = local.controller_hostname
  flavor_id = data.zillaforge_flavors.selected.flavors[0].id
  image_id  = data.zillaforge_images.selected.images[0].id
  keypair   = data.zillaforge_keypairs.selected.keypairs[0].id
  password  = var.server_password

  user_data = <<-USERDATA
#!/bin/bash
hostnamectl set-hostname "${local.controller_hostname}"

# Create dummy0 interface for neutron_external_interface
modprobe dummy
ip link add dummy0 type dummy
ip link set dummy0 up

# Persist dummy module and interface across reboots
echo "dummy" > /etc/modules-load.d/dummy.conf
nmcli connection add type dummy ifname dummy0 con-name dummy0 autoconnect yes
USERDATA

  network_attachment {
    network_id         = data.zillaforge_networks.default.networks[0].id
    security_group_ids = [data.zillaforge_security_groups.selected.security_groups[0].id]
    floating_ip_id     = var.enable_controller_fip ? zillaforge_floating_ip.controller[0].id : null
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
# OpenStack Compute / Slurm Worker Nodes — index 2..total-1
# These nodes run BOTH:
#   - Slurm compute (install_compute.sh.tpl cloud-init)
#   - OpenStack compute (dummy0 interface for neutron)
# The Slurm cloud-init already includes dummy0 setup, so no extra step needed.
# --------------------------------------------------------------------------

resource "zillaforge_server" "workers" {
  count = var.total - 2

  name      = local.worker_hostnames[count.index]
  flavor_id = data.zillaforge_flavors.selected.flavors[0].id
  image_id  = data.zillaforge_images.selected.images[0].id
  keypair   = data.zillaforge_keypairs.selected.keypairs[0].id
  password  = var.server_password

  user_data = templatefile("${path.module}/templates/install_compute.sh.tpl", {
    node_hostname       = local.worker_hostnames[count.index]
    controller_hostname = local.headnode_hostname
    controller_ip       = zillaforge_server.headnode.network_attachment[0].ip_address
    nfs_share_dir       = local.nfs_share_dir
    test_user_password  = var.server_password
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
  depends_on = [module.check_deps, zillaforge_server.workers]

  triggers = {
    headnode_ip = zillaforge_server.headnode.network_attachment[0].ip_address
    bastion_ip  = zillaforge_server.bastion.network_attachment[0].ip_address
    worker_ips  = join(",", zillaforge_server.workers[*].network_attachment[0].ip_address)
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = templatefile("${path.module}/templates/configure_cluster.sh.tpl", {
      bastion_fip   = zillaforge_floating_ip.bastion.ip_address
      headnode_ip   = zillaforge_server.headnode.network_attachment[0].ip_address
      headnode_name = local.headnode_hostname
      password      = var.server_password
      cloud_user    = local.cloud_user
      cluster_name  = var.cluster_name
      nfs_share_dir = local.nfs_share_dir
      hosts_entries = [for i, s in zillaforge_server.workers : {
        ip   = s.network_attachment[0].ip_address
        name = local.worker_hostnames[i]
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
      BASTION_FIP="${zillaforge_floating_ip.bastion.ip_address}"
      PASS="${var.server_password}"
      USER="${local.cloud_user}"
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no"

      echo "=== Slurm Cluster Status ==="
      sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
        "echo '$PASS' | sudo -S sinfo" || true

      echo ""
      echo "=== Submitting Test Job ==="
      sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
        "srun --nodes=1 --ntasks=1 hostname" || true

      echo ""
      echo "=== Slurm Cluster Test Complete ==="
    EOF
  }
}

# --------------------------------------------------------------------------
# Test: verify Slurm REST API (slurmrestd) is operational
# --------------------------------------------------------------------------

resource "null_resource" "test_slurm_api" {
  depends_on = [module.check_deps, null_resource.test_slurm]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOF
      set -euo pipefail
      BASTION_FIP="${zillaforge_floating_ip.bastion.ip_address}"
      HEADNODE_HOSTNAME="${local.headnode_hostname}"
      PASS="${var.server_password}"
      USER="${local.cloud_user}"
      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no"

      echo "=== Slurm REST API Test ==="

      echo ""
      echo "--- Step 1: Ping slurmrestd ---"
      TOKEN=$(sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
        "echo '$PASS' | sudo -S scontrol token username=$USER lifespan=3600 2>/dev/null | sed -n 's/^SLURM_JWT=//p'")
      if [ -z "$TOKEN" ]; then
        echo "ERROR: Failed to generate JWT token"
        exit 1
      fi
      echo "Token acquired: $${TOKEN:0:20}..."

      PING_RESULT=$(sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
        "curl -s http://$HEADNODE_HOSTNAME:6820/slurm/v0.0.38/ping \
          -H 'X-SLURM-USER-NAME: $USER' \
          -H 'X-SLURM-USER-TOKEN: $TOKEN'")
      echo "$PING_RESULT"

      echo ""
      echo "--- Step 2: Submit Job via REST API ---"
      sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
        "cat > /tmp/api_test_job.json << 'ENDJSON'
{
  \"script\": \"#!/bin/bash\nhostname\necho slurm-api-test-ok\",
  \"job\": {
    \"current_working_directory\": \"/tmp\",
    \"environment\": {
      \"PATH\": \"/bin:/usr/bin:/usr/local/bin\"
    }
  }
}
ENDJSON"

      JOB_SUBMIT_RESULT=$(sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
        "curl -s -X POST http://$HEADNODE_HOSTNAME:6820/slurm/v0.0.38/job/submit \
          -H 'Content-Type: application/json' \
          -H 'X-SLURM-USER-NAME: $USER' \
          -H 'X-SLURM-USER-TOKEN: $TOKEN' \
          -d @/tmp/api_test_job.json")
      echo "$JOB_SUBMIT_RESULT"

      JOB_ID=$(echo "$JOB_SUBMIT_RESULT" | sed -n 's/.*"job_id"\s*:\s*\([0-9]*\).*/\1/p' | head -1)
      if [ -z "$JOB_ID" ]; then
        echo "ERROR: Failed to submit job via REST API"
        echo "Response: $JOB_SUBMIT_RESULT"
        exit 1
      fi
      echo "Submitted job ID: $JOB_ID"

      echo ""
      echo "--- Step 3: Wait for job completion and verify with sacct ---"
      for i in $(seq 1 12); do
        STATE=$(sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
          "sacct -j $JOB_ID --noheader -o State%20 2>/dev/null | head -1 | xargs" || true)
        echo "  Job $JOB_ID state: $STATE (attempt $i)"
        if echo "$STATE" | grep -qiE "COMPLETED|FAILED|CANCELLED|TIMEOUT"; then
          break
        fi
        sleep 5
      done

      echo ""
      echo "--- Step 4: Show job details from sacct ---"
      sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
        "sacct -j $JOB_ID -o JobID,JobName%20,User%12,State%12,ExitCode,Start,End"

      echo ""
      if echo "$STATE" | grep -qi "COMPLETED"; then
        echo "=== Slurm REST API Test PASSED ==="
      else
        echo "=== Slurm REST API Test FAILED (job state: $STATE) ==="
        exit 1
      fi
    EOF
  }
}
