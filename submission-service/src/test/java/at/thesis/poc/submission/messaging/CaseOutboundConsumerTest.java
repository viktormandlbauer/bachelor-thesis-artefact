package at.thesis.poc.submission.messaging;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.time.Instant;
import java.util.UUID;

import org.eclipse.microprofile.reactive.messaging.Message;
import org.junit.jupiter.api.Test;

import at.thesis.poc.submission.domain.CaseRecord;
import at.thesis.poc.submission.domain.CaseStore;
import io.quarkus.test.junit.QuarkusTest;
import io.vertx.core.json.JsonObject;
import jakarta.inject.Inject;

/**
 * Consumer semantics (plan §3.4/§6.2): idempotent by eventId, loud failure for
 * malformed or unprocessable events. Invokes the consumer directly with synthetic
 * messages, so at-least-once redelivery is simulated by calling it twice.
 */
@QuarkusTest
class CaseOutboundConsumerTest {

    @Inject
    CaseOutboundConsumer consumer;

    @Inject
    CaseStore store;

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

    private CaseRecord knownCase() {
        CaseRecord record = new CaseRecord(UUID.randomUUID().toString(), new byte[32], Instant.now());
        store.commit(record);
        return record;
    }

    @Test
    void duplicateDeliveryDoesNotDuplicateThreadMessages() {
        CaseRecord record = knownCase();
        JsonObject event = outboundEvent(UUID.randomUUID().toString(), record.caseId(), "reply");

        consumer.onCaseOutbound(Message.of(event));
        consumer.onCaseOutbound(Message.of(event));

        assertEquals(1, record.messageCount());
    }

    @Test
    void malformedEventFailsLoudly() {
        assertThrows(IllegalArgumentException.class, () ->
                consumer.onCaseOutbound(Message.of(new JsonObject().put("eventId", "only-this"))));
    }

    @Test
    void wrongDirectionFailsLoudly() {
        CaseRecord record = knownCase();
        JsonObject event = outboundEvent(UUID.randomUUID().toString(), record.caseId(), "x")
                .put("direction", "inbound");
        assertThrows(IllegalArgumentException.class, () -> consumer.onCaseOutbound(Message.of(event)));
    }

    @Test
    void unknownCaseFailsLoudly() {
        JsonObject event = outboundEvent(UUID.randomUUID().toString(), UUID.randomUUID().toString(), "x");
        assertThrows(IllegalStateException.class, () -> consumer.onCaseOutbound(Message.of(event)));
    }

    @Test
    void poisonMarkerFailsLoudly() {
        CaseRecord record = knownCase();
        JsonObject event = outboundEvent(UUID.randomUUID().toString(), record.caseId(), CaseEvents.POISON_MARKER);
        assertThrows(IllegalStateException.class, () -> consumer.onCaseOutbound(Message.of(event)));
        assertEquals(0, record.messageCount(), "poison event must not be applied");
    }
}
