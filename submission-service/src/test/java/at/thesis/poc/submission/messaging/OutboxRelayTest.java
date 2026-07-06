package at.thesis.poc.submission.messaging;

import static io.restassured.RestAssured.given;
import static org.awaitility.Awaitility.await;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import java.time.Duration;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import at.thesis.poc.submission.domain.OutboxEventEntity;
import at.thesis.poc.submission.domain.OutboxRepository;
import io.quarkus.narayana.jta.QuarkusTransaction;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;

/**
 * Outbox happy path (plan §5.3/§10.3): a create commits a PENDING row in the same
 * transaction, and the scheduled relay publishes it to the Dev Services broker and marks
 * it PUBLISHED with the trace context that was captured at command time. The broker-down
 * half of §10.3 is a compose demo (stop Artemis, watch attempts grow), not a unit test.
 */
@QuarkusTest
class OutboxRelayTest {

    @Inject
    OutboxRepository outbox;

    @Test
    void createdCaseOutboxRowGetsPublishedByRelay() {
        String eventId = given()
                .contentType("application/json")
                .body("{\"message\":\"outbox check\"}")
                .post("/api/cases")
                .then().statusCode(201)
                .extract().jsonPath().getString("eventId");

        await().atMost(Duration.ofSeconds(15)).untilAsserted(() -> {
            // Awaitility polls on its own thread: open an explicit transaction for the EM.
            OutboxEventEntity row = QuarkusTransaction.requiringNew()
                    .call(() -> outbox.findById(UUID.fromString(eventId)));
            assertNotNull(row);
            assertEquals(OutboxEventEntity.STATUS_PUBLISHED, row.status);
            assertNotNull(row.publishedAt);
            assertNotNull(row.traceparent, "trace context must be persisted with the row");
        });
    }
}
