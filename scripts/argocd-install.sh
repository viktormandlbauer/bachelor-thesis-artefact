#!/usr/bin/env bash
#
# Bootstraps the GitOps control plane on the k3s POC cluster:
#
#   1. kubectl apply -k deploy/argocd/install   (Argo CD v3.4.4, hardened,
#      namespace-scoped; plus the case-poc namespace and its RBAC)
#   2. applies the case-poc AppProject and the root app-of-apps Application
#
# After this, everything under deploy/argocd/apps/ is deployed and kept in
# sync from GitHub by Argo CD itself. Run inside the control-plane VM (the
# repo is mounted at /repo by scripts/vm-up.sh):
#
#   multipass exec case-poc-cp -- sudo bash /repo/scripts/argocd-install.sh
#
# Re-run after the VM IP changed: the signoz-collector EndpointSlice below
# carries the control-plane node IP.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "==> Applying Argo CD install kustomization (pinned v3.4.4)"
# Server-side apply: the ApplicationSet CRD exceeds the 256KiB annotation limit
# of client-side apply. --force-conflicts keeps re-runs idempotent.
kubectl apply --server-side --force-conflicts -k "$REPO_DIR/deploy/argocd/install"

echo "==> Waiting for Argo CD components"
kubectl -n argocd rollout status deployment argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deployment argocd-redis --timeout=300s
kubectl -n argocd rollout status deployment argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=300s

echo "==> Generating runtime secrets for the app namespace (REQ-G-005)"
# EXTERNAL_INFRA=1: this GitOps environment uses the compose PostgreSQL on
# the control-plane VM, so the db Secret carries its fixture credentials.
EXTERNAL_INFRA=1 bash "$REPO_DIR/scripts/secrets-bootstrap.sh" case-poc

# The supporting infra (SigNoz collector, PostgreSQL, Keycloak, GitLab) runs
# as compose on the control-plane VM (provisioned by deploy/vm/ansible/
# site.yml). Cluster pods cannot reach docker-published ports via the node IP
# (the k3s FORWARD path drops the DNAT to the docker bridge), so host-network
# bridges relay node-IP ports into the compose services
# (infra/cp-bridges.compose.yaml). Publish them as selector-less Services /
# EndpointSlices so pods address them by stable names. Like the Secrets, this
# is runtime state (the node IP), never synced from git.
NODE_IP="$(kubectl get node -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"

echo "==> Publishing the control-plane SigNoz collector as Service case-poc/signoz-collector"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: signoz-collector
  namespace: case-poc
spec:
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 14317
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: signoz-collector-1
  namespace: case-poc
  labels:
    kubernetes.io/service-name: signoz-collector
addressType: IPv4
ports:
  - name: otlp-grpc
    port: 14317
    protocol: TCP
endpoints:
  - addresses: ["$NODE_IP"]
EOF

# The -postgres / -keycloak Services themselves are rendered (selector-less)
# by the chart with postgres.enabled=false / keycloak.enabled=false — only
# their EndpointSlices carry runtime state and are applied here. Port names
# must match the Service port names (postgres / http).
echo "==> Publishing EndpointSlices for the compose PostgreSQL + Keycloak"
kubectl apply -f - <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: case-poc-anonymous-case-poc-postgres-ext-1
  namespace: case-poc
  labels:
    kubernetes.io/service-name: case-poc-anonymous-case-poc-postgres
addressType: IPv4
ports:
  - name: postgres
    port: 15432
    protocol: TCP
endpoints:
  - addresses: ["$NODE_IP"]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: case-poc-anonymous-case-poc-keycloak-ext-1
  namespace: case-poc
  labels:
    kubernetes.io/service-name: case-poc-anonymous-case-poc-keycloak
addressType: IPv4
ports:
  - name: http
    port: 18180
    protocol: TCP
endpoints:
  - addresses: ["$NODE_IP"]
EOF

# The internal GitLab is the GitOps source: deploy/argocd/* reference it as
# http://gitlab.argocd.svc.cluster.local/root/bachelor-thesis-artefact.git.
echo "==> Publishing the control-plane GitLab as Service argocd/gitlab"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: gitlab
  namespace: argocd
spec:
  ports:
    - name: http
      port: 80
      targetPort: 18929
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: gitlab-1
  namespace: argocd
  labels:
    kubernetes.io/service-name: gitlab
addressType: IPv4
ports:
  - name: http
    port: 18929
    protocol: TCP
endpoints:
  - addresses: ["$NODE_IP"]
EOF

echo "==> Applying AppProject and root Application"
kubectl apply -f "$REPO_DIR/deploy/argocd/projects/case-poc.yaml"
kubectl apply -f "$REPO_DIR/deploy/argocd/root-app.yaml"

echo "==> Done."
echo "UI:        kubectl -n argocd port-forward svc/argocd-server 8443:443  ->  https://localhost:8443"
echo "Login:     admin / \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
