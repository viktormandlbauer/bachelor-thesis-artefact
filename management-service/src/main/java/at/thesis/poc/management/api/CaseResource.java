package at.thesis.poc.management.api;

import java.time.Instant;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import at.thesis.poc.management.api.ApiDtos.CaseSummary;
import at.thesis.poc.management.api.ApiDtos.CaseView;
import at.thesis.poc.management.api.ApiDtos.MessageRequest;
import at.thesis.poc.management.api.ApiDtos.ReplyResponse;
import at.thesis.poc.management.domain.CaseRecord;
import at.thesis.poc.management.domain.CaseStore;
import at.thesis.poc.management.domain.MessageRecord;
import at.thesis.poc.management.messaging.CaseEventPublisher;
import at.thesis.poc.management.messaging.CaseEvents;
import at.thesis.poc.management.observability.TraceAttributes;
import io.opentelemetry.api.trace.Span;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * Management API (plan §3.3/§4.2). Open and unauthenticated in Phase 1; acceptable only
 * for local compose (Keycloak arrives in a later phase, plan §9.1). Replies are authored
 * as the fixed placeholder identity "management" and use commit-after-publish.
 */
@Path("/api/cases")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class CaseResource {

    @Inject
    CaseStore store;

    @Inject
    CaseEventPublisher publisher;

    @GET
    public List<CaseSummary> listCases(@QueryParam("status") String status) {
        return store.all().stream()
                .filter(record -> status == null || status.isBlank() || record.status().equals(status))
                .sorted(Comparator.comparing(CaseRecord::createdAt).thenComparing(CaseRecord::caseId))
                .map(CaseSummary::of)
                .toList();
    }

    @GET
    @Path("{caseId}")
    public CaseView getCase(@PathParam("caseId") String caseId) {
        CaseRecord caseRecord = requireCase(caseId);
        TraceAttributes.annotate(Span.current(), caseId, null, null, null, null);
        return CaseView.of(caseRecord);
    }

    @POST
    @Path("{caseId}/reply")
    public Response reply(@PathParam("caseId") String caseId, MessageRequest request) {
        String body = requireMessage(request);
        CaseRecord caseRecord = requireCase(caseId);

        String eventId = UUID.randomUUID().toString();
        MessageRecord message = new MessageRecord(eventId, caseId, CaseEvents.DIRECTION_OUTBOUND,
                CaseEvents.AUTHOR_MANAGEMENT, caseRecord.nextAuthoredSeq(), body, Instant.now());

        TraceAttributes.annotate(Span.current(), caseId, eventId,
                CaseEvents.DIRECTION_OUTBOUND, CaseEvents.AUTHOR_MANAGEMENT, null);

        // Span-link target: latest prior opposite-direction event (plan §11 default).
        publisher.publishOutbound(message, caseRecord.latestTraceContext(CaseEvents.DIRECTION_INBOUND));
        caseRecord.append(message);

        return Response.status(Response.Status.ACCEPTED)
                .entity(new ReplyResponse(caseId, eventId, "accepted"))
                .build();
    }

    private String requireMessage(MessageRequest request) {
        if (request == null || request.message() == null || request.message().isBlank()) {
            throw new WebApplicationException(Response.status(Response.Status.BAD_REQUEST)
                    .type(MediaType.APPLICATION_JSON)
                    .entity(Map.of("error", "message must be a non-empty text"))
                    .build());
        }
        return request.message().trim();
    }

    private CaseRecord requireCase(String caseId) {
        CaseRecord caseRecord = store.get(caseId);
        if (caseRecord == null) {
            throw new NotFoundException();
        }
        return caseRecord;
    }
}
