#!/usr/bin/env bash
#
# Generates the runtime credentials of the case-poc chart as Kubernetes
# Secrets (REQ-G-005: no secret material in git — the chart only references
# these names, see deploy/helm/anonymous-case-poc/values.yaml `secrets:`).
#
# Idempotent by design: existing secrets are left untouched, because the
# PostgreSQL volume is initialized with the first-run passwords and the
# running pods hold the current broker credentials.
#
# Run inside the control-plane VM as root (called by scripts/argocd-install.sh):
#
#   multipass exec case-poc-cp -- sudo bash /repo/scripts/secrets-bootstrap.sh [namespace]
#
# EXTERNAL_INFRA=1: the GitOps variant uses the compose PostgreSQL on the
# control-plane VM (postgres.enabled=false in the Application) — its
# per-service passwords are the fixed dev fixtures of
# infra/postgres/init/01-schemas-users.sql, so the db Secret must carry those
# instead of generated ones. Dev fixtures of the local PoC infra, not
# production secrets (same disposition as the compose file itself).
set -euo pipefail

NS="${1:-case-poc}"
EXTERNAL_INFRA="${EXTERNAL_INFRA:-0}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# hex output: safe to single-quote in SQL/property contexts.
rand() { openssl rand -hex 16; }

ensure_secret() {
  local name="$1"; shift
  if kubectl -n "$NS" get secret "$name" >/dev/null 2>&1; then
    echo "==> Secret $NS/$name already exists; keeping it"
    return 0
  fi
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl -n "$NS" create secret generic "$name" "${args[@]}"
}

ensure_secret case-poc-artemis-auth \
  "ARTEMIS_USER=artemis" \
  "ARTEMIS_PASSWORD=$(rand)"

if [ "$EXTERNAL_INFRA" = "1" ]; then
  ensure_secret case-poc-db-auth \
    "POSTGRES_PASSWORD=postgres" \
    "SUBMISSION_DB_PASSWORD=submission_service" \
    "MANAGEMENT_DB_PASSWORD=management_service"
else
  ensure_secret case-poc-db-auth \
    "POSTGRES_PASSWORD=$(rand)" \
    "SUBMISSION_DB_PASSWORD=$(rand)" \
    "MANAGEMENT_DB_PASSWORD=$(rand)"
fi

ensure_secret case-poc-keycloak-admin \
  "KC_BOOTSTRAP_ADMIN_USERNAME=admin" \
  "KC_BOOTSTRAP_ADMIN_PASSWORD=$(rand)"

echo "==> Secrets present in namespace $NS:"
kubectl -n "$NS" get secrets case-poc-artemis-auth case-poc-db-auth case-poc-keycloak-admin
