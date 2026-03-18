#!/bin/bash
# Terraform external data source: verify required host commands exist.
# Runs during `terraform plan` so missing dependencies are caught before
# any resource is created — not deferred to NIC-discovery time.
set -e

# Consume stdin (Terraform always sends a JSON query object)
cat > /dev/null

for cmd in sshpass ssh rsync; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    >&2 echo "ERROR: '$cmd' is not installed. Please install it before running terraform plan/apply."
    exit 1
  fi
done

echo '{"ok":"true"}'
