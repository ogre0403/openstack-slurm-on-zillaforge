set -euo pipefail

BASTION_FIP="${bastion_fip}"
HEADNODE_IP="${headnode_ip}"
HEADNODE_NAME="${headnode_name}"
PASS="${password}"
USER="${cloud_user}"
NFS_SHARE_DIR="${nfs_share_dir}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no"

echo "=== Waiting for bastion SSH ==="
for i in $(seq 1 30); do
  ssh-keygen -R "$BASTION_FIP" >/dev/null 2>&1 || true
  sshpass -p "$PASS" ssh $SSH_OPTS -o ConnectTimeout=5 "$USER@$BASTION_FIP" "echo ready" 2>/dev/null && break
  echo "  attempt $i ..."
  sleep 10
done

echo "=== Waiting for cloud-init to finish on bastion ==="
ssh-keygen -R "$BASTION_FIP" >/dev/null 2>&1 || true
sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "echo '$PASS' | sudo -S cloud-init status --wait 2>/dev/null || true"

echo "=== Waiting for headnode SSH (via bastion) ==="
for i in $(seq 1 30); do
  sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
    "sshpass -p '$PASS' ssh $SSH_OPTS -o ConnectTimeout=5 '$USER@$HEADNODE_IP' 'echo ready'" 2>/dev/null && break
  echo "  attempt $i ..."
  sleep 10
done

echo "=== Waiting for cloud-init to finish on headnode ==="
sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "sshpass -p '$PASS' ssh $SSH_OPTS '$USER@$HEADNODE_IP' \
    \"echo '$PASS' | sudo -S cloud-init status --wait 2>/dev/null || true\""

echo "=== Adding compute node entries to headnode /etc/hosts ==="
sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "sshpass -p '$PASS' ssh $SSH_OPTS '$USER@$HEADNODE_IP' \
    \"echo '$PASS' | sudo -S bash -c 'grep -q \\\"${headnode_ip} ${headnode_name}\\\" /etc/hosts || echo \\\"${headnode_ip} ${headnode_name}\\\" >> /etc/hosts'\""
%{ for entry in hosts_entries ~}
sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "sshpass -p '$PASS' ssh $SSH_OPTS '$USER@$HEADNODE_IP' \
    \"echo '$PASS' | sudo -S bash -c 'grep -q \\\"${entry.ip} ${entry.name}\\\" /etc/hosts || echo \\\"${entry.ip} ${entry.name}\\\" >> /etc/hosts'\""
%{ endfor ~}

echo "=== Configuring bastion for Slurm access ==="
sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "echo '$PASS' | sudo -S bash -c 'grep -q \"${headnode_ip} ${headnode_name}\" /etc/hosts || echo \"${headnode_ip} ${headnode_name}\" >> /etc/hosts'"
%{ for entry in hosts_entries ~}
sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "echo '$PASS' | sudo -S bash -c 'grep -q \"${entry.ip} ${entry.name}\" /etc/hosts || echo \"${entry.ip} ${entry.name}\" >> /etc/hosts'"
%{ endfor ~}

sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "echo '$PASS' | sudo -S mkdir -p '$NFS_SHARE_DIR' /etc/munge /etc/slurm /var/log/slurm /run/slurm"

sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "echo '$PASS' | sudo -S bash -c 'grep -q \"^${headnode_ip}:${nfs_share_dir} \" /etc/fstab || echo \"${headnode_ip}:${nfs_share_dir} ${nfs_share_dir} nfs defaults,_netdev 0 0\" >> /etc/fstab'"

sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" <<'EOF'
set -e
PASS='${password}'
echo "$PASS" | sudo -S mkdir -p /etc/munge /etc/slurm /var/log/slurm /run/slurm
# Allow SSH key authentication from NFS-mounted home directories (SELinux)
echo "$PASS" | sudo -S setsebool -P use_nfs_home_dirs 1 || true
if ! echo "$PASS" | sudo -S rpm -q munge slurm >/dev/null 2>&1; then
  echo "$PASS" | sudo -S dnf install -y epel-release
  OS_VER=$(echo "$PASS" | sudo -S rpm -E '%%{rhel}')
  if [ "$OS_VER" = "8" ]; then
    echo "$PASS" | sudo -S dnf config-manager --set-enabled powertools || true
  else
    echo "$PASS" | sudo -S dnf config-manager --set-enabled crb || true
  fi
  echo "$PASS" | sudo -S dnf install -y munge munge-libs munge-devel slurm nfs-utils curl --allowerasing
fi
echo "$PASS" | sudo -S bash -c "getent group slurm >/dev/null || groupadd -r slurm"
echo "$PASS" | sudo -S bash -c "getent passwd slurm >/dev/null || useradd -r -g slurm -s /bin/nologin -d /nonexistent slurm"
echo "$PASS" | sudo -S bash -c "getent group munge >/dev/null || groupadd -r munge"
echo "$PASS" | sudo -S bash -c "getent passwd munge >/dev/null || useradd -r -g munge -s /bin/nologin -d /nonexistent munge"
for i in $(seq 1 30); do
  echo "$PASS" | sudo -S mount -a && [ -f "${nfs_share_dir}/munge.key.sync" ] && [ -f "${nfs_share_dir}/slurm.conf.sync" ] && break
  echo "Waiting for Slurm NFS share on bastion... attempt $i"
  sleep 10
done
echo "$PASS" | sudo -S cp "${nfs_share_dir}/munge.key.sync" /etc/munge/munge.key
echo "$PASS" | sudo -S chown munge:munge /etc/munge/munge.key
echo "$PASS" | sudo -S chmod 400 /etc/munge/munge.key
echo "$PASS" | sudo -S systemctl enable --now munge
echo "$PASS" | sudo -S cp "${nfs_share_dir}/slurm.conf.sync" /etc/slurm/slurm.conf
if [ -f "${nfs_share_dir}/jwt_hs256.key.sync" ]; then
  echo "$PASS" | sudo -S cp "${nfs_share_dir}/jwt_hs256.key.sync" /etc/slurm/jwt_hs256.key
  echo "$PASS" | sudo -S chown slurm:slurm /etc/slurm/jwt_hs256.key
  echo "$PASS" | sudo -S chmod 600 /etc/slurm/jwt_hs256.key
fi
echo "$PASS" | sudo -S chown slurm:slurm /etc/slurm/slurm.conf
EOF

echo "=== Restarting slurmctld ==="
sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$BASTION_FIP" \
  "sshpass -p '$PASS' ssh $SSH_OPTS '$USER@$HEADNODE_IP' \
    \"echo '$PASS' | sudo -S systemctl restart slurmctld\""

echo "=== Waiting for compute nodes to register ==="
sleep 60

echo "=== Cluster Configuration Complete ==="
