#!/usr/bin/env bash
# VM-side half of scripts/images-publish.sh: builds both service images on
# the control-plane VM's docker (repo mounted at /repo, Dockerfiles are
# self-contained multi-stage builds) and pushes them into the internal
# Harbor. Run as root on the control-plane VM.
set -euo pipefail

TAG="${1:-2.0.0}"
ENV_FILE="${ENV_FILE:-/opt/case-poc/infra.env}"
# shellcheck disable=SC1090
. "$ENV_FILE"

# The Dockerfiles use RUN --mount=type=cache (BuildKit); docker.io ships the
# legacy builder unless the buildx plugin drives the build.
export DOCKER_BUILDKIT=1

echo "==> docker login (Harbor, loopback = implicitly insecure registry)"
docker login 127.0.0.1:8082 -u admin --password-stdin <<<"$HARBOR_ADMIN_PASSWORD"

for svc in submission-service management-service; do
  echo "==> Building case-poc/$svc:$TAG"
  docker build -t "127.0.0.1:8082/case-poc/$svc:$TAG" "/repo/$svc"
  echo "==> Pushing to Harbor"
  docker push "127.0.0.1:8082/case-poc/$svc:$TAG"
done

echo "==> Repositories in Harbor project case-poc:"
curl -sf -u "admin:$HARBOR_ADMIN_PASSWORD" \
  http://127.0.0.1:8082/api/v2.0/projects/case-poc/repositories | jq -r '.[].name'
