package at.thesis.poc.management.domain;

import java.time.Instant;
import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheRepositoryBase;
import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class InboxRepository implements PanacheRepositoryBase<InboxEventEntity, UUID> {

    public boolean isProcessed(UUID eventId) {
        return findById(eventId) != null;
    }

    /**
     * Check-then-insert instead of insert-on-conflict: the normal duplicate (broker
     * redelivery) is caught by the check; the rare concurrent duplicate across replicas
     * hits the primary-key constraint, rolls back, and is redelivered — the second
     * attempt then sees the row and acks.
     */
    public void record(UUID eventId, Instant receivedAt) {
        InboxEventEntity entity = new InboxEventEntity();
        entity.eventId = eventId;
        entity.receivedAt = receivedAt;
        persist(entity);
    }
}
