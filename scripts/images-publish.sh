#!/usr/bin/env bash
#
# Builds both service images ON the control-plane VM (repo mounted at /repo,
# Dockerfiles are fully self-contained multi-stage builds) and pushes them
# into the internal Harbor there. The cluster's containerd pulls them through
# the registry mirror in /etc/rancher/k3s/registries.yaml:
#
#   chart image        harbor.case-poc.local/case-poc/<svc>:<tag>
#   mirror endpoint    http://<cp-ip>:18082  (host-network bridge -> Harbor)
#
# Run on the host (macOS terminal or Git Bash on Windows):
#
#   bash scripts/images-publish.sh [tag]        # default 2.0.0
#
# The actual work happens in scripts/images-publish-vm.sh on the VM
# (multipass exec on Windows loses quoting on multi-word `-c` arguments, so
# everything beyond a plain script invocation lives VM-side).
# scripts/images-import.sh remains the registry-less path for the plain-helm
# variants (measure/, validation harness), which keep local case-poc/* refs.
set -euo pipefail

TAG="${1:-2.0.0}"
CP_NAME="${CP_NAME:-case-poc-cp}"

mp() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' multipass "$@"; }

mp exec "$CP_NAME" -- sudo bash /repo/scripts/images-publish-vm.sh "$TAG"
