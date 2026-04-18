set -euo pipefail

FIP="${fip}"
PASS="${password}"
USER="${cloud_user}"

echo "=== Waiting for headnode SSH ==="
for i in $(seq 1 30); do
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$USER@$FIP" "echo ready" 2>/dev/null && break
  echo "  attempt $i ..."
  sleep 10
done

echo "=== Waiting for cloud-init to finish on headnode ==="
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$FIP" \
  "echo '$PASS' | sudo -S cloud-init status --wait 2>/dev/null || true"

echo "=== Adding compute node entries to headnode /etc/hosts ==="
%{ for entry in hosts_entries ~}
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$FIP" \
  "echo '$PASS' | sudo -S bash -c 'echo \"${entry.ip} ${entry.name}\" >> /etc/hosts'"
%{ endfor ~}

echo "=== Restarting slurmctld ==="
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$FIP" \
  "echo '$PASS' | sudo -S systemctl restart slurmctld"

echo "=== Waiting for compute nodes to register ==="
sleep 60

echo "=== Cluster Configuration Complete ==="
