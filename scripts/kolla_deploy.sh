#!/usr/bin/env bash
# Runs a full kolla-ansible deployment (kolla-up → post-deploy) on the OpenStack bastion.
# Designed to be launched in the background via nohup; progress is logged to kolla-deploy.log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG="$PROJECT_DIR/kolla-deploy.log"
KOLLA_EXEC="docker exec -u kolla -w /home/kolla -e HOME=/home/kolla kolla_ansible"
INPROGRESS_FILE="$PROJECT_DIR/.kolla_deploy.inprogress"
DONE_FILE="$PROJECT_DIR/.kolla_deploy.done"
# Whether to use the bastion's private Docker registry (set by make openstack-deploy)
ENABLE_PRIVATE_REGISTRY="${ENABLE_PRIVATE_REGISTRY:-false}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

cd "$PROJECT_DIR"

log "=============================================="
log " kolla-ansible full deployment starting"
log "=============================================="

# Exit early if deployment already completed
if [ -f "$DONE_FILE" ]; then
    log "Deployment flag found: $DONE_FILE — already completed. Exiting."
    exit 0
fi

# Mark deployment as in-progress
echo "Started at $(date '+%Y-%m-%d %H:%M:%S')" > "$INPROGRESS_FILE"
log "Created in-progress flag: $INPROGRESS_FILE"

log "--- Step 1/7: kolla-up (docker compose) ---"
make kolla-up 2>&1 | tee -a "$LOG"

log "--- Step 2/7: waiting for kolla_ansible container to be ready ---"
for i in $(seq 1 30); do
    if docker inspect -f '{{.State.Running}}' kolla_ansible 2>/dev/null | grep -q true; then
        log "Container kolla_ansible is running."
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "ERROR: kolla_ansible container did not start within 60 seconds."
        exit 1
    fi
    sleep 2
done


log "Waiting for /etc/kolla to become writable inside the container..."
for i in $(seq 1 30); do
    if $KOLLA_EXEC test -w /etc/kolla 2>/dev/null; then
        log "/etc/kolla is writable. Proceeding with kolla-genpwd..."
        break
    fi
    if [ "$i" -eq 30 ]; then
        log "ERROR: /etc/kolla is still not writable after 60 seconds. Check volume mount permissions."
        exit 1
    fi
    sleep 2
done

# ---- Private registry: pull images from public registry then push to bastion ----
if [ "$ENABLE_PRIVATE_REGISTRY" = "true" ]; then
    # LOCAL_IP=$(hostname -I | cut -d ' ' -f 1)
    # REGISTRY_ADDR="${LOCAL_IP}:5000"
    log "--- Step 2a/7: private registry enabled — kolla-ansible pull (public registry) ---"
    make kolla-pull 2>&1 | tee -a "$LOG"

    log "--- Step 2b/7: private registry enabled — pushing images ---"
    make kolla-push 2>&1 | tee -a "$LOG"
    log "Images pushed to private registry. Subsequent deploy steps will use it."
fi
# ---------------------------------------------------------------------------------

log "--- Step 3/7: kolla-genpwd ---"
$KOLLA_EXEC kolla-genpwd 2>&1 | tee -a "$LOG"

log "--- Step 4/7: bootstrap-servers ---"
$KOLLA_EXEC kolla-ansible bootstrap-servers -i /etc/kolla/inventroy/ 2>&1 | tee -a "$LOG"

log "--- Step 5/7: prechecks ---"
$KOLLA_EXEC kolla-ansible prechecks -i /etc/kolla/inventroy/ 2>&1 | tee -a "$LOG"

log "--- Step 6/7: pull ---"
$KOLLA_EXEC kolla-ansible pull -i /etc/kolla/inventroy/ 2>&1 | tee -a "$LOG"

log "--- Step 7/7: deploy ---"
$KOLLA_EXEC kolla-ansible deploy -i /etc/kolla/inventroy/ 2>&1 | tee -a "$LOG"

log "--- Step 7/7 (post): post-deploy ---"
$KOLLA_EXEC kolla-ansible post-deploy -i /etc/kolla/inventroy/ 2>&1 | tee -a "$LOG"

log "=============================================="
log " OpenStack deployment completed successfully!"
log "=============================================="

# rename in-progress flag to done
mv "$INPROGRESS_FILE" "$DONE_FILE"
echo "Completed at $(date '+%Y-%m-%d %H:%M:%S')" >> "$DONE_FILE"
log "Renamed in-progress flag to: $DONE_FILE"
