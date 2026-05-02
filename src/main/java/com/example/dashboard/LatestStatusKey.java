package com.example.dashboard;

import java.io.Serializable;
import java.util.Objects;

public class LatestStatusKey implements Serializable {
    public String app;
    public String environment;
    public String branch;

    public LatestStatusKey() {}

    public LatestStatusKey(String app, String environment, String branch) {
        this.app = app;
        this.environment = environment;
        this.branch = branch;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof LatestStatusKey that)) return false;
        return Objects.equals(app, that.app) && Objects.equals(environment, that.environment) && Objects.equals(branch, that.branch);
    }

    @Override
    public int hashCode() {
        return Objects.hash(app, environment, branch);
    }
}
