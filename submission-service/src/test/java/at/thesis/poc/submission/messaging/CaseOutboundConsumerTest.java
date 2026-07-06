package at.thesis.poc.submission.messaging;

import static io.restassured.RestAssured.given;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import at.thesis.poc.submission.domain.MessageRepository;
import io.quarkus.test.junit.QuarkusTest;
import io.vertx.core.json.JsonObject;
import jakarta.inject.Inject;

/**
 * Consumer semantics (plan §5.4): idempotent by eventId via the persistent inbox, loud
 * failure for malformed or unprocessable events (a throw rolls back and nacks the
 * delivery so broker redelivery and DLQ routing apply). Invokes the consumer directly
 * with synthetic payloads, so at-least-once redelivery is simulated by calling it twice.
 * Cases are seeded through the real API so the token/outbox path stays exercised.
 */
@QuarkusTest
class CaseOutboundConsumerTest {

    @Inject
    CaseOutboundConsumer consumer;

    @Inject
    MessageRepository messages;

    private static JsonObject outboundEvent(String eventId, String caseId, String body) {
        return new JsonObject()
                .put("eventId", eventId)
                .put("caseId", caseId)
                .put("direction", "outbound")
                .put("author", "management")
                .put("seq", 1L)
                .put("body", body)
                .put("createdAt", Instant.now().toString());
    }

    private String knownCaseId() {
        return given()
                .contentType("application/json")
                .body("{\"message\":\"seed report\"}")
                .post("/api/cases")
                .then().statusCode(201)
                .extract().jsonPath().getString("caseId");
    }

    private long messageCount(String caseId) {
        return messages.count("caseId", UUID.fromString(caseId));
    }

    @Test
    void duplicateDeliveryDoesNotDuplicateThreadMessages() {
        String caseId = knownCaseId();
        JsonObject event = outboundEvent(UUID.randomUUID().toString(), caseId, "reply");

        consumer.onCaseOutbound(event);
        consumer.onCaseOutbound(event);

        assertEquals(2, messageCount(caseId), "seed message plus exactly one reply");
    }

    @Test
    void malformedEventFailsLoudly() {
        assertThrows(IllegalArgumentException.class, () ->
                consumer.onCaseOutbound(new JsonObject().put("eventId", "only-this")));
    }

    @Test
    void wrongDirectionFailsLoudly() {
        String caseId = knownCaseId();
        JsonObject event = outboundEvent(UUID.randomUUID().toString(), caseId, "x")
                .put("direction", "inbound");
        assertThrows(IllegalArgumentException.class, () -> consumer.onCaseOutbound(event));
    }

    @Test
    void unknownCaseFailsLoudly() {
        JsonObject event = outboundEvent(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "x");
        assertThrows(IllegalStateException.class, () -> consumer.onCaseOutbound(event));
    }

    @Test
    void poisonMarkerFailsLoudly() {
        String caseId = knownCaseId();
        JsonObject event = outboundEvent(UUID.randomUUID().toString(), caseId, CaseEvents.POISON_MARKER);
        assertThrows(IllegalStateException.class, () -> consumer.onCaseOutbound(event));
        assertEquals(1, messageCount(caseId), "poison event must not be applied");
    }
}
