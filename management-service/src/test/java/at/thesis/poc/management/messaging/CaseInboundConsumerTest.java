package at.thesis.poc.management.messaging;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.time.Instant;
import java.util.UUID;

import org.eclipse.microprofile.reactive.messaging.Message;
import org.junit.jupiter.api.Test;

import at.thesis.poc.management.domain.CaseStore;
import io.quarkus.test.junit.QuarkusTest;
import io.vertx.core.json.JsonObject;
import jakarta.inject.Inject;

/**
 * Consumer semantics (plan §3.4/§6.2): the first inbound event creates the case,
 * processing is idempotent by eventId, and malformed events fail loudly. Invokes the
 * consumer directly with synthetic messages to simulate at-least-once redelivery.
 */
@QuarkusTest
class CaseInboundConsumerTest {

    @Inject
    CaseInboundConsumer consumer;

    @Inject
    CaseStore store;

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
        consumer.onCaseInbound(Message.of(inboundEvent(UUID.randomUUID().toString(), caseId, "hello")));

        assertNotNull(store.get(caseId));
        assertEquals("open", store.get(caseId).status());
        assertEquals(1, store.get(caseId).messageCount());
    }

    @Test
    void duplicateDeliveryDoesNotDuplicateThreadMessages() {
        String caseId = UUID.randomUUID().toString();
        JsonObject event = inboundEvent(UUID.randomUUID().toString(), caseId, "hello");

        consumer.onCaseInbound(Message.of(event));
        consumer.onCaseInbound(Message.of(event));

        assertEquals(1, store.get(caseId).messageCount());
    }

    @Test
    void malformedEventFailsLoudly() {
        assertThrows(IllegalArgumentException.class, () ->
                consumer.onCaseInbound(Message.of(new JsonObject().put("caseId", "only-this"))));
    }

    @Test
    void wrongDirectionFailsLoudly() {
        JsonObject event = inboundEvent(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "x")
                .put("direction", "outbound");
        assertThrows(IllegalArgumentException.class, () -> consumer.onCaseInbound(Message.of(event)));
    }

    @Test
    void poisonMarkerFailsLoudly() {
        String caseId = UUID.randomUUID().toString();
        JsonObject event = inboundEvent(UUID.randomUUID().toString(), caseId, CaseEvents.POISON_MARKER);
        assertThrows(IllegalStateException.class, () -> consumer.onCaseInbound(Message.of(event)));
        assertEquals(null, store.get(caseId), "poison event must not create the case");
    }
}
