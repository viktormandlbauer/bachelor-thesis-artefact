#!/usr/bin/env bash
#
# Dimension 3 — workload performance (protocol M-WP-01..05): k6 constant-
# arrival-rate load against POST /api/cases, five runs with cool-down,
# mid-load workload RSS snapshot, and image-warm service startup.
#
#   bash measure/measure-workload.sh <compose|podman|k3s>
#
# Env: RUNS (default 5), RATE (req/s, default 10), LOAD_DURATION (default 60s),
#      COOLDOWN (s between runs, default 60), PRIME (1 = discarded 30s
#      warm-up load before run 1, default 1), RUN_ID/RESULTS_DIR.
#
# The stack is deployed (untimed) if not already running — run this after
# measure-lifecycle.sh with KEEP_STACK=1 to reuse the installed release.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$MEASURE_DIR/lib/stack.sh"

PLATFORM="${1:?platform (compose|podman|k3s)}"
RUNS="${RUNS:-5}"
RATE="${RATE:-10}"
LOAD_DURATION="${LOAD_DURATION:-60s}"
COOLDOWN="${COOLDOWN:-60}"
PRIME="${PRIME:-1}"

VM=$(platform_vm "$PLATFORM")
ENGINE="$PLATFORM"; [ "$PLATFORM" = "compose" ] && ENGINE="docker"

ensure_only_vm "$VM"
csv_init
mkdir -p "$RESULTS_DIR/k6"

say "D3 on $PLATFORM — ensuring the stack is deployed and ready"
if ! stack_ready "$PLATFORM" 10 >/dev/null 2>&1; then
  note "not running; deploying (untimed)"
  stack_prepare "$PLATFORM"
  stack_deploy "$PLATFORM" "$BASE_TAG"
  stack_ready "$PLATFORM" 600 >/dev/null || die "stack did not become ready"
fi
stack_urls "$PLATFORM"

if [ "$PRIME" = "1" ]; then
  say "Priming (discarded 30s @ 5 req/s — JVM steady state)"
  RATE=5 LOAD_DURATION=30s run_k6 "$SUB_URL" "$RESULTS_DIR/k6/$PLATFORM-prime.json" "$SUB_HOST" >/dev/null || true
  sleep 10
fi

for run in $(seq 1 "$RUNS"); do
  say "M-WP-01..04 run $run/$RUNS: k6 $RATE req/s for $LOAD_DURATION"
  out="$RESULTS_DIR/k6/$PLATFORM-run$run.json"

  run_k6 "$SUB_URL" "$out" "$SUB_HOST" &
  K6_PID=$!
  # mid-load RSS snapshot (M-WP extra: workload memory under load)
  sleep "$(( ${LOAD_DURATION%s} / 2 ))"
  while IFS=, read -r metric value unit notes; do
    [ -n "$metric" ] && record "$PLATFORM" "$metric" "$run" "$value" "$unit" "mid-load; $notes"
  done < <(mp exec "$VM" -- sudo bash /repo/measure/vm/workload-rss.sh "$ENGINE")
  wait "$K6_PID" || die "k6 run $run failed"

  record "$PLATFORM" http_throughput "$run" "$(jq -r .throughput_rps "$out")" rps "target $RATE rps for $LOAD_DURATION"
  record "$PLATFORM" http_p50 "$run" "$(jq -r .p50_ms "$out")" ms ""
  record "$PLATFORM" http_p95 "$run" "$(jq -r .p95_ms "$out")" ms ""
  record "$PLATFORM" http_p99 "$run" "$(jq -r .p99_ms "$out")" ms ""
  record "$PLATFORM" http_error_rate "$run" "$(jq -r .error_rate "$out")" ratio "of $(jq -r .count "$out") requests; dropped=$(jq -r .dropped_iterations "$out")"

  [ "$run" -lt "$RUNS" ] && { note "cool-down ${COOLDOWN}s"; sleep "$COOLDOWN"; }
done

say "M-WP-05 image-warm service startup (submission-service, $RUNS runs)"
for run in $(seq 1 "$RUNS"); do
  case "$PLATFORM" in
    compose)
      eng "docker stop measure-submission-service >/dev/null"
      t0=$(now_ms)
      eng "docker start measure-submission-service >/dev/null"
      wait_http "$SUB_URL/q/health/ready" 300 >/dev/null || die "submission did not come back"
      record "$PLATFORM" startup_time "$run" "$(ms_to_s $(( $(now_ms) - t0 )))" s "docker start -> /q/health/ready 200"
      ;;
    podman)
      eng "podman pod stop submission-service >/dev/null"
      t0=$(now_ms)
      eng "podman pod start submission-service >/dev/null"
      wait_http "$SUB_URL/q/health/ready" 300 >/dev/null || die "submission did not come back"
      record "$PLATFORM" startup_time "$run" "$(ms_to_s $(( $(now_ms) - t0 )))" s "podman pod start -> /q/health/ready 200"
      ;;
    k3s)
      # protocol definition: pod creation -> Ready condition, from the API
      # server's own timestamps (image already in containerd)
      secs=$(k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        kubectl -n measure delete pod -l app.kubernetes.io/name=submission-service --wait=true >/dev/null
        kubectl -n measure wait --for=condition=Ready pod -l app.kubernetes.io/name=submission-service --timeout=300s >/dev/null
        pod=\$(kubectl -n measure get pod -l app.kubernetes.io/name=submission-service -o jsonpath='{.items[0].metadata.name}')
        created=\$(kubectl -n measure get pod \$pod -o jsonpath='{.metadata.creationTimestamp}')
        ready=\$(kubectl -n measure get pod \$pod -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].lastTransitionTime}')
        echo \$(( \$(date -d \"\$ready\" +%s) - \$(date -d \"\$created\" +%s) ))" | tr -d '[:space:]')
      record "$PLATFORM" startup_time "$run" "$secs" s "pod creationTimestamp -> Ready condition (API timestamps)"
      ;;
  esac
  sleep 5
done

if [ "${KEEP_STACK:-0}" != "1" ]; then
  say "Teardown"
  stack_teardown "$PLATFORM"
fi

say "D3 on $PLATFORM done -> $RAW_CSV"
