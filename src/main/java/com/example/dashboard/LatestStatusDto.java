package com.example.dashboard;

import java.time.OffsetDateTime;

public record LatestStatusDto(
        String app,
        String environment,
        String branch,
        String pipelineId,
        OffsetDateTime timestamp,
        Integer total,
        Integer passed,
        Integer failed,
        String status,
        String pipelineUrl,
        String allureUrl
) {
}
