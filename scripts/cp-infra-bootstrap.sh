#!/usr/bin/env bash
#
# Seeds the internal GitLab + Harbor on the control-plane VM (one-time, but
# idempotent) after deploy/vm/ansible/site.yml started them:
#
#   - waits until GitLab finished booting (minutes on first start)
#   - seeds the API token from /opt/case-poc/infra.env as a root PAT
#   - creates the public project root/bachelor-thesis-artefact (public =
#     anonymous git-over-http, so Argo CD needs no repo credential)
#   - creates the public Harbor project case-poc (anonymous pulls for the
#     cluster's containerd; pushes authenticate as admin)
#
# Run inside the control-plane VM as root (repo mounted at /repo):
#
#   multipass exec case-poc-cp -- sudo bash /repo/scripts/cp-infra-bootstrap.sh
#
# Afterwards: scripts/gitops-push.sh publishes the repo into GitLab, and
# scripts/images-publish.sh builds/pushes the service images into Harbor.
set -euo pipefail

ENV_FILE="${ENV_FILE:-/opt/case-poc/infra.env}"
GITLAB_URL="http://127.0.0.1:8929"
HARBOR_URL="http://127.0.0.1:8082"

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

echo "==> Waiting for GitLab to become healthy (first boot takes several minutes)"
for i in $(seq 1 60); do
  if docker exec poc-gitlab /opt/gitlab/bin/gitlab-healthcheck --fail --max-time 10 >/dev/null 2>&1; then
    break
  fi
  [ "$i" = 60 ] && { echo "GitLab did not become healthy"; exit 1; }
  sleep 15
done
echo "GitLab is up"

echo "==> Seeding the root API token (idempotent)"
docker exec -e GL_TOKEN="$GITLAB_API_TOKEN" poc-gitlab gitlab-rails runner '
  user = User.find_by_username("root")
  unless PersonalAccessToken.find_by_token(ENV["GL_TOKEN"])
    t = user.personal_access_tokens.build(
      scopes: [:api, :write_repository],
      name: "case-poc-bootstrap",
      expires_at: 1.year.from_now)
    t.set_token(ENV["GL_TOKEN"])
    t.save!
  end
'

api() { curl -sf -H "PRIVATE-TOKEN: $GITLAB_API_TOKEN" "$@"; }

echo "==> Ensuring public project root/bachelor-thesis-artefact"
if ! api "$GITLAB_URL/api/v4/projects/root%2Fbachelor-thesis-artefact" >/dev/null 2>&1; then
  api -X POST "$GITLAB_URL/api/v4/projects" \
    -d "name=bachelor-thesis-artefact" -d "visibility=public" \
    -d "initialize_with_readme=false" >/dev/null
  echo "created"
else
  echo "exists"
fi

echo "==> Ensuring public Harbor project case-poc"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$HARBOR_ADMIN_PASSWORD" \
  -X POST "$HARBOR_URL/api/v2.0/projects" \
  -H 'Content-Type: application/json' \
  -d '{"project_name":"case-poc","metadata":{"public":"true"}}')
case "$code" in
  201) echo "created" ;;
  409) echo "exists" ;;
  *)   echo "Harbor project creation failed (HTTP $code)"; exit 1 ;;
esac

echo "==> Done. GitLab: $GITLAB_URL (root)  Harbor: $HARBOR_URL (admin)"
echo "    Push the repo:   bash scripts/gitops-push.sh   (host)"
echo "    Publish images:  bash scripts/images-publish.sh  (host)"
