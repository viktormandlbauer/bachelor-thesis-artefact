package at.thesis.poc.management.domain;

import java.time.Instant;

/**
 * One message in a case thread. The trace context is captured when the message is
 * authored (publish span) or consumed (process span) and enables span links from
 * later actions in the same case.
 */
public final class MessageRecord {

    private final String eventId;
    private final String caseId;
    private final String direction;
    private final String author;
    private final long seq;
    private final String body;
    private final Instant createdAt;
    private volatile TraceContextRef traceContext;

    public MessageRecord(String eventId, String caseId, String direction, String author,
                         long seq, String body, Instant createdAt) {
        this.eventId = eventId;
        this.caseId = caseId;
        this.direction = direction;
        this.author = author;
        this.seq = seq;
        this.body = body;
        this.createdAt = createdAt;
    }

    public String eventId() {
        return eventId;
    }

    public String caseId() {
        return caseId;
    }

    public String direction() {
        return direction;
    }

    public String author() {
        return author;
    }

    public long seq() {
        return seq;
    }

    public String body() {
        return body;
    }

    public Instant createdAt() {
        return createdAt;
    }

    public TraceContextRef traceContext() {
        return traceContext;
    }

    public void traceContext(TraceContextRef traceContext) {
        this.traceContext = traceContext;
    }
}
