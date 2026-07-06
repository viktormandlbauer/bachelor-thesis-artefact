package at.thesis.poc.management.domain;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheRepositoryBase;
import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class MessageRepository implements PanacheRepositoryBase<MessageEntity, UUID> {

    /** Thread ordering contract: by createdAt, tie-broken by eventId (Phase 1 §3.4). */
    public List<MessageEntity> thread(UUID caseId) {
        return list("caseId = ?1 order by createdAt, eventId", caseId);
    }

    /** Per-case, per-side monotonic sequence; the authoring side owns one direction. */
    public long nextSeq(UUID caseId, String direction) {
        Long max = getEntityManager()
                .createQuery("select max(m.seq) from MessageEntity m"
                        + " where m.caseId = :caseId and m.direction = :direction", Long.class)
                .setParameter("caseId", caseId)
                .setParameter("direction", direction)
                .getSingleResult();
        return (max == null ? 0 : max) + 1;
    }

    /**
     * Traceparent of the most recent message with the given direction — the span-link
     * target for the next authored event (latest prior opposite-direction event).
     */
    public String latestTraceparent(UUID caseId, String direction) {
        return find("caseId = ?1 and direction = ?2 and traceparent is not null"
                        + " order by createdAt desc, eventId desc", caseId, direction)
                .firstResultOptional()
                .map(message -> message.traceparent)
                .orElse(null);
    }

    /** Message count per case in one query (case-list summaries without N+1). */
    public Map<UUID, Long> countByCase() {
        Map<UUID, Long> counts = new HashMap<>();
        getEntityManager()
                .createQuery("select m.caseId, count(m) from MessageEntity m group by m.caseId",
                        Object[].class)
                .getResultList()
                .forEach(row -> counts.put((UUID) row[0], (Long) row[1]));
        return counts;
    }
}
