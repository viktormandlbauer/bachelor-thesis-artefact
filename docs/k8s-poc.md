# Kubernetes POC — CIS-hardened k3s + Argo CD GitOps

This stage runs the Phase-2 application (submission-service, management-service,
ActiveMQ Artemis, PostgreSQL, Keycloak) on a single-node [k3s](https://k3s.io)
cluster that

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

```text
Host = Ansible controller (macOS or Windows 11)
├── Docker (Desktop)          -> builds the two service images (scripts/images-import.sh)
├── ansible-playbook          -> provisions the VM over SSH (deploy/vm/ansible/)
└── Multipass VM "case-poc"   -> Ubuntu 24.04
    └── k3s v1.36.2+k3s1      -> hardened per deploy/cluster/k3s/ (embedded etcd)
        ├── kube-system       -> traefik ingress, coredns, ... (token-automount hardened)
        ├── argocd            -> Argo CD v3.4.4, namespace-scoped, non-wildcard RBAC
        └── case-poc          -> Helm release "case-poc" of deploy/helm/anonymous-case-poc
                                 (artemis + postgres + keycloak + submission + management,
                                  restricted PSS, deny-by-default NetworkPolicies both
                                  directions, credentials from bootstrap-generated Secrets)
```

| Pinned component | Version |
|---|---|
| VM guest OS | Ubuntu `24.04` (multipass, provisioned by Ansible from the host) |
| k3s (Kubernetes) | `v1.36.2+k3s1` |
| Argo CD | `v3.4.4` (namespace-scoped install) |
| kube-bench | `0.15.6`, benchmark `k3s-cis-1.9` |
| Artemis image | `apache/activemq-artemis:2.44.0` |
| PostgreSQL image | `postgres:17-alpine` |
| Keycloak image | `quay.io/keycloak/keycloak:26.3` (dev mode + declarative realm import) |
| Helm (on the node) | `v3.19.0` (installed by the playbook; used for REQ-F/O validation) |
| Service images | `case-poc/{submission,management}-service:2.0.0` (local, imported into containerd) |

## Prerequisites

* [Multipass](https://canonical.com/multipass) — the VM manager.
  * On Windows, run the scripts from **Git Bash** and enable mounts once:
    `multipass set local.privileged-mounts=true`.
* [Ansible](https://docs.ansible.com) on the host — the host is the Ansible
  **controller** (`brew install ansible`; on Windows, where a native control
  node is unsupported, run it from WSL or another POSIX environment).
* Docker (Desktop) — only for building the two service images on the host.
* `curl` + `jq` on the host for the demo script.

`scripts/vm-up.sh` wires controller and VM together: it generates a dedicated
SSH keypair (`~/.ssh/multipass-case-poc`), authorizes it for the VM's `ubuntu`
user, writes `deploy/vm/ansible/inventory.ini` (gitignored) with the current
VM IP, and runs the playbook over SSH. Nothing is installed in the VM other
than what the playbook itself manages.

## Bring-up from scratch

```bash
# 1. Launch the multipass VM, mount the repo at /repo, and provision the
#    hardened k3s server with Ansible over SSH (curl/jq/git, sysctls, config,
#    k3s itself, file-permission hardening, SA + kube-system hardening).
#    Idempotent: re-run to re-apply the playbook.
bash scripts/vm-up.sh

# 2. Prove the CIS baseline (writes docs/reports/kube-bench-<date>.txt on the
#    host through the /repo mount)
multipass exec case-poc -- sudo bash /repo/scripts/kube-bench-run.sh

# 3. Build the Phase-1 service images and import them into k3s containerd
#    (Docker running on the host)
bash scripts/images-import.sh

# 4. Bootstrap the GitOps control plane (Argo CD + AppProject + root app).
#    Also generates the runtime credentials as in-cluster Secrets
#    (scripts/secrets-bootstrap.sh — nothing secret is stored in git).
#    Everything below deploy/argocd/apps/ is afterwards synced from GitHub.
multipass exec case-poc -- sudo bash /repo/scripts/argocd-install.sh

# 5. End-to-end proof through the ingress (OIDC login, 401/403 checks,
#    full two-way case thread; resolves the VM IP itself)
bash scripts/k8s-demo.sh

# 6. Execute the requirements-catalogue acceptance criteria and write the
#    evidence report to docs/reports/requirements-validation-<date>.md
multipass exec case-poc -- sudo bash /repo/scripts/validate-requirements.sh
```

The Argo CD `Application`s track branch `phase2`
(`deploy/argocd/root-app.yaml`, `deploy/argocd/apps/*.yaml`); switch
`targetRevision` to `HEAD` once the branch is merged. Note the bootstrap is
two-phase by design: `deploy/argocd/install` (applied once by hand) creates the
control plane and the `case-poc` namespace/RBAC; everything after that is
pulled from git by Argo CD itself — pushing a change to the chart or an
`Application` manifest is the deployment action.

## GitOps layout

```text
deploy/
├── vm/ansible/           # VM provisioning from the host (scripts/vm-up.sh)
│   ├── ansible.cfg
│   └── k3s-playbook.yml  #   CIS-hardened k3s install, applied over SSH
├── cluster/k3s/          # node-level hardening, copied by the playbook
│   ├── config.yaml       #   /etc/rancher/k3s/config.yaml
│   ├── admission-config.yaml  # PodSecurity "restricted" default + EventRateLimit
│   ├── audit-policy.yaml
│   └── 90-kubelet-sysctl.conf
├── argocd/
│   ├── install/          # kubectl apply -k: Argo CD v3.4.4 + case-poc ns/RBAC
│   ├── projects/case-poc.yaml
│   ├── root-app.yaml     # app-of-apps, applied once by argocd-install.sh
│   └── apps/             # every Application here is auto-synced by root
│       └── anonymous-case-poc.yaml
└── helm/anonymous-case-poc/   # the Phase-2 app chart (values pin the images;
                               # secrets only referenced by name, never templated)
```

Access:

* API from the host: `kubectl --kubeconfig .vm-kubeconfig.yaml` — the
  kubeconfig is exported (server rewritten to the VM IP) by `scripts/vm-up.sh`;
  the VM IP is in the k3s serving-cert SANs, so TLS verification holds.
* App: `http://submission.localtest.me`, `http://management.localtest.me` and
  `http://keycloak.localtest.me` against the **VM IP** (Traefik on port 80;
  `localtest.me` resolves to `127.0.0.1`, so pin the IP with `curl --resolve`,
  as `scripts/k8s-demo.sh` does — that also sidesteps router DNS-rebind
  protection). The management API requires a Keycloak bearer token
  (realm `case-poc`, demo user `staff`); see
  [k8s-poc-usage.md](k8s-poc-usage.md) for the token snippet.
* Argo CD UI: `kubectl --kubeconfig .vm-kubeconfig.yaml -n argocd port-forward svc/argocd-server 8443:443`,
  login `admin` / `kubectl --kubeconfig .vm-kubeconfig.yaml -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
* Artemis console (DLQ inspection): `kubectl --kubeconfig .vm-kubeconfig.yaml -n case-poc port-forward svc/case-poc-anonymous-case-poc-artemis 8161:8161`
  (port-forward intentionally bypasses the deny-by-default NetworkPolicies).

## How the kube-bench pass is achieved

`scripts/kube-bench-run.sh` runs kube-bench **on the node** (not as a pod):
the k3s profile audits the systemd journal (`journalctl -u k3s`) and files
under `/var/lib/rancher`, which are only reliably visible from the host. Pass
criterion: **0 checks in state FAIL**. WARN entries are the profile's
manual-verification items (secure defaults k3s cannot attest automatically,
RBAC review guidance, PSS/NetworkPolicy adoption — addressed by the
restricted-PSS admission default and the chart's NetworkPolicies).

What the defaults did not cover (everything versioned in this repo):

| Area | Measure |
|---|---|
| Kernel/kubelet (4.2.x) | sysctls in `90-kubelet-sysctl.conf` + `protect-kernel-defaults: true`, `make-iptables-util-chains=true`, `streaming-connection-idle-timeout=5m` |
| API server (1.2.x) | audit logging, `EventRateLimit` + cluster-wide **restricted** PodSecurity via `admission-config.yaml`, `secrets-encryption: true` |
| Datastore | embedded etcd (`cluster-init: true`) — the k3s-cis-1.9 profile audits the etcd files |
| File permissions (1.1.x/4.1.x) | `chmod 600` sweep over k3s TLS/kubeconfig/CNI files in `deploy/vm/ansible/k3s-playbook.yml` |
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

* The repo is mounted at `/repo` inside the VM (`scripts/vm-up.sh`), so the
  in-VM scripts always run against the working tree and `kube-bench-run.sh`
  writes its report straight back to `docs/reports/` on the host. On Windows
  the mount needs `multipass set local.privileged-mounts=true` once.
* On Apple Silicon the VM (and hence k3s, kube-bench, the service images) is
  arm64; every pinned component ships multi-arch images, and
  `kube-bench-run.sh` picks the binary via `dpkg --print-architecture`.
* `multipass stop case-poc` / `multipass start case-poc` park and resume the
  cluster; k3s is a systemd unit and comes back on boot. Durable state (etcd,
  Artemis journal on the local-path PV) survives. The VM IP can change across
  restarts — re-run `scripts/vm-up.sh` to re-export `.vm-kubeconfig.yaml`
  (the demo script resolves the current IP on every run).
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
* OpenTelemetry export is disabled by default (`otel.enabled=false`) because
  the cluster runs no collector; point `otel.endpoint` at an OTLP gRPC
  collector to restore tracing (and add a matching egress NetworkPolicy).
* Images are imported into containerd (`scripts/images-import.sh`); a
  registry + CI pipeline is future work (see application-architecture/future.md
  and the REQ-F-010 justification in docs/requirements-validation.md).

## Teardown

```bash
multipass delete --purge case-poc   # removes the VM including k3s + data
# or, to keep the VM but remove k3s:
multipass exec case-poc -- sudo /usr/local/bin/k3s-uninstall.sh
```
