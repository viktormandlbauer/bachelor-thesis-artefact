#!/usr/bin/env bash
#
# In-VM collector for Dimension 1 (platform resource footprint) of the SRQ3
# measurement protocol. Prints CSV fragments `metric,value,unit,notes` to
# stdout; the host-side orchestrator (measure/measure-platform.sh) prefixes
# platform and run number.
#
#   sudo footprint.sh <docker|podman|k3s> rss
#   sudo footprint.sh <docker|podman|k3s> cpu [seconds=60]     (pidstat)
#   sudo footprint.sh <docker|podman|k3s> disk
#   sudo footprint.sh <docker|podman|k3s> versions
#
# Method (protocol §3 D1): RSS from /proc/<pid>/status VmRSS summed over the
# platform process set — for k3s the pod processes are enumerated through
# the CRI (crictl) and attributed per namespace, so platform pods
# (kube-system, argocd) are separable from workload pods. CPU uses pidstat
# over the same pid set. Disk separates binaries, state and image store.
set -euo pipefail

PLATFORM="${1:?platform (docker|podman|k3s)}"
ACTION="${2:?action (rss|cpu|disk|versions)}"
CPU_SECONDS="${3:-60}"

emit() { printf '%s,%s,%s,%s\n' "$1" "$2" "$3" "${4:-}"; }

# ---- pid enumeration ------------------------------------------------------

# all pids of the cgroup that contains <pid> (covers forked children)
cgroup_pids() {
  local pid="$1" rel
  rel=$(awk -F: '$1=="0"{print $3}' "/proc/$pid/cgroup" 2>/dev/null) || return 0
  [ -n "$rel" ] && cat "/sys/fs/cgroup$rel/cgroup.procs" 2>/dev/null || echo "$pid"
}

host_pids_docker()  { pgrep -x dockerd || true; pgrep -x containerd || true; pgrep -f 'containerd-shim' || true; pgrep -x docker-proxy || true; }
host_pids_podman()  { pgrep -x podman || true; pgrep -x conmon || true; pgrep -x netavark || true; pgrep -x aardvark-dns || true; }
host_pids_k3s()     { pgrep -x k3s-server || true; pgrep -x k3s || true; pgrep -x containerd || true; pgrep -f 'containerd-shim' || true; }

# k3s pod pids grouped by namespace: "namespace pid" lines
k3s_pod_pids() {
  command -v crictl >/dev/null || export PATH="$PATH:/usr/local/bin"
  local pods containers
  pods=$(crictl pods -o json | jq -r '.items[] | "\(.id) \(.metadata.namespace)"')
  containers=$(crictl ps -o json | jq -r '.containers[] | "\(.id) \(.podSandboxId)"')
  while read -r cid sandbox; do
    [ -n "$cid" ] || continue
    local ns pid
    ns=$(awk -v s="$sandbox" '$1==s{print $2}' <<<"$pods")
    pid=$(crictl inspect -o json "$cid" 2>/dev/null | jq -r '.info.pid // empty')
    [ -n "$pid" ] && [ -n "$ns" ] || continue
    for p in $(cgroup_pids "$pid"); do echo "$ns $p"; done
  done <<<"$containers"
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

# ---- actions --------------------------------------------------------------

do_rss() {
  case "$PLATFORM" in
    docker|podman)
      local pids kb
      pids=$("host_pids_$PLATFORM" | sort -u)
      # shellcheck disable=SC2086
      kb=$(rss_kb_of_pids $pids)
      emit platform_rss_total "$(kb_to_mib "$kb")" MiB "procs=$(echo $pids | tr ' ' '+')"
      ;;
    k3s)
      local host_pids kb_core
      host_pids=$(host_pids_k3s | sort -u)
      # shellcheck disable=SC2086
      kb_core=$(rss_kb_of_pids $host_pids)
      emit platform_rss_core "$(kb_to_mib "$kb_core")" MiB "k3s+containerd+shims"

      local mapping kb_ns total_kb="$kb_core"
      mapping=$(k3s_pod_pids)
      for ns in $(awk '{print $1}' <<<"$mapping" | sort -u); do
        # shellcheck disable=SC2086
        kb_ns=$(rss_kb_of_pids $(awk -v n="$ns" '$1==n{print $2}' <<<"$mapping"))
        case "$ns" in
          kube-system|argocd)
            emit "platform_rss_${ns//-/_}" "$(kb_to_mib "$kb_ns")" MiB "pod processes in $ns"
            total_kb=$(( total_kb + kb_ns ))
            ;;
          *)
            emit "workload_rss_${ns//-/_}" "$(kb_to_mib "$kb_ns")" MiB "excluded from platform total"
            ;;
        esac
      done
      emit platform_rss_total "$(kb_to_mib "$total_kb")" MiB "core+kube-system+argocd"
      ;;
  esac
}

do_cpu() {
  local pids
  case "$PLATFORM" in
    docker|podman) pids=$("host_pids_$PLATFORM" | sort -u) ;;
    k3s) pids=$( { host_pids_k3s; k3s_pod_pids | awk '$1=="kube-system"||$1=="argocd"{print $2}'; } | sort -un) ;;
  esac
  if [ -z "$pids" ]; then
    emit platform_cpu_idle 0 pct "no platform processes (daemonless)"
    return
  fi
  local list total
  list=$(echo "$pids" | paste -sd, -)
  # one report over the whole window; sum the %CPU column of the report rows
  total=$(pidstat -u -h -p "$list" "$CPU_SECONDS" 1 2>/dev/null | awk '
    /^#/ { for (i=1;i<=NF;i++) if ($i=="%CPU") col=i-1; next }
    NF && $1 ~ /^[0-9]/ && col { sum += $col }
    END { printf "%.2f", sum }')
  emit platform_cpu_idle "${total:-0}" pct "pidstat ${CPU_SECONDS}s; ncpu=$(nproc); pids=$(echo "$pids" | wc -l | tr -d ' ')"
}

du_mib() { du -sm "$@" 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s}'; }
bin_mib() {
  local total=0 f
  for f in "$@"; do
    [ -f "$f" ] && total=$(( total + $(stat -c %s "$f") ))
  done
  awk -v b="$total" 'BEGIN{printf "%.1f", b/1048576}'
}

do_disk() {
  case "$PLATFORM" in
    docker)
      emit platform_disk_binaries "$(bin_mib /usr/bin/dockerd /usr/bin/docker /usr/bin/containerd /usr/bin/containerd-shim-runc-v2 /usr/sbin/runc /usr/bin/runc /usr/bin/docker-proxy)" MiB "dockerd+docker+containerd+shim+runc"
      emit platform_disk_state "$(du_mib /var/lib/docker /var/lib/containerd)" MiB "/var/lib/docker + /var/lib/containerd (incl. images)"
      # Docker >=28 defaults to the containerd snapshotter: layers live under
      # /var/lib/containerd, the classic overlay2 dir stays empty
      emit image_store "$(du_mib /var/lib/docker/overlay2 /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs /var/lib/containerd/io.containerd.content.v1.content)" MiB "layer+content store"
      ;;
    podman)
      emit platform_disk_binaries "$(bin_mib /usr/bin/podman /usr/bin/conmon /usr/lib/podman/netavark /usr/lib/podman/aardvark-dns /usr/sbin/runc /usr/bin/runc /usr/bin/crun)" MiB "podman+conmon+netavark+aardvark+runtime"
      emit platform_disk_state "$(du_mib /var/lib/containers)" MiB "/var/lib/containers (incl. images)"
      emit image_store "$(du_mib /var/lib/containers/storage/overlay)" MiB "layer store"
      ;;
    k3s)
      emit platform_disk_binaries "$(bin_mib /usr/local/bin/k3s)" MiB "k3s single binary"
      emit platform_disk_state "$(du_mib /var/lib/rancher /var/lib/kubelet /etc/rancher)" MiB "/var/lib/rancher + /var/lib/kubelet + /etc/rancher (incl. images)"
      emit image_store "$(du_mib /var/lib/rancher/k3s/agent/containerd)" MiB "containerd content+snapshots"
      ;;
  esac
}

do_versions() {
  case "$PLATFORM" in
    docker) emit version "$(docker --version | tr -d ',')" text "$(docker compose version 2>/dev/null | tr -d ',')" ;;
    podman) emit version "$(podman --version | tr -d ',')" text "" ;;
    k3s)    emit version "$(/usr/local/bin/k3s --version | head -1 | tr -d ',')" text "" ;;
  esac
  emit os "$(. /etc/os-release && echo "$PRETTY_NAME" | tr -d ',')" text "kernel $(uname -r)"
}

case "$ACTION" in
  rss) do_rss ;;
  cpu) do_cpu ;;
  disk) do_disk ;;
  versions) do_versions ;;
  *) echo "unknown action $ACTION" >&2; exit 2 ;;
esac
