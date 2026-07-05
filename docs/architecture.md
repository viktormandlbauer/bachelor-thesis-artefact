# Phase 1 — Architecture & Runbook

Implementation of [application-architecture/phase-1-plan.md](../application-architecture/phase-1-plan.md):
a minimal, fully traceable microservice pair that proves **one distributed trace per
HTTP-triggered user action across an asynchronous ActiveMQ Artemis (AMQP 1.0) hop**, with
the whole case conversation discoverable in SigNoz as a **conversation-correlated trace
graph** via `case.id` / `conversation.id`.

## 1. System overview

```text
curl ──POST /api/cases──────────▶ submission-service ──publish case.inbound──▶ [Artemis] ──▶ management-service
curl ──POST /api/cases/{id}/reply▶ management-service ──publish case.outbound─▶ [Artemis] ──▶ submission-service
                                        │                                                        │
                                        └───────────── OTLP traces ──▶ SigNoz collector ◀────────┘
```

- The two Quarkus services integrate **only** through Artemis — no direct calls.
- Trace context (W3C `traceparent`) is carried in AMQP application properties by the
  Quarkus OpenTelemetry + SmallRye AMQP connector instrumentation; no manual injection.
- Each user action is one trace. Conversation continuity comes from correlation
  attributes on every span (`case.id`, `conversation.id`, `event.id`) plus **span links**
  from each authored event to the latest prior opposite-direction event of the same case.

### Pinned versions

| Component | Version |
|---|---|
| Quarkus platform | 3.33.2.1 (LTS), Java 21, Maven |
| ActiveMQ Artemis | apache/activemq-artemis:2.44.0 (newest image published on Docker Hub) |
| SigNoz | v0.129.0 (last release with docker-compose manifests; vendored in `infra/signoz/`) |
| SigNoz otel-collector | v0.144.5 |

### Repository layout

```text
submission-service/   Quarkus: anonymous submit + token-gated thread + consumes case.outbound
management-service/   Quarkus: open case list/detail + reply + consumes case.inbound
infra/
  docker-compose.yml  Artemis + both services (joins signoz-net)
  artemis/broker.xml  addresses, durable queues, DLQ, bounded redelivery
  signoz/             vendored SigNoz stack (UI on host port 3301)
scripts/
  demo.sh             happy path (plan §8.4)
  resilience.sh       resilience checks (plan §8.5)
docs/architecture.md  this file
```

## 2. Messaging design

| Address | Durable queue | Producer | Consumer |
|---|---|---|---|
| `case.inbound` | `case.inbound.management` | submission-service | management-service |
| `case.outbound` | `case.outbound.submission` | management-service | submission-service |
| `DLQ` | `DLQ` | Artemis (dead-lettering) | manual inspection |

- Consumers bind to the concrete durable queue via the Artemis **FQQN** in the channel
  address (`case.inbound::case.inbound.management`), producers stay address-oriented
  (plan §7.4).
- Events are JSON (`eventId`, `caseId`, `direction`, `author`, `seq`, `body`,
  `createdAt`) sent durable, with `caseId`/`eventId`/`direction` duplicated into AMQP
  application properties for broker-side inspection (plan §5).
- **Commit-after-publish** (plan §7.5): REST endpoints stage local records, send via an
  `Emitter`, and block until the broker settles the message (ack/nack callback with a
  10s timeout, `app.publish-timeout`). Success → staged state committed and 201/202
  returned; failure → 503 and no visible local state. There is no outbox in Phase 1: a
  timeout can still mean the broker delivers later, in which case the receiving side
  knows an event the authoring side never committed (accepted, documented gap; closed by
  the Phase 2 outbox).
- **Idempotency**: consumers dedupe by `eventId` (in-process set; does not survive
  restart — durable idempotency is Phase 2). Dedup is checked before processing and
  marked after, so a crash mid-processing still allows redelivery.
- **Fail loudly**: malformed events, wrong-direction events, unknown-case replies, and
  the `__poison__` demo marker all throw. The channel's
  `failure-strategy=modified-failed` nacks with `delivery-failed=true`, Artemis counts
  the attempt, redelivers at most 3 times (1s delay), then routes to `DLQ`
  (`infra/artemis/broker.xml`, address-setting `case.#`).

## 3. Security model (Phase 1 scope)

- Case access token: 32 bytes `SecureRandom` → base64url (256 bits entropy), returned
  **once** in the `POST /api/cases` response.
- Only the SHA-256 hash is stored; presented tokens are hashed and compared with
  `MessageDigest.isEqual` (constant time).
- Wrong/missing token → **404** (never 403), so case existence is not confirmed.
- Tokens never appear in logs, spans, AMQP messages/properties, or error messages.
- Management API is **unauthenticated** — local compose only (Keycloak is Phase 2+).

## 4. Observability model

Resource attributes on both services: `service.name` (= `quarkus.application.name`),
`service.namespace=anonymous-case-poc`, `deployment.environment=local`.

Every relevant span (HTTP server, author/publish, consume/process) carries:

```text
case.id, conversation.id           (= caseId)
event.id                           (= eventId)
message.direction                  inbound | outbound
message.author                     submission | management
messaging.destination.name         case.inbound | case.outbound
messaging.system                   activemq
messaging.message.id               (= eventId)
messaging.message.conversation_id  (= caseId)
```

Domain attributes and OTel messaging-convention attributes are emitted side by side
(plan §5.4). Each authored or consumed message record stores its span context in memory;
when a later action is authored for the same case, the publisher opens an
`author case.<direction> event` span with a **span link** to the latest prior
opposite-direction event context (plan §11 default policy).

### Trace anatomy per user action

- `POST /api/cases` (and `/messages`): HTTP server span (submission-service) →
  `author case.inbound event` → AMQP send span → AMQP receive/process span
  (management-service). Follow-ups link back to the last consumed reply.
- `POST /api/cases/{id}/reply`: HTTP server span (management-service) →
  `author case.outbound event` (link to last consumed inbound event) → AMQP send →
  AMQP receive/process span (submission-service).

## 5. Runbook

Prerequisites: Docker + Compose, and for the host inner loop JDK 21 + Maven. Scripts
need bash, curl, jq (Git Bash works on Windows).

```bash
# 1. Observability stack first (creates the shared signoz-net network; ~2-3 GB RAM)
docker compose -f infra/signoz/docker-compose.yaml up -d
# SigNoz UI: http://localhost:3301 (first visit creates the admin account)

# 2. Broker + services
docker compose -f infra/docker-compose.yml up -d --build
# submission-service: http://localhost:8080, management-service: http://localhost:8081
# Artemis console:    http://localhost:8161 (artemis/artemis)

# 3. Health
curl http://localhost:8080/q/health/ready
curl http://localhost:8081/q/health/ready
# The AMQP connector participates in readiness: services are only ready with a broker connection.

# 4. Demo + resilience checks
./scripts/demo.sh
./scripts/resilience.sh
```

Faster inner loop: `docker compose -f infra/docker-compose.yml up -d artemis`, then run
each service on the host with `mvn quarkus:dev` (defaults point at `localhost:5672` and
OTLP `localhost:4317`; run the second dev instance with `-Ddebug=false` to avoid the
debug-port clash).

Tests (`mvn test` in each service) start a throwaway Artemis via Quarkus Dev Services /
Testcontainers — Docker must be running; no local broker needed and no OTLP exporter is
used in the test profile.

## 6. Observability smoke test (plan §5.5)

1. Run `./scripts/demo.sh`; note the printed `caseId` and the three `eventId`s.
2. Open SigNoz → Traces (http://localhost:3301).
3. Filter by tag: `case.id = <caseId>` (or `conversation.id`). Expect **three traces**,
   one per user action (submit, reply, follow-up) — the conversation-correlated trace
   graph.
4. Open the submit trace and confirm, in one trace:
   - `POST /api/cases` HTTP server span in `submission-service`,
   - `author case.inbound event` span (+ AMQP send span) toward `case.inbound`,
   - AMQP receive/process span in `management-service`.
5. Open the reply trace and confirm the mirror image via `case.outbound`
   (management HTTP span → author/publish → submission receive/process), and that the
   `author case.outbound event` span has a **span link** to the inbound event context.
6. Confirm the follow-up trace links back to the consumed reply event.
7. Spot-check span attributes: `case.id`, `conversation.id`, `event.id`,
   `message.direction`, `message.author`, `messaging.destination.name`,
   `service.namespace`, `deployment.environment`.

### Trace demo checklist (plan §8.6)

For each direction record: the request used, resulting `caseId`/`eventId`, the SigNoz
trace ID, and a screenshot showing HTTP + AMQP send + AMQP receive/process spans across
both services, plus a screenshot of the `case.id` filter returning all traces of the
conversation. `demo.sh` prints everything needed.

## 7. Resilience demonstrations (plan §8.5)

`./scripts/resilience.sh` (compose stack required) verifies:

1. Wrong/missing token → 404; unknown case → 404.
2. Blank message → 400 on all three write endpoints.
3. Duplicate delivery dedupe — covered by JUnit consumer tests (in-process idempotency).
4. Consumer downtime: management-service stopped → follow-up still accepted (202,
   durable queue buffers) → after restart the buffered event is consumed.
5. Poison message: a reply with body `__poison__` makes the submission consumer throw;
   after 3 redeliveries Artemis routes it to `DLQ` (count checked via `artemis queue stat`).
6. The poison message does not block subsequent valid messages.

## 8. Known Phase 1 limits (by design, see plan §9)

- In-memory state: restarts lose cases, threads, token hashes, and dedupe sets; both
  services are single-replica. No autoscaling before persistence.
- No outbox: the publish-timeout edge (event delivered but 503 returned) is accepted.
- Management API unauthenticated; no TLS; polling only (no push).
- Span links target only the latest prior opposite-direction event, and the stored link
  context lives in memory (lost on restart; correlation attributes still work).
