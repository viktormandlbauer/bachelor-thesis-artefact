package at.thesis.poc.submission.domain;

import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheRepositoryBase;
import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class CaseRepository implements PanacheRepositoryBase<CaseEntity, UUID> {
}
