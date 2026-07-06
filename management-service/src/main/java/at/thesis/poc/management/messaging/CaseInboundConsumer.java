package at.thesis.poc.management.messaging;

import java.time.Instant;
import java.util.UUID;

import org.eclipse.microprofile.reactive.messaging.Incoming;

import at.thesis.poc.management.domain.CaseEntity;
import at.thesis.poc.management.domain.CaseRepository;
import at.thesis.poc.management.domain.InboxRepository;
import at.thesis.poc.management.domain.MessageEntity;
import at.thesis.poc.management.domain.MessageRepository;
import at.thesis.poc.management.messaging.CaseEvents.CaseEvent;
import at.thesis.poc.management.observability.TraceAttributes;
import at.thesis.poc.management.observability.Traceparent;
import io.opentelemetry.api.trace.Span;
import io.quarkus.logging.Log;
import io.smallrye.common.annotation.Blocking;
import io.vertx.core.json.JsonObject;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;

/**
 * Consumes submissions and follow-ups from the durable queue case.inbound.management.
 * The first inbound event of a case creates the management-side projection as "open".
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
public class CaseInboundConsumer {

    @Inject
    CaseRepository cases;

    @Inject
    MessageRepository messages;

    @Inject
    InboxRepository inbox;

    @Incoming("case-inbound-in")
    @Blocking
    @Transactional
    public void onCaseInbound(JsonObject payload) {
        CaseEvent event = CaseEvents.parse(payload);
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
            caseEntity = new CaseEntity();
            caseEntity.caseId = caseId;
            caseEntity.status = CaseEntity.STATUS_OPEN;
            caseEntity.createdAt = event.createdAt();
            caseEntity.updatedAt = event.createdAt();
            cases.persist(caseEntity);
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
        Log.infof("Applied inbound event %s to case %s", event.eventId(), event.caseId());
    }
}
