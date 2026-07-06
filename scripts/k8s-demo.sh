#!/usr/bin/env bash
#
# Happy-path demo against the k3s deployment (mirror of scripts/demo.sh, but
# through the Traefik ingress): submit -> visible on management -> reply ->
# visible on submission -> follow-up -> visible on management.
#
# Works on the host (macOS terminal or Git Bash on Windows); requires
# curl + jq + multipass. Traefik listens on port 80 of the multipass VM.
set -euo pipefail

SUBMISSION_HOST="${SUBMISSION_HOST:-submission.localtest.me}"
MANAGEMENT_HOST="${MANAGEMENT_HOST:-management.localtest.me}"
# Pin the ingress IP (the multipass VM) instead of trusting DNS: localtest.me
# resolves to 127.0.0.1, not to the VM — and DNS-rebind protection on many
# routers refuses such answers anyway.
VM_NAME="${VM_NAME:-case-poc}"
INGRESS_IP="${INGRESS_IP:-$(multipass exec "$VM_NAME" -- hostname -I | tr -d '\r' | awk '{print $1}')}"

SUBMISSION_URL="http://$SUBMISSION_HOST"
MANAGEMENT_URL="http://$MANAGEMENT_HOST"
curl() {
  command curl --resolve "$SUBMISSION_HOST:80:$INGRESS_IP" \
               --resolve "$MANAGEMENT_HOST:80:$INGRESS_IP" "$@"
}

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
