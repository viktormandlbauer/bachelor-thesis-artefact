#!/usr/bin/env bash
#
# Happy-path demo against the k3s deployment (mirror of scripts/demo.sh, but
# through the Traefik ingress): submit -> visible on management -> reply ->
# visible on submission -> follow-up -> visible on management.
#
# Works from Git Bash on the Windows host or from WSL; requires curl + jq.
# The *.localtest.me hosts resolve to 127.0.0.1, which WSL2 forwards to the
# k3s ingress on port 80.
set -euo pipefail

SUBMISSION_URL="${SUBMISSION_URL:-http://submission.localtest.me}"
MANAGEMENT_URL="${MANAGEMENT_URL:-http://management.localtest.me}"

say() { printf '\n== %s\n' "$*"; }

say "1. Reporter submits an anonymous case (POST $SUBMISSION_URL/api/cases)"
created=$(curl -sf -X POST "$SUBMISSION_URL/api/cases" \
  -H 'Content-Type: application/json' \
  -d '{"message":"k8s demo: anonymous report submitted via ingress"}')
echo "$created" | jq .
case_id=$(echo "$created" | jq -r .caseId)
token=$(echo "$created" | jq -r .accessToken)

say "2. Management sees the case (GET $MANAGEMENT_URL/api/cases?status=open)"
for i in $(seq 1 20); do
  if curl -sf "$MANAGEMENT_URL/api/cases?status=open" | jq -e --arg c "$case_id" 'map(select(.caseId==$c)) | length == 1' >/dev/null; then
    break
  fi
  sleep 1
done
curl -sf "$MANAGEMENT_URL/api/cases/$case_id" | jq .

say "3. Management replies (POST $MANAGEMENT_URL/api/cases/$case_id/reply)"
curl -sf -X POST "$MANAGEMENT_URL/api/cases/$case_id/reply" \
  -H 'Content-Type: application/json' \
  -d '{"message":"k8s demo: management reply"}' | jq .

say "4. Reporter sees the reply (GET $SUBMISSION_URL/api/cases/$case_id)"
for i in $(seq 1 20); do
  if curl -sf "$SUBMISSION_URL/api/cases/$case_id" -H "X-Case-Token: $token" | jq -e '.messages | length >= 2' >/dev/null; then
    break
  fi
  sleep 1
done
curl -sf "$SUBMISSION_URL/api/cases/$case_id" -H "X-Case-Token: $token" | jq .

say "5. Reporter follow-up (POST $SUBMISSION_URL/api/cases/$case_id/messages)"
curl -sf -X POST "$SUBMISSION_URL/api/cases/$case_id/messages" \
  -H 'Content-Type: application/json' -H "X-Case-Token: $token" \
  -d '{"message":"k8s demo: reporter follow-up"}' | jq .

say "6. Management sees the full thread"
for i in $(seq 1 20); do
  if curl -sf "$MANAGEMENT_URL/api/cases/$case_id" | jq -e '.messages | length >= 3' >/dev/null; then
    break
  fi
  sleep 1
done
curl -sf "$MANAGEMENT_URL/api/cases/$case_id" | jq .

say "DEMO OK: case $case_id travelled reporter -> management -> reporter -> management through Artemis on k3s"
