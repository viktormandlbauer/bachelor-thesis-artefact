package at.thesis.poc.submission.domain;

import java.time.Instant;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;

/**
 * In-memory case record on the submission side. Only the SHA-256 hash of the access
 * token is stored, never the plaintext token. Instances start "staged" (not in the
 * store) and become visible only after the initial AMQP publish succeeded
 * (commit-after-publish, plan §3.1/§7.5).
 */
public final class CaseRecord {

    public static final String STATUS_OPEN = "open";

    private final String caseId;
    private final byte[] tokenHash;
    private final Instant createdAt;
    private volatile String status = STATUS_OPEN;
    private volatile Instant updatedAt;
    private final List<MessageRecord> messages = new CopyOnWriteArrayList<>();
    private final AtomicLong authoredSeq = new AtomicLong();

    public CaseRecord(String caseId, byte[] tokenHash, Instant createdAt) {
        this.caseId = caseId;
        this.tokenHash = tokenHash;
        this.createdAt = createdAt;
        this.updatedAt = createdAt;
    }

    public String caseId() {
        return caseId;
    }

    public byte[] tokenHash() {
        return tokenHash;
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
