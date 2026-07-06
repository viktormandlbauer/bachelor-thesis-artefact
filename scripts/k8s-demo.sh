#!/usr/bin/env bash
#
# Happy-path demo against the k3s deployment (Phase-2 app, through the
# Traefik ingress): OIDC login -> submit -> visible on management -> reply ->
# visible on submission -> follow-up -> visible on management. Includes the
# negative identity checks (no token -> 401, role-less user -> 403).
#
# Works on the host (macOS terminal or Git Bash on Windows); requires
# curl + jq + multipass. Traefik listens on port 80 of the multipass VM.
set -euo pipefail

SUBMISSION_HOST="${SUBMISSION_HOST:-submission.localtest.me}"
MANAGEMENT_HOST="${MANAGEMENT_HOST:-management.localtest.me}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.localtest.me}"
# Pin the ingress IP (the multipass VM) instead of trusting DNS: localtest.me
# resolves to 127.0.0.1, not to the VM — and DNS-rebind protection on many
# routers refuses such answers anyway.
VM_NAME="${VM_NAME:-case-poc}"
INGRESS_IP="${INGRESS_IP:-$(multipass exec "$VM_NAME" -- hostname -I | tr -d '\r' | awk '{print $1}')}"

SUBMISSION_URL="http://$SUBMISSION_HOST"
MANAGEMENT_URL="http://$MANAGEMENT_HOST"
KEYCLOAK_URL="http://$KEYCLOAK_HOST"
curl() {
  command curl --resolve "$SUBMISSION_HOST:80:$INGRESS_IP" \
               --resolve "$MANAGEMENT_HOST:80:$INGRESS_IP" \
               --resolve "$KEYCLOAK_HOST:80:$INGRESS_IP" "$@"
}

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Password-grant login against the case-poc realm (demo users are fixtures
# of the checked-in realm import; see deploy/helm/.../files/case-poc-realm.json).
token_for() {
  curl -sf -X POST "$KEYCLOAK_URL/realms/case-poc/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=management-api \
    -d "username=$1" -d "password=$2" | jq -r .access_token
}

say "0. OIDC: fetch tokens from Keycloak ($KEYCLOAK_URL, realm case-poc)"
STAFF_TOKEN=$(token_for staff staff-password)
INTERN_TOKEN=$(token_for intern intern-password)
[ -n "$STAFF_TOKEN" ] && [ "$STAFF_TOKEN" != "null" ] || fail "no staff token"
echo "tokens acquired for staff (role case-manager) and intern (no role)"

say "0a. Identity checks: management API without token -> 401, without role -> 403"
code_no_token=$(curl -s -o /dev/null -w '%{http_code}' "$MANAGEMENT_URL/api/cases?status=open")
code_intern=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $INTERN_TOKEN" "$MANAGEMENT_URL/api/cases?status=open")
echo "no token: $code_no_token, intern: $code_intern"
[ "$code_no_token" = "401" ] || fail "expected 401 without token, got $code_no_token"
[ "$code_intern" = "403" ] || fail "expected 403 for intern, got $code_intern"

mcurl() { curl -H "Authorization: Bearer $STAFF_TOKEN" "$@"; }

say "1. Reporter submits an anonymous case (POST $SUBMISSION_URL/api/cases)"
created=$(curl -sf -X POST "$SUBMISSION_URL/api/cases" \
  -H 'Content-Type: application/json' \
  -d '{"message":"k8s demo: anonymous report submitted via ingress"}')
echo "$created" | jq .
case_id=$(echo "$created" | jq -r .caseId)
token=$(echo "$created" | jq -r .accessToken)

say "2. Management (staff) sees the case (GET $MANAGEMENT_URL/api/cases?status=open)"
for i in $(seq 1 20); do
  if mcurl -sf "$MANAGEMENT_URL/api/cases?status=open" | jq -e --arg c "$case_id" 'map(select(.caseId==$c)) | length == 1' >/dev/null; then
    break
  fi
  sleep 1
done
mcurl -sf "$MANAGEMENT_URL/api/cases/$case_id" | jq .

say "3. Management replies (POST $MANAGEMENT_URL/api/cases/$case_id/reply)"
mcurl -sf -X POST "$MANAGEMENT_URL/api/cases/$case_id/reply" \
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

say "6. Management sees the full thread (reply author = preferred_username)"
for i in $(seq 1 20); do
  if mcurl -sf "$MANAGEMENT_URL/api/cases/$case_id" | jq -e '.messages | length >= 3' >/dev/null; then
    break
  fi
  sleep 1
done
mcurl -sf "$MANAGEMENT_URL/api/cases/$case_id" | jq .

say "DEMO OK: case $case_id travelled reporter -> management -> reporter -> management through Artemis + PostgreSQL on k3s, management access gated by Keycloak OIDC"
