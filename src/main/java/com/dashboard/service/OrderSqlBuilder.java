package com.dashboard.service;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Collectors;

class OrderSqlBuilder {

    private OrderSqlBuilder() {}

    static String buildSearchCte(String q, MapSqlParameterSource params) {
        return "";
    }

    static String buildWhere(boolean fulltextEnabled, String q, String status, String regionCode,
                              String from, String to,
                              BigDecimal minTotal, BigDecimal maxTotal,
                              MapSqlParameterSource params) {
        List<String> clauses = new ArrayList<>();

        if (q != null && !q.isBlank()) {
            if (fulltextEnabled) {
                clauses.add("o.search_tsv @@ websearch_to_tsquery('simple', :q)");
                params.addValue("q", q.strip());
            } else {
                String[] tokens = q.strip().split("\\s+");
                for (int i = 0; i < tokens.length; i++) {
                    String key = "q" + i;
                    clauses.add("o.search_text ILIKE :" + key);
                    params.addValue(key, "%" + tokens[i] + "%");
                }
            }
        }
        if (status != null && !status.isBlank()) {
            List<String> statuses = Arrays.stream(status.split(","))
                    .map(String::strip).filter(s -> !s.isEmpty()).toList();
            clauses.add("o.status = ANY(ARRAY[" +
                    statuses.stream().map(s -> "'" + s + "'::\"OrderStatus\"").collect(Collectors.joining(",")) + "])");
        }
        if (regionCode != null && !regionCode.isBlank()) {
            List<String> codes = Arrays.stream(regionCode.split(","))
                    .map(String::strip).filter(s -> !s.isEmpty()).toList();
            clauses.add("r.code = ANY(ARRAY[" +
                    codes.stream().map(c -> "'" + c + "'").collect(Collectors.joining(",")) + "])");
        }
        if (from != null && !from.isBlank()) {
            clauses.add("o.\"placedAt\" >= :from::timestamptz");
            params.addValue("from", from);
        }
        if (to != null && !to.isBlank()) {
            clauses.add("o.\"placedAt\" <= (:to::date + interval '1 day' - interval '1 second')");
            params.addValue("to", to);
        }
        if (minTotal != null) {
            clauses.add("o.total >= :minTotal");
            params.addValue("minTotal", minTotal);
        }
        if (maxTotal != null) {
            clauses.add("o.total <= :maxTotal");
            params.addValue("maxTotal", maxTotal);
        }
        return clauses.isEmpty() ? "" : "WHERE " + String.join(" AND ", clauses);
    }

    static String buildCountCacheKey(String q, String status, String regionCode,
                                      String from, String to,
                                      BigDecimal minTotal, BigDecimal maxTotal) {
        return "q=" + (q != null ? q.strip().toLowerCase() : "") +
               "&status=" + (status != null ? status : "") +
               "&regionCode=" + (regionCode != null ? regionCode : "") +
               "&from=" + (from != null ? from : "") +
               "&to=" + (to != null ? to : "") +
               "&minTotal=" + (minTotal != null ? minTotal.toPlainString() : "") +
               "&maxTotal=" + (maxTotal != null ? maxTotal.toPlainString() : "");
    }

    static String flipOrderByDirection(String orderBy) {
        return orderBy.replace(" DESC", "  ").replace(" ASC", " DESC").replace("  ", " ASC");
    }
}
