# Phase 2 — Implementation State

> Working log for the Phase 2 implementation (see `phase-2-plan.md`). Updated after every
> slice so work can resume in a fresh session without re-deriving decisions.
> Build order follows plan §11; acceptance criteria are plan §10.

## Status

| Slice (plan §11) | State | Notes |
|---|---|---|
| 1. Compose: PostgreSQL + Keycloak | done | `infra/postgres/init/01-schemas-users.sql`, `infra/keycloak/case-poc-realm.json`, compose services with health checks |
| 2. submission-service: Flyway + entities replace in-memory store | done | entities/repos in `domain/`, `V1__submission_schema.sql`, `CaseService` owns commands; compiles |
| 3. submission-service: inbox consumer + outbox relay + trace context | done | `OutboxRelay` (SKIP LOCKED, 1 row/tx, capped exp backoff), consumer `@Blocking @Transactional` + inbox; `Traceparent` util |
| 4. management-service: persistence + inbox + outbox | done | mirror of submission minus token hash; consumer creates case projection |
| 5. management-service: OIDC + roles, author from JWT | done | `@RolesAllowed("case-manager")`, author = preferred_username → principal name fallback |
| 6. Compose wiring for services (env, readiness) | done | DB_URL/DB_USERNAME/DB_PASSWORD + QUARKUS_OIDC_* env; KC_HOSTNAME pins issuer to http://localhost:8180 |
| 7. Tests reworked for persistent semantics | done | 16 + 14 green vs Dev Services PostgreSQL + Artemis; OIDC via @TestSecurity/@OidcSecurity |
| 8. End-to-end verification (§10.1–10.6) | done | verified 2026-07-06 against compose, see below |

## E2E verification results (compose, 2026-07-06)

- §10.1 statelessness: case + 3-message thread survived `docker restart` of both services.
- §10.2 identity: no/garbage token → 401, intern (no role) → 403, staff → 200; reply
  author recorded as `staff` (preferred_username from the Keycloak JWT).
- §10.3 outbox: with Artemis stopped, append returned 202 and the row sat
  `PENDING|attempts=1|TimeoutException`; after `docker start poc-artemis` it flipped to
  `PUBLISHED` (3 attempts) and the management side received it exactly once.
- §10.4 inbox: duplicate delivery covered by consumer tests; management `inbox_events`
  holds exactly one row per inbound event.
- §10.5 probes: `/q/health/ready` on both services includes the AMQP channels and the
  datasource checks.
- §10.6 observability: traceparent persisted per outbox row (asserted in
  OutboxRelayTest); visual SigNoz check (one trace across HTTP → outbox → AMQP →
  consumer → DB) is the remaining **manual** step — open the SigNoz UI while running
  `scripts/demo.sh`-style traffic.

## Decisions already made (do not re-litigate)

- Commit-after-publish from Phase 1 is **retired**; POST endpoints return after local DB
  commit, the `@Scheduled` outbox relay publishes asynchronously (plan §2, §5.3).
  `PublishFailedException`/mapper and the settle-wait in `CaseEventPublisher` go away.
- Relay claims rows with `SELECT … FOR UPDATE SKIP LOCKED`, bounded exponential backoff
  via `attempts` + `next_attempt_at`; statuses `PENDING | PUBLISHED | FAILED`.
- Inbox: insert `event_id` first inside the same tx as the message apply; conflict = duplicate → ack.
- Trace context (`traceparent`/`tracestate`) persisted per outbox row, restored at relay
  time under an `outbox.publish` span (plan §7).
- DB: one instance, database `case_poc`, schema+user `submission_service`/`submission`
  and `management_service`/`management`, no cross-grants. Flyway per service,
  `migrate-at-start`, no auto-DDL.
- Keycloak: realm `case-poc` imported from checked-in export; client `management-api`
  (public/service, JWT via realm JWKS), realm role `case-manager`, staff user
  `staff` / `staff-password`. Host port 8180.
- Management auth: `@RolesAllowed("case-manager")`; reply author =
  `preferred_username` claim, fallback `sub`.
- Event JSON schema unchanged from Phase 1 (plan §5.5); `eventId` stays idempotency key.
- Keep Phase 1 rules: no direct service-to-service calls, FQQN queue bindings, DLQ +
  bounded redelivery, 404-on-bad-token, `TokenService` SHA-256 hashing.

## Known follow-ups / risks

- Existing tests assume in-memory store and commit-after-publish semantics
  (`CaseResourceTest`, `*EndToEndTest`, `CaseOutboundConsumerTest`); they need rework:
  Dev Services will provide PostgreSQL (testcontainers) + Artemis automatically, and
  management tests need `quarkus-test-security`/OIDC handling.
- SigNoz stack must be running (`infra/signoz/docker-compose.yaml`) before
  `infra/docker-compose.yml` because of the external `signoz-net` network.
- k3s/Helm updates are the infrastructure track — out of scope here until §10 passes.

## Resume instructions

1. Read `phase-2-plan.md` (§5–§8 for semantics, §11 for order) and this file.
2. Continue at the first non-done slice in the table above.
3. After each slice: build (`mvn -q package` in the service dir), update this file, commit.
