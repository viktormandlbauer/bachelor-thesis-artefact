package at.thesis.poc.submission.messaging;

import java.time.Duration;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.reactive.messaging.Channel;
import org.eclipse.microprofile.reactive.messaging.Emitter;
import org.eclipse.microprofile.reactive.messaging.Message;
import org.eclipse.microprofile.reactive.messaging.Metadata;

import at.thesis.poc.submission.domain.MessageRecord;
import at.thesis.poc.submission.domain.TraceContextRef;
import at.thesis.poc.submission.observability.TraceAttributes;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanBuilder;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import io.smallrye.reactive.messaging.amqp.OutgoingAmqpMetadata;
import io.vertx.core.json.JsonObject;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Publishes case.inbound events and waits for the broker to settle the message before
 * returning, so REST endpoints can implement commit-after-publish (plan §7.5): staged
 * local state becomes visible only after this method returns normally.
 *
 * Each publish runs inside an application-level "author" span that carries the
 * correlation attributes and, for follow-ups, a span link to the most recent prior
 * opposite-direction event of the same case (plan §5.4).
 */
@ApplicationScoped
public class CaseEventPublisher {

    @Inject
    @Channel("case-inbound-out")
    Emitter<JsonObject> emitter;

    @Inject
    Tracer tracer;

    @ConfigProperty(name = "app.publish-timeout", defaultValue = "10S")
    Duration publishTimeout;

    public void publishInbound(MessageRecord record, TraceContextRef linkTarget) {
        SpanBuilder spanBuilder = tracer.spanBuilder("author case.inbound event")
                .setSpanKind(SpanKind.INTERNAL);
        if (linkTarget != null) {
            SpanContext link = linkTarget.toSpanContext();
            if (link.isValid()) {
                spanBuilder.addLink(link);
            }
        }
        Span span = spanBuilder.startSpan();
        try (Scope ignored = span.makeCurrent()) {
            TraceAttributes.annotate(span, record.caseId(), record.eventId(),
                    record.direction(), record.author(), CaseEvents.ADDRESS_INBOUND);
            record.traceContext(TraceContextRef.from(span.getSpanContext()));

            OutgoingAmqpMetadata metadata = OutgoingAmqpMetadata.builder()
                    .withDurable(true)
                    .withApplicationProperties(new JsonObject()
                            .put("caseId", record.caseId())
                            .put("eventId", record.eventId())
                            .put("direction", record.direction()))
                    .build();

            CompletableFuture<Void> settled = new CompletableFuture<>();
            Message<JsonObject> message = Message.of(CaseEvents.toJson(record))
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
        } catch (Exception e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, "AMQP publish did not complete");
            throw new PublishFailedException("Publishing case.inbound event failed", e);
        } finally {
            span.end();
        }
    }
}
