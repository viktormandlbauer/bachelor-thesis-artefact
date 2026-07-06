package at.thesis.poc.management.domain;

import java.time.Instant;
import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * One message of a case thread (plan §6). The unique event_id is the second line of
 * defence against duplicate processing after the inbox check. The W3C traceparent of the
 * authoring/consuming span is persisted so later actions in the same case can add span
 * links back to the most recent related event (Phase 1 §5.4 behavior, now durable).
 */
@Entity
@Table(name = "messages")
public class MessageEntity extends PanacheEntityBase {

    @Id
    @Column(name = "message_id")
    public UUID messageId;

    @Column(name = "event_id", nullable = false, unique = true)
    public UUID eventId;

    @Column(name = "case_id", nullable = false)
    public UUID caseId;

    @Column(name = "direction", nullable = false)
    public String direction;

    @Column(name = "author", nullable = false)
    public String author;

    @Column(name = "seq", nullable = false)
    public long seq;

    @Column(name = "body", nullable = false)
    public String body;

    @Column(name = "traceparent")
    public String traceparent;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;
}
