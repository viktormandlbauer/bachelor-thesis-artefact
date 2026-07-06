package at.thesis.poc.submission.messaging;

import java.time.Duration;
import java.time.Instant;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.reactive.messaging.Channel;
import org.eclipse.microprofile.reactive.messaging.Emitter;
import org.eclipse.microprofile.reactive.messaging.Message;
import org.eclipse.microprofile.reactive.messaging.Metadata;

import at.thesis.poc.submission.domain.OutboxEventEntity;
import at.thesis.poc.submission.domain.OutboxRepository;
import at.thesis.poc.submission.observability.TraceAttributes;
import at.thesis.poc.submission.observability.Traceparent;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanBuilder;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import io.quarkus.logging.Log;
import io.quarkus.narayana.jta.QuarkusTransaction;
import io.quarkus.scheduler.Scheduled;
import io.smallrye.reactive.messaging.amqp.OutgoingAmqpMetadata;
import io.vertx.core.json.JsonObject;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Transactional-outbox relay (plan §5.3): polls PENDING rows, publishes them to Artemis
 * with a settle-wait, and marks them PUBLISHED in the same transaction that holds the
 * claimed row's lock. Replaces Phase 1 commit-after-publish: a broker outage is no
 * longer a request failure, it just leaves rows PENDING with growing backoff.
 *
 * Crash/eviction safety: if the pod dies after the broker accepted the message but
 * before the status update commits, the row stays PENDING and is republished after
 * restart — at-least-once by design; the receiving side's inbox dedupes (plan §5.4).
 *
 * Trace continuity (plan §7): each row carries the traceparent captured at command
 * time; the publish span is started under that restored context, so the SigNoz trace
 * shows the relay hop inside the original request flow instead of a detached
 * scheduler trace.
 */
@ApplicationScoped
public class OutboxRelay {

    @Inject
    OutboxRepository outbox;

    @Inject
    Tracer tracer;

    @Inject
    @Channel("case-inbound-out")
    Emitter<JsonObject> emitter;

    @ConfigProperty(name = "app.outbox.publish-timeout", defaultValue = "5S")
    Duration publishTimeout;

    @ConfigProperty(name = "app.outbox.max-batch", defaultValue = "25")
    int maxBatch;

    @ConfigProperty(name = "app.outbox.max-backoff", defaultValue = "30S")
    Duration maxBackoff;

    @Scheduled(every = "${app.outbox.poll-interval:1s}",
               concurrentExecution = Scheduled.ConcurrentExecution.SKIP)
    void relayPending() {
        // One row per transaction: a failed publish only costs its own settle-timeout
        // and commits its backoff bookkeeping; a batch never exceeds the tx timeout.
        for (int i = 0; i < maxBatch; i++) {
            if (!QuarkusTransaction.requiringNew().call(this::relayNext)) {
                return;
            }
        }
    }

    /** Returns true to keep draining; false when idle or after a failed publish. */
    boolean relayNext() {
        OutboxEventEntity row = outbox.claimNext();
        if (row == null) {
            return false;
        }
        SpanContext storedContext = Traceparent.parse(row.traceparent);
        SpanBuilder spanBuilder = tracer.spanBuilder("outbox.publish")
                .setSpanKind(SpanKind.PRODUCER);
        if (storedContext.isValid()) {
            spanBuilder.setParent(Context.root().with(Span.wrap(storedContext)));
        }
        Span span = spanBuilder.startSpan();
        try (Scope ignored = span.makeCurrent()) {
            JsonObject payload = new JsonObject(row.payload);
            TraceAttributes.annotate(span, row.caseId.toString(), row.eventId.toString(),
                    payload.getString("direction"), payload.getString("author"), row.address);
            span.setAttribute("app.outbox.attempts", row.attempts);

            sendAndAwaitSettle(payload, row);

            row.status = OutboxEventEntity.STATUS_PUBLISHED;
            row.publishedAt = Instant.now();
            row.lastError = null;
            return true;
        } catch (Exception e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, "outbox publish failed");
            row.attempts += 1;
            long backoffSeconds = Math.min(maxBackoff.toSeconds(),
                    1L << Math.min(row.attempts, 12));
            row.nextAttemptAt = Instant.now().plusSeconds(backoffSeconds);
            row.lastError = abbreviate(e);
            Log.warnf("Outbox publish of event %s failed (attempt %d, retry in %ds): %s",
                    row.eventId, row.attempts, backoffSeconds, row.lastError);
            // Broker is likely unavailable; stop this tick, backoff decides the next try.
            return false;
        } finally {
            span.end();
        }
    }

    private void sendAndAwaitSettle(JsonObject payload, OutboxEventEntity row) throws Exception {
        OutgoingAmqpMetadata metadata = OutgoingAmqpMetadata.builder()
                .withDurable(true)
                .withApplicationProperties(new JsonObject()
                        .put("caseId", row.caseId.toString())
                        .put("eventId", row.eventId.toString())
                        .put("direction", payload.getString("direction")))
                .build();

        CompletableFuture<Void> settled = new CompletableFuture<>();
        Message<JsonObject> message = Message.of(payload)
                .withMetadata(Metadata.of(metadata))
                .withAck(() -> {
                    settled.complete(null);
                    return CompletableFuture.completedFuture(null);
                })
                .withNack(failure -> {
                    settled.completeExceptionally(failure);
                    return CompletableFuture.completedFuture(null);
                });
        emitter.send(message);
        settled.get(publishTimeout.toMillis(), TimeUnit.MILLISECONDS);
    }

    private static String abbreviate(Exception e) {
        String text = e.toString();
        return text.length() > 500 ? text.substring(0, 500) : text;
    }
}
