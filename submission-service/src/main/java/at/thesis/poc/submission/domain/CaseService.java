package at.thesis.poc.submission.domain;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import at.thesis.poc.submission.messaging.CaseEvents;
import at.thesis.poc.submission.observability.TraceAttributes;
import at.thesis.poc.submission.observability.Traceparent;
import at.thesis.poc.submission.security.TokenService;
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
 * Reporter-side commands and queries (plan §5.1/§5.3). Every command is one local
 * transaction that writes the domain change AND the outbox row; the HTTP response means
 * "committed locally, will be delivered", never "the other side has consumed it"
 * (eventual consistency, plan §12). Publishing is the OutboxRelay's job.
 *
 * Authorization stays 404-based: a wrong or missing token is indistinguishable from a
 * missing case, so the API never confirms that a case exists.
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
    TokenService tokens;

    @Inject
    Tracer tracer;

    public record CaseCreation(String caseId, String eventId, String accessToken) {
    }

    public record MessageAppend(String caseId, String eventId) {
    }

    public record CaseThread(CaseEntity caseEntity, List<MessageEntity> messages) {
    }

    @Transactional
    public CaseCreation createCase(String body) {
        Instant now = Instant.now();
        UUID caseId = UUID.randomUUID();
        UUID eventId = UUID.randomUUID();
        String accessToken = tokens.generate();

        CaseEntity caseEntity = new CaseEntity();
        caseEntity.caseId = caseId;
        caseEntity.status = CaseEntity.STATUS_OPEN;
        caseEntity.accessTokenHash = tokens.hashToText(accessToken);
        caseEntity.createdAt = now;
        caseEntity.updatedAt = now;
        cases.persist(caseEntity);

        authorInboundEvent(caseId, eventId, 1, body, now, null);
        return new CaseCreation(caseId.toString(), eventId.toString(), accessToken);
    }

    @Transactional
    public MessageAppend appendReporterMessage(String rawCaseId, String token, String body) {
        CaseEntity caseEntity = requireAuthorized(rawCaseId, token);
        Instant now = Instant.now();
        UUID eventId = UUID.randomUUID();
        long seq = messages.nextSeq(caseEntity.caseId, CaseEvents.DIRECTION_INBOUND);
        // Span-link target: latest prior opposite-direction event (Phase 1 §11 default).
        String linkTraceparent = messages.latestTraceparent(caseEntity.caseId, CaseEvents.DIRECTION_OUTBOUND);

        authorInboundEvent(caseEntity.caseId, eventId, seq, body, now, linkTraceparent);
        caseEntity.updatedAt = now;
        return new MessageAppend(caseEntity.caseId.toString(), eventId.toString());
    }

    @Transactional
    public CaseThread getThread(String rawCaseId, String token) {
        CaseEntity caseEntity = requireAuthorized(rawCaseId, token);
        return new CaseThread(caseEntity, messages.thread(caseEntity.caseId));
    }

    /**
     * Authors one reporter message: message row plus outbox row in the ambient
     * transaction, under an "author" span whose context is persisted with both rows so
     * the relay publish (plan §7) and later span links stay attached to this trace.
     */
    private void authorInboundEvent(UUID caseId, UUID eventId, long seq, String body,
                                    Instant now, String linkTraceparent) {
        SpanBuilder spanBuilder = tracer.spanBuilder("author case.inbound event")
                .setSpanKind(SpanKind.INTERNAL);
        SpanContext link = Traceparent.parse(linkTraceparent);
        if (link.isValid()) {
            spanBuilder.addLink(link);
        }
        Span span = spanBuilder.startSpan();
        try (Scope ignored = span.makeCurrent()) {
            TraceAttributes.annotate(span, caseId.toString(), eventId.toString(),
                    CaseEvents.DIRECTION_INBOUND, CaseEvents.AUTHOR_SUBMISSION,
                    CaseEvents.ADDRESS_INBOUND);
            String traceparent = Traceparent.of(span.getSpanContext());

            MessageEntity message = new MessageEntity();
            message.messageId = UUID.randomUUID();
            message.eventId = eventId;
            message.caseId = caseId;
            message.direction = CaseEvents.DIRECTION_INBOUND;
            message.author = CaseEvents.AUTHOR_SUBMISSION;
            message.seq = seq;
            message.body = body;
            message.traceparent = traceparent;
            message.createdAt = now;
            messages.persist(message);

            OutboxEventEntity outboxRow = new OutboxEventEntity();
            outboxRow.eventId = eventId;
            outboxRow.caseId = caseId;
            outboxRow.address = CaseEvents.ADDRESS_INBOUND;
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
    }

    private CaseEntity requireAuthorized(String rawCaseId, String token) {
        UUID caseId;
        try {
            caseId = UUID.fromString(rawCaseId);
        } catch (IllegalArgumentException | NullPointerException e) {
            throw new NotFoundException();
        }
        CaseEntity caseEntity = cases.findById(caseId);
        if (caseEntity == null || !tokens.matchesHash(token, caseEntity.accessTokenHash)) {
            throw new NotFoundException();
        }
        return caseEntity;
    }
}
