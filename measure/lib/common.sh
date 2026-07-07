# Shared helpers for the measurement harness (sourced by measure/*.sh).
#
# Conventions:
#   * every metric sample is one CSV row appended to $RESULTS_DIR/raw.csv:
#       timestamp_utc,platform,metric,run,value,unit,notes
#   * platforms: compose | podman | k3s
#   * host scripts talk to the VMs exclusively through `mp` (multipass);
#     in-VM collectors live under measure/vm/ and run via the /repo mount.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEASURE_DIR="$REPO_DIR/measure"

ENGINES_VM="${ENGINES_VM:-case-engines}"
K3S_VM="${K3S_VM:-case-poc}"

# One results dir per campaign; override RUN_ID to append to an existing one.
RUN_ID="${RUN_ID:-$(date -u +%Y-%m-%d)}"
RESULTS_DIR="${RESULTS_DIR:-$REPO_DIR/docs/reports/measurements/$RUN_ID}"
RAW_CSV="$RESULTS_DIR/raw.csv"

# Git Bash on Windows rewrites POSIX-looking args before they reach
# multipass.exe; keep VM-side paths untouched (same pattern as scripts/).
mp() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' multipass "$@"; }
host_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

csv_init() {
  mkdir -p "$RESULTS_DIR"
  [ -f "$RAW_CSV" ] || echo "timestamp_utc,platform,metric,run,value,unit,notes" > "$RAW_CSV"
}

# record <platform> <metric> <run> <value> <unit> [notes]
record() {
  csv_init
  local notes="${6:-}"
  # commas would break the CSV; keep notes comma-free
  notes="${notes//,/;}"
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$notes" >> "$RAW_CSV"
  note "[$1] $2 run=$3 -> $4 $5 ${notes:+($notes)}"
}

vm_ip() { mp exec "$1" -- hostname -I | tr -d '\r' | awk '{print $1}'; }

vm_state() { mp info "$1" --format json 2>/dev/null \
  | jq -r --arg n "$1" '.info[$n].state // "Absent"'; }

# The host has 16 GiB; the two 8 GiB VMs must never run concurrently —
# which also guarantees the measured VM has the hypervisor to itself.
ensure_only_vm() {
  local want="$1" other
  if [ "$want" = "$ENGINES_VM" ]; then other="$K3S_VM"; else other="$ENGINES_VM"; fi
  if [ "$(vm_state "$other")" = "Running" ]; then
    say "Stopping $other (one measured VM at a time)"
    mp stop "$other"
  fi
  if [ "$(vm_state "$want")" != "Running" ]; then
    say "Starting $want"
    mp start "$want"
    sleep 5
  fi
}

# wait_http <url> <timeout_s> [host_header]  — polls until HTTP 200, prints
# elapsed milliseconds on stdout, fails after the timeout.
wait_http() {
  local url="$1" timeout="$2" hosthdr="${3:-}" t0 code
  # always non-empty: macOS bash 3.2 errors on empty-array expansion with -u
  local -a hdr=(-H 'Accept: */*')
  [ -n "$hosthdr" ] && hdr=(-H "Host: $hosthdr")
  t0=$(now_ms)
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${hdr[@]}" "$url" || true)
    if [ "$code" = "200" ]; then
      echo $(( $(now_ms) - t0 ))
      return 0
    fi
    if [ $(( $(now_ms) - t0 )) -gt $(( timeout * 1000 )) ]; then
      echo "-1"
      return 1
    fi
    sleep 0.5
  done
}

ms_to_s() { awk -v ms="$1" 'BEGIN { printf "%.1f", ms/1000 }'; }

# Uniform application ready criterion used by every platform: the three
# public endpoints answer 200 (submission + management health, Keycloak
# realm discovery). Args: <submission_url> <management_url> <keycloak_url>
# [timeout_s] [host_submission] [host_management] [host_keycloak]
wait_app_ready() {
  local sub="$1" mgm="$2" kc="$3" timeout="${4:-600}"
  local hsub="${5:-}" hmgm="${6:-}" hkc="${7:-}" t0 e
  t0=$(now_ms)
  wait_http "$kc/realms/case-poc/.well-known/openid-configuration" "$timeout" "$hkc" >/dev/null || return 1
  wait_http "$sub/q/health/ready" "$timeout" "$hsub" >/dev/null || return 1
  wait_http "$mgm/q/health/ready" "$timeout" "$hmgm" >/dev/null || return 1
  e=$(( $(now_ms) - t0 ))
  echo "$e"
}

# run_k6 <base_url> <out_json> [host_header] — constant-arrival-rate POST
# /api/cases; RATE/LOAD_DURATION overridable from the environment. (Not
# named K6_DURATION: k6 treats K6_* env vars as its own CLI shortcuts and
# a stray K6_DURATION silently replaces the whole scenario config.)
run_k6() {
  local base="$1" out="$2" hosthdr="${3:-}"
  local rate="${RATE:-10}" duration="${LOAD_DURATION:-60s}"
  if command -v k6 >/dev/null 2>&1; then
    BASE_URL="$base" HOST_HEADER="$hosthdr" RATE="$rate" DURATION="$duration" \
      SUMMARY_PATH="$out" k6 run --quiet "$MEASURE_DIR/k6/workload.js"
  else
    # fallback: containerised k6 (host network egress reaches the VM IP)
    docker run --rm -i \
      -e BASE_URL="$base" -e HOST_HEADER="$hosthdr" -e RATE="$rate" \
      -e DURATION="$duration" -e SUMMARY_PATH="/out/$(basename "$out")" \
      -v "$(host_path "$(dirname "$out")"):/out" \
      grafana/k6 run --quiet - < "$MEASURE_DIR/k6/workload.js"
  fi
  [ -f "$out" ] || die "k6 produced no summary at $out"
}
