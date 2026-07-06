package at.thesis.poc.management.domain;

import java.util.List;
import java.util.UUID;

import io.quarkus.hibernate.orm.panache.PanacheRepositoryBase;
import jakarta.enterprise.context.ApplicationScoped;

@ApplicationScoped
public class CaseRepository implements PanacheRepositoryBase<CaseEntity, UUID> {

    public List<CaseEntity> byStatus(String status) {
        if (status == null || status.isBlank()) {
            return list("order by createdAt, caseId");
        }
        return list("status = ?1 order by createdAt, caseId", status);
    }
}
