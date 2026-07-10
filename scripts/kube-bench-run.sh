#!/usr/bin/env bash
#
# Runs kube-bench (pinned) against the local k3s node using the k3s-specific
# CIS profile and stores the report under docs/reports/.
#
# kube-bench runs directly on the node (not as a pod): the k3s-cis-1.9 profile
# audits systemd journal entries (journalctl -u k3s) and files under
# /var/lib/rancher, which are only reliably reachable from the node. Run it
# inside a cluster VM (the repo is mounted at /repo by scripts/vm-up.sh;
# the report lands in docs/reports/ on the host through the mount):
#
#   multipass exec case-poc-cp -- sudo bash /repo/scripts/kube-bench-run.sh
#
# The control-plane run (all targets, incl. the node checks for its own
# kubelet) is the acceptance evidence. On a worker the script audits the
# node target only, best-effort: the k3s profile addresses the journal unit
# 'k3s', while agents log under 'k3s-agent' — the workers get the identical
# kubelet hardening from the same playbook either way.
#
# Pass criterion: 0 checks in state FAIL. (WARN entries are the profile's
# "manual verification" items; see docs/k8s-poc.md for their disposition.)
set -euo pipefail

KUBE_BENCH_VERSION="0.15.6"
BENCHMARK="k3s-cis-1.9"

if [ -f /etc/systemd/system/k3s.service ]; then
  ROLE=server TARGETS="master,etcd,controlplane,node,policies"
elif [ -f /etc/systemd/system/k3s-agent.service ]; then
  ROLE=agent TARGETS="node"
else
  echo "neither k3s.service nor k3s-agent.service found on this node" >&2; exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/kube-bench"
REPORT_DIR="$REPO_DIR/docs/reports"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (multipass exec ... -- sudo)"; exit 1; }

# amd64 on Intel hosts, arm64 when the multipass VM runs on Apple Silicon
ARCH="$(dpkg --print-architecture)"

if [ ! -x "$INSTALL_DIR/kube-bench" ] || ! "$INSTALL_DIR/kube-bench" version | grep -q "$KUBE_BENCH_VERSION"; then
  echo "==> Downloading kube-bench $KUBE_BENCH_VERSION ($ARCH)"
  mkdir -p "$INSTALL_DIR"
  curl -sfL "https://github.com/aquasecurity/kube-bench/releases/download/v${KUBE_BENCH_VERSION}/kube-bench_${KUBE_BENCH_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C "$INSTALL_DIR"
fi

mkdir -p "$REPORT_DIR"
STAMP="$(date +%Y-%m-%d)"
if [ "$ROLE" = server ]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  REPORT="$REPORT_DIR/kube-bench-$STAMP.txt"
else
  REPORT="$REPORT_DIR/kube-bench-$STAMP-$(hostname).txt"
fi

echo "==> Running kube-bench --benchmark $BENCHMARK ($ROLE: targets $TARGETS)"
cd "$INSTALL_DIR"
./kube-bench run \
  --config-dir "$INSTALL_DIR/cfg" \
  --benchmark "$BENCHMARK" \
  --targets "$TARGETS" \
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
