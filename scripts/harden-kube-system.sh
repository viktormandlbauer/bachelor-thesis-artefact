#!/usr/bin/env bash
#
# Makes the k3s-bundled kube-system workloads (coredns, traefik,
# metrics-server, local-path-provisioner, svclb) compliant with CIS 5.1.6:
# no ServiceAccount token automounting anywhere.
#
# Rationale: the kube-bench k3s-cis-1.9 profile whitelists these components'
# ServiceAccounts, but with use_multiple_values kube-bench only passes a check
# if ONE of its test items holds for EVERY audited pod. As soon as any
# non-whitelisted workload pod exists (Argo CD, the app), the whitelist item
# can no longer cover all lines, so every pod - including the k3s bundled
# ones - must satisfy the automount conditions instead.
#
# Pattern (same as the Argo CD install): ServiceAccounts get
# automountServiceAccountToken: false, and deployments that genuinely need the
# Kubernetes API mount an explicitly projected, expiring token at the default
# path. Patches live in the cluster state; k3s's addon controller only
# re-applies its manifests when they change (i.e. on k3s upgrades), at which
# point this script must be re-run. Applied by deploy/vm/ansible/site.yml;
# to re-run by hand:
#
#   multipass exec case-poc-cp -- sudo bash /repo/scripts/harden-kube-system.sh
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

TOKEN_VOLUME='{
  "name": "sa-token",
  "projected": {
    "defaultMode": 292,
    "sources": [
      {"serviceAccountToken": {"expirationSeconds": 3607, "path": "token"}},
      {"configMap": {"name": "kube-root-ca.crt", "items": [{"key": "ca.crt", "path": "ca.crt"}]}},
      {"downwardAPI": {"items": [{"path": "namespace", "fieldRef": {"fieldPath": "metadata.namespace"}}]}}
    ]
  }
}'

patch_deployment() {
  local deploy="$1" container="$2"
  kubectl -n kube-system patch deployment "$deploy" --type strategic -p "{
    \"spec\": {\"template\": {\"spec\": {
      \"automountServiceAccountToken\": false,
      \"volumes\": [$TOKEN_VOLUME],
      \"containers\": [{
        \"name\": \"$container\",
        \"volumeMounts\": [{
          \"name\": \"sa-token\",
          \"mountPath\": \"/var/run/secrets/kubernetes.io/serviceaccount\",
          \"readOnly\": true
        }]
      }]
    }}}
  }"
}

echo "==> Disabling token automount on kube-system ServiceAccounts"
# helm-traefik/-crd run one-shot install jobs at cluster bring-up; with
# automount disabled a FUTURE job run (traefik chart upgrade on a k3s version
# bump) would fail - temporarily revert the SA patch for upgrades, then re-run
# this script.
for sa in coredns metrics-server local-path-provisioner-service-account svclb traefik helm-traefik helm-traefik-crd; do
  kubectl -n kube-system patch serviceaccount "$sa" \
    -p '{"automountServiceAccountToken": false}'
done

echo "==> Re-mounting explicit projected tokens on API-consuming deployments"
patch_deployment coredns coredns
patch_deployment metrics-server metrics-server
patch_deployment local-path-provisioner local-path-provisioner
patch_deployment traefik traefik

echo "==> Pruning Succeeded one-shot pods (deleting the Jobs would only make the helm controller recreate them)"
kubectl -n kube-system delete pod --field-selector=status.phase==Succeeded --ignore-not-found

echo "==> Waiting for rollouts"
for d in coredns metrics-server local-path-provisioner traefik; do
  kubectl -n kube-system rollout status deployment "$d" --timeout=180s
done

echo "==> kube-system hardening done"
