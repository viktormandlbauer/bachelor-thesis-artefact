#!/usr/bin/env bash
# Happy-path demo (plan §8.4): drives the full two-way anonymous case thread across
# Artemis and prints the IDs needed to find the traces in SigNoz.
#
# Prerequisites: both services + Keycloak running (compose or quarkus dev),
# curl + jq installed.
#   SUBMISSION_URL (default http://localhost:8080)
#   MANAGEMENT_URL (default http://localhost:8081)
#   KEYCLOAK_URL   (default http://localhost:8180 — the compose port mapping)
set -euo pipefail

SUBMISSION_URL="${SUBMISSION_URL:-http://localhost:8080}"
MANAGEMENT_URL="${MANAGEMENT_URL:-http://localhost:8081}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"

bold() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# Phase 2: the management API requires a Keycloak JWT with the case-manager
# role. Password-grant login as the demo user 'staff' (realm fixture).
bold "0. OIDC login as staff (realm case-poc @ $KEYCLOAK_URL)"
STAFF_TOKEN=$(curl -sf -X POST "$KEYCLOAK_URL/realms/case-poc/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=management-api \
  -d username=staff -d password=staff-password | jq -r .access_token)
[ -n "$STAFF_TOKEN" ] && [ "$STAFF_TOKEN" != "null" ] || fail "could not obtain staff token"
AUTH="Authorization: Bearer $STAFF_TOKEN"
echo "token acquired"

# wait_for <description> <command producing json> <jq predicate>
wait_for() {
  local desc="$1" cmd="$2" predicate="$3" out
  for _ in $(seq 1 30); do
    out=$(eval "$cmd" 2>/dev/null || true)
    if [ -n "$out" ] && jq -e "$predicate" >/dev/null 2>&1 <<<"$out"; then
      echo "$out"
      return 0
    fi
    sleep 1
  done
  fail "$desc did not become true within 30s. Last response: ${out:-<empty>}"
}

bold "1. Submit a new anonymous case (POST $SUBMISSION_URL/api/cases)"
create_response=$(curl -sf -X POST "$SUBMISSION_URL/api/cases" \
  -H 'Content-Type: application/json' \
  -d '{"message":"Initial anonymous report: something is wrong."}')
echo "$create_response" | jq .

bold "2. Extract caseId and access token"
CASE_ID=$(jq -r '.caseId' <<<"$create_response")
TOKEN=$(jq -r '.accessToken' <<<"$create_response")
EVENT_1=$(jq -r '.eventId' <<<"$create_response")
[ -n "$CASE_ID" ] && [ "$CASE_ID" != "null" ] || fail "no caseId in response"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "no accessToken in response"
echo "caseId  = $CASE_ID"
echo "eventId = $EVENT_1"
echo "token   = (redacted, kept in memory for this run)"

bold "3. Read the case back on the submission side (token-gated)"
curl -sf "$SUBMISSION_URL/api/cases/$CASE_ID" -H "X-Case-Token: $TOKEN" | jq .

bold "4. Case appears in the management open-case list (via Artemis)"
wait_for "case visible on management side" \
  "curl -sf -H '$AUTH' '$MANAGEMENT_URL/api/cases?status=open'" \
  "[.[] | select(.caseId == \"$CASE_ID\")] | length == 1" | jq .

bold "5. Management case detail"
curl -sf -H "$AUTH" "$MANAGEMENT_URL/api/cases/$CASE_ID" | jq .

bold "6. Management replies (POST $MANAGEMENT_URL/api/cases/$CASE_ID/reply)"
reply_response=$(curl -sf -X POST -H "$AUTH" "$MANAGEMENT_URL/api/cases/$CASE_ID/reply" \
  -H 'Content-Type: application/json' \
  -d '{"message":"Thank you for the report. We are investigating."}')
echo "$reply_response" | jq .
EVENT_2=$(jq -r '.eventId' <<<"$reply_response")

bold "7. Reply becomes visible on the submission side (via Artemis)"
# The reply author is the authenticated Keycloak principal ("staff"), so match
# the concrete event rather than a hardcoded author name.
wait_for "management reply visible to the reporter" \
  "curl -sf '$SUBMISSION_URL/api/cases/$CASE_ID' -H 'X-Case-Token: $TOKEN'" \
  "[.messages[] | select(.eventId == \"$EVENT_2\")] | length == 1" | jq .

bold "8. Reporter sends a follow-up"
followup_response=$(curl -sf -X POST "$SUBMISSION_URL/api/cases/$CASE_ID/messages" \
  -H "X-Case-Token: $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"message":"Follow-up: here is one more detail."}')
echo "$followup_response" | jq .
EVENT_3=$(jq -r '.eventId' <<<"$followup_response")

bold "9. Follow-up becomes visible on the management side (via Artemis)"
wait_for "follow-up visible to management" \
  "curl -sf -H '$AUTH' '$MANAGEMENT_URL/api/cases/$CASE_ID'" \
  '.messages | length == 3' | jq .

bold "Demo complete"
cat <<EOF
Two-way anonymous thread verified across Artemis.

SigNoz checklist (plan §5.5, UI at http://localhost:3301):
  - Filter traces by attribute:            case.id = $CASE_ID
    (equivalently: conversation.id = $CASE_ID) — expect one trace per user action.
  - Submission trace   (event.id $EVENT_1): HTTP POST /api/cases in submission-service
      -> author/publish case.inbound -> receive/process in management-service.
  - Reply trace        (event.id $EVENT_2): HTTP POST reply in management-service
      -> author/publish case.outbound -> receive/process in submission-service,
      with a span link back to the consumed inbound event.
  - Follow-up trace    (event.id $EVENT_3): like the first, with a span link back
      to the consumed outbound reply.
EOF
