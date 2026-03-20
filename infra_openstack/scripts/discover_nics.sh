#!/bin/bash
set -e

# Terraform external data source protocol:
#   Read JSON query from stdin, write JSON result to stdout.
#   All output on stderr is shown to the user as diagnostics.
#
# This script SSHs into the bastion host and discovers which NIC name
# is assigned to the default network IP and the optional network IP.

INPUT=$(cat)

HOST=$(echo "$INPUT" | grep -o '"host":"[^"]*"' | cut -d'"' -f4)
USER=$(echo "$INPUT" | grep -o '"user":"[^"]*"' | cut -d'"' -f4)
PASSWORD=$(echo "$INPUT" | grep -o '"password":"[^"]*"' | cut -d'"' -f4)
DEFAULT_IP=$(echo "$INPUT" | grep -o '"default_ip":"[^"]*"' | cut -d'"' -f4)
OPTIONAL_IP=$(echo "$INPUT" | grep -o '"optional_ip":"[^"]*"' | cut -d'"' -f4)

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

# Wait for bastion SSH to become available
for i in $(seq 1 30); do
  if sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$HOST" 'echo ready' >/dev/null 2>&1; then
    break
  fi
  >&2 echo "Waiting for bastion SSH ($i/30)..."
  sleep 10
done

# Discover NIC name for default network (match bastion's assigned IP)
NETWORK_INTERFACE=$(sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$HOST" \
  "ip -o -4 addr show | awk '\$4 ~ /^${DEFAULT_IP}\// {print \$2}'" 2>/dev/null | head -1)

# Discover NIC name for optional/tunnel network (only if an optional IP was provided)
TUNNEL_INTERFACE=""
if [ -n "$OPTIONAL_IP" ]; then
  TUNNEL_INTERFACE=$(sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER@$HOST" \
    "ip -o -4 addr show | awk '\$4 ~ /^${OPTIONAL_IP}\// {print \$2}'" 2>/dev/null | head -1)
fi

# Return JSON to Terraform
echo "{\"network_interface\":\"${NETWORK_INTERFACE}\",\"tunnel_interface\":\"${TUNNEL_INTERFACE}\"}"
