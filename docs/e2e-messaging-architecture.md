# End-to-End Messaging — Architecture

How a message travels between an anonymous reporter and a case manager. The two
services never call each other: every message crosses exactly one asynchronous
Artemis hop, made reliable by a **transactional outbox** on the sending side and a
**persistent inbox** on the receiving side (Phase 2 plan §5.3/§5.4).

## 1. Component view

```mermaid
flowchart LR
    REP(["Reporter<br/>anonymous, case token"])
    KC["Keycloak<br/>realm case-poc"]
    MGR(["Case manager<br/>JWT · role case-manager"])

    subgraph SS["submission-service (Quarkus)"]
        SS_API["REST API<br/>POST /api/cases<br/>GET /api/cases/:id<br/>POST /api/cases/:id/messages"]
        SS_SVC["CaseService<br/>one tx: message row + outbox row<br/>(traceparent captured)"]
        SS_REL["OutboxRelay<br/>@Scheduled 1s · SKIP LOCKED claim<br/>publish + settle-wait · exp. backoff"]
        SS_CON["CaseOutboundConsumer<br/>inbox dedupe + apply, one tx"]
    end
    PG_S[("PostgreSQL case_poc<br/>schema submission<br/>cases · messages<br/>outbox_events · inbox_events")]

    subgraph MQ["Artemis (AMQP 1.0)"]
        A_IN{{"address<br/>case.inbound"}}
        Q_IN[["durable queue<br/>case.inbound.management"]]
        A_OUT{{"address<br/>case.outbound"}}
        Q_OUT[["durable queue<br/>case.outbound.submission"]]
        DLQ[["DLQ"]]
    end

    subgraph MS["management-service (Quarkus)"]
        MS_API["REST API · @RolesAllowed(case-manager)<br/>GET /api/cases · GET /api/cases/:id<br/>POST /api/cases/:id/reply"]
        MS_SVC["CaseService<br/>one tx: reply row + outbox row<br/>author = preferred_username (JWT)"]
        MS_REL["OutboxRelay<br/>(same pattern)"]
        MS_CON["CaseInboundConsumer<br/>inbox dedupe + case projection, one tx"]
    end
    PG_M[("PostgreSQL case_poc<br/>schema management<br/>cases · messages<br/>outbox_events · inbox_events")]

    %% reporter -> manager direction
    REP -->|"1 · POST body"| SS_API
    SS_API --> SS_SVC
    SS_SVC -->|"commit"| PG_S
    SS_REL <-->|"2 · claim PENDING /<br/>mark PUBLISHED"| PG_S
    SS_REL -->|"3 · JSON event<br/>+ traceparent"| A_IN
    A_IN --> Q_IN
    Q_IN -->|"4 · deliver"| MS_CON
    MS_CON -->|"5 · apply"| PG_M

    %% manager -> reporter direction
    MGR -->|"6 · POST reply (JWT)"| MS_API
    MS_API --> MS_SVC
    MS_SVC -->|"commit"| PG_M
    MS_REL <-->|"7 · claim / mark"| PG_M
    MS_REL -->|"8 · publish"| A_OUT
    A_OUT --> Q_OUT
    Q_OUT -->|"9 · deliver"| SS_CON
    SS_CON -->|"10 · apply"| PG_S
    REP -->|"11 · GET thread<br/>(sees reply)"| SS_API

    %% identity & failure paths
    MGR -.->|"login"| KC
    MS_API -.->|"verify JWT<br/>(JWKS)"| KC
    Q_IN -.->|"3 failed<br/>deliveries"| DLQ
    Q_OUT -.->|"3 failed<br/>deliveries"| DLQ
```

Deliveries (4, 9) are at-least-once; the receiving inbox makes them effectively-once.
A nacked delivery is redelivered up to 3 times (1s delay) before Artemis dead-letters
it to `DLQ`. Both services connect to the same PostgreSQL instance but own disjoint
schemas — there are no cross-schema grants; the broker is the only integration path.

## 2. One message end to end (reporter → manager → reporter)

```mermaid
sequenceDiagram
    autonumber
    actor R as Reporter
    participant SS as submission-service
    participant DBS as Postgres (submission)
    participant MQ as Artemis
    participant MS as management-service
    participant DBM as Postgres (management)
    actor M as Case manager

    R->>SS: POST /api/cases { body }
    activate SS
    SS->>DBS: tx: case + message + outbox row (PENDING, traceparent)
    SS-->>R: 201 { caseId, accessToken }
    deactivate SS
    Note over SS,DBS: Response = committed locally,<br/>not yet delivered (eventual consistency)

    loop OutboxRelay, every 1s
        SS->>DBS: claim next PENDING (FOR UPDATE SKIP LOCKED)
        SS->>MQ: publish to case.inbound, await settle
        alt broker acks
            SS->>DBS: same tx: status → PUBLISHED
        else broker down / timeout
            SS->>DBS: attempts++, next_attempt_at = now + min(2^n, 30s)
        end
    end

    MQ->>MS: deliver from case.inbound.management
    activate MS
    MS->>DBM: tx: insert inbox_events(eventId) — conflict ⇒ duplicate, ack & skip
    MS->>DBM: same tx: create case projection + message row
    MS-->>MQ: ack on commit (nack ⇒ redelivery ×3 ⇒ DLQ)
    deactivate MS

    M->>MS: POST /api/cases/:id/reply (JWT, role case-manager)
    MS->>DBM: tx: reply row + outbox row (author = preferred_username)
    MS-->>M: 202

    MS->>MQ: OutboxRelay publishes to case.outbound
    MQ->>SS: deliver from case.outbound.submission
    SS->>DBS: tx: inbox dedupe + append reply to thread

    R->>SS: GET /api/cases/:id (access token)
    SS-->>R: thread incl. manager reply
```

## 3. Why it is built this way

| Concern | Mechanism |
| --- | --- |
| No lost messages on broker outage | Outbox row commits with the domain change; POST never waits for the broker. Relay retries with capped exponential backoff (max 30s) until Artemis accepts. |
| No lost messages on service crash | Crash after broker-accept but before status update leaves the row `PENDING` → republished on restart (at-least-once). |
| No duplicate effects | Receiver inserts `event_id` into `inbox_events` in the same tx as the apply; a conflict means duplicate → ack without effect (effectively-once). |
| Poison messages can't block the queue | Consumer throws → nack (`failure-strategy=reject`) → Artemis bounded redelivery (3 × 1s) → `DLQ`. |
| Horizontal scaling | Relay rows claimed with `FOR UPDATE SKIP LOCKED`; consumers bind to shared durable queues (FQQN) — multiple pods compete safely. |
| Anonymity boundary | Reporter side is token-gated (SHA-256 hash, 404-on-bad-token); only the management side authenticates users via Keycloak OIDC. Identity never crosses the broker except as the chosen `author` label. |
| Trace continuity | `traceparent` is persisted on the outbox row; the relay's `outbox.publish` span restores it, so SigNoz shows HTTP → outbox → AMQP → consumer → DB as one trace. |

Event payload (unchanged since Phase 1): `eventId` (idempotency key), `caseId`,
`direction` (`inbound`/`outbound`), `author`, `seq`, `body`, `createdAt`.
