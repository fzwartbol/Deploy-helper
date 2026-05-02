package com.example.dashboard;

import io.quarkus.hibernate.orm.panache.PanacheEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;

import java.time.OffsetDateTime;

@Entity
@Table(name = "test_status")
public class TestStatusEntity extends PanacheEntity {

    @Column(nullable = false, length = 100)
    public String app;

    @Column(length = 50)
    public String environment;

    @Column(length = 120)
    public String branch;

    @Column(name = "pipeline_id", length = 100)
    public String pipelineId;

    public OffsetDateTime timestamp;

    public Integer total;
    public Integer passed;
    public Integer failed;

    @Column(length = 10)
    public String status;

    @Column(name = "pipeline_url", length = 500)
    public String pipelineUrl;

    @Column(name = "allure_url", length = 500)
    public String allureUrl;
}
