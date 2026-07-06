#!/usr/bin/env bash
#
# Installs a CIS-hardened single-node k3s server (pinned version) inside the
# WSL2 Ubuntu distro. Run as root INSIDE WSL from the repo checkout:
#
#   wsl -d Ubuntu -u root bash /windir/c/dev/bachelor-thesis/bachelor-thesis-artefact/scripts/k3s-install.sh
#
# Idempotent: re-running refreshes config files and restarts k3s.
# Uninstall with /usr/local/bin/k3s-uninstall.sh (created by the installer).
set -euo pipefail

K3S_VERSION="v1.36.2+k3s1"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K3S_CFG_SRC="$REPO_DIR/deploy/cluster/k3s"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (wsl -u root)"; exit 1; }

echo "==> Installing prerequisites (curl, jq, git - jq/git are needed by kube-bench audits and kustomize)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl jq git >/dev/null

echo "==> Applying kubelet kernel parameters (protect-kernel-defaults)"
install -m 0644 "$K3S_CFG_SRC/90-kubelet-sysctl.conf" /etc/sysctl.d/90-kubelet.conf
sysctl --system >/dev/null

echo "==> Installing k3s config (CIS hardening)"
mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/server/logs
install -m 0600 "$K3S_CFG_SRC/config.yaml"           /etc/rancher/k3s/config.yaml
install -m 0600 "$K3S_CFG_SRC/admission-config.yaml" /var/lib/rancher/k3s/server/admission-config.yaml
install -m 0600 "$K3S_CFG_SRC/audit-policy.yaml"     /var/lib/rancher/k3s/server/audit-policy.yaml

if command -v k3s >/dev/null 2>&1 && [ "$(k3s --version | head -1 | awk '{print $3}')" = "$K3S_VERSION" ]; then
  echo "==> k3s $K3S_VERSION already installed; restarting to pick up config"
  systemctl restart k3s
else
  echo "==> Installing k3s $K3S_VERSION"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
fi

echo "==> Waiting for node Ready"
k3s kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> Post-install file hardening (CIS 1.1.x / 4.1.x file permissions)"
# k3s creates some certificates world-readable; the CIS file-permission checks
# expect 600. k3s preserves permissions of existing files across restarts.
find /var/lib/rancher/k3s -type f \( -name '*.crt' -o -name '*.key' -o -name '*.kubeconfig' \) -exec chmod 600 {} +
chmod 600 /etc/rancher/k3s/k3s.yaml
# CNI config (CIS 1.1.9/1.1.10)
find /var/lib/rancher/k3s/agent/etc/cni -type f -exec chmod 600 {} + 2>/dev/null || true

echo "==> Hardening default service accounts (CIS 5.1.5)"
# Every namespace except kube-system must have automountServiceAccountToken: false
# on its default ServiceAccount. Namespaces created later via GitOps carry their
# own hardened default SA in the manifests.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for ns in $(k3s kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  [ "$ns" = "kube-system" ] && continue
  k3s kubectl -n "$ns" patch serviceaccount default \
    -p '{"automountServiceAccountToken": false}' >/dev/null || true
done

echo "==> Done. Cluster info:"
k3s kubectl get node -o wide
echo
echo "Kubeconfig (inside WSL): /etc/rancher/k3s/k3s.yaml"
echo "From Windows: copy it and replace 127.0.0.1 only if WSL localhost forwarding is disabled."
