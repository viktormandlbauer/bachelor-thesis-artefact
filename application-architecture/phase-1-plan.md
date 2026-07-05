# Phase 1 Implementation Plan — Traceable Microservice POC (Quarkus + Artemis AMQP + OpenTelemetry/SigNoz)

## Context

The repo (`bachelor-thesis-artefact`) currently contains only architecture documents — no code. [phase-1-plan.md](application-architecture/phase-1-plan.md) fully specifies a minimal two-service POC whose core thesis artifact is: **each HTTP-triggered user action produces one distributed trace that survives the synchronous → asynchronous hand-off across ActiveMQ Artemis (AMQP 1.0)**, and all traces for one case are discoverable as a conversation-correlated trace graph via `case.id`. This plan turns that spec into an executable build. The spec is authoritative for API/event contracts (§4, §5); this plan pins versions, resolves the §11 ambiguities, and maps requirements onto concrete Quarkus mechanisms.

**Note:** `.git` exists but is empty — run `git init` first and commit incrementally.

## Resolved decisions (§11 ambiguities, confirmed with user)

| Decision | Choice |
|---|---|
| Quarkus platform | **3.33 LTS** (pin latest 3.33.x patch at implementation time), Java 21, Maven |
| Artemis image | **apache/activemq-artemis:2.53.0** (pinned) |
| SigNoz | **Bundled in compose** (pinned SigNoz release, adapted from official docker-compose: ClickHouse + signoz + signoz-otel-collector), services export OTLP gRPC to the collector; endpoint still env-configurable |
| Run mode | **Both**: full compose for the reviewer demo (Artemis + SigNoz + both services, with Dockerfiles); `quarkus dev` against composed Artemis+SigNoz for the inner loop |
| Span links | **First pass**: application-level "author" span with `SpanBuilder.addLink()` to the stored context of the latest prior opposite-direction event |
| Span-link target policy | Latest prior opposite-direction event (spec default) |

## Repo layout (per spec §8.1)

```
├── submission-service/        # Quarkus, own pom, own Dockerfile (src/main/docker)
├── management-service/        # Quarkus, own pom, own Dockerfile
├── infra/
│   ├── docker-compose.yml     # artemis + both services (+ shared network)
│   ├── artemis/broker.xml     # addresses, durable anycast queues, DLQ, bounded redelivery
│   └── signoz/                # pinned SigNoz compose (clickhouse, signoz, otel-collector)
├── scripts/
│   ├── demo.sh                # curl+jq happy path (§8.4)
│   └── resilience.sh          # §8.5 checks (wrong token, blank msg, duplicate, DLQ)
└── docs/architecture.md       # restated architecture + observability smoke-test guide (§5.5)
```

DTOs are small and **duplicated per service** (spec §10.4 — no shared domain library): `CaseEvent`, request/response records.

## Per-service implementation

### Common (both services)

- Extensions: `quarkus-rest`, `quarkus-rest-jackson`, `quarkus-messaging-amqp`, `quarkus-opentelemetry`, `quarkus-smallrye-health`.
- Config (all env-overridable, no hardcoding): AMQP host/port/user/password (`quarkus.qpid-jms.*`/connector attrs), `quarkus.otel.exporter.otlp.traces.endpoint` (default `http://localhost:4317`; in compose → signoz collector), `quarkus.application.name`, `quarkus.otel.resource.attributes=service.namespace=anonymous-case-poc,deployment.environment=local`.
- In-memory stores: `ConcurrentHashMap<String, CaseRecord>` (case → status + `CopyOnWriteArrayList<MessageRecord>`), `ConcurrentHashMap.newKeySet()` for processed `eventId`s, per-case `AtomicLong` for `seq`. `MessageRecord` stores `traceContext` (traceId, spanId, traceFlags, tracestate) captured from `Span.current().getSpanContext()` on both authoring and consumption (§5.4).
- **Commit-after-publish** (§7.5): build staged records → publish via `MutinyEmitter<CaseEvent>.sendMessage(...)` and **await completion** (`.await().atMost(...)` or return `Uni` from the endpoint) → only then put records into the visible store. Publish failure → `503`, staged records dropped. AMQP messages sent durable with `OutgoingAmqpMetadata` carrying `caseId`, `eventId`, `direction` application properties (§5.2).
- Consumers: `@Incoming` method, dedupe by `eventId` (duplicate → log + ack, never double-post), invalid/malformed payload → **throw** (fail loudly). Failure strategy `modified-failed` so Artemis increments delivery count, redelivers boundedly, then routes to DLQ (§6.2). Ack happens post-processing (default).
- Span enrichment on every REST/consume/author span where values exist: `case.id`, `conversation.id`, `event.id`, `message.direction`, `message.author` + messaging conventions `messaging.system=activemq`(as emitted by instrumentation), `messaging.destination.name`, `messaging.message.id=<eventId>`, `messaging.message.conversation_id=<caseId>` (§5.4). Small shared-per-service helper class `TraceAttributes` to keep this consistent.
- Span links: when authoring an event, wrap the publish in a `tracer.spanBuilder("author case.<direction> event")` span with `.addLink(storedPrevContext)` — management reply links to latest consumed inbound event; submission follow-up links to latest consumed outbound event; initial submission has no link.
- Tokens never in logs, spans, AMQP props, exceptions, or test snapshots (§6.3).
- Health: `/q/health/live` + `/q/health/ready`; AMQP connector participates in readiness (default `health-enabled`).

### submission-service (port 8080)

- `POST /api/cases` → 201: validate non-blank → `caseId`/`eventId` UUIDs → token = 32 bytes `SecureRandom` Base64url (256 bits) → store **SHA-256 hash only** → stage case+message → publish `case.inbound` → commit → return `{caseId, eventId, accessToken, note}`.
- `GET /api/cases/{caseId}` with `X-Case-Token` → 200 thread (sorted `createdAt`, tie-break `eventId`) | **404** on missing case OR missing/wrong token (constant-time compare via `MessageDigest.isEqual` on hashes).
- `POST /api/cases/{caseId}/messages` → 202 `{caseId, eventId, status}`; same token rule; commit-after-publish.
- Consumes `case.outbound` from durable queue via **FQQN address `case.outbound::case.outbound.submission`**, `durable=true` (§7.4 — verify exact connector attr against Quarkus 3.33 docs; FQQN in the `address` attribute is the standard Artemis mechanism).
- Publishes to address `case.inbound`.

### management-service (port 8081)

- `GET /api/cases?status=open` → 200 list `{caseId, status, messageCount, createdAt, updatedAt}`.
- `GET /api/cases/{caseId}` → 200 detail+thread | 404.
- `POST /api/cases/{caseId}/reply` → 202 `{caseId, eventId, status}` | 400 | 404 | 503; author fixed `"management"`; commit-after-publish.
- Consumes `case.inbound` via FQQN `case.inbound::case.inbound.management`; publishes to address `case.outbound`.
- Unauthenticated (Phase 1, local-compose only).

### Event payload (§5.1, both directions)

`{eventId, caseId, direction, author, seq, body, createdAt}` as JSON body; trace context auto-propagated in AMQP application properties by Quarkus OTel + SmallRye AMQP (do **not** hand-roll `traceparent` unless auto-propagation fails — then document it).

## Infrastructure

- **broker.xml**: addresses `case.inbound` (anycast queue `case.inbound.management`), `case.outbound` (anycast queue `case.outbound.submission`), both durable; `DLQ` address; address-setting matching the case addresses with `max-delivery-attempts=3`, small `redelivery-delay`, `dead-letter-address=DLQ`. Mounted into the pinned Artemis container (etc-override mechanism of the apache image).
- **infra/docker-compose.yml**: artemis (AMQP 61616/5672 + console 8161), submission-service, management-service (built from Dockerfiles, env for AMQP + OTLP), shared network with the SigNoz stack; SigNoz under `infra/signoz/` from the official pinned compose (document its RAM appetite). Services depend_on artemis healthy.
- `quarkus dev` inner loop: compose up artemis+signoz only; dev services for AMQP **disabled** when the local broker is configured (avoid surprise Testcontainers broker in dev; tests use Dev Services deliberately).

## Tests (per spec §10.18)

JUnit + RestAssured `@QuarkusTest` per service; AMQP Dev Services (Testcontainers Artemis) for publish/consume paths — requires Docker at test time.
- Validation: blank/missing message → 400.
- Token: wrong/missing → 404 (not 403); correct → 200.
- Dedupe: same `eventId` delivered twice → one thread entry.
- Ordering: render by `createdAt`, tie-break `eventId`.
- Commit-after-publish: store-level unit test — staged record invisible until publish completes; failure path leaves store unchanged (simulate emitter failure).
- Happy path: submission consume→store; management consume→store.

## Build order

1. `git init`; scaffold both services (Quarkus 3.33 LTS, Maven, Java 21) + extensions; health endpoints; verify both boot.
2. DTOs + in-memory stores + token gen/hash/constant-time compare.
3. REST endpoints + validation + response codes (both services), stores wired, no AMQP yet.
4. broker.xml + compose (artemis); AMQP channels: publish (durable, awaited, metadata) + FQQN consumers; commit-after-publish; idempotent consume; failure strategy.
5. OTel: resource attrs, domain+messaging span attributes, stored trace contexts, span links.
6. SigNoz compose integration + service Dockerfiles + full-compose wiring.
7. `scripts/demo.sh` + `scripts/resilience.sh`.
8. Tests (§ above).
9. `docs/architecture.md` incl. §5.5 smoke-test walkthrough + §8.6 trace demo checklist.

## Verification (definition of done)

1. `docker compose up` (infra + signoz) → both services ready (`/q/health/ready`).
2. Run `scripts/demo.sh`: full §3.4 loop passes (submit → visible on management → reply → visible on submission → follow-up → visible on management).
3. Run `scripts/resilience.sh`: wrong token 404, blank 400, duplicate event no double-post, management-service down→up consumes buffered message, poison message lands in DLQ after 3 attempts (inspect via Artemis console).
4. SigNoz smoke test (§5.5): submission trace = HTTP span (submission) → AMQP publish `case.inbound` → receive/process (management); reply trace mirror-image via `case.outbound`; attributes present (`case.id`, `conversation.id`, `event.id`, messaging conventions, service.namespace/deployment.environment); **filter by `case.id` returns all traces of the case**; reply/follow-up traces carry span links to prior opposite-direction event.
5. `mvn test` green in both services.

## Risks / verify against pinned docs during implementation

- Exact Quarkus 3.33 connector attribute names for durable FQQN consumption and `failure-strategy` values (`modified-failed` semantics vs Artemis delivery counting) — the spec explicitly delegates exact property names to the pinned docs (§7.3/§7.4).
- Reactive-messaging OTel instrumentation must be active by default in 3.33 (`quarkus.otel.instrument.*`); confirm publish/consume spans join one trace before layering span links.
- SigNoz compose resource footprint on the dev machine (ClickHouse); pin a SigNoz release and document required RAM.
- Windows host: demo scripts are bash (Git Bash available); document that.
