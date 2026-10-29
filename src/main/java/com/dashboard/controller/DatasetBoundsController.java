package com.dashboard.controller;

import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.namedparam.EmptySqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/dataset-bounds")
@RequiredArgsConstructor
public class DatasetBoundsController {

    private final NamedParameterJdbcTemplate jdbc;

    @GetMapping
    public ResponseEntity<?> get() {
        Map<String, Object> row = jdbc.queryForMap(
                "SELECT MIN(\"placedAt\")::date AS \"from\", MAX(\"placedAt\")::date AS \"to\" FROM orders",
                EmptySqlParameterSource.INSTANCE);
        return ResponseEntity.ok(Map.of(
                "from", row.get("from") != null ? row.get("from").toString() : "",
                "to",   row.get("to")   != null ? row.get("to").toString()   : ""));
    }
}
