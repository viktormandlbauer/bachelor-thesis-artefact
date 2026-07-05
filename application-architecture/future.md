## Future Considerations (deferred, with re-integration notes)

Each item below was removed from Phase 1 to keep the core small. They're ordered roughly by natural build sequence, and each notes how it slots back onto the Phase-1 skeleton without rework.

### Authentication — Keycloak (management side only)
- Add `quarkus-oidc` (**`service` type** — Bearer JWT resource server, no session) to `management-service`; it validates JWTs against Keycloak's JWKS on each request (stateless — no shared store, no per-request round-trip once keys are cached).
- The (future) management frontend runs OIDC **Authorization Code + PKCE** directly against Keycloak, holds tokens client-side, and sends `Bearer` on every call.
- The **submission side stays anonymous** — token-only, no accounts, no PII. OAuth cannot apply there without breaking anonymity.
- Replace the placeholder `"staff"` author with the JWT subject/username. **No change** to the event schema shape or the Artemis transport.
- *Note:* new management pods must fetch JWKS on cold start; "no round-trip to Keycloak" is a steady-state property. A Keycloak outage degrades only the internal half — a nice failure-isolation point for the thesis.

### 9.2 Persistence — PostgreSQL
- Add `quarkus-hibernate-orm-panache` + `quarkus-jdbc-postgresql`; replace the in-memory stores with Panache entities (`Case`, `Message`). One Postgres instance, **one schema per service**, and — for real per-service ownership — **a distinct DB user per service** with grants limited to its own schema.
- JDBC/Hibernate spans then appear in the trace **automatically** (auto-instrumented), adding the DB-write span the full design wanted.
- Move idempotency from the in-memory `seen` set to an **inbox table** keyed by `eventId`.
- Close the **dual-write gap**: publishing to Artemis and committing to Postgres are two systems with no shared commit. Add a **transactional outbox** (write the event to an outbox table in the same DB tx, relay to Artemis) so "submissions reliably reach management" is airtight. (Phase 1 sidesteps this because there is no DB.)

### 9.3 Attachments + AV scanning + object storage
- Accept multipart on `POST /api/cases` (and `/messages`); validate **file count (≤5), MIME via magic-byte sniffing (not extension), and size caps** (config).
- Stream every file to **ClamAV `clamd` (`INSTREAM`) before it touches disk or object storage**; any hit or an unreachable scanner → **fail closed** (reject the whole submission, log the security event, never persist).
- On clean, upload to **MinIO** (S3 API, `quarkus-amazon-s3` with `quarkus.s3.endpoint-override`; swappable for AWS S3 by config) under a per-case prefix; put **object keys + metadata into the event**, so both services can locate files in the shared bucket.
- **Define the read-back path** (left open in the full design): presigned MinIO URLs (short TTL, scoped; browser must reach the endpoint) **or** proxied through the service (adds load — factor into scaling numbers). Staff reads stay behind auth; reporter reads behind the token.
- The scan + upload become **additional spans** in the same trace.

### 9.4 Autoscaling (HPA / VPA) — **depends on 9.2**
- Requires persistence first: the in-memory store must move to Postgres so any replica can serve any request. **Do not scale before that.**
- Give each stateless Deployment an `HorizontalPodAutoscaler`; set `requests`/`limits` on every container (HPA is meaningless without them). Needs `metrics-server`.
- **Scaling-signal caveat:** the submission path is I/O-bound (scan, upload, DB), so CPU-based HPA may not trip under load. Prefer **Artemis queue depth as a custom metric** as the *primary* signal for the submission service; keep CPU HPA on the (static) frontends. This is the single biggest risk to a convincing "watch it scale" demo — plan the signal deliberately.
- Vertical scaling (`requests`/`limits` tuning, optional `VerticalPodAutoscaler`) as a secondary demonstration.

### 9.5 Kubernetes / Helm
- Target: k3s, 1 control-plane + 2 workers (real scheduling/scaling without a lab); `kind`/`minikube` fine for single-machine dev.
- The `docker-compose` services map to `Deployment` + `ClusterIP` `Service`; one `Ingress` (ingress-nginx) with two hosts/paths; `ConfigMap`/`Secret` for all config; **TLS terminated at the ingress**.
- Use community charts for Postgres/Keycloak/MinIO and **SigNoz's Helm chart** for observability; write manifests only for the custom services and Artemis.
- One namespace is enough; optionally split `app` vs `observability`.
- *Resource reality check:* the "minimal" cluster is memory-heavy (ClickHouse + ClamAV signature DB + Keycloak + Artemis + multiple JVMs). Size worker nodes accordingly; the SigNoz "one deployable unit vs four projects" win is operational, not necessarily compute.

### 9.6 Frontends (Angular) + RUM
- Two static Angular SPAs (submission + management) slot onto the **existing REST contract**. Reporter token goes in the **URL fragment** (`#token=...`, read client-side, sent as a header) so it never lands in logs/`Referer`.
- Needs **CORS** on both services (and Keycloak web-origins for the management client).
- Management SPA holds tokens **in memory only** (never `localStorage`/`sessionStorage`); consequence to accept: **page reload → re-auth** (Keycloak may SSO-silent it). Refresh tokens would weaken the in-memory-only posture.
- Stretch: **OpenTelemetry JS SDK** RUM to extend the trace into the browser.

### 9.7 Other hardening (noted, not built)
- **Graceful shutdown / drain** of in-flight messages before pod termination (matters once HPA kills pods); tune `terminationGracePeriodSeconds` + preStop.
- **Rate limiting** for the anonymous token endpoints — Phase 1/POC uses per-instance in-memory counters; a shared store or an API-gateway limiter is the real answer, weaker across replicas.
- **Retry/DLQ tuning** beyond the minimal bounded policy.
- **i18n, multi-tenancy, service mesh/mTLS, CI/CD** — reasonable stretch goals, not required for the core argument.

---

## 10. Assumptions to Review (Phase 1)

- **Text-only messages** in Phase 1; attachments (and therefore ClamAV + MinIO + multipart + MIME sniffing) are deferred to §9.3.
- **Management APIs are unauthenticated** and must only be reached locally via compose until §9.1 lands.
- **In-memory stores** mean data is lost on service restart. That's fine for the trace and reply demos; the queue-buffering demo (§8.5) still works because Artemis persists messages independently of the app.
- **Single-replica** services — a direct consequence of in-memory state. Autoscaling is intentionally deferred and coupled to persistence (§9.4).
- **AMQP connector, not JMS** — chosen specifically so trace propagation across Artemis is automatic; the thesis explains the wire-level mechanism (traceparent in AMQP application-properties) rather than hand-rolling it.
- **SigNoz** as the single OTLP backend; swappable for any OTLP-compatible backend by pointing the exporter elsewhere.
- **Ordering** by authored `createdAt` + `eventId` tie-break, accepting minor cross-service clock skew; no guarantee of broker-delivery ordering.

---