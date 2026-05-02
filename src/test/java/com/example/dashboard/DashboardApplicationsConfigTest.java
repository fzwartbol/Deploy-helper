package com.example.dashboard;

import io.quarkus.test.junit.QuarkusTest;
import jakarta.inject.Inject;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

@QuarkusTest
class DashboardApplicationsConfigTest {

    @Inject
    DashboardApplicationsConfig config;

    @Test
    void parsesCardsFromConfig() {
        var applications = config.applications();
        assertEquals(2, applications.size());
        assertEquals("checkout-service", applications.get(0).app());
        assertEquals("dev", applications.get(0).environment());
    }

    @Test
    void rejectsInvalidEntries() {
        IllegalArgumentException ex = assertThrows(IllegalArgumentException.class,
                () -> new DashboardApplicationsConfig() {{ applications = "bad-entry"; }}.applications());
        assertTrue(ex.getMessage().contains("Expected app:environment"));
    }
}
