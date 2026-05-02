package com.example.dashboard;

import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

@ApplicationScoped
public class TestResultServerConfig {

    @ConfigProperty(name = "testresult.server.base-url", defaultValue = "")
    String baseUrl;

    @ConfigProperty(name = "testresult.pvc.allure-root", defaultValue = "/allure")
    String allureRoot;

    @ConfigProperty(name = "testresult.pvc.summary-relative-path", defaultValue = "widgets/summary.json")
    String summaryRelativePath;

    public String baseUrl() { return baseUrl; }
    public String allureRoot() { return allureRoot; }
    public String summaryRelativePath() { return summaryRelativePath; }
}
