package com.example.dashboard;

import io.quarkus.panache.common.Sort;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@ApplicationScoped
public class TestStatusService {

    @Inject
    DashboardApplicationsConfig applicationsConfig;

    @Transactional
    public void ingest(TestStatusPayload payload) {
        TestStatusEntity history = mapHistory(payload);
        history.persist();

        LatestStatusEntity latest = LatestStatusEntity.findById(new LatestStatusKey(payload.app(), payload.environment(), payload.branch()));
        if (latest == null) {
            latest = new LatestStatusEntity();
            latest.app = payload.app();
            latest.environment = payload.environment();
            latest.branch = payload.branch();
        }

        latest.branch = payload.branch();
        latest.pipelineId = payload.pipelineId();
        latest.timestamp = payload.timestamp();
        latest.total = payload.total();
        latest.passed = payload.passed();
        latest.failed = payload.failed();
        latest.status = payload.status();
        latest.pipelineUrl = payload.pipelineUrl();
        latest.allureUrl = payload.allureUrl();
        latest.persist();
    }

    public List<LatestStatusDto> latest() {
        Map<String, LatestStatusDto> merged = new LinkedHashMap<>();

        for (ApplicationDefinition application : applicationsConfig.applications()) {
            merged.put(key(application.app(), application.environment(), "main"), new LatestStatusDto(
                    application.app(), application.environment(), "main", null, null, null, null, null, "UNKNOWN", null, null));
        }

        List<LatestStatusEntity> rows = LatestStatusEntity.findAll(Sort.by("environment").and("app").and("branch")).list();
        for (LatestStatusEntity row : rows) {
            merged.put(key(row.app, row.environment, row.branch), new LatestStatusDto(row.app, row.environment, row.branch, row.pipelineId, row.timestamp,
                    row.total, row.passed, row.failed, row.status, row.pipelineUrl, row.allureUrl));
        }

        return merged.values().stream().toList();
    }

    private static String key(String app, String environment, String branch) {
        return app + "::" + environment + "::" + branch;
    }

    private static TestStatusEntity mapHistory(TestStatusPayload payload) {
        TestStatusEntity entity = new TestStatusEntity();
        entity.app = payload.app();
        entity.environment = payload.environment();
        entity.branch = payload.branch();
        entity.pipelineId = payload.pipelineId();
        entity.timestamp = payload.timestamp();
        entity.total = payload.total();
        entity.passed = payload.passed();
        entity.failed = payload.failed();
        entity.status = payload.status();
        entity.pipelineUrl = payload.pipelineUrl();
        entity.allureUrl = payload.allureUrl();
        return entity;
    }
}
