#!/usr/bin/env bash
# Heals the k3s control-plane node after a DHCP address change across a VM
# restart (a normal event on Windows/multipass). Two coupled failure modes:
#
#   1. embedded etcd pins the old peer URL -> handled in site.yml via
#      `k3s server --cluster-reset`
#   2. the Node object's status.addresses pins the old InternalIP: the
#      netpol controller fatals ("failed to start networking: ... failed to
#      find interface with specified node ip") ~60s after every start, which
#      never lets the cloud controller's periodic address refresh run — a
#      deadlock this script breaks by starting once WITHOUT the netpol
#      controller, correcting the annotations + status, and restoring the
#      original config.
#
# Conservative: exits 0 without touching anything unless the node is
# actually in the mismatch state. Run on the control-plane VM as root
# (called by deploy/vm/ansible/site.yml on every provision).
set -eu
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
CFG=/etc/rancher/k3s/config.yaml
NODE="$(hostname)"
NEW_IP="$(hostname -I | awk '{print $1}')"

node_ip() {
  k3s kubectl get node "$NODE" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true
}

# Fast path: healthy service and matching address -> nothing to do.
if systemctl is-active --quiet k3s && [ "$(node_ip)" = "$NEW_IP" ]; then
  echo "OK: node InternalIP matches $NEW_IP"
  exit 0
fi

# Only intervene on positive evidence of the mismatch state.
if ! journalctl -u k3s -n 300 --no-pager 2>/dev/null \
     | grep -q 'failed to find interface with specified node ip'; then
  current="$(node_ip)"
  if [ -z "$current" ] || [ "$current" = "$NEW_IP" ]; then
    echo "OK: no node-IP mismatch evidence; leaving k3s alone"
    exit 0
  fi
fi

echo "== healing stale node InternalIP ($(node_ip) -> $NEW_IP)"
cp "$CFG" /tmp/k3s-config.yaml.bak
grep -q '^disable-network-policy' "$CFG" || echo 'disable-network-policy: true' >> "$CFG"
systemctl restart k3s

for i in $(seq 1 40); do
  k3s kubectl get node "$NODE" >/dev/null 2>&1 && break
  sleep 5
done

k3s kubectl annotate node "$NODE" "k3s.io/internal-ip=$NEW_IP" --overwrite
k3s kubectl annotate node "$NODE" "flannel.alpha.coreos.com/public-ip=$NEW_IP" --overwrite
k3s kubectl patch node "$NODE" --subresource=status --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/status/addresses/0\",\"value\":{\"type\":\"InternalIP\",\"address\":\"$NEW_IP\"}}]"

cp /tmp/k3s-config.yaml.bak "$CFG"
systemctl restart k3s

for i in $(seq 1 40); do
  if k3s kubectl wait --for=condition=Ready "node/$NODE" --timeout=20s 2>/dev/null; then
    sleep 90   # outlive the window in which the netpol fatal used to hit
    if systemctl is-active --quiet k3s && [ "$(node_ip)" = "$NEW_IP" ]; then
      echo "FIXED: node InternalIP now $NEW_IP and k3s stable"
      exit 0
    fi
  fi
  sleep 5
done
echo "STILL BROKEN after heal attempt"
exit 1
