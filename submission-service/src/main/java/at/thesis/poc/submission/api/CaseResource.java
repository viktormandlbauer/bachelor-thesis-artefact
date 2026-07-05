package at.thesis.poc.submission.api;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

import at.thesis.poc.submission.api.ApiDtos.AppendMessageResponse;
import at.thesis.poc.submission.api.ApiDtos.CaseView;
import at.thesis.poc.submission.api.ApiDtos.CreateCaseResponse;
import at.thesis.poc.submission.api.ApiDtos.MessageRequest;
import at.thesis.poc.submission.domain.CaseRecord;
import at.thesis.poc.submission.domain.CaseStore;
import at.thesis.poc.submission.domain.MessageRecord;
import at.thesis.poc.submission.messaging.CaseEventPublisher;
import at.thesis.poc.submission.messaging.CaseEvents;
import at.thesis.poc.submission.observability.TraceAttributes;
import at.thesis.poc.submission.security.TokenService;
import io.opentelemetry.api.trace.Span;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * Anonymous submission API (plan §3.1/§3.2/§4.1). The access token is the only
 * credential; a wrong or missing token yields 404 (never 403) so the existence of a
 * case is not confirmed. All authored events use commit-after-publish: local state
 * becomes visible only after Artemis accepted the event.
 */
@Path("/api/cases")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class CaseResource {

    static final String TOKEN_NOTE =
            "Save this access token now. It is shown only once and cannot be recovered.";

    @Inject
    CaseStore store;

    @Inject
    TokenService tokens;

    @Inject
    CaseEventPublisher publisher;

    @POST
    public Response createCase(MessageRequest request) {
        String body = requireMessage(request);
        Instant now = Instant.now();
        String caseId = UUID.randomUUID().toString();
        String eventId = UUID.randomUUID().toString();
        String accessToken = tokens.generate();

        CaseRecord staged = new CaseRecord(caseId, tokens.hash(accessToken), now);
        MessageRecord message = new MessageRecord(eventId, caseId, CaseEvents.DIRECTION_INBOUND,
                CaseEvents.AUTHOR_SUBMISSION, staged.nextAuthoredSeq(), body, now);

        TraceAttributes.annotate(Span.current(), caseId, eventId,
                CaseEvents.DIRECTION_INBOUND, CaseEvents.AUTHOR_SUBMISSION, null);

        publisher.publishInbound(message, null);
        staged.append(message);
        store.commit(staged);

        return Response.status(Response.Status.CREATED)
                .entity(new CreateCaseResponse(caseId, eventId, accessToken, TOKEN_NOTE))
                .build();
    }

    @GET
    @Path("{caseId}")
    public CaseView getCase(@PathParam("caseId") String caseId,
                            @HeaderParam("X-Case-Token") String token) {
        CaseRecord caseRecord = requireAuthorized(caseId, token);
        TraceAttributes.annotate(Span.current(), caseId, null, null, null, null);
        return CaseView.of(caseRecord);
    }

    @POST
    @Path("{caseId}/messages")
    public Response appendMessage(@PathParam("caseId") String caseId,
                                  @HeaderParam("X-Case-Token") String token,
                                  MessageRequest request) {
        String body = requireMessage(request);
        CaseRecord caseRecord = requireAuthorized(caseId, token);

        String eventId = UUID.randomUUID().toString();
        MessageRecord message = new MessageRecord(eventId, caseId, CaseEvents.DIRECTION_INBOUND,
                CaseEvents.AUTHOR_SUBMISSION, caseRecord.nextAuthoredSeq(), body, Instant.now());

        TraceAttributes.annotate(Span.current(), caseId, eventId,
                CaseEvents.DIRECTION_INBOUND, CaseEvents.AUTHOR_SUBMISSION, null);

        // Span-link target: latest prior opposite-direction event (plan §11 default).
        publisher.publishInbound(message, caseRecord.latestTraceContext(CaseEvents.DIRECTION_OUTBOUND));
        caseRecord.append(message);

        return Response.status(Response.Status.ACCEPTED)
                .entity(new AppendMessageResponse(caseId, eventId, "accepted"))
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

    private CaseRecord requireAuthorized(String caseId, String token) {
        CaseRecord caseRecord = store.get(caseId);
        if (caseRecord == null || !tokens.matches(token, caseRecord.tokenHash())) {
            throw new NotFoundException();
        }
        return caseRecord;
    }
}
