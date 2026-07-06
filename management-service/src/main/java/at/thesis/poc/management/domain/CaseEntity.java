package at.thesis.poc.management.domain;

import java.time.Instant;
import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/**
 * Persistent case projection on the management side (plan §6). Created by the first
 * inbound event of a case (the reporter side owns case creation). No token hash here:
 * staff access is authorized by Keycloak, not by case tokens.
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

    @Column(name = "created_at", nullable = false)
    public Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    public Instant updatedAt;
}
