# Kubernetes POC — day-2 usage

How to interact with a **running** POC environment. For bring-up from scratch,
prerequisites and the security rationale see [k8s-poc.md](k8s-poc.md); for
teardown see its last section. All commands run on the host from the repo
root unless stated otherwise.

```text
you (host)
├── multipass            -> VM lifecycle (start/stop/shell)
├── kubectl --kubeconfig .vm-kubeconfig.yaml   -> cluster API
├── curl --resolve ...   -> app API through the Traefik ingress (port 80)
├── git push (phase2)    -> deployment (Argo CD pulls from GitHub)
└── port-forward         -> Argo CD UI (8443), Artemis console (8161)
```

## VM lifecycle

```bash
multipass stop case-poc      # park the VM (k3s state survives: etcd + PV)
multipass start case-poc     # resume; k3s is a systemd unit, comes back on boot
multipass shell case-poc     # shell inside the VM (repo mounted at /repo)
multipass info case-poc      # state + current IP
```

The VM **IP can change across restarts**. Everything below that talks to the
cluster directly depends on it; after a restart re-run

```bash
bash scripts/vm-up.sh        # idempotent: re-applies the playbook and
                             # re-exports .vm-kubeconfig.yaml with the new IP
```

## Cluster access (kubectl)

`scripts/vm-up.sh` exports the admin kubeconfig to `.vm-kubeconfig.yaml`
(gitignored, server rewritten to the VM IP — TLS verification holds because
the IP is in the serving-cert SANs).

```bash
export KUBECONFIG=$PWD/.vm-kubeconfig.yaml     # or pass --kubeconfig each time

kubectl get pods -A                            # everything
kubectl -n case-poc get pods                   # the application
kubectl -n case-poc logs deploy/case-poc-anonymous-case-poc-submission -f
kubectl -n case-poc logs deploy/case-poc-anonymous-case-poc-management -f
kubectl -n case-poc describe pod <pod>         # scheduling/PSS/probe issues
kubectl -n case-poc get events --sort-by=.lastTimestamp
```

Keep in mind the guardrails the POC deliberately enforces: the `case-poc`
namespace is **restricted PSS** (no privileged debug pods) and has
**deny-by-default NetworkPolicies** — `kubectl port-forward` and `exec` still
work (they go through the API server, not the pod network).

## Using the application (HTTP API)

Traefik listens on **port 80 of the VM** and routes by `Host` header. The
hostnames resolve to `127.0.0.1` publicly (`localtest.me`), so pin the VM IP
with `--resolve` (avoids router DNS-rebind filtering, works on macOS and Git
Bash):

```bash
VM_IP=$(multipass exec case-poc -- hostname -I | awk '{print $1}')
alias capp='curl --resolve submission.localtest.me:80:$VM_IP --resolve management.localtest.me:80:$VM_IP --resolve keycloak.localtest.me:80:$VM_IP'
```

The management API is OIDC-protected (Phase 2). Fetch a bearer token for the
demo user `staff` (realm fixture with the `case-manager` role) from the
in-cluster Keycloak:

```bash
STAFF_TOKEN=$(capp -s -X POST http://keycloak.localtest.me/realms/case-poc/protocol/openid-connect/token \
  -d grant_type=password -d client_id=management-api \
  -d username=staff -d password=staff-password | jq -r .access_token)
```

The full happy path in one command (also the smoke test after any change):

```bash
bash scripts/k8s-demo.sh
```

Endpoints (reporter side = submission, case-handler side = management):

| Actor | Call | Auth |
| --- | --- | --- |
| Reporter | `POST http://submission.localtest.me/api/cases` `{"message": "..."}` | — (returns `caseId` + one-time `accessToken`) |
| Reporter | `GET  http://submission.localtest.me/api/cases/{caseId}` | header `X-Case-Token: <accessToken>` |
| Reporter | `POST http://submission.localtest.me/api/cases/{caseId}/messages` `{"message": "..."}` | header `X-Case-Token: <accessToken>` |
| Management | `GET  http://management.localtest.me/api/cases?status=open` | header `Authorization: Bearer $STAFF_TOKEN` (role `case-manager`; no token → 401, no role → 403) |
| Management | `GET  http://management.localtest.me/api/cases/{caseId}` | header `Authorization: Bearer $STAFF_TOKEN` |
| Management | `POST http://management.localtest.me/api/cases/{caseId}/reply` `{"message": "..."}` | header `Authorization: Bearer $STAFF_TOKEN` |

Example session:

```bash
resp=$(capp -s -X POST http://submission.localtest.me/api/cases \
  -H 'Content-Type: application/json' -d '{"message":"hello"}')
case_id=$(echo "$resp" | jq -r .caseId)
token=$(echo "$resp" | jq -r .accessToken)        # shown only once

capp -s -H "Authorization: Bearer $STAFF_TOKEN" \
  "http://management.localtest.me/api/cases?status=open" | jq .
capp -s -X POST -H "Authorization: Bearer $STAFF_TOKEN" \
  "http://management.localtest.me/api/cases/$case_id/reply" \
  -H 'Content-Type: application/json' -d '{"message":"we are on it"}' | jq .
capp -s "http://submission.localtest.me/api/cases/$case_id" \
  -H "X-Case-Token: $token" | jq .
```

Messages travel asynchronously through Artemis, so a reply may take a moment
to appear on the other side (the demo script polls for exactly this reason).

## Deploying changes (GitOps)

Argo CD auto-syncs everything under `deploy/argocd/apps/` and the Helm chart
from **GitHub branch `phase2`** — the working tree and even a local commit
are *not* enough; **pushing is the deployment action**:

```bash
# chart or Application change
vim deploy/helm/anonymous-case-poc/values.yaml
git commit -am "..." && git push        # Argo CD picks it up (poll ≤ 3 min)

# watch it land
kubectl -n argocd get applications      # SYNC/HEALTH columns
kubectl -n case-poc get pods -w
```

Code changes need a new image first — images are local to the node's
containerd (no registry), so the tag must move for the kubelet to see a
change (`imagePullPolicy: IfNotPresent`):

```bash
bash scripts/images-import.sh 2.0.1     # build both services, import into k3s
vim deploy/helm/anonymous-case-poc/values.yaml   # bump images.*.tag to 2.0.1
git commit -am "bump service images to 2.0.1" && git push
```

To force an immediate refresh instead of waiting for the poll:

```bash
kubectl -n argocd annotate application anonymous-case-poc \
  argocd.argoproj.io/refresh=normal --overwrite
```

Don't `kubectl apply` into `case-poc` by hand — Argo CD's `selfHeal` reverts
manual drift; that is the point of the setup.

## Argo CD UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8443:443
# https://localhost:8443  (self-signed cert)
# user: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

The UI is intentionally not exposed through the ingress; the port-forward is
the only path.

## Artemis (broker console, DLQ)

```bash
kubectl -n case-poc port-forward svc/case-poc-anonymous-case-poc-artemis 8161:8161
# http://localhost:8161/console — login artemis / <generated password>:
kubectl -n case-poc get secret case-poc-artemis-auth \
  -o jsonpath='{.data.ARTEMIS_PASSWORD}' | base64 -d; echo
```

Look under *Queues* for depths and the dead-letter queue; the port-forward
deliberately bypasses the deny-by-default NetworkPolicies, which is why the
console is reachable this way and no other.

## Verifying the security posture

After any cluster-level change (k3s config, kube-system patches, upgrades):

```bash
multipass exec case-poc -- sudo bash /repo/scripts/kube-bench-run.sh
# writes docs/reports/kube-bench-<date>.txt on the host; exits non-zero on FAIL
```

Run it with the workload deployed — 5.1.6 (no SA token automounts) must hold
for **every** pod in the cluster, see k8s-poc.md.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `kubectl` connection refused / TLS error | VM IP changed after restart — re-run `bash scripts/vm-up.sh` |
| App pod `ErrImagePull`/`ImagePullBackOff` | image tag not in containerd (the registry pull it falls back to cannot succeed) — `bash scripts/images-import.sh <tag>` |
| App `OutOfSync` but nothing happens | change not **pushed** to `origin/phase2`, or force a refresh (annotation above) |
| Management API answers 401/403 | token missing/expired (they are short-lived — re-fetch `$STAFF_TOKEN`) or user lacks the `case-manager` role |
| Demo fails on step 1 | ingress not up or wrong IP — `kubectl -n kube-system get pods`, check `traefik`; re-run demo (it re-resolves the IP) |
| Pod rejected on create | restricted PSS violation — `kubectl -n case-poc get events` shows the exact field |
| Reply never arrives | broker issue — check Artemis pod logs and the DLQ via the console |
| kube-bench suddenly FAILs after k3s upgrade | bundled manifests were re-applied — see the upgrade note in k8s-poc.md, re-run `scripts/harden-kube-system.sh` |
