#!/usr/bin/env bash
# Compact GitOps status: where each Argo CD Application syncs from, which
# revision it is at, and its sync/health state. Run on the control-plane VM:
#
#   multipass exec case-poc-cp -- sudo bash /repo/scripts/argocd-status.sh
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

for app in $(kubectl -n argocd get applications -o name); do
  kubectl -n argocd get "$app" -o jsonpath='{.metadata.name}{"\n  repo:     "}{.spec.source.repoURL}{"\n  target:   "}{.spec.source.targetRevision}{" -> "}{.status.sync.revision}{"\n  state:    "}{.status.sync.status}{" / "}{.status.health.status}{"\n"}'
done
