package at.thesis.poc.management.domain;

import java.time.Instant;
import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Processed inbound AMQP event ids (plan §5.4). Inserted in the same transaction as the
 * message apply, so at-least-once delivery becomes effectively-once processing — across
 * restarts, redeliveries, and overlapping replicas during a rolling update. Replaces the
 * Phase 1 in-memory "seen" set.
 */
@Entity
@Table(name = "inbox_events")
public class InboxEventEntity extends PanacheEntityBase {

    @Id
    @Column(name = "event_id")
    public UUID eventId;

    @Column(name = "received_at", nullable = false)
    public Instant receivedAt;
}
