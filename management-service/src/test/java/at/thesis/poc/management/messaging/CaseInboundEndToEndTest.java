package at.thesis.poc.management.messaging;

import static io.restassured.RestAssured.given;
import static org.awaitility.Awaitility.await;
import static org.hamcrest.Matchers.equalTo;

import java.time.Duration;
import java.time.Instant;
import java.util.UUID;

import org.eclipse.microprofile.reactive.messaging.Channel;
import org.eclipse.microprofile.reactive.messaging.Emitter;
import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.security.TestSecurity;
import io.vertx.core.json.JsonObject;
import jakarta.inject.Inject;

/**
 * Full broker round trip on the Dev Services Artemis: a case.inbound event published
 * over real AMQP must land in the durable queue case.inbound.management (FQQN binding),
 * pass the persistent inbox, and surface as an open case in the management API. The API
 * read requires the case-manager role (plan §5.2), injected via @TestSecurity.
 */
@QuarkusTest
class CaseInboundEndToEndTest {

    @Inject
    @Channel("test-case-inbound")
    Emitter<JsonObject> testEmitter;

    @Test
    @TestSecurity(user = "staff", roles = {"case-manager"})
    void submittedCaseAppearsInManagementApi() throws Exception {
        String caseId = UUID.randomUUID().toString();
        JsonObject submissionEvent = new JsonObject()
                .put("eventId", UUID.randomUUID().toString())
                .put("caseId", caseId)
                .put("direction", "inbound")
                .put("author", "submission")
                .put("seq", 1L)
                .put("body", "anonymous report")
                .put("createdAt", Instant.now().toString());
        testEmitter.send(submissionEvent).toCompletableFuture().get();

        await().atMost(Duration.ofSeconds(15)).untilAsserted(() ->
                given().get("/api/cases/" + caseId).then()
                        .statusCode(200)
                        .body("status", equalTo("open"))
                        .body("messages.size()", equalTo(1))
                        .body("messages[0].body", equalTo("anonymous report")));
    }
}
