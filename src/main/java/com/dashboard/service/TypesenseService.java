package com.dashboard.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import java.util.ArrayList;
import java.util.List;

@Slf4j
@Service
public class TypesenseService {

    private final boolean enabled;
    private final RestClient restClient;
    private final ObjectMapper mapper = new ObjectMapper();

    public record SearchResult(List<Integer> ids, long total) {}

    public TypesenseService(
            @Value("${typesense.enabled:false}") boolean enabled,
            @Value("${typesense.url:}") String url,
            @Value("${typesense.api-key:}") String apiKey) {
        this.enabled = enabled;
        this.restClient = enabled
                ? RestClient.builder()
                        .baseUrl(url)
                        .defaultHeader("X-TYPESENSE-API-KEY", apiKey)
                        .build()
                : null;
    }

    public boolean isEnabled() { return enabled; }

    /**
     * Returns the IDs and total for the given page, or null on any failure
     * (caller falls back to Postgres ILIKE).
     */
    public SearchResult search(String q, int page, int perPage) {
        try {
            String body = restClient.get()
                    .uri(u -> u.path("/collections/orders/documents/search")
                            .queryParam("q", q)
                            .queryParam("query_by", "firstName,lastName,notes")
                            .queryParam("page", page)
                            .queryParam("per_page", perPage)
                            .build())
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
}
