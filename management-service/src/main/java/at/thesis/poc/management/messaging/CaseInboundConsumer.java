package at.thesis.poc.management.messaging;

import java.util.concurrent.CompletionStage;

import org.eclipse.microprofile.reactive.messaging.Incoming;
import org.eclipse.microprofile.reactive.messaging.Message;

import at.thesis.poc.management.domain.CaseRecord;
import at.thesis.poc.management.domain.CaseStore;
import at.thesis.poc.management.domain.MessageRecord;
import at.thesis.poc.management.domain.TraceContextRef;
import at.thesis.poc.management.messaging.CaseEvents.CaseEvent;
import at.thesis.poc.management.observability.TraceAttributes;
import io.opentelemetry.api.trace.Span;
import io.quarkus.logging.Log;
import io.vertx.core.json.JsonObject;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Consumes submissions and follow-ups from the durable queue case.inbound.management.
 * The first inbound event of a case creates the management-side copy as "open" (plan §3.1).
 *
 * Delivery is at-least-once: processing is idempotent by eventId (in-process only,
 * plan §3.4). Malformed or unprocessable events throw, which nacks the message so
 * Artemis applies bounded redelivery and finally routes it to the DLQ (plan §6.2).
 */
@ApplicationScoped
public class CaseInboundConsumer {

    @Inject
    CaseStore store;

    @Incoming("case-inbound-in")
    public CompletionStage<Void> onCaseInbound(Message<JsonObject> message) {
        CaseEvent event = CaseEvents.parse(message.getPayload());
        if (!CaseEvents.DIRECTION_INBOUND.equals(event.direction())) {
            throw new IllegalArgumentException(
                    "Unexpected direction on case.inbound: " + event.direction());
        }
        if (CaseEvents.POISON_MARKER.equals(event.body())) {
            throw new IllegalStateException("Poison marker event, failing on purpose");
        }

        Span span = Span.current();
        TraceAttributes.annotate(span, event.caseId(), event.eventId(),
                event.direction(), event.author(), CaseEvents.ADDRESS_INBOUND);

        if (store.isProcessed(event.eventId())) {
            Log.infof("Duplicate delivery of event %s for case %s ignored", event.eventId(), event.caseId());
            span.setAttribute("app.duplicate_delivery", true);
            return message.ack();
        }

        CaseRecord caseRecord = store.getOrCreate(event.caseId(), event.createdAt());
        MessageRecord record = new MessageRecord(event.eventId(), event.caseId(),
                event.direction(), event.author(), event.seq(), event.body(), event.createdAt());
        record.traceContext(TraceContextRef.from(span.getSpanContext()));
        caseRecord.append(record);
        store.markProcessed(event.eventId());
        Log.infof("Applied inbound event %s to case %s", event.eventId(), event.caseId());
        return message.ack();
    }
}
