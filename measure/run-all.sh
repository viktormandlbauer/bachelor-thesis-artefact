#!/usr/bin/env bash
#
# Full SRQ3 comparison campaign over the three platforms, following
# protocol §4: per platform D1 (cold start + idle) x RUNS, D2 (install/
# upgrade/rollback) x RUNS, then D3 (k6 + startup) on a fresh install.
# Ends by restoring the GitOps-managed workload on the k3s VM and
# aggregating docs/reports/measurements/$RUN_ID/report.md.
#
#   bash measure/run-all.sh                      # the real thing (~hours)
#   SMOKE=1 bash measure/run-all.sh              # 1 run each, short windows
#   PLATFORMS="podman" RUNS=3 bash measure/run-all.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$MEASURE_DIR/lib/stack.sh"

PLATFORMS="${PLATFORMS:-compose podman k3s}"
RUNS="${RUNS:-5}"

if [ "${SMOKE:-0}" = "1" ]; then
  RUNS=1
  export WARMUP="${WARMUP:-30}" CPU_SECONDS="${CPU_SECONDS:-10}" \
         LOAD_DURATION="${LOAD_DURATION:-20s}" COOLDOWN="${COOLDOWN:-5}" PRIME="${PRIME:-0}"
  say "SMOKE mode: 1 run per dimension, shortened windows (not protocol-conformant)"
fi

for p in $PLATFORMS; do
  say "======================= PLATFORM: $p ======================="

  for run in $(seq 1 "$RUNS"); do
    bash "$MEASURE_DIR/measure-platform.sh" "$p" "$run"
  done

  for run in $(seq 1 "$RUNS"); do
    bash "$MEASURE_DIR/measure-lifecycle.sh" "$p" "$run"
  done

  RUNS="$RUNS" bash "$MEASURE_DIR/measure-workload.sh" "$p"
done

if grep -q k3s <<<"$PLATFORMS"; then
  say "Restoring the GitOps-managed workload on $K3S_VM"
  ensure_only_vm "$K3S_VM"
  k3s "bash /repo/measure/vm/k3s-quiesce.sh restore"
fi

say "Aggregating $RESULTS_DIR/report.md"
python3 "$MEASURE_DIR/stats.py" "$RAW_CSV" > "$RESULTS_DIR/report.md"
note "done: $RESULTS_DIR/report.md"
