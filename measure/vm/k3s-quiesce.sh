#!/usr/bin/env bash
#
# Quiesce / restore the GitOps-managed application on the k3s PoC so that
# measurements run without the case-poc workload competing for resources
# (protocol §5.1: "no other user applications running").
#
#   sudo k3s-quiesce.sh quiesce   # Argo controller -> 0, case-poc deploys -> 0
#   sudo k3s-quiesce.sh restore   # controller -> 1 (self-heal re-syncs), deploys -> 1
#
# Order matters: the Argo CD application controller must stop first,
# otherwise auto-sync reverts the scale-down. Restore scales the
# deployments back explicitly, so it does not depend on self-heal being on.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ACTION="${1:?quiesce|restore}"

case "$ACTION" in
  quiesce)
    kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
    kubectl -n argocd wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller --timeout=120s 2>/dev/null || true
    kubectl -n case-poc scale deployment --all --replicas=0
    kubectl -n case-poc wait --for=delete pod --all --timeout=300s 2>/dev/null || true
    echo "quiesced: argocd controller=0, case-poc workload=0"
    ;;
  restore)
    kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
    kubectl -n case-poc scale deployment --all --replicas=1
    kubectl -n case-poc rollout status deployment --timeout=600s
    echo "restored: argocd controller=1, case-poc workload up"
    ;;
  *) echo "usage: $0 quiesce|restore" >&2; exit 2 ;;
esac
