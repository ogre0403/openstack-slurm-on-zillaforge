#!/bin/bash
# kolla-push.sh
# Re-tag and push all kolla images from local Docker daemon to a private registry.
#
# Usage: kolla-push.sh <REGISTRY>
#   e.g.: kolla-push.sh localhost:4000
#
# The script finds all locally pulled kolla images (quay.io/openstack.kolla/*)
# and pushes them to the specified private registry.

set -euo pipefail

REGISTRY="${1:?Usage: $0 <REGISTRY>  (e.g. localhost:4000)}"

echo "=== Discovering kolla images ==="
IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^quay\.io/openstack\.kolla/' | sort -u)

if [ -z "$IMAGES" ]; then
    echo "No kolla images found. Run 'make kolla-pull' first."
    exit 1
fi

TOTAL=$(echo "$IMAGES" | wc -l)
echo "Found $TOTAL kolla image(s) to push."
echo ""

COUNT=0
FAILED=0
for IMAGE in $IMAGES; do
    COUNT=$((COUNT + 1))

    # quay.io/openstack.kolla/rocky-nova-api:2024.2 -> <REGISTRY>/openstack.kolla/rocky-nova-api:2024.2
    NAME_TAG="${IMAGE#quay.io/}"
    NEW_TAG="${REGISTRY}/${NAME_TAG}"

    echo "[$COUNT/$TOTAL] $IMAGE -> $NEW_TAG"

    if ! docker tag "$IMAGE" "$NEW_TAG"; then
        echo "  ERROR: failed to tag $IMAGE"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! docker push "$NEW_TAG"; then
        echo "  ERROR: failed to push $NEW_TAG"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Clean up local re-tagged image and original quay.io image to save space
    docker rmi "$NEW_TAG" > /dev/null 2>&1 || true
    docker rmi "$IMAGE" > /dev/null 2>&1 || true
done

echo ""
echo "=== Done: pushed $((COUNT - FAILED))/$TOTAL images to $REGISTRY ==="
if [ "$FAILED" -gt 0 ]; then
    echo "WARNING: $FAILED image(s) failed."
    exit 1
fi
