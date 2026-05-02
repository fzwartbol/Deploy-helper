package com.example.dashboard;

import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.util.List;

@Path("/api/test-status")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class TestStatusResource {

    @Inject
    TestStatusService service;

    @Inject
    PvcPipelineRunParser pvcPipelineRunParser;

    @POST
    public Response ingest(TestStatusPayload payload) {
        service.ingest(payload);
        return Response.accepted().build();
    }

    @GET
    @Path("/latest")
    public List<LatestStatusDto> latest() {
        return service.latest();
    }

    @POST
    @Path("/sync-pvc")
    public Response syncPvc() {
        pvcPipelineRunParser.parseAll().forEach(service::ingest);
        return Response.accepted().build();
    }
}
