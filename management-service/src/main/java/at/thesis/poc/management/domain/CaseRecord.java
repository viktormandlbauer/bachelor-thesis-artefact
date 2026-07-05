package at.thesis.poc.management.domain;

import java.time.Instant;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;

/**
 * In-memory case record on the management side, created when the first case.inbound
 * event for a case is consumed. Management holds its own copy of the thread; the two
 * services only ever integrate through Artemis (plan §3.4).
 */
public final class CaseRecord {

    public static final String STATUS_OPEN = "open";

    private final String caseId;
    private final Instant createdAt;
    private volatile String status = STATUS_OPEN;
    private volatile Instant updatedAt;
    private final List<MessageRecord> messages = new CopyOnWriteArrayList<>();
    private final AtomicLong authoredSeq = new AtomicLong();

    public CaseRecord(String caseId, Instant createdAt) {
        this.caseId = caseId;
        this.createdAt = createdAt;
        this.updatedAt = createdAt;
    }

    public String caseId() {
        return caseId;
    }

    public Instant createdAt() {
        return createdAt;
    }

    public Instant updatedAt() {
        return updatedAt;
    }

    public String status() {
        return status;
    }

    /** Per-case, per-authoring-service monotonic sequence (plan §3.4). */
    public long nextAuthoredSeq() {
        return authoredSeq.incrementAndGet();
    }

    public void append(MessageRecord message) {
        messages.add(message);
        Instant created = message.createdAt();
        if (created != null && created.isAfter(updatedAt)) {
            updatedAt = created;
        }
    }

    /** Thread ordering contract: by createdAt, tie-broken by eventId (plan §3.4). */
    public List<MessageRecord> sortedMessages() {
        return messages.stream()
                .sorted(Comparator.comparing(MessageRecord::createdAt)
                        .thenComparing(MessageRecord::eventId))
                .toList();
    }

    public int messageCount() {
        return messages.size();
    }

    /**
     * Trace context of the most recent message with the given direction — the span-link
     * target for the next authored event (default policy: latest prior opposite-direction
     * event, plan §11).
     */
    public TraceContextRef latestTraceContext(String direction) {
        List<MessageRecord> sorted = sortedMessages();
        for (int i = sorted.size() - 1; i >= 0; i--) {
            MessageRecord candidate = sorted.get(i);
            if (candidate.direction().equals(direction) && candidate.traceContext() != null) {
                return candidate.traceContext();
            }
        }
        return null;
    }
}
