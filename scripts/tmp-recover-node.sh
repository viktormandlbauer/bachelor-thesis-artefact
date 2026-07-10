#!/usr/bin/env bash
# One-shot recovery: the Node object holds the pre-reboot InternalIP, which
# kills the k3s netpol controller ("failed to find interface with specified
# node ip") ~60s after every start. Delete the stale node during an apiserver
# window and restart k3s so it re-registers with the current IP.
set -u
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "== current node object (if reachable):"
k3s kubectl get node case-poc-cp -o jsonpath='{.status.addresses}' 2>/dev/null && echo

systemctl start k3s 2>/dev/null || true

echo "== waiting for an apiserver window to delete the stale node object"
for i in $(seq 1 60); do
  if k3s kubectl delete node case-poc-cp --timeout=10s 2>/dev/null; then
    echo "node object deleted"
    break
  fi
  sleep 3
done

echo "== restarting k3s for a clean re-registration"
systemctl restart k3s

echo "== waiting for node Ready with fresh addresses"
for i in $(seq 1 60); do
  if k3s kubectl wait --for=condition=Ready node/case-poc-cp --timeout=20s 2>/dev/null; then
    k3s kubectl get node -o wide
    echo "RECOVERED"
    exit 0
  fi
  sleep 5
done
echo "NOT RECOVERED"
exit 1
