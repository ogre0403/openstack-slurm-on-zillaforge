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

# --------------------------------------------------------------------------
# Test: verify Slurm REST API (slurmrestd) is operational
# --------------------------------------------------------------------------

resource "null_resource" "test_slurm_api" {
  depends_on = [module.check_deps, null_resource.test_slurm]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOF
      set -euo pipefail
      FIP="${zillaforge_floating_ip.headnode.ip_address}"
      PASS="${var.server_password}"
      USER="${local.cloud_user}"

      echo "=== Slurm REST API Test ==="

      echo ""
      echo "--- Step 1: Ping slurmrestd ---"
      # Generate a token (slurmrestd with jwt auth requires token for all endpoints)
      TOKEN=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$FIP" \
        "echo '$PASS' | sudo -S scontrol token username=$USER lifespan=3600 2>/dev/null | sed -n 's/^SLURM_JWT=//p'")
      if [ -z "$TOKEN" ]; then
        echo "ERROR: Failed to generate JWT token"
        exit 1
      fi
      echo "Token acquired: $${TOKEN:0:20}..."

      PING_RESULT=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$FIP" \
        "curl -s http://localhost:6820/slurm/v0.0.38/ping \
          -H 'X-SLURM-USER-NAME: $USER' \
          -H 'X-SLURM-USER-TOKEN: $TOKEN'")
      echo "$PING_RESULT"

      echo ""
      echo "--- Step 2: Submit Job via REST API ---"
      # Write JSON payload on remote host to avoid shell escaping issues
      sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$FIP" \
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

      JOB_SUBMIT_RESULT=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$FIP" \
        "curl -s -X POST http://localhost:6820/slurm/v0.0.38/job/submit \
          -H 'Content-Type: application/json' \
          -H 'X-SLURM-USER-NAME: $USER' \
          -H 'X-SLURM-USER-TOKEN: $TOKEN' \
          -d @/tmp/api_test_job.json")
      echo "$JOB_SUBMIT_RESULT"

      # Extract job_id from response using sed (Alpine BusyBox grep doesn't support -P)
      JOB_ID=$(echo "$JOB_SUBMIT_RESULT" | sed -n 's/.*"job_id"\s*:\s*\([0-9]*\).*/\1/p' | head -1)
      if [ -z "$JOB_ID" ]; then
        echo "ERROR: Failed to submit job via REST API"
        echo "Response: $JOB_SUBMIT_RESULT"
        exit 1
      fi
      echo "Submitted job ID: $JOB_ID"

      echo ""
      echo "--- Step 3: Wait for job completion and verify with sacct ---"
      # Wait for the job to finish (max 60s)
      for i in $(seq 1 12); do
        STATE=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$FIP" \
          "sacct -j $JOB_ID --noheader -o State%20 2>/dev/null | head -1 | xargs" || true)
        echo "  Job $JOB_ID state: $STATE (attempt $i)"
        if echo "$STATE" | grep -qiE "COMPLETED|FAILED|CANCELLED|TIMEOUT"; then
          break
        fi
        sleep 5
      done

      echo ""
      echo "--- Step 4: Show job details from sacct ---"
      sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$FIP" \
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
