#!/bin/bash
# kolla-pull-additional.sh
# Pull additional kolla images that are not downloaded by 'kolla-ansible pull'.
# Currently handles: kolla-toolbox
#
# This script detects the tag from already-pulled kolla images and pulls
# the missing ones using the same tag.
#
# Usage: kolla-pull-additional.sh
#   (Run automatically after 'make kolla-pull')

set -euo pipefail

KOLLA_REGISTRY="quay.io/openstack.kolla"

ADDITIONAL_IMAGES=(
    "kolla-toolbox"
    "rocky-source-kolla-toolbox"
)

echo "=== Detecting tag from existing kolla images ==="
KOLLA_TAG=$(docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep "^${KOLLA_REGISTRY}/" \
    | head -n1 \
    | sed 's|.*:||')

if [ -z "$KOLLA_TAG" ]; then
    echo "ERROR: No existing kolla images found. Run 'make kolla-pull' first."
    exit 1
fi

echo "Detected kolla tag: ${KOLLA_TAG}"
echo ""

FAILED=0
SUCCESS=0
for NAME in "${ADDITIONAL_IMAGES[@]}"; do
    IMAGE="${KOLLA_REGISTRY}/${NAME}:${KOLLA_TAG}"
    echo "Pulling ${IMAGE} ..."
    if docker pull "${IMAGE}"; then
        echo "  OK: ${IMAGE}"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "  ERROR: failed to pull ${IMAGE}"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

if [ "$FAILED" -gt 0 ]; then
    echo "WARNING: $FAILED image(s) failed to pull."
fi

if [ "$SUCCESS" -eq 0 ]; then
    echo "ERROR: No images pulled successfully."
    exit 1
fi

echo "=== Done: all additional kolla images pulled successfully ==="
