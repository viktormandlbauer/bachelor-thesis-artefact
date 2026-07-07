#!/usr/bin/env bash
#
# Dimension 1 — platform resource footprint (protocol M-PF-01..04), one run:
# cold start, warm-up, idle RSS, idle CPU; disk footprint and versions on
# run 1 (deterministic). No application workload is deployed (§2 principle
# "isolate one variable"); on k3s the GitOps-managed case-poc app is
# quiesced first and the Argo CD application controller is scaled to zero —
# its RSS is therefore sampled separately BEFORE quiescing and noted.
#
#   bash measure/measure-platform.sh <compose|podman|k3s> [run=1]
#
# Env: WARMUP (s, default 300), CPU_SECONDS (default 60), RUN_ID/RESULTS_DIR
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$MEASURE_DIR/lib/stack.sh"

PLATFORM="${1:?platform (compose|podman|k3s)}"
RUN="${2:-1}"
WARMUP="${WARMUP:-300}"
CPU_SECONDS="${CPU_SECONDS:-60}"

VM=$(platform_vm "$PLATFORM")
ENGINE="$PLATFORM"; [ "$PLATFORM" = "compose" ] && ENGINE="docker"

ensure_only_vm "$VM"
csv_init

collect() { # <action> [arg] -> records each emitted metric row
  local line metric value unit notes
  while IFS=, read -r metric value unit notes; do
    [ -n "$metric" ] && record "$PLATFORM" "$metric" "$RUN" "$value" "$unit" "$notes"
  done < <(mp exec "$VM" -- sudo bash /repo/measure/vm/footprint.sh "$ENGINE" "$@")
}

say "D1 run $RUN on $PLATFORM — preparing workload-free state"
if [ "$PLATFORM" = "k3s" ]; then
  # The application controller must be scaled to 0 during idle sampling
  # (selfHeal would bring the workload back), so its RSS is missing from
  # the idle totals. Sample the argocd namespace once BEFORE quiescing and
  # record it under a distinct metric so the controller's cost stays visible.
  if [ "$RUN" = "1" ]; then
    # after a VM start the pods need a moment before crictl can attribute them
    k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
         until kubectl -n argocd get pods 2>/dev/null | grep -q Running; do sleep 2; done" || true
    sleep 10
    pre=$(mp exec "$VM" -- sudo bash /repo/measure/vm/footprint.sh k3s rss \
      | awk -F, '$1=="platform_rss_argocd"{print $2}')
    [ -n "${pre:-}" ] && record k3s platform_rss_argocd_with_controller "$RUN" "$pre" MiB "pre-quiesce; incl. application controller; case-poc workload still running"
  fi
  stack_teardown k3s
  k3s "bash /repo/measure/vm/k3s-quiesce.sh quiesce >/dev/null"
else
  stack_teardown "$PLATFORM"
fi

say "M-PF-04 cold start ($PLATFORM)"
case "$PLATFORM" in
  compose)
    eng "systemctl stop docker.socket docker containerd >/dev/null 2>&1; sleep 2"
    t0=$(now_ms)
    eng "systemctl start docker"
    until eng "docker info >/dev/null 2>&1"; do sleep 0.5; done
    record "$PLATFORM" cold_start "$RUN" "$(ms_to_s $(( $(now_ms) - t0 )))" s "systemctl start docker -> docker info OK"
    ;;
  podman)
    record "$PLATFORM" cold_start "$RUN" 0 s "daemonless engine; no platform service to start"
    ;;
  k3s)
    k3s "/usr/local/bin/k3s-killall.sh >/dev/null 2>&1; sleep 2"
    t0=$(now_ms)
    k3s "systemctl start k3s"
    k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
         until kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; do sleep 1; done
         for ns in kube-system argocd; do
           for d in \$(kubectl -n \$ns get deploy -o name); do
             kubectl -n \$ns rollout status \$d --timeout=600s >/dev/null
           done
         done"
    record "$PLATFORM" cold_start "$RUN" "$(ms_to_s $(( $(now_ms) - t0 )))" s "k3s-killall -> node Ready + kube-system/argocd deployments available (argocd controller at 0)"
    ;;
esac

say "Warm-up ${WARMUP}s before idle sampling (protocol §4.1)"
sleep "$WARMUP"

say "M-PF-01 idle RSS"
collect rss

say "M-PF-02 idle CPU (pidstat ${CPU_SECONDS}s)"
collect cpu "$CPU_SECONDS"

if [ "$RUN" = "1" ]; then
  say "M-PF-03 disk footprint + versions (deterministic, run 1 only)"
  collect disk
  collect versions
fi

say "D1 run $RUN on $PLATFORM done -> $RAW_CSV"
