# Anonymous Case Management PoC — Bachelor Thesis Artefact

A cloud-native proof of concept built to *demonstrate* (not ship) production-grade
patterns: two Quarkus services — `submission-service` for anonymous reporters,
`management-service` for staff — that integrate **only** through an ActiveMQ Artemis
broker, made reliable with a transactional outbox/persistent inbox over PostgreSQL,
authenticated with Keycloak OIDC, traced end-to-end with OpenTelemetry/SigNoz,
developed compose-first, and promoted onto a CIS-hardened k3s cluster (dedicated
control-plane VM — which doubles as Ansible controller and compose-infra host
running SigNoz, Keycloak, PostgreSQL, an internal GitLab as the GitOps source
and an internal Harbor registry — plus workers carrying only the application
stack) managed by Argo CD GitOps. A measurement harness compares the k3s
platform against docker compose and podman `kube play` running the identical
workload.

## The four tracks

| Track | Proves | Status / evidence |
|---|---|---|
| Phase 1 app | One distributed trace per user action across an async AMQP hop | Superseded — [docs/phase-1-architecture.md](docs/phase-1-architecture.md) |
| Phase 2 app | Same flow with durable state, reliable messaging (outbox/inbox), OIDC | Done, verified — [docs/e2e-messaging-architecture.md](docs/e2e-messaging-architecture.md) |
| Cluster (k3s PoC) | CIS-clean k3s (kube-bench **0 FAIL** with workload), git-defined state, requirements catalogue **0 FAIL** | Done — [docs/k8s-poc.md](docs/k8s-poc.md), reports in [docs/reports/](docs/reports/) |
| Measurement (SRQ3) | What k3s costs vs. compose/podman, and what the cost buys | Harness smoke-verified; full campaign pending — [docs/measurement-comparison.md](docs/measurement-comparison.md) |

## Repository layout

```text
application-architecture/   Design history: phase plans, implementation log, deferred work
docs/                       Architecture, runbooks, review, measurement method
  reports/                  Dated evidence (kube-bench, requirements validation, measurements)
submission-service/         Quarkus: anonymous submit + token-gated thread (reporter side)
management-service/         Quarkus: case list/detail/reply, OIDC-protected (staff side)
infra/                      Compose stack: Artemis, PostgreSQL, Keycloak (+ vendored SigNoz)
deploy/                     k3s track: Ansible VM provisioning, k3s hardening, Argo CD, Helm chart
scripts/                    Bring-up, demos, kube-bench, secrets bootstrap, requirements validation
measure/                    SRQ3 comparative measurement harness (compose / podman / k3s)
```

## Running it

**Locally (compose)** — Docker + Compose, JDK 21/Maven only for the dev loop:

```bash
docker compose -f infra/signoz/docker-compose.yaml up -d   # observability first (signoz-net)
docker compose -f infra/docker-compose.yml up -d --build   # broker, DB, Keycloak, services
./scripts/demo.sh                                          # two-way case thread + trace IDs
./scripts/resilience.sh                                    # DLQ, consumer-downtime, token checks
```

Details: runbook in [docs/phase-1-architecture.md](docs/phase-1-architecture.md) §5
(commands unchanged for Phase 2), semantics in
[docs/e2e-messaging-architecture.md](docs/e2e-messaging-architecture.md).

**On k3s (Multipass VM)** — bring-up from scratch:
[docs/k8s-poc.md](docs/k8s-poc.md); day-2 interaction (kubectl, API, deploying via
GitOps, consoles, troubleshooting): [docs/k8s-poc-usage.md](docs/k8s-poc-usage.md).

**Measurements** — [measure/README.md](measure/README.md); method and threats to
validity: [docs/measurement-comparison.md](docs/measurement-comparison.md).

## Documentation index

| Document | Content |
|---|---|
| [docs/e2e-messaging-architecture.md](docs/e2e-messaging-architecture.md) | Current messaging architecture: outbox → Artemis → inbox, end-to-end sequence, design rationale |
| [docs/k8s-poc.md](docs/k8s-poc.md) | Cluster runbook: hardened k3s + Argo CD bring-up, how the kube-bench pass is achieved |
| [docs/k8s-poc-usage.md](docs/k8s-poc-usage.md) | Day-2 usage of the running cluster |
| [docs/requirements-validation.md](docs/requirements-validation.md) | How the thesis requirements catalogue is validated (method, verdict semantics) |
| [docs/measurement-comparison.md](docs/measurement-comparison.md) | SRQ3 platform-comparison method: metrics, parity controls, capability matrix |
| [docs/architecture-review.md](docs/architecture-review.md) | Full-project review: per-layer assessment, gaps, principles catalogue (§6) for the thesis |
| [docs/phase-1-architecture.md](docs/phase-1-architecture.md) | Phase 1 baseline architecture & compose runbook (superseded by Phase 2) |
| [application-architecture/](application-architecture/) | Phase 1/2 plans, Phase 2 implementation log, deferred future work |
| [docs/reports/](docs/reports/) | Dated evidence: kube-bench runs, requirements-validation reports, rebuild log, measurements |

## Pinned versions (top level)

Quarkus 3.33.2.1 (Java 21) · Artemis 2.44.0 · PostgreSQL 17 · Keycloak 26.3 ·
k3s v1.36.2+k3s1 · Argo CD v3.4.4 · SigNoz v0.129.0 — full tables in
[docs/phase-1-architecture.md](docs/phase-1-architecture.md) and
[docs/k8s-poc.md](docs/k8s-poc.md).
