# Platform comparison measurement — docker compose / podman kube play / k3s

This document defines how the single-host container platforms (docker
compose, podman `kube play`) are measured **against the same metrics** as
the Kubernetes PoC, so the thesis can quantify what the k3s platform costs
(footprint, lifecycle time) relative to the simplest deployment mechanisms
that can run the identical workload — and what capabilities that cost buys
(rolling updates, revisioned rollback, RBAC, readiness-gated traffic).

It instantiates the metric definitions of *SRQ3 — Measurement Protocol*
(thesis vault, `research/`) comparatively. The protocol's qualification
gate (Dimension 4) already excludes podman kube play from the
*requirements-based* evaluation (no Helm, no rolling-update primitive);
here it is measured anyway as **comparison context**, with the gate
outcomes reported as a capability matrix rather than as a disqualification.
The harness lives in [`measure/`](../measure/README.md); results land in
`docs/reports/measurements/<id>/`.

## 1. Test environment

| Parameter | `case-engines` (compose, podman) | `case-poc` (k3s) |
|---|---|---|
| VM | Multipass, Ubuntu 24.04, **4 vCPU / 8 GiB / 40 GiB** | identical |
| Host | same macOS host (10 cores / 16 GiB), one VM running at a time | identical |
| Engine | Docker Engine + compose v2; rootful Podman (Ubuntu 24.04 apt versions, recorded in each report) | k3s v1.36.2+k3s1, CIS-hardened per `deploy/` |
| Workload | `measure/compose/docker-compose.yml` / `measure/podman/*.yaml` | Helm chart `deploy/helm/anonymous-case-poc`, namespace `measure`, plain Helm (as in `scripts/validate-requirements.sh`) |
| Load generator | k6 on the macOS host, against the VM's published ports / Traefik ingress | identical |

Parity controls (one variable — the platform):

* **Same images** everywhere, staged before any timing (`measure/images-load.sh`);
  the "upgrade" tag 2.0.1 is the 2.0.0 image retagged, so lifecycle timings
  measure mechanics, not image content.
* **Same configuration fixtures** (broker.xml, Postgres init SQL, Keycloak
  realm) mounted from `infra/` on the single-host platforms and shipped as
  ConfigMaps by the chart.
* **Same memory limits**: compose `deploy.resources.limits` and the podman
  pod specs mirror the chart's `values.yaml`; no platform sets CPU limits.
* **OpenTelemetry disabled** on all platforms (the PoC cluster runs
  `otel.enabled=false`).
* **No co-tenant load**: the other VM is stopped; on k3s the Argo
  CD-managed `case-poc` release is quiesced (`measure/vm/k3s-quiesce.sh`)
  so the `measure` release is the only workload.
* **Uniform end state** for every timed operation: the expected image tag
  is running **and** the three public endpoints answer 200 (submission
  `/q/health/ready`, management `/q/health/ready`, Keycloak realm
  discovery), each through the platform's canonical entry point.

## 2. Metrics (SRQ3 mapping)

Five runs per timed metric, median + IQR reported (`measure/stats.py`).

| Protocol ID | Harness metric | compose | podman | k3s |
|---|---|---|---|---|
| M-PF-01 | `platform_rss_*` | dockerd + containerd (+shims) | daemonless: conmon/netavark only when running (idle ≈ 0) | k3s process tree + kube-system pods + Argo CD pods (split out; workload namespaces excluded) |
| M-PF-02 | `platform_cpu_idle` | pidstat 60 s over the same pid set | 〃 | 〃 |
| M-PF-03 | `platform_disk_*`, `image_store` | binaries, `/var/lib/docker` (+containerd) | binaries, `/var/lib/containers` | k3s binary, `/var/lib/rancher`+kubelet+config |
| M-PF-04 | `cold_start` | `systemctl start docker` → `docker info` | 0 (no daemon) | `k3s-killall` → `systemctl start k3s` → node Ready + kube-system/argocd deployments available |
| M-LC-01..03 | `install/upgrade/rollback_time` | `compose up -d` with `TAG` | `kube play` / `--replace` | `helm install/upgrade/rollback` |
| M-WP-01..04 | `http_*` | k6, constant arrival rate (default 10 req/s, 60 s) on `POST /api/cases` — anonymous by design, and every accepted case still traverses outbox → Artemis → management inbox | 〃 | 〃 through Traefik (Host `submission.measure.localtest.me`) |
| M-WP-05 | `startup_time` | `docker start` → ready (image-warm) | `podman pod start` → ready | pod `creationTimestamp` → `Ready` condition (API timestamps) |
| (extra) | `workload_rss_*` | mid-load container RSS, identical VmRSS-over-cgroup method on all platforms | 〃 | 〃 |

RSS is `VmRSS` summed over every pid in each container's cgroup (physical
memory pressure, per protocol §5.2); pause/infra containers are excluded
(≈ 0.5 MiB each).

## 3. Manual step counts (M-LC-04..06)

Distinct human-initiated commands per runbook, from a fresh VM with the
repository mounted; image staging (`measure/images-load.sh` /
`scripts/images-import.sh`) counted as one step everywhere.

| Operation | compose | podman kube play | k3s PoC (GitOps runbook) |
|---|---|---|---|
| Platform install | 1 (`engines-vm-up.sh`: apt) | 1 (same provisioning step) | 1 (`vm-up.sh`: Ansible playbook) |
| Stage images | 1 | 1 | 1 |
| App install | 1 (`compose up -d`) | 2 (`kube play` infra, render+play app) | 1 (`argocd-install.sh` — bootstraps secrets, Argo CD, and syncs the app) |
| **Install total** | **3** | **4** | **3** |
| Upgrade | 1 (`TAG=… up -d`) | 1 (render + `play --replace`) | 1 (git push / `helm upgrade`) |
| Rollback | 1 (`TAG=… up -d`, old tag) | 1 (render + `play --replace`, old tag) | 1 (git revert / `helm rollback`) |

Step count is a proxy for procedural effort only; the wall-clock metrics
(M-LC-01..03) and the *content* of each step (an apt install vs. a
CIS-hardened cluster provisioning) carry the interpretation in the thesis
text.

## 4. Capability matrix (protocol Dimension 4)

The qualification gates are reported as capabilities; only k3s qualifies
for the requirements-based evaluation, which the landscape analysis
(SRQ1) already concluded — the measurements quantify the trade.

| Gate | compose | podman kube play | k3s |
|---|---|---|---|
| Q-01 Helm install | ✗ (no Kubernetes API) | ✗ (kube YAML subset, no Helm) | ✓ |
| Q-02 rolling upgrade | ✗ recreate (downtime, measured) | ✗ replace (downtime, measured) | ✓ (zero-downtime, REQ-F-003 evidence) |
| Q-03 revisioned rollback | ✗ re-apply old definition | ✗ re-apply old definition | ✓ `helm rollback` to revision |
| Q-04 readiness gates traffic | partial (healthcheck orders startup, doesn't gate traffic) | partial (probes → healthchecks) | ✓ endpoint removal (REQ-F-005) |
| Q-05 RBAC | ✗ (root socket) | ✗ | ✓ (REQ-G-001) |
| Q-06 TLS on control plane | n/a | n/a | ✓ (REQ-G-004) |

## 5. Procedure

Per platform (automated by `measure/run-all.sh`, protocol §4):

1. **D1 × 5** — workload-free: cold start, 5 min warm-up, idle RSS, idle
   CPU (60 s pidstat); disk + versions once.
2. **D2 × 5** — clean state, then install → upgrade → rollback, each timed
   command-to-ready; teardown between sequences.
3. **D3** — fresh install, discarded 30 s priming load (JVM steady state),
   then 5 × k6 with 60 s cool-down and a mid-load RSS snapshot; then 5 ×
   image-warm startup.
4. k3s: restore the GitOps-managed workload (`k3s-quiesce.sh restore`).

## 6. Threats to validity (additions to protocol §5.4)

| Threat | Mitigation / disclosure |
|---|---|
| Entry-point asymmetry: k3s is measured through Traefik (ingress), compose through docker-proxy, podman through its port forward | Each platform's *canonical* published entry point is used; the extra proxy hop is part of the platform under test and is disclosed with the latency results. |
| Podman has no `depends_on`: app pods crash-loop until the backing services accept connections | Reported as-is — convergence behaviour is the platform's genuine install semantic (same convergence model as Kubernetes). |
| k3s idle RSS excludes the Argo CD application controller (scaled to 0 to keep selfHeal from restoring the workload) | The controller's RSS is sampled separately pre-quiesce (`platform_rss_argocd_with_controller`) and reported alongside. |
| Upgrade/rollback semantics differ (recreate vs. replace vs. rolling) | By design: the timing quantifies each platform's native operation; the capability matrix (§4) states the semantic difference. |
| Same-bits retag for the upgrade may flatter platforms that skip image pulls | All platforms are measured with pre-staged images (protocol's image-pull confound control applies to all three equally). |
| macOS/Multipass virtualisation is not the RHEL 9 target environment of the protocol's §2 table | The comparison is internally consistent (same hypervisor, same guest OS, same allocation); absolute values are indicative, deltas between platforms are the result. |
| k6 timings are second-resolution for k3s M-WP-05 (API timestamps) | Values are multi-second; ±1 s quantisation is visible in the IQR. |
| Docker and Podman cohabit the `case-engines` VM | The other engine is stopped during each platform's runs; Docker's FORWARD-DROP iptables policy is reset for podman measurements (it silently drops inbound connections to netavark's published ports) and re-asserted by dockerd on the next compose run. |

## 7. Reproducing

```bash
brew install k6
bash measure/engines-vm-up.sh      # once
bash measure/images-load.sh        # once (k3s PoC must already run)
bash measure/run-all.sh            # full campaign -> docs/reports/measurements/<date>/report.md
```
