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
# Run inside the multipass VM as root (called by scripts/argocd-install.sh):
#
#   multipass exec case-poc -- sudo bash /repo/scripts/secrets-bootstrap.sh [namespace]
set -euo pipefail

NS="${1:-case-poc}"
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

ensure_secret case-poc-db-auth \
  "POSTGRES_PASSWORD=$(rand)" \
  "SUBMISSION_DB_PASSWORD=$(rand)" \
  "MANAGEMENT_DB_PASSWORD=$(rand)"

ensure_secret case-poc-keycloak-admin \
  "KC_BOOTSTRAP_ADMIN_USERNAME=admin" \
  "KC_BOOTSTRAP_ADMIN_PASSWORD=$(rand)"

echo "==> Secrets present in namespace $NS:"
kubectl -n "$NS" get secrets case-poc-artemis-auth case-poc-db-auth case-poc-keycloak-admin
