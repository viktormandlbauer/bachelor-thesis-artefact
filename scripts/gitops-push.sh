#!/usr/bin/env bash
#
# Publishes the local repo state to the internal GitLab on the control-plane
# VM — the GitOps source Argo CD watches (deploy/argocd/* points at
# root/bachelor-thesis-artefact there). Pushing a branch IS the deployment
# mechanism: Argo CD picks up the new revision within its poll interval.
#
# Run on the host (macOS terminal or Git Bash on Windows):
#
#   bash scripts/gitops-push.sh [branch]   # default: current branch
#
# Reaches GitLab via the host-network bridge :18929 (the docker-published
# :8929 sits behind the k3s-blocked FORWARD path, like every compose port on
# that VM — see infra/cp-bridges.compose.yaml). Authenticates with the
# provision-time API token from the VM (never in git).
set -euo pipefail

CP_NAME="${CP_NAME:-case-poc-cp}"
BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"

mp() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' multipass "$@"; }

CP_IP="$(mp exec "$CP_NAME" -- hostname -I | tr -d '\r' | awk '{print $1}')"
# Read via a VM-side helper: multipass exec on Windows loses quoting on
# multi-word `sh -c` arguments, so the sourcing must happen in a script file.
TOKEN="$(mp exec "$CP_NAME" -- sudo bash /repo/scripts/infra-env-value.sh GITLAB_API_TOKEN | tr -d '\r')"
[ -n "$TOKEN" ] || { echo "no GITLAB_API_TOKEN on $CP_NAME (run scripts/cp-infra-bootstrap.sh first)"; exit 1; }

echo "==> Pushing $BRANCH to the internal GitLab ($CP_NAME @ $CP_IP)"
git push "http://oauth2:$TOKEN@$CP_IP:18929/root/bachelor-thesis-artefact.git" "$BRANCH"
echo "==> Done. Argo CD will sync the new revision of $BRANCH."
