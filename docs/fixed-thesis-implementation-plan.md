# Fixed Bachelor Thesis Implementation Plan

**Baseline:** 1.0  
**Status:** Frozen implementation and experiment plan  
**Frozen on:** 2026-07-11  
**Authoritative for:** scope, sequence, profiles, metrics, run count, thresholds,
analysis, and evidence collection

This is the plan that will be executed. The larger
`measurement-hardening-plan.md` remains a review backlog; it cannot expand or
alter this baseline.

## 1. Fixed research contract

The thesis remains a requirements-based evaluation of a controlled,
reproducible Kubernetes PoC. Its formal verdict is whether the k3s PoC meets the
predefined SRQ1 requirements and SRQ2 acceptance criteria.

Docker Compose is retained as a secondary, matched reference. It shows the
relative cost and behavior of running the same workload with a simpler
deployment mechanism, but it is not evaluated against Kubernetes-specific
qualification gates. Compose results provide context; they do not change the
formal k3s verdict.

The following decisions are fixed:

- k3s is the only Kubernetes distribution evaluated.
- Docker Compose is the only quantitative comparison platform.
- Podman is excluded from the final thesis campaign and results.
- The quantitative comparison uses a single-node k3s profile.
- The full GitOps PoC is verified separately and is not mixed into comparative
  performance results.
- The measured claim is limited to these configured profiles on the recorded
  test host. It is not a universal Kubernetes-versus-Compose benchmark.
- The workload test is a fixed-load responsiveness test, not a maximum-capacity
  benchmark.

## 2. Fixed deployment profiles

### 2.1 `compose-measure`

- One Multipass VM named `case-engines`.
- Docker Engine and Docker Compose.
- One canonical measurement Compose file.
- Five workload containers: Artemis, PostgreSQL, Keycloak,
  submission-service, and management-service.
- OpenTelemetry export disabled during quantitative measurement.
- No SigNoz, GitLab, Harbor, or unrelated containers.

### 2.2 `k3s-measure`

- One Multipass VM named `case-poc-cp`.
- Single-node CIS-hardened k3s.
- Plain Helm deployment using a committed measurement values file.
- Traefik and the normal k3s system components remain enabled.
- The same five workload components as `compose-measure` run inside k3s.
- OpenTelemetry export disabled during quantitative measurement.
- No worker nodes, Argo CD, SigNoz, GitLab, Harbor, or compose-side
  infrastructure.

### 2.3 `k3s-gitops-evidence`

- The repository's full GitOps PoC, including Argo CD and the current internal
  GitLab/Harbor workflow.
- Used only for clean-rebuild, GitOps, observability, requirements, and security
  evidence.
- OpenTelemetry and SigNoz are enabled for the observability proof.
- Never used as a source of comparative performance results.

### 2.4 Workload invariants

The quantitative profiles must have all of the following in common:

- identical application and infrastructure image digests;
- identical broker, database, and Keycloak fixtures;
- one replica of each component;
- identical memory limits;
- no CPU limits and no CPU requests/reservations;
- persistent PostgreSQL and Artemis storage;
- the same application environment contract;
- the same base and upgrade application bits;
- images preloaded before any timed operation;
- volumes/PVCs deleted by the reset operation.

Kubernetes-native behavior—Traefik, Services, probes, rolling Deployments,
NetworkPolicy, RBAC, and CIS hardening—remains part of the k3s profile and is
reported as an intentional configured-platform difference.

## 3. Fixed test environment

| Parameter | Frozen value |
|---|---|
| Physical host | The same Windows host for every run, connected to AC power |
| Host VM manager | Multipass `1.16.3+win` |
| Guest image | One checksum-pinned Ubuntu 24.04.4 image used for both VMs |
| Guest kernel | The same exact kernel release on both VMs; expected `6.8.0-134-generic` |
| VM allocation | 4 vCPU, 8 GiB RAM, 40 GiB disk per VM |
| VM concurrency | Exactly one measurement VM running at a time |
| k3s | `v1.36.2+k3s1` |
| Helm | `v3.19.0` |
| Docker Engine | `29.1.3` |
| Docker Compose | `2.40.3` |
| Load generator | Native host installation of k6 `v2.0.0` |
| Network | Local Multipass network; no unrelated load or transfers |

All container references, base images, downloads, and package versions are
recorded in a committed version lock. Container images are pinned by digest.
The two service images are built once, exported once, and imported into both
runtimes. The campaign preflight must prove digest equality.

If an exact frozen dependency cannot be installed, implementation stops at the
input gate. A different version is not silently substituted.

## 4. Frozen acceptance criteria

The existing pre-registered thresholds are retained. They are not raised after
observing the final measurements.

| Requirement | Fixed pass criterion |
|---|---|
| REQ-O-001 idle memory | Platform process RSS median ≤ 512 MiB |
| REQ-O-001 idle CPU | Median ≤ 5% of total four-vCPU capacity |
| REQ-O-002 cold readiness | VM start to platform ready ≤ 300 s |
| REQ-O-003 install | Helm command to verified public readiness ≤ 180 s |
| REQ-O-004 upgrade | Helm command to verified public readiness ≤ 180 s |
| REQ-O-005 rollback | Helm command to verified public readiness ≤ 120 s |
| REQ-F-003 availability | No failed external availability sample during k3s upgrade |

Qualification gates Q-01 through Q-06—Helm install, rolling upgrade, rollback,
readiness enforcement, RBAC, and control-plane TLS—must pass before the final
quantitative campaign begins.

Compose is measured with the same timing boundaries, but Kubernetes-specific
thresholds and gates do not produce a Compose pass/fail verdict.

## 5. Fixed implementation sequence

The order is mandatory. A phase cannot begin until the preceding gate passes.

### Phase 1 — Align and freeze the research documents

**Target effort:** 1 working day

1. Update the SRQ3 protocol from the obsolete two-node RHEL environment to the
   single-node Ubuntu measurement profile in this plan.
2. Replace every TBD for host, VM allocation, topology, load rate, run count,
   timing boundary, and tool version.
3. Update the old SRQ2 acceptance scenarios and image names to the implemented
   anonymous-case application.
4. State explicitly that the formal evaluation is k3s versus requirements and
   that Compose is secondary context.
5. Remove Podman from the final measurement protocol and validation matrix.
6. Explain that OpenTelemetry is enabled for operational observability evidence
   but disabled equally in both quantitative profiles.
7. Freeze metric IDs and acceptance thresholds.

**Gate G1 — Research contract:** the proposal, SRQ1, SRQ2, SRQ3 protocol, this
plan, and the repository documentation describe the same scope and contain no
TBDs or conflicting topology.

### Phase 2 — Freeze versions and build artifacts once

**Target effort:** 2 working days

1. Add the committed version lock and download checksums.
2. Pin Maven/JRE base images and all infrastructure images by digest.
3. Build both application images once from a clean, tested commit.
4. Export immutable archives and import the same archives into Docker and k3s.
5. Create the base and upgrade tags from the same application bits so lifecycle
   measurements isolate deployment mechanics.
6. Preload every required image before timing.
7. Produce a machine-readable image manifest and digest verifier.

**Gate G2 — Immutable inputs:** runtime digests match on both platforms, no
timed operation downloads an image, and a second staging run resolves the same
manifest.

### Phase 3 — Implement the three explicit profiles

**Target effort:** 2 working days

1. Add a committed Helm measurement values file.
2. Add a separate committed GitOps values file.
3. Make the measurement Compose file match the workload invariants.
4. Add Artemis persistence to Compose.
5. Remove CPU requests from the Helm measurement profile.
6. Replace long measurement-time Helm `--set` strings with the values file.
7. Implement identical clean reset behavior for Compose volumes and k3s PVCs.
8. Add a rendered-profile parity validator.

**Gate G3 — Profile parity:** the validator finds no unexplained workload
difference, and the GitOps profile cannot be selected by the measurement
harness.

### Phase 4 — Make clean provisioning and isolation reliable

**Target effort:** 2 working days

1. Make both measurement VMs originate from the same pinned guest image.
2. Fail rather than reuse a VM with the wrong allocation, kernel, mount, or
   platform version.
3. Add an explicit clean/recreate command.
4. Create a verified clean snapshot after platform provisioning and image
   preload, with no application state.
5. Add `measure/preflight.sh`.
6. Verify one running VM, one k3s node, no workers, no compose-side
   infrastructure, no unrelated workloads, identical image digests, native k6,
   synchronized clocks, and sufficient disk space.
7. Save preflight output in every campaign directory.

**Gate G4 — Isolation:** deliberately leaving a stale worker, wrong kernel,
wrong allocation, unrelated container, or mismatched digest causes preflight to
fail before a sample is written.

### Phase 5 — Correct the measurement harness

**Target effort:** 4 working days

Implement the fixed metrics in Section 6 without adding further metrics or load
profiles. Add uniform timing boundaries, continuous availability measurement,
semantic HTTP success, asynchronous completion verification, time-series
resource collection, safe campaign IDs, cleanup traps, and result validation.

**Gate G5 — Harness correctness:** injected HTTP downtime is detected, an
unexpected non-201 response counts as failure, a missing downstream case is
reported, duplicate/missing artifacts fail validation, and interrupted runs
restore the environment.

### Phase 6 — Verify, pilot, and freeze the code

**Target effort:** 2 working days

1. Run service tests, Bash checks, Compose rendering, Helm lint/template,
   Kubernetes schema checks, and result-processor tests.
2. Execute two complete excluded pilot blocks: Compose→k3s, then k3s→Compose.
3. Use pilot runs only to find implementation defects. Do not change load,
   duration, metrics, thresholds, repetitions, or analysis rules.
4. Fix defects, discard pilot results from the final dataset, rerun both pilots,
   and require complete valid output.
5. Commit a clean tree and tag it `thesis-campaign-v1.0`.

**Gate G6 — Experiment freeze:** both excluded pilots pass validation, all
checks pass, the tree is clean, and the tagged protocol, code, images, profiles,
and analysis scripts are immutable.

### Phase 7 — Execute the final campaign

**Target effort:** 3 controlled sessions

Run the six fixed paired blocks in Section 7. Do not edit source,
configuration, images, tools, VM allocation, or analysis code during the
campaign.

**Gate G7 — Dataset:** exactly six valid observations exist for every repeated
metric on each platform, every pair is complete, and the result validator
passes.

### Phase 8 — Produce evidence and thesis results

**Target effort:** 2 working days plus writing

1. Generate the report only from the frozen raw data and analysis code.
2. Execute the final clean GitOps rebuild and application demo.
3. Run requirements validation and kube-bench with the workload deployed.
4. Capture the OpenTelemetry/SigNoz observability evidence.
5. Create the SRQ3 validation matrix.
6. Write the results as k3s requirement verdicts first and Compose comparison
   context second.
7. Report all failures and threats to validity without changing criteria.

**Gate G8 — Evidence:** every result traces to the frozen commit, campaign
manifest, raw artifact, requirement, and acceptance criterion.

## 6. Frozen metric protocol

### D1 — Platform footprint and readiness

Run with no application workload deployed.

| Metric | Boundary/instrument | Repetitions |
|---|---|---:|
| Platform cold readiness | Host monotonic time immediately before `multipass start` until Docker API ready, or k3s API + Node + kube-system + Traefik ready | 6 |
| Idle process RSS | After 300 s stabilization, sample the unique platform process set once per second for 60 s; the run value is the median | 6 |
| Idle CPU | Platform process/cgroup CPU delta over the same 60 s, normalized to four-vCPU capacity | 6 |
| VM memory/CPU | One-second VM-wide series during the same window, reported as supporting evidence | 6 |
| Disk footprint | Clean-OS→platform and platform→preloaded-image deltas | 1 per platform |

The formal REQ-O-001 memory verdict continues to use process RSS for
traceability to the registered criterion. Cgroup and VM-wide values are
supporting evidence and are not substituted post hoc.

### D2 — Lifecycle time and availability

Each repetition executes clean install → upgrade → rollback.

The timer starts immediately before the platform-native command and stops when:

1. the expected application image reference is running;
2. submission, management, and Keycloak public endpoints return their expected
   responses; and
3. all three checks pass three consecutive times at 250 ms intervals.

Images are already local. The operation timeout is 600 s.

For upgrade and rollback, a 10 req/s constant-arrival workload starts 15 s
before command invocation and stops 15 s after the completion condition. Record
operation duration, offered requests, accepted HTTP-201 responses, all failures,
longest consecutive unavailable interval, and downstream completion. The k3s
zero-downtime criterion permits no failed availability sample.

Install, upgrade, and rollback are each repeated six times per platform. Manual
step counts are derived once from the frozen runbooks; one human-entered
top-level command counts as one step.

### D3 — Fixed-load workload behavior

Each repetition uses this exact sequence:

1. deploy a fresh stack with preloaded images;
2. prime at 5 req/s for 30 s; discard the priming results;
3. wait until outbox, broker, and inbox backlog are empty;
4. submit at 10 req/s for 60 s;
5. poll downstream completion for at most 60 s;
6. record the final backlog and reset the application state.

Record:

- offered requests and executed requests;
- accepted HTTP-201 goodput;
- latency p50, p95, and p99;
- non-201 responses, connection errors, timeouts, and dropped iterations;
- downstream completion count and ratio;
- asynchronous completion-lag p50, p95, and p99;
- one-second workload and VM CPU/memory series;
- image-warm submission-service start command to public readiness.

There is no ramp, stress, soak, or capacity test in the thesis campaign.

## 7. Fixed repetitions and execution order

There are exactly six final paired blocks, split across three sessions. This
exceeds the proposal's minimum of five runs and gives equal order balance.

| Session | Block | Fixed order |
|---:|---:|---|
| 1 | 1 | Compose → k3s |
| 1 | 2 | k3s → Compose |
| 2 | 3 | k3s → Compose |
| 2 | 4 | Compose → k3s |
| 3 | 5 | Compose → k3s |
| 3 | 6 | k3s → Compose |

Before each platform leg, restore that VM's verified clean snapshot and run the
preflight. Each leg executes D1 → reset → D2 → reset → D3. Only the current
leg's VM may run.

## 8. Frozen data and analysis rules

- Generate one immutable campaign ID from UTC timestamp and Git commit.
- Refuse an existing campaign directory; there is no implicit append mode.
- Store the commit, dirty status, protocol version, parameters, profile hashes,
  preflight, VM/tool versions, image digests, order, raw metrics, time series,
  logs, and per-run summaries.
- Report all six raw values, median, IQR, minimum, and maximum.
- For Compose context, report paired k3s-minus-Compose differences and ratios.
- Do not perform null-hypothesis significance tests with this small PoC sample.
- Do not pool request-level observations across runs as if they were independent.
- Do not remove outliers. If IQR exceeds 20% of the median, report the
  instability and investigate it in the threats-to-validity section.
- Do not add runs because a platform result is slow, failed, or inconvenient.

### Invalid-run rule

A platform/application failure is a valid result. A run is invalid only for an
independently identifiable measurement failure: preflight failure, host power
loss, load-generator/tool crash, corrupt/missing artifact, or operator executing
the wrong frozen command.

An invalid run remains archived with its reason. Repeat the entire matched block
at the end using the same order. If a systemic harness defect is discovered,
abort the campaign, fix it before a new freeze tag, and restart the complete
campaign from block 1.

## 9. Change-control rule

The following cannot change after this baseline is approved:

- research role of k3s and Compose;
- included platforms and profiles;
- topology and VM allocation;
- thresholds and qualification gates;
- metric definitions and timing boundaries;
- load rate and duration;
- run count and order;
- reset, invalid-run, and analysis rules.

Before `thesis-campaign-v1.0`, code may be corrected only to implement this
plan. After that tag, any source, configuration, image, tool, protocol, schema,
or analysis change invalidates the entire final campaign. The change requires a
written deviation, a new version/tag, and a restart from block 1. Results from
different versions are never combined.

## 10. Final definition of done

The bachelor-thesis implementation is complete when:

- the research documents and repository describe this same frozen plan;
- two excluded pilot blocks and six final paired blocks validate completely;
- the k3s verdict is traceable to all SRQ1/SRQ2 criteria;
- the Compose comparison uses the same workload artifacts and conditions;
- a clean GitOps rebuild, demo, requirements run, kube-bench run, and
  observability proof exist for the frozen tag;
- the report can be regenerated from a clean clone and the archived raw data;
- no final claim is broader than the measured PoC profiles.
