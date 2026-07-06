#!/usr/bin/env bash
#
# Runs kube-bench (pinned) against the local k3s node using the k3s-specific
# CIS profile and stores the report under docs/reports/.
#
# kube-bench runs directly on the node (not as a pod): the k3s-cis-1.9 profile
# audits systemd journal entries (journalctl -u k3s) and files under
# /var/lib/rancher, which are only reliably reachable from the host.
#
#   wsl -d Ubuntu -u root bash /windir/c/dev/bachelor-thesis/bachelor-thesis-artefact/scripts/kube-bench-run.sh
#
# Pass criterion: 0 checks in state FAIL. (WARN entries are the profile's
# "manual verification" items; see docs/k8s-poc.md for their disposition.)
set -euo pipefail

KUBE_BENCH_VERSION="0.15.6"
BENCHMARK="k3s-cis-1.9"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/kube-bench"
REPORT_DIR="$REPO_DIR/docs/reports"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (wsl -u root)"; exit 1; }

if [ ! -x "$INSTALL_DIR/kube-bench" ] || ! "$INSTALL_DIR/kube-bench" version | grep -q "$KUBE_BENCH_VERSION"; then
  echo "==> Downloading kube-bench $KUBE_BENCH_VERSION"
  mkdir -p "$INSTALL_DIR"
  curl -sfL "https://github.com/aquasecurity/kube-bench/releases/download/v${KUBE_BENCH_VERSION}/kube-bench_${KUBE_BENCH_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C "$INSTALL_DIR"
fi

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y-%m-%d)"
REPORT="$REPORT_DIR/kube-bench-$STAMP.txt"

echo "==> Running kube-bench --benchmark $BENCHMARK"
cd "$INSTALL_DIR"
./kube-bench run \
  --config-dir "$INSTALL_DIR/cfg" \
  --benchmark "$BENCHMARK" \
  --targets master,etcd,controlplane,node,policies \
  | tee "$REPORT"

echo
echo "==> Report saved to $REPORT"
if grep -E '^\[FAIL\]' "$REPORT" >/dev/null; then
  echo "==> RESULT: FAILING checks present:"
  grep -E '^\[FAIL\]' "$REPORT"
  exit 1
else
  echo "==> RESULT: no FAIL findings."
fi
