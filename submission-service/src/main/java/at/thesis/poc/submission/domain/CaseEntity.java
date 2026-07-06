package at.thesis.poc.submission.domain;

import java.time.Instant;
import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Persistent case on the submission side (plan §6). Only the SHA-256 hash of the access
 * token is stored, never the plaintext (plan §5.1). Replaces the Phase 1 in-memory
 * CaseRecord: state now survives restarts, which is what makes the pod stateless.
 */
@Entity
@Table(name = "cases")
public class CaseEntity extends PanacheEntityBase {

    public static final String STATUS_OPEN = "open";

    @Id
    @Column(name = "case_id")
    public UUID caseId;

    @Column(name = "status", nullable = false)
    public String status;

    @Column(name = "access_token_hash", nullable = false)
    public String accessTokenHash;

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    public Instant updatedAt;
}
