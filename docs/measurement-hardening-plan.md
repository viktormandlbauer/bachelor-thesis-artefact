# Measurement and reproducibility hardening plan

> **Status:** Working backlog. This document records the detailed review
> recommendations but is not the authoritative thesis schedule or experimental
> protocol. The fixed baseline is
> [`fixed-thesis-implementation-plan.md`](fixed-thesis-implementation-plan.md).

## 1. Objective

Produce a reproducible, evidence-backed comparison of the concrete Docker
Compose and single-node k3s deployments in this repository.

The final claim must remain scoped to these configured stacks, the recorded VM
and host environment, and the selected workload. It must not be presented as a
universal comparison of Docker Compose and Kubernetes.

Podman remains optional comparison context. It should not delay or reduce the
number of independent Compose/k3s repetitions.

## 2. Definition of done

The work is complete when all of the following hold:

- A clean clone can create both measurement environments without relying on
  pre-existing VMs, images, volumes, credentials, or uncommitted files.
- Both environments use the same application and infrastructure image content,
  verified by immutable digest.
- A fail-fast preflight proves the VM allocation, guest OS, kernel, architecture,
  node count, running workloads, image inventory, and measurement tools match
  the campaign contract.
- Every metric has the same start/end boundary on both platforms or is reported
  as a deliberately platform-specific metric.
- Workload results distinguish offered load, accepted HTTP goodput, errors,
  dropped work, and asynchronous downstream completion.
- Upgrade and rollback availability are measured while traffic is running.
- Campaign output is immutable, complete, traceable to a Git commit and image
  digests, and cannot silently mix or overwrite runs.
- Platform order is blocked and randomized across independent sessions.
- A fresh rebuild, application demo, requirements validation, and kube-bench run
  have been repeated against the final frozen commit.

## 3. Implementation order

Do not run the full measurement campaign until phases 0 through 6 pass their
acceptance criteria. Phases 1 and 2 can proceed in parallel after phase 0.

| Phase | Priority | Outcome |
|---|---|---|
| 0 | P0 | Freeze the research question and comparison contract |
| 1 | P0 | Make clean bootstrap and current evidence trustworthy |
| 2 | P0 | Make all build and runtime inputs immutable |
| 3 | P0 | Enforce isolation with a campaign preflight |
| 4 | P0 | Define explicit, semantically matched deployment profiles |
| 5 | P0 | Correct metric definitions and collectors |
| 6 | P0 | Make campaign orchestration and data handling safe |
| 7 | P1 | Add automated static and integration verification |
| 8 | P1 | Pilot, freeze the protocol, and run the final campaign |

## Phase 0 — Freeze the comparison contract

### Tasks

- Make Compose versus single-node k3s the primary comparison. Keep Podman behind
  an explicit opt-in or move it to an appendix campaign.
- Define the estimand in `docs/measurement-comparison.md`:
  - **matched platform comparison**: align workload configuration and quantify
    platform overhead; or
  - **configured-stack comparison**: retain platform-native capabilities and
    describe the result as a comparison of two complete deployment profiles.
- Use two named k3s profiles:
  - `k3s-minimal`: single-node k3s, Traefik, plain Helm, no Argo CD;
  - `k3s-gitops`: the complete PoC including Argo CD, reported separately as
    addon/capability cost.
- Define the invariant workload: Artemis, PostgreSQL, Keycloak, submission
  service, and management service, with OpenTelemetry disabled for the primary
  performance comparison.
- Write a parity table covering images, environment variables, fixtures,
  persistence, replicas, resource policy, health semantics, entry points, and
  reset behavior.

### Acceptance criteria

- One paragraph states exactly what causal comparison is attempted.
- Every intentional Compose/k3s difference is listed and classified as either a
  platform effect, a capability effect, or a limitation.
- The Kubernetes GitOps demonstration and the controlled measurement profile are
  no longer described as the same environment.

### Main files

- `docs/measurement-comparison.md`
- `measure/README.md`
- `docs/k8s-poc.md`
- root `README.md`

## Phase 1 — Repair clean bootstrap and evidence generation

### Tasks

- Make `scripts/validate-requirements.sh` use the images produced by the current
  Harbor workflow, or explicitly import the same OCI archives before its plain
  Helm release.
- Add an Argo CD convergence helper that waits for the root and child
  Applications to become `Synced` and `Healthy`, then waits for all public
  application endpoints.
- Call that helper from `scripts/argocd-install.sh` before reporting success.
- Make the GitOps revision contract consistent:
  - prefer a supplied immutable commit/tag for evidence runs;
  - otherwise verify that `gitops-push.sh` pushed the exact revision Argo tracks.
- Move the acceptance kube-bench run after the workload has converged.
- Add explicit Compose `start`, `wait`, `verify`, and `reset` operations so the
  demo is not started against a partially ready or stale stack.
- Use timestamp-and-commit evidence paths rather than date-only filenames.
- Record the local commit, dirty state, Argo synced revision, and image digests in
  rebuild, requirements, and security reports.

### Acceptance criteria

- Starting from deleted VMs and a clean clone, the documented workflow reaches a
  healthy application without manual recovery.
- The demo, requirements validator, and kube-bench pass on the final commit.
- No validation step relies on an image that was left in containerd by an older
  run.
- New evidence explicitly supersedes the July 2026 pre-GitLab/Harbor reports.

### Main files

- `docs/k8s-poc.md`
- `scripts/argocd-install.sh`
- `scripts/gitops-push.sh`
- `scripts/validate-requirements.sh`
- `scripts/k8s-demo.sh`
- `scripts/kube-bench-run.sh`
- `infra/docker-compose.yml`

## Phase 2 — Freeze inputs and build once

### Tasks

- Create one version lock/manifest for:
  - Multipass guest image identity;
  - k3s, Helm, Argo CD, kube-bench, and k6;
  - Docker, Compose, Podman if retained, and required apt packages;
  - Maven and JRE builder/runtime images;
  - Artemis, PostgreSQL, Keycloak, and observability images.
- Pin container images by manifest-list digest where architecture portability is
  required. Verify downloaded binaries with published checksums.
- Tag service images with the Git commit rather than repeatedly overwriting
  `2.0.0`.
- Build each service exactly once per campaign and export one OCI/Docker archive.
- Import that same archive into Docker and k3s containerd. If Podman is retained,
  import the same archive there as well.
- Preload all infrastructure images before lifecycle timing.
- Generate an image manifest containing logical name, reference, platform,
  architecture, and resolved digest.
- Fail if runtime digests differ across platforms.

### Acceptance criteria

- Repeating image staging without a source change produces the same resolved
  campaign image set.
- The first timed install performs no registry download.
- Compose and k3s report identical application and infrastructure image digests.

### Main files

- `submission-service/Dockerfile`
- `management-service/Dockerfile`
- `measure/images-load.sh`
- `scripts/images-import.sh`
- `scripts/images-publish.sh`
- `deploy/helm/anonymous-case-poc/values.yaml`
- new `versions.env` or `versions.yaml`

## Phase 3 — Add fail-fast environment isolation

### Tasks

- Add `measure/preflight.sh` and run it before any sample is recorded.
- Validate and record:
  - host OS, CPU model, power mode, free memory, Multipass version, and driver;
  - VM image identity, CPU, RAM, disk, architecture, OS, kernel, and clock;
  - exactly one running measurement VM;
  - exactly one Ready k3s node for the parity profile;
  - no running `case-poc-w*` VMs or stale Kubernetes Node objects;
  - no compose-side SigNoz, Keycloak, PostgreSQL, GitLab, Harbor, or bridge
    containers on the k3s VM;
  - no unexpected Compose, Podman, or Kubernetes workload;
  - required native tools and their exact versions;
  - expected image digests and sufficient free disk space.
- Make VM reuse conditional on exact configuration equality. Otherwise fail with
  a clear recreate command.
- Add an explicit, user-invoked clean/recreate command. Do not make preflight
  silently destroy VMs or data.
- If Podman remains, ensure Docker and all Docker workloads are stopped during
  its platform-footprint measurement, and vice versa.

### Acceptance criteria

- Deliberately leaving a worker VM, compose-infra container, wrong kernel, wrong
  VM allocation, unexpected workload, or wrong image digest makes preflight fail.
- The full preflight output is saved with the campaign results.

### Main files

- new `measure/preflight.sh`
- `measure/lib/common.sh`
- `measure/run-all.sh`
- `scripts/vm-up.sh`
- `measure/engines-vm-up.sh`
- `deploy/vm/ansible/site.yml`

## Phase 4 — Create explicit deployment profiles

### Tasks

- Add committed profile files instead of long command-line `--set` strings:
  - `deploy/helm/anonymous-case-poc/values-measure.yaml`;
  - `deploy/helm/anonymous-case-poc/values-gitops.yaml`.
- Keep one canonical measurement Compose file.
- Align the primary measurement workload:
  - identical images and fixtures;
  - identical replica counts;
  - identical memory limits;
  - equivalent CPU weighting/reservations, or no platform-specific reservation;
  - equivalent Artemis and PostgreSQL persistence semantics;
  - OpenTelemetry disabled;
  - a documented reset operation that returns both databases and brokers to the
    same initial state.
- Preserve Kubernetes-only capabilities such as readiness-gated Services,
  NetworkPolicy, and rolling Deployments, but classify them as intentional
  platform capabilities.
- Add a parity validator that checks the resolved Compose configuration and
  rendered Helm manifests against the comparison contract.

### Acceptance criteria

- Measurement commands reference profile files and contain no undocumented
  behavior-changing overrides.
- The parity validator reports no unexplained workload difference.
- The GitOps profile is never used accidentally by the primary performance run.

### Main files

- `measure/compose/docker-compose.yml`
- `deploy/helm/anonymous-case-poc/values.yaml`
- new measurement/GitOps values files
- `measure/lib/stack.sh`

## Phase 5 — Correct the measurements

### D1: platform footprint and recovery

- Rename the current service restart measurement to `control_service_recovery`.
  Report Podman as not applicable rather than a numeric zero.
- Add a separate VM boot-to-platform-ready metric if true cold start matters.
- Measure a clean VM baseline and report incremental platform cost.
- Prefer cgroup v2 `memory.current`, `cpu.stat`, and I/O counters, plus VM-wide
  time series. Keep RSS only as a clearly labeled secondary diagnostic.
- Measure disk as before/after deltas on a clean state. Separate binaries,
  platform-required images, workload images, persistent data, and logs.
- Report minimal-k3s and GitOps-addon costs separately.

### D2: lifecycle and availability

- Use one host monotonic boundary for all platforms: operation issued to the
  same externally published endpoint becoming healthy with the expected digest.
- Run a continuous probe or low-rate workload during install, upgrade, and
  rollback.
- Record total failed requests, longest continuous outage, total unavailable
  time, in-flight request loss, and final running digest.
- Keep lifecycle semantics explicit: Compose recreate/reapply versus Kubernetes
  rolling update and revisioned rollback.

### D3: workload behavior

- Rename the fixed-rate result to `achieved_request_rate`; do not call a
  10-request/s target a capacity measurement.
- Export semantic success as accepted HTTP 201 goodput. Include check failures,
  HTTP failures, timeouts, and dropped iterations in the result schema.
- Add a separate step/ramp load sweep to estimate sustainable capacity under a
  predefined latency and error objective.
- Attach a unique campaign/run identifier to submitted cases.
- Verify that accepted cases reach the management inbox and record completion
  ratio and end-to-end asynchronous lag.
- Wait for the broker/outbox/inbox backlog to drain, or reset the workload,
  before the next repetition.
- Sample workload and VM CPU, memory, disk I/O, and network throughout the run
  instead of taking one mid-run RSS snapshot.

### Acceptance criteria

- An unexpected 2xx response is counted as a semantic failure.
- Missing downstream cases fail the end-to-end completion check.
- Compose and k3s startup/lifecycle values use identical timing boundaries.
- An injected unavailable interval is visible in the availability metrics.
- Fixed-load responsiveness and maximum sustainable capacity are reported as
  different experiments.

### Main files

- `measure/k6/workload.js`
- `measure/measure-platform.sh`
- `measure/measure-lifecycle.sh`
- `measure/measure-workload.sh`
- `measure/vm/footprint.sh`
- `measure/vm/workload-rss.sh`

## Phase 6 — Make campaigns immutable and statistically usable

### Tasks

- Generate and export one campaign ID at startup using timestamp, short commit,
  and a random suffix.
- Refuse to write into an existing campaign directory unless an explicit
  `RESUME=1` mode passes consistency checks.
- Never overwrite per-run JSON or time-series artifacts.
- Write a campaign manifest before measurement containing:
  - commit, branch, dirty status, and patch hash;
  - protocol/profile version;
  - all environment knobs;
  - preflight output;
  - host, VM, kernel, and tool versions;
  - image digests;
  - randomized order and random seed.
- Run Compose and k3s in matched blocks. Randomize or counterbalance platform
  order within each block and spread blocks across independent sessions.
- Determine the final repetition count from pilot variance rather than choosing
  it solely in advance.
- Install cleanup traps that restore GitOps state and record an aborted campaign
  without treating partial data as complete.
- Add a result validator for required platforms, metrics, repetitions, units,
  uniqueness, finite numeric values, and referenced artifact existence.
- Make `stats.py` refuse incomplete/duplicate campaigns and report paired
  differences or ratios, median/IQR, and bootstrap confidence intervals where
  the sample design supports them.

### Acceptance criteria

- Two campaigns started on the same day cannot collide.
- A campaign crossing midnight remains in one directory.
- Duplicate rows, missing metrics, unit changes, and missing k6 artifacts fail
  validation.
- An interrupted campaign restores the environment and is clearly marked
  incomplete.
- The report shows the actual execution order and paired platform effects.

### Main files

- `measure/lib/common.sh`
- `measure/run-all.sh`
- `measure/stats.py`
- new `measure/validate-results.py`

## Phase 7 — Add verification gates

### Tasks

- Add Maven Wrapper files and a single repository verification entry point.
- Run both service test suites before building campaign images.
- Add static checks for Bash, Compose, Helm lint/template, Kubernetes schema,
  Python, and documentation links.
- Add unit tests for statistics, manifest handling, duplicate detection, and
  completeness validation.
- Add a lightweight CI workflow for checks that do not require Multipass.
- Keep the destructive clean rebuild and full campaign as explicit local
  acceptance jobs.

### Acceptance criteria

- A documented `verify` command gates campaign image creation.
- CI catches invalid Compose/Helm configuration, shell syntax errors, service
  test failures, and result-schema regressions.

## Phase 8 — Pilot and final campaign

### Pilot

- Run at least two complete randomized blocks from freshly verified state.
- Inspect time-series stability, backlog drain, errors, dropped iterations,
  campaign manifests, and result completeness.
- Use pilot variance and observed warm-up behavior to freeze repetition count,
  warm-up criteria, cooldown/drain criteria, and load-sweep levels.
- Fix the protocol and tag the repository. Do not tune thresholds after viewing
  the final comparative results.

### Final campaign

- Recreate both VMs from the frozen inputs.
- Run preflight and archive the manifest before collecting samples.
- Execute the randomized blocked campaign without source/configuration changes.
- Validate completeness before aggregation.
- Report raw data, paired effects, uncertainty, capabilities, and threats to
  validity.
- Repeat the scratch rebuild, demo, requirements validation, and kube-bench
  evidence on the same frozen revision.

### Acceptance criteria

- A third party can identify every input and repeat the documented procedure.
- The final report makes no claim broader than the concrete k3s and Compose
  profiles that were measured.

## 4. Suggested delivery slices

1. **Reproducible bootstrap:** phases 0–2.
2. **Controlled environment:** phases 3–4.
3. **Valid measurement harness:** phases 5–6.
4. **Verification and evidence:** phases 7–8.

Each slice should end with a commit and a short evidence report. The full
campaign should be the last activity, not the mechanism used to debug the
harness.
