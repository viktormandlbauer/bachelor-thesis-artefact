package at.thesis.poc.submission.domain;

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

    /** Makes a staged case visible through the API (commit-after-publish). */
    public void commit(CaseRecord caseRecord) {
        cases.put(caseRecord.caseId(), caseRecord);
    }

    public boolean isProcessed(String eventId) {
        return processedEventIds.contains(eventId);
    }

    /** Mark only after successful processing, so a failed attempt can be redelivered. */
    public void markProcessed(String eventId) {
        processedEventIds.add(eventId);
    }
}
