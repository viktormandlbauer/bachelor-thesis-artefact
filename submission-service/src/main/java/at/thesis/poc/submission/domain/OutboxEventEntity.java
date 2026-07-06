package at.thesis.poc.submission.domain;

import java.time.Instant;
import java.util.UUID;

import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Transactional outbox row (plan §5.3): committed together with the domain change, then
 * published to Artemis by the relay. Carries the W3C trace context captured at command
 * time so the relay's publish span joins the original request trace (plan §7).
 */
@Entity
@Table(name = "outbox_events")
public class OutboxEventEntity extends PanacheEntityBase {

    public static final String STATUS_PENDING = "PENDING";
    public static final String STATUS_PUBLISHED = "PUBLISHED";

    @Id
    @Column(name = "event_id")
    public UUID eventId;

    @Column(name = "case_id", nullable = false)
    public UUID caseId;

    @Column(name = "address", nullable = false)
    public String address;

    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "payload", nullable = false)
    public String payload;

    @Column(name = "traceparent")
    public String traceparent;

    @Column(name = "tracestate")
    public String tracestate;

    @Column(name = "status", nullable = false)
    public String status;

    @Column(name = "attempts", nullable = false)
    public int attempts;

    @Column(name = "next_attempt_at", nullable = false)
    public Instant nextAttemptAt;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;

    @Column(name = "published_at")
    public Instant publishedAt;

    @Column(name = "last_error")
    public String lastError;
}
