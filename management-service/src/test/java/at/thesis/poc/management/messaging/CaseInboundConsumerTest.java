package at.thesis.poc.management.messaging;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import at.thesis.poc.management.domain.CaseEntity;
import at.thesis.poc.management.domain.CaseRepository;
import at.thesis.poc.management.domain.MessageRepository;
import io.quarkus.test.junit.QuarkusTest;
import io.vertx.core.json.JsonObject;
import jakarta.inject.Inject;

/**
 * Consumer semantics (plan §5.4): the first inbound event creates the case projection,
 * processing is idempotent by eventId via the persistent inbox, and malformed events
 * fail loudly (a throw rolls back and nacks the delivery so broker redelivery and DLQ
 * routing apply). Invokes the consumer directly with synthetic payloads to simulate
 * at-least-once redelivery.
 */
@QuarkusTest
class CaseInboundConsumerTest {

    @Inject
    CaseInboundConsumer consumer;

    @Inject
    CaseRepository cases;

    @Inject
    MessageRepository messages;

    private static JsonObject inboundEvent(String eventId, String caseId, String body) {
        return new JsonObject()
                .put("eventId", eventId)
                .put("caseId", caseId)
                .put("direction", "inbound")
                .put("author", "submission")
                .put("seq", 1L)
                .put("body", body)
                .put("createdAt", Instant.now().toString());
    }

    @Test
    void firstInboundEventCreatesOpenCase() {
        String caseId = UUID.randomUUID().toString();
        consumer.onCaseInbound(inboundEvent(UUID.randomUUID().toString(), caseId, "hello"));

        CaseEntity caseEntity = cases.findById(UUID.fromString(caseId));
        assertNotNull(caseEntity);
        assertEquals("open", caseEntity.status);
        assertEquals(1, messages.count("caseId", UUID.fromString(caseId)));
    }

    @Test
    void duplicateDeliveryDoesNotDuplicateThreadMessages() {
        String caseId = UUID.randomUUID().toString();
        JsonObject event = inboundEvent(UUID.randomUUID().toString(), caseId, "hello");

        consumer.onCaseInbound(event);
        consumer.onCaseInbound(event);

        assertEquals(1, messages.count("caseId", UUID.fromString(caseId)));
    }

    @Test
    void malformedEventFailsLoudly() {
        assertThrows(IllegalArgumentException.class, () ->
                consumer.onCaseInbound(new JsonObject().put("caseId", "only-this")));
    }

    @Test
    void wrongDirectionFailsLoudly() {
        JsonObject event = inboundEvent(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "x")
                .put("direction", "outbound");
        assertThrows(IllegalArgumentException.class, () -> consumer.onCaseInbound(event));
    }

    @Test
    void poisonMarkerFailsLoudly() {
        String caseId = UUID.randomUUID().toString();
        JsonObject event = inboundEvent(UUID.randomUUID().toString(), caseId, CaseEvents.POISON_MARKER);
        assertThrows(IllegalStateException.class, () -> consumer.onCaseInbound(event));
        assertNull(cases.findById(UUID.fromString(caseId)), "poison event must not create the case");
    }
}
