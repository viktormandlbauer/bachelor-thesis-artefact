#!/usr/bin/env bash
#
# Builds both service images with Docker Desktop and imports them into the
# k3s node's containerd (no registry involved - the chart pins the tags with
# imagePullPolicy: IfNotPresent).
#
# Run from Git Bash on the Windows host (Docker Desktop must be running):
#
#   bash scripts/images-import.sh [tag]
set -euo pipefail

TAG="${1:-1.0.0}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for svc in submission-service management-service; do
  echo "==> Building case-poc/$svc:$TAG"
  docker build -t "case-poc/$svc:$TAG" "$REPO_DIR/$svc"
  echo "==> Exporting and importing into k3s containerd"
  docker save -o "$TMP/$svc.tar" "case-poc/$svc:$TAG"
  # Translate the Git Bash tmp path to the WSL drvfs automount (root: /windir)
  # and stop MSYS from rewriting the Linux path on the way into wsl.exe.
  WIN_TAR="$(cygpath -m "$TMP/$svc.tar")"
  DRIVE="$(printf '%s' "${WIN_TAR:0:1}" | tr '[:upper:]' '[:lower:]')"
  WSL_TAR="/windir/$DRIVE/${WIN_TAR:3}"
  MSYS2_ARG_CONV_EXCL='*' wsl.exe -d Ubuntu -u root -- k3s ctr images import "$WSL_TAR"
done

echo "==> Images in the cluster:"
wsl.exe -d Ubuntu -u root -- k3s crictl images | grep case-poc
