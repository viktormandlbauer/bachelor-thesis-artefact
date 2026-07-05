package at.thesis.poc.submission.messaging;

import static io.restassured.RestAssured.given;
import static org.awaitility.Awaitility.await;

import java.time.Duration;
import java.time.Instant;
import java.util.UUID;

import org.eclipse.microprofile.reactive.messaging.Channel;
import org.eclipse.microprofile.reactive.messaging.Emitter;
import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.restassured.response.Response;
import io.vertx.core.json.JsonObject;
import jakarta.inject.Inject;

/**
 * Full broker round trip on the Dev Services Artemis: a case.outbound event published
 * over real AMQP must land in the durable queue case.outbound.submission (FQQN binding,
 * plan §7.4), be consumed, and appear in the token-gated thread.
 */
@QuarkusTest
class CaseOutboundEndToEndTest {

    @Inject
    @Channel("test-case-outbound")
    Emitter<JsonObject> testEmitter;

    @Test
    void managementReplyArrivesInSubmissionThread() throws Exception {
        Response created = given()
                .contentType("application/json")
                .body("{\"message\":\"initial report\"}")
                .post("/api/cases");
        created.then().statusCode(201);
        String caseId = created.jsonPath().getString("caseId");
        String token = created.jsonPath().getString("accessToken");

        JsonObject replyEvent = new JsonObject()
                .put("eventId", UUID.randomUUID().toString())
                .put("caseId", caseId)
                .put("direction", "outbound")
                .put("author", "management")
                .put("seq", 1L)
                .put("body", "we hear you")
                .put("createdAt", Instant.now().toString());
        testEmitter.send(replyEvent).toCompletableFuture().get();

        await().atMost(Duration.ofSeconds(15)).untilAsserted(() ->
                given().header("X-Case-Token", token)
                        .get("/api/cases/" + caseId).then()
                        .statusCode(200)
                        .body("messages.size()", org.hamcrest.Matchers.is(2)));
    }
}
