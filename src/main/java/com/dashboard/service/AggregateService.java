package com.dashboard.service;

import com.dashboard.dto.DailyAggregateDTO;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.util.*;

@Service
@RequiredArgsConstructor
public class AggregateService {

    private final NamedParameterJdbcTemplate jdbc;
    private final OrderService orderService;

    /**
     * Exact distinct order count for the same filters as getDailyAggregates.
     * This exists because the per-category rows above cannot be summed into a
     * grand total: an order with items in two categories gets totalOrders=1
     * in EACH category's row (correct for the category breakdown), so summing
     * across categories double-counts any order spanning more than one
     * category.
     *
     * Delegates to OrderService.exactCount so /api/aggregates's grand total
     * and /api/orders's list total always agree and share the same
     * daily_order_count-rollup-for-pure-date-range / cached-count-otherwise
     * logic — see that method's javadoc for details.
     */
    public long getExactTotal(String from, String to, String q,
                               String status, String regionCode,
                               BigDecimal minTotal, BigDecimal maxTotal) {
        return orderService.exactCountUncapped(q, status, regionCode, from, to, minTotal, maxTotal);
    }

    public List<DailyAggregateDTO> getDailyAggregates(
            String from, String to, String q,
            String status, String regionCode,
            BigDecimal minTotal, BigDecimal maxTotal,
            Integer topCategories) {

        boolean hasQ = q != null && !q.isBlank();
        boolean isMultiToken = hasQ && q.strip().contains(" ");
        boolean hasStatus = status != null && !status.isBlank();
        boolean hasRegion = regionCode != null && !regionCode.isBlank();
        boolean hasTotal = minTotal != null || maxTotal != null;

        List<Map<String, Object>> rows;

        if (!hasQ && !hasStatus && !hasRegion && !hasTotal) {
            rows = queryDailySummary(from, to, regionCode);
        } else if (hasQ && isMultiToken && !hasTotal) {
            rows = queryMultiTokenViaCte(from, to, q, status, regionCode);
            if (rows.isEmpty()) rows = queryViaSearchText(from, to, q, status, regionCode, null, null);
        } else if (hasQ) {
            rows = queryViaSearchText(from, to, q, status, regionCode, minTotal, maxTotal);
        } else if (hasStatus && !hasRegion && !hasTotal) {
            rows = queryStatusCategorySummary(from, to, status);
        } else if ((hasStatus || hasRegion) && !hasTotal) {
            rows = queryFilterCategorySummary(from, to, status, regionCode);
        } else {
            rows = queryOrderCategoryFacts(from, to, status, regionCode, minTotal, maxTotal);
        }

        return buildResult(rows, topCategories != null ? topCategories : 5);
    }

    private List<Map<String, Object>> queryDailySummary(String from, String to, String regionCode) {
        var params = new MapSqlParameterSource()
                .addValue("from", from).addValue("to", to);
        String where = "WHERE date BETWEEN :from::date AND :to::date";
        if (regionCode != null && !regionCode.isBlank()) {
            where += " AND \"regionCode\" = ANY(ARRAY[" + quoteList(regionCode) + "])";
        }
        return jdbc.queryForList(
                "SELECT date::text AS day, \"categoryName\" AS category, " +
                "SUM(\"totalOrders\") AS total_orders, SUM(\"totalRevenue\") AS total_revenue, " +
                "SUM(\"totalItems\") AS total_items FROM daily_summary " + where +
                " GROUP BY date, \"categoryName\" ORDER BY date", params);
    }

    private List<Map<String, Object>> queryStatusCategorySummary(String from, String to, String status) {
        var params = new MapSqlParameterSource().addValue("from", from).addValue("to", to);
        return jdbc.queryForList(
                "SELECT date::text AS day, \"categoryName\" AS category, " +
                "SUM(\"totalOrders\") AS total_orders, SUM(\"totalRevenue\") AS total_revenue, " +
                "SUM(\"totalItems\") AS total_items FROM daily_status_category_summary " +
                "WHERE status = ANY(ARRAY[" + quoteStatusList(status) + "]) " +
                "AND date BETWEEN :from::date AND :to::date " +
                "GROUP BY date, \"categoryName\" ORDER BY date", params);
    }

    private List<Map<String, Object>> queryFilterCategorySummary(
            String from, String to, String status, String regionCode) {
        var params = new MapSqlParameterSource().addValue("from", from).addValue("to", to);
        List<String> extra = new ArrayList<>();
        if (status != null && !status.isBlank())
            extra.add("status = ANY(ARRAY[" + quoteStatusList(status) + "])");
        if (regionCode != null && !regionCode.isBlank())
            extra.add("\"regionCode\" = ANY(ARRAY[" + quoteList(regionCode) + "])");
        String where = "WHERE date BETWEEN :from::date AND :to::date" +
                (extra.isEmpty() ? "" : " AND " + String.join(" AND ", extra));
        return jdbc.queryForList(
                "SELECT date::text AS day, \"categoryName\" AS category, " +
                "SUM(\"totalOrders\") AS total_orders, SUM(\"totalRevenue\") AS total_revenue, " +
                "SUM(\"totalItems\") AS total_items FROM daily_filter_category_summary " +
                where + " GROUP BY date, \"categoryName\" ORDER BY date", params);
    }

    private List<Map<String, Object>> queryOrderCategoryFacts(
            String from, String to, String status, String regionCode,
            BigDecimal minTotal, BigDecimal maxTotal) {
        var params = new MapSqlParameterSource().addValue("from", from).addValue("to", to);
        List<String> extra = new ArrayList<>();
        if (status != null && !status.isBlank())
            extra.add("status = ANY(ARRAY[" + quoteStatusList(status) + "])");
        if (regionCode != null && !regionCode.isBlank())
            extra.add("\"regionCode\" = ANY(ARRAY[" + quoteList(regionCode) + "])");
        if (minTotal != null) { extra.add("\"orderTotal\" >= :minTotal"); params.addValue("minTotal", minTotal); }
        if (maxTotal != null) { extra.add("\"orderTotal\" <= :maxTotal"); params.addValue("maxTotal", maxTotal); }
        String where = "WHERE date BETWEEN :from::date AND :to::date" +
                (extra.isEmpty() ? "" : " AND " + String.join(" AND ", extra));
        return jdbc.queryForList(
                "SELECT date::text AS day, \"categoryName\" AS category, " +
                "COUNT(DISTINCT \"orderId\") AS total_orders, SUM(\"totalRevenue\") AS total_revenue, " +
                "SUM(\"totalItems\") AS total_items FROM order_category_facts " +
                where + " GROUP BY date, \"categoryName\" ORDER BY date", params);
    }

    private List<Map<String, Object>> queryViaSearchText(
            String from, String to, String q,
            String status, String regionCode,
            BigDecimal minTotal, BigDecimal maxTotal) {
        var params = new MapSqlParameterSource().addValue("from", from).addValue("to", to);
        String[] tokens = q.strip().split("\\s+");
        List<String> clauses = new ArrayList<>();
        for (int i = 0; i < tokens.length; i++) {
            String key = "q" + i;
            clauses.add("o.search_text ILIKE :" + key);
            params.addValue(key, "%" + tokens[i] + "%");
        }
        if (status != null && !status.isBlank())
            clauses.add("o.status = ANY(ARRAY[" + quoteStatusList(status) + "])");
        if (regionCode != null && !regionCode.isBlank())
            clauses.add("r.code = ANY(ARRAY[" + quoteList(regionCode) + "])");
        if (minTotal != null) { clauses.add("o.total >= :minTotal"); params.addValue("minTotal", minTotal); }
        if (maxTotal != null) { clauses.add("o.total <= :maxTotal"); params.addValue("maxTotal", maxTotal); }
        String where = "WHERE o.\"placedAt\"::date BETWEEN :from::date AND :to::date" +
                (clauses.isEmpty() ? "" : " AND " + String.join(" AND ", clauses));
        return jdbc.queryForList(
                "SELECT o.\"placedAt\"::date::text AS day, cat.name AS category, " +
                "COUNT(DISTINCT o.id)::bigint AS total_orders, " +
                "COALESCE(SUM(oi.quantity * oi.\"unitPrice\" * (1 - oi.discount)), 0) AS total_revenue, " +
                "COALESCE(SUM(oi.quantity), 0)::bigint AS total_items " +
                "FROM orders o " +
                "JOIN customers c ON c.id = o.\"customerId\" " +
                "JOIN regions r ON r.id = o.\"regionId\" " +
                "JOIN order_items oi ON oi.\"orderId\" = o.id " +
                "JOIN products p ON p.id = oi.\"productId\" " +
                "JOIN categories cat ON cat.id = p.\"categoryId\" " +
                where +
                " GROUP BY o.\"placedAt\"::date, cat.name ORDER BY o.\"placedAt\"::date",
                params);
    }

    private List<Map<String, Object>> queryMultiTokenViaCte(
            String from, String to, String q,
            String status, String regionCode) {
        var params = new MapSqlParameterSource()
                .addValue("from", from).addValue("to", to);
        String[] tokens = q.strip().split("\\s+");
        List<String> tokenClauses = new ArrayList<>();
        for (int i = 0; i < tokens.length; i++) {
            String key = "q" + i;
            tokenClauses.add("(\"firstName\" || ' ' || \"lastName\") ILIKE :" + key);
            params.addValue(key, "%" + tokens[i] + "%");
        }
        String customerWhere = String.join(" AND ", tokenClauses);
        List<String> extra = new ArrayList<>();
        if (status != null && !status.isBlank())
            extra.add("dcs.status = ANY(ARRAY[" + quoteStatusList(status) + "])");
        if (regionCode != null && !regionCode.isBlank())
            extra.add("dcs.\"regionCode\" = ANY(ARRAY[" + quoteList(regionCode) + "])");
        String extraWhere = extra.isEmpty() ? "" : " AND " + String.join(" AND ", extra);
        return jdbc.queryForList(
                "WITH matching_customers AS (" +
                "  SELECT id FROM customers WHERE " + customerWhere +
                ") " +
                "SELECT dcs.date::text AS day, dcs.\"categoryName\" AS category, " +
                "SUM(dcs.\"totalOrders\") AS total_orders, " +
                "SUM(dcs.\"totalRevenue\") AS total_revenue, " +
                "SUM(dcs.\"totalItems\") AS total_items " +
                "FROM daily_customer_category_summary dcs " +
                "WHERE dcs.\"customerId\" IN (SELECT id FROM matching_customers) " +
                "AND dcs.date BETWEEN :from::date AND :to::date" +
                extraWhere +
                " GROUP BY dcs.date, dcs.\"categoryName\" ORDER BY dcs.date",
                params);
    }

    private List<DailyAggregateDTO> buildResult(List<Map<String, Object>> rows, int topN) {
        // Group by day
        LinkedHashMap<String, Map<String, long[]>> byDay = new LinkedHashMap<>();
        for (var row : rows) {
            String day = (String) row.get("day");
            String cat = (String) row.get("category");
            long orders = toLong(row.get("total_orders"));
            double revenue = toDouble(row.get("total_revenue"));
            long items = toLong(row.get("total_items"));
            byDay.computeIfAbsent(day, k -> new LinkedHashMap<>())
                    .put(cat, new long[]{orders, Double.doubleToLongBits(revenue), items});
        }

        // Find top-N categories by total orders across the range
        Map<String, Long> catTotals = new HashMap<>();
        for (var dayMap : byDay.values())
            dayMap.forEach((cat, v) -> catTotals.merge(cat, v[0], Long::sum));
        Set<String> top = catTotals.entrySet().stream()
                .sorted(Map.Entry.<String, Long>comparingByValue().reversed())
                .limit(topN).map(Map.Entry::getKey)
                .collect(java.util.LinkedHashSet::new, LinkedHashSet::add, LinkedHashSet::addAll);

        List<DailyAggregateDTO> result = new ArrayList<>();
        for (var entry : byDay.entrySet()) {
            Map<String, DailyAggregateDTO.CategoryAggregateDTO> cats = new LinkedHashMap<>();
            long othersOrders = 0; double othersRevenue = 0; long othersItems = 0;
            for (var ce : entry.getValue().entrySet()) {
                long o = ce.getValue()[0];
                double r = Double.longBitsToDouble(ce.getValue()[1]);
                long i = ce.getValue()[2];
                if (top.contains(ce.getKey())) {
                    cats.put(ce.getKey(), new DailyAggregateDTO.CategoryAggregateDTO(
                            o, r, i, o > 0 ? r / o : 0));
                } else {
                    othersOrders += o; othersRevenue += r; othersItems += i;
                }
            }
            if (othersOrders > 0)
                cats.put("Others", new DailyAggregateDTO.CategoryAggregateDTO(
                        othersOrders, othersRevenue, othersItems,
                        othersOrders > 0 ? othersRevenue / othersOrders : 0));
            result.add(new DailyAggregateDTO(entry.getKey(), cats));
        }
        return result;
    }

    private String quoteList(String csv) {
        return Arrays.stream(csv.split(",")).map(String::strip)
                .filter(s -> !s.isEmpty()).map(s -> "'" + s.replace("'", "''") + "'")
                .collect(java.util.stream.Collectors.joining(","));
    }

    private String quoteStatusList(String csv) {
        return Arrays.stream(csv.split(",")).map(String::strip)
                .filter(s -> !s.isEmpty())
                .map(s -> "'" + s.replace("'", "''") + "'::\"OrderStatus\"")
                .collect(java.util.stream.Collectors.joining(","));
    }

    private long toLong(Object v) {
        return v instanceof Number n ? n.longValue() : 0L;
    }

    private double toDouble(Object v) {
        if (v instanceof BigDecimal bd) return bd.doubleValue();
        return v instanceof Number n ? n.doubleValue() : 0.0;
    }
}
