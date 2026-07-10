#!/usr/bin/env bash
#
# Builds both service images with Docker on the host and imports them into
# the k3s containerd of EVERY cluster VM — the control plane and all workers
# (no registry involved - the chart pins the tags with imagePullPolicy:
# IfNotPresent, and the services may schedule on any node).
#
# Run on the host (macOS terminal or Git Bash on Windows; Docker running):
#
#   bash scripts/images-import.sh [tag]
set -euo pipefail

TAG="${1:-2.0.0}"
CP_NAME="${CP_NAME:-case-poc-cp}"
WORKER_PREFIX="${WORKER_PREFIX:-case-poc-w}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Git Bash rewrites arguments that look like POSIX paths before they reach the
# native multipass.exe; VM-side paths (/tmp/...) must stay untouched. The
# host-side tar is transferred from its directory as a bare filename: multipass
# parses anything before a colon as an instance name, so Windows drive-letter
# paths (C:/...) are rejected.
mp() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' multipass "$@"; }

# Control plane + every running worker VM (case-poc-w1, ...).
VMS="${VMS:-$(mp list --format csv | tr -d '\r' \
  | awk -F, -v cp="$CP_NAME" -v wp="$WORKER_PREFIX" \
      'NR>1 && $2=="Running" && ($1==cp || index($1,wp)==1) {print $1}')}"
[ -n "$VMS" ] || { echo "no running cluster VMs found (expected $CP_NAME / $WORKER_PREFIX*)"; exit 1; }
echo "==> Importing into: $(echo $VMS | tr '\n' ' ')"

for svc in submission-service management-service; do
  echo "==> Building case-poc/$svc:$TAG"
  docker build -t "case-poc/$svc:$TAG" "$REPO_DIR/$svc"
  echo "==> Exporting and importing into k3s containerd"
  docker save -o "$TMP/$svc.tar" "case-poc/$svc:$TAG"
  for vm in $VMS; do
    (cd "$TMP" && mp transfer "$svc.tar" "$vm:/tmp/$svc.tar")
    mp exec "$vm" -- sudo k3s ctr images import "/tmp/$svc.tar"
    mp exec "$vm" -- rm -f "/tmp/$svc.tar"
  done
done

echo "==> Images per node:"
for vm in $VMS; do
  echo "--- $vm"
  mp exec "$vm" -- sudo k3s crictl images | grep case-poc
done
