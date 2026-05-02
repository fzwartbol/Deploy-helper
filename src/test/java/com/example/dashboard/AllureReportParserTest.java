package com.example.dashboard;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;

class AllureReportParserTest {

    @Test
    void parsesAllureSummary() {
        AllureReportParser parser = new AllureReportParser();
        Path summary = Path.of("src/test/resources/mockdata/allure/widgets/summary.json");

        TestStatusPayload payload = parser.parse(summary, new ApplicationDefinition("checkout-service", "dev"), "main", "pvc-sync", null, "https://results.example/checkout");

        assertEquals(120, payload.total());
        assertEquals(115, payload.passed());
        assertEquals(5, payload.failed());
        assertEquals("YELLOW", payload.status());
    }
}
