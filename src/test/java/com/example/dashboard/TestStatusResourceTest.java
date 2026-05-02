package com.example.dashboard;

import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.*;

@QuarkusTest
class TestStatusResourceTest {

    @Inject
    TestStatusService service;

    @BeforeEach
    @Transactional
    void cleanup() {
        TestStatusEntity.deleteAll();
        LatestStatusEntity.deleteAll();
    }

    @Test
    void latestIncludesConfiguredApplicationsAsUnknownWhenNoData() {
        given()
                .when().get("/api/test-status/latest")
                .then()
                .statusCode(200)
                .body("size()", is(2))
                .body("status", everyItem(anyOf(is("UNKNOWN"), is("GREEN"), is("YELLOW"), is("RED"))));
    }

    @Test
    void ingestStoresHistoryAndUpdatesLatest() {
        String payload = """
                {
                  "app":"checkout-service",
                  "environment":"dev",
                  "branch":"main",
                  "pipelineId":"run-123",
                  "timestamp":"2026-05-01T10:00:00Z",
                  "total":120,
                  "passed":115,
                  "failed":5,
                  "status":"YELLOW",
                  "pipelineUrl":"https://pipeline.example/run-123",
                  "allureUrl":"https://allure.example/checkout"
                }
                """;

        given().contentType("application/json").body(payload)
                .when().post("/api/test-status")
                .then().statusCode(202);

        given()
                .when().get("/api/test-status/latest")
                .then()
                .statusCode(200)
                .body("find { it.app == 'checkout-service' && it.environment == 'dev' && it.branch == 'main' }.status", is("YELLOW"))
                .body("find { it.app == 'checkout-service' && it.environment == 'dev' && it.branch == 'main' }.failed", is(5))
                .body("find { it.app == 'payment-service' && it.environment == 'staging' }.status", is("UNKNOWN"));
    }

    @Test
    void ingestAcceptsMockdataPayloadFromResourceFile() throws Exception {
        String payload = java.nio.file.Files.readString(java.nio.file.Path.of("src/test/resources/mockdata/test-status-payload.json"));

        given().contentType("application/json").body(payload)
                .when().post("/api/test-status")
                .then().statusCode(202);

        given()
                .when().get("/api/test-status/latest")
                .then()
                .statusCode(200)
                .body("find { it.app == 'checkout-service' && it.environment == 'dev' && it.branch == 'release/1.2' }.pipelineId", is("run-mock-1"))
                .body("find { it.app == 'checkout-service' && it.environment == 'dev' && it.branch == 'release/1.2' }.failed", is(5));
    }
}
