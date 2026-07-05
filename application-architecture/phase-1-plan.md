# Phase 1 — Minimal Traceable Microservice Architecture (Quarkus + AMQP + OpenTelemetry)

> **Scope of this document.** This is the *first, intentionally minimal* build derived from the full POC prompt. The goal is a clean, end-to-end **distributed trace per HTTP-triggered user action** that survives a synchronous → asynchronous hand-off across ActiveMQ Artemis (AMQP), plus a **whole-conversation observability model** that correlates all action traces for one case into a trace graph. Everything not required to prove that — Keycloak/auth, database persistence, attachments + AV scanning + object storage, autoscaling, Kubernetes/Helm, and Angular frontends — is **deferred**, with re-integration notes in §9 (Future Considerations). Hand this to the coding assistant as-is; it should restate the architecture, propose a build order, and flag ambiguities before generating code.

> **Important tracing clarification.** Do **not** attempt to force the whole conversational lifecycle into one long-lived OpenTelemetry trace. Each HTTP-triggered action should produce its own distributed trace across the relevant AMQP hop. The entire case conversation is modeled as a **conversation-correlated trace graph**: all related traces share stable correlation attributes such as `case.id`, `conversation.id`, and `event.id`, and later actions should add span links to the most recent related event context where practical. The mandatory Phase 1 acceptance criterion is both successful AMQP trace propagation **per direction** and whole-conversation discoverability by `case.id`.

---

## 1. Goal & Non-Goals for Phase 1

**The one thing to prove:** complete distributed traces, viewable in one backend UI, for each direction of the workflow, while the full case conversation is discoverable as a correlated trace graph by `case.id`:

**Submission → management trace**

```text
HTTP request
  → submission-service
  → AMQP publish case.inbound
  → [Artemis]
  → AMQP consume case.inbound
  → management-service
```

**Management → submission trace**

```text
HTTP request
  → management-service
  → AMQP publish case.outbound
  → [Artemis]
  → AMQP consume case.outbound
  → submission-service
```

Trace context must be carried **through Artemis message properties**, so the async hop does not break the trace. This is the part HTTP-only tracing setups do not get for free, and it is the core thesis artifact. Cross-action conversation continuity is modeled separately through correlation attributes and optional span links, not by keeping one trace open for the whole human conversation.

**In scope (Phase 1)**

- Two independently deployable Quarkus services integrating **only** through Artemis (AMQP 1.0), never through direct service-to-service calls.
- A **two-way, text-only message thread** tied to one `caseId`: submission-side user ↔ management-side user, every cross-service hop crossing Artemis.
- `quarkus-opentelemetry` auto-instrumentation of REST and AMQP messaging, exporting OTLP to a configurable backend that is set up outside this plan.
- Whole-conversation trace graph: all action traces for one case should be discoverable by `case.id` / `conversation.id`, with `event.id` on message-level spans and optional span links between causally related events.
- Idempotent consumers, a dead-letter path, bounded redelivery, and readiness/liveness probes — the cheap resilience primitives.
- `docker-compose` to run everything locally; no cluster required.

**Out of scope (Phase 1)**

- One single long-lived OpenTelemetry trace ID for the whole case conversation across multiple later HTTP requests.
- Database persistence and restart-safe deduplication.
- Authentication for management APIs.
- Object storage, attachments, virus scanning, Kubernetes, autoscaling, and production TLS/ingress.
- WebSockets or push-based updates.

> **Architectural coupling to remember:** because Phase 1 stores state in memory, both services are effectively **single-replica**. Do **not** introduce autoscaling before persistence lands.

---

## 2. Components

| Component | Tech | Responsibility |
|---|---|---|
| `submission-service` | Quarkus | Accepts a text submission (`POST /api/cases`), issues an access token, serves the token-gated case/thread API, publishes `case.inbound`, consumes `case.outbound`. In-memory store. |
| `management-service` | Quarkus | Consumes `case.inbound`, exposes an open case list + detail, accepts a management reply that publishes `case.outbound`. In-memory store. |
| Artemis | ActiveMQ Artemis | AMQP 1.0 broker for `case.inbound` / `case.outbound` — the only integration point. Durable anycast queues, DLQ, and bounded redelivery configured. |
| Observability | SigNoz (OTLP-capable) | Single OTLP destination for traces and, optionally, metrics/logs later. SigNoz is provided outside this implementation plan and wired in through the OTLP endpoint. |

---

## 3. Functional Requirements

### 3.1 Submission: submission → management

1. Anonymous client sends `POST /api/cases` with JSON:

   ```json
   { "message": "<required non-empty text>" }
   ```

2. `submission-service`:
   - Validates that the message is present and non-empty after trimming.
   - Creates a `caseId` as a UUID.
   - Creates the initial in-memory case record as a staged object, not yet visible through the API.
   - Creates an `eventId` as a UUID for the initial message.
   - Generates a high-entropy access token with at least 128 bits of entropy.
   - Stores **only a SHA-256 hash** of the token in memory, never the plaintext token.
   - Builds the first local message record as a staged object, not yet visible through the API.
   - Publishes a `case.inbound` event to Artemis; see §5.
   - Waits for the AMQP publish to complete successfully.
   - Commits the staged case and first message to the visible in-memory store only after the publish has completed successfully.
   - Returns `201` with the `caseId`, the initial `eventId`, the plaintext access token, and a “save this, it cannot be recovered” note.

3. `management-service` consumes `case.inbound` and stores the case in memory as `open`, appending the message to its own copy of the thread.

**No outbox in Phase 1.** Because there is no database/outbox, publish failure semantics must be simple and explicit: do not return a successful response unless the AMQP publish completes successfully. If publishing fails, return `503 Service Unavailable`. Do not create or expose user-visible local state that pretends the cross-service message was delivered. For authored events, use commit-after-publish; staged local records become visible only after the broker accepts the message.

### 3.2 Anonymous tracking & follow-ups: submission side

- The access token is the **only** credential.
- `GET /api/cases/{caseId}` with the token in an `X-Case-Token` header returns:

  ```json
  {
    "status": "open",
    "messages": []
  }
  ```

- Follow-ups: `POST /api/cases/{caseId}/messages` with the token header and JSON body:

  ```json
  { "message": "<required non-empty text>" }
  ```

- On a valid follow-up, `submission-service` creates a new `eventId`, stages the local message, publishes another `case.inbound` event, waits for AMQP publish completion, and only then appends the message to the visible local thread.
- A successful follow-up response returns the `caseId`, the new `eventId`, and a success status. Use `202 Accepted` consistently for follow-up messages because the remote side may not have consumed the event yet.
- If publishing fails, return `503 Service Unavailable` and do not append the staged message locally.
- The token is validated by hashing the header value and comparing it to the stored hash using a constant-time comparison.
- Wrong or missing token → `404 Not Found`, not `403`, to avoid confirming that a case exists.

### 3.3 Management case handling: management → submission

- `GET /api/cases?status=open` returns the open-case list.
- `GET /api/cases/{caseId}` returns detail + thread.
- Management APIs are **open and unauthenticated in Phase 1**; see §9.1.
- Reply: `POST /api/cases/{caseId}/reply` with JSON:

  ```json
  { "message": "<required non-empty text>" }
  ```

- On a valid management reply, `management-service` creates a new `eventId`, stages the local reply, publishes a `case.outbound` event, waits for AMQP publish completion, and only then appends the reply to the visible local thread.
- A successful reply response returns the `caseId`, the new `eventId`, and a success status. Use `202 Accepted` consistently for management replies because the submission service may not have consumed the event yet.
- If publishing fails, return `503 Service Unavailable` and do not append the staged reply locally.
- `submission-service` consumes `case.outbound` and appends the reply to that case's thread, visible on the next submission-side `GET`.

### 3.4 Two-way anonymous channel — acceptance criterion

The above must add up to one demonstrable feature: **a two-way, anonymous, text message thread carried entirely over Artemis.** Stated as a contract so it is not lost:

- **Asymmetric identity, Phase 1 form.** The submission-side user is identified only by the access token. The management author is a fixed placeholder identity for now: `"management"`. Real Keycloak identity arrives in §9.1. Submission-side users can only access their own case via token. Management-side isolation is deferred until auth is added.
- **Transport is the queue, only the queue.** No direct service-to-service calls. `case.inbound` = submission→management. `case.outbound` = management→submission. Each side consumes the other side's queue and appends to its own copy.
- **Correlation & ordering.** Every message binds to one `caseId` and carries a `createdAt` timestamp plus monotonic-ish `seq` from its authoring service. Both sides render by `createdAt`, tie-breaking by `eventId`. Do **not** rely on broker delivery order. Clock skew between services is acceptable for the POC.
- **Delivery semantics.** At-least-once delivery means both consumers must be idempotent, deduping by `eventId`. A duplicate broker delivery must never post a message into a thread twice.
- **Idempotency limit.** Phase 1 idempotency is in-process only. Because state and processed event IDs are stored in memory, deduplication does **not** survive service restart. Durable idempotency belongs to the database phase.
- **Visibility.** Polling only. The submission side sees management replies on the next `GET`. The management side sees submission messages on the next list/detail fetch. No WebSockets.

**Definition of done for the channel:** a reviewer can:

1. Submit anonymously.
2. See the case appear on the management side.
3. Reply from the management side.
4. Fetch the submission-side case and see the reply.
5. Reply again from the submission side.
6. See the follow-up appear on the management side.
7. Verify in SigNoz that each user action produced a distributed trace crossing Artemis in the correct direction.
8. Search or filter by `case.id` / `conversation.id` and see all traces belonging to the same case conversation.

---

## 4. API Contract

### 4.1 `submission-service`

#### `POST /api/cases`

Request:

```json
{ "message": "Initial report text" }
```

Success response: `201 Created`.

The response must include the generated `caseId`, the generated initial `eventId`, the plaintext access token, and a clear note that the token is returned once only and cannot be recovered. Do not return success until the `case.inbound` AMQP publish has completed successfully and the staged local case has been committed to the visible in-memory store.

Failure responses:

- `400 Bad Request` if `message` is missing or blank.
- `503 Service Unavailable` if the AMQP publish fails. In this case, the staged case must not become visible through the API.

#### `GET /api/cases/{caseId}`

Required header:

```text
X-Case-Token: <plaintext access token>
```

Success response: `200 OK`

```json
{
  "caseId": "a91b...-uuid",
  "status": "open",
  "messages": [
    {
      "eventId": "0f2c...-uuid",
      "author": "submission",
      "seq": 1,
      "body": "Initial report text",
      "createdAt": "2026-01-15T10:04:12.501Z"
    }
  ]
}
```

Failure responses:

- `404 Not Found` if the case does not exist, the token is missing, or the token is wrong.

#### `POST /api/cases/{caseId}/messages`

Required header:

```text
X-Case-Token: <plaintext access token>
```

Request:

```json
{ "message": "Follow-up text" }
```

Success response: `202 Accepted`.

The response must include the `caseId`, the newly generated `eventId`, and a success status. Do not return success until the `case.inbound` AMQP publish has completed successfully and the staged local message has been appended to the visible in-memory thread.

Failure responses:

- `400 Bad Request` if `message` is missing or blank.
- `404 Not Found` if the case does not exist, the token is missing, or the token is wrong.
- `503 Service Unavailable` if the AMQP publish fails. In this case, the staged message must not be appended locally.

### 4.2 `management-service`

#### `GET /api/cases?status=open`

Success response: `200 OK`

```json
[
  {
    "caseId": "a91b...-uuid",
    "status": "open",
    "messageCount": 1,
    "createdAt": "2026-01-15T10:04:12.501Z",
    "updatedAt": "2026-01-15T10:04:12.501Z"
  }
]
```

#### `GET /api/cases/{caseId}`

Success response: `200 OK`

```json
{
  "caseId": "a91b...-uuid",
  "status": "open",
  "messages": []
}
```

Failure response:

- `404 Not Found` if the case does not exist.

#### `POST /api/cases/{caseId}/reply`

Request:

```json
{ "message": "Management reply text" }
```

Success response: `202 Accepted`.

The response must include the `caseId`, the newly generated `eventId`, and a success status. Do not return success until the `case.outbound` AMQP publish has completed successfully and the staged local reply has been appended to the visible in-memory thread.

Failure responses:

- `400 Bad Request` if `message` is missing or blank.
- `404 Not Found` if the case does not exist.
- `503 Service Unavailable` if the AMQP publish fails. In this case, the staged reply must not be appended locally.

## 5. Event Schema & Trace Propagation

### 5.1 Event payload: JSON body of the AMQP message

```jsonc
{
  "eventId":   "0f2c...-uuid",     // idempotency key, unique per message
  "caseId":    "a91b...-uuid",
  "direction": "inbound",          // "inbound" submission→management | "outbound" management→submission
  "author":    "submission",         // "submission" | "management"; real identities come later, §9.1
  "seq":       3,                   // per-case, per-author sequence, monotonic within a service
  "body":      "free-text message",
  "createdAt": "2026-01-15T10:04:12.501Z"
}
```

### 5.2 AMQP message metadata

Use the JSON above as the AMQP message body. Trace context should be propagated through AMQP application properties by Quarkus/OpenTelemetry instrumentation.

For debugging and broker inspection, also set these message properties where the connector API allows it:

```text
caseId=<case UUID>
eventId=<event UUID>
direction=inbound|outbound
```

Do not put the submission-side access token into the payload, message properties, logs, span attributes, or error messages.

### 5.3 Trace context — automatic with the AMQP connector

Use the **Quarkus Messaging AMQP connector**: SmallRye Reactive Messaging, connector id `smallrye-amqp`.

When `quarkus-opentelemetry` is on the classpath and messaging tracing is active, outgoing messages should carry the current span context and incoming message processing should continue from the propagated context. In practical terms:

- The HTTP server span in the publishing service is the parent or ancestor of the AMQP send span.
- The AMQP receive/process span in the consuming service should be in the same trace as the publish side for that user action.
- The management reply is a later HTTP request and should produce a separate distributed trace unless span links are explicitly implemented.

### 5.4 Whole-conversation observability model: conversation-correlated trace graph

Phase 1 must **not** force the entire case lifecycle into one literal OpenTelemetry trace. A case conversation is a long-running business object made up of multiple user actions. Each action gets its own correct distributed trace across Artemis, and the collection of those traces forms the whole-conversation trace graph.

Mandatory domain span attributes for every relevant REST, publish, consume, and application processing span where the values are available:

```text
case.id=<case UUID>
conversation.id=<case UUID>
event.id=<event UUID>
message.direction=inbound|outbound
message.author=submission|management
messaging.destination.name=case.inbound|case.outbound
```

Use the dotted OpenTelemetry-style names above in span attributes. The API and event payload can still use JSON field names such as `caseId` and `eventId`, but emitted telemetry should prefer `case.id`, `conversation.id`, and `event.id`.

In addition to the domain attributes, implementation should follow the OpenTelemetry messaging semantic conventions where practical. Messaging spans should identify Artemis/ActiveMQ as the messaging system, identify the destination, map the event identifier to the conventional message identifier attribute, and map the case/conversation identifier to the conventional messaging conversation identifier attribute. The purpose is to make traces useful both to the POC reviewer and to generic OpenTelemetry-aware tooling. Do not replace the explicit domain attributes with only conventional attributes; emit both when values are available.

For every authored or consumed event, store the current trace/span context alongside the in-memory message record. This stored context is **not** a substitute for normal AMQP trace propagation. It exists so later user actions in the same case can link back to the previous related event.

Recommended local message record shape:

```jsonc
{
  "eventId": "0f2c...-uuid",
  "caseId": "a91b...-uuid",
  "direction": "inbound",
  "author": "submission",
  "seq": 1,
  "body": "free-text message",
  "createdAt": "2026-01-15T10:04:12.501Z",
  "traceContext": {
    "traceId": "otel-trace-id",
    "spanId": "otel-span-id",
    "traceFlags": "01",
    "tracestate": "optional"
  }
}
```

When a later action is authored for the same case, the service should load the most recent related event context and add an OpenTelemetry span link from the new application/publish span to that previous context where the Quarkus/OpenTelemetry APIs make this practical. Examples:

- A management reply can link to the latest inbound submission event consumed by `management-service`.
- A submission follow-up can link to the latest outbound management event consumed by `submission-service`.

If span links are difficult to implement cleanly in the first coding pass, the implementation must still emit the mandatory correlation attributes and the relevant OpenTelemetry messaging convention attributes. Span links can then be added as a focused follow-up without changing the API or AMQP event contract.

Whole-conversation acceptance criterion:

```text
A reviewer can search SigNoz by case.id or conversation.id and see all traces belonging to the same case conversation. Each trace must independently show the full AMQP hand-off for its user action. Where implemented, later traces should include span links to the most recent prior related event context.
```

### 5.5 Mandatory observability smoke test

The implementation is not done until this can be demonstrated in SigNoz:

1. Submit a new case via `POST /api/cases`.
2. Open the trace for that request.
3. Confirm it contains, at minimum:
   - HTTP server span in `submission-service`.
   - AMQP publish/send span to `case.inbound`.
   - AMQP receive/process span in `management-service`.
4. Send a management reply via `POST /api/cases/{caseId}/reply`.
5. Open the trace for that request.
6. Confirm it contains, at minimum:
   - HTTP server span in `management-service`.
   - AMQP publish/send span to `case.outbound`.
   - AMQP receive/process span in `submission-service`.
7. Confirm spans include useful attributes such as service name, deployment environment, messaging destination, `case.id`, `conversation.id`, `event.id`, and the relevant OpenTelemetry messaging convention attributes where available.
8. Search/filter in SigNoz by `case.id` or `conversation.id` and confirm all traces for the case appear as one conversation-correlated trace graph.
9. If span links were implemented, confirm the management reply trace links back to the prior inbound event context and the submission follow-up trace links back to the prior outbound event context.

---

## 6. Non-Functional Requirements

### 6.1 Observability: the priority

- `quarkus-opentelemetry` on both services.
- Auto-instrument REST and AMQP messaging.
- Export OTLP to SigNoz. SigNoz itself is provided outside this implementation plan; the services must accept the OTLP endpoint as environment-specific runtime configuration.
- Use consistent resource attributes:
  - `quarkus.application.name=submission-service` or `management-service`.
  - `service.namespace=anonymous-case-poc`.
  - `deployment.environment=local`.
- Add `case.id`, `conversation.id`, and `event.id` as span attributes in application code where available.
- Add the relevant OpenTelemetry messaging semantic convention attributes in addition to the domain attributes. In particular, messaging spans should identify the messaging system, destination, event/message identifier, and case/conversation identifier where available.
- Store trace/span context next to each in-memory message record so later actions can add span links and the whole conversation can be inspected as a correlated trace graph.
- Tracing is enabled by default.
- Metrics and logs are optional and should remain out of the critical path. Add them only after the trace demo passes.
- If metrics are added, prefer `quarkus-micrometer-opentelemetry` so Micrometer metrics flow through the same OTLP pipeline with matching resource attributes.

### 6.2 Resilience: cheap primitives only

- The queue keeps the two sides decoupled: `submission-service` can keep accepting submissions while `management-service` is down, provided Artemis is up. The management service catches up when it returns.
- Configure a **dead-letter path** and **bounded redelivery** in Artemis.
- Consumers ack only after successful processing.
- Consumer processing should fail loudly for invalid or unprocessable messages. In practice, this means the consumer must not silently swallow malformed events, must not acknowledge messages it did not process, and must let the broker treat the processing attempt as failed.
- Artemis should then redeliver the failed message only a bounded number of times. If the message keeps failing, Artemis must route it to the DLQ so the system avoids an infinite retry loop and the bad event remains available for inspection.
- A poison message must not permanently stop the service from processing unrelated valid messages.
- Consumers are idempotent in-process, deduping by `eventId`.
- Add `quarkus-smallrye-health` on both services.
- Expose `/q/health/live` and `/q/health/ready`.
- The AMQP connector should contribute to readiness so the service is not considered ready when the broker connection is unavailable.
- Use durable Artemis addresses/queues so buffered messages survive consumer downtime.

### 6.3 Security: minimal, honest

- Access tokens are high entropy.
- Store only SHA-256 token hashes in memory.
- Compare token hashes with a constant-time comparison.
- Return plaintext tokens once only.
- Never log tokens.
- Never include tokens in span attributes, AMQP messages, AMQP properties, exception messages, or test snapshots.
- Management APIs are unauthenticated in Phase 1 and acceptable only for local compose.
- No TLS termination in Phase 1; TLS/ingress arrives with the Kubernetes phase.

### 6.4 Scalability

- Deliberately out of scope for Phase 1.
- Services are single-replica because state is in memory.
- Autoscaling must not be introduced before persistence and durable idempotency exist.

---

## 7. Technology Stack, Extensions & Configuration

### 7.1 Stack

| Layer | Choice |
|---|---|
| Backend framework | Quarkus, Java |
| Messaging | ActiveMQ Artemis via AMQP 1.0, SmallRye connector `smallrye-amqp` |
| Observability | SigNoz, provided externally and reached through OTLP |
| Packaging / local run | Docker images + `docker-compose` |

### 7.2 Quarkus platform and extensions

Use one pinned Quarkus platform version for both services. Do not mix old and new extension names.

**Minimal extensions:**

- `quarkus-rest` — REST APIs.
- `quarkus-rest-jackson` — JSON serialization/deserialization.
- `quarkus-messaging-amqp` — AMQP 1.0 connector. Older name: `quarkus-smallrye-reactive-messaging-amqp`; do not use the older name unless the pinned Quarkus version requires it.
- `quarkus-opentelemetry` — tracing and trace propagation.
- `quarkus-smallrye-health` — liveness/readiness probes.

**Optional, after tracing works:**

- `quarkus-micrometer-opentelemetry` — unified metrics over OTLP.

### 7.3 Runtime configuration guidance

Do not hard-code broker locations, credentials, OTLP endpoints, service ports, or environment names in application code. The implementation should keep these values environment-specific and configurable at runtime. The pinned Quarkus version's documentation is the source of truth for exact property names.

The implementation plan intentionally does not include copy-paste configuration snippets. The coding assistant must derive the exact configuration from the pinned Quarkus version and document the final values in the generated repository, not in this architecture plan.

### 7.4 AMQP durable queue binding requirements

The two services must not only publish to and consume from the logical addresses. They must bind their incoming consumers to the concrete durable Artemis queues defined for this POC:

- `management-service` consumes from the durable queue `case.inbound.management` on the `case.inbound` address.
- `submission-service` consumes from the durable queue `case.outbound.submission` on the `case.outbound` address.

The implementation should use the Quarkus AMQP connector features required to attach to those existing durable queues. If the pinned Quarkus version requires queue-specific naming, durable subscription, container identity, link naming, or equivalent properties, the coding assistant must apply them in the service configuration and verify them in the generated repository.

Outbound publishing remains address-oriented: `submission-service` publishes inbound events to the `case.inbound` address, and `management-service` publishes outbound events to the `case.outbound` address. The broker topology determines which durable queue receives each message.

### 7.5 AMQP publish/consume implementation constraints

- Publish while the HTTP request span is still active.
- Await the AMQP send acknowledgement/completion before returning success from the REST endpoint.
- Use commit-after-publish for authored local state: create staged case/message records first, publish the AMQP event, and only then commit the staged records to the visible in-memory store.
- If publish fails, return `503 Service Unavailable` and do not expose the staged local state.
- Consumer processing must be idempotent by `eventId`.
- Consumer processing should fail loudly for invalid or unprocessable messages so broker redelivery and DLQ routing can be demonstrated.
- Application code should annotate spans with `case.id`, `conversation.id`, `event.id`, and the relevant OpenTelemetry messaging convention attributes when available.
- Do not manually inject `traceparent` unless auto-propagation fails and the failure is documented.

## 8. Local Dev, Repo Layout & Demo

### 8.1 Repo layout

```text
.
├── submission-service/        # Quarkus
├── management-service/        # Quarkus
├── infra/
│   ├── docker-compose.yml      # Artemis, optionally services
│   └── artemis/                # broker.xml: addresses, queues, DLQ, redelivery
├── scripts/
│   └── demo.sh                 # curl-based happy-path demo
└── docs/
    └── architecture.md
```

### 8.2 `docker-compose` contents

- **artemis** — use a pinned Apache Artemis image version, or a latest tag only during early exploration.
  - AMQP should be exposed for the services.
  - The Artemis console may be exposed for local inspection.
  - The broker must be provisioned with the two addresses, two durable anycast queues, a DLQ, and bounded redelivery.
- **SigNoz** — provided outside this implementation plan. The local services must be able to export traces to the SigNoz OTLP endpoint supplied by the implementer.
- **Services** — optionally run the two Quarkus services in compose, or run them via `quarkus dev` on the host and compose only Artemis for a faster inner loop.

### 8.3 Artemis topology

Use durable anycast queues with the following logical topology:

- `case.inbound` is the address for submission-to-management events. Its durable queue is `case.inbound.management`, consumed by `management-service`.
- `case.outbound` is the address for management-to-submission events. Its durable queue is `case.outbound.submission`, consumed by `submission-service`.
- `DLQ` is the dead-letter destination used for repeatedly failing messages from the case queues.

For both case directions, Artemis must use bounded redelivery. A message that repeatedly fails consumer processing should be retried only a small finite number of times and then routed to the DLQ. The exact broker syntax belongs in the generated infrastructure files, not in this implementation plan.

### 8.4 Demo script: happy path

Create `scripts/demo.sh` that performs the following using `curl` and `jq`:

1. `POST /api/cases` to `submission-service`.
2. Extract `caseId` and `accessToken`.
3. `GET /api/cases/{caseId}` on `submission-service` using `X-Case-Token`.
4. `GET /api/cases?status=open` on `management-service`.
5. `GET /api/cases/{caseId}` on `management-service`.
6. `POST /api/cases/{caseId}/reply` on `management-service`.
7. `GET /api/cases/{caseId}` on `submission-service` using `X-Case-Token`; verify the management reply is visible.
8. `POST /api/cases/{caseId}/messages` on `submission-service` using `X-Case-Token`.
9. `GET /api/cases/{caseId}` on `management-service`; verify the submission follow-up is visible.

### 8.5 Demo script: resilience checks

Add manual or scripted checks for:

- Wrong submission-side token returns `404`, not `403`.
- Blank message returns `400`.
- Duplicate event delivery does not create duplicate thread messages.
- `management-service` can be stopped while `submission-service` publishes an inbound event; when restarted, it consumes the buffered message.
- A deliberately failing consumer path sends a message to DLQ after bounded retries.

### 8.6 Trace demo checklist

For each direction, capture or document:

- The request used.
- The resulting `caseId` and `eventId`.
- The trace ID shown in SigNoz.
- A screenshot or written confirmation that the trace contains HTTP + AMQP send + AMQP receive/process spans across both services.
- A screenshot or written confirmation that filtering by `case.id` / `conversation.id` returns all traces for the case conversation.
- If span links are implemented, a screenshot or written confirmation that later action traces link to the previous related event context.

---

## 9. Future Considerations / Deferred Reintegration

### 9.1 Keycloak and management identity

Later phases should add Keycloak/OIDC authentication to management APIs. Replace the fixed `"management"` author with the authenticated management identity or a privacy-preserving management display name. Management-side authorization should ensure management users only see cases they are allowed to handle.

### 9.2 Database persistence and outbox

Add database persistence for cases, messages, token hashes, and processed event IDs. Once a database exists, introduce a transactional outbox or equivalent reliable publication pattern so local state and AMQP publication cannot diverge.

### 9.3 Durable idempotency

Move dedupe from in-memory sets to durable storage keyed by `eventId`. This is required before restarts, rolling deployments, or multiple replicas can be considered safe.

### 9.4 Autoscaling

Do not autoscale either service while state and dedupe are in memory. After persistence and durable idempotency are implemented, scaling can be revisited.

### 9.5 Kubernetes, TLS, ingress, and production security

Kubernetes manifests, Helm, ingress, TLS termination, secrets management, network policies, and production observability collector configuration are deferred. Do not add them to Phase 1.

### 9.6 Attachments and object storage

Attachments, AV scanning, object storage, retention policies, and download authorization are deferred. Do not model them in Phase 1 APIs.

---

## 10. Implementation Build Order for the Coding Assistant

1. Create the repository layout and two Quarkus services using the same pinned Quarkus platform version.
2. Add the minimal extensions listed in §7.2.
3. Add health endpoints and verify both services start locally.
4. Implement shared DTOs in each service or in a tiny shared module. Keep this simple; avoid introducing a broad shared domain library.
5. Implement in-memory stores:
   - Cases.
   - Messages.
   - Token hashes in `submission-service`.
   - Processed `eventId` sets in both services.
   - Stored trace/span context next to each message record for conversation-graph correlation.
6. Implement token generation, SHA-256 hashing, and constant-time token comparison.
7. Implement REST validation and response codes.
8. Implement AMQP publish/consume for `case.inbound` and `case.outbound`, including durable binding to the actual Artemis queue names.
9. Ensure authored REST operations use commit-after-publish and return success only after AMQP publish completion.
10. Ensure all successful write endpoints return the generated `eventId`.
11. Add span attributes for `case.id`, `conversation.id`, `event.id`, `message.direction`, and `message.author` where available.
12. Add the relevant OpenTelemetry messaging convention attributes for messaging system, destination, message/event identifier, and conversation/case identifier where available.
13. Store the current trace/span context alongside each authored or consumed message record.
14. Add span links from later actions to the most recent prior related event context where cleanly supported by the Quarkus/OpenTelemetry APIs. If this is not clean in the first pass, keep the correlation attributes mandatory and document span links as the next follow-up.
15. Add Artemis compose config with durable anycast queues, DLQ, and bounded redelivery in the generated infrastructure files.
16. Add `scripts/demo.sh` for the happy path.
17. Add resilience checks for wrong token, blank message, duplicate event, consumer downtime, and DLQ.
18. Add tests for validation, token failure returning `404`, duplicate event dedupe, ordering, commit-after-publish behavior, and basic publish/consume behavior.
19. Add observability smoke-test documentation showing how to verify both AMQP traces and whole-conversation discoverability in SigNoz by `case.id`.

## 11. Explicit Ambiguities to Resolve Before Coding

The coding assistant should flag these if they are not already decided by the implementer:

- Exact pinned Quarkus version.
- Exact pinned Artemis image version.
- Exact SigNoz OTLP endpoint and whether it is reached directly or through an OpenTelemetry Collector.
- Whether services run in compose or via `quarkus dev` during local development.
- Whether span links should be implemented in the first pass or deferred after mandatory `case.id` / `conversation.id` correlation works.
- Exact span-link target policy if implemented: latest prior event, latest opposite-direction event, or all prior related events. Default: latest prior opposite-direction event.

