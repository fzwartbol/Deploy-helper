package com.example.dashboard;

import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.util.Arrays;
import java.util.List;

@ApplicationScoped
public class DashboardApplicationsConfig {

    @ConfigProperty(name = "dashboard.applications", defaultValue = "")
    String applications;

    public List<ApplicationDefinition> applications() {
        if (applications == null || applications.isBlank()) {
            return List.of();
        }

        return Arrays.stream(applications.split(","))
                .map(String::trim)
                .filter(v -> !v.isBlank())
                .map(this::toApplication)
                .toList();
    }

    private ApplicationDefinition toApplication(String value) {
        String[] parts = value.split(":", 2);
        if (parts.length != 2 || parts[0].isBlank() || parts[1].isBlank()) {
            throw new IllegalArgumentException("Invalid dashboard.applications entry: " + value + ". Expected app:environment");
        }
        return new ApplicationDefinition(parts[0].trim(), parts[1].trim());
    }
}
