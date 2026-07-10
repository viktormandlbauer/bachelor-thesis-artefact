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
# The push targets 127.0.0.1:8082 (loopback = implicitly insecure for docker,
# so no daemon config is needed); Harbor stores it as case-poc/<svc>:<tag>,
# which is exactly what the mirror resolves.
#
# Run on the host (macOS terminal or Git Bash on Windows):
#
#   bash scripts/images-publish.sh [tag]        # default 2.0.0
#
# scripts/images-import.sh remains the registry-less path for the plain-helm
# variants (measure/, validation harness), which keep local case-poc/* refs.
set -euo pipefail

TAG="${1:-2.0.0}"
CP_NAME="${CP_NAME:-case-poc-cp}"

mp() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' multipass "$@"; }

echo "==> Logging in to Harbor on $CP_NAME"
mp exec "$CP_NAME" -- sudo bash -c \
  '. /opt/case-poc/infra.env && docker login 127.0.0.1:8082 -u admin --password-stdin <<<"$HARBOR_ADMIN_PASSWORD"'

for svc in submission-service management-service; do
  echo "==> Building case-poc/$svc:$TAG on $CP_NAME"
  mp exec "$CP_NAME" -- sudo docker build \
    -t "127.0.0.1:8082/case-poc/$svc:$TAG" "/repo/$svc"
  echo "==> Pushing to Harbor"
  mp exec "$CP_NAME" -- sudo docker push "127.0.0.1:8082/case-poc/$svc:$TAG"
done

echo "==> Repositories in Harbor project case-poc:"
mp exec "$CP_NAME" -- sudo bash -c \
  '. /opt/case-poc/infra.env && curl -sf -u "admin:$HARBOR_ADMIN_PASSWORD" \
     http://127.0.0.1:8082/api/v2.0/projects/case-poc/repositories | jq -r ".[].name"'
