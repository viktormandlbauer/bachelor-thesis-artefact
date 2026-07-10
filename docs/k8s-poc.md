# Kubernetes POC — CIS-hardened k3s + Argo CD GitOps

This stage runs the Phase-2 application (submission-service, management-service,
ActiveMQ Artemis, PostgreSQL, Keycloak) on a [k3s](https://k3s.io) cluster with
a **dedicated control-plane VM** plus worker VM(s) that

* **passes [kube-bench](https://github.com/aquasecurity/kube-bench) with 0 failed
  checks** (profile `k3s-cis-1.9`, run with the full workload deployed), and
* is **versioned with Argo CD**: the cluster state is defined by this git
  repository; the Helm chart and the Argo CD `Application` manifests are the
  deployment mechanism, and
* is **validated against the thesis requirements catalogue**: every
  automatable acceptance criterion (functional, operational, governance) is
  executed by `scripts/validate-requirements.sh` — method in
  [requirements-validation.md](requirements-validation.md), evidence reports
  under `docs/reports/`.

Day-2 interaction with the running environment (kubectl access, app API,
deploying changes, consoles, troubleshooting) is documented in
[k8s-poc-usage.md](k8s-poc-usage.md).

The architectural split matters for the thesis comparison: the **cluster runs
ONLY the application stack** (submission + management + Artemis, on the
worker nodes), while the supporting infra — monitoring (SigNoz), identity
(Keycloak), persistence (PostgreSQL), the GitOps source (GitLab) and the
image registry (Harbor) — is **deployed compose-wise on the control-plane
VM**. The compose/podman variants of the measurement track run the identical
three-container app stack against the same kind of VM-level infra, so the
platform of the app stack is the only variable
([measurement-comparison.md](measurement-comparison.md)).

```text
Host (macOS or Windows 11; multipass + Docker only)
├── Multipass VM "case-poc-cp"   -> Ubuntu 24.04 — the DEDICATED CONTROL-PLANE VM
│   ├── Ansible controller       -> repo mounted at /repo; scripts/vm-up.sh runs
│   │                               deploy/vm/ansible/site.yml from inside this VM
│   ├── docker compose           -> ALL supporting infra, compose-wise on this VM:
│   │                               SigNoz (monitoring, OTLP :4317, UI :3301),
│   │                               Keycloak (:8180), PostgreSQL (:5432),
│   │                               GitLab CE (:8929 — the GitOps source),
│   │                               Harbor (:8082 — the image registry),
│   │                               + host-network bridges (infra/cp-bridges.compose.yaml:
│   │                                 :14317/:15432/:18180/:18929/:18082 — the only
│   │                                 path cluster pods can take to compose ports)
│   └── k3s server v1.36.2+k3s1  -> hardened per deploy/cluster/k3s/ (embedded etcd)
│       ├── kube-system          -> traefik ingress, coredns, ... (token-automount hardened)
│       ├── argocd               -> Argo CD v3.4.4, namespace-scoped, non-wildcard RBAC;
│       │                           syncs from the INTERNAL GitLab (Service argocd/gitlab)
│       └── case-poc             -> Helm release "case-poc" of deploy/helm/anonymous-case-poc
│                                   (restricted PSS, deny-by-default NetworkPolicies both
│                                    directions, credentials from bootstrap-generated Secrets;
│                                    postgres/keycloak = selector-less Services -> CP bridges)
└── Multipass VM "case-poc-w1"   -> Ubuntu 24.04, k3s agent (joined via the node token)
    └── case-poc                 -> THE APPLICATION STACK: submission + management +
                                    artemis (images from Harbor via the containerd
                                    mirror; soft affinity for case-poc/role=worker;
                                    traces -> SigNoz)
```

| Pinned component | Version |
|---|---|
| VM guest OS | Ubuntu `24.04` (multipass; provisioned by Ansible run from the control-plane VM) |
| SigNoz (compose, on the control-plane VM) | `v0.129.0` (vendored `infra/signoz/`) |
| k3s (Kubernetes) | `v1.36.2+k3s1` |
| Argo CD | `v3.4.4` (namespace-scoped install) |
| kube-bench | `0.15.6`, benchmark `k3s-cis-1.9` |
| Artemis image | `apache/activemq-artemis:2.44.0` |
| PostgreSQL image | `postgres:17-alpine` |
| Keycloak image | `quay.io/keycloak/keycloak:26.3` (dev mode + declarative realm import) |
| Helm (on the node) | `v3.19.0` (installed by the playbook; used for REQ-F/O validation) |
| GitLab CE (compose, on the control-plane VM) | `18.2.1-ce.0` (internal GitOps source, project `root/bachelor-thesis-artefact`) |
| Harbor (compose, on the control-plane VM) | `v2.13.1` (internal registry, project `case-poc`, http-only on the VM-internal bridge) |
| Service images | `harbor.case-poc.local/case-poc/{submission,management}-service:2.0.0` (GitOps variant; plain-helm variants keep local `case-poc/*` names) |

## Prerequisites

* [Multipass](https://canonical.com/multipass) — the VM manager.
  * On Windows, run the scripts from **Git Bash** and enable mounts once:
    `multipass set local.privileged-mounts=true`.
* Docker (Desktop) — only for building the two service images on the host.
* `curl` + `jq` on the host for the demo script.

Ansible is **not** needed on the host: the **control-plane VM is the Ansible
controller** (which also sidesteps Windows' lack of a native control node).
`scripts/vm-up.sh` wires it all together: it launches the control-plane and
worker VMs (repo mounted at `/repo` in each), installs ansible on the control
plane, generates a controller SSH keypair there and authorizes it on the
workers, writes `deploy/vm/ansible/inventory.ini` (gitignored — control plane
as `ansible_connection=local`, workers by IP), and runs
`deploy/vm/ansible/site.yml` from inside the control-plane VM. Beyond
ansible itself and that keypair, nothing is installed in the VMs other than
what the playbook manages.

Topology knobs (env vars of `scripts/vm-up.sh`): `WORKERS=1` worker count
(`0` = single-node, used by the measurement track), `COMPOSE_INFRA=1` toggle
for the compose-side infra on the control plane, and
`CP_CPUS/CP_MEMORY/CP_DISK` (default 4/8G/40G) resp.
`WORKER_CPUS/WORKER_MEMORY/WORKER_DISK` (default 2/3G/20G).

## Bring-up from scratch

```bash
# 1. Launch the control-plane VM (case-poc-cp) + worker VM(s) (case-poc-w1..N),
#    mount the repo at /repo in each, and provision everything with Ansible
#    run FROM the control-plane VM: hardened k3s server + agents (sysctls,
#    config, file-permission hardening, SA + kube-system hardening, containerd
#    Harbor mirror) and the compose-side infra on the control plane (SigNoz,
#    Keycloak, PostgreSQL, GitLab, Harbor, host-network bridges).
#    Idempotent: re-run to re-apply the playbook.
bash scripts/vm-up.sh

# 2. Prove the CIS baseline (writes docs/reports/kube-bench-<date>.txt on the
#    host through the /repo mount)
multipass exec case-poc-cp -- sudo bash /repo/scripts/kube-bench-run.sh

# 3. Seed the internal GitLab (root API token + public project
#    root/bachelor-thesis-artefact) and Harbor (public project case-poc);
#    idempotent, waits for GitLab's first boot (minutes)
multipass exec case-poc-cp -- sudo bash /repo/scripts/cp-infra-bootstrap.sh

# 4. Publish the repo into the internal GitLab (the GitOps source) and the
#    two service images into Harbor (built on the CP VM, no host Docker needed)
bash scripts/gitops-push.sh
bash scripts/images-publish.sh

# 5. Bootstrap the GitOps control plane (Argo CD + AppProject + root app).
#    Also generates the runtime credentials as in-cluster Secrets
#    (scripts/secrets-bootstrap.sh — nothing secret is stored in git) and
#    publishes the compose infra into the cluster as selector-less Services /
#    EndpointSlices (signoz-collector, postgres, keycloak endpoints in
#    case-poc; gitlab in argocd). Everything below deploy/argocd/apps/ is
#    afterwards synced from the INTERNAL GitLab.
multipass exec case-poc-cp -- sudo bash /repo/scripts/argocd-install.sh

# 6. End-to-end proof through the ingress (OIDC login, 401/403 checks,
#    full two-way case thread; resolves the VM IP itself)
bash scripts/k8s-demo.sh

# 7. Execute the requirements-catalogue acceptance criteria and write the
#    evidence report to docs/reports/requirements-validation-<date>.md
multipass exec case-poc-cp -- sudo bash /repo/scripts/validate-requirements.sh
```

The Argo CD `Application`s track branch `phase2` of the **internal GitLab**
(`repoURL: http://gitlab.argocd.svc.cluster.local/root/bachelor-thesis-artefact.git`
in `deploy/argocd/root-app.yaml` and `deploy/argocd/apps/*.yaml` — the
`gitlab` Service in the argocd namespace fronts the control-plane GitLab via
its bridge port); switch `targetRevision` to `HEAD` once the branch is
merged. Note the bootstrap is two-phase by design: `deploy/argocd/install`
(applied once by hand) creates the control plane and the `case-poc`
namespace/RBAC; everything after that is pulled from git by Argo CD itself —
committing and running `scripts/gitops-push.sh` is the deployment action.

## GitOps layout

```text
deploy/
├── vm/ansible/           # cluster provisioning, run from the control-plane VM
│   ├── ansible.cfg       #   (scripts/vm-up.sh launches VMs + invokes the play)
│   ├── site.yml          #   play 1: CIS-hardened k3s server + compose infra
│   │                     #   play 2: CIS-hardened k3s agents (workers)
│   └── templates/k3s-agent-config.yaml.j2  # agent hardening + join parameters
├── cluster/k3s/          # server-node hardening, copied by the playbook
│   ├── config.yaml       #   /etc/rancher/k3s/config.yaml (control plane)
│   ├── admission-config.yaml  # PodSecurity "restricted" default + EventRateLimit
│   ├── audit-policy.yaml
│   └── 90-kubelet-sysctl.conf # applied on every node (server + agents)
├── argocd/
│   ├── install/          # kubectl apply -k: Argo CD v3.4.4 + case-poc ns/RBAC
│   ├── projects/case-poc.yaml
│   ├── root-app.yaml     # app-of-apps, applied once by argocd-install.sh
│   └── apps/             # every Application here is auto-synced by root
│       └── anonymous-case-poc.yaml   # this env: images from Harbor,
│                                     # postgres/keycloak external (compose),
│                                     # artemis with the services, otel on
└── helm/anonymous-case-poc/   # the Phase-2 app chart (values pin the images;
                               # secrets only referenced by name, never templated;
                               # postgres.enabled/keycloak.enabled switch between
                               # in-cluster (plain-helm default) and the compose
                               # infra on the control plane (GitOps variant))
```

Access:

* API from the host: `kubectl --kubeconfig .vm-kubeconfig.yaml` — the
  kubeconfig is exported (server rewritten to the control-plane VM IP) by
  `scripts/vm-up.sh`; that IP is in the k3s serving-cert SANs, so TLS
  verification holds.
* App: `http://submission.localtest.me`, `http://management.localtest.me` and
  `http://keycloak.localtest.me` against the **control-plane VM IP** (Traefik's
  svclb listens on every node, so any node IP works; `localtest.me` resolves
  to `127.0.0.1`, so pin the IP with `curl --resolve`, as
  `scripts/k8s-demo.sh` does — that also sidesteps router DNS-rebind
  protection). The management API requires a Keycloak bearer token
  (realm `case-poc`, demo user `staff`); see
  [k8s-poc-usage.md](k8s-poc-usage.md) for the token snippet.
* SigNoz UI (traces of the k8s workloads AND of a compose-run stack):
  `http://<control-plane VM IP>:3301` — SigNoz runs compose-side on the
  control-plane VM; the k8s services export OTLP to it through the
  bootstrap-created `signoz-collector` Service (node IP endpoint, port 4317).
* Compose-side infra on the control-plane VM: Keycloak
  `http://<control-plane VM IP>:8180`, PostgreSQL `<control-plane VM IP>:5432`
  (both from `infra/docker-compose.yml`; the compose app services are NOT
  started there). GitLab `http://<control-plane VM IP>:18929` (user `root`)
  and Harbor `http://<control-plane VM IP>:18082` (user `admin`) — passwords
  live in `/opt/case-poc/infra.env` on the VM (generated at provision time,
  never in git); note the host reaches both through the **bridge** ports, the
  docker-published ports are unreachable behind the k3s FORWARD path.
* Argo CD UI: `kubectl --kubeconfig .vm-kubeconfig.yaml -n argocd port-forward svc/argocd-server 8443:443`,
  login `admin` / `kubectl --kubeconfig .vm-kubeconfig.yaml -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
* Artemis console (DLQ inspection): `kubectl --kubeconfig .vm-kubeconfig.yaml -n case-poc port-forward svc/case-poc-anonymous-case-poc-artemis 8161:8161`
  (port-forward intentionally bypasses the deny-by-default NetworkPolicies).

## How the kube-bench pass is achieved

`scripts/kube-bench-run.sh` runs kube-bench **on the node** (not as a pod):
the k3s profile audits the systemd journal (`journalctl -u k3s`) and files
under `/var/lib/rancher`, which are only reliably visible from the host. The
acceptance evidence is the **control-plane run** (all targets — its own
kubelet covers the node checks); on workers the script runs the `node` target
best-effort (the profile addresses journal unit `k3s`, agents log under
`k3s-agent`), and the workers receive the identical kubelet hardening from
the same playbook. Pass criterion: **0 checks in state FAIL**. WARN entries are the profile's
manual-verification items (secure defaults k3s cannot attest automatically,
RBAC review guidance, PSS/NetworkPolicy adoption — addressed by the
restricted-PSS admission default and the chart's NetworkPolicies).

What the defaults did not cover (everything versioned in this repo):

| Area | Measure |
|---|---|
| Kernel/kubelet (4.2.x) | sysctls in `90-kubelet-sysctl.conf` + `protect-kernel-defaults: true`, `make-iptables-util-chains=true`, `streaming-connection-idle-timeout=5m` |
| API server (1.2.x) | audit logging, `EventRateLimit` + cluster-wide **restricted** PodSecurity via `admission-config.yaml`, `secrets-encryption: true` |
| Datastore | embedded etcd (`cluster-init: true`) — the k3s-cis-1.9 profile audits the etcd files |
| File permissions (1.1.x/4.1.x) | `chmod 600` sweep over k3s TLS/kubeconfig/CNI files in `deploy/vm/ansible/site.yml` (server and agents) |
| 5.1.1/5.1.3 (RBAC) | Argo CD **namespace-scoped** install: no ClusterRoles, no wildcard rules; per-namespace Roles enumerate exactly the kinds the chart deploys (`deploy/argocd/install/case-poc/argocd-rbac.yaml`) |
| 5.1.5 (default SAs) | `automountServiceAccountToken: false` on every namespace's default SA (playbook + versioned SA manifests) |
| 5.1.6 (token mounts) | **No pod automounts SA tokens.** Pods that need the API (Argo CD controller/server, redis' secret-init, coredns, traefik, metrics-server, local-path-provisioner) mount an explicitly **projected, expiring token** instead — `scripts/harden-kube-system.sh` and the kustomize patches under `deploy/argocd/install/argocd/patches/` |

Details worth knowing before re-running:

* **kube-bench evaluates `use_multiple_values` checks per test item across all
  output lines.** The k3s profile whitelists the bundled kube-system
  ServiceAccounts for 5.1.6, but as soon as any other pod exists the whitelist
  item can no longer hold for every line — so this repo makes the bundled
  workloads genuinely compliant instead of relying on the whitelist.
* `harden-kube-system.sh` patches live k3s-managed objects. A k3s **version
  upgrade** re-applies the bundled manifests and re-runs the traefik helm job
  (whose SA has automount disabled) — temporarily revert that SA patch for the
  upgrade, then re-run the script and kube-bench.

## Multipass-specific notes

* The repo is mounted at `/repo` inside **every** cluster VM
  (`scripts/vm-up.sh`), so the in-VM scripts always run against the working
  tree and `kube-bench-run.sh` writes its report straight back to
  `docs/reports/` on the host. On Windows the mounts need
  `multipass set local.privileged-mounts=true` once.
* On Apple Silicon the VMs (and hence k3s, kube-bench, the service images) are
  arm64; every pinned component ships multi-arch images, and
  `kube-bench-run.sh` picks the binary via `dpkg --print-architecture`.
* `multipass stop case-poc-cp case-poc-w1` / `multipass start ...` park and
  resume the cluster; k3s(-agent) are systemd units and come back on boot.
  Durable state (etcd, Artemis journal + Postgres data on local-path PVs, the
  compose volumes) survives on the control-plane VM. The VM IPs can change
  across restarts — re-run `scripts/vm-up.sh` (re-exports
  `.vm-kubeconfig.yaml` and re-points the agents at the current server IP via
  their config template) and `argocd-install.sh` (refreshes the
  `signoz-collector` EndpointSlice with the current node IP); the demo script
  resolves the current IP on every run.
* The host-side scripts wrap `multipass` with `MSYS_NO_PATHCONV=1` so Git
  Bash on Windows does not rewrite VM-side paths like `/repo/...`; host-side
  paths are converted explicitly with `cygpath`.

## Scope notes / known limitations (POC)

* All infrastructure credentials (broker, PostgreSQL superuser + per-service
  logins, Keycloak admin) are generated at bootstrap
  (`scripts/secrets-bootstrap.sh`) and exist only as in-cluster Secrets
  (REQ-G-005). The Keycloak **demo users** (`staff`/`intern`) are checked-in
  realm fixtures — synthetic test identities the 401/403 demo depends on.
* The management API is OIDC-protected (Phase 2): realm `case-poc`, client
  `management-api`, role `case-manager`. Keycloak runs in dev mode with an
  ephemeral H2 store; realm state is declarative (re-imported on every start).
  Production mode (external DB, TLS, strict hostname) is rollout-phase work.
* No TLS on the ingress; Argo CD UI only via port-forward.
* OpenTelemetry export: the chart default stays `otel.enabled=false` (plain-
  helm installs — measurement/validation — have no collector), but the GitOps
  `Application` enables it for this environment. The collector is the
  compose-run SigNoz on the control-plane VM, addressed via the selector-less
  `signoz-collector` Service whose EndpointSlice (node IP) is created by
  `scripts/argocd-install.sh`; the matching egress NetworkPolicy
  (port 4317) is rendered by the chart when otel is enabled.
* Images come from the **internal Harbor** (`scripts/images-publish.sh`
  builds on the CP VM and pushes; every node's containerd resolves
  `harbor.case-poc.local` through `/etc/rancher/k3s/registries.yaml`). Harbor
  runs http-only on the VM-internal bridge port — acceptable for the
  local-only PoC, TLS + a CI pipeline that pushes on merge remain rollout
  work. `scripts/images-import.sh` (registry-less containerd import) stays
  for the plain-helm variants.
* GitLab CE is tuned for the shared 10G infra VM (single puma worker, low
  sidekiq concurrency, bundled monitoring/KAS/registry off) — sized for one
  user and Argo CD's poll, not for team use.

## Teardown

```bash
multipass delete --purge case-poc-cp case-poc-w1   # removes the VMs incl. k3s + data
# or, to keep the VMs but remove k3s:
multipass exec case-poc-cp -- sudo /usr/local/bin/k3s-uninstall.sh
multipass exec case-poc-w1 -- sudo /usr/local/bin/k3s-agent-uninstall.sh
```
