#!/usr/bin/env bash
#
# In-VM snapshot of the deployed workload's memory (RSS, MiB), taken
# mid-load by measure/measure-workload.sh. Same method as footprint.sh
# (VmRSS summed over all pids of each container's cgroup) so the numbers
# are comparable across platforms. Prints `metric,value,unit,notes` rows.
#
#   sudo workload-rss.sh <docker|podman|k3s>
set -euo pipefail

PLATFORM="${1:?docker|podman|k3s}"

emit() { printf '%s,%s,%s,%s\n' "$1" "$2" "$3" "${4:-}"; }

cgroup_pids() {
  local pid="$1" rel
  rel=$(awk -F: '$1=="0"{print $3}' "/proc/$pid/cgroup" 2>/dev/null) || return 0
  [ -n "$rel" ] && cat "/sys/fs/cgroup$rel/cgroup.procs" 2>/dev/null || echo "$pid"
}

rss_kb_of_pids() {
  local total=0 v
  for p in "$@"; do
    v=$(awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null || true)
    total=$(( total + ${v:-0} ))
  done
  echo "$total"
}

kb_to_mib() { awk -v kb="$1" 'BEGIN{printf "%.1f", kb/1024}'; }

total_kb=0

emit_container() { # <label> <main_pid>
  local kb
  # shellcheck disable=SC2086
  kb=$(rss_kb_of_pids $(cgroup_pids "$2"))
  total_kb=$(( total_kb + kb ))
  emit "workload_rss_$1" "$(kb_to_mib "$kb")" MiB ""
}

case "$PLATFORM" in
  docker)
    for name in $(docker ps --filter label=com.docker.compose.project=measure-compose --format '{{.Names}}'); do
      pid=$(docker inspect -f '{{.State.Pid}}' "$name")
      emit_container "${name#measure-}" "$pid"
    done
    ;;
  podman)
    while IFS='|' read -r name pod; do
      [ -n "$name" ] || continue
      case "$name" in *-infra) continue ;; esac
      pid=$(podman inspect -f '{{.State.Pid}}' "$name")
      emit_container "$pod" "$pid"
    done < <(podman ps --format '{{.Names}}|{{.PodName}}')
    ;;
  k3s)
    export PATH="$PATH:/usr/local/bin"
    sandboxes=$(crictl pods --namespace measure -o json | jq -r '.items[].id')
    while read -r cid cname sandbox; do
      [ -n "$cid" ] || continue
      grep -qx "$sandbox" <<<"$sandboxes" || continue
      pid=$(crictl inspect -o json "$cid" 2>/dev/null | jq -r '.info.pid // empty')
      [ -n "$pid" ] && emit_container "$cname" "$pid"
    done < <(crictl ps -o json | jq -r '.containers[] | "\(.id) \(.metadata.name) \(.podSandboxId)"')
    ;;
esac

emit workload_rss_total "$(kb_to_mib "$total_kb")" MiB "all workload containers"
