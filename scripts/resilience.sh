#!/usr/bin/env bash
# Resilience checks (plan §8.5). Requires the compose stack from infra/docker-compose.yml
# (the consumer-downtime and DLQ checks manage containers with docker compose).
#
#   SUBMISSION_URL (default http://localhost:8080)
#   MANAGEMENT_URL (default http://localhost:8081)
#   COMPOSE_FILE   (default infra/docker-compose.yml, relative to repo root)
set -euo pipefail

SUBMISSION_URL="${SUBMISSION_URL:-http://localhost:8080}"
MANAGEMENT_URL="${MANAGEMENT_URL:-http://localhost:8081}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/infra/docker-compose.yml}"

bold() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[32mOK: %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

expect_status() { # <expected> <description> <curl args...>
  local expected="$1" desc="$2"; shift 2
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  [ "$status" = "$expected" ] && ok "$desc -> $status" || fail "$desc: expected $expected, got $status"
}

wait_until() { # <description> <command producing json> <jq predicate> <seconds>
  local desc="$1" cmd="$2" predicate="$3" secs="${4:-30}" out
  for _ in $(seq 1 "$secs"); do
    out=$(eval "$cmd" 2>/dev/null || true)
    if [ -n "$out" ] && jq -e "$predicate" >/dev/null 2>&1 <<<"$out"; then
      ok "$desc"
      return 0
    fi
    sleep 1
  done
  fail "$desc (timeout after ${secs}s). Last response: ${out:-<empty>}"
}

dlq_count() {
  docker exec poc-artemis /var/lib/artemis-instance/bin/artemis queue stat \
    --user artemis --password artemis --queueName DLQ --clustered 2>/dev/null \
    | awk -F'|' '$2 ~ /DLQ/ { gsub(/ /,"",$4); print $4 }' | head -1
}

bold "Setup: create a case to work with"
create_response=$(curl -sf -X POST "$SUBMISSION_URL/api/cases" \
  -H 'Content-Type: application/json' -d '{"message":"Resilience check case"}')
CASE_ID=$(jq -r '.caseId' <<<"$create_response")
TOKEN=$(jq -r '.accessToken' <<<"$create_response")
echo "caseId = $CASE_ID"
wait_until "case reached management side" \
  "curl -sf '$MANAGEMENT_URL/api/cases/$CASE_ID'" '.caseId != null'

bold "Check 1: wrong token returns 404 (not 403), plan §3.2"
expect_status 404 "GET with wrong token" \
  "$SUBMISSION_URL/api/cases/$CASE_ID" -H 'X-Case-Token: wrong-token'
expect_status 404 "GET without token" "$SUBMISSION_URL/api/cases/$CASE_ID"
expect_status 404 "GET unknown case with any token" \
  "$SUBMISSION_URL/api/cases/00000000-0000-0000-0000-000000000000" -H 'X-Case-Token: x'

bold "Check 2: blank message returns 400"
expect_status 400 "POST /api/cases with blank message" \
  -X POST "$SUBMISSION_URL/api/cases" -H 'Content-Type: application/json' -d '{"message":"   "}'
expect_status 400 "follow-up with missing message" \
  -X POST "$SUBMISSION_URL/api/cases/$CASE_ID/messages" \
  -H "X-Case-Token: $TOKEN" -H 'Content-Type: application/json' -d '{}'
expect_status 400 "management reply with blank message" \
  -X POST "$MANAGEMENT_URL/api/cases/$CASE_ID/reply" \
  -H 'Content-Type: application/json' -d '{"message":""}'

bold "Check 3: duplicate event delivery does not duplicate thread messages"
echo "Covered by JUnit consumer tests (idempotency by eventId is in-process, plan §3.4):"
echo "  submission: CaseOutboundConsumerTest, management: CaseInboundConsumerTest."

bold "Check 4: management-service down -> durable queue buffers -> catches up"
docker compose -f "$COMPOSE_FILE" stop management-service >/dev/null
ok "management-service stopped"
buffered_response=$(curl -sf -X POST "$SUBMISSION_URL/api/cases/$CASE_ID/messages" \
  -H "X-Case-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"message":"Sent while management was down"}')
BUFFERED_EVENT=$(jq -r '.eventId' <<<"$buffered_response")
ok "submission accepted follow-up $BUFFERED_EVENT while management was down (202)"
docker compose -f "$COMPOSE_FILE" start management-service >/dev/null
ok "management-service restarted"
wait_until "management consumed the buffered message after restart" \
  "curl -sf '$MANAGEMENT_URL/api/cases/$CASE_ID'" \
  "[.messages[] | select(.eventId == \"$BUFFERED_EVENT\")] | length == 1" 60

bold "Check 5: poison message goes to DLQ after bounded redelivery"
before=$(dlq_count); before=${before:-0}
echo "DLQ message count before: $before"
curl -sf -X POST "$MANAGEMENT_URL/api/cases/$CASE_ID/reply" \
  -H 'Content-Type: application/json' -d '{"message":"__poison__"}' >/dev/null
echo "Sent __poison__ reply; submission consumer fails on purpose, Artemis retries 3x (1s delay), then routes to DLQ."
for _ in $(seq 1 30); do
  after=$(dlq_count); after=${after:-0}
  if [ "$after" -gt "$before" ]; then break; fi
  sleep 1
done
[ "${after:-0}" -gt "$before" ] && ok "DLQ count went from $before to $after" \
  || fail "poison message did not reach DLQ (before=$before, after=${after:-0})"

bold "Check 6: poison message did not block the queue"
recovery_response=$(curl -sf -X POST "$MANAGEMENT_URL/api/cases/$CASE_ID/reply" \
  -H 'Content-Type: application/json' -d '{"message":"Normal reply after the poison one"}')
RECOVERY_EVENT=$(jq -r '.eventId' <<<"$recovery_response")
wait_until "valid reply after poison still reaches the reporter" \
  "curl -sf '$SUBMISSION_URL/api/cases/$CASE_ID' -H 'X-Case-Token: $TOKEN'" \
  "[.messages[] | select(.eventId == \"$RECOVERY_EVENT\")] | length == 1" 60

bold "All resilience checks passed"
