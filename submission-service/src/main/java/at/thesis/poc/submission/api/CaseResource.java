package at.thesis.poc.submission.api;

import java.util.Map;

import at.thesis.poc.submission.api.ApiDtos.AppendMessageResponse;
import at.thesis.poc.submission.api.ApiDtos.CaseView;
import at.thesis.poc.submission.api.ApiDtos.CreateCaseResponse;
import at.thesis.poc.submission.api.ApiDtos.MessageRequest;
import at.thesis.poc.submission.domain.CaseService;
import at.thesis.poc.submission.domain.CaseService.CaseCreation;
import at.thesis.poc.submission.domain.CaseService.MessageAppend;
import at.thesis.poc.submission.messaging.CaseEvents;
import at.thesis.poc.submission.observability.TraceAttributes;
import io.opentelemetry.api.trace.Span;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * Anonymous submission API (plan §5.1). The access token is the only credential; a wrong
 * or missing token yields 404 (never 403) so the existence of a case is not confirmed.
 * Phase 2 semantics: a successful POST means the local transaction (domain rows + outbox
 * row) committed — delivery to the management side is the outbox relay's job and is
 * eventually consistent (plan §2/§12).
 */
@Path("/api/cases")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
public class CaseResource {

    static final String TOKEN_NOTE =
            "Save this access token now. It is shown only once and cannot be recovered.";

    @Inject
    CaseService service;

    @POST
    public Response createCase(MessageRequest request) {
        String body = requireMessage(request);
        CaseCreation creation = service.createCase(body);

        TraceAttributes.annotate(Span.current(), creation.caseId(), creation.eventId(),
                CaseEvents.DIRECTION_INBOUND, CaseEvents.AUTHOR_SUBMISSION, null);

        return Response.status(Response.Status.CREATED)
                .entity(new CreateCaseResponse(creation.caseId(), creation.eventId(),
                        creation.accessToken(), TOKEN_NOTE))
                .build();
    }

    @GET
    @Path("{caseId}")
    public CaseView getCase(@PathParam("caseId") String caseId,
                            @HeaderParam("X-Case-Token") String token) {
        TraceAttributes.annotate(Span.current(), caseId, null, null, null, null);
        return CaseView.of(service.getThread(caseId, token));
    }

    @POST
    @Path("{caseId}/messages")
    public Response appendMessage(@PathParam("caseId") String caseId,
                                  @HeaderParam("X-Case-Token") String token,
                                  MessageRequest request) {
        String body = requireMessage(request);
        MessageAppend appended = service.appendReporterMessage(caseId, token, body);

        TraceAttributes.annotate(Span.current(), appended.caseId(), appended.eventId(),
                CaseEvents.DIRECTION_INBOUND, CaseEvents.AUTHOR_SUBMISSION, null);

        return Response.status(Response.Status.ACCEPTED)
                .entity(new AppendMessageResponse(appended.caseId(), appended.eventId(), "accepted"))
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
}
