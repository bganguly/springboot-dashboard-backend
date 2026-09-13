package com.dashboard.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import java.math.BigDecimal;
import java.net.http.HttpClient;
import java.time.Duration;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Collectors;

@Slf4j
@Service
public class TypesenseService {

    private static final long HEALTH_TTL_MS = 30_000;

    private final boolean enabled;
    private final RestClient restClient;
    private final ObjectMapper mapper = new ObjectMapper();

    private volatile boolean typesenseAvailable = false;
    private volatile long lastHealthCheck = 0;

    public record SearchResult(List<Integer> ids, long total) {}

    public TypesenseService(
            @Value("${typesense.enabled:false}") boolean enabled,
            @Value("${typesense.url:}") String url,
            @Value("${typesense.api-key:}") String apiKey) {
        this.enabled = enabled;
        if (enabled) {
            var httpClient = HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(3))
                    .build();
            var factory = new JdkClientHttpRequestFactory(httpClient);
            factory.setReadTimeout(Duration.ofSeconds(5));
            this.restClient = RestClient.builder()
                    .baseUrl(url)
                    .defaultHeader("X-TYPESENSE-API-KEY", apiKey)
                    .requestFactory(factory)
                    .build();
        } else {
            this.restClient = null;
        }
    }

    public boolean isEnabled() { return enabled; }

    public boolean isAvailable() {
        if (!enabled) return false;
        long now = System.currentTimeMillis();
        if (now - lastHealthCheck > HEALTH_TTL_MS) {
            lastHealthCheck = now;
            typesenseAvailable = probe();
        }
        return typesenseAvailable;
    }

    private boolean probe() {
        try {
            restClient.get().uri("/health").retrieve().toBodilessEntity();
            return true;
        } catch (Exception e) {
            log.debug("Typesense health probe failed: {}", e.getMessage());
            return false;
        }
    }

    public SearchResult search(String q, int page, int perPage,
                               String sort, String dir,
                               String status, String regionCode,
                               String from, String to,
                               BigDecimal minTotal, BigDecimal maxTotal) {
        try {
            String sortBy = buildSortBy(sort, dir);
            String filterBy = buildFilterBy(status, regionCode, from, to, minTotal, maxTotal);

            String body = restClient.get()
                    .uri(u -> {
                        var b = u.path("/collections/orders/documents/search")
                                .queryParam("q", q)
                                .queryParam("query_by", "firstName,lastName,notes")
                                .queryParam("sort_by", sortBy)
                                .queryParam("page", page)
                                .queryParam("per_page", perPage);
                        if (!filterBy.isEmpty()) {
                            b = b.queryParam("filter_by", filterBy);
                        }
                        return b.build();
                    })
                    .retrieve()
                    .body(String.class);

            JsonNode root = mapper.readTree(body);
            long found = root.path("found").asLong(0);
            List<Integer> ids = new ArrayList<>();
            for (JsonNode hit : root.path("hits")) {
                ids.add(hit.path("document").path("orderId").asInt());
            }
            return new SearchResult(ids, found);
        } catch (Exception e) {
            log.warn("Typesense search failed — falling back to Postgres: {}", e.getMessage());
            return null;
        }
    }

    private String buildSortBy(String sort, String dir) {
        String d = "asc".equalsIgnoreCase(dir) ? "asc" : "desc";
        return switch (sort != null ? sort : "") {
            case "total"  -> "total:" + d + ",placedAt:desc";
            case "id"     -> "id:" + d;
            case "status" -> "status:" + d + ",placedAt:desc";
            default       -> "placedAt:" + d;
        };
    }

    private String buildFilterBy(String status, String regionCode,
                                  String from, String to,
                                  BigDecimal minTotal, BigDecimal maxTotal) {
        List<String> filters = new ArrayList<>();

        if (status != null && !status.isBlank()) {
            String[] parts = Arrays.stream(status.split(","))
                    .map(String::strip).filter(s -> !s.isEmpty()).toArray(String[]::new);
            String joined = String.join(",", parts);
            filters.add(parts.length == 1 ? "status:=" + joined : "status:=[" + joined + "]");
        }
        if (regionCode != null && !regionCode.isBlank()) {
            String[] parts = Arrays.stream(regionCode.split(","))
                    .map(String::strip).filter(s -> !s.isEmpty()).toArray(String[]::new);
            String joined = String.join(",", parts);
            filters.add(parts.length == 1 ? "regionCode:=" + joined : "regionCode:=[" + joined + "]");
        }
        if (from != null && !from.isBlank()) {
            long epoch = LocalDate.parse(from.substring(0, 10))
                    .atStartOfDay(ZoneOffset.UTC).toEpochSecond();
            filters.add("placedAt:>=" + epoch);
        }
        if (to != null && !to.isBlank()) {
            long epoch = LocalDate.parse(to.substring(0, 10)).plusDays(1)
                    .atStartOfDay(ZoneOffset.UTC).toEpochSecond() - 1;
            filters.add("placedAt:<=" + epoch);
        }
        if (minTotal != null) {
            filters.add("total:>=" + minTotal.toPlainString());
        }
        if (maxTotal != null) {
            filters.add("total:<=" + maxTotal.toPlainString());
        }

        return String.join(" && ", filters);
    }
}
