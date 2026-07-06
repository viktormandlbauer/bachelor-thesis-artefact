package at.thesis.poc.submission.api;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.hasSize;
import static org.hamcrest.Matchers.notNullValue;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;
import io.restassured.response.Response;

/**
 * REST contract tests (plan §5.1). Runs against Dev Services PostgreSQL and Artemis; a
 * successful POST means the local transaction (domain rows + outbox row) committed —
 * the thread is immediately readable because it is local state, while delivery to the
 * management side is the relay's asynchronous job.
 */
@QuarkusTest
class CaseResourceTest {

    private Response createCase(String message) {
        return given()
                .contentType("application/json")
                .body("{\"message\":\"" + message + "\"}")
                .post("/api/cases");
    }

    @Test
    void blankMessageIsRejectedWith400() {
        createCase("   ").then().statusCode(400);
        given().contentType("application/json").body("{}")
                .post("/api/cases").then().statusCode(400);
    }

    @Test
    void createReturns201WithTokenAndIds() {
        createCase("hello management").then()
                .statusCode(201)
                .body("caseId", notNullValue())
                .body("eventId", notNullValue())
                .body("accessToken", notNullValue())
                .body("note", equalTo(CaseResource.TOKEN_NOTE));
    }

    @Test
    void wrongOrMissingTokenYields404NotForbidden() {
        Response created = createCase("secret report");
        String caseId = created.jsonPath().getString("caseId");

        given().get("/api/cases/" + caseId).then().statusCode(404);
        given().header("X-Case-Token", "not-the-token")
                .get("/api/cases/" + caseId).then().statusCode(404);
        given().header("X-Case-Token", "whatever")
                .get("/api/cases/00000000-0000-0000-0000-000000000000")
                .then().statusCode(404);
    }

    @Test
    void tokenGatedReadReturnsThread() {
        Response created = createCase("first message");
        String caseId = created.jsonPath().getString("caseId");
        String token = created.jsonPath().getString("accessToken");
        String eventId = created.jsonPath().getString("eventId");

        given().header("X-Case-Token", token)
                .get("/api/cases/" + caseId).then()
                .statusCode(200)
                .body("caseId", equalTo(caseId))
                .body("status", equalTo("open"))
                .body("messages", hasSize(1))
                .body("messages[0].eventId", equalTo(eventId))
                .body("messages[0].author", equalTo("submission"))
                .body("messages[0].seq", equalTo(1))
                .body("messages[0].body", equalTo("first message"));
    }

    @Test
    void followUpAppendsToThreadWith202() {
        Response created = createCase("first");
        String caseId = created.jsonPath().getString("caseId");
        String token = created.jsonPath().getString("accessToken");

        given().header("X-Case-Token", token)
                .contentType("application/json")
                .body("{\"message\":\"follow-up\"}")
                .post("/api/cases/" + caseId + "/messages").then()
                .statusCode(202)
                .body("caseId", equalTo(caseId))
                .body("eventId", notNullValue())
                .body("status", equalTo("accepted"));

        given().header("X-Case-Token", token)
                .get("/api/cases/" + caseId).then()
                .statusCode(200)
                .body("messages", hasSize(2))
                .body("messages[1].seq", equalTo(2));
    }

    @Test
    void followUpWithWrongTokenYields404() {
        Response created = createCase("first");
        String caseId = created.jsonPath().getString("caseId");

        given().header("X-Case-Token", "wrong")
                .contentType("application/json")
                .body("{\"message\":\"follow-up\"}")
                .post("/api/cases/" + caseId + "/messages").then()
                .statusCode(404);
    }
}
