package at.thesis.poc.management.api;

import java.util.List;
import java.util.Map;

import org.eclipse.microprofile.jwt.JsonWebToken;

import at.thesis.poc.management.api.ApiDtos.CaseSummary;
import at.thesis.poc.management.api.ApiDtos.CaseView;
import at.thesis.poc.management.api.ApiDtos.MessageRequest;
import at.thesis.poc.management.api.ApiDtos.ReplyResponse;
import at.thesis.poc.management.domain.CaseService;
import at.thesis.poc.management.domain.CaseService.ReplyResult;
import at.thesis.poc.management.messaging.CaseEvents;
import at.thesis.poc.management.observability.TraceAttributes;
import io.opentelemetry.api.trace.Span;
import io.quarkus.security.identity.SecurityIdentity;
import jakarta.annotation.security.RolesAllowed;
import jakarta.enterprise.context.RequestScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

/**
 * Management API (plan §5.2). Every endpoint requires a valid Keycloak JWT with the
 * case-manager realm role: no token → 401, valid token without the role → 403. The
 * reply author is derived from the authenticated principal (preferred_username, falling
 * back to the principal name/sub) — never from the request body. Identity checks are
 * stateless (JWKS), so any replica can serve any request.
 */
@Path("/api/cases")
@Produces(MediaType.APPLICATION_JSON)
@Consumes(MediaType.APPLICATION_JSON)
@RolesAllowed("case-manager")
@RequestScoped
public class CaseResource {

    @Inject
    CaseService service;

    @Inject
    SecurityIdentity identity;

    @Inject
    JsonWebToken jwt;

    @GET
    public List<CaseSummary> listCases(@QueryParam("status") String status) {
        return service.listCases(status).stream().map(CaseSummary::of).toList();
    }

    @GET
    @Path("{caseId}")
    public CaseView getCase(@PathParam("caseId") String caseId) {
        TraceAttributes.annotate(Span.current(), caseId, null, null, null, null);
        return CaseView.of(service.getThread(caseId));
    }

    @POST
    @Path("{caseId}/reply")
    public Response reply(@PathParam("caseId") String caseId, MessageRequest request) {
        String body = requireMessage(request);
        String author = authenticatedAuthor();

        ReplyResult result = service.reply(caseId, author, body);

        TraceAttributes.annotate(Span.current(), result.caseId(), result.eventId(),
                CaseEvents.DIRECTION_OUTBOUND, author, null);

        return Response.status(Response.Status.ACCEPTED)
                .entity(new ReplyResponse(result.caseId(), result.eventId(), "accepted"))
                .build();
    }

    /** Stable, non-sensitive staff identity from the JWT (plan §5.2/§5.5). */
    private String authenticatedAuthor() {
        String preferredUsername = jwt.getClaim("preferred_username");
        if (preferredUsername != null && !preferredUsername.isBlank()) {
            return preferredUsername;
        }
        return identity.getPrincipal().getName();
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
