package com.dashboard.controller;

import com.dashboard.service.TypesenseService;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api")
public class RuntimeController {

    @Value("${BACKEND_RUNTIME:cr}")
    private String runtime;

    @Value("${search.fulltext.enabled:false}")
    private boolean fulltextEnabled;

    private final TypesenseService typesenseService;

    public RuntimeController(TypesenseService typesenseService) {
        this.typesenseService = typesenseService;
    }

    @GetMapping("/runtime")
    public Map<String, String> runtime() {
        return Map.of("runtime", runtime);
    }

    @GetMapping("/status")
    public Map<String, Object> status() {
        boolean ts = typesenseService.isAvailable();
        String searchMode = ts ? "typesense"
                : fulltextEnabled ? "postgres-fts"
                : "postgres-ilike";
        return Map.of(
            "runtime", runtime,
            "typesense", ts,
            "searchMode", searchMode
        );
    }
}
