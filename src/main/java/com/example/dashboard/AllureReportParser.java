package com.example.dashboard;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;

@ApplicationScoped
public class AllureReportParser {
    private final ObjectMapper mapper = new ObjectMapper();

    public TestStatusPayload parse(Path summaryPath, ApplicationDefinition app, String branch, String pipelineId, String pipelineUrl, String allureUrl) {
        try {
            JsonNode root = mapper.readTree(Files.readString(summaryPath));
            JsonNode stat = root.path("statistic");
            int total = intOr(root, stat, "total");
            int passed = intOr(root, stat, "passed");
            int failed = intOr(root, stat, "failed") + intOr(root, stat, "broken");
            String status = root.path("status").asText(deriveStatus(total, failed));
            return new TestStatusPayload(app.app(), app.environment(), branch, pipelineId, OffsetDateTime.now(), total, passed, failed, status, pipelineUrl, allureUrl);
        } catch (IOException e) {
            throw new IllegalStateException("Failed to parse Allure summary: " + summaryPath, e);
        }
    }

    private int intOr(JsonNode root, JsonNode stat, String key) {
        if (stat.has(key)) return stat.path(key).asInt(0);
        return root.path(key).asInt(0);
    }

    private String deriveStatus(int total, int failed) {
        if (total <= 0) return "UNKNOWN";
        if (failed == 0) return "GREEN";
        return ((double) failed / total) < 0.1 ? "YELLOW" : "RED";
    }
}
