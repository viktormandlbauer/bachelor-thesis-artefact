#!/usr/bin/env bash
#
# Builds both service images with Docker on the host and imports them into
# the multipass VM's k3s containerd (no registry involved - the chart pins
# the tags with imagePullPolicy: IfNotPresent).
#
# Run on the host (macOS terminal or Git Bash on Windows; Docker running):
#
#   bash scripts/images-import.sh [tag]
set -euo pipefail

TAG="${1:-2.0.0}"
VM_NAME="${VM_NAME:-case-poc}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Git Bash rewrites arguments that look like POSIX paths before they reach the
# native multipass.exe; VM-side paths (/tmp/...) must stay untouched, while
# host-side paths must be converted explicitly (host_path).
mp() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' multipass "$@"; }
host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

for svc in submission-service management-service; do
  echo "==> Building case-poc/$svc:$TAG"
  docker build -t "case-poc/$svc:$TAG" "$REPO_DIR/$svc"
  echo "==> Exporting and importing into k3s containerd"
  docker save -o "$TMP/$svc.tar" "case-poc/$svc:$TAG"
  mp transfer "$(host_path "$TMP/$svc.tar")" "$VM_NAME:/tmp/$svc.tar"
  mp exec "$VM_NAME" -- sudo k3s ctr images import "/tmp/$svc.tar"
  mp exec "$VM_NAME" -- rm -f "/tmp/$svc.tar"
done

echo "==> Images in the cluster:"
mp exec "$VM_NAME" -- sudo k3s crictl images | grep case-poc
