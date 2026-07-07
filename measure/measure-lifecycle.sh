#!/usr/bin/env bash
#
# Dimension 2 — deployment lifecycle timing (protocol M-LC-01..03), one
# sequence: clean state -> install -> upgrade (image tag 2.0.0 -> 2.0.1) ->
# rollback -> teardown. Every phase is timed from command invocation to the
# uniform end state: the expected image tag is running AND the three public
# endpoints answer 200 (stack_ready). The upgrade image is the same bits
# retagged, so the timing isolates lifecycle mechanics from image content.
#
#   bash measure/measure-lifecycle.sh <compose|podman|k3s> [run=1]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$MEASURE_DIR/lib/stack.sh"

PLATFORM="${1:?platform (compose|podman|k3s)}"
RUN="${2:-1}"
READY_TIMEOUT="${READY_TIMEOUT:-600}"

ensure_only_vm "$(platform_vm "$PLATFORM")"
csv_init

say "D2 run $RUN on $PLATFORM — clean state"
stack_prepare "$PLATFORM"

say "M-LC-01 install ($BASE_TAG)"
t0=$(now_ms)
stack_deploy "$PLATFORM" "$BASE_TAG"
stack_ready "$PLATFORM" "$READY_TIMEOUT" >/dev/null || die "install did not become ready"
t=$(( $(now_ms) - t0 ))
stack_verify_tag "$PLATFORM" "$BASE_TAG"
record "$PLATFORM" install_time "$RUN" "$(ms_to_s "$t")" s "command -> tag $BASE_TAG running + all endpoints 200"

say "M-LC-02 upgrade ($BASE_TAG -> $UPGRADE_TAG)"
t0=$(now_ms)
stack_upgrade "$PLATFORM" "$UPGRADE_TAG"
stack_ready "$PLATFORM" "$READY_TIMEOUT" >/dev/null || die "upgrade did not become ready"
t=$(( $(now_ms) - t0 ))
stack_verify_tag "$PLATFORM" "$UPGRADE_TAG"
record "$PLATFORM" upgrade_time "$RUN" "$(ms_to_s "$t")" s "command -> tag $UPGRADE_TAG running + all endpoints 200"

say "M-LC-03 rollback (-> $BASE_TAG)"
t0=$(now_ms)
stack_rollback "$PLATFORM"
stack_ready "$PLATFORM" "$READY_TIMEOUT" >/dev/null || die "rollback did not become ready"
t=$(( $(now_ms) - t0 ))
stack_verify_tag "$PLATFORM" "$BASE_TAG"
record "$PLATFORM" rollback_time "$RUN" "$(ms_to_s "$t")" s "command -> tag $BASE_TAG running + all endpoints 200"

if [ "${KEEP_STACK:-0}" = "1" ]; then
  say "KEEP_STACK=1 — leaving the stack deployed"
else
  say "Teardown"
  stack_teardown "$PLATFORM"
fi

say "D2 run $RUN on $PLATFORM done -> $RAW_CSV"
