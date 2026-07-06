package at.thesis.poc.submission.messaging;

import java.time.Instant;
import java.util.UUID;

import org.eclipse.microprofile.reactive.messaging.Incoming;

import at.thesis.poc.submission.domain.CaseEntity;
import at.thesis.poc.submission.domain.CaseRepository;
import at.thesis.poc.submission.domain.InboxRepository;
import at.thesis.poc.submission.domain.MessageEntity;
import at.thesis.poc.submission.domain.MessageRepository;
import at.thesis.poc.submission.messaging.CaseEvents.CaseEvent;
import at.thesis.poc.submission.observability.TraceAttributes;
import at.thesis.poc.submission.observability.Traceparent;
import io.opentelemetry.api.trace.Span;
import io.quarkus.logging.Log;
import io.smallrye.common.annotation.Blocking;
import io.vertx.core.json.JsonObject;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;

/**
 * Consumes management replies from the durable queue case.outbound.submission.
 *
 * Persistent-inbox pattern (plan §5.4): the inbox insert and the message apply share one
 * transaction; a normal return commits and acks, a throw rolls back and nacks so the
 * channel's failure strategy (reject) hands the delivery to Artemis' bounded-redelivery
 * and DLQ machinery. Duplicates — broker redelivery, or overlapping pods during a
 * rolling update — are detected on the inbox row and acked without effect.
 *
 * @Blocking moves processing off the I/O thread so JDBC is allowed.
 */
@ApplicationScoped
public class CaseOutboundConsumer {

    @Inject
    CaseRepository cases;

    @Inject
    MessageRepository messages;

    @Inject
    InboxRepository inbox;

    @Incoming("case-outbound-in")
    @Blocking
    @Transactional
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

        // Malformed UUIDs throw → nack → redelivery → DLQ, like any unprocessable event.
        UUID eventId = UUID.fromString(event.eventId());
        UUID caseId = UUID.fromString(event.caseId());

        if (inbox.isProcessed(eventId)) {
            Log.infof("Duplicate delivery of event %s for case %s ignored", event.eventId(), event.caseId());
            span.setAttribute("app.duplicate_delivery", true);
            return;
        }
        inbox.record(eventId, Instant.now());

        CaseEntity caseEntity = cases.findById(caseId);
        if (caseEntity == null) {
            // A reply must reference a case this service created; anything else is
            // unprocessable and belongs in the DLQ after bounded redelivery.
            throw new IllegalStateException("Received reply for unknown case " + event.caseId());
        }

        MessageEntity message = new MessageEntity();
        message.messageId = UUID.randomUUID();
        message.eventId = eventId;
        message.caseId = caseId;
        message.direction = event.direction();
        message.author = event.author();
        message.seq = event.seq();
        message.body = event.body();
        message.traceparent = Traceparent.of(span.getSpanContext());
        message.createdAt = event.createdAt();
        messages.persist(message);

        if (event.createdAt().isAfter(caseEntity.updatedAt)) {
            caseEntity.updatedAt = event.createdAt();
        }
        Log.infof("Applied outbound event %s to case %s", event.eventId(), event.caseId());
    }
}
