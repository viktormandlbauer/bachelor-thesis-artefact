package at.thesis.poc.submission.domain;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheRepositoryBase;
import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class OutboxRepository implements PanacheRepositoryBase<OutboxEventEntity, UUID> {

    /**
     * Claims the next due PENDING row. FOR UPDATE SKIP LOCKED is the property that makes
     * the relay safe with replicas > 1 (plan §1 row 2): concurrent relays never block on
     * or double-publish the same row; the lock is held until the surrounding transaction
     * commits the status change.
     */
    @SuppressWarnings("unchecked")
    public OutboxEventEntity claimNext() {
        List<OutboxEventEntity> rows = getEntityManager()
                .createNativeQuery("""
                        select * from submission.outbox_events
                        where status = 'PENDING' and next_attempt_at <= now()
                        order by created_at
                        limit 1
                        for update skip locked
                        """, OutboxEventEntity.class)
                .getResultList();
        return rows.isEmpty() ? null : rows.get(0);
    }

    public long pendingCount() {
        return count("status", OutboxEventEntity.STATUS_PENDING);
    }
}
