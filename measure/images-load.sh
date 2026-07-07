#!/usr/bin/env bash
#
# Stages every image on every platform BEFORE any timing starts, so image
# pull/build latency never contaminates lifecycle or startup measurements
# (protocol §5.1 "image pull latency" confound control):
#
#   * builds the two service images (2.0.0) with host Docker,
#   * loads them into the case-engines VM's docker AND podman stores,
#   * pre-pulls the infra images (artemis/postgres/keycloak) once in the
#     VM's docker and copies them into podman via save|load,
#   * retags 2.0.1 (same bits — upgrades measure lifecycle mechanics, not
#     image content) in docker, podman, and the k3s VM's containerd.
#
#   bash measure/images-load.sh
#
# The k3s VM must already have the 2.0.0 images (scripts/images-import.sh).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

TAG="${TAG:-2.0.0}"
UPGRADE_TAG="${UPGRADE_TAG:-2.0.1}"
INFRA_IMAGES=(apache/activemq-artemis:2.44.0 postgres:17-alpine quay.io/keycloak/keycloak:26.3)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ensure_only_vm "$ENGINES_VM"

say "Building service images on the host (docker)"
for svc in submission-service management-service; do
  docker build -t "case-poc/$svc:$TAG" "$REPO_DIR/$svc"
  docker save -o "$TMP/$svc.tar" "case-poc/$svc:$TAG"
  mp transfer "$(host_path "$TMP/$svc.tar")" "$ENGINES_VM:/tmp/$svc.tar"
done

# multipass exec does not quote arguments — pipe scripts via stdin (bash -s)
say "Loading service images into docker and podman (case-engines)"
for svc in submission-service management-service; do
  mp exec "$ENGINES_VM" -- sudo bash -s <<EOF
set -e
docker load -i /tmp/$svc.tar
podman load -i /tmp/$svc.tar
docker tag case-poc/$svc:$TAG case-poc/$svc:$UPGRADE_TAG
podman tag localhost/case-poc/$svc:$TAG localhost/case-poc/$svc:$UPGRADE_TAG
rm -f /tmp/$svc.tar
EOF
done

say "Pre-pulling infra images (docker) and copying into podman"
for img in "${INFRA_IMAGES[@]}"; do
  mp exec "$ENGINES_VM" -- sudo bash -s <<EOF
set -e
docker pull -q $img
docker save $img | podman load
EOF
done

say "Retagging $UPGRADE_TAG in the k3s VM containerd"
ensure_only_vm "$K3S_VM"
for svc in submission-service management-service; do
  mp exec "$K3S_VM" -- sudo bash -s <<EOF
set -e
ref=\$(k3s ctr images ls -q | grep 'case-poc/$svc:$TAG' | head -1)
[ -n "\$ref" ] || { echo 'image case-poc/$svc:$TAG not in containerd - run scripts/images-import.sh first' >&2; exit 1; }
k3s ctr images tag --force "\$ref" "\${ref%:$TAG}:$UPGRADE_TAG"
EOF
done

say "Done — all images staged on all three platforms"
