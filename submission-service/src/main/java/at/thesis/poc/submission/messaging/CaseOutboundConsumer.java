package at.thesis.poc.submission.messaging;

import org.eclipse.microprofile.reactive.messaging.Incoming;

import at.thesis.poc.submission.domain.CaseRecord;
import at.thesis.poc.submission.domain.CaseStore;
import at.thesis.poc.submission.domain.MessageRecord;
import at.thesis.poc.submission.domain.TraceContextRef;
import at.thesis.poc.submission.messaging.CaseEvents.CaseEvent;
import at.thesis.poc.submission.observability.TraceAttributes;
import io.opentelemetry.api.trace.Span;
import io.quarkus.logging.Log;
import io.vertx.core.json.JsonObject;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Consumes management replies from the durable queue case.outbound.submission.
 *
 * The payload-style signature uses SmallRye's post-processing acknowledgement: a normal
 * return acks the message only after successful processing, and a thrown exception nacks
 * it so the channel's failure strategy (reject) hands it to Artemis' bounded-redelivery
 * and DLQ machinery (plan §6.2). A Message<T> signature would make acknowledgement
 * manual and a throw would leave the delivery unsettled forever.
 *
 * Delivery is at-least-once: processing is idempotent by eventId (in-process only,
 * plan §3.4).
 */
@ApplicationScoped
public class CaseOutboundConsumer {

    @Inject
    CaseStore store;

    @Incoming("case-outbound-in")
    public void onCaseOutbound(JsonObject payload) {
        CaseEvent event = CaseEvents.parse(payload);
        if (!CaseEvents.DIRECTION_OUTBOUND.equals(event.direction())) {
            throw new IllegalArgumentException(
                    "Unexpected direction on case.outbound: " + event.direction());
        }
        if (CaseEvents.POISON_MARKER.equals(event.body())) {
            throw new IllegalStateException("Poison marker event, failing on purpose");
        }

        Span span = Span.current();
        TraceAttributes.annotate(span, event.caseId(), event.eventId(),
                event.direction(), event.author(), CaseEvents.ADDRESS_OUTBOUND);

        if (store.isProcessed(event.eventId())) {
            Log.infof("Duplicate delivery of event %s for case %s ignored", event.eventId(), event.caseId());
            span.setAttribute("app.duplicate_delivery", true);
            return;
        }

        CaseRecord caseRecord = store.get(event.caseId());
        if (caseRecord == null) {
            // In-memory Phase 1: after a restart the submission side no longer knows the
            // case; the event is unprocessable and belongs in the DLQ after redelivery.
            throw new IllegalStateException("Received reply for unknown case " + event.caseId());
        }

        MessageRecord record = new MessageRecord(event.eventId(), event.caseId(),
                event.direction(), event.author(), event.seq(), event.body(), event.createdAt());
        record.traceContext(TraceContextRef.from(span.getSpanContext()));
        caseRecord.append(record);
        store.markProcessed(event.eventId());
        Log.infof("Applied outbound event %s to case %s", event.eventId(), event.caseId());
    }
}
