package at.thesis.poc.management.api;

import java.util.Map;

import at.thesis.poc.management.messaging.PublishFailedException;
import io.quarkus.logging.Log;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.ext.ExceptionMapper;
import jakarta.ws.rs.ext.Provider;

@Provider
public class PublishFailedExceptionMapper implements ExceptionMapper<PublishFailedException> {

    @Override
    public Response toResponse(PublishFailedException exception) {
        Log.error("AMQP publish failed; returning 503 and discarding staged state", exception);
        return Response.status(Response.Status.SERVICE_UNAVAILABLE)
                .type(MediaType.APPLICATION_JSON)
                .entity(Map.of("error", "The message broker did not accept the event. Please retry."))
                .build();
    }
}
