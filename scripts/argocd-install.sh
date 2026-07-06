#!/usr/bin/env bash
#
# Bootstraps the GitOps control plane on the k3s POC cluster:
#
#   1. kubectl apply -k deploy/argocd/install   (Argo CD v3.4.4, hardened,
#      namespace-scoped; plus the case-poc namespace and its RBAC)
#   2. applies the case-poc AppProject and the root app-of-apps Application
#
# After this, everything under deploy/argocd/apps/ is deployed and kept in
# sync from GitHub by Argo CD itself. Run inside WSL:
#
#   wsl -d Ubuntu -u root bash /windir/c/dev/bachelor-thesis/bachelor-thesis-artefact/scripts/argocd-install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "==> Applying Argo CD install kustomization (pinned v3.4.4)"
kubectl apply -k "$REPO_DIR/deploy/argocd/install"

echo "==> Waiting for Argo CD components"
kubectl -n argocd rollout status deployment argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment argocd-redis --timeout=300s
kubectl -n argocd rollout status deployment argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=300s

echo "==> Applying AppProject and root Application"
kubectl apply -f "$REPO_DIR/deploy/argocd/projects/case-poc.yaml"
kubectl apply -f "$REPO_DIR/deploy/argocd/root-app.yaml"

echo "==> Done."
echo "UI:        kubectl -n argocd port-forward svc/argocd-server 8443:443  ->  https://localhost:8443"
echo "Login:     admin / \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
