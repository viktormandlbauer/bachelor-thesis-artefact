# Measurement harness — docker compose vs. podman kube play vs. k3s

Implements the thesis measurement protocol (SRQ3 — Measurement Protocol) as
a **comparative** harness over three deployment platforms running the same
Phase-2 application (Artemis, PostgreSQL, Keycloak, submission-service,
management-service):

| platform  | where | workload definition |
|---|---|---|
| `compose` | VM `case-engines` (Docker Engine) | [compose/docker-compose.yml](compose/docker-compose.yml) |
| `podman`  | VM `case-engines` (rootful Podman) | [podman/infra.yaml](podman/infra.yaml) + [podman/app.yaml.tpl](podman/app.yaml.tpl) via `podman kube play` |
| `k3s`     | VM `case-poc` (the hardened PoC cluster) | `deploy/helm/anonymous-case-poc` (plain Helm, namespace `measure`) |

Both VMs have the identical allocation (4 vCPU / 8 GiB / 40 GiB, Ubuntu
24.04 on Multipass), so the platform is the only variable. The 16 GiB host
cannot run both VMs at once — the harness stops the other VM before each
measurement, which doubles as the "no background load" control.

Method, metric definitions, SRQ3 mapping, manual step counts and threats to
validity: [docs/measurement-comparison.md](../docs/measurement-comparison.md).

## One-time setup

```bash
# 0. the k3s PoC must be up (scripts/vm-up.sh, argocd-install.sh,
#    images-import.sh — see docs/k8s-poc.md), and k6 installed on the host
brew install k6

# 1. create + provision the engines VM (docker, compose v2, podman, sysstat)
bash measure/engines-vm-up.sh

# 2. stage all images on all three platforms (build 2.0.0, load into
#    docker + podman, pre-pull infra images, retag 2.0.1 everywhere)
bash measure/images-load.sh
```

## Running

```bash
# full protocol campaign: 5 runs per metric, all three platforms (~hours)
bash measure/run-all.sh

# quick end-to-end validation of the harness (not protocol-conformant)
SMOKE=1 bash measure/run-all.sh

# individual dimensions (platform = compose | podman | k3s)
bash measure/measure-platform.sh compose 1     # D1: cold start + idle footprint
bash measure/measure-lifecycle.sh podman 1     # D2: install/upgrade/rollback
RUNS=5 bash measure/measure-workload.sh k3s    # D3: k6 + startup
```

Results land in `docs/reports/measurements/<date>/` (`raw.csv`, per-run k6
summaries under `k6/`, aggregated `report.md`). `RUN_ID=<id>` groups runs
into one campaign directory; `python3 measure/stats.py <raw.csv>`
re-aggregates at any time.

Knobs (env): `RUNS`, `RATE` (k6 req/s), `LOAD_DURATION`, `WARMUP` (idle
warm-up), `CPU_SECONDS` (pidstat window), `COOLDOWN`, `KEEP_STACK=1`
(leave the stack deployed after a lifecycle run, e.g. to chain D3),
`BASE_TAG`/`UPGRADE_TAG`.

## What is recorded (protocol mapping)

| CSV metric | protocol | note |
|---|---|---|
| `cold_start` | M-PF-04 | engine/cluster start → ready; podman is daemonless (0) |
| `platform_rss_*` | M-PF-01 | VmRSS sums; k3s split into core / kube-system / argocd |
| `platform_cpu_idle` | M-PF-02 | pidstat over the platform pid set, 60 s |
| `platform_disk_*`, `image_store` | M-PF-03 | binaries / state / layer store |
| `install_time`, `upgrade_time`, `rollback_time` | M-LC-01..03 | command → expected tag running + all endpoints 200 |
| `http_throughput`, `http_p50/p95/p99`, `http_error_rate` | M-WP-01..04 | k6 constant-arrival-rate on POST /api/cases |
| `startup_time` | M-WP-05 | image-warm service start → ready |
| `workload_rss_*` | (extra) | mid-load container RSS, same VmRSS method |

## k3s specifics

The PoC cluster is GitOps-managed (Argo CD, selfHeal on). The harness
quiesces it first (`vm/k3s-quiesce.sh`: application controller → 0, then
case-poc deployments → 0) so the measured `measure` namespace release —
installed with plain Helm exactly like `scripts/validate-requirements.sh`
does — is the only workload. `run-all.sh` restores everything at the end;
manually: `multipass exec case-poc -- sudo bash /repo/measure/vm/k3s-quiesce.sh restore`.
