package at.thesis.poc.management.api;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.greaterThanOrEqualTo;
import static org.hamcrest.Matchers.hasSize;
import static org.hamcrest.Matchers.notNullValue;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import at.thesis.poc.management.domain.CaseRecord;
import at.thesis.poc.management.domain.CaseStore;
import at.thesis.poc.management.domain.MessageRecord;
import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;

/**
 * REST contract tests (plan §4.2). Cases are seeded through the store the same way the
 * inbound consumer creates them; replies exercise the real commit-after-publish path
 * against the Dev Services Artemis broker.
 */
@QuarkusTest
class CaseResourceTest {

    @Inject
    CaseStore store;

    private CaseRecord seededCase() {
        String caseId = UUID.randomUUID().toString();
        Instant now = Instant.now();
        CaseRecord record = store.getOrCreate(caseId, now);
        record.append(new MessageRecord(UUID.randomUUID().toString(), caseId,
                "inbound", "submission", 1, "reporter message", now));
        return record;
    }

    @Test
    void unknownCaseYields404() {
        given().get("/api/cases/00000000-0000-0000-0000-000000000000").then().statusCode(404);
        given().contentType("application/json").body("{\"message\":\"hi\"}")
                .post("/api/cases/00000000-0000-0000-0000-000000000000/reply")
                .then().statusCode(404);
    }

    @Test
    void blankReplyYields400() {
        CaseRecord record = seededCase();
        given().contentType("application/json").body("{\"message\":\" \"}")
                .post("/api/cases/" + record.caseId() + "/reply")
                .then().statusCode(400);
        given().contentType("application/json").body("{}")
                .post("/api/cases/" + record.caseId() + "/reply")
                .then().statusCode(400);
    }

    @Test
    void openCaseListShowsSeededCase() {
        CaseRecord record = seededCase();
        given().get("/api/cases?status=open").then()
                .statusCode(200)
                .body("size()", greaterThanOrEqualTo(1))
                .body("find { it.caseId == '" + record.caseId() + "' }.status", equalTo("open"))
                .body("find { it.caseId == '" + record.caseId() + "' }.messageCount", equalTo(1))
                .body("find { it.caseId == '" + record.caseId() + "' }.createdAt", notNullValue());
    }

    @Test
    void caseDetailShowsThread() {
        CaseRecord record = seededCase();
        given().get("/api/cases/" + record.caseId()).then()
                .statusCode(200)
                .body("caseId", equalTo(record.caseId()))
                .body("status", equalTo("open"))
                .body("messages", hasSize(1))
                .body("messages[0].author", equalTo("submission"));
    }

    @Test
    void replyIsAcceptedAndAppendedAfterPublish() {
        CaseRecord record = seededCase();
        given().contentType("application/json")
                .body("{\"message\":\"management answer\"}")
                .post("/api/cases/" + record.caseId() + "/reply").then()
                .statusCode(202)
                .body("caseId", equalTo(record.caseId()))
                .body("eventId", notNullValue())
                .body("status", equalTo("accepted"));

        given().get("/api/cases/" + record.caseId()).then()
                .statusCode(200)
                .body("messages", hasSize(2))
                .body("messages[1].author", equalTo("management"))
                .body("messages[1].seq", equalTo(1));
    }
}
