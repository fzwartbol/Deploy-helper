package com.example.dashboard;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

@ApplicationScoped
public class PvcPipelineRunParser {
    @Inject DashboardApplicationsConfig applicationsConfig;
    @Inject TestResultServerConfig serverConfig;
    @Inject AllureReportParser allureReportParser;

    public List<TestStatusPayload> parseAll() {
        List<TestStatusPayload> out = new ArrayList<>();
        for (ApplicationDefinition app : applicationsConfig.applications()) {
            Path summary = Path.of(serverConfig.allureRoot(), app.app(), app.environment(), serverConfig.summaryRelativePath());
            if (!Files.exists(summary)) continue;
            String base = trimSlash(serverConfig.baseUrl());
            String reportPath = "/" + app.app() + "/" + app.environment() + "/";
            String allureUrl = base.isBlank() ? null : base + reportPath;
            out.add(allureReportParser.parse(summary, app, "main", "pvc-sync", null, allureUrl));
        }
        return out;
    }

    private String trimSlash(String v) { return v == null ? "" : v.replaceAll("/$", ""); }
}
