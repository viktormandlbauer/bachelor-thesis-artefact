package at.thesis.poc.management.api;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.greaterThanOrEqualTo;
import static org.hamcrest.Matchers.hasSize;
import static org.hamcrest.Matchers.notNullValue;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import at.thesis.poc.management.messaging.CaseInboundConsumer;
import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.security.TestSecurity;
import io.quarkus.test.security.oidc.Claim;
import io.quarkus.test.security.oidc.OidcSecurity;
import io.vertx.core.json.JsonObject;
import jakarta.inject.Inject;

/**
 * REST contract and authorization tests (plan §5.2/§10.2). The OIDC tenant is disabled
 * in the test profile; identities are injected with @TestSecurity/@OidcSecurity, which
 * still exercises the @RolesAllowed checks: anonymous → 401, wrong role → 403, staff →
 * 200, reply author from the JWT. Cases are seeded through the real inbound consumer,
 * the same path the AMQP queue uses.
 */
@QuarkusTest
class CaseResourceTest {

    @Inject
    CaseInboundConsumer consumer;

    private String seededCaseId() {
        String caseId = UUID.randomUUID().toString();
        consumer.onCaseInbound(new JsonObject()
                .put("eventId", UUID.randomUUID().toString())
                .put("caseId", caseId)
                .put("direction", "inbound")
                .put("author", "submission")
                .put("seq", 1L)
                .put("body", "reporter message")
                .put("createdAt", Instant.now().toString()));
        return caseId;
    }

    @Test
    void anonymousRequestYields401() {
        given().get("/api/cases").then().statusCode(401);
        given().get("/api/cases/" + UUID.randomUUID()).then().statusCode(401);
        given().contentType("application/json").body("{\"message\":\"hi\"}")
                .post("/api/cases/" + UUID.randomUUID() + "/reply")
                .then().statusCode(401);
    }

    @Test
    @TestSecurity(user = "intern", roles = {})
    void authenticatedWithoutCaseManagerRoleYields403() {
        given().get("/api/cases").then().statusCode(403);
    }

    @Test
    @TestSecurity(user = "staff", roles = {"case-manager"})
    void unknownCaseYields404() {
        given().get("/api/cases/00000000-0000-0000-0000-000000000000").then().statusCode(404);
        given().contentType("application/json").body("{\"message\":\"hi\"}")
                .post("/api/cases/00000000-0000-0000-0000-000000000000/reply")
                .then().statusCode(404);
    }

    @Test
    @TestSecurity(user = "staff", roles = {"case-manager"})
    void blankReplyYields400() {
        String caseId = seededCaseId();
        given().contentType("application/json").body("{\"message\":\" \"}")
                .post("/api/cases/" + caseId + "/reply")
                .then().statusCode(400);
        given().contentType("application/json").body("{}")
                .post("/api/cases/" + caseId + "/reply")
                .then().statusCode(400);
    }

    @Test
    @TestSecurity(user = "staff", roles = {"case-manager"})
    void openCaseListShowsSeededCase() {
        String caseId = seededCaseId();
        given().get("/api/cases?status=open").then()
                .statusCode(200)
                .body("size()", greaterThanOrEqualTo(1))
                .body("find { it.caseId == '" + caseId + "' }.status", equalTo("open"))
                .body("find { it.caseId == '" + caseId + "' }.messageCount", equalTo(1))
                .body("find { it.caseId == '" + caseId + "' }.createdAt", notNullValue());
    }

    @Test
    @TestSecurity(user = "staff", roles = {"case-manager"})
    void caseDetailShowsThread() {
        String caseId = seededCaseId();
        given().get("/api/cases/" + caseId).then()
                .statusCode(200)
                .body("caseId", equalTo(caseId))
                .body("status", equalTo("open"))
                .body("messages", hasSize(1))
                .body("messages[0].author", equalTo("submission"));
    }

    @Test
    @TestSecurity(user = "staff", roles = {"case-manager"})
    @OidcSecurity(claims = {
            @Claim(key = "preferred_username", value = "staff.user")
    })
    void replyIsCommittedWithAuthorFromJwt() {
        String caseId = seededCaseId();
        given().contentType("application/json")
                .body("{\"message\":\"management answer\"}")
                .post("/api/cases/" + caseId + "/reply").then()
                .statusCode(202)
                .body("caseId", equalTo(caseId))
                .body("eventId", notNullValue())
                .body("status", equalTo("accepted"));

        given().get("/api/cases/" + caseId).then()
                .statusCode(200)
                .body("messages", hasSize(2))
                .body("messages[1].author", equalTo("staff.user"))
                .body("messages[1].seq", equalTo(1));
    }

    @Test
    @TestSecurity(user = "staff", roles = {"case-manager"})
    void replyAuthorFallsBackToPrincipalName() {
        String caseId = seededCaseId();
        given().contentType("application/json")
                .body("{\"message\":\"fallback author\"}")
                .post("/api/cases/" + caseId + "/reply").then()
                .statusCode(202);

        given().get("/api/cases/" + caseId).then()
                .statusCode(200)
                .body("messages[1].author", equalTo("staff"));
    }
}
