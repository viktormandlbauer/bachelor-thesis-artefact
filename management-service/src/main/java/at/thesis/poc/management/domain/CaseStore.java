package at.thesis.poc.management.domain;

import java.time.Instant;
import java.util.Collection;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * In-memory store. Phase 1 explicitly has no persistence: cases, threads, and the
 * processed-event dedupe set do not survive a restart (plan §1/§3.4). Single-replica only.
 */
@ApplicationScoped
public class CaseStore {

    private final Map<String, CaseRecord> cases = new ConcurrentHashMap<>();
    private final Set<String> processedEventIds = ConcurrentHashMap.newKeySet();

    public CaseRecord get(String caseId) {
        return caseId == null ? null : cases.get(caseId);
    }

    /** Creates the management-side copy of a case when its first inbound event arrives. */
    public CaseRecord getOrCreate(String caseId, Instant createdAt) {
        return cases.computeIfAbsent(caseId, id -> new CaseRecord(id, createdAt));
    }

    public Collection<CaseRecord> all() {
        return cases.values();
    }

    public boolean isProcessed(String eventId) {
        return processedEventIds.contains(eventId);
    }

    /** Mark only after successful processing, so a failed attempt can be redelivered. */
    public void markProcessed(String eventId) {
        processedEventIds.add(eventId);
    }
}
