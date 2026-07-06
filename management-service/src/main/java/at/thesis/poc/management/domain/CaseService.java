package at.thesis.poc.management.domain;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import at.thesis.poc.management.messaging.CaseEvents;
import at.thesis.poc.management.observability.TraceAttributes;
import at.thesis.poc.management.observability.Traceparent;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanBuilder;
import io.opentelemetry.api.trace.SpanContext;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.NotFoundException;

/**
 * Staff-side commands and queries (plan §5.2/§5.3). A reply is one local transaction
 * that writes the message AND the outbox row; the HTTP response means "committed
 * locally, will be delivered" (eventual consistency, plan §12). Publishing is the
 * OutboxRelay's job. The reply author is the authenticated Keycloak principal, passed in
 * by the resource layer — never taken from the request body.
 */
@ApplicationScoped
public class CaseService {

    @Inject
    CaseRepository cases;

    @Inject
    MessageRepository messages;

    @Inject
    OutboxRepository outbox;

    @Inject
    Tracer tracer;

    public record ReplyResult(String caseId, String eventId) {
    }

    public record CaseSummaryData(CaseEntity caseEntity, long messageCount) {
    }

    public record CaseThread(CaseEntity caseEntity, List<MessageEntity> messages) {
    }

    @Transactional
    public List<CaseSummaryData> listCases(String status) {
        Map<UUID, Long> counts = messages.countByCase();
        return cases.byStatus(status).stream()
                .map(caseEntity -> new CaseSummaryData(caseEntity,
                        counts.getOrDefault(caseEntity.caseId, 0L)))
                .toList();
    }

    @Transactional
    public CaseThread getThread(String rawCaseId) {
        CaseEntity caseEntity = requireCase(rawCaseId);
        return new CaseThread(caseEntity, messages.thread(caseEntity.caseId));
    }

    @Transactional
    public ReplyResult reply(String rawCaseId, String author, String body) {
        CaseEntity caseEntity = requireCase(rawCaseId);
        Instant now = Instant.now();
        UUID eventId = UUID.randomUUID();
        long seq = messages.nextSeq(caseEntity.caseId, CaseEvents.DIRECTION_OUTBOUND);
        // Span-link target: latest prior opposite-direction event (Phase 1 §11 default).
        String linkTraceparent = messages.latestTraceparent(caseEntity.caseId, CaseEvents.DIRECTION_INBOUND);

        SpanBuilder spanBuilder = tracer.spanBuilder("author case.outbound event")
                .setSpanKind(SpanKind.INTERNAL);
        SpanContext link = Traceparent.parse(linkTraceparent);
        if (link.isValid()) {
            spanBuilder.addLink(link);
        }
        Span span = spanBuilder.startSpan();
        try (Scope ignored = span.makeCurrent()) {
            TraceAttributes.annotate(span, caseEntity.caseId.toString(), eventId.toString(),
                    CaseEvents.DIRECTION_OUTBOUND, author, CaseEvents.ADDRESS_OUTBOUND);
            String traceparent = Traceparent.of(span.getSpanContext());

            MessageEntity message = new MessageEntity();
            message.messageId = UUID.randomUUID();
            message.eventId = eventId;
            message.caseId = caseEntity.caseId;
            message.direction = CaseEvents.DIRECTION_OUTBOUND;
            message.author = author;
            message.seq = seq;
            message.body = body;
            message.traceparent = traceparent;
            message.createdAt = now;
            messages.persist(message);

            OutboxEventEntity outboxRow = new OutboxEventEntity();
            outboxRow.eventId = eventId;
            outboxRow.caseId = caseEntity.caseId;
            outboxRow.address = CaseEvents.ADDRESS_OUTBOUND;
            outboxRow.payload = CaseEvents.toJson(message).encode();
            outboxRow.traceparent = traceparent;
            outboxRow.status = OutboxEventEntity.STATUS_PENDING;
            outboxRow.attempts = 0;
            outboxRow.nextAttemptAt = now;
            outboxRow.createdAt = now;
            outbox.persist(outboxRow);
        } finally {
            span.end();
        }

        caseEntity.updatedAt = now;
        return new ReplyResult(caseEntity.caseId.toString(), eventId.toString());
    }

    private CaseEntity requireCase(String rawCaseId) {
        UUID caseId;
        try {
            caseId = UUID.fromString(rawCaseId);
        } catch (IllegalArgumentException | NullPointerException e) {
            throw new NotFoundException();
        }
        CaseEntity caseEntity = cases.findById(caseId);
        if (caseEntity == null) {
            throw new NotFoundException();
        }
        return caseEntity;
    }
}
