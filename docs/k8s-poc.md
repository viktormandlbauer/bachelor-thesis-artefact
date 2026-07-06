# Kubernetes POC — CIS-hardened k3s + Argo CD GitOps

This stage moves the Phase-1 application (submission-service, management-service,
ActiveMQ Artemis) onto a single-node [k3s](https://k3s.io) cluster that

* **passes [kube-bench](https://github.com/aquasecurity/kube-bench) with 0 failed
  checks** (profile `k3s-cis-1.9`, run with the full workload deployed), and
* is **versioned with Argo CD**: the cluster state is defined by this git
  repository; the Helm chart and the Argo CD `Application` manifests are the
  deployment mechanism.

```text
Windows 11 host
├── Docker Desktop            -> builds the two service images (scripts/images-import.sh)
└── WSL2 Ubuntu (systemd)
    └── k3s v1.36.2+k3s1      -> hardened per deploy/cluster/k3s/ (embedded etcd)
        ├── kube-system       -> traefik ingress, coredns, ... (token-automount hardened)
        ├── argocd            -> Argo CD v3.4.4, namespace-scoped, non-wildcard RBAC
        └── case-poc          -> Helm release "case-poc" of deploy/helm/anonymous-case-poc
                                 (artemis + submission + management, restricted PSS)
```

| Pinned component | Version |
|---|---|
| k3s (Kubernetes) | `v1.36.2+k3s1` |
| Argo CD | `v3.4.4` (namespace-scoped install) |
| kube-bench | `0.15.6`, benchmark `k3s-cis-1.9` |
| Artemis image | `apache/activemq-artemis:2.44.0` |
| Service images | `case-poc/{submission,management}-service:1.0.0` (local, imported into containerd) |

## Prerequisites

* Windows 11 with WSL2 and an Ubuntu distro with **systemd enabled**
  (`/etc/wsl.conf`: `[boot] systemd=true`).
* `%USERPROFILE%\.wslconfig` must boot the WSL kernel with **cgroup v2 only**
  (`[wsl2] kernelCommandLine = cgroup_no_v1=all`), then `wsl --shutdown`.
  Kubernetes ≥ 1.33 refuses to start on cgroup v1; Docker Desktop is
  cgroup-v2 compatible.
* Docker Desktop (only for building the images on the Windows side).

## Bring-up from scratch

```bash
# 1. Hardened k3s server inside WSL (installs curl/jq/git, sysctls, config,
#    k3s itself, file-permission hardening, SA hardening in kube-system)
wsl -d Ubuntu -u root bash /windir/c/dev/bachelor-thesis/bachelor-thesis-artefact/scripts/k3s-install.sh

# 2. Prove the CIS baseline (writes docs/reports/kube-bench-<date>.txt)
wsl -d Ubuntu -u root bash /windir/c/dev/bachelor-thesis/bachelor-thesis-artefact/scripts/kube-bench-run.sh

# 3. Build the Phase-1 service images and import them into k3s containerd
#    (Git Bash on Windows, Docker Desktop running)
bash scripts/images-import.sh

# 4. Bootstrap the GitOps control plane (Argo CD + AppProject + root app).
#    Everything below deploy/argocd/apps/ is afterwards synced from GitHub.
wsl -d Ubuntu -u root bash /windir/c/dev/bachelor-thesis/bachelor-thesis-artefact/scripts/argocd-install.sh

# 5. End-to-end proof through the ingress
bash scripts/k8s-demo.sh
```

The Argo CD `Application`s track branch `k8s-poc`
(`deploy/argocd/root-app.yaml`, `deploy/argocd/apps/*.yaml`); switch
`targetRevision` to `HEAD` once the branch is merged. Note the bootstrap is
two-phase by design: `deploy/argocd/install` (applied once by hand) creates the
control plane and the `case-poc` namespace/RBAC; everything after that is
pulled from git by Argo CD itself — pushing a change to the chart or an
`Application` manifest is the deployment action.

## GitOps layout

```text
deploy/
├── cluster/k3s/          # node-level hardening, copied by scripts/k3s-install.sh
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
└── helm/anonymous-case-poc/   # the Phase-1 app chart (values pin the images)
```

Access:

* API from Windows: `kubectl --kubeconfig <copy of /etc/rancher/k3s/k3s.yaml>`
  (server `https://127.0.0.1:6443`, WSL forwards localhost).
* App: `http://submission.localtest.me` and `http://management.localtest.me`
  (Traefik on port 80; `localtest.me` resolves to `127.0.0.1` — if your router's
  DNS-rebind protection blocks that, use `curl --resolve`, as
  `scripts/k8s-demo.sh` does).
* Argo CD UI: `kubectl -n argocd port-forward svc/argocd-server 8443:443`,
  login `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
* Artemis console (DLQ inspection): `kubectl -n case-poc port-forward svc/case-poc-anonymous-case-poc-artemis 8161:8161`
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
| File permissions (1.1.x/4.1.x) | `chmod 600` sweep over k3s TLS/kubeconfig/CNI files in `k3s-install.sh` |
| 5.1.1/5.1.3 (RBAC) | Argo CD **namespace-scoped** install: no ClusterRoles, no wildcard rules; per-namespace Roles enumerate exactly the kinds the chart deploys (`deploy/argocd/install/case-poc/argocd-rbac.yaml`) |
| 5.1.5 (default SAs) | `automountServiceAccountToken: false` on every namespace's default SA (install script + versioned SA manifests) |
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

## WSL-specific pitfalls (already handled, documented for reproducibility)

* **cgroup v2**: see prerequisites; without it the kubelet exits
  (`kubelet is configured to not run on a host using cgroup v1`) and k3s
  crash-loops.
* **Docker Desktop WSL integration** mounts
  `C:\Program Files\Docker\Docker\resources` into the distro with an unescaped
  space in the mount options; the kubelet's `/proc/mounts` parser then fails
  (`system validation failed - wrong number of fields (expected 6, got 7)`).
  `k3s-install.sh` installs a systemd drop-in that unmounts `/Docker/host`
  before every k3s start (the mount only serves the docker CLI proxy inside
  the distro, which this setup does not use).
* WSL stops the VM when idle; k3s (systemd unit) comes back automatically the
  next time the distro starts. Durable state (etcd, Artemis journal on the
  local-path PV) survives.

## Scope notes / known limitations (POC)

* Broker credentials are POC values in `values.yaml`; the management API is
  deliberately unauthenticated (Phase-1 scope — Keycloak arrives in Phase 2)
  and must not be exposed beyond the local machine.
* No TLS on the ingress; Argo CD UI only via port-forward.
* OpenTelemetry export is disabled by default (`otel.enabled=false`) because
  the cluster runs no collector; point `otel.endpoint` at an OTLP gRPC
  collector to restore Phase-1 tracing.
* Images are imported into containerd by hand (`scripts/images-import.sh`);
  a registry + CI pipeline is future work (see application-architecture/future.md).

## Teardown

```bash
wsl -d Ubuntu -u root /usr/local/bin/k3s-uninstall.sh   # removes k3s + data
# optional: remove the cgroup line from %USERPROFILE%\.wslconfig
```
