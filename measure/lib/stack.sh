# Platform abstraction for the SRQ3 comparison: the same lifecycle verbs
# (deploy / upgrade / rollback / verify / teardown) and the same uniform
# ready criterion (wait_app_ready in common.sh) for all three platforms.
# Timing is done by the callers around these verbs.
#
# Requires common.sh to be sourced first.

COMPOSE_FILE="/repo/measure/compose/docker-compose.yml"
PODMAN_INFRA="/repo/measure/podman/infra.yaml"
PODMAN_APP_TPL="/repo/measure/podman/app.yaml.tpl"
K3S_NS="measure"
K3S_RELEASE="measure"
K3S_CHART="/repo/deploy/helm/anonymous-case-poc"
K3S_FULLNAME="measure-anonymous-case-poc"

BASE_TAG="${BASE_TAG:-2.0.0}"
UPGRADE_TAG="${UPGRADE_TAG:-2.0.1}"

# in-VM shell helpers. multipass exec does NOT quote arguments — the remote
# shell re-parses the joined words, so `bash -c "<string>"` breaks on any
# space/newline/redirect. Scripts are therefore piped via stdin (bash -s),
# which preserves them byte-for-byte and keeps set -e semantics.
vsh() { local vm="$1"; shift; printf 'set -e\n%s\n' "$1" | mp exec "$vm" -- sudo bash -s; }
eng() { vsh "$ENGINES_VM" "$1"; }
k3s() { vsh "$K3S_VM" "$1"; }

platform_vm() { case "$1" in compose|podman) echo "$ENGINES_VM" ;; k3s) echo "$K3S_VM" ;; esac; }

# stack_urls <platform>: sets SUB_URL/MGM_URL/KC_URL and (k3s) *_HOST headers
stack_urls() {
  local ip
  case "$1" in
    compose|podman)
      ip=$(vm_ip "$ENGINES_VM")
      SUB_URL="http://$ip:8080"; MGM_URL="http://$ip:8081"; KC_URL="http://$ip:8180"
      SUB_HOST=""; MGM_HOST=""; KC_HOST=""
      ;;
    k3s)
      ip=$(vm_ip "$K3S_VM")
      SUB_URL="http://$ip"; MGM_URL="http://$ip"; KC_URL="http://$ip"
      SUB_HOST="submission.measure.localtest.me"
      MGM_HOST="management.measure.localtest.me"
      KC_HOST="keycloak.measure.localtest.me"
      ;;
  esac
}

K3S_HELM_SET="--set hardenDefaultServiceAccount=false \
--set ingress.submissionHost=submission.measure.localtest.me \
--set ingress.managementHost=management.measure.localtest.me \
--set ingress.keycloakHost=keycloak.measure.localtest.me"

# one-time per-sequence preparation (namespace, secrets, argo quiesced).
# The two engines cohabit the VM, so each platform's prepare quiesces the
# other engine: dockerd is stopped for podman runs (and its FORWARD-DROP
# iptables policy reset, which would drop new inbound connections DNATed to
# netavark's bridge — the podman hostPorts would be unreachable from the
# host); starting docker back re-asserts its own policy.
stack_prepare() {
  case "$1" in
    compose)
      eng "systemctl start docker >/dev/null 2>&1 || true
           docker compose -f $COMPOSE_FILE down -v --remove-orphans >/dev/null 2>&1 || true"
      ;;
    podman)
      # config fixtures must live on a real filesystem: podman's hostPath
      # statfs check fails on the multipass /repo mount (sshfs/9p)
      eng "podman kube down $PODMAN_INFRA >/dev/null 2>&1 || true
           [ -f /tmp/measure-app.yaml ] && podman kube down /tmp/measure-app.yaml >/dev/null 2>&1 || true
           podman volume rm measure-pgdata --force >/dev/null 2>&1 || true
           rm -rf /opt/measure/infra && mkdir -p /opt/measure/infra
           cp -r /repo/infra/artemis /repo/infra/postgres /repo/infra/keycloak /opt/measure/infra/
           systemctl stop docker.socket docker >/dev/null 2>&1 || true
           iptables -P FORWARD ACCEPT"
      ;;
    k3s)
      k3s "bash /repo/measure/vm/k3s-quiesce.sh quiesce >/dev/null"
      k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
           kubectl delete ns $K3S_NS --ignore-not-found --wait=true >/dev/null 2>&1
           kubectl create ns $K3S_NS >/dev/null
           bash /repo/scripts/secrets-bootstrap.sh $K3S_NS >/dev/null"
      ;;
  esac
}

# stack_deploy <platform> <tag> — issue the install command (blocking until
# the platform's own completion signal; the HTTP-ready wait is the caller's)
stack_deploy() {
  local tag="$2"
  case "$1" in
    compose) eng "TAG=$tag docker compose -f $COMPOSE_FILE up -d --quiet-pull >/dev/null 2>&1" ;;
    podman)
      eng "sed 's/__TAG__/$tag/g' $PODMAN_APP_TPL > /tmp/measure-app.yaml
           podman kube play --network measure-net $PODMAN_INFRA >/dev/null
           podman kube play --network measure-net /tmp/measure-app.yaml >/dev/null"
      ;;
    k3s)
      k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
           helm upgrade --install $K3S_RELEASE $K3S_CHART -n $K3S_NS $K3S_HELM_SET \
             --set images.submission.tag=$tag --set images.management.tag=$tag \
             --wait --timeout 10m >/dev/null"
      ;;
  esac
}

# stack_upgrade <platform> <tag> — change only the two service images
stack_upgrade() {
  local tag="$2"
  case "$1" in
    compose) eng "TAG=$tag docker compose -f $COMPOSE_FILE up -d >/dev/null 2>&1" ;;
    podman)
      # no rolling-update primitive: --replace tears down and recreates the
      # two app pods (measured downtime is the platform's genuine behaviour)
      eng "sed 's/__TAG__/$tag/g' $PODMAN_APP_TPL > /tmp/measure-app.yaml
           podman kube play --network measure-net --replace /tmp/measure-app.yaml >/dev/null"
      ;;
    k3s)
      k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
           helm upgrade $K3S_RELEASE $K3S_CHART -n $K3S_NS $K3S_HELM_SET \
             --set images.submission.tag=$tag --set images.management.tag=$tag \
             --wait --timeout 10m >/dev/null"
      ;;
  esac
}

# stack_rollback <platform> — return to BASE_TAG / helm revision 1
stack_rollback() {
  case "$1" in
    compose|podman) stack_upgrade "$1" "$BASE_TAG" ;;
    k3s) k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
              helm rollback $K3S_RELEASE 1 -n $K3S_NS --wait --timeout 10m >/dev/null" ;;
  esac
}

# stack_verify_tag <platform> <tag> — the running service containers report
# the expected image tag (fails the measurement if not)
stack_verify_tag() {
  local tag="$2" imgs
  case "$1" in
    compose)
      imgs=$(eng "docker inspect -f '{{.Config.Image}}' measure-submission-service measure-management-service")
      ;;
    podman)
      imgs=$(eng "podman inspect -f '{{.ImageName}}' submission-service-submission-service management-service-management-service")
      ;;
    k3s)
      imgs=$(k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                  kubectl -n $K3S_NS get pods -l 'app.kubernetes.io/name in (submission-service,management-service)' \
                    --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.spec.containers[0].image}{\"\n\"}{end}'")
      ;;
  esac
  [ "$(grep -c ":$tag" <<<"$imgs")" -eq 2 ] || die "expected 2 containers on :$tag, got: $(tr '\n' ' ' <<<"$imgs")"
}

stack_teardown() {
  case "$1" in
    compose) eng "docker compose -f $COMPOSE_FILE down -v --remove-orphans >/dev/null 2>&1 || true" ;;
    podman)
      eng "podman kube down /tmp/measure-app.yaml >/dev/null 2>&1 || true
           podman kube down $PODMAN_INFRA >/dev/null 2>&1 || true
           podman volume rm measure-pgdata --force >/dev/null 2>&1 || true"
      ;;
    k3s)
      k3s "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
           helm uninstall $K3S_RELEASE -n $K3S_NS >/dev/null 2>&1 || true
           kubectl delete ns $K3S_NS --ignore-not-found --wait=true >/dev/null 2>&1 || true"
      ;;
  esac
}

# stack_ready <platform> [timeout] — uniform end state; echoes elapsed ms
stack_ready() {
  stack_urls "$1"
  wait_app_ready "$SUB_URL" "$MGM_URL" "$KC_URL" "${2:-600}" "$SUB_HOST" "$MGM_HOST" "$KC_HOST"
}
